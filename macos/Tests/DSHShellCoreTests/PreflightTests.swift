import XCTest
@testable import DSHShellCore

/// Mirrors `windows/src-tauri/src/preflight.rs` and its tests. See
/// `docs/dsh-shell-contract.md` §4.
final class PreflightTests: XCTestCase {
    // MARK: - Nested session

    func testACleanEnvironmentIsNotNested() {
        XCTAssertFalse(Preflight.isNestedSession(environment: ["PATH": "/usr/bin"]))
    }

    func testOneAmbiguousMarkerIsNotProof() {
        // A user may legitimately have exported DSH_PROFILE in a normal
        // terminal, so a lone one is not enough to refuse.
        XCTAssertFalse(Preflight.isNestedSession(environment: ["DSH_PROFILE": "web"]))
        XCTAssertFalse(Preflight.isNestedSession(environment: ["DSH_PROFILE_DIR": "/x"]))
        XCTAssertFalse(Preflight.isNestedSession(environment: ["DSH_WEB_URL": "http://127.0.0.1:3080/"]))
    }

    func testASessionIdIsDecisiveOnItsOwn() {
        XCTAssertTrue(Preflight.isNestedSession(environment: ["DSH_SESSION_ID": "s-1"]))
    }

    func testTwoMarkersAreDecisive() {
        XCTAssertTrue(Preflight.isNestedSession(
            environment: ["DSH_PROFILE": "web", "DSH_WEB_URL": "http://127.0.0.1:3080/"]))
    }

    func testAnEmptyMarkerStillCounts() {
        // dsh injects the snapshot with whatever values it has; the *presence*
        // of the variable is the signal, not its contents.
        XCTAssertTrue(Preflight.isNestedSession(environment: ["DSH_SESSION_ID": ""]))
    }

    func testANestedSessionReportsWhichMarkersWereFound() {
        let vars = Preflight.nestedSessionMarkers(environment: [
            "DSH_SESSION_ID": "s-1", "PATH": "/usr/bin", "DSH_WEB_URL": "http://x/",
        ])
        XCTAssertEqual(vars, ["DSH_SESSION_ID", "DSH_WEB_URL"])
    }

    func testCheckNestingThrowsWithTheMarkers() {
        XCTAssertThrowsError(
            try Preflight.checkNesting(environment: ["DSH_SESSION_ID": "s-1"])
        ) { error in
            guard case DSHProcessError.nestedSession(let vars)? =
                error as? DSHProcessError else {
                return XCTFail("expected nestedSession, got \(error)")
            }
            XCTAssertEqual(vars, ["DSH_SESSION_ID"])
        }
    }

    func testCheckNestingPassesACleanEnvironment() {
        XCTAssertNoThrow(try Preflight.checkNesting(environment: [:]))
    }

    // MARK: - Port ownership

    func testAFreePortIsReportedAsFree() {
        // Bind an ephemeral port, release it, and ask again. SO_REUSEADDR is
        // set on both sides, so the release is immediate.
        let probe = Socket(port: 0)
        let port = probe.port
        probe.close()
        XCTAssertTrue(Preflight.isPortFree(host: "127.0.0.1", port: port))
    }

    func testABoundPortIsReportedAsInUse() {
        // Tested by binding, not by scraping netstat, so it observes what dsh's
        // own bind would observe.
        let probe = Socket(port: 0)
        defer { probe.close() }
        XCTAssertFalse(Preflight.isPortFree(host: "127.0.0.1", port: probe.port))
    }

    func testPortZeroNeverCollides() {
        // 0 means the OS assigns a port, so there is nothing to collide with.
        XCTAssertNoThrow(try Preflight.checkPortOwnership(host: "127.0.0.1", port: 0))
    }

    func testPortOwnershipRefusesAndNamesAttach() {
        let probe = Socket(port: 0)
        defer { probe.close() }
        XCTAssertThrowsError(
            try Preflight.checkPortOwnership(host: "127.0.0.1", port: probe.port)
        ) { error in
            guard case DSHProcessError.portInUse(let host, let port)? =
                error as? DSHProcessError else {
                return XCTFail("expected portInUse, got \(error)")
            }
            XCTAssertEqual(host, "127.0.0.1")
            XCTAssertEqual(port, probe.port)
            // The message has to name the alternative, because refusing without
            // a next step is how a user ends up killing dsh by hand.
            let message = (error as? DSHProcessError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("attach"), "message should name attach: \(message)")
            // And it must promise not to have killed anything.
            XCTAssertTrue(message.contains("never kills"), "message should be explicit: \(message)")
        }
    }

    func testANonLoopbackHostIsRefused() {
        // dsh binds loopback only. Refusing here beats discovering it as a bind
        // error much later.
        XCTAssertThrowsError(try Preflight.checkPortOwnership(host: "0.0.0.0", port: 3080))
        XCTAssertFalse(Preflight.isLoopback("0.0.0.0"))
        XCTAssertTrue(Preflight.isLoopback("127.0.0.1"))
        XCTAssertTrue(Preflight.isLoopback("LOCALHOST"))
    }

    // MARK: - Ordering

    func testCheckSpawnReportsNestingFirst() {
        // Nesting is the more dangerous of the two: the damage lands on the
        // outer session, so it must be reported before the port, which is the
        // more likely but less harmful of the two.
        var settings = ShellSettings.default
        settings.preferredPort = 0
        let listener = Socket(port: 0)
        defer { listener.close() }
        settings.preferredPort = listener.port  // also occupied, so both guards fire

        XCTAssertThrowsError(
            try Preflight.checkSpawn(
                settings: settings, environment: ["DSH_SESSION_ID": "s-1"])
        ) { error in
            guard case DSHProcessError.nestedSession? = error as? DSHProcessError else {
                return XCTFail("expected nestedSession first, got \(error)")
            }
        }
    }

    func testASpawnCheckWithNothingWrongPasses() {
        var settings = ShellSettings.default
        settings.preferredPort = 0  // OS-assigned, nothing to collide with
        XCTAssertNoThrow(try Preflight.checkSpawn(settings: settings, environment: [:]))
    }

    func testASpawnCheckOnACleanPortPasses() {
        let candidate = Socket(port: 0)
        let port = candidate.port
        candidate.close()
        var settings = ShellSettings.default
        settings.preferredPort = port
        XCTAssertNoThrow(try Preflight.checkSpawn(settings: settings, environment: [:]))
    }
}

/// A listening socket used to make a port genuinely occupied.
private final class Socket {
    let fd: Int32
    let port: Int

    init(port: Int) {
        // A local, not `self.fd`: the closures below run before every stored
        // property is initialised, so touching `self` there is a use-before-init.
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
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
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