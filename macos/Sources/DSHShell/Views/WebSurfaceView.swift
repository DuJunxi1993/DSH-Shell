import SwiftUI
import WebKit
import OSLog
import DSHShellCore
import DSHShellBridge

/// A `WKWebView` bridged into SwiftUI. The native side owns the container; the
/// web side is the dsh SPA. The bridge script (`bridge.js`) is injected at
/// document start to give the shell a two-way channel with the page.
///
/// External drops (Finder images/files onto the window) are deliberately NOT
/// intercepted at the AppKit level. WKWebView's default `draggingEntered/…/
/// performDragOperation` forward the drop as a DOM `dragover` + `drop` event
/// to the page, where `event.dataTransfer.files` exposes the actual `File`
/// objects. dsh-session-manager's image-attachment flow (and any other SPA
/// drop handler) then works exactly as it does in a regular browser. An
/// earlier `DroppableWebView` subclass claimed the drop in AppKit and only
/// forwarded file paths as text, which broke image attachments entirely.
struct WebSurfaceView: NSViewRepresentable {
    let url: URL
    weak var bridgeClient: WebBridgeClient?
    /// Page zoom, 50–200 in 10% steps. Applied to the webview and remembered by
    /// the coordinator. The `⌘=`/`⌘-` chords are claimed by the host's key
    /// monitor before dsh's font-size shortcuts can see them; see `ZoomChord`
    /// and `DshDesktopBridge.installKeyMonitor`.
    var zoomPercent: Int = 100
    /// The origin the shell is allowed to show. Everything else is handed to the
    /// system browser — see the coordinator for why that matters.
    var allowedOrigin: String = ""
    /// Declares this webview to dsh as a macOS desktop host.
    ///
    /// Owned by the coordinator, not by this value type: the bridge has to
    /// outlive every view update (SwiftUI recreates `self` freely), and it has to
    /// be released explicitly when the app quits so the key monitor stops.
    let desktopBridge: DshDesktopBridge?
    /// Hands an external URL to the system browser.
    ///
    /// Called from the navigation delegate and from the ObjC UI delegate's
    /// new-window handler, so a plain link and a `target="_blank"` link follow
    /// the same path. The coordinator applies the origin rule first; this
    /// closure only ever sees an external `http(s)` URL.
    var onExternalURL: ((URL) -> Void)?
    /// Hands back the window this webview is actually in.
    ///
    /// Preferred over looking one up in `NSApp.windows`, which can only guess:
    /// with more than one window open it returned whichever came first in
    /// z-order, so the status item and the title bar could end up driving a
    /// window nobody was looking at.
    var onWindowResolved: ((NSWindow) -> Void)?

    final class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: WebBridge?
        /// Held here rather than by the caller so it outlives the view update
        /// that created it; the page keeps calling into it for the webview's
        /// whole life.
        var desktopBridge: DshDesktopBridge?
        /// The endpoint this webview has already been pointed at.
        ///
        /// Deliberately not derived from `webView.url`: dsh consumes the
        /// `?token=` on first load, so that value settles on a URL the shell
        /// never handed out and differs from the one we are holding. Comparing
        /// against what *we* loaded instead of what WebKit currently displays is
        /// what turns "already loaded" into a question with a stable answer.
        var loadedEndpoint: URL?
        /// The zoom preference this shell last pushed, so a pinch or WebKit's
        /// own zoom is not undone, and a menu step still takes effect.
        /// See `ZoomDecision`.
        var appliedPercent: Int?
        /// Strong owner of the `WKUIDelegate`.
        ///
        /// `WKWebView.UIDelegate` is declared `weak` (see `WKWebView.h`:
        /// `@property (nullable, nonatomic, weak) id <WKUIDelegate> UIDelegate;`),
        /// so the delegate must be retained by someone else. It used to be a
        /// local `let` in `makeNSView`, which meant it deallocated at the end of
        /// that function's scope and `uiDelegate` silently became nil —
        /// `confirm`/`alert`/`prompt` stopped being routed and every JS dialog
        /// vanished. `navigationDelegate` is weak too, but the Coordinator is
        /// retained by SwiftUI, so that one was never at risk. This is the
        /// reason the whole `DSHShellBridge` ObjC framework exists.
        ///
        /// This is also where `target="_blank"` / `window.open` is handled: the
        /// ObjC delegate implements `createWebViewWith…` and calls back into
        /// this coordinator, which applies the same origin rule as
        /// `decidePolicyFor`. Without it WebKit returns nil and a link clicked
        /// in dsh does nothing at all.
        let uiDelegate = DSHObjCWebUIDelegate()

        var allowedOrigin: String = ""
        var onExternalURL: ((URL) -> Void)?

        let uiLogger = Logger(subsystem: "ai.deepseek.dsh-shell", category: "WebUIDialog")

