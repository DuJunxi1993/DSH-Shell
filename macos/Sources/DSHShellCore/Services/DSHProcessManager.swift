import Foundation
import os

private let logger = Logger(subsystem: "ai.deepseek.dsh-shell", category: "DSHProcessManager")

/// Errors thrown by `DSHProcessManager`.
public enum DSHProcessError: Error, LocalizedError, Sendable {
    case binaryNotFound(String)
    case binaryNotExecutable(String)
    case alreadyRunning
    case spawnFailed(Int32)
    case spawnFailedWithDetail(Int32, String)
    case timedOutWaitingForURL(Int, diagnostics: String)
    case noExistingEndpointFound
    case childExitedUnexpectedly(Int32, lastLogLines: [String])
    case nestedSession(vars: [String])
    case portInUse(host: String, port: Int)
    case nonLoopbackHost(String)
    case attachNeedsFixedPort

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "dsh binary not found at \(path). Set `dshBinaryPath` in Preferences."
        case .binaryNotExecutable(let path):
            return "dsh binary at \(path) is not executable. Run `chmod +x \(path)`."
        case .alreadyRunning:
            return "A dsh process is already running under this manager."
        case .spawnFailed:
            // The associated code is -1 on every path that reaches here without a real errno —
            // the child exited before it could report anything. Printing "errno
            // -1" is a lie the user cannot act on, and so is the `node`/PATH
            // advice that used to follow it: dsh is launched from an absolute
            // configured path and its own output goes to the log. Point at both
            // instead.
            return "dsh did not start, and did not say why. Its own output is in the "
                + "log file (see Preferences → Diagnostics), and it is also the first "
                + "thing to look for there."
        case .spawnFailedWithDetail(let code, let detail):
            return "Failed to spawn dsh (errno \(code)): \(detail)"
        case .timedOutWaitingForURL(let seconds, let diagnostics):
            // The old text pointed at "the console tab", which is a live UI that
            // is useless here — the user cannot see it while a launch screen is
            // up, and it is empty after a relaunch. The diagnosis has to be in
            // the error itself.
            return "dsh web did not print its authenticated URL line within \(seconds)s. "
                + "dsh prints that line from a plugin lifecycle hook, so a silent "
                + "dsh is stuck loading, not slow to listen.\n\n\(diagnostics)"
        case .noExistingEndpointFound:
            return "No dsh instance is listening on the configured port."
        case .childExitedUnexpectedly(let code, let lines):
            let tail = lines.suffix(5).joined(separator: "\n")
            return "dsh exited with status \(code). Last log:\n\(tail)"
        case .nestedSession(let vars):
            return "Refusing to start inside a harness session (found \(vars.joined(separator: ", "))). "
                + "A second dsh contends for the same ports, proxy and session store, and the damage lands on the outer session."
        case .portInUse(let host, let port):
            return "Nothing was started: \(host):\(port) is already in use. "
                + "Switch `launchMode` to `attach` to use the instance that owns it — this shell never kills a dsh it did not spawn."
        case .nonLoopbackHost(let host):
            return "Refusing to bind \(host): dsh listens on loopback only."
        case .attachNeedsFixedPort:
            return "attach mode needs a known port to adopt. Set `preferredPort` in Preferences."
        }
    }
}

/// Lifecycle events emitted by `DSHProcessManager`.
public enum DSHProcessEvent: Sendable {
    case launching
    case launched(pid: Int32)
    case stdoutLine(String)
    case stderrLine(String)
    case endpointResolved(URL)
    case childExited(status: Int32)
    case autoRestartScheduled(after: TimeInterval)
    case autoRestartAttempted
    case autoRestartAborted(reason: String)
    /// A leftover dsh from an earlier run was closed before spawning.
    ///
    /// Only ever emitted for a process `PortOccupant` could prove is this
    /// shell's own leavings; see `reclaimOrphans(from:terminate:log:)`.
    case orphanReclaimed(pid: Int32)
    /// The child died and the shell cannot bring it back on its own.
    ///
    /// Without this the window keeps showing the last good URL over a server
    /// that is no longer listening — a window that lies. Every path that loses
    /// the child emits it, so "the dsh is gone" is always something the UI can
    /// show rather than something only the log knows.
    case connectionLost(reason: String)
}

/// Bounds and shape of the crash-restart ladder.
///
/// Injectable so tests can exercise the ladder without waiting out the
/// production backoff. The defaults are the shipping values and mirror
/// `windows/src-tauri/src/config.rs` (`MAX_RESTARTS` = 3, `HEALTHY_AFTER` =
/// 60s, and the bounded port-release wait before a respawn).
public struct RestartPolicy: Sendable {
    /// How many times a crashed dsh is respawned before the shell gives up.
    /// Bounded on purpose: an unbounded restart loop fights the contract that
    /// closing the window ends the session.
    public var maxAttempts: Int
    /// A child that ran this long was working; its death is a new failure and
    /// resets the budget. Windows calls this `HEALTHY_AFTER`.
    public var healthyUptime: TimeInterval
    /// How long the ladder waits for the crashed child's port to come free
    /// before respawning anyway. Windows calls this `wait_for_port_release`.
    public var portReleaseTimeout: TimeInterval
    /// Delay before `attempt` (1-based) of the ladder. The default is a real
    /// exponential ladder, 2/4/8s capped at 30s.
    public var backoff: @Sendable (Int) -> TimeInterval

