import XCTest
@testable import DSHShellCore

/// The log a person reads to diagnose their own launch has to contain only
/// their own launch.
///
/// This suite drives dozens of stub dsh lifecycles whose output deliberately
/// mimics the real thing — decoy `bili` URLs, `token=stub-token`,
/// `boom: refusing to start because the profile could not be composed`. Those
/// lines used to be appended to the same daily file as a real session, which
/// makes the file actively misleading: the fake lines are indistinguishable from
/// evidence, and they arrive in volume. A bug report pointing at that file
/// would be pointing at the test suite.
final class FileLoggerTests: XCTestCase {
    private let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("DSHShell/logs", isDirectory: true)

    func testTheRunningTestsDoNotWriteToTheUsersLog() {
        // `FileLogger.shared` was constructed when the test process started, so
        // asking it now answers the question that matters: where would a log
        // line written from here have gone?
        XCTAssertNotEqual(
            FileLogger.shared.directoryPath.hasPrefix(appSupport.path), true,
            "tests are writing into \(appSupport.path)")
        XCTAssertTrue(
            FileLogger.shared.directoryPath.contains("DSHShellTestLogs"),
            "tests should log to a scratch directory, not \(FileLogger.shared.directoryPath)")
    }

    func testTheOverrideIsHonouredWhenGiven() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-log-override-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = FileLogger(directory: dir)
        logger.write("a line")
        logger.flush()
        let written = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(written.count, 1, "an explicit directory must be used verbatim")
        XCTAssertTrue(written[0].hasPrefix("dsh-shell.log."), "\(written[0])")
    }

    func testAWriteIsReadableImmediatelyAfterFlush() {
        // `applicationWillTerminate` flushes before telling anyone where to look.
        // If that flush did not work, the tail of a crash report is missing — the
        // part that describes the crash.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-log-flush-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = FileLogger(directory: dir)
        for i in 0..<200 { logger.write("line \(i)") }
        logger.flush()
        let file = try? FileManager.default
            .contentsOfDirectory(atPath: dir.path).first.map { dir.appendingPathComponent($0) }
        let body = (try? String(contentsOf: XCTUnwrap(file), encoding: .utf8)) ?? ""
        XCTAssertTrue(body.contains("line 199"), "the tail must survive the flush")
    }

    func testConcurrentWritesDoNotInterleave() {
        // The shell writes from the main actor, from drain callbacks, and from
        // lifecycle tasks at once. A torn line would be worse than no line,
        // because it reads as corruption of the log itself.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-log-concurrent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = FileLogger(directory: dir)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<100 { logger.write("worker \(worker) line \(i)") }
        }
        logger.flush()
        let file = try? FileManager.default
            .contentsOfDirectory(atPath: dir.path).first.map { dir.appendingPathComponent($0) }
        let lines = ((try? String(contentsOf: XCTUnwrap(file), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 800)
        for line in lines {
            XCTAssertTrue(line.contains("worker ") && line.contains(" line "),
                          "torn line: \(line)")
        }
    }
}