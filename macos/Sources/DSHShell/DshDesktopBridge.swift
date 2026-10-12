import AppKit
import WebKit
import DSHShellCore

/// Declares this webview to dsh as a macOS desktop host, and serves the five
/// entry points dsh then requires.
///
/// ## The whole thing is one script, or none of it
///
/// `documentElement.dataset.platform` is dsh's *runtime switch*, not a CSS hook:
/// its presence puts dsh into the desktop runtime, which then refuses to mount
/// anything until `dshDesktopBoot.ready()` resolves. Setting the attribute
/// without the bridge produces a boot card that says "24 entries did not
/// activate" and never finishes — an app that is dead with no error.
///
/// So the attribute lives *inside* `dsh_desktop_bridge.js`, injected as one
/// `WKUserScript`. If the resource cannot be loaded, nothing is injected, dsh
/// renders as a browser document, and the only symptom is an info line in the
/// log. That is the failure mode worth having.
///
/// ## The revision is load-bearing
///
/// `installNativeKeyboard` opens with `if (input.revision !== snapshot().revision) return;`.
/// A stale revision is dropped silently, and since the listener returns nothing
/// the host cannot tell that happened — the user presses ⌘N and nothing occurs.
///
/// So every dispatched input carries the revision from the most recent
/// `shortcuts.get()`, refreshed after each successful `edit`. `currentRevision`
/// is the single place that tracks it.
@MainActor
final class DshDesktopBridge: NSObject {
    private weak var webView: WKWebView?
    private var config = ShortcutConfigStore()

    /// The revision dsh currently believes. Dispatched inputs carry this.
    private(set) var currentRevision: String?

    /// Posted after a successful `shortcuts.edit`, so the UI can refresh.
    var onShortcutsChanged: ((ShortcutSnapshot) -> Void)?

    /// Set while the native key monitor is active, so it can be released.
    private var keyMonitor: Any?

    // MARK: - Injection

    /// Whether the bridge is in effect. `false` means dsh is running as a plain
    /// browser document, which is a supported state, not a failure.
    private(set) var active = false

    /// The controller this bridge registered with, so a second `attach` to the
    /// same webview is a no-op.
    ///
    /// `updateNSView` runs on every SwiftUI state change, and both
    /// `addUserScript` and `add(_:name:)` append rather than replace. Calling
    /// them again would queue the same `documentStart` script once per state
    /// change and re-register a message handler under a name that is already
    /// taken — the handler raises, and the script is re-run against a live
    /// subscription each time.
    private weak var attachedController: WKUserContentController?

