import SwiftUI
import AppKit
import CoreGraphics
import DSHShellCore

struct PreferencesView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var working: ShellSettings = .default
    /// Read at appearance rather than only on demand: the answer is a plain
    /// process-level check with no prompt attached, so showing stale "not
    /// granted" from before the user visited System Settings would be a lie.
    @State private var screenGranted = CGPreflightScreenCaptureAccess()

    var body: some View {
        // The Apply button is drawn here, in the layout, rather than declared
        // through `.toolbar`.
        //
        // A `Settings` scene has no working window toolbar on this OS. Both
        // toolbar attempts landed inside the tab strip instead: attached to
        // `generalTab`, "Apply" rendered as a fourth tab beside
        // General/Advanced/Console; hoisted onto this `VStack`, it still
        // rendered there — squatting to the left of the tabs and overlapping
        // their labels and icons. Same assumption both times: that a
        // `confirmationAction` reaches the window's real toolbar.
        //
        // So the bottom bar is a plain `HStack`. It is also, unlike the toolbar,
        // reachable from every tab — the toolbar had been attached to
        // `generalTab` alone, so Advanced and Console had no way to save at
        // all: edits there lived in `working`, a `@State`, and were discarded
        // when the window closed.
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gear") }
                advancedTab
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                consoleTab
                    .tabItem { Label("Console", systemImage: "text.alignleft") }
            }
            // The bottom bar is part of the window's 460pt, so the tab content
            // takes what is left rather than being squeezed under it.
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Apply") {
                    coordinator.saveSettings(working)
                    coordinator.reload()
                    // Re-read rather than leaving `working` as it was: the
                    // saved settings are the source of truth once written, and
                    // the fields should show what is actually stored.
                    working = coordinator.settings
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 600, height: 460)
        .onAppear {
            working = coordinator.settings
            screenGranted = CGPreflightScreenCaptureAccess()
        }
        // The user's grant happens in another app (System Settings), so the
        // answer changes while this window is open. Re-reading on activation is
        // the cheap way to stop showing a stale "Not granted".
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private var generalTab: some View {
        Form {
            Section("dsh binary") {
                LabeledContent("Path") {
                    HStack {
                        TextField("", text: $working.dshBinaryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            pickBinary()
                        }
                    }
                }
            }
            Section("Connection") {
                Picker("Mode", selection: $working.launchMode) {
                    Text("Spawn dsh web").tag(LaunchMode.spawn)
                    Text("Attach to existing").tag(LaunchMode.attach)
                }
                .pickerStyle(.segmented)
                if working.launchMode == .spawn {
                    LabeledContent("Listen host") {
                        TextField("", text: $working.listenHost)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Preferred port") {
                        TextField("", value: $working.preferredPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }

    private var advancedTab: some View {
        Form {
            Section("Trusted hosts") {
                ForEach(working.trustedHosts.indices, id: \.self) { idx in
                    TextField("", text: Binding(
                        get: { working.trustedHosts[idx] },
                        set: { working.trustedHosts[idx] = $0 }
                    ))
                }
                .onDelete { working.trustedHosts.remove(atOffsets: $0) }
                Button("Add host") {
                    working.trustedHosts.append("")
                }
            }
            Section("Timeouts") {
                LabeledContent("Spawn timeout (s)") {
                    TextField("", value: $working.spawnTimeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Poll interval (s)") {
                    TextField("", value: $working.pollIntervalSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Auto-restart on crash", isOn: $working.autoRestartOnCrash)
            }
            screenRecordingSection
        }
        .formStyle(.grouped)
    }

    /// Screen Recording, where the user can actually see it.
    ///
    /// dsh's screenshot tools run as *children* of this app, so the permission
    /// macOS asks for belongs to dsh Shell — not to the `dsh` CLI, and not to
    /// whatever terminal started it. Two things follow, and neither is
    /// discoverable without being told: the grant has to be made in System
    /// Settings (the alert only offers a link there), and a new grant is not
    /// live until the app is relaunched. Without this row the only feedback a
    /// user ever gets is "the screenshot failed", again.
    private var screenRecordingSection: some View {
        Section("Screen Recording") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: screenGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(screenGranted ? Color.green : Color.orange)
                    Text(screenGranted ? "Granted" : "Not granted")
                }
            }
            HStack {
                Button("Request Access…") { requestScreenCapture() }
                Button("Restart dsh Shell") { relaunch() }
                Spacer()
            }
            Text(screenGranted
                 ? "If a screenshot still fails, relaunch dsh Shell: macOS applies a new grant only to a newly started process."
                 : "dsh's screenshot tools run inside this app, so the permission belongs to dsh Shell. Grant it in System Settings, then relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func requestScreenCapture() {
        // Ask, then show the pane: the system alert on this macOS offers only
        // "Open System Settings" and "Deny", so the toggle is where the grant
        // actually happens.
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        screenGranted = CGPreflightScreenCaptureAccess()
    }

    /// Quit and come back, because a Screen Recording grant is not live in the
    /// process that was running when it was made.
    ///
    /// The relaunch goes through a short-lived shell: the single-instance guard
    /// takes a lock, so a new instance started before this one has exited would
    /// be turned away. One second is enough and costs nothing.
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(Bundle.main.bundlePath)\""]
        try? process.run()
        NSApp.terminate(nil)
    }

    private var consoleTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(coordinator.consoleLines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.origin == .dsh ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: coordinator.consoleLines.count) { _, count in
                if let last = coordinator.consoleLines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func pickBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            working.dshBinaryPath = url.path
        }
    }
}
