import XCTest
@testable import DSHShellCore

/// Why this exists: the rule that decides whether a zoom reaches the page was
/// written backwards, and nothing caught it.
///
/// The wrong version skipped whenever the webview already held the value the
/// shell last applied — which is the condition for *nothing having changed*.
/// So the first ⌘- worked and every one after it was dropped: the page sat at
/// 60% while `settings.json` had already been rewritten to 100, and a restart
/// "fixed" it because a fresh webview has no remembered value.
///
/// Each test below is one of the states that has to behave differently.
final class ZoomDecisionTests: XCTestCase {
    func testTheFirstUpdateAlwaysApplies() {
        // Nothing pushed yet, so the webview holds WebKit's default and the
        // preference must win — including when that default happens to match.
        XCTAssertEqual(ZoomDecision.decide(percent: 100, appliedPercent: nil), .apply(100))
    }

    func testAChangedPreferenceApplies() {
        // The regression itself: 100 is where the page is, 80 is what was just
        // asked for. This must apply.
        XCTAssertEqual(ZoomDecision.decide(percent: 80, appliedPercent: 100), .apply(80))
        XCTAssertEqual(ZoomDecision.decide(percent: 120, appliedPercent: 100), .apply(120))
    }

    func testRepeatedStepsAllApply() {
        // Every rung on the way down and back up, which is where the old rule
        // stopped dead after the first one.
        var applied: Int? = nil
        var seen: [Int] = []
        for target in [90, 80, 70, 80, 90, 100, 110, 100] {
            if case .apply(let snapped) = ZoomDecision.decide(percent: target,
                                                             appliedPercent: applied) {
                seen.append(snapped)
                applied = snapped
            }
        }
        XCTAssertEqual(seen, [90, 80, 70, 80, 90, 100, 110, 100])
    }

    func testAnUnchangedPreferenceLeavesThePageAlone() {
        // This is what keeps ⌘-pinch: the page moved, the preference did not,
        // so the shell has nothing to say and stays quiet.
        XCTAssertEqual(ZoomDecision.decide(percent: 100, appliedPercent: 100), .leaveAlone)
    }

    func testAPinchIsNotUndone() {
        // The page is at 1.4, the preference is still 100. Nothing is pushed,
        // because the shell cannot tell a pinch from a stale value and should
        // not be guessing on its own either.
        XCTAssertEqual(ZoomDecision.decide(percent: 100, appliedPercent: 100), .leaveAlone)
        // …and a menu step afterwards takes control back.
        XCTAssertEqual(ZoomDecision.decide(percent: 110, appliedPercent: 100), .apply(110))
    }

    func testAnOffLadderPreferenceIsSnappedBeforeItIsCompared() {
        // A hand-edited 57 behaves like 60, so it is 60 that must be pushed —
        // and asking for 57 again afterwards must be a no-op, or every view
        // update would re-push the same value.
        XCTAssertEqual(ZoomDecision.decide(percent: 57, appliedPercent: nil), .apply(60))
        XCTAssertEqual(ZoomDecision.decide(percent: 58, appliedPercent: 60), .leaveAlone)
    }

    func testTheDecisionIsIndependentOfTheWebviewsCurrentValue() {
        // The whole point. Whatever the page is showing, only the preference
        // and what was last applied decide.
        XCTAssertEqual(ZoomDecision.decide(percent: 140, appliedPercent: 100), .apply(140))
        XCTAssertEqual(ZoomDecision.decide(percent: 140, appliedPercent: 140), .leaveAlone)
    }
}