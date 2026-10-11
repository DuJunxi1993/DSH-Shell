import Foundation

/// Parses the `dsh web:` URL line emitted by `dsh-web-app` on **stdout**.
///
/// The contract is small, and every clause of it was bought with a bug. This
/// type is the macOS half of a two-implementation contract; `windows/src-tauri/
/// src/endpoint.rs` is the other half, and the two must accept the same lines
/// for the same reasons. The rules are documented in
/// `docs/dsh-shell-contract.md` §2.
///
/// The four acceptance rules, each of which rejects a real failure:
///
/// 1. **The `dsh web:` prefix.** stderr carries loopback URLs that are *not* the
///    UI — dsh logs `bili: attaching to running proxy at http://127.0.0.1:18787`,
///    which is its internal HTTP proxy. A loose "any loopback URL" match points
///    the webview at the proxy and shows a white window.
/// 2. **A loopback host.** dsh binds loopback only.
/// 3. **The port we asked for.** The proxy, or a stale dsh, may answer on
///    another port. `expectedPort == 0` means the OS picks, so any loopback
///    port is then acceptable.
/// 4. **A non-empty `?token=`.** `dsh-client-connection`'s `authorizeIndex`
///    answers `401` to a request with neither a valid token query nor a
///    `dsh-auth-` cookie. A tokenless URL can never load the SPA, so one must
///    never be accepted — verified against real dsh, where the tokenized URL
///    answers `303` + a cookie, the cookied clean URL answers `200`, and the
///    bare URL answers `401`.
///
/// A tokenized URL is a one-shot credential: dsh trades the query for a
/// `dsh-auth-` cookie and redirects to `./`. Keeping `?token=` in the address
/// bar loops on 303s.
public struct EndpointResolver: Sendable {
    /// Compiled once. dsh's stdout can be chatty, and this runs per line.
    private static let urlLine: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^\s*dsh\s+web\s*:\s*(\S+)"#, options: [.caseInsensitive])
    }()

    /// Hosts dsh can possibly bind. Both spellings of the IPv6 loopback are
    /// needed because `URL.host` returns the bracketed form.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    public init() {}

    /// Strip ANSI escape sequences from a log line.
    ///
    /// A colourised line has to parse like a plain one. This used to be
    /// `"\\u{001B}\\[[0-9;]*[a-zA-Z]"`, which never matched anything: `\u{001B}`
    /// is Swift's escape syntax, not a regex one, so the compiled pattern was a
    /// literal `u{001B}` and the leading escape byte survived into the match.
    /// The old test passed anyway, because the unanchored pattern captured the
    /// escape bytes *inside* the URL and `URL(string:)` happened to tolerate
    /// them. Anchoring the pattern exposed the bug — which is what an anchor is
    /// for. `\x1B` is the escape ICU understands.
    private static let ansi: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\x1B(?:\\[[0-9;?]*[ -/]*[@-~]|.)")
    }()

    private static func strippingANSI(_ line: String) -> String {
        guard let ansi else { return line }
        let range = NSRange(line.startIndex..., in: line)
        return ansi.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    /// Try to extract an authenticated URL from one line of stdout.
    ///
    /// - Parameter expectedPort: the port the shell asked dsh to bind. Pass `0`
    ///   to accept any loopback port (OS-assigned).
    public func resolveURL(in line: String, expectedPort: Int) -> URL? {
        let cleaned = Self.strippingANSI(line)

        guard let regex = Self.urlLine,
              let match = regex.firstMatch(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              match.numberOfRanges >= 2,
              let urlRange = Range(match.range(at: 1), in: cleaned)
        else { return nil }

        // `\S+` stops at the whitespace of an optional ` (LAN: …)` suffix, so
        // the LAN address is ignored rather than parsed as part of the URL.
        guard let url = URL(string: String(cleaned[urlRange])) else { return nil }

        // Rule 2: loopback only.
        let host = (url.host ?? "").lowercased()
        guard Self.loopbackHosts.contains(host) else { return nil }

        // Rule 3: the port we asked for. 0 means the OS picked, so accept any.
        if expectedPort != 0, url.port != expectedPort { return nil }

        // Rule 4: a non-empty token is mandatory.
        guard let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" })?.value,
            !token.isEmpty
        else { return nil }

        return url
    }
}