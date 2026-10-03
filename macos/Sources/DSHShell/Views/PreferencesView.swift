import SwiftUI
import DSHShellCore

struct PreferencesView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var working: ShellSettings = .default

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            consoleTab
                .tabItem { Label("Console", systemImage: "text.alignleft") }
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    coordinator.saveSettings(working)
                    coordinator.reload()
                }
            }
        }
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
