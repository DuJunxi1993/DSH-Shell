import XCTest
@testable import DSHShellCore

/// The macOS half of a shared contract; `windows/src-tauri/src/endpoint.rs`
/// carries the same twelve cases for the same reasons. If one side changes a
/// rule, the other has to change with it — see `docs/dsh-shell-contract.md` §2.
final class EndpointResolverTests: XCTestCase {
    private let resolver = EndpointResolver()

    // MARK: - Accepted

    func testAcceptsTheCanonicalDSHWebLine() {
        let url = resolver.resolveURL(
            in: "dsh web: http://127.0.0.1:3080/?token=abc123", expectedPort: 3080)
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:3080/?token=abc123")
    }

    func testAcceptsALanSuffix() {
        // `\S+` stops at the space, so the parenthesised LAN address is ignored
        // rather than swallowed into the URL. Verified against real dsh, which
        // prints exactly this shape on a second interface.
        let url = resolver.resolveURL(
            in: "dsh web: http://127.0.0.1:3080/?token=t (LAN: http://192.168.1.9:3080/?token=t)",
            expectedPort: 3080)
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:3080/?token=t")
    }

    func testToleratesLeadingWhitespaceCasingAndSpacing() {
        XCTAssertNotNil(resolver.resolveURL(
            in: "   DSH  Web:   http://127.0.0.1:3080/?token=t", expectedPort: 3080))
    }

    func testStripsANSIBeforeMatching() {
        let url = resolver.resolveURL(
            in: "\u{001B}[2Kdsh web: \u{001B}[0mhttp://127.0.0.1:3080/?token=t", expectedPort: 3080)
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:3080/?token=t")
    }

    func testAcceptsAnyPortWhenTheOSPicksOne() {
        // expectedPort 0 means dsh chose, so no port can mismatch.
        XCTAssertNotNil(resolver.resolveURL(
            in: "dsh web: http://127.0.0.1:54321/?token=t", expectedPort: 0))
    }

    func testAcceptsLocalhostAndIPv6Loopback() {
        XCTAssertNotNil(resolver.resolveURL(
            in: "dsh web: http://localhost:3080/?token=t", expectedPort: 3080))
        XCTAssertNotNil(resolver.resolveURL(
            in: "dsh web: http://[::1]:3080/?token=t", expectedPort: 3080))
    }

    // MARK: - Rejected: the decoy

    func testRejectsTheBiliProxyDecoy() {
        // The line this repository once shipped with. dsh's internal HTTP proxy
        // is announced on stderr and is not the UI; a loose "any loopback URL"
        // match points the webview at it and shows a white window.
        let decoy = "bili: attaching to running proxy at http://127.0.0.1:18787 (pid 24028)"
        XCTAssertNil(resolver.resolveURL(in: decoy, expectedPort: 18787))
        XCTAssertNil(resolver.resolveURL(in: decoy, expectedPort: 0))
    }

    func testRejectsAHyphenatedToolName() {
        // `dsh-web` is a different tool, not a spelling of `dsh web`.
        XCTAssertNil(resolver.resolveURL(
            in: "dsh-web: http://127.0.0.1:3080/?token=t", expectedPort: 3080))
    }

    // MARK: - Rejected: the token fence

    func testRejectsALineWithNoToken() {
        // `authorizeIndex` answers 401 without a token query or a `dsh-auth-`
        // cookie. Verified against real dsh: a bare URL answers 401, the
        // tokenized URL answers 303 + a cookie, and the cookied clean URL
        // answers 200. A tokenless URL can therefore never load the SPA.
        XCTAssertNil(resolver.resolveURL(
            in: "dsh web: http://127.0.0.1:3080/", expectedPort: 3080))
    }

    func testRejectsAnEmptyToken() {
        XCTAssertNil(resolver.resolveURL(
            in: "dsh web: http://127.0.0.1:3080/?token=", expectedPort: 3080))
    }

    func testRejectsADifferentQueryAsAMistakenToken() {
        XCTAssertNil(resolver.resolveURL(
            in: "dsh web: http://127.0.0.1:3080/?other=t", expectedPort: 3080))
    }

    // MARK: - Rejected: host and port

    func testRejectsARemoteHostEvenWithAToken() {
        XCTAssertNil(resolver.resolveURL(
            in: "dsh web: http://192.168.1.9:3080/?token=t", expectedPort: 3080))
        // The LAN address dsh prints in parentheses is not the loopback UI.
        XCTAssertNil(resolver.resolveURL(
            in: "dsh web: http://example.com:3080/?token=t", expectedPort: 3080))
    }

    func testRejectsAPortWeDidNotAskFor() {
        // The internal proxy, or a stale dsh, may answer on another port.
        XCTAssertNil(resolver.resolveURL(
            in: "dsh web: http://127.0.0.1:18787/?token=t", expectedPort: 3080))
        XCTAssertNil(resolver.resolveURL(
            in: "dsh web: http://127.0.0.1:9999/?token=t", expectedPort: 3080))
        // Prefix confusion: 999 must not satisfy 9999's expectation.
        XCTAssertNil(resolver.resolveURL(
            in: "dsh web: http://127.0.0.1:999/?token=t", expectedPort: 9999))
    }

    // MARK: - Rejected: chatter

    func testRejectsUnrelatedChatter() {
        for line in [
            "hello world",
            "dsh web http://no-colon",
            "dsh web:",
            "dsh web: ",
            "[info] something happened",
            "",
        ] {
            XCTAssertNil(resolver.resolveURL(in: line, expectedPort: 3080),
                         "should have rejected: \(line)")
        }
    }

    func testAcceptsTheFirstAcceptableLineAndKeepsRejectingAfter() {
        // dsh prints one line; a resolver that later accepts a decoy would point
        // the webview at the proxy, so rejection has to be permanent.
        XCTAssertNotNil(resolver.resolveURL(
            in: "dsh web: http://127.0.0.1:3080/?token=t", expectedPort: 3080))
        XCTAssertNil(resolver.resolveURL(
            in: "bili: attaching to running proxy at http://127.0.0.1:18787", expectedPort: 0))
    }
}