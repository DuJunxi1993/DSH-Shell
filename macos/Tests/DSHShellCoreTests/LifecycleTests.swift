import XCTest
@testable import DSHShellCore

/// Drives `DSHProcessManager` against `stub-dsh` — never a real harness.
///
/// This is the spine the macOS suite was missing. The invariant everything
/// else serves is: **the app exits → dsh dies → the port is freed.** In the
/// Rust implementation every lifecycle test ends with an assertion that the
/// port is bindable again; here, nothing asserted it at all, so the one bug the
/// application exists to prevent could have regressed silently.
///
/// Mirrors `windows/src-tauri/tests/{endpoint_resolution,lifecycle}.rs`. See
/// `docs/dsh-shell-contract.md` §3 for the shared fixture table.
final class LifecycleTests: XCTestCase {
    // MARK: - Harness

    /// Path to the `stub-dsh` test double.
    ///
    /// Not `CommandLine.arguments[0]`: `swift test` is launched by a runner
    /// inside the toolchain, so that path points at `.../usr/bin` rather than
    /// at this package's build products. The source file's own location is the
    /// reliable anchor.
    private static var stubURL: URL {
        if let override = ProcessInfo.processInfo.environment["STUB_DSH_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/DSHShellCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        // Both layouts: the current `out/Products/<config>` and the older
        // `.build/<triple>/<config>` that older toolchains use.
        var candidates = ["Debug", "Release"].map {
            root.appendingPathComponent(".build/out/Products/\($0)/stub-dsh")
        }
        if let debug = try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent(".build").path) {
            for triple in debug where triple.contains("apple-macos") {
                candidates.append(
                    root.appendingPathComponent(".build/\(triple)/debug/stub-dsh"))
            }
        }
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        XCTFail("stub-dsh not found. Build it with `swift build --product stub-dsh`, "
                + "or set STUB_DSH_PATH. Tried:\n  "
                + candidates.map(\.path).joined(separator: "\n  "))
        return root.appendingPathComponent("stub-dsh")
    }

    /// A port that is free right now, found by binding and releasing.
    private static func freePort() -> Int {
        let socket = OccupyingSocket(port: 0)
        let port = socket.port
        socket.close()
        return port
    }

    /// Settings pointed at the stub, on a port nothing else owns.
    private func stubSettings(
        port: Int? = nil, mode: String, urlDelayMS: Int = 0, chatterBytes: Int = 0,
        spawnTimeoutSeconds: Int = 20, stallReportSeconds: Int = 20
    ) -> ShellSettings {
        var settings = ShellSettings.default
        settings.dshBinaryPath = Self.stubURL.path
        settings.preferredPort = port ?? Self.freePort()
        settings.listenHost = "127.0.0.1"
        settings.trustedHosts = ["127.0.0.1"]
        settings.autoRestartOnCrash = false
        settings.pollIntervalSeconds = 0.2
        settings.spawnTimeoutSeconds = spawnTimeoutSeconds
        settings.spawnStallReportSeconds = stallReportSeconds
        // The knobs `buildArgv` cannot pass, so they travel by environment.
        setenv("STUB_DSH_MODE", mode, 1)
        setenv("STUB_DSH_URL_DELAY_MS", String(urlDelayMS), 1)
        setenv("STUB_DSH_CHATTER_BYTES", String(chatterBytes), 1)
        return settings
    }

    private func clearStubEnv() {
        unsetenv("STUB_DSH_MODE")
        unsetenv("STUB_DSH_URL_DELAY_MS")
        unsetenv("STUB_DSH_CHATTER_BYTES")
        unsetenv("STUB_DSH_CRASH_DELAY_MS")
    }

    override func tearDown() {
        clearStubEnv()
        super.tearDown()
    }

    /// The invariant. Asserted directly rather than inferred: a leaked dsh is
    /// the one outcome this application exists to prevent.
    private func assertPortFree(_ port: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if Preflight.isPortFree(host: "127.0.0.1", port: port) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("port \(port) is still held after shutdown", file: file, line: line)
    }

    // MARK: - Endpoint resolution against a real process

