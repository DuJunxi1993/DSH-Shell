import XCTest
@testable import DSHShellCore

/// dsh consumes `⌘=`, `⇧⌘=` and `⌘-` for its own font size before AppKit's
/// menu sees them. The host has to recognise exactly those chords — and no
/// others — to route them to page zoom instead.
final class ZoomChordTests: XCTestCase {
    private func step(_ code: String, _ modifiers: [ShortcutModifier]) -> Int? {
        ZoomChord.step(code: code, modifiers: modifiers)
    }

    func testCommandEqualsZoomsIn() {
        // The chord macOS users actually press, and the one dsh binds first.
        XCTAssertEqual(step("Equal", [.meta]), ZoomLadder.step)
        // The shifted form matches the menu's displayed ⌘+.
        XCTAssertEqual(step("Equal", [.meta, .shift]), ZoomLadder.step)
    }

    func testCommandMinusZoomsOut() {
        XCTAssertEqual(step("Minus", [.meta]), -ZoomLadder.step)
        // Not bound by dsh, but the conventional macOS form of the same action.
        XCTAssertEqual(step("Minus", [.meta, .shift]), -ZoomLadder.step)
    }

    func testTypingEqualsIsNotAZoomChord() {
        XCTAssertNil(step("Equal", []))
        XCTAssertNil(step("Minus", []))
    }

    func testOtherModifiersAreLeftToTheirOwnCommands() {
        XCTAssertNil(step("Equal", [.meta, .alt]))
        XCTAssertNil(step("Equal", [.meta, .control]))
        XCTAssertNil(step("Equal", [.control]))
        XCTAssertNil(step("Equal", [.shift]))
    }

    func testOtherKeysAreNotZoomChords() {
        // ⌘0 is Actual Size, handled by the menu; the ladder has no step for it.
        XCTAssertNil(step("Digit0", [.meta]))
        XCTAssertNil(step("KeyN", [.meta]))
        XCTAssertNil(step("Slash", [.meta]))
    }
}
