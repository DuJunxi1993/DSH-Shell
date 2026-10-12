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
        // Not `squareLength`: the whale is landscape (23.40 × 17.19 in dsh's own
        // units), and a square slot would either squash it or leave the padding
        // looking like a bug. A variable-length button fits the mark and still
        // keeps the click target a comfortable size thanks to the 2pt inset.
        let item = NSStatusBar.system.statusItem(withLength: FishLogoImage.width + 4)
        item.button?.image = Self.templateIcon()
        item.button?.toolTip = "DSH Shell"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "显示 / 隐藏", action: #selector(toggleWindow), keyEquivalent: "")
            .target = self
        menu.addItem(zoomSubmenu())
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
                [weak self] _ in MainActor.assumeIsolated { self?.refreshTitle() }
            })
        refreshTitle()
    }

    /// Every zoom rung, as a submenu of the status item.
    ///
    /// A submenu rather than "放大/缩小" because the ladder has sixteen rungs and
    /// the ones worth reaching are not adjacent: 50% for a dense log, 200% for
    /// small text across the room. Stepping there one 10% press at a time is the
    /// reason the ladder used to stop at 100 — the far rungs were not worth
    /// walking to.
    ///
    /// Built from `ZoomLadder.rungs` so it cannot offer a percentage that
    /// ⌘+/- could never produce.
    private func zoomSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.title = "缩放"

        for rung in ZoomLadder.rungs {
            let item = NSMenuItem(title: "\(rung)%", action: #selector(setZoom(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rung
            // A radio group rather than plain checks: exactly one rung is ever
            // set, and the menu items are not toggles.
            item.state = (rung == coordinator?.zoomPercent) ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let reset = NSMenuItem(title: "实际大小 (100%)", action: #selector(resetZoom), keyEquivalent: "")
        reset.target = self
        submenu.addItem(reset)

        parent.submenu = submenu
        return parent
    }

    /// A template image, or nothing.
    ///
    /// A multicolour image in the menu bar is not recoloured for light and dark,
    /// dsh's own whale, drawn as a template image so AppKit handles light and
    /// dark appearances. `FishLogoImage` explains why a coloured SVG is not
    /// usable here and why redrawing the shape is.
    private static func templateIcon() -> NSImage? {
        FishLogoImage.make()
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

    /// Re-stamped every time the menu opens, because the zoom can be changed
    /// from three places — here, ⌘+/⌘-, and the settings field — and a checkmark
    /// frozen at launch is worse than none.
    func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            refreshTitle()
            refreshZoomChecks(in: menu)
        }
    }

    private func refreshZoomChecks(in menu: NSMenu) {
        let current = coordinator?.zoomPercent ?? ZoomLadder.default
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            for rung in submenu.items {
                guard let value = rung.representedObject as? Int else { continue }
                rung.state = (value == current) ? .on : .off
            }
            for rung in submenu.items where rung.action == #selector(resetZoom) {
                rung.isEnabled = current != ZoomLadder.default
            }
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
            coordinator.hideMainWindow()
        } else {
            coordinator.showMainWindow()
        }
    }

    /// Pick one rung. `representedObject` carries the number because the title
    /// is a localised string and "50%" is not a number anyone should parse back
    /// out of it.
    @objc private func setZoom(_ sender: NSMenuItem) {
        guard let rung = sender.representedObject as? Int else { return }
        coordinator?.setZoom(rung)
    }

    @objc private func resetZoom() {
        coordinator?.setZoom(ZoomLadder.default)
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