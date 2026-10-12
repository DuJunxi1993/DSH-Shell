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
    /// Page zoom, 50–100 in 10% steps. Applied to the webview and remembered by
    /// the coordinator; the webview's own ⌘+/- is deliberately left alone,
    /// because WKWebView has no way to suppress it and a percentage that drifts
    /// from the real zoom is worse than no percentage at all.
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var bridge: WebBridge?
        /// Held here rather than by the caller so it outlives the view update
        /// that created it; the page keeps calling into it for the webview's
        /// whole life.
        var desktopBridge: DshDesktopBridge?
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
        /// This coordinator also conforms to `WKUIDelegate` so `createWebViewWith`
        /// is implemented: without it, `target="_blank"` and `window.open` return
        /// nil and a link clicked in dsh does nothing at all.
        let uiDelegate = DSHObjCWebUIDelegate()

        var allowedOrigin: String = ""
        var onExternalURL: ((URL) -> Void)?

        let uiLogger = Logger(subsystem: "ai.deepseek.dsh-shell", category: "WebUIDialog")
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

        context.coordinator.allowedOrigin = URLOrigin.of(url)
        apply(zoomPercent, to: view)

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
        context.coordinator.allowedOrigin = URLOrigin.of(url)
        apply(zoomPercent, to: webView)
        // SwiftUI can hand us a different webview than the one the bridge was
        // attached to; a desktop contract injected into the old one is not
        // running in the new one, and dsh would boot as a browser document with
        // no sign of why.
        desktopBridge?.attach(to: webView)
        desktopBridge?.installKeyMonitor()
        context.coordinator.desktopBridge = desktopBridge
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    private func apply(_ percent: Int, to view: WKWebView) {
        let clamped = min(100, max(50, percent))
        let scale = CGFloat(clamped) / 100.0
        guard abs(view.pageZoom - scale) > 0.001 else { return }
        view.pageZoom = scale
        Log.debug("page zoom -> \(clamped)%")
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
// `target="_blank"` / `window.open` lands here too, via `createWebViewWith`.
// Without it the call returns nil and the link does nothing at all, which is a
// different failure with the same cause.
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
        if isInternal(target) {
            decisionHandler(.allow)
            return
        }
        uiLogger.notice("nav.external — \(target.absoluteString, privacy: .public)")
        onExternalURL?(target)
        decisionHandler(.cancel)
    }

    /// `target="_blank"` and `window.open`. Always cancelled; an internal URL is
    /// *not* loaded here either — it would open a second webview with its own
    /// bridge and its own window, which is the multi-window this shell does not
    /// have. An external URL still goes to the browser.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, !isInternal(url) {
            uiLogger.notice("nav.newWindow.external — \(url.absoluteString, privacy: .public)")
            onExternalURL?(url)
        }
        return nil
    }

    /// Only `http(s)` is ever handed to the operating system. Anything else is a
    /// way to make the OS launch something with this process's identity — a
    /// `file:` URL, a custom scheme, `javascript:`.
    private func isInternal(_ url: URL) -> Bool {
        URLOrigin.isInternal(url, allowedOrigin: allowedOrigin)
    }
}