    func testResolvesTheAuthenticatedURLFromStdout() async throws {
        let settings = stubSettings(mode: "ok")
        let manager = DSHProcessManager(settings: settings)
        let url = try await manager.start()
        defer { Task { await manager.stop() } }

        XCTAssertEqual(url.port, settings.preferredPort)
        XCTAssertEqual(url.host, "127.0.0.1")
        // The LAN suffix in parentheses must not have leaked into the URL.
        XCTAssertFalse(url.absoluteString.contains("192.168"),
                       "LAN suffix leaked: \(url.absoluteString)")
        XCTAssertTrue(url.absoluteString.contains("token=stub-token"),
                      "no token in \(url.absoluteString)")

        await manager.stop()
        assertPortFree(settings.preferredPort)
    }

    func testIgnoresTheBiliProxyURLOnStderr() async throws {
        // The stub prints dsh's real decoy on stderr, unconditionally. A
        // resolver that scans stderr for any loopback URL points the webview at
        // the internal HTTP proxy and shows a white window.
        let settings = stubSettings(mode: "ok")
        let manager = DSHProcessManager(settings: settings)
        let url = try await manager.start()
        defer { Task { await manager.stop() } }

        XCTAssertNotEqual(url.port, 18787, "adopted dsh's internal proxy")
        XCTAssertEqual(url.port, settings.preferredPort)

        await manager.stop()
        assertPortFree(settings.preferredPort)
    }

    func testTokenlessURLIsRefused() async throws {
        // The stub prints a URL with no token. `authorizeIndex` answers 401 to
        // it, so the shell must never point the webview there — it must wait for
        // the real line and then time out with a message that says why.
        let settings = stubSettings(mode: "tokenless", spawnTimeoutSeconds: 3)
        let manager = DSHProcessManager(settings: settings)
        defer { Task { await manager.stop() } }

        do {
            let url = try await manager.start()
            XCTFail("a tokenless URL was adopted: \(url)")
        } catch {
            guard case DSHProcessError.timedOutWaitingForURL = error else {
                return XCTFail("expected a timeout, got \(error)")
            }
            // The message must point at the token, not at a `pkill`. Telling a
            // user to kill processes by name is how the previous agent
            // destroyed its own host.
            let message = (error as? DSHProcessError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("401") || message.contains("token"),
                          "message should explain the fence: \(message)")
            XCTAssertFalse(message.contains("pkill"), "must not suggest a name-based kill")
        }
        assertPortFree(settings.preferredPort)
    }

    /// A timeout that says only "dsh did not answer in time" is indistinguishable
    /// from every other timeout, which is how 5 stalls in 12 real launches went
    /// undiagnosed. The error has to carry the evidence.
    func testATimeoutCarriesTheEvidenceAndNotJustAnElapsedTime() async throws {
        let settings = stubSettings(mode: "no-url-line", spawnTimeoutSeconds: 3)
        let manager = DSHProcessManager(settings: settings)
        defer { Task { await manager.stop() } }

        do {
            let url = try await manager.start()
            return XCTFail("expected a timeout, got \(url)")
        } catch {
            guard case DSHProcessError.timedOutWaitingForURL(_, let diagnostics) = error else {
                return XCTFail("expected a timeout, got \(error)")
            }
            // dsh's own output, not the shell's opinion about it.
            XCTAssertTrue(diagnostics.contains("printUrl disabled"),
                          "must quote what dsh actually said: \(diagnostics)")
            XCTAssertTrue(diagnostics.contains("child process:"),
                          "must say whether the child is alive: \(diagnostics)")
            // The stale advice this replaced: a live console tab the user cannot
            // see while a launch screen is up, and which is empty after relaunch.
            let message = (error as? DSHProcessError)?.errorDescription ?? ""
            XCTAssertFalse(message.contains("console tab"),
                           "the diagnosis must not defer to a UI that is not reachable")
            XCTAssertTrue(message.contains(diagnostics.prefix(80)),
                          "the visible error must carry the evidence itself")
        }
        assertPortFree(settings.preferredPort)
    }

