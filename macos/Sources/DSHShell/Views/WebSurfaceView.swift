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
        let objcDelegate = DSHObjCWebUIDelegate()
        context.coordinator.uiLogger.notice("objcDelegate init — class=\(String(describing: type(of: objcDelegate)), privacy: .public) isWKUIDelegate=\(objcDelegate is WKUIDelegate ? "true" : "false", privacy: .public)")
        view.uiDelegate = objcDelegate
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
        // SwiftUI may reuse the WKWebView across state transitions and drop
        // delegate references. The ObjC WKUIDelegate is owned by SwiftUI once
        // assigned, but re-assert it cheaply so a fresh instance is in place
        // if anything replaced it; the WKNavigationDelegate must follow our
        // Coordinator (used for diagnostic logs only).
        if !(webView.uiDelegate is DSHObjCWebUIDelegate) {
            webView.uiDelegate = DSHObjCWebUIDelegate()
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
