import XCTest
@testable import DSHShellCore

/// The rule both navigation callbacks share.
///
/// The bug this guards: `decidePolicyFor` cancelled every navigation off dsh's
/// origin and then called a callback that was never wired, and
/// `createWebViewWith` was implemented on a delegate WebKit never used. A link
/// therefore did nothing at all. The policy itself was right; nothing asserted
/// that the new-window path and the same-view path answer the same way.
final class NavigationPolicyTests: XCTestCase {
    private let dsh = "http://127.0.0.1:3080"

    private func policy(_ raw: String) throws -> NavigationPolicy {
        let url = try XCTUnwrap(URL(string: raw))
        return NavigationPolicy.decide(url, allowedOrigin: dsh)
    }

    func testDshItselfIsShownInTheShell() throws {
        XCTAssertEqual(try policy("http://127.0.0.1:3080/"), .allow)
        XCTAssertEqual(try policy("http://127.0.0.1:3080/session/abc?x=1"), .allow)
    }

    /// Another port is another origin — the shape of a second dsh, not ours.
    func testAnotherOriginGoesToTheBrowser() throws {
        XCTAssertEqual(try policy("http://127.0.0.1:3081/"), .openExternally)
        XCTAssertEqual(try policy("https://example.com/"), .openExternally)
    }

    /// A scheme downgrade on the same host and port is still a different origin.
    func testADowngradedSchemeIsExternal() throws {
        XCTAssertEqual(try policy("https://127.0.0.1:3080/"), .openExternally)
    }

    /// Only http(s) is handed to Launch Services: anything else would launch
    /// something with this process's identity. `mailto:` is refused on purpose —
    /// it matches `windows/src-tauri/src/navigate.rs`.
    func testSchemesThatAreNotHTTPAreRefused() throws {
        for raw in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,x",
            "mailto:someone@example.com",
            "dsh://open",
        ] {
            XCTAssertEqual(try policy(raw), .deny, raw)
        }
    }

    /// Before dsh resolves, its URL is not "internal" yet. It is still an
    /// ordinary web URL, so the browser gets it rather than the shell — the safe
    /// direction, and the same one the origin rule documents.
    func testNothingIsInternalBeforeTheOriginIsKnown() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:3080/"))
        XCTAssertEqual(NavigationPolicy.decide(url, allowedOrigin: ""), .openExternally)
    }

    // MARK: - New windows

    /// `target="_blank"` on an internal link must not become a second dsh page:
    /// there is no window to put it in and no bridge state to share.
    func testANewWindowIsNeverUsedForDshItself() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:3080/session/abc"))
        XCTAssertEqual(NavigationPolicy.decideNewWindow(url, allowedOrigin: dsh), .deny)
    }

    /// The new-window case exists to get external links out to the browser, so
    /// it must agree with the in-place rule about which ones those are.
    func testANewWindowStillOpensExternalLinksExternally() throws {
        let external = try XCTUnwrap(URL(string: "https://example.com/docs"))
        XCTAssertEqual(NavigationPolicy.decideNewWindow(external, allowedOrigin: dsh), .openExternally)

        let script = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        XCTAssertEqual(NavigationPolicy.decideNewWindow(script, allowedOrigin: dsh), .deny)
    }
}
