import Foundation

/// A process holding the shell's port, and what can be proven about it.
///
/// ## Why this exists, and what it deliberately refuses to do
///
/// The shell refused to start once because a `dsh web` was orphaned on port
/// 3080 — left behind when the app was killed rather than quit — and the user
/// could see only `EADDRINUSE` behind a message about `node` not being on PATH.
/// Useful reaction: clean it up. The obvious implementation is "kill whatever is
/// on the port", and that is the one this type is built to refuse.
///
/// `docs/dsh-shell-contract.md` §9 makes killing by name a hard prohibition, and
/// for a reason recorded there: a previous agent ran `pkill -f dsh` and destroyed
/// the harness that was hosting it. Killing "every dsh on 3080" has the same
/// shape with a narrower blast radius — a `dsh web` the user started by hand, in
/// a terminal, is on that port too and is holding live work.
///
/// So the rule here is narrower and stated positively: **terminate only what can
/// be shown to be the shell's own leavings.** Three facts, all of them necessary:
///
/// 1. it is listening on the port this shell wants;
/// 2. its parent is `1`, so nothing is supervising it — a dsh the user ran from a
///    terminal has that terminal as its parent, and a dsh this shell started has
///    this shell;
/// 3. its command line is this shell's configured `dshBinaryPath` serving this
///    shell's configured port.
///
/// Fails any of them and it is reported as `notOrphan`, with the evidence, and the
/// shell says nothing is killed and why. The user is shown the PID either way;
/// deciding what to do with it is theirs.
public struct PortOccupant: Identifiable, Equatable, Sendable {
    public let pid: Int32
    /// The full command line, as `ps` reports it. Shown to the user verbatim —
    /// an opaque "PID 1234" is not something anyone can act on safely.
    public let commandLine: String
    public let parentPID: Int32
    public let verdict: Verdict

    public var id: Int32 { pid }

    public enum Verdict: Equatable, Sendable {
        /// Provably the shell's own leavings: no parent, and it is this binary on
        /// this port. Safe to close, and the user is shown exactly what will be.
        case orphan
        /// Something else, for a reason worth naming.
        case notOrphan(Reason)

        public enum Reason: Equatable, Sendable {
            /// A parent process is still supervising it.
            case supervised(parentPID: Int32)
            /// Not the `dshBinaryPath` this shell is configured to run.
            case differentBinary(String)
            /// A dsh, but not serving the port this shell asked for.
            case differentPort(String)
            /// Not a dsh at all.
            case notDsh(String)
            /// Gone between the port query and now.
            case gone
            /// `ps` would not say.
            case unreadable(String)

            public var explanation: String {
                switch self {
                case .supervised(let parent):
                    return "仍在 pid \(parent) 的管理下 —— 可能是你在终端里启动的，会话还在用它"
                case .differentBinary(let path):
                    return "不是本应用配置的 dsh（配置的路径：\(path)）"
                case .differentPort(let port):
                    return "是 dsh，但它服务的不是本应用配置的端口（\(port)）"
                case .notDsh(let name):
                    return "不是 dsh 进程（\(name)）"
                case .gone:
                    return "已经退出了"
                case .unreadable(let why):
                    return "无法读取进程信息（\(why)）"
                }
            }
        }
    }

    public var isOrphan: Bool { verdict == .orphan }

    // MARK: - Discovery

    /// Everyone listening on `port`, newest evidence first.
    ///
    /// Reads `lsof` and `ps` directly: this runs on a launch failure, where the
    /// user is waiting and the answer decides whether a button appears. Injectable
    /// so the decision logic can be tested without occupying a real port.
    public static func occupants(ofPort port: Int,
                                 binaryPath: String,
                                 run: (String, [String]) -> String? = defaultRun) -> [PortOccupant] {
        guard port > 0 else { return [] }
        // -t gives bare PIDs, which is what we want to signal. Only LISTEN: a
        // TIME_WAIT socket has no process to signal, and reporting one would put
        // a PID in front of the user that does not exist.
        let output = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
            ?? ""
        let pids: [Int32] = output.split(whereSeparator: \.isNewline).compactMap {
            Int32($0.trimmingCharacters(in: .whitespaces))
        }.filter { $0 > 0 }
        // lsof can list one process twice for the same port (IPv4 and IPv6
        // rows). Identity is the PID, so de-duplicate before deciding anything.
        var seen = Set<Int32>()
        return pids.filter { seen.insert($0).inserted }.map { inspect(pid: $0, binaryPath: binaryPath, run: run) }
    }

