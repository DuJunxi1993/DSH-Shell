import SwiftUI
import DSHShellCore

struct PreferencesView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var working: ShellSettings = .default

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
        .onAppear { working = coordinator.settings }
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
        }
        .formStyle(.grouped)
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
