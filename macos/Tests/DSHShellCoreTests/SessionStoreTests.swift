import XCTest
import Compression
@testable import DSHShellCore

final class SessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-session-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(
        workspace: String,
        id: String,
        title: String?,
        cwd: String,
        createdAt: Date
    ) throws {
        let dir = root.appendingPathComponent(workspace, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var lines = [String]()
        lines.append(#"{"type":"session","version":0,"id":"\#(id)","createdAt":"\#(ISO8601DateFormatter().string(from: createdAt))","cwd":"\#(cwd)","delegationDepth":0,"agentPreset":"standard"}"#)
        lines.append(#"{"type":"event","seq":1,"time":0,"source":"user","event":{"type":"user/input"}}"#)
        if let title {
            lines.append(#"{"type":"session/title","version":0,"time":1,"data":{"title":"\#(title)"}}"#)
        }
        let jsonl = lines.joined(separator: "\n")
        let compressed = Self.zstdCompress(Data(jsonl.utf8))
        try compressed.write(to: dir.appendingPathComponent("session.jsonl.zstd"))
    }

    func testListSessionsParsesHeaderAndTitle() throws {
        try makeSession(
            workspace: "my-project",
            id: "session-aaa",
            title: "Chat about the refactor",
            cwd: "/Users/test/my-project",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try makeSession(
            workspace: "other",
            id: "session-bbb",
            title: nil,
            cwd: "/Users/test/other",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let store = SessionStore(rootURL: root)
        let sessions = store.listSessions()
        XCTAssertEqual(sessions.count, 2)

        let aaa = sessions.first { $0.id == "session-aaa" }
        XCTAssertNotNil(aaa)
        XCTAssertEqual(aaa?.title, "Chat about the refactor")
        XCTAssertEqual(aaa?.workspace, "/Users/test/my-project")
        XCTAssertEqual(aaa?.directoryURL.lastPathComponent, "session-aaa")

        let bbb = sessions.first { $0.id == "session-bbb" }
        XCTAssertNotNil(bbb)
        XCTAssertNil(bbb?.title)
    }

    func testListSessionsNewestFirst() throws {
        try makeSession(
            workspace: "w", id: "session-old", title: nil,
            cwd: "/x", createdAt: Date(timeIntervalSince1970: 1_000)
        )
        try makeSession(
            workspace: "w", id: "session-new", title: nil,
            cwd: "/x", createdAt: Date(timeIntervalSince1970: 2_000)
        )

        // newline padding so the newest session has a later mtime
        let sessions = SessionStore(rootURL: root).listSessions()
        XCTAssertEqual(sessions.first?.id, "session-new")
    }

    func testIgnoresNonSessionDirectories() throws {
        try makeSession(
            workspace: "w", id: "session-only", title: nil,
            cwd: "/x", createdAt: Date()
        )
        let stray = root.appendingPathComponent("w/stray", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        let sessions = SessionStore(rootURL: root).listSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "session-only")
    }

    func testZstdRoundTrip() throws {
        let original = Data("hello dsh session transcript\nsecond line\n".utf8)
        let compressed = Self.zstdCompress(original)
        let decoded = SessionStore.zstdDecompress(compressed)
        XCTAssertEqual(decoded, original)
    }

    private static func zstdCompress(_ data: Data) -> Data {
        // Mirror the production decoder: write to a temp file and pass the
        // path to `zstd` so we don't share the stdio pipes (which is what
        // hangs the app when the parent fills the kernel buffer before the
        // child gets a chance to read).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-zstd-test-\(UUID().uuidString).zst")
        do {
            try data.write(to: tmp)
        } catch {
            return Data()
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zstd", "-z", "-q", "-o", tmp.path, "--force", "/dev/stdin"]
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        do {
            try process.run()
        } catch {
            return Data()
        }
        stdinPipe.fileHandleForWriting.write(data)
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return Data() }
        return (try? Data(contentsOf: tmp)) ?? Data()
    }
}