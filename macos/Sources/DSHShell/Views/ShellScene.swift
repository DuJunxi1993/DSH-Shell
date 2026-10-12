import SwiftUI
import AppKit
import DSHShellCore

/// Identifies the main scene across the app: `Window(_:id:)` here, and
/// `openWindow(id:)` from the status item.
///
/// The title is what the Window menu shows before a session sets its own, so it
/// is the user-facing name rather than the identifier.
enum MainScene {
    static let id = "dsh"
    static let title = "dsh"

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
            // this app can have the settings panel open at the same time, and
            // that lookup can return the panel, sending the title to the wrong
            // window.
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