    public init(
        maxAttempts: Int = 3,
        healthyUptime: TimeInterval = 60,
        portReleaseTimeout: TimeInterval = 10,
        backoff: @escaping @Sendable (Int) -> TimeInterval = { attempt in
            min(30, pow(2.0, Double(attempt)))
        }
    ) {
        self.maxAttempts = maxAttempts
        self.healthyUptime = healthyUptime
        self.portReleaseTimeout = portReleaseTimeout
        self.backoff = backoff
    }

    public static let `default` = RestartPolicy()
}

/// Owns the `dsh web` child process. Never invokes a shell, so user input
/// cannot become argv injection. Implemented as an actor so all state mutation
/// happens under Swift's structured concurrency isolation rules.
public actor DSHProcessManager {
    /// How long a child gets to honour SIGTERM before SIGKILL. Long enough for
    /// dsh to close its listeners and release the port cleanly.
    public static let terminationGrace: TimeInterval = 5

    public let settings: ShellSettings
    private let resolver: EndpointResolver
    private let policy: RestartPolicy

    private var process: Process?
    private var listeners: [UUID: AsyncStream<DSHProcessEvent>.Continuation] = [:]
    private var state: ConnectionState = .idle
    private var lastLogLines: [String] = []
    private var restartAttempts: Int = 0
    private var inFlightAttach: Task<URL?, Error>?
    /// The one ladder. A second crash while it is running must not start a
    /// competing loop: two loops mean two spawns racing for one port, which
    /// presents as an intermittent `EADDRINUSE` nobody can reproduce.
    private var restartTask: Task<Void, Never>?
    /// True from just before `Process.run()` until the URL line resolves (or
    /// the attempt throws). The termination handler uses it to tell "the start
    /// failed" from "a working session crashed".
    private var startupInFlight = false
    /// Set by the termination handler when the child dies during startup, so
    /// the wait loop can fail fast instead of burning the whole timeout.
    private var startupExitStatus: Int32?
    /// When the current child was spawned; the reference point for
    /// `RestartPolicy.healthyUptime`. Nil when no child is running.
    private var spawnedAt: Date?
    /// Exit status of the last child, for the give-up message.
    private var lastExitStatus: Int32?
    /// Bumped on every accepted child exit. The ladder captures it before a
    /// respawn so it can tell "this attempt is running" from "it announced
    /// itself and immediately died", which must not end the ladder.
    private var exitGeneration = 0
    /// Cached PID of the currently spawned child, written synchronously right
    /// after `Process.run()` succeeds so a teardown path that cannot `await`
    /// the actor (e.g. `applicationWillTerminate`) can still signal the child.
    nonisolated(unsafe) private var lastSpawnedPID: Int32?

    public init(
        settings: ShellSettings,
        resolver: EndpointResolver = EndpointResolver(),
        policy: RestartPolicy = .default
    ) {
        self.settings = settings
        self.resolver = resolver
        self.policy = policy
    }

    /// Returns a live stream of events. The stream terminates when `stop()` is called.
    public func events() -> AsyncStream<DSHProcessEvent> {
        AsyncStream { continuation in
            let id = UUID()
            // Closure runs outside the actor; hop in to register.
            let selfRef = self
            Task { await selfRef.addListener(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeListener(id: id) }
            }
        }
    }

    private func addListener(id: UUID, continuation: AsyncStream<DSHProcessEvent>.Continuation) {
        listeners[id] = continuation
    }

    private func removeListener(id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private func broadcast(_ event: DSHProcessEvent) {
        for c in listeners.values { c.yield(event) }
    }

    /// Begin the lifecycle. Returns the URL once known.
    public func start() async throws -> URL {
        try Self.validateBinary(settings.dshBinaryPath)

        switch settings.launchMode {
        case .spawn:
            return try await startSpawn()
        case .attach:
            return try await startAttach()
        }
    }

        /// Who holds the port, what the child is doing, and what dsh last said.
    ///
    /// Assembled only once something has already gone wrong — every part of it
    /// runs another process, and none of it should happen on a healthy start.
    ///
    /// No shell is involved: `Process` is invoked directly with an argument
    /// vector built from integers we produced. The rule this class otherwise
    /// holds to — "never invokes a shell, so user input cannot become argv
    /// injection" — survives.
    static func diagnostics(port: Int, pid: Int32, lines: [String], extra: String? = nil) async -> String {
        var parts: [String] = []
        if let extra { parts.append(extra) }

        // dsh's own output, blank lines dropped. This is the reason the whole
        // function exists: a stalled start used to leave the log holding
        // nothing but the shell's own "starting" line.
        let tail = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(20)
        if tail.isEmpty {
            parts.append("dsh produced no output at all")
        } else {
            parts.append("dsh's last \(tail.count) line(s):\n"
                         + tail.map { "    \($0)" }.joined(separator: "\n"))
        }

        parts.append(await describePortHolder(port) ?? "nothing is bound to port \(port)")
        parts.append(await describeChild(pid))
        return parts.joined(separator: "\n")
    }

    /// `lsof` for whoever owns the port.
    ///
    /// A live listener is the interesting case. `Preflight` already refuses to
    /// start when one exists, so reaching here with a holder means something
    /// took the port between the preflight and dsh's own `listen` — the one race
    /// the preflight cannot close, and the one this makes visible.
    private static func describePortHolder(_ port: Int) async -> String? {
        guard let output = await run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)"], timeout: 5),
              !output.isEmpty
        else { return nil }
        let rows = output.split(separator: "\n").dropFirst().prefix(4)
        guard !rows.isEmpty else { return nil }
        return "port \(port) is in use by:\n"
            + rows.map { "    \($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
    }

    /// What the spawned child is, and whether it is still alive.
    ///
    /// "Exited without printing a URL line" and "still running, silent" are the
    /// two halves of the question, and they point at different bugs.
    private static func describeChild(_ pid: Int32) async -> String {
        guard let output = await run("/bin/ps",
                                     ["-o", "pid,ppid,stat,etime,command", "-p", "\(pid)"],
                                     timeout: 5),
              !output.isEmpty
        else {
            return "dsh pid \(pid) is no longer running — it exited without printing a URL line"
        }
        let rows = output.split(separator: "\n").dropFirst()
        guard !rows.isEmpty else {
            return "dsh pid \(pid) is no longer running — it exited without printing a URL line"
        }
        return "child process:\n"
            + rows.map { "    \($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
    }

    /// Run a diagnostic tool, bounded by `timeout`. Never throws: a diagnostic
    /// that cannot be gathered reports nothing rather than replacing the real
    /// error with a second one.
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Spawn

    private func startSpawn() async throws -> URL {
        if process != nil { throw DSHProcessError.alreadyRunning }

        // Before the guards, and before every spawn: a dsh orphaned by an
        // earlier run holds the port this launch needs, and preflight would
        // only be able to report that. Closing it first is the difference
        // between a start that recovers on its own and one that needs a
        // button; only a process proven to be this shell's own is touched.
        await reclaimOrphanedOnPort()

        // Both guards run before `spawn` and nowhere else. `attach` forks
        // nothing, so it cannot collide and is exempt.
        try Preflight.checkSpawn(settings: settings)

        state = .launching
        broadcast(.launching)
        startupExitStatus = nil
        startupInFlight = true
        defer { startupInFlight = false }

        let argv = Self.buildArgv(settings: settings)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.dshBinaryPath)
        process.arguments = Array(argv.dropFirst())
        process.environment = Self.childEnvironment(dshBinaryPath: settings.dshBinaryPath)
        // Never inherit the app's stdin: dsh would see a terminal it has no
        // business reading, and a close would race whatever is on it.
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let pid = proc.processIdentifier
            Task { await self?.handleChildExit(pid: pid, status: status) }
        }

        do {
            try process.run()
        } catch {
            let detail: String
            if let e = error as? POSIXError {
                detail = "POSIX code \(e.code.rawValue) (\(e.code)): \(e.localizedDescription)"
            } else {
                detail = "\(type(of: error)): \(error.localizedDescription)"
            }
            state = .failed(reason: "spawn failed: \(detail)")
            throw DSHProcessError.spawnFailedWithDetail(-1, detail)
        }

        self.process = process
        let pid = process.processIdentifier
        spawnedAt = Date()
        lastExitStatus = nil
        // Recorded the instant the PID exists, not when `start()` returns.
        // `start()` blocks for seconds waiting for the URL line, and a close
        // during that window finds neither this manager's teardown nor a stored
        // child — dsh would survive holding the port. The invariant is: while we
        // own, or are about to own, a dsh, its PID is recorded.
        lastSpawnedPID = pid
        broadcast(.launched(pid: pid))

        // Drain stdout/stderr. The detached tasks read from the pipe on a
        // utility-priority executor; FileHandle is Sendable, so the closures
        // can capture the local bindings without ceremony.
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        drain(handle: outHandle, isErr: false)
        drain(handle: errHandle, isErr: true)

        // Wait for the authenticated URL line. The port is only ever logged,
        // never adopted: see `probePortLiveness`.
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(TimeInterval(settings.spawnTimeoutSeconds))
        // Reported once, well before the deadline, so a dsh that is wedged
        // produces an explanation instead of a window that sits on
        // "Launching dsh web…" for two minutes and then a bare timeout.
        let stallAt = startedAt.addingTimeInterval(TimeInterval(settings.spawnStallReportSeconds))
        var stallReported = false
        var lastPhase: PortStatus?
        while true {
            if Task.isCancelled {
                await terminateSpawnedChild()
                throw CancellationError()
            }
            // A child that died before announcing itself is a failed start,
            // not a slow one. Failing here keeps the ladder responsive instead
            // of letting each attempt sit out the full spawn timeout.
            //
            // `.ready` wins the race when it happened at all: the endpoint was
            // printed, so this is a successful start whose session then
            // crashed, and the termination handler has already scheduled the
            // steady-state ladder.
            if let exitStatus = startupExitStatus {
                if case .ready = state {
                    startupExitStatus = nil
                } else {
                    startupExitStatus = nil
                    let lines = lastLogLines
                    await terminateSpawnedChild()
                    throw DSHProcessError.childExitedUnexpectedly(exitStatus, lastLogLines: lines)
                }
            }
            switch state {
            case .ready(let url):
                return url
            case .failed:
                await terminateSpawnedChild()
                throw DSHProcessError.spawnFailed(-1)
            case .shuttingDown:
                await terminateSpawnedChild()
                throw DSHProcessError.spawnFailed(-1)
            default:
                // Logged on *change*, not once. A start that is progressing
                // produces one line; a start that is stuck produces one line
                // naming which of the two stuck states it is in.
                let status = await probePortLiveness()
                if status != lastPhase {
                    Log.info("startup: dsh pid \(pid) — port \(settings.preferredPort) \(status.summary); waiting for the URL line")
                    lastPhase = status
                }
                if !stallReported, Date() >= stallAt {
                    stallReported = true
                    // Not a failure: the deadline below still decides. This only
                    // stops the wait from being silent, and says which of the two
                    // stuck states it is in.
                    let waited = settings.spawnStallReportSeconds
                    let budget = settings.spawnTimeoutSeconds
                    let summary = """
                        dsh has printed no URL line after \(waited)s and is not \
                        being failed yet (deadline \(budget)s). Port \
                        \(settings.preferredPort): \(status.summary).
                        """
                    let evidence = await Self.diagnostics(
                        port: settings.preferredPort, pid: pid, lines: lastLogLines)
                    Log.error(summary + "\n" + evidence)
                }
                if Date() >= deadline {
                    // Gather the evidence *before* the teardown. Killing the
                    // child first makes `ps` report nothing, and "the process
                    // is gone" is the one thing this diagnosis must not be able
                    // to say about a dsh that was alive the instant before.
                    let diagnostics = await Self.diagnostics(
                        port: settings.preferredPort, pid: pid, lines: lastLogLines,
                        extra: "final port state: \(status.summary)")
                    await terminateSpawnedChild()
                    throw DSHProcessError.timedOutWaitingForURL(
                        settings.spawnTimeoutSeconds, diagnostics: diagnostics)
                }
                try? await Task.sleep(nanoseconds: UInt64(settings.pollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    /// A `weak` reference that can be carried by a `@Sendable` closure.
private final class WeakActor: @unchecked Sendable {
    private weak var ref: DSHProcessManager?
    init(_ value: DSHProcessManager?) { ref = value }
    var value: DSHProcessManager? { ref }
}

/// What the port we asked dsh for is doing right now.
    ///
    /// The distinction is the whole point. "dsh is slow" and "dsh is broken" are
    /// different failures with the same symptom in the window, and they are
    /// separable: dsh prints its URL from a plugin lifecycle hook
    /// (`ctx.inject(["connection"], …)` in dsh-web-app), so a dsh that is
    /// *listening* but silent is stuck resolving that dependency chain, while a
    /// dsh that is not listening yet has not reached `server.listen()`.
    enum PortStatus: Equatable {
        /// No fixed port configured, or the child is gone — nothing to ask.
        case notApplicable
        case notListening
        /// Answering. The status code is 401 without a token, which is expected
        /// and still means "listening".
        case listening(statusCode: Int)

        var summary: String {
            switch self {
            case .notApplicable: return "not probed"
            case .notListening: return "nothing listening"
            case .listening(let code): return "listening (HTTP \(code))"
            }
        }
    }

    /// Ask the port we asked for whether anything is listening, purely to log
    /// it. This can never produce a URL.
    ///
    /// The earlier implementation adopted a probed `http://host:port/` as the
    /// endpoint. That URL has no `?token=`, and `authorizeIndex` answers `401`
    /// to it — verified against real dsh — so the feature could only ever
    /// produce a white window. Against a dsh that requires the token it was
    /// silently inert; against one that does not, it worked. The behaviour of
    /// the app therefore depended on the dsh version, which is the worst
    /// possible place for it.
    private func probePortLiveness() async -> PortStatus {
        guard settings.preferredPort > 0, Preflight.isLoopback(settings.listenHost) else {
            return .notApplicable
        }
        guard let process, process.isRunning else { return .notApplicable }
        guard let url = URL(string: "http://\(settings.listenHost):\(settings.preferredPort)/") else {
            return .notApplicable
        }
        let probe = HealthProbe()
        let result = await probe.probe(url: url, timeout: 1.0)
        return result.reachable ? .listening(statusCode: result.statusCode) : .notListening
    }

    /// Best-effort teardown of the just-spawned child when startup fails
    /// (timeout, cancellation, or a mid-start error). Prevents a dsh web that
    /// never reported its endpoint from lingering as an orphan.
    ///
    /// Also clears the record when the child is already gone: the startup path
    /// can observe an exit before the reap has been reflected here, and a
    /// manager that keeps a dead `Process` refuses the next spawn with
    /// `alreadyRunning`.
    private func terminateSpawnedChild() async {
        guard let process else { return }
        let pid = process.processIdentifier
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        lastSpawnedPID = nil
        spawnedAt = nil
        self.process = nil
    }

    /// Reads one pipe and hands whole lines to the actor.
    ///
    /// ## The version this replaces was the bug
    ///
    /// It iterated `FileHandle.AsyncBytes`, which yields **one byte per
    /// iteration** — a `read` syscall and a cooperative-pool hop per byte.
    /// Measured against a dsh that prints a realistic plugin-loader log, that
    /// sustains roughly 25 bytes/second. So a 20 KB startup log put the URL line
    /// thirteen minutes behind the pipe, and 200 KB never arrived at all.
    ///
    /// That is the whole explanation for a launch that sits on "Launching dsh
    /// web…" forever: dsh was healthy, the shell was reading its output at a
    /// speed that made reaching the URL line impossible. It looked
    /// "probabilistic" only because dsh's startup chatter varies — quiet
    /// launches finished, loud ones wedged.
    ///
    /// ## Why `readabilityHandler` and not a blocking loop
    ///
    /// A blocking `read` loop is the obvious answer and it does not work: the
    /// pipes `Process` hands back are non-blocking, so it returns EOF
    /// immediately and reports a child that is alive and quiet as a child that
    /// has exited. And parking a cooperative-pool thread for the life of the
    /// shell is not acceptable anyway.
    ///
    /// `readabilityHandler` is the API that already solves both: the kernel
    /// wakes it, `availableData` hands over everything buffered in one piece,
    /// and an empty read is genuinely EOF. No thread is held, and throughput is
    /// bounded by the pipe rather than by byte-by-byte iteration.
    private nonisolated func drain(handle: FileHandle, isErr: Bool) {
        let lines = LineAccumulator()
        // A weak box, because the actor outlives every drain and must not be kept
        // alive by one, while the closure itself has to be `@Sendable` — and a
        // `@Sendable` closure may not capture a `weak var`.
        let owner = WeakActor(self)
        let emit: @Sendable (String) -> Void = { line in
            Task {
                guard let self = owner.value else { return }
                if isErr {
                    await self.consumeStderr(line)
                } else {
                    await self.consumeStdout(line)
                }
            }
        }
        handle.readabilityHandler = { source in
            let chunk = source.availableData
            guard !chunk.isEmpty else {
                // The child closed the pipe. Retire the handler and emit the
                // partial line the loader may have left unterminated.
                source.readabilityHandler = nil
                if let last = lines.takeRemainder() { emit(last) }
                return
            }
            for line in lines.takeCompletedLines(chunk) { emit(line) }
        }
    }

    private func consumeStdout(_ line: String) {
        appendLog(line, isErr: false)
        broadcast(.stdoutLine(line))
        if case .ready = state { return }
        // Only stdout is a URL source. stderr carries dsh's `bili` proxy URL,
        // which is not the UI.
        if let url = resolver.resolveURL(in: line, expectedPort: settings.preferredPort) {
            state = .ready(url)
            broadcast(.endpointResolved(url))
        }
    }

    private func consumeStderr(_ line: String) {
        appendLog(line, isErr: true)
        broadcast(.stderrLine(line))
    }

    /// dsh's own output, to the log file as well as to memory.
    ///
    /// This used to live only in `lastLogLines`, which is in-memory and gone at
    /// exit. So when dsh failed to print its URL line, the log contained exactly
    /// one entry — the shell's own "starting" line — and nothing whatsoever about
    /// what dsh was doing. Measured over one afternoon: 5 undiagnosable stalls
    /// out of 12 launches, each of them this missing line.
    ///
    /// The file logger is async on its own queue, so this does not add latency to
    /// the drain task that is racing dsh's startup.
    private func appendLog(_ line: String, isErr: Bool) {
        lastLogLines.append(line)
        if lastLogLines.count > 200 { lastLogLines.removeFirst(lastLogLines.count - 200) }
        // Blank lines are the majority of a plugin loader's chatter; keeping
        // them makes the real lines unreadable in a text editor.
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Log.debug("\(isErr ? "stderr" : "stdout") │ \(line)")
    }

    /// The child died. This is the single place that decides whether the shell
    /// tries again or gives up, and every outcome is broadcast — including the
    /// ones that used to be silent.
    ///
    /// Note what this does *not* do any more: it does not abort the ladder on
    /// the first failed respawn. A crashed dsh holds its port for a moment
    /// after exiting, and the old code read that moment as "somebody else owns
    /// the port", gave up, and put the user in front of a manual Retry button.
    /// The ladder now owns the retry: wait for the port, respawn, and only
    /// report a failure once the budget is spent.
    private func handleChildExit(pid: Int32, status: Int32) {
        // An exit reported by a child a previous ladder attempt spawned must
        // not touch the state of the current attempt.
        guard process?.processIdentifier == pid else { return }

        exitGeneration += 1
        lastSpawnedPID = nil
        lastExitStatus = status
        appendLog("[exit] status=\(status)", isErr: true)
        broadcast(.childExited(status: status))

        if case .shuttingDown = state { return }

        // Dying before the URL line is a failed *start*, not a crashed
        // session: fail the attempt so the ladder can decide what to do. Once
        // the endpoint has been announced, this is a working session that
        // crashed — even if `startSpawn` has not returned yet.
        if startupInFlight {
            if case .ready = state {
                // Fall through: steady-state handling below.
            } else {
                startupExitStatus = status
                return
            }
        }

        // A child that ran long enough was working; its death is a new
        // failure and gets the full budget back. This replaces resetting on
        // the URL line, which forgave a dsh that crashed a second after
        // announcing itself — the shape a crash loop actually takes.
        let uptime = spawnedAt.map { Date().timeIntervalSince($0) } ?? 0
        spawnedAt = nil
        if uptime >= policy.healthyUptime {
            restartAttempts = 0
        }

        guard settings.autoRestartOnCrash else {
            fail(reason: "\(Self.describe(status: status)); automatic restart is off.")
            return
        }
        beginRestartLadder()
    }

    /// The part of dsh's output that says what went wrong.
    ///
    /// Only lines that look like an error, so the message carries the cause and
    /// not the load. Falls back to the tail when nothing matched, because a
    /// silent unexplained exit is exactly the case where *something* is better
    /// than nothing — but the caller is told which of the two it got.
    static func failureExplanation(from lines: [String]) -> String {
        let errors = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains("error") || lower.contains("failed")
                || lower.contains("eaddrinuse") || lower.contains("refused")
                || lower.contains("boom")
        }
        if !errors.isEmpty {
            return errors.suffix(6).map { "    \($0)" }.joined(separator: "\n")
        }
        let tail = lines.suffix(6)
        guard !tail.isEmpty else { return "" }
        return "dsh's last output:\n" + tail.map { "    \($0)" }.joined(separator: "\n")
    }

    private static func describe(status: Int32) -> String {
        status == 0
            ? "dsh exited normally while the window was still open"
            : "dsh exited with status \(status)"
    }

    /// Start the one ladder, unless it is already running.
    private func beginRestartLadder() {
        guard restartTask == nil else { return }
        restartTask = Task { [weak self] in
            await self?.runRestartLadder()
        }
    }

    /// The restart ladder: bounded, sequential, and single-owner.
    ///
    /// Each iteration consumes one unit of budget, waits for the backoff, waits
    /// for the crashed child to release the port, and respawns. A failed
    /// respawn is *not* the end of the ladder — it is the next iteration —
    /// which is what makes the common case (the port is still draining)
    /// recover without the user ever seeing it.
    private func runRestartLadder() async {
        defer { restartTask = nil }
        while true {
            if Task.isCancelled { return }
            if case .shuttingDown = state { return }

            guard restartAttempts < policy.maxAttempts else {
                let what = lastExitStatus.map { Self.describe(status: $0) }
                    ?? "dsh could not be started"
                fail(reason: "\(what) and the shell gave up after "
                     + "\(restartAttempts) restart attempt\(restartAttempts == 1 ? "" : "s").")
                return
            }

            restartAttempts += 1
            let delay = max(0, policy.backoff(restartAttempts))
            broadcast(.autoRestartScheduled(after: delay))
            Log.info("dsh crashed (\(lastExitStatus.map { "status \($0)" } ?? "start failed")); "
                     + "restarting in \(delay)s (attempt \(restartAttempts)/\(policy.maxAttempts))")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            if case .shuttingDown = state { return }

            broadcast(.autoRestartAttempted)
            // The dead child's handle: `startSpawn` refuses a manager that
            // still holds one.
            process = nil
            // Reclaim before waiting: an orphan atop the port is never going to
            // release it, so waiting out `portReleaseTimeout` first would burn
            // ten seconds of every attempt for nothing.
            await reclaimOrphanedOnPort()
            await waitForPortRelease()
            let generation = exitGeneration
            do {
                _ = try await startSpawn()
                // A respawn whose child announced its endpoint and then died
                // before this line would otherwise end the ladder with a dead
                // dsh and no restart. The exit already bumped the generation;
                // spend the next attempt on it.
                if exitGeneration != generation { continue }
                return
            } catch is CancellationError {
                return
            } catch {
                Log.error("dsh restart attempt \(restartAttempts)/\(policy.maxAttempts) "
                          + "failed: \(error.localizedDescription)")
            }
        }
    }

    /// Wait, bounded, for the crashed child's port to come free.
    ///
    /// The port has to be free *before* the respawn, not after: dsh's exit
    /// path closes the listener asynchronously, and respawning into a socket
    /// that is still draining fails preflight in exactly the way that used to
    /// end the ladder. Windows' `wait_for_port_release` is the same rule.
    func waitForPortRelease() async {
        guard settings.preferredPort > 0,
              Preflight.isLoopback(settings.listenHost)
        else { return }

        let deadline = Date().addingTimeInterval(policy.portReleaseTimeout)
        while Date() < deadline {
            if Task.isCancelled { return }
            if Preflight.isPortFree(host: settings.listenHost, port: settings.preferredPort) {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        Log.info("port \(settings.preferredPort) is still held "
                 + "\(Int(policy.portReleaseTimeout))s after the crash; "
                 + "the respawn will fail in preflight")
    }

    /// Close leftovers that are provably this shell's own, before spawning.
    ///
    /// Windows' `orphan::reclaim_orphan(AtStartup)` has no macOS counterpart,
    /// and its absence is what turned one orphaned `dsh web` into three doomed
    /// respawns and an error page: the port never came free because the process
    /// holding it was never supervised and nothing was going to close it.
    /// Retrying cannot fix an orphan; only closing it can.
    ///
    /// The right to kill is not widened. `PortOccupant` requires all three
    /// facts — this port, this configured dsh, and no parent — and anything less
    /// is left alone with a line in the log saying why. A dsh started in a
    /// terminal has that terminal as its parent; a child of ours that has just
    /// died still has this app, so neither can be mistaken for a leftover.
    @discardableResult
    private func reclaimOrphanedOnPort() async -> [Int32] {
        guard settings.preferredPort > 0,
              Preflight.isLoopback(settings.listenHost)
        else { return [] }

        // `lsof` and `ps` are synchronous; keep them off the actor's executor
        // so the drain tasks and the UI's state reads do not queue behind them.
        let port = settings.preferredPort
        let binaryPath = settings.dshBinaryPath
        let occupants = await Task.detached(priority: .utility) {
            PortOccupant.occupants(ofPort: port, binaryPath: binaryPath)
        }.value

        let reclaimed = Self.reclaimOrphans(from: occupants)
        for pid in reclaimed { broadcast(.orphanReclaimed(pid: pid)) }
        return reclaimed
    }

    /// The decision, separated from discovery and from the event bus.
    ///
    /// Pure apart from its two injected effects, so the rule that decides
    /// whether the shell may terminate something stays testable without a live
    /// process: only `.orphan` verdicts are signalled, and only a successful
    /// termination counts as reclaimed.
    static func reclaimOrphans(from occupants: [PortOccupant],
                               terminate: (Int32) -> Bool = { PortOccupant.terminate(pid: $0) },
                               log: (String) -> Void = { Log.info($0) }) -> [Int32] {
        var reclaimed: [Int32] = []
        for occupant in occupants {
            switch occupant.verdict {
            case .orphan:
                if terminate(occupant.pid) {
                    log("reclaimed an orphaned dsh (pid \(occupant.pid)) "
                        + "holding the port: \(occupant.commandLine)")
                    reclaimed.append(occupant.pid)
                } else {
                    log("could not close the orphaned dsh (pid \(occupant.pid)); "
                        + "it may have exited on its own")
                }
            case .notOrphan(let reason):
                log("not touching pid \(occupant.pid) on the port: \(reason.explanation)")
            }
        }
        return reclaimed
    }

    /// Stop trying, and put a message on screen that carries the evidence.
    ///
    /// dsh's own last words go with it. A dsh that dies on `EADDRINUSE` says
    /// exactly that, on stderr, and it is the whole difference between a user
    /// who knows what happened and one reading "exited with status 1".
    private func fail(reason: String) {
        let explanation = Self.failureExplanation(from: lastLogLines)
        let full = explanation.isEmpty ? reason : reason + "\n\n" + explanation
        state = .failed(reason: full)
        broadcast(.autoRestartAborted(reason: reason))
        broadcast(.connectionLost(reason: full))
    }

    // MARK: - Attach

    private func startAttach() async throws -> URL {
        // Only the configured port. The previous implementation swept all 16384
        // macOS ephemeral ports with 32-way concurrency, ignored `preferredPort`
        // entirely, and could adopt a dsh belonging to a different session —
        // then, by design, never kill it.
        //
        // Note what attach can and cannot do: the URL it adopts has no token, so
        // the index answers 401. That is not a defect to work around — it is
        // information. Attaching to a token-fenced dsh requires that dsh's
        // authenticated URL, which only its owner can print. `attach` therefore
        // suits a dsh started with the fence already satisfied (a LaunchAgent,
        // or one whose cookie jar is shared); for a fresh `dsh web` the answer
        // is to print its URL line and paste it into Preferences.
        guard settings.preferredPort > 0 else {
            state = .failed(
                reason: "attach mode needs a fixed port. Set `preferredPort` in Preferences.")
            throw DSHProcessError.attachNeedsFixedPort
        }
        let probe = AttachProbe(host: settings.listenHost, port: settings.preferredPort)
        inFlightAttach?.cancel()
        let task = Task<URL?, Error> { await probe.findExisting() }
        inFlightAttach = task
        state = .connecting(host: settings.listenHost, port: settings.preferredPort)
        do {
            guard let url = try await task.value else {
                state = .failed(
                    reason: "Nothing is listening on \(settings.listenHost):\(settings.preferredPort).")
                throw DSHProcessError.noExistingEndpointFound
            }
            state = .ready(url)
            broadcast(.endpointResolved(url))
            return url
        } catch {
            state = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Shutdown

    public func stop() async {
        state = .shuttingDown
        // Cancel the ladder first: a retry that lands after the user asked
        // for the app to quit must not resurrect dsh.
        restartTask?.cancel()
        restartTask = nil
        startupExitStatus = nil

        // Signal the child first, and always — the previous version returned
        // early when there was no process, which skipped the reader-task
        // cancellation and the listener teardown below, leaving the event
        // stream open forever so any `for await` on it hung.
        if let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            let deadline = Date().addingTimeInterval(Self.terminationGrace)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                logger.warning("dsh pid \(pid, privacy: .public) ignored SIGTERM for \(Int(Self.terminationGrace))s; sending SIGKILL")
                kill(pid, SIGKILL)
                // Give the kernel a moment to reap so the port is actually free
                // by the time we return; the app's exit path depends on it.
                let hard = Date().addingTimeInterval(2)
                while process.isRunning && Date() < hard {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        // Clear the record only after the child is gone, so a concurrent
        // teardown path that reads `currentChildPID()` never sees a stale PID
        // it could signal twice — or misses the one it needed.
        lastSpawnedPID = nil
        spawnedAt = nil
        process = nil

        // The drain loops end on their own: they are blocked in `read` on a
        // pipe whose write end died with the child. There is nothing to cancel.
        inFlightAttach?.cancel()
        inFlightAttach = nil

        for c in listeners.values { c.finish() }
        listeners.removeAll()
    }

    // MARK: - Helpers

    /// Synchronous accessor for the teardown path that cannot `await` the
    /// actor (e.g. `applicationWillTerminate`). Reads the cached PID of the
    /// current child, if any; see `lastSpawnedPID`.
    nonisolated public func currentChildPID() -> Int32? {
        lastSpawnedPID
    }

    public static func validateBinary(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw DSHProcessError.binaryNotFound(path)
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw DSHProcessError.binaryNotExecutable(path)
        }
    }

    public static func buildArgv(settings: ShellSettings) -> [String] {
        var argv: [String] = [settings.dshBinaryPath, "web"]
        // dsh opens the default browser unless told otherwise; the WKWebView is
        // the shell's own surface, so never hand off to an external browser.
        argv.append("--no-open")
        argv.append(contentsOf: ["--host", settings.listenHost])
        // 0 means "let the OS pick", so the flag is omitted entirely rather
        // than passed as `--port 0`. A literal 0 is ambiguous — whether dsh
        // treats it as "kernel assigns" has never been verified against a real
        // dsh, and omitting the flag is the spelling that cannot be misread.
        if settings.preferredPort > 0 {
            argv.append(contentsOf: ["--port", String(settings.preferredPort)])
        }
        for host in settings.trustedHosts {
            argv.append(contentsOf: ["--trusted-host", host])
        }
        return argv
    }

    // NOTE: the orphan reaper that used to live here has been removed. It ran
    // `lsof` to find whoever held the configured port and killed it, which is
    // wrong twice over:
    //
    //   - It destroyed a `dsh web` the operator started by hand — possibly one
    //     they were actively using — merely by opening the app.
    //   - Its identification test could not work. It only killed a port owner
    //     that answered an *unauthenticated* request with the dsh SPA, and a
    //     token-fenced dsh answers `401` to exactly that. So against a current
    //     dsh the reaper never fired, and the orphan scenario it was sold as
    //     solving could not occur through it either.
    //
    // `Preflight.checkPortOwnership` replaces it: refuse to start, and name
    // `attach` as the alternative. A second dsh cannot share a port anyway, and
    // the user's alternative is already implemented.

    /// Environment for the child process.
    ///
    /// Two jobs, and the second is the one that used to be missing.
    ///
    /// **PATH.** Launching the app from Finder gives the process a minimal PATH
    /// (no Homebrew or npm locations), while `dsh` is a node script whose
    /// shebang is `#!/usr/bin/env node`; without `node` on the PATH the exec
    /// fails and the app reports "Failed to spawn dsh".
    ///
    /// **Strip the harness markers.** The previous version copied the entire
    /// parent environment, so a `DSH_SESSION_ID` / `DSH_PROFILE` / `DSH_WEB_URL`
    /// belonging to an *enclosing* harness session was handed to the child dsh.
    /// That child would then believe it is inside a session, contend for the
    /// same ports and session store, and the damage lands on the outer session.
    /// We never *set* a `DSH_*` variable to mark our own child: the same
    /// scrubbing that makes the markers trustworthy would strip it before dsh
    /// ever saw it.
    static func childEnvironment(dshBinaryPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in Preflight.harnessMarkers {
            env.removeValue(forKey: key)
        }

        var dirs: [String] = []
        dirs.append((dshBinaryPath as NSString).deletingLastPathComponent)
        dirs.append(contentsOf: ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"])
        let nvmRoot = NSHomeDirectory() + "/.nvm/versions/node"
        if FileManager.default.fileExists(atPath: nvmRoot) {
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvmRoot)) ?? []
            for version in versions.sorted(by: >) {
                dirs.append(nvmRoot + "/" + version + "/bin")
            }
        }
        if let existing = env["PATH"], !existing.isEmpty {
            dirs.append(existing)
        }
        env["PATH"] = dirs.joined(separator: ":")
        return env
    }
}