        /// Point the ObjC delegate's new-window block at this coordinator.
        ///
        /// The block is called by WebKit on the main thread, but its ObjC type
        /// carries no actor annotation. Rather than assert isolation and risk a
        /// trap if a future WebKit version calls it from somewhere else (this
        /// codebase has already been bitten by one `assumeIsolated` on a
        /// non-main queue), hop to the main actor explicitly. The one-run-loop
        /// delay is invisible when the only work is opening a browser.
        func installNewWindowHandler() {
            uiDelegate.newWindowHandler = { [weak self] url in
                Task { @MainActor [weak self] in
                    self?.handleNewWindow(url)
                }
            }
        }

        /// Decide what happens to a `target="_blank"` / `window.open` URL.
        ///
        /// An internal URL is refused rather than loaded into this webview: dsh
        /// would get a second page with no shared bridge state, which is the
        /// multi-window this shell does not have. Windows refuses the same case
        /// in `on_new_window`.
        private func handleNewWindow(_ url: URL) {
            switch NavigationPolicy.decideNewWindow(url, allowedOrigin: allowedOrigin) {
            case .openExternally:
                uiLogger.notice("nav.newWindow.external — \(url.absoluteString, privacy: .public)")
                onExternalURL?(url)
            case .allow:
                // Unreachable by construction: decideNewWindow turns .allow
                // into .deny. Kept exhaustive so a future policy change has to
                // make a deliberate choice here.
                uiLogger.notice("nav.newWindow.internal — refused \(url.absoluteString, privacy: .public)")
            case .deny:
                uiLogger.notice("nav.newWindow.denied — \(url.absoluteString, privacy: .public)")
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // The version used to be hard-coded as "dsh-swiftUI/0.1" while the
        // bundle said 0.1.2, so anything reading the UA was told a lie.
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        config.applicationNameForUserAgent = "DSHShell/\(version)"

        let bridge = WebBridge()
        bridge.client = bridgeClient
        let controller = WKUserContentController()
        if let script = WebBridge.makeUserScript() {
            controller.addUserScript(script)
        }
        controller.add(bridge, name: "dshBridge")
        config.userContentController = controller

        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = false
        view.translatesAutoresizingMaskIntoConstraints = false
        // WKUIDelegate is implemented in pure ObjC (DSHObjCWebUIDelegate) so the
        // three optional selectors (`runJavaScriptConfirm/Alert/TextInputPanel…`)
        // are visible to the ObjC runtime regardless of Swift 6 strict
        // concurrency settings — a Swift-only conformance silently dropped
        // every confirm, breaking dsh-session-manager's delete button.
        //
        // The instance is owned by the Coordinator, not by this scope: the
        // property is weak, so a local would be gone before the first dialog.
        context.coordinator.uiLogger.notice("objcDelegate installed — class=\(String(describing: type(of: context.coordinator.uiDelegate)), privacy: .public) owner=\(context.coordinator)")
        view.uiDelegate = context.coordinator.uiDelegate
        view.navigationDelegate = context.coordinator
        context.coordinator.uiLogger.notice("webView installed — uiDelegate=\(String(describing: view.uiDelegate), privacy: .public) navDelegate=\(String(describing: view.navigationDelegate), privacy: .public) url=\(url.absoluteString, privacy: .public)")

        context.coordinator.onExternalURL = onExternalURL
        context.coordinator.allowedOrigin = URLOrigin.of(url)
        context.coordinator.installNewWindowHandler()
        apply(zoomPercent, to: view, context: context)

        // The desktop contract goes in before `view.load`, so `data-platform` is
        // set before any of dsh's own scripts run. Its bridge script shares the
        // configuration's user content controller, so it is injected alongside
        // bridge.js rather than replacing it.
        desktopBridge?.attach(to: view)
        desktopBridge?.installKeyMonitor()
        context.coordinator.desktopBridge = desktopBridge

        context.coordinator.bridge = bridge
        bridge.webView = view
        bridgeClient?.bridgeReady(bridge)

        view.load(URLRequest(url: url))
        // Defer constraint installation to the next runloop tick, by which
        // time the SwiftUI container has wired up its NSHostingView.
        DispatchQueue.main.async {
            guard let superview = view.superview else { return }
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: superview.topAnchor),
                view.bottomAnchor.constraint(equalTo: superview.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: superview.trailingAnchor)
            ])
        }
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // SwiftUI may reuse the WKWebView across state transitions. Both
        // delegate properties are weak, so re-assert ours each time: if the
        // webview was recreated, or anything replaced either delegate, the
        // dialogs and the diagnostic log would go quiet without any error.
        if webView.uiDelegate !== context.coordinator.uiDelegate {
            webView.uiDelegate = context.coordinator.uiDelegate
        }
        if webView.navigationDelegate !== context.coordinator {
            webView.navigationDelegate = context.coordinator
        }
        context.coordinator.onExternalURL = onExternalURL
        context.coordinator.allowedOrigin = URLOrigin.of(url)
        context.coordinator.installNewWindowHandler()
        apply(zoomPercent, to: webView, context: context)
        // SwiftUI can hand us a different webview than the one the bridge was
        // attached to; a desktop contract injected into the old one is not
        // running in the new one, and dsh would boot as a browser document with
        // no sign of why.
        desktopBridge?.attach(to: webView)
        desktopBridge?.installKeyMonitor()
        context.coordinator.desktopBridge = desktopBridge
        // `webView.window`, not a search over `NSApp.windows` for one containing
        // a `WKWebView`. The search returned the first such window in z-order,
        // which is only ever the right one while there is exactly one — and
        // `WebSurfaceView` already knows which window it is in.
        //
        // Nil until the view is in a window, which is why this is repeated here
        // rather than done once in `makeNSView`.
        if let window = webView.window {
            onWindowResolved?(window)
        }
        // dsh answers the first request for `/?token=…` with a redirect that sets a
        // cookie, so from then on `webView.url` is `http://127.0.0.1:3080/` —
        // the token is gone from the URL, permanently and by design.
        //
        // Comparing that against the URL we were handed therefore said "changed"
        // on *every* `updateNSView`, forever. SwiftUI calls it whenever any
        // observed state moves — the page title, a bridge event, a console line
        // — so the page reloaded in a loop: measured 51 reloads in 90 seconds,
        // each one re-running the desktop bridge and re-subscribing to native
        // keyboard input. The bridge attached once, the page loaded 51 times.
        //
        // What this actually needs to know is "has this webview already been
        // pointed at this endpoint", which is a question about us, not about
        // WebKit's current address bar. A new token from a restarted dsh is a
        // different endpoint and must load; the same token is the same endpoint
        // and must not.
        if context.coordinator.loadedEndpoint != url {
            context.coordinator.loadedEndpoint = url
            webView.load(URLRequest(url: url))
        }
    }

    /// Push the zoom onto the webview, but only when our preference moved.
    ///
    /// The rule is deliberately about `percent` and never about the page's
    /// current `pageZoom`. Writing unconditionally made every `updateNSView`
    /// overrule WebKit — which broke ⌘-pinch. Comparing the page against the
    /// value we last wrote was the opposite mistake and worse: it skipped
    /// exactly when a new preference arrived, so the first ⌘- worked and every
    /// one after it was dropped while `settings.json` still recorded the change.
    /// The judgement itself lives in `ZoomDecision` so it can be tested.
    private func apply(_ percent: Int, to view: WKWebView, context: Context) {
        switch ZoomDecision.decide(percent: percent,
                                   appliedPercent: context.coordinator.appliedPercent) {
        case .leaveAlone:
            return
        case .apply(let snapped):
            context.coordinator.appliedPercent = snapped
            view.pageZoom = CGFloat(snapped) / 100.0
            Log.debug("page zoom -> \(snapped)%")
        }
    }
}

