import Foundation

/// How the shell obtains a dsh web endpoint.
///
/// - `spawn`: fork `dsh web` ourselves and watch its stdout for the URL line.
/// - `attach`: do not fork; instead, probe well-known local ports for an existing
///   dsh SPA. Useful when `dsh web` is already running under a separate process
///   manager (LaunchAgent, CI, dev, container).
public enum LaunchMode: String, Codable, Sendable, CaseIterable {
    case spawn
    case attach
}

/// Persistent user preferences for the shell.
///
/// `Codable` so it can be serialised to `~/Library/Application Support/dsh-swiftUI/settings.json`.
///
/// **Every field decodes through `decodeIfPresent` with a default.** This is
/// load-bearing, not defensive: the previous version required every key, and
/// `SettingsStore.load` swallowed the resulting decode failure and returned
/// defaults — so *adding one field in a future release would have made every
/// existing settings file fail to decode, and the user would have silently lost
/// their binary path, port and launch mode.* A field added later therefore
/// costs nothing to the files already on disk. See
/// `docs/dsh-shell-contract.md` §6 and the equivalent Rust guard
/// (`config.rs` `#[serde(default)]` plus its
/// `a_settings_file_without_zoom_still_loads` test).
public struct ShellSettings: Codable, Equatable, Sendable {
    public var dshBinaryPath: String
    public var launchMode: LaunchMode
    public var listenHost: String
    public var preferredPort: Int
    public var trustedHosts: [String]
    public var pollIntervalSeconds: Double
    public var spawnTimeoutSeconds: Int
    public var autoRestartOnCrash: Bool
    /// Page zoom, 50–100 in 10% steps. Carries a default on decode, so a
    /// settings file written before this field existed still loads — the same
    /// guard as every other field here.
    public var zoomPercent: Int

    public init(
        dshBinaryPath: String = ShellSettings.defaultBinaryPath(),
        launchMode: LaunchMode = .spawn,
        listenHost: String = "127.0.0.1",
        preferredPort: Int = 3080,
        trustedHosts: [String] = ["127.0.0.1", "localhost"],
        pollIntervalSeconds: Double = 0.5,
        spawnTimeoutSeconds: Int = 120,
        autoRestartOnCrash: Bool = true,
        zoomPercent: Int = 100
    ) {
        self.dshBinaryPath = dshBinaryPath
        self.launchMode = launchMode
        self.listenHost = listenHost
        self.preferredPort = preferredPort
        self.trustedHosts = trustedHosts
        self.pollIntervalSeconds = pollIntervalSeconds
        self.spawnTimeoutSeconds = spawnTimeoutSeconds
        self.autoRestartOnCrash = autoRestartOnCrash
        self.zoomPercent = zoomPercent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        dshBinaryPath = value(.dshBinaryPath, ShellSettings.defaultBinaryPath())
        launchMode = value(.launchMode, LaunchMode.spawn)
        listenHost = value(.listenHost, "127.0.0.1")
        preferredPort = value(.preferredPort, 3080)
        trustedHosts = value(.trustedHosts, ["127.0.0.1", "localhost"])
        pollIntervalSeconds = value(.pollIntervalSeconds, 0.5)
        spawnTimeoutSeconds = value(.spawnTimeoutSeconds, 120)
        autoRestartOnCrash = value(.autoRestartOnCrash, true)
        zoomPercent = value(.zoomPercent, 100)
    }

    /// Discover `dsh` at runtime instead of shipping someone's home directory
    /// as a default.
    ///
    /// The previous default was the literal `/Users/djx/.npm-global/bin/dsh`.
    /// On any other Mac a fresh install opened with "dsh binary not found at
    /// /Users/djx/…", and the Browse dialog started in `/usr/local/bin` — not
    /// where npm actually puts it.
    ///
    /// Returns bare `"dsh"` when nothing is found, which is correct: it resolves
    /// against the child's rebuilt PATH at spawn time rather than failing
    /// validation up front.
    public static func defaultBinaryPath() -> String {
        let fm = FileManager.default
        var candidates: [String] = []
        candidates.append(NSHomeDirectory() + "/.npm-global/bin/dsh")
        candidates.append(NSHomeDirectory() + "/.local/bin/dsh")
        // An npm prefix configured through the environment, e.g. nvm.
        for key in ["NPM_CONFIG_PREFIX", "npm_config_prefix"] {
            if let prefix = ProcessInfo.processInfo.environment[key], !prefix.isEmpty {
                candidates.append(prefix + "/bin/dsh")
            }
        }
        candidates.append("/opt/homebrew/bin/dsh")
        candidates.append("/usr/local/bin/dsh")
        candidates.append(contentsOf: candidateNvmBinaries().map { $0 + "/dsh" })

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return "dsh"
    }

    /// Every `~/.nvm/versions/node/*/bin/dsh`, newest version first.
    private static func candidateNvmBinaries() -> [String] {
        let root = NSHomeDirectory() + "/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return versions.sorted(by: >).map { root + "/" + $0 + "/bin" }
    }

    public static let `default` = ShellSettings()
}

/// Where the shell is in its lifecycle.
public enum ConnectionState: Equatable, Sendable {
    case idle
    case launching
    case connecting(host: String, port: Int)
    case ready(URL)
    case failed(reason: String)
    case shuttingDown
}

/// One console line emitted by the dsh child or the shell itself.
public struct ConsoleLine: Identifiable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case dsh
        case shell
    }

    public let id: UUID
    public let origin: Origin
    public let timestamp: Date
    public let text: String

    public init(id: UUID = UUID(), origin: Origin, timestamp: Date = Date(), text: String) {
        self.id = id
        self.origin = origin
        self.timestamp = timestamp
        self.text = text
    }
}
