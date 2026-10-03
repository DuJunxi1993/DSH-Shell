import SwiftUI
import DSHShellCore

/// Native session archive browser: list, search, delete, and reveal dsh
/// sessions. Independent of the web UI.
struct SessionPanelView: View {
    @State private var sessions: [SessionInfo] = []
    @State private var query = ""
    @State private var selected: SessionInfo.ID?
    @State private var confirmDelete: SessionInfo?

    private let store = SessionStore()

    private var filtered: [SessionInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        return sessions.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
                || ($0.workspace ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions…", text: $query)
                    .textFieldStyle(.plain)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            .padding(10)
            Divider()
            if sessions.isEmpty {
                Spacer()
                Text("No sessions found under\n~/.dsh/sessions")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered, selection: $selected) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([session.directoryURL])
                            }
                            Button("Delete Session…", role: .destructive) {
                                confirmDelete = session
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .onAppear(perform: refresh)
        .confirmationDialog(
            "Delete this session permanently?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let session = confirmDelete {
                    do {
                        try store.deleteSession(session)
                        refresh()
                    } catch {
                        NSSound.beep()
                    }
                }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
    }

    private func refresh() {
        sessions = store.listSessions()
    }
}

private struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title ?? "Untitled session")
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(session.workspace ?? "unknown workspace")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(session.modifiedDate, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
