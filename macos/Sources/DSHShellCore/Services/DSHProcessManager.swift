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
            return "dsh web did not print its URL line within \(seconds)s. Check for a stale `dsh web` process (`pkill -f 'dsh web'`) and try again."
        case .noExistingEndpointFound:
            return "No existing dsh web instance was found on loopback ports."
        case .childExitedUnexpectedly(let code, let lines):
            let tail = lines.suffix(5).joined(separator: "\n")
            return "dsh exited with status \(code). Last log:\n\(tail)"
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
}

/// Owns the `dsh web` child process. Never invokes a shell, so user input
/// cannot become argv injection. Implemented as an actor so all state mutation
/// happens under Swift's structured concurrency isolation rules.
public actor DSHProcessManager {
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
        state = .launching
        broadcast(.launching)

        // An orphaned `dsh web` from a previous session may still hold the
        // fixed preferred port. Reclaim it (only if it truly serves the dsh
        // SPA) so the fresh child can bind.
        await Self.reclaimPort(host: settings.listenHost, port: settings.preferredPort)

        let argv = Self.buildArgv(settings: settings)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.dshBinaryPath)
        process.arguments = Array(argv.dropFirst())
        process.environment = Self.childEnvironment(dshBinaryPath: settings.dshBinaryPath)

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

        // Wait for endpoint resolution with a per-instance deadline.
        let deadline = Date().addingTimeInterval(TimeInterval(settings.spawnTimeoutSeconds))
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
                // The URL line can be late by 30s+ (dsh's own startup loader
                // gates it) while the HTTP server is already up. With a fixed
                // preferred port we race the URL line against a health probe
                // of the known port and adopt whichever confirms first, so a
                // slow loader never makes the user wait.
                if Date() >= deadline {
                    if let url = await adoptByProbe() {
                        return url
                    }
                    await terminateSpawnedChild()
                    throw DSHProcessError.timedOutWaitingForURL(settings.spawnTimeoutSeconds)
                }
                if let url = await probeFixedPort() {
                    return url
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// One-shot health probe of the fixed preferred port. Returns the URL
    /// when the endpoint already serves the dsh SPA; nil when not applicable
    /// or not yet up.
    private func probeFixedPort() async -> URL? {
        guard settings.preferredPort > 0,
              ["127.0.0.1", "localhost"].contains(settings.listenHost) else {
            return nil
        }
        guard let process, process.isRunning else { return nil }
        guard let url = URL(string: "http://\(settings.listenHost):\(settings.preferredPort)/") else { return nil }
        let probe = HealthProbe()
        if await probe.probe(url: url).isAdoptable {
            logger.debug("adopted endpoint by probe (URL line not yet emitted): \(url.absoluteString, privacy: .public)")
            state = .ready(url)
            broadcast(.endpointResolved(url))
            return url
        }
        return nil
    }

    /// When the child printed no URL line but we know its expected port, wait
    /// for the HTTP endpoint to come up and adopt it. `dsh web` takes 1-60s+
    /// to settle depending on startup work; the probe tolerates that latency
    /// while the URL-line parse alone would give up.
    private func adoptByProbe() async -> URL? {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let url = await probeFixedPort() {
                return url
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
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
        if let url = resolver.resolveURL(in: line) {
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

    private func handleChildExit(status: Int32) {
        lastSpawnedPID = nil
        appendLog("[exit] status=\(status)")
        broadcast(.childExited(status: status))
        if case .shuttingDown = state { return }
        if settings.autoRestartOnCrash && restartAttempts == 0 {
            restartAttempts += 1
            let delay: TimeInterval = min(30, pow(2.0, Double(restartAttempts)))
            broadcast(.autoRestartScheduled(after: delay))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                await self.attemptAutoRestart()
            }
        } else {
            state = .failed(reason: "Child exited with status \(status).")
        }
    }

    private func attemptAutoRestart() async {
        broadcast(.autoRestartAttempted)
        process = nil
        do {
            _ = try await startSpawn()
        } catch {
            state = .failed(reason: "Auto-restart failed: \(error.localizedDescription)")
            broadcast(.autoRestartAborted(reason: error.localizedDescription))
        }
    }

    // MARK: - Attach

    private func startAttach() async throws -> URL {
        let probe = AttachProbe()
        inFlightAttach?.cancel()
        let task = Task<URL?, Error> { await probe.findExisting() }
        inFlightAttach = task
        state = .connecting(host: "127.0.0.1", port: 0)
        do {
            guard let url = try await task.value else {
                state = .failed(reason: "No dsh instance found on loopback ports.")
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
        guard let process else { return }
        let pid = process.processIdentifier
        lastSpawnedPID = nil
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
        }
        stdoutTask?.cancel()
        stderrTask?.cancel()
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
        if settings.preferredPort >= 0 {
            argv.append(contentsOf: ["--port", String(settings.preferredPort)])
        }
        for host in settings.trustedHosts {
            argv.append(contentsOf: ["--trusted-host", host])
        }
        return argv
    }

    /// Kills whatever process listens on `port` when it serves the dsh SPA.
    /// This is the orphan reaper: `dsh web` spawned by a previous app session
    /// survives `pkill`/crashes (SIGTERM does not run our cleanup), and with a
    /// fixed preferred port a leftover instance would make the next spawn die
    /// with EADDRINUSE. We only touch listeners that pass the dsh probe, so a
    /// user service squatting on the same port is left alone.
    static func reclaimPort(host: String, port: Int) async {
        guard port > 0, ["127.0.0.1", "localhost"].contains(host) else { return }
        guard let url = URL(string: "http://\(host):\(port)/") else { return }
        let probe = HealthProbe()
        guard await probe.probe(url: url, timeout: 0.8).isAdoptable else { return }

        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = Pipe()
        do {
            try lsof.run()
        } catch {
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        for raw in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            guard let pid = Int32(raw) else { continue }
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, kill(pid, 0) == 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// PATH for the child process. Launching the app from Finder gives the
    /// process a minimal PATH (no Homebrew or npm locations), while `dsh` is a
    /// node script whose shebang is `#!/usr/bin/env node`; without `node` on
    /// the PATH the exec fails and the app reports "Failed to spawn dsh".
    /// Rebuild a sane PATH from common node install locations plus the
    /// app's own PATH.
    static func childEnvironment(dshBinaryPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
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
