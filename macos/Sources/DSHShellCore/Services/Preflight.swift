import Foundation

/// Guards run *before* `spawn` and nowhere else.
///
/// `attach` forks nothing, so it cannot collide with anything and is exempt
/// from both checks. This is the macOS half of a two-implementation contract;
/// the other half is `windows/src-tauri/src/preflight.rs`. See
/// `docs/dsh-shell-contract.md` §4.
public enum Preflight {
    /// The `DSH_*` variables dsh injects into every model-facing shell call.
    ///
    /// `dsh-shell-env` scrubs ambient `DSH_*` before injecting the session
    /// snapshot, which is what makes these a reliable signal rather than a
    /// guess. Note that this also means we must *not* set a `DSH_*` variable on
    /// our own child to mark it: the same scrubbing would strip it before dsh
    /// ever saw it.
    public static let harnessMarkers = [
        "DSH_SESSION_ID", "DSH_PROFILE", "DSH_PROFILE_DIR", "DSH_WEB_URL",
    ]

    /// A harness session is one where a `dsh` shell call is already running.
    ///
    /// A lone `DSH_PROFILE` is treated as *ambiguous* rather than decisive,
    /// because a user may legitimately have exported one in a normal terminal.
    /// A session id alone is decisive, and so are any two markers.
    public static func isNestedSession(environment: [String: String]) -> Bool {
        let present = harnessMarkers.filter { environment[$0] != nil }
        return environment["DSH_SESSION_ID"] != nil || present.count >= 2
    }

    /// Which harness markers are present, for the error message.
    public static func nestedSessionMarkers(
        environment: [String: String]
    ) -> [String] {
        harnessMarkers.filter { environment[$0] != nil }.sorted()
    }

    /// Whether the shell is running inside a harness session.
    public static func checkNesting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard isNestedSession(environment: environment) else { return }
        throw DSHProcessError.nestedSession(
            vars: nestedSessionMarkers(environment: environment))
    }

    /// Whether `port` can be bound right now.
    ///
    /// Tested by *binding*, not by scraping `lsof`/`netstat`, so it observes
    /// what dsh's own bind would observe. `SO_REUSEADDR` is set, because that
    /// is what a listening server sets: without it a socket lingering in
    /// `TIME_WAIT` from a previous run reports "in use" long after the listener
    /// is gone, which would refuse every launch after the first.
    public static func isPortFree(host: String, port: Int) -> Bool {
        guard port > 0, isLoopback(host) else { return true }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        // INADDR_ANY rather than the specific loopback address: a listener on
        // 127.0.0.1:port still makes this bind fail, which is the collision we
        // are looking for, and it also catches a wildcard listener.
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Refuse to spawn over a port someone else owns, and say what to do
    /// instead.
    ///
    /// The previous behaviour *killed* the port owner. That is wrong twice
    /// over: a dsh the operator started by hand — possibly one they are
    /// actively using — was destroyed by opening the app, and against a
    /// token-fenced dsh the probe that identified it never succeeded anyway,
    /// so the feature was either dangerous or inert.
    ///
    /// `0` means the OS assigns a port, so there is nothing to collide with.
    public static func checkPortOwnership(host: String, port: Int) throws {
        guard port > 0 else { return }
        guard !isLoopback(host) else {
            guard isPortFree(host: host, port: port) else {
                throw DSHProcessError.portInUse(host: host, port: port)
            }
            return
        }
        // dsh binds loopback only; refuse to hand it a non-loopback host rather
        // than discovering the refusal as a bind error much later.
        throw DSHProcessError.nonLoopbackHost(host)
    }

    public static func isLoopback(_ host: String) -> Bool {
        EndpointResolver.loopbackHosts.contains(host.lowercased())
    }

    /// Both guards, in the order they are reported: nesting first, because a
    /// nested harness is the more dangerous of the two.
    ///
    /// `environment` is injectable so the rules can be tested without mutating
    /// the process environment — a guard whose test depends on the machine it
    /// runs on is a guard that stops being tested.
    public static func checkSpawn(
        settings: ShellSettings,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try checkNesting(environment: environment)
        try checkPortOwnership(host: settings.listenHost, port: settings.preferredPort)
    }
}