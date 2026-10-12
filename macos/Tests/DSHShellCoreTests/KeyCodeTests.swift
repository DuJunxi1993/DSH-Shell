import XCTest
@testable import DSHShellCore

/// The physical-key mapping between AppKit and the DOM.
///
/// Every case here is a whole-file assertion rather than a spot check: a gap in
/// the table shows up as "some shortcuts do nothing", which is close to
/// undiagnosable from a user's report and impossible to catch by eye.
final class KeyCodeTests: XCTestCase {
    func testEveryLetterMaps() {
        let expected: [(UInt16, String)] = [
            (0, "KeyA"), (1, "KeyS"), (2, "KeyD"), (3, "KeyF"), (4, "KeyH"),
            (5, "KeyG"), (6, "KeyZ"), (7, "KeyX"), (8, "KeyC"), (9, "KeyV"),
            (11, "KeyB"), (12, "KeyQ"), (13, "KeyW"), (14, "KeyE"), (15, "KeyR"),
            (16, "KeyY"), (17, "KeyT"), (31, "KeyO"), (32, "KeyU"), (33, "KeyI"),
            (34, "KeyP"), (37, "KeyL"), (38, "KeyJ"), (40, "KeyK"), (45, "KeyN"),
            (46, "KeyM"),
        ]
        for (code, name) in expected {
            XCTAssertEqual(KeyCode.domCode(for: code), name, "keyCode \(code)")
        }
    }

    func testEveryTopRowDigitMaps() {
        let expected: [(UInt16, String)] = [
            (18, "Digit1"), (19, "Digit2"), (20, "Digit3"), (21, "Digit4"),
            (22, "Digit6"), (23, "Digit5"), (25, "Digit9"), (26, "Digit7"),
            (28, "Digit8"), (29, "Digit0"),
        ]
        for (code, name) in expected {
            XCTAssertEqual(KeyCode.domCode(for: code), name, "keyCode \(code)")
        }
    }

    func testPunctuationMaps() {
        let expected: [(UInt16, String)] = [
            (24, "Equal"), (27, "Minus"), (30, "BracketRight"), (35, "BracketLeft"),
            (39, "Quote"), (41, "Semicolon"), (42, "Backslash"), (43, "Comma"),
            (44, "Slash"), (47, "Period"), (50, "Backquote"), (10, "IntlBackslash"),
        ]
        for (code, name) in expected {
            XCTAssertEqual(KeyCode.domCode(for: code), name, "keyCode \(code)")
        }
    }

    func testControlAndArrowKeysMap() {
        let expected: [(UInt16, String)] = [
            (36, "Enter"), (48, "Tab"), (49, "Space"), (51, "Backspace"),
            (53, "Escape"), (123, "ArrowLeft"), (124, "ArrowRight"),
            (125, "ArrowDown"), (126, "ArrowUp"),
            (115, "Home"), (116, "PageUp"), (119, "End"), (121, "PageDown"),
        ]
        for (code, name) in expected {
            XCTAssertEqual(KeyCode.domCode(for: code), name, "keyCode \(code)")
        }
    }

    func testFunctionKeysMap() {
        let expected: [(UInt16, String)] = [
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"),
            (97, "F6"), (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"),
            (103, "F11"), (111, "F12"),
        ]
        for (code, name) in expected {
            XCTAssertEqual(KeyCode.domCode(for: code), name, "keyCode \(code)")
        }
    }

    /// A key with no DOM equivalent must return nil, never a guess. Returning
    /// something wrong dispatches a chord to a command the user never assigned.
    func testAnUnknownKeyReturnsNil() {
        for code: UInt16 in [999, 65535, 200] {
            XCTAssertNil(KeyCode.domCode(for: code), "keyCode \(code)")
        }
    }

    /// The reverse lookup has to be deterministic. Several DOM names share a
    /// keyCode — keypad Enter against main Enter — and a dictionary-order
    /// dependency would make a recorded binding depend on hash seeding.
    func testReverseLookupIsStableAndRoundTrips() {
        for name in ["KeyA", "Digit0", "Slash", "Space", "Escape", "F12"] {
            guard let code = KeyCode.appKitCode(for: name) else {
                return XCTFail("\(name) has no reverse mapping")
            }
            XCTAssertEqual(KeyCode.domCode(for: code), name)
        }
        for _ in 0..<50 {
            XCTAssertEqual(KeyCode.appKitCode(for: "KeyA"), KeyCode.appKitCode(for: "KeyA"))
        }
    }

    /// Guards the bug the compiler caught once already: two keyCodes claiming the
    /// same DOM name makes a binding silently unreachable, and two codes with one
    /// name cannot be expressed in a Swift dictionary literal at all, so the
    /// failure shows up as a build break rather than as a broken shortcut. This
    /// test keeps the *values* honest too.
    func testNoTwoKeysClaimTheSameName() {
        var seen = Set<String>()
        for name in KeyCode.bindableNames {
            XCTAssertTrue(seen.insert(name).inserted, "\(name) appears more than once")
        }
    }

    func testTheTableHasNoUnmappedHolesInTheBindableRange() {
        // Every entry must round-trip. A one-way mapping would still compile and
        // would still look fine in a recording UI until it tried to save.
        for name in KeyCode.bindableNames {
            guard let code = KeyCode.appKitCode(for: name) else {
                return XCTFail("\(name) cannot be reversed")
            }
            XCTAssertEqual(KeyCode.domCode(for: code), name)
        }
    }

    func testTheTableIsLargeEnoughToBeUseful() {
        XCTAssertGreaterThan(KeyCode.bindableNames.count, 80)
    }
}
