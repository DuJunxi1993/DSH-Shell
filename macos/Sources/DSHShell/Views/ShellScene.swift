import SwiftUI
import DSHShellCore
import OSLog

/// Top-level scene. Shows one of three states: a loading overlay, the WKWebView,
/// or an error view with a retry button. The connection status badge floats in
/// the middle of the (transparent) titlebar, without a toolbar or any material.
struct ShellScene: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var showReadyToast = false
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            background
            content
            readyToast
        }
        .background(TitlebarConfiguringView())
        .onChange(of: coordinator.state) { _, newState in
            if case .ready = newState {
                presentReadyToast()
            }
        }
        .onReceive(coordinator.$webSession) { session in
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            if let title = session.title, !title.isEmpty {
                window.title = "\(title) — dsh"
            } else {
                window.title = "dsh"
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .ready(let url):
            WebSurfaceView(url: url, bridgeClient: coordinator)
                .ignoresSafeArea(edges: [.top, .bottom])
        case .failed(let reason):
            ErrorView(reason: reason) {
                coordinator.reload()
            }
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
    private let logger = Logger(subsystem: "ai.deepseek.dsh-shell", category: "Titlebar")

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
        // appears to shrink for a frame or two. Re-asserting the style mask
        // synchronously from these notifications happens before the next
        // frame composes, so the flash never becomes visible. The timer
        // remains as a backstop for rebuilds/restoration.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.applyConfiguration()
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.applyConfiguration()
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.applyConfiguration()
            }
        ]

        watchdog?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.applyConfiguration()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    fileprivate func applyConfiguration() {
        guard let window else { return }
        let hadFull = window.styleMask.contains(.fullSizeContentView)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        if !hadFull {
            logger.debug("re-asserted fullSizeContentView (title \(window.title, privacy: .public))")
        }
        let contentH = window.contentView?.frame.height ?? -1
        let windowH = window.frame.height
        logger.debug("tick mask=\(String(window.styleMask.rawValue), privacy: .public) transparent=\(window.titlebarAppearsTransparent, privacy: .public) content=\(contentH) window=\(windowH)")
    }
}