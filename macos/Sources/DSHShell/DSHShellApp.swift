import SwiftUI
import DSHShellCore
import UserNotifications

@main
struct DSHShellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("dsh") {
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
                    openWindow(id: "sessions")
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
            // Zoom lives in View, not in a shell-specific group, because
            // ⌘+/- is where a Mac user expects it and because WebKit answers
            // ⌘+ itself — these items set the same state the webview reports
            // back, so the two cannot drift apart.
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    appDelegate.coordinator.stepZoom(10)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") {
                    appDelegate.coordinator.stepZoom(-10)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") {
                    appDelegate.coordinator.setZoom(100)
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

        WindowGroup(id: "sessions") {
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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