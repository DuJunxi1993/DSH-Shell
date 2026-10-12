import SwiftUI
import DSHShellCore
import UserNotifications

@main
struct DSHShellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // `Window`, not `WindowGroup`. A `WindowGroup` scene exists precisely so the
        // app can have several instances of it, and `openWindow(id:)` takes that
        // up: every request opens another one. The status item's "show" did
        // exactly that, so each press added a window — each with its own
        // `WKWebView`, its own bridge attach, and its own live connection to
        // dsh. Six presses, six conversations, one dsh.
        //
        // `Window` is the single-instance scene: opening it again focuses the
        // window that is already there. That is the whole point of this app, and
        // it is now stated by the type rather than enforced by hope.
        Window(MainScene.title, id: MainScene.id) {
            ShellScene()
                .environmentObject(appDelegate.coordinator)
                .frame(minWidth: 800, minHeight: 600)
                .onAppear { appDelegate.coordinator.start() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About DSH Shell") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    appDelegate.coordinator.webNewSession()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Sessions…") {
                    openWindow(id: MainScene.sessionsID)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Button("Reload dsh") {
                    appDelegate.coordinator.reload()
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button("Focus Composer") {
                    appDelegate.coordinator.webFocusComposer()
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Send Message") {
                    appDelegate.coordinator.webSendMessage()
                }
                .keyboardShortcut(.return, modifiers: .command)
                Button("Open Workspace…") {
                    appDelegate.coordinator.webOpenWorkspace()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            // The zoom *ladder* lives in the status item's menu, which is an
            // `NSMenu` and can hold a real submenu. It cannot live here: SwiftUI's
            // main menu bar has no nested-menu support at all — a `Menu` is a
            // `View`, not `Commands`, so putting one in `.commands` does not
            // compile. The step that macOS users actually reach for stays.
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    appDelegate.coordinator.stepZoom(ZoomLadder.step)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") {
                    appDelegate.coordinator.stepZoom(-ZoomLadder.step)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") {
                    appDelegate.coordinator.setZoom(ZoomLadder.default)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(after: .windowList) {
                Button("Open Preferences…") {
                    appDelegate.coordinator.showPreferences()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }

        // Same reasoning as the main scene: one sessions panel, focused rather than
        // duplicated. `WindowGroup` here would let every click of "Sessions…"
        // stack another panel.
        Window(MainScene.sessionsTitle, id: MainScene.sessionsID) {
            SessionPanelView()
        }
        .windowResizability(.contentMinSize)

        Settings {
            PreferencesView()
                .environmentObject(appDelegate.coordinator)
        }
    }
}

/// Owns the single `AppCoordinator` for the app's lifetime. A plain `let`
/// on the (reference-type) delegate guarantees the view tree, the scene
/// closures, and `applicationWillTerminate` all touch the same instance —
/// `@StateObject` inside an `App` struct is re-created when SwiftUI
/// re-instantiates the struct, silently splitting state across instances.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    /// Held for the app's lifetime: releasing the lock mid-run would let a
    /// second copy start while this one is still holding the port.
    private var instanceGuard: SingleInstanceGuard?
    private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before anything else, so there is no window in which two instances can
        // both be alive. Two shells racing for the same port means the loser
        // dies with "address already in use", which is a confusing way to learn
        // that the app is already running.
        if let acquired = SingleInstanceGuard() {
            instanceGuard = acquired
        } else {
            Log.info("another instance already holds the lock; raising it")
            _ = SingleInstanceGuard.activateRunningInstance()
            NSApp.terminate(nil)
            return
        }
        Log.info("DSH Shell starting; logs in \(FileLogger.shared.directoryPath)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The result is worth recording. The notification shim reports whatever
        // macOS actually decided, so an app that has never been granted this
        // makes `dsh-notification` inert — silently, because the plugin's own
        // failure message is a string nobody reads. Without this line the log
        // says "notifications: denied" and leaves the question of *why* open.
        //
        // `requestAuthorization` only ever prompts once per app. After a refusal
        // macOS will not ask again, and the grant has to be made in System
        // Settings → Notifications. The log line is how that gets noticed.
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                // `Task { @MainActor }`, not `assumeIsolated`. This completion
                // arrives on an internal queue, not the main thread, and
                // `assumeIsolated` traps when the isolation it asserts is not
                // there — which killed the app on launch, before a window.
                Task { @MainActor in
                    if let error {
                        Log.error("notification authorisation failed: \(error.localizedDescription)")
                    } else {
                        Log.info(granted
                                 ? "notifications authorised — page notifications will be delivered"
                                 : "notifications not authorised; grant them in System Settings → Notifications, "
                                 + "or plugins that raise them will stay silent")
                    }
                }
            }
        statusItem = StatusItemController(coordinator: coordinator)
        statusItem?.onQuit = { [weak self] in self?.quit() }
    }

    /// The real exit, from ⌘Q and from the status item alike.
    ///
    /// Both go through `applicationWillTerminate`, which runs the same shutdown
    /// path — a second exit that skipped the tree kill would be exactly the
    /// third way out `AGENTS.md` rule 1 warns about.
    func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdownBlocking()
        statusItem?.uninstall()
        FileLogger.shared.flush()
        Log.info("DSH Shell exiting")
    }
}