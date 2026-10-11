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
        XCTAssertEqual(ZoomLadder.snap(1000), 100)
    }

    func testZoomIsAlwaysAMultipleOfTheStep() {
        for value in 0...200 {
            XCTAssertEqual(ZoomLadder.snap(value) % ZoomLadder.step, 0, "snap(\(value))")
        }
    }

    func testNextWalksTheLadderAndStopsAtTheEnds() {
        XCTAssertEqual(ZoomLadder.next(from: 50, delta: 10), 60)
        XCTAssertEqual(ZoomLadder.next(from: 100, delta: 10), 100)
        XCTAssertEqual(ZoomLadder.next(from: 50, delta: -10), 50)
        XCTAssertEqual(ZoomLadder.next(from: 100, delta: -10), 90)
    }

    /// An oversized delta from a corrupted settings file must not escape the
    /// range, and must not overflow either.
    func testNextSurvivesAnOversizedDelta() {
        XCTAssertEqual(ZoomLadder.next(from: 50, delta: Int.max), 100)
        XCTAssertEqual(ZoomLadder.next(from: 100, delta: Int.min), 50)
    }

    func testNextIsIdempotentOnAnAlreadySnappedValue() {
        for value in stride(from: 50, through: 100, by: 10) {
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
