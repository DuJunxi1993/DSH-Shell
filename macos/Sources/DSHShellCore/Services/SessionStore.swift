import Foundation
import Compression

/// One dsh session found under `~/.dsh/sessions`.
public struct SessionInfo: Identifiable, Equatable, Sendable {
    /// The `session-<uuid>` directory name.
    public let id: String
    /// Workspace the session ran in (from the session header line).
    public let workspace: String?
    /// Title from the first `session/title` event, if any.
    public let title: String?
    /// Modification date of the session file.
    public let modifiedDate: Date
    /// Full path of the session directory.
    public let directoryURL: URL
}

/// Reads the dsh session archive (`~/.dsh/sessions`). Sessions are
/// per-workspace directories holding a zstd-compressed JSONL transcript.
public struct SessionStore: Sendable {
    /// Root of the session archive this store reads.
    public let rootURL: URL

    public init(rootURL: URL = SessionStore.defaultRootURL) {
        self.rootURL = rootURL
    }

    /// Root of the dsh session archive, `~/.dsh/sessions`.
    public static var defaultRootURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".dsh/sessions", isDirectory: true)
    }

    /// Lists all sessions across workspaces, newest first.
    public func listSessions() -> [SessionInfo] {
        let fm = FileManager.default
        guard let workspaces = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [SessionInfo] = []
        for workspaceDir in workspaces {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: workspaceDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let sessions = try? fm.contentsOfDirectory(
                at: workspaceDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for sessionDir in sessions {
                guard sessionDir.lastPathComponent.hasPrefix("session-") else { continue }
                guard let info = Self.readSession(at: sessionDir) else { continue }
                result.append(info)
            }
        }
        return result.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    /// Moves a session directory to the Trash.
    public func deleteSession(_ session: SessionInfo) throws {
        _ = try FileManager.default.trashItem(at: session.directoryURL, resultingItemURL: nil)
    }

    // MARK: - Private

    /// Parses one session directory: the header line (id/cwd/createdAt) and
    /// the first `session/title` event from the zstd-compressed transcript.
    static func readSession(at dir: URL) -> SessionInfo? {
        let file = dir.appendingPathComponent("session.jsonl.zstd")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
              let data = try? Data(contentsOf: file),
              let decompressed = Self.zstdDecompress(data) else {
            return nil
        }
        let attributes = try? fm.attributesOfItem(atPath: file.path)
        let modified = attributes?[.modificationDate] as? Date ?? Date.distantPast

        var id = dir.lastPathComponent
        var workspace: String?
        var title: String?
        var seenTitle = false

        decompressed.split(separator: 0x0A).forEach { rawLine in
            guard let object = try? JSONSerialization.jsonObject(with: rawLine) as? [String: Any] else { return }
            guard let type = object["type"] as? String else { return }

            if type == "session", let sessionID = object["id"] as? String {
                id = sessionID
                workspace = object["cwd"] as? String
            } else if type == "session/title", !seenTitle, let data = object["data"] as? [String: Any] {
                seenTitle = true
                title = data["title"] as? String
            }
        }

        return SessionInfo(
            id: id,
            workspace: workspace,
            title: title,
            modifiedDate: modified,
            directoryURL: dir
        )
    }

    /// zstd algorithm id (COMPRESSION_ZSTD = 0x700). The named constants are
    /// not surfaced by the SDK's Swift overlay, so use the raw value.
    private static let zstdAlgorithm = compression_algorithm(rawValue: 0x700)

    /// Decompresses zstd data. Apple's `compression_decode_buffer` only handles
    /// a stripped-down subset of the zstd frame format (no frame header, no
    /// checksum), which is incompatible with the standard frames produced by
    /// libzstd and used by dsh. We shell out to the `zstd` CLI by writing the
    /// payload to a temp file and passing the path as an argument — piping the
    /// compressed bytes through stdin deadlocks because libzstd's worker
    /// threads don't drain the input pipe until much later, so the parent's
    /// synchronous `write` blocks forever once the kernel pipe buffer fills
    /// (seen in /Library/Logs/DiagnosticReports/DSHShell_*.hang, frame 155).
    static func zstdDecompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return decompressViaCLI(data)
    }

    /// Spawn `/usr/bin/env zstd -d -c <tmp>`, read stdout, and clean up. PATH
    /// is set explicitly because `open` launches the app with a minimal env
    /// that doesn't include Homebrew; without it, `env` can't find `zstd`.
    private static func decompressViaCLI(_ data: Data) -> Data? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-zstd-\(UUID().uuidString).zst")
        do {
            try data.write(to: tmp)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zstd", "-d", "-c", tmp.path]
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        do {
            try process.run()
        } catch {
            return nil
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return outData
    }
}
