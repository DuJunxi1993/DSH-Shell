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
public struct ShellSettings: Codable, Equatable, Sendable {
    public var dshBinaryPath: String
    public var launchMode: LaunchMode
    public var listenHost: String
    public var preferredPort: Int
    public var trustedHosts: [String]
    public var pollIntervalSeconds: Double
    public var spawnTimeoutSeconds: Int
    public var autoRestartOnCrash: Bool

    public init(
        dshBinaryPath: String = "/Users/djx/.npm-global/bin/dsh",
        launchMode: LaunchMode = .spawn,
        listenHost: String = "127.0.0.1",
        preferredPort: Int = 34247,
        trustedHosts: [String] = ["127.0.0.1", "localhost"],
        pollIntervalSeconds: Double = 0.5,
        spawnTimeoutSeconds: Int = 60,
        autoRestartOnCrash: Bool = true
    ) {
        self.dshBinaryPath = dshBinaryPath
        self.launchMode = launchMode
        self.listenHost = listenHost
        self.preferredPort = preferredPort
        self.trustedHosts = trustedHosts
        self.pollIntervalSeconds = pollIntervalSeconds
        self.spawnTimeoutSeconds = spawnTimeoutSeconds
        self.autoRestartOnCrash = autoRestartOnCrash
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
