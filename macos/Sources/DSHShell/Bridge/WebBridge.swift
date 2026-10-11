import Foundation
import DSHShellCore
import WebKit
import OSLog

/// Events reported by the injected bridge script in the dsh SPA.
enum WebBridgeEvent: Equatable {
    case probe(WebProbeReport)
    case title(String)
    case agentState(running: Bool)
    case ack(action: String, ok: Bool)
    case unknown(String)
}

/// A snapshot of DOM candidates the injected script found. Used to tune the
/// bridge selectors against the real SPA layout without guessing.
struct WebProbeReport: Equatable {
    struct Element: Equatable {
        var tag: String
        var attribute: String
        var text: String
    }

    var headings: [Element]
    var buttons: [Element]
    var inputs: [Element]
}

/// Native-side commands the Swift shell can invoke on the SPA. Every action is
/// best-effort: the bridge JS guards each lookup and reports `{ok:false}`
/// instead of throwing, so the web page is never broken by a stale selector.
enum WebAction {
    case focusComposer
    case sendMessage
    case newSession
    case openWorkspace
    case injectText(String)
}

/// Client of the bridge: receives events and the bridge instance itself.
@MainActor
protocol WebBridgeClient: AnyObject {
    func handleBridgeEvent(_ event: WebBridgeEvent)
    func bridgeReady(_ bridge: WebBridge)
}

/// Owns the injected user script and the `WKScriptMessageHandler` that routes
/// page events to the client. Also forwards native actions into the page via
/// `evaluateJavaScript`.
@MainActor
final class WebBridge: NSObject, WKScriptMessageHandler {
    /// An absent value and an empty one read the same in a log line, and the
    /// difference between "dsh published nothing" and "dsh published 0" is
    /// exactly what the contract report is for.
    private static func orDash(_ value: Any?) -> String {
        guard let text = value as? String else { return String(describing: value ?? "-") }
        return text.isEmpty ? "-" : text
    }

    weak var webView: WKWebView?
    weak var client: WebBridgeClient?

    /// Loads `bridge.js` from the app bundle and wraps it in a user script.
    static func makeUserScript() -> WKUserScript? {
        guard let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "dshBridge", let body = message.body as? String,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch type {
        case "probe":
            if let layout = payload["layout"] as? [[String: Any]] {
                let lines = layout.map { item -> String in
                    let data = (item["data"] as? [String])?.joined(separator: " ") ?? ""
                    let grid = item["grid"] as? String ?? ""
                    return "\(item["tag"] ?? "?") \(item["cls"] ?? "") [\(data)] \(grid)"
                }.joined(separator: " | ")
                Logger(subsystem: "ai.deepseek.dsh-shell", category: "Bridge").debug("bridge layout — \(lines, privacy: .public)")
            }
            // What dsh thinks about being on a desktop, read from CSS rather
            // than from class names. This is the single most decision-relevant
            // thing the page can tell us: `--dsh-frame-top-clearance` being
            // non-empty means dsh reserved the titlebar band itself, and the
            // whole chrome question is settled. `appRegionSupported: false` is
            // expected on WebKit — `-webkit-app-region` is a Blink property — so
            // `data-window-drag` rows need native drag forwarding from here.
            if let desktop = payload["desktop"] as? [String: Any] {
                let summary = [
                    "platform=\(Self.orDash(desktop["platform"]))",
                    "titlebar=\(Self.orDash(desktop["titlebar"]))",
                    "fullscreen=\(Self.orDash(desktop["fullscreen"]))",
                    "topClearance=\(Self.orDash(desktop["topClearance"]))",
                    "chromeTop=\(Self.orDash(desktop["chromeTop"]))",
                    "leading=\(Self.orDash(desktop["leadingClearance"]))",
                    "overlay=\(Self.orDash(desktop["overlayTop"]))",
                    "dragRegions=\(Self.orDash(desktop["dragRegions"]))",
                    "appRegion=\(Self.orDash(desktop["appRegionSupported"]))",
                ].joined(separator: " ")
                Log.debug("desktop contract — \(summary)")
                FileLogger.shared.write("desktop contract — \(summary)", level: "contract")
            }
            client?.handleBridgeEvent(.probe(parseProbe(payload)))
        case "title":
            if let text = payload["text"] as? String, !text.isEmpty {
                client?.handleBridgeEvent(.title(text))
            }
        case "agentState":
            if let running = payload["running"] as? Bool {
                client?.handleBridgeEvent(.agentState(running: running))
            }
        case "ack":
            if let action = payload["action"] as? String, let ok = payload["ok"] as? Bool {
                client?.handleBridgeEvent(.ack(action: action, ok: ok))
            }
        default:
            client?.handleBridgeEvent(.unknown(type))
        }
    }

    func invoke(_ action: WebAction) {
        guard let webView else { return }
        let js: String
        switch action {
        case .focusComposer:
            js = "window.__dshShell && window.__dshShell.do('focusComposer')"
        case .sendMessage:
            js = "window.__dshShell && window.__dshShell.do('sendMessage')"
        case .newSession:
            js = "window.__dshShell && window.__dshShell.do('newSession')"
        case .openWorkspace:
            js = "window.__dshShell && window.__dshShell.do('openWorkspace')"
        case .injectText(let text):
            let encoded = Self.jsonString(text)
            js = "window.__dshShell && window.__dshShell.do('injectText', \(encoded))"
        }
        webView.evaluateJavaScript(js) { _, _ in }
    }

    private func parseProbe(_ payload: [String: Any]) -> WebProbeReport {
        func elements(_ key: String) -> [WebProbeReport.Element] {
            let raw = payload[key] as? [[String: Any]] ?? []
            return raw.compactMap { item in
                WebProbeReport.Element(
                    tag: item["tag"] as? String ?? "",
                    attribute: item["aria"] as? String ?? item["placeholder"] as? String ?? item["title"] as? String ?? "",
                    text: item["text"] as? String ?? ""
                )
            }
        }
        return WebProbeReport(
            headings: elements("headings"),
            buttons: elements("buttons"),
            inputs: elements("inputs")
        )
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }
}