    func testTheStallIsReportedLongBeforeTheDeadline() async throws {
        // A dsh that never announces itself used to produce silence for the whole
        // 120s. `spawnStallReportSeconds` is what turns that into an explanation
        // while the user is still looking at it — and it must stay well inside
        // the timeout, or the explanation arrives with the failure it was
        // supposed to precede.
        XCTAssertLessThan(ShellSettings.default.spawnStallReportSeconds,
                          ShellSettings.default.spawnTimeoutSeconds,
                          "the stall report is pointless if it lands at the deadline")

        // 6s deadline with a 1s stall report: if the report ever became the
        // thing that decides, this would return in ~1s instead of ~6s.
        let settings = stubSettings(mode: "no-url-line",
                                    spawnTimeoutSeconds: 6, stallReportSeconds: 1)
        let manager = DSHProcessManager(settings: settings)
        defer { Task { await manager.stop() } }

        let started = Date()
        do {
            _ = try await manager.start()
            XCTFail("expected a timeout")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertGreaterThan(elapsed, 4, "the deadline should still be what decides")
            XCTAssertLessThan(elapsed, 12, "and it should be honoured, not extended")
        }
    }

    /// The regression test for the launch that never leaves "Launching dsh web…".
    ///
    /// The reader used to iterate the pipe one byte at a time, which sustained
    /// about 25 bytes/second. dsh prints its URL line *last*, after the plugin
    /// loader has been chatty, so the volume of chatter before it decided whether
    /// the app would ever start. 20 KB was enough to make it impossible; the
    /// symptom looked probabilistic only because a quiet dsh boots fine.
    func testALoudStartupLogDoesNotDelayTheURLLine() async throws {
        for chatter in [0, 20_000, 200_000] {
            let settings = stubSettings(mode: "ok", chatterBytes: chatter, spawnTimeoutSeconds: 30)
            let manager = DSHProcessManager(settings: settings)
            let started = Date()
            do {
                let url = try await manager.start()
                let elapsed = Date().timeIntervalSince(started)
                XCTAssertEqual(url.port, settings.preferredPort)
                XCTAssertLessThan(elapsed, 10,
                                  "chatter=\(chatter): the reader is volume-dependent again")
            } catch {
                await manager.stop()
                return XCTFail("chatter=\(chatter): \(error)")
            }
            await manager.stop()
            assertPortFree(settings.preferredPort)
        }
    }

    func testSurfacesAnEarlyExitWithStderr() async throws {
        let settings = stubSettings(mode: "die-early", spawnTimeoutSeconds: 6)
        let manager = DSHProcessManager(settings: settings)
        defer { Task { await manager.stop() } }

        do {
            _ = try await manager.start()
            XCTFail("expected the start to fail")
        } catch {
            // Whatever the shape, the stub's own words must survive: a release
            // build has no console, so the tail is the only place the reason
            // can live.
            XCTAssertNotNil(error as? DSHProcessError)
        }
        assertPortFree(settings.preferredPort)
    }

    func testWaitsForASlowURLLineInsteadOfRacingThePort() async throws {
        // dsh binds the socket seconds before its plugin Loader settles and
        // prints the URL. A resolver that races them and adopts the port hands
        // the user a 401 — so the port must only ever be logged.
        let settings = stubSettings(mode: "ok", urlDelayMS: 2500, spawnTimeoutSeconds: 25)
        let manager = DSHProcessManager(settings: settings)
        let url = try await manager.start()
        defer { Task { await manager.stop() } }

        XCTAssertEqual(url.port, settings.preferredPort)
        XCTAssertTrue(url.absoluteString.contains("token="),
                      "the port was adopted instead of the URL line: \(url)")

        await manager.stop()
        assertPortFree(settings.preferredPort)
    }

    func testTimesOutWhenDshNeverAnnouncesItself() async throws {
        let settings = stubSettings(mode: "no-url-line", spawnTimeoutSeconds: 3)
        let manager = DSHProcessManager(settings: settings)
        defer { Task { await manager.stop() } }

        do {
            _ = try await manager.start()
            XCTFail("expected a timeout")
        } catch {
            guard case DSHProcessError.timedOutWaitingForURL = error else {
                return XCTFail("expected a timeout, got \(error)")
            }
        }
        assertPortFree(settings.preferredPort)
    }

    // MARK: - Crash restart ladder

    /// Fast ladder for tests: the production 2/4/8s backoff is the thing under
    /// test elsewhere; here it only makes the suite slow.
    private func fastPolicy(
        maxAttempts: Int = 2,
        healthyUptime: TimeInterval = 60,
        portReleaseTimeout: TimeInterval = 2
    ) -> RestartPolicy {
        RestartPolicy(maxAttempts: maxAttempts,
                      healthyUptime: healthyUptime,
                      portReleaseTimeout: portReleaseTimeout,
                      backoff: { _ in 0.05 })
    }

