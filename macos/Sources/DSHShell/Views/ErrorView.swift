import SwiftUI
import DSHShellCore

/// The launch-failed screen.
///
/// Carries a second action only when there is one worth offering: a button that
/// closes the leftovers of a previous run. That button appears *only* for
/// processes that can be shown to be this shell's own — see `PortOccupant` for
/// why "everything on the port" is not good enough, and for the evidence shown
/// next to it.
struct ErrorView: View {
    let reason: String
    /// Process leftovers the user has been shown and may close.
    let orphans: [PortOccupant]
    let onRetry: () -> Void
    let onCloseOrphans: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("dsh could not start")
                .font(.title2)
            Text(reason)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if !orphans.isEmpty {
                Divider().frame(maxWidth: 480)
                orphanSection
            }
            HStack(spacing: 12) {
                if !orphans.isEmpty {
                    Button("Close \(orphans.count) leftover\(orphans.count == 1 ? "" : "s") and Retry",
                           action: onCloseOrphans)
                }
                Button("Retry", action: onRetry)
                    .keyboardShortcut(.defaultAction)
                // `SettingsLink` is the supported way to open a SwiftUI
                // `Settings` scene. The previous code sent the legacy
                // `showPreferencesWindow:` selector, which this app never
                // implements — it has no preferences *window*, only a Settings
                // scene — so the button was dead on every macOS that ships
                // this API's replacement.
                SettingsLink {
                    Text("Open Preferences…")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Exactly what will be closed, and why each one qualifies.
    ///
    /// Not decoration. The shell has a standing rule against terminating anything
    /// it did not spawn, and the user's consent to override it is only meaningful
    /// if they are told what they are consenting to.
    private var orphanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leftovers from an earlier run:")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: 480, alignment: .leading)
            ForEach(orphans) { orphan in
                VStack(alignment: .leading, spacing: 2) {
                    Text("PID \(orphan.pid)")
                        .font(.system(.body, design: .monospaced))
                    Text(orphan.commandLine)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(whyItQualifies(orphan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 480, alignment: .leading)
            }
            Text("These have no parent process and are running this app's dsh on the port it asked for.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 480, alignment: .leading)
        }
    }

    private func whyItQualifies(_ orphan: PortOccupant) -> String {
        switch orphan.verdict {
        case .orphan:
            return "no parent process · this app's dsh · its configured port"
        case .notOrphan(let reason):
            return reason.explanation
        }
    }
}