    func attach(to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if attachedController === controller {
            // Already registered. The webview was re-created only if its
            // configuration was, and a new configuration means a new
            // controller, which is not this one.
            self.webView = webView
            return
        }
        self.webView = webView
        guard let script = Self.loadScript() else {
            // The single most important branch in this file: log loudly, inject
            // nothing, and do not set the attribute.
            Log.error("""
                dsh-desktop-bridge.js is not in the bundle. Declaring the desktop \
                runtime without the bridge stops the dsh UI from booting at all, \
                so nothing was injected and dsh is running as a browser document. \
                Build through Xcode, or add the script to the target's resources.
                """)
            active = false
            return
        }
        // `WKWebView.configuration` is read-only after initialisation, so the
        // script has to go into the controller the configuration already has —
        // which is the one `WebSurfaceView` built for bridge.js. That is fine and
        // in fact required: two controllers would mean the page ran with
        // whichever one the configuration points at.
        controller.addUserScript(WKUserScript(source: script,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.add(self, name: "dshDesktop")
        attachedController = controller
        active = true
        Log.info("dsh desktop bridge attached")
    }

    /// The single most important lookup in this file.
    ///
    /// `Bundle.module` is deliberately not used: it exists only under SwiftPM,
    /// and this target is also built by XcodeGen, where it does not compile.
    /// `ResourceLocator` searches the `.app` layout and the SwiftPM sibling
    /// bundle instead. See ResourceLocator.swift.
    static func loadScript() -> String? {
        let bundle = Bundle.main
        guard let url = ResourceLocator.url(
            forResource: "dsh_desktop_bridge",
            withExtension: "js",
            in: bundle,
            container: ResourceLocator.defaultContainer(for: bundle)
        ), let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return source
    }

    // MARK: - Outgoing

    /// Push one `DesktopShortcutInput` into the listener dsh registered.
    ///
    /// Returns false when nothing is listening, so the caller can log rather
    /// than believe a shortcut fired. That distinction matters: a shortcut that
    /// silently does nothing is indistinguishable, from the keyboard, from a
    /// binding dsh no longer has.
    @discardableResult
    func dispatch(code: String, secondCode: String?, modifiers: NSEvent.ModifierFlags,
                  isRepeat: Bool) -> Bool {
        guard let webView, let revision = currentRevision else { return false }
        let input: [String: Any] = [
            "revision": revision,
            "kind": "keyboard",
            "frameName": "__dsh_shell_top__",
            "code": code,
            "control": modifiers.contains(.control),
            "alt": modifiers.contains(.option),
            "shift": modifiers.contains(.shift),
            "meta": modifiers.contains(.command),
            "repeat": isRepeat,
        ]
        var body = input
        if let secondCode { body["secondCode"] = secondCode }

        guard let json = try? JSONSerialization.data(withJSONObject: body),
              let literal = String(data: json, encoding: .utf8)
        else { return false }

        var dispatched = false
        webView.evaluateJavaScript(
            "window.__dshShellDesktop && window.__dshShellDesktop.dispatchShortcut(\(literal))"
        ) { value, _ in
            dispatched = (value as? Bool) == true
        }
        // `evaluateJavaScript` calls back on the main run loop, so spin it once.
        let deadline = Date().addingTimeInterval(0.25)
        while !dispatched && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return dispatched
    }

    /// Deliver a pending `shortcuts.get` / `edit` back into the page.
    private func resolve(requestId: String, ok: Bool, value: Any) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: value),
              let literal = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript(
            "window.__dshShellDesktop && window.__dshShellDesktop.resolveShortcuts(\(requestId), \(ok), \(literal))"
        ) { _, _ in }
    }

    /// Begin a native window drag from a `[data-window-drag]` row.
    ///
    /// The reported coordinates are only used to decide *which* row was pressed;
    /// the drag itself tracks the real cursor from the Window Server. They are
    /// logged rather than discarded because a drag that starts in the wrong place
    /// is otherwise impossible to diagnose.
    private func beginWindowDrag(screenX: Double, screenY: Double) {
        guard let window = webView?.window else { return }

        // AppKit's origin is bottom-left; the DOM reports top-left screen
        // coordinates. The reported position is not what drives the drag —
        // `NSEvent.mouseLocation` is the real cursor, which is what the Window
        // Server wants. Synthesising a whole drag ourselves (mouseDown,
        // mouseMoved…, mouseUp) would be both more code and a worse result: the
        // window would follow our synthetic positions rather than the user's
        // pointer, and it would not participate in Space switching or Mission
        // Control the way a real drag does.
        let point = NSEvent.mouseLocation

        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }

