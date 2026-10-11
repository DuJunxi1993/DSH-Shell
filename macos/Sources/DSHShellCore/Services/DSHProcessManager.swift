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
    case timedOutWaitingForURL(Int)
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
        case .spawnFailed(let code):
            return "Failed to spawn dsh (errno \(code)). If dsh is a node script, ensure `node` is reachable from the app's PATH (e.g. /opt/homebrew/bin)."
        case .spawnFailedWithDetail(let code, let detail):
            return "Failed to spawn dsh (errno \(code)): \(detail)"
        case .timedOutWaitingForURL(let seconds):
            return "dsh web did not print its authenticated URL line within \(seconds)s. "
                + "dsh's startup loader gates that line, and a port that answers is not enough — "
                + "the index answers 401 without the token. See the console tab for dsh's own output."
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
    /// The child died and the shell cannot bring it back on its own.
    ///
    /// Without this the window keeps showing the last good URL over a server
    /// that is no longer listening — a window that lies. Every path that loses
    /// the child emits it, so "the dsh is gone" is always something the UI can
    /// show rather than something only the log knows.
    case connectionLost(reason: String)
}

/// Owns the `dsh web` child process. Never invokes a shell, so user input
/// cannot become argv injection. Implemented as an actor so all state mutation
/// happens under Swift's structured concurrency isolation rules.
public actor DSHProcessManager {
    /// How many times a crashed dsh is respawned before the shell gives up and
    /// tells the user. Bounded on purpose: an unbounded restart loop fights the
    /// contract that closing the window ends the session.
    public static let maxRestartAttempts = 3
    public static let maxRestartDelay: TimeInterval = 30
    /// How long a child gets to honour SIGTERM before SIGKILL. Long enough for
    /// dsh to close its listeners and release the port cleanly.
    public static let terminationGrace: TimeInterval = 5

    public let settings: ShellSettings
    private let resolver: EndpointResolver

    private var process: Process?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<DSHProcessEvent>.Continuation] = [:]
    private var state: ConnectionState = .idle
    private var lastLogLines: [String] = []
    private var restartAttempts: Int = 0
    private var inFlightAttach: Task<URL?, Error>?
    /// Cached PID of the currently spawned child, written synchronously right
    /// after `Process.run()` succeeds so a teardown path that cannot `await`
    /// the actor (e.g. `applicationWillTerminate`) can still signal the child.
    nonisolated(unsafe) private var lastSpawnedPID: Int32?

    public init(settings: ShellSettings, resolver: EndpointResolver = EndpointResolver()) {
        self.settings = settings
        self.resolver = resolver
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

    // MARK: - Spawn

    private func startSpawn() async throws -> URL {
        if process != nil { throw DSHProcessError.alreadyRunning }

        // Both guards run before `spawn` and nowhere else. `attach` forks
        // nothing, so it cannot collide and is exempt.
        try Preflight.checkSpawn(settings: settings)

        state = .launching
        broadcast(.launching)

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
            Task { await self?.handleChildExit(status: status) }
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
        stdoutTask = Task.detached(priority: .utility) { [weak self] in
            await self?.drain(handle: outHandle, isErr: false)
        }
        stderrTask = Task.detached(priority: .utility) { [weak self] in
            await self?.drain(handle: errHandle, isErr: true)
        }

        // Wait for the authenticated URL line. The port is only ever logged,
        // never adopted: see `probePortLiveness`.
        let deadline = Date().addingTimeInterval(TimeInterval(settings.spawnTimeoutSeconds))
        var announcedListening = false
        while true {
            if Task.isCancelled {
                await terminateSpawnedChild()
                throw CancellationError()
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
                // The socket binds seconds before dsh's plugin Loader settles and
                // prints the URL. Telling the two apart is the difference between
                // "dsh is slow" and "dsh is broken" in the log — and it is the
                // only thing a port probe is good for.
                if !announcedListening, await probePortLiveness() {
                    announcedListening = true
                }
                if Date() >= deadline {
                    await terminateSpawnedChild()
                    throw DSHProcessError.timedOutWaitingForURL(settings.spawnTimeoutSeconds)
                }
                try? await Task.sleep(nanoseconds: UInt64(settings.pollIntervalSeconds * 1_000_000_000))
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
    private func probePortLiveness() async -> Bool {
        guard settings.preferredPort > 0, Preflight.isLoopback(settings.listenHost) else {
            return false
        }
        guard let process, process.isRunning else { return false }
        guard let url = URL(string: "http://\(settings.listenHost):\(settings.preferredPort)/") else {
            return false
        }
        let probe = HealthProbe()
        let result = await probe.probe(url: url, timeout: 1.0)
        if result.reachable {
            logger.info("port \(self.settings.preferredPort, privacy: .public) is listening (HTTP \(result.statusCode, privacy: .public)); still waiting for the authenticated URL line")
            return true
        }
        return false
    }

    /// Best-effort teardown of the just-spawned child when startup fails
    /// (timeout, cancellation, or a mid-start error). Prevents a dsh web that
    /// never reported its endpoint from lingering as an orphan.
    private func terminateSpawnedChild() async {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        lastSpawnedPID = nil
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
        }
        self.process = nil
    }

    /// Reads one byte at a time from a `FileHandle.AsyncBytes` and accumulates
    /// them into a `Data` buffer, splitting on `0x0A` (newline) and forwarding
    /// each line to the actor. Marked `nonisolated` so it can run inside a
    /// `Task.detached` without dragging the actor's executor.
    private nonisolated func drain(handle: FileHandle, isErr: Bool) async {
        var buffer = Data()
        func emit(_ line: String) {
            Task { [weak self] in
                guard let self else { return }
                if isErr {
                    await self.consumeStderr(line)
                } else {
                    await self.consumeStdout(line)
                }
            }
        }
        do {
            for try await byte in handle.bytes {
                if byte == 0x0A {
                    let line = String(data: buffer, encoding: .utf8) ?? ""
                    buffer.removeAll(keepingCapacity: true)
                    emit(line)
                } else {
                    buffer.append(byte)
                }
            }
            if !buffer.isEmpty, let last = String(data: buffer, encoding: .utf8) {
                emit(last)
            }
        } catch {
            // fd closed or read failed
        }
    }

    private func consumeStdout(_ line: String) {
        appendLog(line)
        broadcast(.stdoutLine(line))
        if case .ready = state { return }
        // Only stdout is a URL source. stderr carries dsh's `bili` proxy URL,
        // which is not the UI.
        if let url = resolver.resolveURL(in: line, expectedPort: settings.preferredPort) {
            noteEndpointResolved()
            state = .ready(url)
            broadcast(.endpointResolved(url))
        }
    }

    private func consumeStderr(_ line: String) {
        appendLog(line)
        broadcast(.stderrLine(line))
    }

    private func appendLog(_ line: String) {
        lastLogLines.append(line)
        if lastLogLines.count > 200 { lastLogLines.removeFirst(lastLogLines.count - 200) }
    }

    /// The child died. This is the single place that decides whether the shell
    /// tries again or gives up, and every outcome is broadcast — including the
    /// ones that used to be silent.
    private func handleChildExit(status: Int32) {
        lastSpawnedPID = nil
        appendLog("[exit] status=\(status)")
        broadcast(.childExited(status: status))
        if case .shuttingDown = state { return }

        if settings.autoRestartOnCrash, restartAttempts < Self.maxRestartAttempts {
            restartAttempts += 1
            // A real exponential ladder. The previous code incremented a counter
            // that was never reset and guarded on it being zero, so exactly one
            // restart ever happened, always after 2s, and both the cap and the
            // exponential shape were unreachable.
            let delay = min(Self.maxRestartDelay, pow(2.0, Double(restartAttempts)))
            broadcast(.autoRestartScheduled(after: delay))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                await self.attemptAutoRestart()
            }
            return
        }

        // Out of attempts. Say so, and say why — a window still showing the
        // last conversation over a dead server is the failure this exists to
        // prevent.
        let reason = status == 0
            ? "dsh exited normally while the window was still open."
            : "dsh exited with status \(status)"
            + " and the shell did not restart it (\(restartAttempts)/\(Self.maxRestartAttempts) attempts)."
        state = .failed(reason: reason)
        broadcast(.connectionLost(reason: reason))
    }

    /// A successful endpoint resets the ladder, so a dsh that crashes once an
    /// hour is not treated as a crash loop.
    private func noteEndpointResolved() {
        restartAttempts = 0
    }

    private func attemptAutoRestart() async {
        if case .shuttingDown = state { return }
        broadcast(.autoRestartAttempted)
        process = nil
        do {
            _ = try await startSpawn()
        } catch {
            let reason = "dsh could not be restarted: \(error.localizedDescription)"
            state = .failed(reason: reason)
            broadcast(.autoRestartAborted(reason: reason))
            broadcast(.connectionLost(reason: reason))
        }
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
            noteEndpointResolved()
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
        process = nil

        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
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
