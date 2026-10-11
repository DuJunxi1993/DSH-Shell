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

    final class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: WebBridge?
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
        let uiDelegate = DSHObjCWebUIDelegate()

        let uiLogger = Logger(subsystem: "ai.deepseek.dsh-shell", category: "WebUIDialog")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.applicationNameForUserAgent = "dsh-swiftUI/0.1"

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
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}

// WKNavigationDelegate conformance — implemented in the same extension so the
// protocol's `@MainActor` isolation (from `WK_SWIFT_UI_ACTOR` in the header)
// is inferred correctly. The WKNavigationDelegate methods here are diagnostic
// only: they fire unconditionally on every load, so seeing them in the log
// proves the Coordinator is actually bound to the WKWebView.
//
// `WKUIDelegate` is NOT conformed to here on purpose — it lives in pure ObjC
// (DSHObjCWebUIDelegate) so the three optional `runJavaScript…` selectors
// are visible to the ObjC runtime regardless of Swift 6 strict concurrency.
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
}
