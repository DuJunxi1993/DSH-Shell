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

    func testBuildArgvIncludesPortZeroForOSAssignment() {
        var s = ShellSettings.default
        s.dshBinaryPath = "/opt/dsh"
        s.preferredPort = 0
        let argv = DSHProcessManager.buildArgv(settings: s)
        // We pass `--port 0` through to dsh so the OS picks the port. dsh's
        // webserver treats port=0 as "ask the kernel".
        XCTAssertTrue(argv.contains("--port"))
        if let i = argv.firstIndex(of: "--port") {
            XCTAssertEqual(argv[i + 1], "0")
        } else {
            XCTFail("expected --port 0 in argv")
        }
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
}
