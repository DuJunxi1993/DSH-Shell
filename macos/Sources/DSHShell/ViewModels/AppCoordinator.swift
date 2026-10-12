import Foundation
import SwiftUI
import DSHShellCore
import OSLog
import UserNotifications
import AppKit

/// State reported by the dsh SPA through the injected bridge script.
struct WebSessionState: Equatable {
    var title: String?
    var agentRunning: Bool = false
}

/// Bridges the SwiftUI shell to the underlying `DSHProcessManager`. Owns the
/// process lifecycle for the lifetime of the app and exposes the connection
/// state to the view tree.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var state: ConnectionState = .idle {
        didSet {
            // Anything that is not directly observing the state — the status
            // item — needs to be told, and a `didSet` on the single source of
            // truth is the only place that cannot drift out of step with it.
            NotificationCenter.default.post(name: .dshShellStateChanged, object: nil)
        }
    }
    @Published var settings: ShellSettings = .default
    @Published var consoleLines: [ConsoleLine] = []
    @Published var isPresentingPreferences: Bool = false
    /// Leftovers from an earlier run that would block a launch, offered to the
    /// user on the error screen. Empty unless the failure was a port collision
    /// and something is genuinely provably ours — see `PortOccupant`.
    @Published var leftoverProcesses: [PortOccupant] = []
    @Published var webSession: WebSessionState = .init()
    /// Page zoom, 50–100 in 10% steps. Persisted in settings so it survives a
    /// relaunch, and read back from there rather than kept separately — two
    /// copies of a preference is a preference that eventually disagrees with
    /// itself.
    @Published var zoomPercent: Int = 100
    /// The window the web surface is attached to. Set by `WebSurfaceView`, read
    /// by the title updater, which may not assume `NSApp.windows.first` is the
    /// right one.
    ///
    /// **Not** the way to get a window back. It is a `weak` reference to an
    /// `NSWindow` a SwiftUI scene owns, and closing that window destroys the
    /// object while the scene survives — so it is `nil` for as long as the user
    /// has the window closed, and re-created from nothing afterwards. Anything
    /// that needs "show the window" must go through ``showMainWindow()``.
    private(set) weak var mainWindow: NSWindow?

    /// Brings the main scene back, whatever state it is in.
    ///
    /// Captured from `ShellScene`, where `@Environment(\.openWindow)` resolves
    /// against the scene that owns the window. `openWindow(id:)` is idempotent
    /// for an existing window — it orders it front rather than making a second
    /// one — and it re-creates a window whose scene outlived it.
    private var openMainScene: (() -> Void)?

    private let store: SettingsStore
    private var manager: DSHProcessManager?
    /// The task driving `runLifecycle`. Cancelled and cleared only by an
    /// explicit teardown — see `stopLifecycle()`.
    private var lifecycleTask: Task<Void, Never>?
    /// The task consuming the manager's event stream. Stored for the same
    /// reason: it used to be discarded, so a `reload()` left the previous
    /// manager's stream being drained by a task nobody could stop.
    private var eventTask: Task<Void, Never>?
    /// Whether a lifecycle is currently in flight.
    ///
    /// This is deliberately *not* derived from `lifecycleTask != nil`. The
    /// original `start()` guarded on the task handle being nil, but
    /// `runLifecycle()` returned without clearing it, so the guard latched shut
    /// after the first launch: ⌘R and Preferences→Apply killed dsh, called
    /// `start()`, got an immediate no-op, and left the window on
    /// "Shutting down dsh…" until the app was restarted.
    private var lifecycleRunning = false
    private var lastURL: URL?
    private var lastChildPID: Int32?
    private var bridge: WebBridge?
    /// The dsh desktop-host contract. App-lifetime, because it owns a key
    /// monitor that must be released explicitly on quit and must not be tied to
    /// any one view's lifetime.
    let desktopBridge = DshDesktopBridge()
    private var agentWasRunning = false
    private var agentRunningSince: Date?
    private let logger = Logger(subsystem: "ai.deepseek.dsh-shell", category: "AppCoordinator")

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        let loaded = store.load()
        self.settings = loaded
        // Seed from the persisted value rather than defaulting to 100 and
        // writing that back on the first zoom change, which would silently reset
        // a user who had chosen 70%.
        self.zoomPercent = ZoomLadder.snap(loaded.zoomPercent)
    }

    func start() {
        guard !lifecycleRunning else {
            logger.debug("start() ignored — a lifecycle is already running")
            return
        }
        lifecycleRunning = true
        lifecycleTask = Task { [weak self] in
            await self?.runLifecycle()
        }
    }

    func shutdown() {
        Task { @MainActor in await stopLifecycle() }
    }

    /// Stop the current lifecycle, if any, and wait for the teardown to finish.
    ///
    /// Everything the previous version did from `reload()` and `shutdown()`,
    /// in one place, and awaited: cancel the lifecycle task, cancel the event
    /// consumer, stop the manager (which terminates dsh), then clear the
    /// references. Clearing `manager` matters — a reused manager still holding
    /// `process != nil` would refuse the next `start()` with `alreadyRunning`.
    private func stopLifecycle() async {
        lifecycleRunning = false
        lifecycleTask?.cancel()
        lifecycleTask = nil
        eventTask?.cancel()
        eventTask = nil
        if let manager {
            await manager.stop()
        }
        manager = nil
        lastChildPID = nil
    }

    /// Blocking shutdown for `applicationWillTerminate`. The process exits
    /// immediately after the delegate returns, and by then the Swift
    /// concurrency runtime is being torn down, so neither unstructured nor
    /// detached `Task`s reliably get to run `manager.stop()` (observed: the
    /// stop never executed and the child dsh web was orphaned). Instead we
    /// signal the tracked child PID synchronously with `kill`/`waitpid` —
    /// plain syscalls that cannot be dropped by teardown — and only then
    /// attempt the best-effort actor cleanup.
    func shutdownBlocking() {
        desktopBridge.removeKeyMonitor()
        lifecycleRunning = false
        lifecycleTask?.cancel()
        lifecycleTask = nil
        eventTask?.cancel()
        eventTask = nil
        let pid = manager?.currentChildPID() ?? lastChildPID
        if let pid {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) != 0 { break }
                usleep(100_000)
            }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGKILL)
            }
        }
        if let manager {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await manager.stop()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1)
        }
        manager = nil
    }

    func reload() {
        Task { @MainActor in
            self.state = .shuttingDown
            await self.stopLifecycle()
            self.consoleLines.removeAll()
            self.leftoverProcesses = []
            self.state = .idle
            self.start()
        }
    }

    /// Look for leftovers and publish the ones that can be shown to be ours.
    ///
    /// Called only on a failed start, so two runs of `lsof` cost nothing next
    /// to a launch the user is watching fail.
    func refreshLeftoverProcesses() {
        let occupants = PortOccupant.occupants(ofPort: settings.preferredPort,
                                                binaryPath: settings.dshBinaryPath)
        let orphans = occupants.filter(\.isOrphan)
        leftoverProcesses = orphans
        guard !occupants.isEmpty else { return }
        // Named in the log whether or not anything qualifies: "something holds
        // the port but it is not ours" is what stops a user retrying forever.
        Log.info("port \(settings.preferredPort) is held by \(occupants.count) process(es); "
                 + "\(orphans.count) are this app's own leftovers")
        for occupant in occupants where !occupant.isOrphan {
            Log.info("not touching pid \(occupant.pid): \(explanation(of: occupant))")
        }
    }

    private func explanation(of occupant: PortOccupant) -> String {
        switch occupant.verdict {
        case .orphan: return "provably this app's leftover"
        case .notOrphan(let reason): return reason.explanation
        }
    }

    /// Close the leftovers the user has been shown, then start again.
    ///
    /// Signals nothing but the PIDs `PortOccupant` proved are leftovers, and
    /// says so before doing it. If one refuses to close the retry is attempted
    /// anyway: the screen simply comes back listing whatever is left.
    func closeLeftoversAndRetry() {
        let targets = leftoverProcesses
        guard !targets.isEmpty else { reload(); return }
        for occupant in targets {
            let stopped = PortOccupant.terminate(pid: occupant.pid)
            Log.info(stopped
                     ? "closed leftover pid \(occupant.pid)"
                     : "could not close leftover pid \(occupant.pid); it may already be gone")
        }
        reload()
    }

    func saveSettings(_ new: ShellSettings) {
        self.settings = new
        store.save(new)
    }

    func showPreferences() {
        isPresentingPreferences = true
    }

    // MARK: - Window and page

    func attach(window: NSWindow?) {
        mainWindow = window
    }

    /// Adopts the scene's own `openWindow` action, supplied by `ShellScene`.
    ///
    /// The status item cannot build this itself: `OpenWindowAction` only exists
    /// as an `Environment` value inside a view, and the status item is not in
    /// one. Handing it up from the scene is the supported route.
    func adopt(openMainScene: @escaping () -> Void) {
        self.openMainScene = openMainScene
    }

    /// Put the main window on screen.
    ///
    /// **An existing window is raised. A new one is only created when there is
    /// none** — and that branch is the whole reason this is two steps rather than
    /// an unconditional `openWindow(id:)`.
    ///
    /// Both callers used to take the unconditional path, and both could not work:
    ///
    /// - The menu-bar item did `NSApp.windows.first?.makeKeyAndOrderFront`. A
    ///   closed scene keeps no `NSWindow` — it is deallocated — so that found
    ///   nothing, or found the settings window, and the click did nothing. The
    ///   "it minimises instead of hiding" impression was the same bug from the
    ///   other side: `orderOut` leaves the app with no key window and a live Dock
    ///   icon, which is what a minimise looks like.
    /// - Switching to `openWindow(id:)` fixed that and broke the next thing: on a
    ///   `WindowGroup` scene, *every* call opens another window. Each press of the
    ///   menu item added one, with its own `WKWebView` and its own dsh connection.
    ///
    /// So the window that is already on screen is raised directly — which is what
    /// the user asked for and what no scene type can take away — and
    /// `openWindow(id:)` is left to do the only job it is still needed for,
    /// which is making a window where none exists.
    ///
    /// Clicking the Dock icon goes through `applicationShouldHandleReopen`
    /// instead, which macOS and SwiftUI agree on; it is not reimplemented here.
    func showMainWindow() {
        if let window = mainWindow {
            // Read before raising. After `makeKeyAndOrderFront` it is true by
            // definition, so logging it afterwards says nothing — and "visible:
            // true" on every line is exactly the shape a log has when the
            // branch above it is dead.
            let wasVisible = window.isVisible
            window.makeKeyAndOrderFront(nil)
            Log.info("showMainWindow: raised window #\(window.windowNumber) "
                     + "(was \(wasVisible ? "visible" : "hidden"), "
                     + "\(Self.visibleWindowCount) visible window(s))")
        } else {
            openMainScene?()
            Log.info("showMainWindow: no window exists, asked the scene to make one "
                     + "(\(Self.visibleWindowCount) visible window(s))")
        }
        NSApp.activate()
    }

    /// Takes the main window off screen without destroying it.
    ///
    /// `orderOut` rather than `miniaturize`: a minimised window stays in the
    /// Dock's window list, which is a different thing to have to undo.
    func hideMainWindow() {
        guard let window = mainWindow else { return }
        window.orderOut(nil)
        Log.info("hideMainWindow: hid window #\(window.windowNumber) "
                 + "(\(Self.visibleWindowCount) visible window(s))")
    }

    /// On-screen windows belonging to this app, excluding ordered-out and
    /// SwiftUI-internal ones.
    ///
    /// `NSApp.windows.count` is not this: it counts every window the app has ever
    /// had, including hidden ones and the ones SwiftUI keeps around, so it read
    /// "7" on a build that had exactly one window on screen. A number that does
    /// not mean what it looks like is worse than no number in a diagnostic.
    private static var visibleWindowCount: Int {
        NSApp.windows.filter(\.isVisible).count
    }

    /// Whether the main window is currently on screen.
    ///
    /// Read through ``mainWindow`` when it exists, and answered as `false` when
    /// it does not: a scene with no window is not a window that is hidden.
    var isMainWindowVisible: Bool {
        guard let window = mainWindow else { return false }
        return window.isVisible
    }

    /// Step the page zoom, snapped to the ladder.
    ///
    /// The ladder lives here and nowhere else, for the reason it lives in
    /// `config.rs` on the Windows side: the status item's "reset" item and the
    /// menu's −/+ both need it, and a ladder written down twice is a ladder that
    /// disagrees with itself. A *signed delta* rather than an absolute value, so
    /// there is only one place that decides what "next" means.
    func stepZoom(_ delta: Int) {
        setZoom(ZoomLadder.next(from: zoomPercent, delta: delta))
    }

    func setZoom(_ percent: Int) {
        let snapped = ZoomLadder.snap(percent)
        guard snapped != zoomPercent else { return }
        zoomPercent = snapped
        var updated = settings
        updated.zoomPercent = snapped
        settings = updated
        store.save(updated)
        Log.info("page zoom -> \(snapped)%")
    }

    /// Hand a URL to the system browser.
    ///
    /// `http(s)` only. Anything else is a way to make the OS launch something
    /// with this process's identity — a `file:` URL, a custom scheme.
    func openExternally(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            Log.error("refused to open \(url.scheme ?? "<none>"):// externally")
            return
        }
        NSWorkspace.shared.open(url)
        Log.info("opened externally: \(url.absoluteString)")
    }

    // MARK: - Web bridge

    /// The injected bridge forwards a `probe` shortly after the SPA mounts.
    /// Log the candidates so the selectors in `bridge.js` can be tuned against
    /// the real page without guessing.
    private func logProbe(_ report: WebProbeReport) {
        let heads = report.headings.prefix(3).map { "\($0.tag):\($0.text.prefix(40))" }.joined(separator: " | ")
        let buttons = report.buttons.prefix(6).map { "\($0.attribute.isEmpty ? $0.text : $0.attribute)" }.joined(separator: " | ")
        let inputs = report.inputs.map { "\($0.tag)@\($0.attribute)" }.joined(separator: " | ")
        logger.debug("bridge probe — headings[\(report.headings.count)]: \(heads, privacy: .public)")
        logger.debug("bridge probe — buttons[\(report.buttons.count)]: \(buttons, privacy: .public)")
        logger.debug("bridge probe — inputs[\(report.inputs.count)]: \(inputs, privacy: .public)")
    }

    private func notifyAgentIdle() {
        guard let since = agentRunningSince, Date().timeIntervalSince(since) > 5 else { return }
        let body = webSession.title.map { "\($0) — 任务完成" } ?? "任务完成"
        notify(title: "Agent 已空闲", body: body)
    }

    /// Post a user notification.
    ///
    /// Deliberately not routed through a delegate that raises the window: the
    /// whole point of these two notifications is that they arrive *while* the
    /// window is showing a dead page, which is exactly when a click that only
    /// brings the window forward would be useless.
    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The SPA's `document.title` is `"<conversation> — DeepSeek Harness"`,
    /// or just the product default when no conversation is open. The shell
    /// only surfaces the real conversation name — in the badge and the window
    /// title — so the product suffix/default is stripped to nil.
    private static func normalizedSessionTitle(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.replacingOccurrences(
            of: #"\s*[-—–]\s*DeepSeek Harness\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        return stripped
    }

    // MARK: - Private

    private func runLifecycle() async {
        logger.debug("runLifecycle: dsh=\(self.settings.dshBinaryPath, privacy: .public) mode=\(self.settings.launchMode.rawValue, privacy: .public)")
        let manager = DSHProcessManager(settings: settings)
        self.manager = manager
        let events = await manager.events()
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                self?.handle(event: event)
            }
        }

        do {
            let url = try await manager.start()
            logger.info("manager.start() returned url=\(url.absoluteString, privacy: .public)")
            self.lastURL = url
        } catch is CancellationError {
            // Teardown, not a failure. Leave whatever state `stopLifecycle()`
            // already set.
            logger.debug("lifecycle cancelled during startup")
        } catch {
            logger.error("manager.start() failed: \(String(describing: error), privacy: .public)")
            await MainActor.run {
                self.state = .failed(reason: error.localizedDescription)
                self.appendConsole(.shell, text: "[error] \(error.localizedDescription)")
                self.notify(title: "DSH Shell 无法启动", body: error.localizedDescription)
                // Whatever took the port, work out what it is now that there is
                // time for `lsof`. The error screen offers to close it only if
                // it can be shown to be a leftover of ours.
                self.refreshLeftoverProcesses()
            }
        }
    }

    private func handle(event: DSHProcessEvent) {
        switch event {
        case .launching:
            state = .launching
            appendConsole(.shell, text: "[shell] launching dsh…")
        case .launched(let pid):
            lastChildPID = pid
            appendConsole(.shell, text: "[shell] dsh spawned (pid \(pid))")
        case .stdoutLine(let line):
            logger.debug("dsh stdout: \(line, privacy: .public)")
            appendConsole(.dsh, text: line)
        case .stderrLine(let line):
            logger.debug("dsh stderr: \(line, privacy: .public)")
            appendConsole(.dsh, text: line)
        case .endpointResolved(let url):
            state = .ready(url)
            lastURL = url
            appendConsole(.shell, text: "[shell] endpoint resolved: \(url.absoluteString)")
        case .childExited(let status):
            lastChildPID = nil
            appendConsole(.shell, text: "[shell] dsh exited (status \(status))")
        case .autoRestartScheduled(let after):
            appendConsole(.shell, text: "[shell] auto-restart scheduled in \(Int(after))s")
            notify(title: "DSH Shell：dsh 已退出",
                   body: "将在 \(Int(after)) 秒后重启。")
        case .autoRestartAttempted:
            appendConsole(.shell, text: "[shell] auto-restart attempting")
        case .autoRestartAborted(let reason):
            appendConsole(.shell, text: "[shell] auto-restart aborted: \(reason)")
        case .connectionLost(let reason):
            // The window must stop pretending. Without this the UI stayed on
            // `.ready(oldURL)`, showing a conversation over a server that is no
            // longer listening — the "lying window" failure.
            lastURL = nil
            state = .failed(reason: reason)
            appendConsole(.shell, text: "[shell] connection lost: \(reason)")
            notify(title: "DSH Shell：连接已断开", body: reason)
        }
    }

    private func appendConsole(_ origin: ConsoleLine.Origin, text: String) {
        let line = ConsoleLine(origin: origin, text: text)
        consoleLines.append(line)
        if consoleLines.count > 2000 { consoleLines.removeFirst(consoleLines.count - 2000) }
    }
}

