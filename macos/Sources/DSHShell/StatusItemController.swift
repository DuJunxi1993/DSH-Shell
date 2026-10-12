import AppKit
import SwiftUI
import DSHShellCore

/// The menu-bar item: how you get a hidden window back.
///
/// The window has no caption of its own — the titlebar is transparent and dsh
/// paints under it — so ⌘W and the traffic-light ✕ are not a complete set of
/// ways out. A status item is the one that does not depend on the window being
/// visible, which is the whole reason the Windows shell needs a tray for the
/// same job.
///
/// Three items, and no more: put the window back, put the zoom back, and leave
/// for real. A menu that grows is a menu nobody reads.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var coordinator: AppCoordinator?
    private var observers: [NSObjectProtocol] = []

    /// Called when the user picks 退出. Runs the same shutdown path as ⌘Q.
    var onQuit: (() -> Void)?

    /// Tearing the observer down explicitly rather than in `deinit`: a
    /// `@MainActor` class cannot touch its own state from a nonisolated
    /// deinit, and an observer that outlives its controller keeps the closure —
    /// and everything it captured — alive for the life of the process. The
    /// controller is owned by the app delegate for the app's whole lifetime, so
    /// this runs once, at the end, and that is exactly once.
    func uninstall() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        install()
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.templateIcon()
        item.button?.toolTip = "DSH Shell"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "显示 / 隐藏", action: #selector(toggleWindow), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "缩放复位 100%", action: #selector(resetZoom), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出（关闭 dsh）", action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
        statusItem = item

        // Keep the item's title in step with the connection state, so "dsh is
        // gone" is visible from the menu bar without opening the window.
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .dshShellStateChanged, object: nil, queue: .main) {
                [weak self] _ in self?.refreshTitle()
            })
        refreshTitle()
    }

    /// A template image, or nothing.
    ///
    /// A multicolour image in the menu bar is not recoloured for light and dark,
    /// which is why dsh's whale mark cannot be used here as-is. A template image
    /// is; an SF Symbol is already one.
    private static func templateIcon() -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "terminal", accessibilityDescription: "DSH Shell")
        else { return nil }
        symbol.isTemplate = true
        return symbol
    }

    private func refreshTitle() {
        guard let button = statusItem?.button else { return }
        let state = coordinator?.state
        switch state {
        case .ready:
            button.title = ""
            button.toolTip = "DSH Shell — dsh 已就绪"
        case .failed:
            button.title = "!"
            button.toolTip = "DSH Shell — 连接已断开"
        case .shuttingDown:
            button.title = "…"
            button.toolTip = "DSH Shell — 正在关闭 dsh"
        default:
            button.title = "…"
            button.toolTip = "DSH Shell — 正在启动"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshTitle()
        for item in menu.items where item.action == #selector(resetZoom) {
            item.isEnabled = (coordinator?.zoomPercent ?? 100) != 100
        }
    }

    // MARK: - Actions

    /// Show or hide the main window.
    ///
    /// Restoring goes through ``AppCoordinator/showMainWindow``, not through
    /// `NSWindow`. That is the whole fix for the item that "minimised instead of
    /// hiding, and could not bring the window back after ⌘W":
    ///
    /// - The window belongs to a SwiftUI `WindowGroup` scene. Closing it — red
    ///   button, ⌘W, or dsh's own `closeWindow` — destroys the `NSWindow` object
    ///   while the scene survives. A `weak` reference to it is `nil` from that
    ///   moment on.
    /// - The old code then fell back to `NSApp.windows.first`, which by then is
    ///   either empty or the settings window, and called
    ///   `makeKeyAndOrderFront` on it. That cannot re-create a window whose scene
    ///   has no window.
    /// - Hiding with `orderOut` is also what produced the "it minimised"
    ///   impression: an app with no key window and a live Dock icon looks
    ///   exactly like a minimise.
    ///
    /// So there is one restore path, and it is the one macOS itself uses for
    /// ⌘-clicking the Dock icon — which is why that always worked.
    @objc private func toggleWindow() {
        guard let coordinator else { return }
        if coordinator.isMainWindowVisible {
            // Deliberately `orderOut` and not `miniaturize`: minimising leaves a
            // window in the Dock's window list, which is a different thing and
            // harder to get back than this one.
            coordinator.mainWindow?.orderOut(nil)
        } else {
            coordinator.showMainWindow()
        }
    }

    @objc private func resetZoom() {
        coordinator?.setZoom(100)
    }

    @objc private func quit() {
        // The same path ⌘Q takes, so the tray cannot become a third exit that
        // skips the tree kill — the thing `AGENTS.md` rule 1 is about.
        onQuit?()
    }

    /// The shell's own window.
    ///
    /// `NSApp.windows.first` is every window in the app, in z-order, so it can be
    /// the sessions panel or a sheet. `AppCoordinator.mainWindow` is set by the
    /// web surface when it is attached to a window, which is what "the main
    /// window" actually means here.
    ///
    /// Kept for callers that need the live `NSWindow` — hiding is an `NSWindow`
    /// operation and cannot be expressed as "show", so the two directions
    /// legitimately differ. What must not happen is *restoring* through this:
    /// see `toggleWindow`.
    var mainWindow: NSWindow? {
        coordinator?.mainWindow
    }
}

// MARK: - State notification

extension Notification.Name {
    /// Posted whenever the coordinator's connection state changes, so UI that
    /// is not directly observing it (the status item) can stay in step.
    static let dshShellStateChanged = Notification.Name("ai.deepseek.dsh-shell.stateChanged")
}