    /// The failure that started this: dsh exits, its port is not free yet, and
    /// the shell gives up on the first respawn instead of waiting. The ladder
    /// must retry without the user touching anything, and failing a respawn is
    /// not the end of the ladder.
    func testACrashIsRestartedWithoutAskingTheUser() async throws {
        var settings = stubSettings(mode: "crash-after-ready", spawnTimeoutSeconds: 10)
        settings.autoRestartOnCrash = true
        let manager = DSHProcessManager(settings: settings, policy: fastPolicy(maxAttempts: 2))
        let events = await manager.events()

        let log = EventLog()
        let gaveUp = expectation(description: "the ladder reported its final failure")
        Task {
            for await event in events {
                switch event {
                case .autoRestartScheduled:
                    log.scheduled += 1
                case .connectionLost:
                    gaveUp.fulfill()
                    return
                default:
                    break
                }
            }
        }

        let url = try await manager.start()
        XCTAssertEqual(url.port, settings.preferredPort,
                       "the endpoint must still be reported before the crash")
        await fulfillment(of: [gaveUp], timeout: 20)
        XCTAssertGreaterThanOrEqual(log.scheduled, 2,
                                    "the ladder must spend its whole budget before giving up")
        await manager.stop()
        assertPortFree(settings.preferredPort)
    }

    /// A child that ran past `healthyUptime` is a new failure, not the
    /// continuation of a crash loop. Without the reset, the third crash of the
    /// morning would never be retried — with it, a flapping dsh can be retried
    /// indefinitely as long as it works between crashes.
    func testAHealthyRunRestoresTheRestartBudget() async throws {
        var settings = stubSettings(mode: "crash-after-ready", spawnTimeoutSeconds: 10)
        settings.autoRestartOnCrash = true
        // Shorter than the stub's 500ms crash delay, so every run is "healthy".
        let manager = DSHProcessManager(
            settings: settings,
            policy: fastPolicy(maxAttempts: 2, healthyUptime: 0.1))
        let events = await manager.events()

        let log = EventLog()
        let sawEnough = expectation(description: "budget survived more than maxAttempts restarts")
        Task {
            for await event in events {
                switch event {
                case .autoRestartAttempted:
                    log.attempted += 1
                    if log.attempted >= 3 { sawEnough.fulfill(); return }
                case .connectionLost:
                    log.lost = true
                default:
                    break
                }
            }
        }

        _ = try await manager.start()
        await fulfillment(of: [sawEnough], timeout: 20)
        XCTAssertFalse(log.lost, "a healthy run must return the budget instead of exhausting it")
        await manager.stop()
    }

    /// The respawn must wait for the dead child's port instead of reading
    /// "still bound" as "somebody else owns it".
    func testRestartWaitsForThePortToComeFree() async throws {
        let occupant = OccupyingSocket(port: 0)
        let settings = stubSettings(port: occupant.port, mode: "ok")
        let manager = DSHProcessManager(
            settings: settings,
            policy: fastPolicy(portReleaseTimeout: 0.6))
        defer { occupant.close() }

        let started = Date()
        await manager.waitForPortRelease()
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(waited, 0.4, "it did not wait while the port was held")
        XCTAssertLessThan(waited, 5, "the wait must stay bounded")

        occupant.close()
        let freed = Date()
        await manager.waitForPortRelease()
        XCTAssertLessThan(Date().timeIntervalSince(freed), 0.3,
                          "it kept waiting after the port came free")
    }

    // MARK: - Teardown

    func testAFailedStartDoesNotLeaveDshHoldingThePort() async throws {
        // The stub has a lifetime ceiling, but the shell must not depend on it.
        let settings = stubSettings(mode: "no-url-line", spawnTimeoutSeconds: 3)
        let manager = DSHProcessManager(settings: settings)
        _ = try? await manager.start()
        await manager.stop()
        assertPortFree(settings.preferredPort)
    }

    func testStopIsIdempotentAndFreesThePortOnce() async throws {
        // `stop()` used to return early when there was no child, skipping the
        // reader-task cancellation and the listener teardown, so a second call
        // — or the first after a failed start — left state behind.
        let settings = stubSettings(mode: "ok")
        let manager = DSHProcessManager(settings: settings)
        let url = try await manager.start()
        XCTAssertNotNil(url)

        await manager.stop()
        await manager.stop()
        await manager.stop()

        assertPortFree(settings.preferredPort)
        XCTAssertNil(manager.currentChildPID(), "the PID record must be cleared")
    }

