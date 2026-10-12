import AppKit
import Foundation
import DSHShellCore

/// Refuses a second copy of the shell, and points it at the window already open.
///
/// Two shells racing for the same port is not a cosmetic problem: the loser
/// dies with "address already in use", which is a confusing way to learn that
/// the app is already running. The Windows shell registers its single-instance
/// plugin *before anything else*, so there is no window in which two instances
/// can both be alive, and the rule is the same here — see
/// `docs/dsh-shell-contract.md` §5.
///
/// An `flock` on a file rather than `NSRunningApplication`: it works for a
/// `swift run` binary that has no bundle identifier, it cannot be fooled by a
/// second copy racing the enumeration, and the kernel releases it if the process
/// dies, so a crashed shell does not leave a lock nobody can take.
final class SingleInstanceGuard {
    private let descriptor: Int32
    private let path: String

    /// The lock path. Under Application Support so it lives with the app's other
    /// state and is removed by a normal uninstall of the user's home directory,
    /// rather than in /tmp where it would outlive the app.
    static var defaultPath: String {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("DSHShell", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("instance.lock").path
    }

    /// Succeeds when this process now owns the lock. `nil` means another
    /// instance already has it.
    init?(path: String = SingleInstanceGuard.defaultPath) {
        self.path = path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.descriptor = fd
        // Record the PID so the raiser can say something useful if activation
        // fails, and so a stale lock file is never mistaken for a live process.
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Bring an already-running shell to the front.
    ///
    /// By bundle identifier when there is one — which is how a real installed
    /// build is found — and by a window titled as ours otherwise, so a
    /// `swift run` copy still finds its sibling.
    @MainActor
    static func activateRunningInstance() -> Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        let candidates: [NSRunningApplication]
        if let id = Bundle.main.bundleIdentifier {
            candidates = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        } else {
            candidates = NSWorkspace.shared.runningApplications
        }
        guard let other = candidates.first(where: { $0.processIdentifier != mine }) else {
            return false
        }
        // `activateIgnoringOtherApps` has been deprecated since macOS 14 and
        // does nothing; the app is already the frontmost candidate, so
        // `activateAllWindows` is both sufficient and not a warning.
        other.activate(options: [.activateAllWindows])
        return true
    }
}