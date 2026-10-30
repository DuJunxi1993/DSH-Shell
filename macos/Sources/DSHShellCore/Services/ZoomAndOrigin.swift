import Foundation

/// The page-zoom ladder: 50–200 in 10% steps.
///
/// It lives in `DSHShellCore` rather than beside the menu that uses it, for the
/// same reason `config.rs` owns it on the Windows side: the menu's −/+, the
/// status item's "reset", and the settings file all need to agree, and a ladder
/// written down twice is a ladder that disagrees with itself the first time
/// either copy is edited.
///
/// Public so the app layer can ask "what does the next step look like" without
/// re-implementing the clamp.
///
/// ## Why the top used to be 100
///
/// It was, and nothing was defending it. Measured against real dsh by the probe
/// (`--zoom`), zooming past it costs nothing but layout:
///
/// | zoom | CSS viewport | horizontal overflow | breakpoint crossed | page errors |
/// |---|---|---|---|---|
/// | 100% | 1280px | none | — | 0 |
/// | 125% | 1024px | none | — | 0 |
/// | 150% | 854px | none | ≤900px | 0 |
/// | 200% | 640px | none | ≤900px, ≤700px | 0 |
///
/// So a dsh at 200% boots clean and reflows into its narrow layout — which is
/// the honest trade: past ~150% you are choosing to read dsh as a small window,
/// not making it bigger. Capping at 100% did not prevent that, it just denied a
/// choice that turns out to be available and safe. 200 is the point where the
/// ≤700px layout takes over and further zooming only makes it smaller.
public enum ZoomLadder {
    public static let minimum = 50
    public static let maximum = 200
    public static let step = 10
    public static let `default` = 100

    /// Every rung, ascending.
    ///
    /// Exists so the Zoom submenu cannot drift from the ladder: it enumerates
    /// this rather than writing out its own percentages, which is how a menu
    /// ends up offering a 130% that nothing can produce.
    public static let rungs: [Int] = {
        stride(from: minimum, through: maximum, by: step).map { $0 }
    }()

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

/// Which page-zoom step a key chord asks for.
///
/// dsh's desktop runtime binds `⌘=`, `⇧⌘=` and `⌘-` to its own *font size*
/// shortcuts (`dsh-client-ui-theme` → `installFontSizeShortcuts`) and consumes
/// them in the page. Those are `fixed` bindings, so `dispatchKeys` — which only
/// carries the editable rows — does not list them and the host's key monitor
/// never sees a reason to swallow them. The result is that the menu's page-zoom
/// shortcuts are unreachable: the page has already eaten the chord.
///
/// The host therefore recognises the same physical chords itself, before it
/// asks dsh what to dispatch, and treats them as page zoom. The mapping lives
/// here rather than inside the `NSEvent` monitor so it can be tested without a
/// window: a wrong mapping either zooms on an unrelated chord or leaves the
/// original bug in place.
public enum ZoomChord {
    /// The signed ladder delta this chord asks for, or `nil` if it is not a
    /// page-zoom chord.
    ///
    /// Accepts `⌘` and `⌘⇧` only. `⌘⌥=` and `⌘⌃=` belong to other commands, and
    /// an unmodified `=` is typing.
    public static func step(code: String, modifiers: [ShortcutModifier]) -> Int? {
        let meta = modifiers.contains(.meta)
        let other = modifiers.contains { $0 != .meta && $0 != .shift }
        guard meta, !other else { return nil }
        switch code {
        case "Equal":
            return ZoomLadder.step
        case "Minus":
            return -ZoomLadder.step
        default:
            return nil
        }
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

/// What to do with a URL the webview is about to navigate to.
///
/// There are two callbacks that need this answer — `decidePolicyFor` for a
/// navigation in the one webview, and `createWebViewWith` for `target="_blank"`
/// / `window.open` — and they must agree. Keeping the rule in one place also
/// makes it testable without a `WKWebView`, which is why it is here rather than
/// inline in the app target.
///
/// The new-window case deliberately turns `.allow` into a refusal: loading an
/// internal URL there would start a second dsh page with no shared bridge state
/// and a window the shell does not have. Windows refuses the same case in
/// `on_new_window`.
public enum NavigationPolicy: Equatable, Sendable {
    /// Load it in the shell's single webview.
    case allow
    /// Hand it to the system browser.
    case openExternally
    /// Refuse it. `file:`, `data:`, `javascript:` and custom schemes end up here.
    case deny

    public static func decide(_ url: URL, allowedOrigin: String) -> NavigationPolicy {
        if URLOrigin.isInternal(url, allowedOrigin: allowedOrigin) {
            return .allow
        }
        return URLOrigin.isOpenable(url) ? .openExternally : .deny
    }

    /// The decision for a new-window navigation (`target="_blank"`,
    /// `window.open`).
    ///
    /// A URL that would be allowed in the single webview is refused here
    /// instead: there is no second webview to put it in, and loading it into the
    /// current one would pretend the page got the window it asked for. External
    /// URLs still go to the browser; everything else is refused as before.
    public static func decideNewWindow(_ url: URL, allowedOrigin: String) -> NavigationPolicy {
        let decision = decide(url, allowedOrigin: allowedOrigin)
        return decision == .allow ? .deny : decision
    }
}