// MARK: - WebBridgeClient

extension AppCoordinator: WebBridgeClient {
    func handleBridgeEvent(_ event: WebBridgeEvent) {
        switch event {
        case .probe(let report):
            logProbe(report)
        case .title(let text):
            webSession.title = Self.normalizedSessionTitle(text)
        case .agentState(let running):
            if running {
                agentWasRunning = true
                agentRunningSince = Date()
            } else if agentWasRunning {
                agentWasRunning = false
                notifyAgentIdle()
            }
            webSession.agentRunning = running
        case .ack(let action, let ok):
            logger.debug("bridge ack — \(action, privacy: .public) ok=\(ok, privacy: .public)")
        case .unknown(let type):
            logger.debug("bridge unknown event: \(type, privacy: .public)")
        }
    }

    func bridgeReady(_ bridge: WebBridge) {
        // Note this fires *before* `view.load`, so anything evaluated here runs
        // against an empty document. The previous version toggled the CSS shim
        // from here, so the shim only ever applied because the page's heartbeat
        // happened to re-assert it — an accident that looked like a working
        // design. Nothing is invoked at this point any more.
        self.bridge = bridge
    }

    func webFocusComposer() {
        bridge?.invoke(.focusComposer)
    }

    func webSendMessage() {
        bridge?.invoke(.sendMessage)
    }

    func webNewSession() {
        bridge?.invoke(.newSession)
    }

    func webOpenWorkspace() {
        bridge?.invoke(.openWorkspace)
    }

    func webInjectText(_ text: String) {
        bridge?.invoke(.injectText(text))
    }
}
