import Foundation

/// Physical key code translation between AppKit and the DOM.
///
/// dsh binds shortcuts by **physical** key, using DOM `KeyboardEvent.code`
/// values — "KeyN", "Digit1", "Backquote", "Slash". That is the right model:
/// a binding is about a key's position, not about which character the current
/// layout prints on it. It also means this mapping has to be explicit, because
/// `NSEvent.keyCode` and `code` are unrelated numberings.
///
/// The two useful properties of the AppKit side:
///
///   - `keyCode` is the **hardware position**, not the produced character, so it
///     is reported the same way on a Dvorak or AZERTY layout. A shortcut bound
///     to physical `KeyN` stays on physical `KeyN`.
///   - The numbers below are the ANSI virtual codes, which is exactly the
///     ordering the DOM `code` names were derived from.
///
/// Everything is a pure lookup so the whole table can be asserted in a test; a
/// gap in it would show up as "some shortcuts do nothing", which is a miserable
/// thing to diagnose from a user's report.
public enum KeyCode {
    /// DOM `code` for an AppKit virtual key code, or `nil` when the key has no
    /// DOM equivalent worth binding.
    ///
    /// `nil` is the honest answer for the numeric keypad and for keys dsh never
    /// binds: returning something wrong would make a chord dispatch to a command
    /// the user did not assign.
    public static func domCode(for keyCode: UInt16) -> String? {
        table[keyCode]
    }

    /// Reverse lookup, for a shortcut-recording UI that has to go from a pressed
    /// key back to the name it stores.
    public static func appKitCode(for dom: String) -> UInt16? {
        reverse[dom]
    }

    /// Printable DOM names, for a "press a key" recorder to offer.
    public static var bindableNames: [String] {
        table.values.sorted()
    }

    // ANSI virtual codes. Letters are not sequential in A–Z order on macOS (they
    // follow the QWERTY sequence starting at A=0, S=1, D=2…), and the digits
    // are not sequential either (the physical 6/5 swap at 22/23). That is why
    // this table is spelled out rather than computed — and why the first draft of
    // it had two keyCodes each listed twice (33 as both `KeyI` and
    // `BracketLeft`, 39 as both `KeyK` and `Quote`), which the Swift compiler
    // rejected as duplicate dictionary keys. The real ANSI assignments:
    private static let table: [UInt16: String] = [
        // Letters — ANSI order, not alphabetical.
        0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG",
        6: "KeyZ", 7: "KeyX", 8: "KeyC", 9: "KeyV", 11: "KeyB", 12: "KeyQ",
        13: "KeyW", 14: "KeyE", 15: "KeyR", 16: "KeyY", 17: "KeyT",
        31: "KeyO", 32: "KeyU", 33: "KeyI", 34: "KeyP", 37: "KeyL",
        38: "KeyJ", 40: "KeyK", 45: "KeyN", 46: "KeyM",

        // Top row. The physical swap of 5 and 6 is in the hardware, not here.
        18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 22: "Digit6",
        23: "Digit5", 25: "Digit9", 26: "Digit7", 28: "Digit8", 29: "Digit0",

        // Punctuation.
        24: "Equal", 27: "Minus", 30: "BracketRight", 35: "BracketLeft",
        39: "Quote", 41: "Semicolon", 42: "Backslash", 43: "Comma",
        44: "Slash", 47: "Period", 50: "Backquote",
        // ISO keyboards report the extra key here rather than as IntlBackslash.
        10: "IntlBackslash",

        // Control keys.
        36: "Enter", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape",
        // The numeric keypad is deliberately absent: its keys occupy positions
        // DOM calls `NumpadEnter` and friends, dsh's UI does not offer them, and
        // mapping them would mean a chord could dispatch to a binding the user
        // never made.

        // Modifiers. macOS names Command and Option; the DOM calls them Meta
        // and Alt.
        55: "MetaLeft", 56: "ShiftLeft", 57: "CapsLock", 58: "AltLeft",
        59: "ControlLeft", 60: "ShiftRight", 61: "AltRight", 62: "ControlRight",
        // 63 is Fn, which is not a modifier the DOM models.

        // Arrows and navigation.
        114: "Help", 115: "Home", 116: "PageUp", 119: "End", 121: "PageDown",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",

        // Function keys. macOS exposes F13–F20 too; dsh's UI does not offer them
        // by default but a user can bind one, and losing them silently would be
        // worse than carrying the extra rows.
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    /// Keep the lowest keyCode for a duplicated name, so the reverse lookup is a
    /// function rather than dictionary-order-dependent.
    private static let reverse: [String: UInt16] = {
        var map: [String: UInt16] = [:]
        for (key, name) in table {
            if let existing = map[name], existing <= key { continue }
            map[name] = key
        }
        return map
    }()
}