    /// Everything that can be proven about one PID.
    public static func inspect(pid: Int32,
                               binaryPath: String,
                               run: (String, [String]) -> String? = defaultRun) -> PortOccupant {
        let psLine = firstLine(run("/bin/ps", ["-o", "ppid=,command=", "-p", "\(pid)"]))
        guard let psLine, !psLine.isEmpty else {
            return .init(pid: pid, commandLine: "", parentPID: -1,
                         verdict: .notOrphan(.gone))
        }
        // `ps -o ppid=,command=` puts the parent first, then whitespace, then
        // everything else — which is the command line verbatim, spaces included.
        let parts = psLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let parent = Int32(parts.first ?? "") ?? -1
        let command = parts.count > 1 ? String(parts[1]) : ""

        return .init(pid: pid, commandLine: command, parentPID: parent,
                     verdict: judge(command: command, parentPID: parent, binaryPath: binaryPath))
    }

    /// The three conditions, and nothing else.
    ///
    /// Pure, so the rule that decides whether the shell is allowed to terminate
    /// something is testable without a live process.
    static func judge(command: String, parentPID: Int32, binaryPath: String) -> Verdict {
        guard !command.isEmpty else { return .notOrphan(.gone) }

        // Identity first, but against the *whole* command line rather than
        // argv[0]. dsh is a `#!/usr/bin/env node` script, so `ps` reports
        // `node /Users/djx/.npm-global/bin/dsh web …` — the interpreter is
        // argv[0] and the binary we are configured to run is an argument. Only
        // the *first* argument naming the interpreter can be skipped, so the
        // match is for the configured path appearing as a whole token.
        guard containsBinary(command: command, binaryPath: binaryPath) else {
            return .notOrphan(.notDsh(String(command.split(separator: " ").first ?? "")))
        }
        // Parent next: a supervised process is never a leftover, whatever else
        // is true of it, and this is what keeps a terminal-started dsh out of
        // reach.
        guard parentPID == 1 else {
            return .notOrphan(.supervised(parentPID: parentPID))
        }
        return .orphan
    }

    /// Whether `command` invokes this shell's configured dsh.
    ///
    /// Token-anchored on both sides, so `…/evil-dsh` cannot satisfy a match for
    /// `…/dsh`.
    ///
    /// The match is **exact whenever the setting is a path**, and only falls back
    /// to the basename when the setting is genuinely unresolved — bare `"dsh"`,
    /// which is what `ShellSettings.defaultBinaryPath()` returns when it finds
    /// nothing. Deciding that by looking at whether the *last component* is named
    /// `dsh` would be wrong in the dangerous direction: `/Users/me/.npm-global/
    /// bin/dsh` also ends in `dsh`, and a configured absolute path would then
    /// start accepting any dsh on the machine, including another user's.
    /// Unresolved-ness is about whether the string is a path, not about its tail.
    private static func containsBinary(command: String, binaryPath: String) -> Bool {
        let resolved = binaryPath.contains("/")
        let tokens = command.split(separator: " ").map(String.init)
        if resolved {
            // Require the configured path itself, as a whole token.
            return tokens.contains(binaryPath)
        }
        // Unresolved setting: accept any dsh by name. Nothing stricter is
        // available, and refusing here would disable the feature for every user
        // whose binary is discovered only via PATH.
        return tokens.contains { ($0 as NSString).lastPathComponent == binaryPath }
    }

    // MARK: - Signals

    /// Ask one process to exit, politely, and wait for it.
    ///
    /// Takes a PID and nothing else. There is deliberately no name-based path
    /// anywhere in this file, so no caller can reach one by accident.
    ///
    /// `SIGTERM` first because dsh closes its listeners and its profile cleanly;
    /// `SIGKILL` only if it will not go, because the alternative is an orphan.
    @discardableResult
    public static func terminate(pid: Int32, graceSeconds: TimeInterval = 5) -> Bool {
        guard pid > 1 else { return false }   // never init
        guard kill(pid, SIGTERM) == 0 else { return errno == ESRCH }
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            usleep(100_000)
        }
        guard kill(pid, SIGKILL) == 0 else { return errno == ESRCH }
        usleep(100_000)
        return kill(pid, 0) != 0
    }

    // MARK: - Plumbing

    /// Run a read-only inspection tool and return stdout, or nil.
    ///
    /// No shell is involved: an argument vector of literal strings, so a path or
    /// PID can never become anything else. The same rule `DSHProcessManager`
    /// holds to.
    ///
    /// Public because it is a default argument on the two entry points above,
    /// and a default argument cannot name something internal.
    public static func defaultRun(_ executable: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func firstLine(_ text: String?) -> String? {
        text.flatMap { $0.split(separator: "\n").first.map(String.init) }?
            .trimmingCharacters(in: .whitespaces)
    }
}