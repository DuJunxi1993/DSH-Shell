import XCTest
@testable import DSHShellCore

/// The page-zoom ladder and the origin comparison.
///
/// The origin half is a security rule: exactly one origin may be shown in the
/// shell's webview. Mirrors `windows/src-tauri/src/navigate.rs` and its five
/// tests.
final class ZoomAndOriginTests: XCTestCase {
    // MARK: - Zoom ladder

    func testZoomSnapsToTheNearestRung() {
        XCTAssertEqual(ZoomLadder.snap(54), 50)
        XCTAssertEqual(ZoomLadder.snap(55), 60)
        XCTAssertEqual(ZoomLadder.snap(57), 60)
        XCTAssertEqual(ZoomLadder.snap(95), 100)
    }

    func testZoomClampsToTheRange() {
        XCTAssertEqual(ZoomLadder.snap(0), 50)
        XCTAssertEqual(ZoomLadder.snap(-100), 50)
        XCTAssertEqual(ZoomLadder.snap(1000), 200)
    }

    func testZoomIsAlwaysAMultipleOfTheStep() {
        for value in 0...400 {
            XCTAssertEqual(ZoomLadder.snap(value) % ZoomLadder.step, 0, "snap(\(value))")
        }
    }

    func testNextWalksTheLadderAndStopsAtTheEnds() {
        XCTAssertEqual(ZoomLadder.next(from: 50, delta: 10), 60)
        XCTAssertEqual(ZoomLadder.next(from: 100, delta: 10), 110)
        XCTAssertEqual(ZoomLadder.next(from: 50, delta: -10), 50)
        XCTAssertEqual(ZoomLadder.next(from: 100, delta: -10), 90)
        XCTAssertEqual(ZoomLadder.next(from: 200, delta: 10), 200)
    }

    /// Past 100% the user is reading dsh as a smaller window, not a bigger one —
    /// measured, that costs a narrower CSS viewport and nothing else.
    func testTheLadderGoesPast100() {
        XCTAssertEqual(ZoomLadder.next(from: 100, delta: 10), 110)
        XCTAssertEqual(ZoomLadder.next(from: 190, delta: 10), 200)
        XCTAssertEqual(ZoomLadder.next(from: 200, delta: 10), 200, "and stops there")
    }

    /// The status item's Zoom submenu enumerates this, so a rung it offers but
    /// stepping cannot reach — or the reverse — is a menu that lies.
    func testTheRungsAreExactlyTheWalkableRange() {
        XCTAssertEqual(ZoomLadder.rungs.first, ZoomLadder.minimum)
        XCTAssertEqual(ZoomLadder.rungs.last, ZoomLadder.maximum)
        XCTAssertEqual(ZoomLadder.rungs, Array(ZoomLadder.rungs).sorted())
        XCTAssertEqual(Set(ZoomLadder.rungs).count, ZoomLadder.rungs.count, "no duplicates")
        for value in ZoomLadder.rungs {
            XCTAssertEqual(ZoomLadder.snap(value), value, "\(value) is not a rung")
        }
        // Every rung is one step from its neighbour.
        for (lower, higher) in zip(ZoomLadder.rungs, ZoomLadder.rungs.dropFirst()) {
            XCTAssertEqual(ZoomLadder.next(from: lower, delta: ZoomLadder.step), higher)
        }
    }

    /// A delta from a corrupted settings file must neither overflow nor escape
    /// the ladder.
    ///
    /// Asserted as "lands on a rung" rather than a specific value, because that
    /// is what the guarantee is. The previous version asserted `100`, and it
    /// passed for the wrong reason: with a ceiling of 100, a delta clamped to
    /// `step * 10` overshot to 150 and was clamped back down to 100 by accident.
    /// Raising the ceiling to 200 turned that coincidence into `150` and exposed
    /// that the test had never been checking overflow at all.
    func testNextSurvivesAnOversizedDelta() {
        for (from, delta) in [(50, Int.max), (200, Int.min), (50, Int.min),
                              (200, Int.max), (0, Int.max), (0, Int.min),
                              (Int.max, Int.max), (Int.min, Int.min)] {
            let next = ZoomLadder.next(from: from, delta: delta)
            XCTAssertTrue(ZoomLadder.rungs.contains(next),
                          "next(from: \(from), delta: \(delta)) = \(next), off the ladder")
        }
    }