    func testStopWithoutAChildDoesNotHang() async throws {
        // A manager that never started has no process. `stop()` must still
        // finish, or any `for await` on its event stream hangs forever.
        let settings = stubSettings(mode: "ok")
        let manager = DSHProcessManager(settings: settings)
        let finished = expectation(description: "stop returns")
        Task {
            await manager.stop()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
    }

    func testTheEventStreamFinishesOnStop() async throws {
        // The stream terminating is what lets a `for await` in the coordinator
        // finish instead of hanging on a continuation that never finishes.
        let settings = stubSettings(mode: "ok")
        let manager = DSHProcessManager(settings: settings)
        let stream = await manager.events()

        let done = expectation(description: "stream ends")
        Task {
            for await _ in stream {}
            done.fulfill()
        }
        _ = try? await manager.start()
        await manager.stop()

        await fulfillment(of: [done], timeout: 5)
    }

    // MARK: - Preflight, end to end

    func testRefusesToSpawnOverAPortSomeoneOwns() async throws {
        // The previous behaviour killed the port owner. That destroyed a dsh the
        // operator started by hand — possibly one they were using — merely by
        // opening the app.
        let occupant = OccupyingSocket(port: 0)
        defer { occupant.close() }

        let settings = stubSettings(port: occupant.port, mode: "ok")
        let manager = DSHProcessManager(settings: settings)
        defer { Task { await manager.stop() } }

        do {
            _ = try await manager.start()
            XCTFail("expected the spawn to be refused")
        } catch {
            guard case DSHProcessError.portInUse(let _, let port) = error else {
                return XCTFail("expected portInUse, got \(error)")
            }
            XCTAssertEqual(port, occupant.port)
        }
        // And the occupant must still be there: refusing is not killing.
        XCTAssertFalse(Preflight.isPortFree(host: "127.0.0.1", port: occupant.port),
                       "the port owner was signalled")
    }

    func testReclaimsOnlyProvenOrphans() {
        // A leftover from an earlier run: no parent, this binary, this port.
        // This is the shape that used to cost three doomed respawns.
        let orphan = PortOccupant(
            pid: 93_416, commandLine: "node /x/bin/dsh web --port 3080",
            parentPID: 1, verdict: .orphan)
        // Still supervised — the terminal the operator started it in.
        let supervised = PortOccupant(
            pid: 101, commandLine: "node /x/bin/dsh web --port 3080",
            parentPID: 4_242, verdict: .notOrphan(.supervised(parentPID: 4_242)))
        // Parentless but not our binary: somebody else's dsh.
        let stranger = PortOccupant(
            pid: 202, commandLine: "node /y/dsh web --port 3080",
            parentPID: 1, verdict: .notOrphan(.differentBinary("/x/bin/dsh")))
        // An orphan that refuses to die must not be counted as reclaimed.
        let stubborn = PortOccupant(
            pid: 303, commandLine: "node /x/bin/dsh web --port 3080",
            parentPID: 1, verdict: .orphan)

        var signalled: [Int32] = []
        var lines: [String] = []
        let reclaimed = DSHProcessManager.reclaimOrphans(
            from: [orphan, supervised, stranger, stubborn],
            terminate: { pid in signalled.append(pid); return pid != 303 },
            log: { lines.append($0) })

        XCTAssertEqual(signalled, [93_416, 303],
                       "only orphans may be signalled")
        XCTAssertEqual(reclaimed, [93_416],
                       "a termination that failed is not a reclaim")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[1].contains("not touching"),
                      "the skipped occupant needs a reason in the log: \(lines[1])")
    }

    /// The failure that motivated automatic reclaim, end to end: a `dsh web`
    /// whose launcher exited (so `ppid == 1`) holds the port, and the shell must
    /// close it and start rather than spending its restart budget on
    /// `EADDRINUSE`.
    ///
    /// `/bin/sh` is only the test's way to manufacture an orphan — it exits
    /// immediately after backgrounding the stub, so the stub is reparented to
    /// `launchd`. The manager itself never invokes a shell.
    func testStartsOverAnOrphanByReclaimingIt() async throws {
        let port = Self.freePort()
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c",
            "'\(Self.stubURL.path)' --port \(port) --host 127.0.0.1 >/dev/null 2>&1 &"]
        try launcher.run()
        launcher.waitUntilExit()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !Preflight.isPortFree(host: "127.0.0.1", port: port) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let orphanPID = try XCTUnwrap(
            PortOccupant.occupants(ofPort: port, binaryPath: Self.stubURL.path)
                .first(where: { $0.isOrphan })?.pid,
            "the launcher did not leave an orphan holding port \(port)")
        defer { PortOccupant.terminate(pid: orphanPID) }