// WKNavigationDelegate conformance — implemented in the same extension so the
// protocol's `@MainActor` isolation (from `WK_SWIFT_UI_ACTOR` in the header)
// is inferred correctly.
//
// The two policy methods are not diagnostics. They are the difference between a
// window that shows dsh and a window that has been navigated somewhere else.
//
// A link or a server-side redirect off dsh's origin would otherwise replace the
// entire contents of the window with someone else's website — keeping the menu
// bar, keeping the dsh process, and offering no way back. So exactly one origin
// may be shown, and everything else is handed to the system browser.
//
// `target="_blank"` / `window.open` follows the same rule through
// `DSHObjCWebUIDelegate`'s `createWebViewWith…`, which calls `handleNewWindow`.
// Without that selector the call returns nil and the link does nothing at all,
// which is a different failure with the same cause.
extension WebSurfaceView.Coordinator {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        uiLogger.notice("nav.didStart — url=\(webView.url?.absoluteString ?? "<none>", privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        uiLogger.notice("nav.didFinish — url=\(webView.url?.absoluteString ?? "<none>", privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        uiLogger.notice("nav.didFail — url=\(webView.url?.absoluteString ?? "<none>", privacy: .public) error=\(error.localizedDescription, privacy: .public)")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        switch NavigationPolicy.decide(target, allowedOrigin: allowedOrigin) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            uiLogger.notice("nav.external — \(target.absoluteString, privacy: .public)")
            onExternalURL?(target)
            decisionHandler(.cancel)
        case .deny:
            uiLogger.notice("nav.denied — \(target.absoluteString, privacy: .public)")
            decisionHandler(.cancel)
        }
    }

    /// `target="_blank"` / `window.open` is handled by `DSHObjCWebUIDelegate`
    /// (`createWebViewWith…`), which calls `handleNewWindow` above. It is not a
    /// `WKUIDelegate` method here because the coordinator is never the
    /// `uiDelegate` — the ObjC adapter is, so the JS dialog selectors stay
    /// visible to the ObjC runtime.
}