    func testNextIsIdempotentOnAnAlreadySnappedValue() {
        for value in ZoomLadder.rungs {
            XCTAssertEqual(ZoomLadder.next(from: value, delta: 0), value)
        }
    }

    // MARK: - Origin comparison

    func testOriginNormalisesCaseAndDefaultPort() throws {
        let a = try XCTUnwrap(URL(string: "HTTP://127.0.0.1:3080/?token=x"))
        XCTAssertEqual(URLOrigin.of(a), "http://127.0.0.1:3080")
        let b = try XCTUnwrap(URL(string: "http://LOCALHOST/"))
        XCTAssertEqual(URLOrigin.of(b), "http://localhost")
    }

    /// The bug a prefix comparison has: `:1` is a prefix of `:12`.
    func testAPortIsNotAPrefixMatch() throws {
        let short = try XCTUnwrap(URL(string: "http://127.0.0.1:999/?token=t"))
        XCTAssertFalse(URLOrigin.isInternal(short, allowedOrigin: "http://127.0.0.1:9999"))
    }

    /// Also a prefix: the same host and port on a downgraded scheme.
    func testTheSchemeIsPartOfTheOrigin() throws {
        let https = try XCTUnwrap(URL(string: "https://127.0.0.1:3080/?token=t"))
        XCTAssertFalse(URLOrigin.isInternal(https, allowedOrigin: "http://127.0.0.1:3080"))
    }

    func testDshItselfIsAllowed() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:3080/?token=t"))
        XCTAssertTrue(URLOrigin.isInternal(url, allowedOrigin: "http://127.0.0.1:3080"))
        XCTAssertTrue(URLOrigin.isInternal(url, allowedOrigin: "http://127.0.0.1:3080"))
    }

    func testAnotherSessionOnTheSamePortIsStillTheSameOrigin() throws {
        // Tokens are per-process but the *origin* is not: dsh's own redirects
        // stay within it, and refusing them would break the app.
        let clean = try XCTUnwrap(URL(string: "http://127.0.0.1:3080/"))
        XCTAssertTrue(URLOrigin.isInternal(clean, allowedOrigin: "http://127.0.0.1:3080"))
    }

    func testExternalSitesAreBlocked() throws {
        for raw in [
            "http://127.0.0.1:9999/",
            "http://127.0.0.1:3081/",
            "https://example.com/",
            "http://evil.test/",
        ] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(URLOrigin.isInternal(url, allowedOrigin: "http://127.0.0.1:3080"), raw)
        }
    }

    /// "We do not know where we are" must not resolve to "anywhere is fine".
    func testNothingIsAllowedBeforeTheOriginIsKnown() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:3080/"))
        XCTAssertFalse(URLOrigin.isInternal(url, allowedOrigin: ""))
    }

    /// Only http(s) may be handed to the OS. Anything else launches something
    /// with this process's identity.
    func testOnlyHTTPIsHandedToTheOperatingSystem() throws {
        // Openable: the two schemes a link can legitimately be.
        for raw in ["http://example.com/", "https://example.com/"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertTrue(URLOrigin.isOpenable(url), raw)
        }
        // Everything else is a way to make Launch Services do something with this
        // process's identity.
        for raw in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,x",
            "ms-settings:",
            "dsh://open",
        ] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(URLOrigin.isOpenable(url), raw)
        }
    }

    func testAMalformedURLHasNoOrigin() {
        XCTAssertEqual(URLOrigin.of(URL(string: "not a url")!), "")
    }
}
