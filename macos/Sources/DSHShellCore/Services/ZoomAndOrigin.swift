import Foundation

/// The page-zoom ladder: 50–100 in 10% steps.
///
/// It lives in `DSHShellCore` rather than beside the menu that uses it, for the
/// same reason `config.rs` owns it on the Windows side: the menu's −/+, the
/// status item's "reset", and the settings file all need to agree, and a ladder
/// written down twice is a ladder that disagrees with itself the first time
/// either copy is edited.
///
/// Public so the app layer can ask "what does the next step look like" without
/// re-implementing the clamp.
public enum ZoomLadder {
    public static let minimum = 50
    public static let maximum = 100
    public static let step = 10
    public static let `default` = 100

    /// Clamp into range, then snap to the nearest rung.
    ///
    /// Snapping rather than rejecting is deliberate: a hand-edited 57 should
    /// behave like 60, not like an error the user cannot see.
    public static func snap(_ value: Int) -> Int {
        let clamped = min(maximum, max(minimum, value))
        return Int((Double(clamped) / Double(step)).rounded()) * step
    }

    /// The next rung in `direction`, clamped at the ends.
    ///
    /// Takes a *signed delta* rather than an absolute value so that every caller
    /// asks the ladder what "next" means instead of deciding for itself.
    public static func next(from current: Int, delta: Int) -> Int {
        let safeDelta = max(-step * 10, min(step * 10, delta))
        return snap(snap(current) + safeDelta)
    }
}

/// Comparing a URL against an origin, correctly.
///
/// This is the macOS half of `windows/src-tauri/src/navigate.rs`. The rule it
/// exists to enforce: **exactly one origin may be shown in the shell's webview**,
/// and everything else goes to the system browser. A link or a server-side
/// redirect off dsh's origin would otherwise replace the entire contents of the
/// window with someone else's website, keeping the menu bar and keeping the dsh
/// process, with no way back.
///
/// Two failure modes to avoid, both of which a prefix comparison has:
///
///   - `http://127.0.0.1:1` starts with `http://127.0.0.1:12`, so a prefix rule
///     admits the wrong origin.
///   - `https://127.0.0.1:3080` starts with `http://127.0.0.1:3080`, so a prefix
///     rule admits a *different scheme* on the same host and port — and a
///     downgraded scheme is not something to hand to a page silently.
///
/// Only `http` and `https` may be shown at all. Anything else is a way to make
/// the system launch something with this process's identity: `file:`, `data:`,
/// `javascript:`, a custom scheme.
public enum URLOrigin {
    /// `scheme://host[:port]`, normalised: lowercase, default port omitted.
    ///
    /// Returns "" for anything without both a scheme and a host, which
    /// `isInternal` then treats as "not ours" — the safe direction to fail.
    public static func of(_ url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return "" }
        // The default port is not part of an origin's identity, and leaving it
        // in would make `http://127.0.0.1` and `http://127.0.0.1:80` compare
        // unequal to themselves — which is a redirect dsh can legitimately make.
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// Whether the shell may navigate to `url` itself.
    ///
    /// - Parameter allowedOrigin: the dsh origin, or "" when none is known yet —
    ///   in which case nothing is allowed, because "we do not know where we
    ///   are" must not resolve to "anywhere is fine".
    public static func isInternal(_ url: URL, allowedOrigin: String) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        guard !allowedOrigin.isEmpty else { return false }
        return of(url) == allowedOrigin
    }

    /// Whether a URL may be handed to the operating system.
    ///
    /// `http(s)` only, for the reason above. Handing anything else to Launch
    /// Services is handing it this process's identity.
    public static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}