import Foundation
import OSLog

/// Loads and persists `ShellSettings` to a JSON file under
/// `~/Library/Application Support/dsh-swiftUI/settings.json`.
///
/// Thread-safe: all work happens on a serial background queue.
public final class SettingsStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dsh-swiftUI.settings", qos: .utility)
    private let fileURL: URL
    private var cached: ShellSettings?
    private let logger = Logger(subsystem: "ai.deepseek.dsh-shell", category: "SettingsStore")

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let fm = FileManager.default
            let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let dir = base.appendingPathComponent("dsh-swiftUI", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("settings.json")
        }
    }

    public func load() -> ShellSettings {
        queue.sync {
            if let cached { return cached }
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                let defaults = ShellSettings.default
                cached = defaults
                return defaults
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode(ShellSettings.self, from: data)
                cached = decoded
                return decoded
            } catch {
                // Previously this returned defaults with no log line at all, so
                // a corrupt or incompatible settings file was indistinguishable
                // from a first launch — and the user's configuration simply
                // stopped applying.
                logger.error(
                    "settings at \(self.fileURL.path, privacy: .public) could not be decoded, falling back to defaults: \(error.localizedDescription, privacy: .public)"
                )
                let defaults = ShellSettings.default
                cached = defaults
                return defaults
            }
        }
    }

    public func save(_ settings: ShellSettings) {
        queue.sync {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(settings)
                try data.write(to: fileURL, options: .atomic)
                cached = settings
            } catch {
                // Non-fatal: surface through the unified log channel.
                logger.error("settings save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public var settingsURL: URL { fileURL }
}
