import Foundation
import CoreGraphics
import Security
import ScreenCaptureKit
import DSHShellCore

/// The answer to "why can't dsh take a screenshot", asked by the app itself.
///
/// ## Why this exists
///
/// Screen Recording is the one TCC service whose state you cannot read from
/// outside the app. `tccd` refuses to let even root read the database, `log
/// show` for that subsystem is withheld, and System Settings shows a row per
/// *code identity* — which, for an ad-hoc signed app, is one row per build.
/// Diagnosing it by hand meant attaching a debugger to a running app and
/// evaluating `CGPreflightScreenCaptureAccess()` in its process, which works
/// only while the app carries `get-task-allow` — precisely the entitlement a
/// release build should not have.
///
/// So the probe lives in the app. It runs before any UI exists, writes one
/// plain-text report, and exits:
///
///     open -n DSHShell.app --args --request-screen    # trigger the prompt
///     open -n DSHShell.app --args --diagnose-screen   # read the verdict
///
/// The report lands next to the rolling log (`FileLogger.directoryPath`), so it
/// is the same place a user already knows to look.
///
/// ## What it reports, and why each line
///
/// - **designated requirement** — the identity TCC pins a grant to. If this
///   line contains `cdhash`, every rebuild silently throws the permission away;
///   that is the whole defect this exists to make visible.
/// - **preflight** — `CGPreflightScreenCaptureAccess()`, the documented
///   "am I allowed to capture right now" answer.
/// - **ScreenCaptureKit** — the API modern capture code actually uses. It can
///   disagree with preflight, and when it fails it says *why* (denied vs.
///   not yet asked), which preflight cannot.
/// - **screencapture** — the end-to-end case: the CLI an agent runs from a
///   shell tool inside dsh. Exit status and byte count only; the image itself
///   is deleted immediately, because a screenshot is the user's screen.
enum ScreenCaptureDiagnostics {
    /// Return `true` when a diagnostic mode ran and the process should exit.
    static func handleCommandLineIfNeeded() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--request-screen") {
            let granted = CGRequestScreenCaptureAccess()
            record(mode: "--request-screen",
                   extra: "CGRequestScreenCaptureAccess() = \(granted ? "true" : "false") "
                        + "(false is expected until the app is relaunched after the grant)")
            // Stay alive while the system alert is up. The alert belongs to the
            // app that asked; exiting immediately would take it down before the
            // user can follow it to System Settings.
            Thread.sleep(forTimeInterval: 60)
            return true
        }
        if arguments.contains("--diagnose-screen") {
            record(mode: "--diagnose-screen", extra: nil)
            return true
        }
        return false
    }

    /// Build the report, write it, and echo it to stdout for anyone running the
    /// binary from a terminal.
    private static func record(mode: String, extra: String?) {
        var lines = ["dsh screen-capture diagnostic — \(mode)", "",
                     "when:        \(ISO8601DateFormatter().string(from: Date()))"]
        lines.append(contentsOf: facts())
        if let extra {
            lines.append(extra)
        }
        let text = lines.joined(separator: "\n") + "\n"

        print(text)
        let path = FileLogger.shared.directoryPath + "/screen-capture.txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print("written to: \(path)")
    }

    private static func facts() -> [String] {
        let bundle = Bundle.main
        return [
            "bundle id:   \(bundle.bundleIdentifier ?? "<none>")",
            "bundle path: \(bundle.bundlePath)",
            "version:     \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
            "requirement: \(designatedRequirement())",
            "preflight:   \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted")",
            "kit:         \(shareableContentSummary())",
            "screencapture: \(runScreencapture())",
        ]
    }

    /// The designated requirement as text.
    ///
    /// For an ad-hoc signature this is `cdhash H"…"` — a value that changes on
    /// every build, which is exactly how a Screen Recording grant evaporates
    /// after a rebuild. A stable requirement names the identifier (and, when a
    /// real certificate is used, the certificate) instead.
    private static func designatedRequirement() -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return "<no static code>" }

        var information: CFDictionary?
        // `kSecCSRequirementInformation` is what makes the requirement
        // available at all; `kSecCSSigningInformation` alone returns an
        // identifier and a team id but no designated requirement.
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let requirement = dictionary[kSecCodeInfoDesignatedRequirement as String] else {
            return "<unavailable>"
        }

        var text: CFString?
        guard SecRequirementCopyString(requirement as! SecRequirement, [], &text) == errSecSuccess,
              let text else { return "<unprintable>" }
        return text as String
    }

    /// Ask ScreenCaptureKit for the window list.
    ///
    /// This is the same gate a screenshot tool hits. Without permission it
    /// fails with a TCC denial; with permission it returns windows. The call is
    /// asynchronous and this runs before any run loop exists, so the wait is on
    /// a semaphore — the completion handler is delivered on its own queue, not
    /// on the main one, so this cannot deadlock; the timeout is only there so a
    /// wedged system daemon cannot hang the app on launch.
    private static func shareableContentSummary() -> String {
        let box = Box()
        let done = DispatchSemaphore(value: 0)

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error {
                box.set("error: \(error.localizedDescription)")
            } else if let content {
                box.set("ok — \(content.windows.count) windows")
            } else {
                box.set("no content and no error")
            }
            done.signal()
        }

        if done.wait(timeout: .now() + 5) == .timedOut {
            return "timed out after 5s"
        }
        return box.value
    }

    /// Run the command an agent's shell tool would run, and report only its
    /// shape. The PNG is deleted immediately: its *contents* are the user's
    /// screen and this is a diagnostic, not a screenshot feature.
    private static func runScreencapture() -> String {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-screen-diagnostic-\(getpid()).png")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png", output.path]
        do {
            try process.run()
        } catch {
            return "could not launch: \(error.localizedDescription)"
        }
        process.waitUntilExit()

        let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int ?? 0
        return "exit=\(process.terminationStatus) bytes=\(bytes)"
    }

    /// Mutable slot for the async result, safe to touch from the completion
    /// handler's queue.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = "no result"

        var value: String {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ newValue: String) {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
