import XCTest
@testable import DSHShellCore

final class DSHProcessManagerTests: XCTestCase {
    func testValidateBinaryRejectsMissingPath() {
        XCTAssertThrowsError(try DSHProcessManager.validateBinary("/no/such/path/dsh-xyz")) { error in
            guard case DSHProcessError.binaryNotFound = error else {
                return XCTFail("expected binaryNotFound, got \(error)")
            }
        }
    }

    func testBuildArgvMatchesExpectedShape() {
        var s = ShellSettings.default
        s.dshBinaryPath = "/opt/dsh"
        s.preferredPort = 5555
        s.listenHost = "127.0.0.1"
        s.trustedHosts = ["127.0.0.1", "::1"]
        let argv = DSHProcessManager.buildArgv(settings: s)
        XCTAssertEqual(argv, [
            "/opt/dsh", "web",
            "--no-open",
            "--host", "127.0.0.1",
            "--port", "5555",
            "--trusted-host", "127.0.0.1",
            "--trusted-host", "::1"
        ])
    }

    func testBuildArgvOmitsThePortFlagWhenTheOSPicksIt() {
        // `--port 0` was passed literally on the strength of an assumption that
        // dsh reads it as "ask the kernel". That was never verified against a
        // real dsh, and a literal 0 is ambiguous — it could equally mean "bind
        // port zero". Omitting the flag is the spelling that cannot be misread,
        // and it matches what `dsh web --help` documents.
        var s = ShellSettings.default
        s.dshBinaryPath = "/opt/dsh"
        s.preferredPort = 0
        let argv = DSHProcessManager.buildArgv(settings: s)
        XCTAssertFalse(argv.contains("--port"), "argv was \(argv)")
        XCTAssertFalse(argv.contains("0"), "a bare 0 must not reach dsh: \(argv)")
    }

    func testBuildArgvNeverInvokesAShell() {
        // Every element is passed as a literal argv entry; nothing is
        // concatenated into a command string, so a path containing shell
        // metacharacters cannot become an injection.
        var s = ShellSettings.default
        s.dshBinaryPath = "/opt/dsh; rm -rf /"
        s.trustedHosts = ["$(whoami)"]
        let argv = DSHProcessManager.buildArgv(settings: s)
        XCTAssertEqual(argv.first, "/opt/dsh; rm -rf /")
        XCTAssertTrue(argv.contains("$(whoami)"))
        XCTAssertFalse(argv.contains { $0.contains("&&") || $0.contains("|") })
    }

    func testSettingsRoundTrip() throws {
        let original = ShellSettings(
            dshBinaryPath: "/x/dsh",
            launchMode: .attach,
            listenHost: "127.0.0.1",
            preferredPort: 0,
            trustedHosts: ["a", "b"],
            pollIntervalSeconds: 1.25,
            spawnTimeoutSeconds: 30,
            autoRestartOnCrash: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShellSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Child environment

    func testChildEnvironmentStripsTheHarnessMarkers() {
        // The whole parent environment used to be copied, so an *enclosing*
        // harness session's DSH_* variables were handed to the child dsh. That
        // child would then believe it is inside a session, contend for the same
        // ports and session store, and the damage lands on the outer session.
        let saved = ProcessInfo.processInfo.environment["DSH_SESSION_ID"]
        setenv("DSH_SESSION_ID", "outer-session", 1)
        setenv("DSH_PROFILE", "web", 1)
        defer {
            if let saved { setenv("DSH_SESSION_ID", saved, 1) } else { unsetenv("DSH_SESSION_ID") }
            unsetenv("DSH_PROFILE")
        }

        let env = DSHProcessManager.childEnvironment(dshBinaryPath: "/opt/dsh")
        XCTAssertNil(env["DSH_SESSION_ID"])
        XCTAssertNil(env["DSH_PROFILE"])
    }

    func testChildEnvironmentPutsNodeOnThePath() {
        // Launching from Finder gives a minimal PATH, while dsh is a node script
        // with `#!/usr/bin/env node`. Without this the exec fails and the app
        // reports "Failed to spawn dsh".
        let env = DSHProcessManager.childEnvironment(dshBinaryPath: "/opt/homebrew/bin/dsh")
        guard let path = env["PATH"] else { return XCTFail("PATH missing from child env") }
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "PATH was \(path)")
        // The dsh binary's own directory comes first, so a sibling `node`
        // resolves to the interpreter that install expects.
        XCTAssertTrue(path.hasPrefix("/opt/homebrew/bin:"), "PATH was \(path)")
    }

    func testTheDefaultBinaryPathIsNeverSomeonesHomeDirectory() {
        // It used to be the literal `/Users/djx/.npm-global/bin/dsh`, so on any
        // other Mac a fresh install opened with "dsh binary not found".
        let resolved = ShellSettings.defaultBinaryPath()
        if resolved != "dsh" {
            XCTAssertTrue(resolved.hasPrefix("/"), "expected an absolute path, got \(resolved)")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved),
                          "discovered path is not executable: \(resolved)")
        }
    }
}