import XCTest
@testable import DSHShellCore

/// The rule that decides whether the shell may terminate a process.
///
/// Every case here is one where getting it wrong costs somebody either a live
/// session or their harness, so the tests pin the refusals as hard as the
/// permission. `docs/dsh-shell-contract.md` §9: never kill by name, only by a
/// PID this shell recorded — and this type is what narrows "only by name" into
/// something a user can be shown and consent to.
final class PortOccupantTests: XCTestCase {
    private let dsh = "/Users/djx/.npm-global/bin/dsh"
    private let dshCommand = "node /Users/djx/.npm-global/bin/dsh web --no-open --host 127.0.0.1 --port 3080"

    // MARK: - What qualifies

    func testAParentlessProcessRunningThisBinaryIsAnOrphan() {
        XCTAssertEqual(PortOccupant.judge(command: dshCommand, parentPID: 1, binaryPath: dsh),
                       .orphan)
    }

    func testAnUnresolvedBinaryNameStillMatches() {
        // `ShellSettings.defaultBinaryPath()` returns bare "dsh" when nothing is
        // found, and that is the configuration most users have. Refusing to act
        // there would make the feature dead exactly when it is needed.
        XCTAssertEqual(PortOccupant.judge(command: "node /usr/local/bin/dsh web", parentPID: 1,
                                          binaryPath: "dsh"),
                       .orphan)
    }

    // MARK: - What must be refused

    /// The case that matters most: a dsh the user started by hand, in a
    /// terminal, on the same port. Killing it would take their session with it.
    func testATerminalStartedDshIsNeverAnOrphan() {
        let verdict = PortOccupant.judge(command: dshCommand, parentPID: 4242, binaryPath: dsh)
        XCTAssertEqual(verdict, .notOrphan(.supervised(parentPID: 4242)))
    }

    func testABareShellRunningDshIsNeverAnOrphan() {
        // `ppid == 1` is the orphan signal, so make sure it is checked against a
        // real parent rather than assumed from "it looks like a dsh".
        XCTAssertEqual(PortOccupant.judge(command: dshCommand, parentPID: 8123, binaryPath: dsh),
                       .notOrphan(.supervised(parentPID: 8123)))
    }

    func testAnotherBinaryIsNeverAnOrphan() {
        XCTAssertEqual(
            PortOccupant.judge(command: "python3 -m http.server 3080", parentPID: 1, binaryPath: dsh),
            .notOrphan(.notDsh("python3")))
    }

    func testADifferentDshInstallIsNotOurs() {
        // Another dsh on the same port. Not ours, so not touchable — even
        // though it is the same program at a different path.
        XCTAssertEqual(
            PortOccupant.judge(command: "node /opt/other/dsh web", parentPID: 1, binaryPath: dsh),
            .notOrphan(.notDsh("node")))
    }

    func testAnEmptyCommandLineIsGoneNotAnOrphan() {
        // `ps` answering with nothing means the process exited underneath us.
        // Treating that as "safe to kill" would let a recycled PID be signalled.
        XCTAssertEqual(PortOccupant.judge(command: "", parentPID: 1, binaryPath: dsh),
                       .notOrphan(.gone))
    }

    /// A lookalike name must not pass when the path is known.
    func testALookalikeNameIsRefusedWhenThePathIsKnown() {
        XCTAssertEqual(
            PortOccupant.judge(command: "node /tmp/evil-dsh web", parentPID: 1, binaryPath: dsh),
            .notOrphan(.notDsh("node")))
    }

    /// The configured path ends in `dsh`, so any test that decides "is this a
    /// path or a bare name?" by looking at the last component would call it a
    /// bare name and start matching every dsh on the machine. That is the
    /// dangerous direction, so it is pinned directly.
    func testAKnownAbsolutePathNeverFallsBackToMatchingByName() {
        XCTAssertEqual(
            PortOccupant.judge(command: "node /somewhere/else/dsh web", parentPID: 1,
                               binaryPath: dsh),
            .notOrphan(.notDsh("node")),
            "a configured absolute path must not accept another dsh by name")
    }

    // MARK: - Reasons are written for a person

    func testEveryRefusalExplainsItself() {
        // The user is looking at this while their app will not start. A reason
        // that says nothing is the same as no reason.
        let reasons: [PortOccupant.Verdict] = [
            .notOrphan(.supervised(parentPID: 4242)),
            .notOrphan(.notDsh("python3")),
            .notOrphan(.gone),
            .notOrphan(.unreadable("ps failed")),
        ]
        for verdict in reasons {
            guard case .notOrphan(let reason) = verdict else {
                return XCTFail("expected a refusal, got \(verdict)")
            }
            XCTAssertFalse(reason.explanation.isEmpty, "\(reason) has no explanation")
        }
    }

    // MARK: - Discovery

    /// `lsof` can report one PID twice (IPv4 and IPv6 rows). Deciding anything
    /// twice — and offering the user a duplicated row — follows from that.
    func testTheSamePIDIsReportedOnce() {
        let fake: (String, [String]) -> String? = { tool, _ in
            tool.hasSuffix("lsof") ? "95164\n95164\n" : nil
        }
        XCTAssertEqual(PortOccupant.occupants(ofPort: 3080, binaryPath: dsh, run: fake).count, 1)
    }

    func testParentsAndCommandsComeFromPsVerbatim() {
        let fake: (String, [String]) -> String? = { tool, _ in
            if tool.hasSuffix("lsof") { return "95164\n" }
            return "  1 node /Users/djx/.npm-global/bin/dsh web --port 3080\n"
        }
        let occupants = PortOccupant.occupants(ofPort: 3080, binaryPath: dsh, run: fake)
        XCTAssertEqual(occupants.count, 1)
        XCTAssertEqual(occupants[0].pid, 95164)
        XCTAssertEqual(occupants[0].parentPID, 1)
        // Whitespace inside the command line must survive: it is shown to the
        // user verbatim, and a truncated path is not something to act on.
        XCTAssertEqual(occupants[0].commandLine,
                       "node /Users/djx/.npm-global/bin/dsh web --port 3080")
        XCTAssertEqual(occupants[0].verdict, .orphan)
    }

    func testAnEmptyPortAsksForNothing() {
        XCTAssertTrue(PortOccupant.occupants(ofPort: 0, binaryPath: dsh, run: { _, _ in
            XCTFail("must not run anything for port 0"); return "1\n"
        }).isEmpty)
    }

    /// `ps` escapes non-ASCII bytes into `M-hM-=M-/…` unless the child runs in a
    /// UTF-8 locale, and the identity check compares that command line against
    /// the configured path. A repository (or a dsh install) under a directory
    /// with Chinese characters therefore looked like "somebody else's binary"
    /// and its orphan was never reclaimed — the shell would refuse to start over
    /// its own leftover. The environment is forced rather than inherited, so it
    /// cannot depend on how the app itself was launched.
    func testPsRunsInAUTF8LocaleSoNonASCIIPathsSurvive() {
        let locale = PortOccupant.defaultRun("/usr/bin/printenv", ["LC_ALL"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(locale, "en_US.UTF-8")
    }
}