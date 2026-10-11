import Foundation
import OSLog

/// A rolling daily file log, alongside the unified log.
///
/// `os_log` is not a diagnostic you can hand to anybody: `log stream` has to be
/// running beforehand, the buffer is bounded, and a release build with no
/// console attached leaves the user with nothing to send. The Windows shell
/// writes `%APPDATA%\...\logs\dsh-shell.log.<date>` for every build, and the
/// point of that is the same as the point of this: a release build that fails
/// silently must still leave a record, or "it just didn't start" is all anyone
/// can say.
///
/// The unified log stays the primary channel — it is what `log stream` and
/// Console read — and this is the copy that survives a bug report.
///
/// Deliberately dependency-free and synchronous-on-a-private-queue: a logger
/// that can block or throw is worse than no logger, and every failure path here
/// degrades to "no file", never to "the app did not start".
public final class FileLogger: @unchecked Sendable {
    public static let shared = FileLogger()

    private let queue = DispatchQueue(label: "com.dsh-shelU.log", qos: .utility)
    private let directory: URL
    private let subsystem: String
    private var handle: FileHandle?
    private var currentDay: String?

    public init(directory: URL? = nil, subsystem: String = "ai.deepseek.dsh-shell") {
        self.subsystem = subsystem
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support")
            let dir = base.appendingPathComponent("DSHShell", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.directory = dir
        }
    }

    /// One file per day, named `dsh-shell.log.<yyyy-MM-dd>`.
    ///
    /// A new file per day rather than a size-based rotation because the useful
    /// unit of a bug report is "what happened on the day it broke", and a date
    /// in the name means nobody has to ask which file to open.
    private static func dayStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private func fileURL(forDay day: String) -> URL {
        directory.appendingPathComponent("dsh-shell.log.\(day)")
    }

    /// Append one line. Never throws, never blocks the caller for longer than
    /// the write itself, and silently gives up if the file cannot be opened.
    public func write(_ message: String, level: String = "info") {
        let day = Self.dayStamp()
        queue.async { [weak self] in
            guard let self else { return }
            if self.handle == nil || self.currentDay != day {
                self.rotate(to: day)
            }
            guard let handle = self.handle else { return }
            let line = "\(Self.timestamp()) [\(level)] \(message)\n"
            handle.write(Data(line.utf8))
        }
    }

    private func rotate(to day: String) {
        try? handle?.close()
        handle = nil
        currentDay = day
        let url = fileURL(forDay: day)
        guard let created = try? FileHandle(forWritingTo: url) else {
            // Create it if missing, then reopen for appending.
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let opened = try? FileHandle(forWritingTo: url) else { return }
            opened.seekToEndOfFile()
            handle = opened
            return
        }
        created.seekToEndOfFile()
        handle = created
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// The directory logs are written to, so the app can tell the user where to
    /// look. Shown in Preferences rather than left to be discovered.
    public var directoryPath: String { directory.path }

    /// A file handle is OS-buffered; a bug report that reads the log before the
    /// buffer flushes sees a truncated tail. Call this before telling anyone the
    /// path.
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// Record a startup failure separately.
    ///
    /// A launch that dies before the logger exists still has to leave something,
    /// and "it quit immediately" with no output is indistinguishable from a hang.
    public func writeCrash(_ message: String) {
        flush()
        let url = directory.appendingPathComponent("crash.log")
        let line = "\(Self.timestamp()) [crash] \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }
}

/// Convenience so call sites read as `Log.info("…")` rather than reaching for a
/// subsystem-scoped `Logger` each time — and so every line lands in both places
/// without the caller having to remember to do the second one.
public enum Log {
    public static let shell = Logger(subsystem: "ai.deepseek.dsh-shell", category: "shell")
    public static let process = Logger(subsystem: "ai.deepseek.dsh-shell", category: "process")
    public static let web = Logger(subsystem: "ai.deepseek.dsh-shell", category: "web")

    public static func info(_ message: String) {
        shell.info("\(message, privacy: .public)")
        FileLogger.shared.write(message)
    }

    public static func error(_ message: String) {
        shell.error("\(message, privacy: .public)")
        FileLogger.shared.write(message, level: "error")
    }

    /// Diagnostics worth keeping but not worth a console line.
    public static func debug(_ message: String) {
        shell.debug("\(message, privacy: .public)")
        FileLogger.shared.write(message, level: "debug")
    }
}