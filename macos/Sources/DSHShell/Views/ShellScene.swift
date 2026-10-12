import SwiftUI
import AppKit
import DSHShellCore
import OSLog

/// Identifies the main scene across the app: `Window(_:id:)` here, and
/// `openWindow(id:)` from the status item.
///
/// The titles are what the Window menu shows before a session sets its own, so
/// they are the user-facing names rather than the identifiers.
enum MainScene {
    static let id = "dsh"
    static let title = "dsh"

    static let sessionsID = "sessions"
    static let sessionsTitle = "Sessions"
}

/// Top-level scene. Shows one of three states: a loading overlay, the WKWebView,
/// or an error view with a retry button. The connection status badge floats in
/// the middle of the (transparent) titlebar, without a toolbar or any material.
struct ShellScene: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var showReadyToast = false
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            background
            content
            readyToast
        }
        .background(TitlebarConfiguringView())
        .onAppear {
            // The scene is the only place `openWindow` resolves correctly, so
            // the coordinator borrows it rather than trying to find a window by
            // itself. See `AppCoordinator.showMainWindow`.
            coordinator.adopt { openWindow(id: MainScene.id) }
        }
        .onChange(of: coordinator.state) { _, newState in
            if case .ready = newState {
                presentReadyToast()
            }
        }
        .onReceive(coordinator.$webSession) { session in
            // The window this scene is actually in, not `NSApp.windows.first`:
            // with a sessions panel open that lookup can return the panel, and
            // the title would follow the wrong window.
            guard let window = coordinator.mainWindow else { return }
            if let title = session.title, !title.isEmpty {
                window.title = "\(title) — DSH Shell"
            } else {
                window.title = "DSH Shell"
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .ready(let url):
            WebSurfaceView(url: url, bridgeClient: coordinator,
                           zoomPercent: coordinator.zoomPercent,
                           allowedOrigin: URLOrigin.of(url),
                           desktopBridge: coordinator.desktopBridge,
                           onWindowResolved: { coordinator.attach(window: $0) })
                .ignoresSafeArea(edges: [.top, .bottom])
        case .failed(let reason):
            ErrorView(reason: reason,
                      orphans: coordinator.leftoverProcesses,
                      onRetry: { coordinator.reload() },
                      onCloseOrphans: { coordinator.closeLeftoversAndRetry() })
        case .shuttingDown:
            LoadingView(title: "Shutting down dsh…")
        case .launching:
            LoadingView(title: "Launching dsh web…")
        case .connecting:
            LoadingView(title: "Connecting to existing dsh instance…")
        case .idle:
            LoadingView(title: "Idle")
        }
    }

    private var background: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }

    /// Transient confirmation that appears at the loading view's position
    /// (window centre) after a successful startup, then fades away. There is
    /// no persistent status indicator: the traffic lights and the page itself
    /// carry the ongoing state.
    private var readyToast: some View {
        Group {
            if showReadyToast {
                Text("dsh 已就绪")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(.regularMaterial))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func presentReadyToast() {
        toastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { showReadyToast = true }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { showReadyToast = false }
        }
    }
}

/// Re-asserts the transparent-titlebar configuration whenever the view is
/// attached to a window. Configuring once in `makeNSView` is not enough:
/// SwiftUI can rebuild or re-attach windows (restore, fullscreen, state
/// transitions) and silently drop the `.fullSizeContentView` style mask,
/// which makes the titlebar opaque and shrinks the content back below it.
///
/// The re-assertion writes each property **only when it differs** from what the
/// window already has. Writing unconditionally fixed the AppKit revert but
/// introduced the exact flash it was meant to prevent: every write is a setter
/// call, AppKit relayouts the titlebar for it, and the observers below fire on
/// every key-state change and resize. The result was a one-frame opaque strip
/// across the top of the window whenever it was switched to or minimised.
///
/// So the notifications and the timer stay — they are still what catches a real
/// revert — and the writes became conditional, which keeps the protection while
/// leaving the steady state silent.
private struct TitlebarConfiguringView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = TitlebarConfiguringNSView()
        view.applyConfiguration()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TitlebarConfiguringNSView)?.applyConfiguration()
    }
}

private final class TitlebarConfiguringNSView: NSView {
    private var watchdog: Timer?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else {
            watchdog?.invalidate()
            watchdog = nil
            return
        }
        applyConfiguration()

        // AppKit briefly reverts the content rect to "below the titlebar"
        // during key-state transitions of a fullSizeContentView window (a
        // known glitch): the titlebar strip flashes opaque and the page
        // appears to shrink for a frame or two. These notifications, and the
        // timer below, are what catch that: `applyConfiguration` puts the style
        // mask back before the next frame composes. With the conditional writes
        // it only touches AppKit when the revert actually happened, so the fix
        // costs nothing in the steady state.
        //
        // `MainActor.assumeIsolated` rather than hopping through a `Task`: the
        // whole point of these callbacks is to re-assert the style mask
        // *before the next frame composes*, and a task hop gives that frame
        // away. `queue: .main` above is what makes the assertion sound — these
        // are main-queue deliveries, so the isolation holds.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyConfiguration() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyConfiguration() }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyConfiguration() }
            },
        ]

        watchdog?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.applyConfiguration() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    fileprivate func applyConfiguration() {
        guard let window else { return }
        // Each property is set only if it is not already in the target state. A
        // setter call is never free — `styleMask` and the two titlebar flags
        // each make AppKit re-lay-out the titlebar — and the observers call in
        // on every key-state change and resize, so redundant writes are what
        // make the titlebar flash.
        var repaired: [String] = []

        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
            repaired.append("fullSizeContentView")
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
            repaired.append("transparent")
        }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
            repaired.append("hiddenTitle")
        }

        // Only speak up when something was actually wrong; the steady state is
        // silent so a busy log is not mistaken for a busy window.
        //
        // `Log.debug` rather than a bare `Logger`: a bare `Logger` only reaches
        // the unified log, which is unreadable after the fact. The old
        // per-tick line was on one of those, so it left no trace in the file and
        // this repair could not be observed at all — the silence that hid the
        // regression is what made it look verified.
        if !repaired.isEmpty {
            Log.debug("titlebar re-asserted [\(repaired.joined(separator: ","))] title=\(window.title)")
        }
    }
}