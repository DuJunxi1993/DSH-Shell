import Foundation

/// When the shell should push a zoom onto the webview.
///
/// ## Why this is a function and not two lines in `updateNSView`
///
/// It was two lines, and they were wrong.
///
/// The rule was "if the webview already holds the value we last applied, do
/// nothing" — but that is the condition describing *nothing has changed yet*,
/// so it skipped precisely when a new preference arrived. Measured: the first
/// ⌘- worked, every one after it was dropped, and the page sat at 60% while
/// `settings.json` said 100%. It looked broken because the preference was
/// persisted but never applied; the log said so too, in the gap between the
/// last `page zoom -> 60%` and the settings file being rewritten to 100.
///
/// The rule is about the **preference**, never about the page. The shell knows
/// whether its own setting changed; it cannot know what WebKit or a pinch did.
///
/// That also settles the pinch question without a policy: a pinch moves
/// `pageZoom` without moving the preference, so it is not pushed over, and the
/// next menu step takes control back.
public enum ZoomDecision: Equatable, Sendable {
    /// `apply` to the webview at `percent`.
    case apply(Int)
    /// Leave it alone.
    case leaveAlone

    /// `appliedPercent` is the last preference this shell pushed; `nil` means it
    /// has not pushed one yet, which is the first update after a webview is built.
    public static func decide(percent: Int, appliedPercent: Int?) -> ZoomDecision {
        let snapped = ZoomLadder.snap(percent)
        return snapped == appliedPercent ? .leaveAlone : .apply(snapped)
    }
}