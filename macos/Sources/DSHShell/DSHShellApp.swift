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
                .onDisappear { appDelegate.coordinator.shutdown() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About dsh-swiftUI") {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdownBlocking()
    }
}