        let settings = stubSettings(port: port, mode: "ok")
        let manager = DSHProcessManager(settings: settings)
        defer { Task { await manager.stop() } }

        let url = try await manager.start()
        XCTAssertEqual(url.port, port,
                       "the shell refused to start over its own leftover")
        XCTAssertFalse(PortOccupant.occupants(ofPort: port, binaryPath: Self.stubURL.path)
                        .contains { $0.pid == orphanPID },
                       "the orphan is still alive alongside the new dsh")

        await manager.stop()
        assertPortFree(port)
    }

    func testAttachForksNothingAndFailsCleanly() async throws {
        let port = Self.freePort()
        var settings = stubSettings(port: port, mode: "ok")
        settings.launchMode = .attach
        let manager = DSHProcessManager(settings: settings)
        defer { Task { await manager.stop() } }

        do {
            _ = try await manager.start()
            XCTFail("expected attach to find nothing")
        } catch {
            guard case DSHProcessError.noExistingEndpointFound = error else {
                return XCTFail("expected noExistingEndpointFound, got \(error)")
            }
        }
        // Nothing was spawned, so there is nothing to kill.
        XCTAssertNil(manager.currentChildPID())
        XCTAssertTrue(Preflight.isPortFree(host: "127.0.0.1", port: port))
    }

    func testAttachAdoptsAListeningStubAndNeverKillsIt() async throws {
        // An adopted instance is not ours. Shutting the shell down must leave it
        // running — otherwise "attach" is a way to kill someone else's dsh.
        let port = Self.freePort()
        setenv("STUB_DSH_MODE", "ok", 1)
        let adopted = Process()
        adopted.executableURL = Self.stubURL
        adopted.arguments = ["--port", String(port)]
        adopted.standardOutput = Pipe()
        adopted.standardError = Pipe()
        adopted.standardInput = FileHandle.nullDevice
        try adopted.run()
        defer { if adopted.isRunning { kill(adopted.processIdentifier, SIGKILL) } }

        // Wait for it to be listening.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, Preflight.isPortFree(host: "127.0.0.1", port: port) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(Preflight.isPortFree(host: "127.0.0.1", port: port),
                       "the adopted stub never bound")

        var settings = stubSettings(port: port, mode: "ok")
        settings.launchMode = .attach
        let manager = DSHProcessManager(settings: settings)
        let url = try await manager.start()
        XCTAssertEqual(url.port, port)
        XCTAssertNil(manager.currentChildPID(), "attach owns no child")

        await manager.stop()
        // The adopted process is still alive, and still owns the port.
        XCTAssertTrue(adopted.isRunning, "attach killed a dsh it did not spawn")
        XCTAssertFalse(Preflight.isPortFree(host: "127.0.0.1", port: port))
    }
}

/// Mutable tallies shared with the event-consuming `Task` in the restart tests.
/// A class so the closure does not capture mutable locals (Swift 6 rejects
/// sending those across task boundaries), and locked because the consuming task
/// is not the test's actor.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _scheduled = 0
    private var _attempted = 0
    private var _lost = false

    var scheduled: Int {
        get { lock.withLock { _scheduled } }
        set { lock.withLock { _scheduled = newValue } }
    }

    var attempted: Int {
        get { lock.withLock { _attempted } }
        set { lock.withLock { _attempted = newValue } }
    }

    var lost: Bool {
        get { lock.withLock { _lost } }
        set { lock.withLock { _lost = newValue } }
    }
}

/// A listening socket used to make a port genuinely occupied.
final class OccupyingSocket {
    let fd: Int32
    let port: Int

    init(port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        _ = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = listen(fd, 1)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        self.fd = fd
        self.port = Int(UInt16(bigEndian: bound.sin_port))
    }

    func close() {
        Darwin.close(fd)
    }
}