        // `performWindowDragWithEvent:` is the documented way to hand a mouseDown
        // to the Window Server so the window participates in the system's own
        // drag handling. Swift's Clang importer does not surface it on this SDK,
        // so it goes through the runtime.
        //
        // The selector is present: verified with `responds(to:)` and
        // `class_getInstanceMethod`, both of which succeed — it is implemented in
        // a category, which is why `class_copyMethodList` does not list it. The
        // guard is there so that a future OS which drops it degrades to a log
        // line rather than an unrecognised-selector crash.
        let selector = NSSelectorFromString("performWindowDragWithEvent:")
        guard window.responds(to: selector) else {
            Log.error("this macOS does not implement performWindowDragWithEvent:, so dsh's window-chrome rows cannot drag the window")
            return
        }
        window.perform(selector, with: down)
    }

    // MARK: - Keyboard interception

    /// The chords dsh will consume, or `nil` until its catalog is known.
    ///
    /// Recomputed from the catalog dsh passes to every `shortcuts.get` plus the
    /// accepted preferences, which is the same input `effectiveShortcuts` uses
    /// inside dsh. See ShortcutModel.
    private var dispatchKeys: Set<String>?
    private var definitions: [EffectiveShortcut.Definition] = []

    /// Intercept chords dsh has actually bound, and forward them.
    ///
    /// The filter is the whole design. Two wrong choices are available:
    ///
    /// - Swallow every mappable key. `dispatch` returns true whenever *any*
    ///   listener is registered, which it is for the whole session — so every
    ///   keystroke in the composer would be swallowed and the user could not
    ///   type at all.
    /// - Forward every key and never swallow. dsh's bindings would fire, and the
    ///   same chord would then act again natively: ⌘N twice, ⌘W closing the
    ///   window behind dsh's back.
    ///
    /// So the host asks the only question dsh's own code answers — is this chord
    /// in the binding table? — and answers it from data dsh supplied. An
    /// unbound chord is left entirely to AppKit and WebKit, which is also what
    /// keeps ⌘W, ⌘Q and ⌘C/V/X working as macOS users expect.
    ///
    /// While the catalog is unknown the monitor forwards nothing and swallows
    /// nothing. Holding a key for a moment until dsh's catalog arrives is a far
    /// better failure than a dead keyboard.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let webView = self.webView else { return event }
            // The page has to be the frontmost thing, or we would steal keys from
            // every other app that happens to be open behind it.
            guard webView.window?.isKeyWindow == true else { return event }

            guard let keys = self.dispatchKeys else { return event }
            guard let code = KeyCode.domCode(for: event.keyCode) else { return event }
            let modifiers = Self.modifiers(of: event)
            let key = ShortcutModel.bindingKey(ShortcutBinding(code: code, modifiers: modifiers))
            guard keys.contains(key) else { return event }

            // dsh's `dispatch` calls `consume()` for a matched binding, so the
            // host must swallow it too. The dispatch result only says whether a
            // listener existed, which by now is guaranteed.
            let dispatched = self.dispatch(code: code, secondCode: nil,
                                           modifiers: event.modifierFlags,
                                           isRepeat: event.isARepeat)
            // A repeat is only swallowed if the initial press was: swallowing a
            // repeat of a key dsh ignored would make the key feel stuck.
            return dispatched || !event.isARepeat ? nil : event
        }
    }

    /// The four modifiers dsh's `dispatch` reads, in its canonical order.
    ///
    /// `NSEvent.modifierFlags` also carries `.capsLock`, `.function`,
    /// `.numericPad` and the device-dependent bits. Passing those through would
    /// make every key with Caps Lock on look like a different chord.
    private static func modifiers(of event: NSEvent) -> [ShortcutModifier] {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return ShortcutModel.modifierOrder.filter { modifier in
            switch modifier {
            case .control: return flags.contains(.control)
            case .alt: return flags.contains(.option)
            case .shift: return flags.contains(.shift)
            case .meta: return flags.contains(.command)
            case .primary: return false
            }
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Recompute which chords to swallow, and say so when the answer changes.
    ///
    /// Logged because the two failure modes look identical from the keyboard: a
    /// chord that is forwarded and ignored, and one that is never forwarded at
    /// all, both present as a key that does nothing.
    private func refreshDispatchKeys() {
        let previous = dispatchKeys
        dispatchKeys = config.dispatchKeys()
        guard previous != dispatchKeys else { return }
        switch dispatchKeys {
        case .some(let keys):
            Log.info("""
                keyboard filter: \(keys.count) bound chord(s) across \
                \(definitions.count) command(s) — \(keys.sorted().prefix(6).joined(separator: ", "))\
                \(keys.count > 6 ? ", …" : "")
                """)
        case .none:
            Log.debug("keyboard filter not ready: dsh has not sent its command catalog yet")
        }
    }
}

// MARK: - Page → host

extension DshDesktopBridge: WKScriptMessageHandler {
    /// The protocol requires a `nonisolated` entry point, but `WKScriptMessage`'s
    /// `name` and `body` are main-actor isolated in this SDK, so they are read
    /// inside the hop rather than here.
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            guard message.name == "dshDesktop",
                  let text = message.body as? String,
                  let data = text.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = envelope["type"] as? String
            else { return }
            let payload = envelope["payload"] as? [String: Any] ?? [:]

            switch type {
            case "bridgeInstalled":
                let hasHost = payload["hasHost"] as? Bool ?? false
                let appRegion = payload["appRegion"] as? Bool ?? false
                Log.info("""
                    desktop bridge ready — host=\(hasHost) \
                    webkit-app-region=\(appRegion)\(appRegion ? "" : " (expected: WebKit has no such property, so drag rows need native forwarding)")
                    """)

            case "bootFailed":
                Log.error("dsh reported a boot failure: \(payload["reason"] ?? "?")")

            case "keyboardSubscribed":
                // Nothing to do yet, but it is the moment the revision starts
                // mattering, so it gets a line of its own.
                Log.debug("dsh subscribed to native keyboard input")

            case "shortcutsGet":
                let id = payload["id"] as? String ?? ""
                // dsh sends the *live* catalog with every registration — 28
                // calls measured, growing as modules activate — each one a
                // superset of the last. Taking the latest is what makes the
                // dispatch table complete; an earlier call would leave later
                // commands unbound.
                let raw = payload["definitions"] as? [[String: Any]] ?? []
                definitions = raw.compactMap(EffectiveShortcut.Definition.decode)
                // The store needs the catalog to accept an edit: dsh refuses to
                // bind a command it has not published a definition for.
                config.setDefinitions(definitions)
                let snapshot = config.readCurrent()
                currentRevision = snapshot.revision
                refreshDispatchKeys()
                resolve(requestId: id, ok: true, value: snapshot.dictionary)

            case "shortcutsEdit":
                let id = payload["id"] as? String ?? ""
                let outcome = config.applyEdit(payload["edit"] as? [String: Any] ?? [:],
                                               against: payload["revision"] as? String)
                if outcome.snapshot.revision != currentRevision {
                    currentRevision = outcome.snapshot.revision
                    // dsh rejects anything but its own current revision, so a
                    // stale one here means every keystroke would be dropped
                    // without a word.
                    if let webView {
                        webView.evaluateJavaScript(
                            "window.__dshShellDesktop && window.__dshShellDesktop.publishShortcuts(\(outcome.snapshot.jsLiteral))"
                        ) { _, _ in }
                    }
                    refreshDispatchKeys()
                }
                resolve(requestId: id, ok: true, value: outcome.resultDictionary)

            case "closeWindow":
                // dsh sends the revision and offers to close only "if its
                // configuration is still current". We do not check it, and
                // should not: the window is ours to close, and a stale
                // revision here would only produce a window the user cannot
                // get rid of by keyboard.
                //
                // Logged because this path is easy to break invisibly. dsh
                // owns `meta+KeyW` on macOS, so the shell's own Close Window
                // item never runs — if this stops firing, ⌘W is dead and
                // nothing else would say so.
                let window = webView?.window
                Log.info("closeWindow: dsh requested it (revision \(payload["revision"] as? String ?? "-")), performing close on \(window?.windowNumber.description ?? "no window")")
                window?.performClose(nil)

            case "beginWindowDrag":
                beginWindowDrag(screenX: payload["screenX"] as? Double ?? 0,
                                screenY: payload["screenY"] as? Double ?? 0)

            default:
                Log.debug("unhandled desktop bridge message: \(type)")
            }
        }
    }
}