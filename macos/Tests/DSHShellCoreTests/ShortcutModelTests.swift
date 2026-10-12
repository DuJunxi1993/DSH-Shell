import XCTest
@testable import DSHShellCore

/// The shortcut model is a port of `@deepseek-ai/dsh-client-shortcuts`. Every
/// expectation here is either the shipped implementation's behaviour or a shape
/// measured from `shortcuts.get(definitions)` on dsh 0.2.0-rc.2. If dsh changes,
/// these fail — which is the point: a silent divergence here means a keyboard
/// that either eats typing or double-fires commands.
final class ShortcutModelTests: XCTestCase {

    // MARK: - normalizeBinding

    func testPrimaryExpandsToMetaOnMacOSAndControlElsewhere() {
        let binding = ShortcutBinding(code: "KeyB", modifiers: [.primary])
        let mac = ShortcutModel.normalize(binding, platform: "macos")
        let linux = ShortcutModel.normalize(binding, platform: "linux")
        XCTAssertEqual(mac?.modifiers, [.meta])
        XCTAssertEqual(linux?.modifiers, [.control])
    }

    func testModifiersAreDedupedAndPutInCanonicalOrder() {
        // dsh filters `modifierOrder`, so declaration order does not survive.
        let binding = ShortcutBinding(code: "KeyO",
                                      modifiers: [.shift, .primary, .primary, .control])
        let normalized = ShortcutModel.normalize(binding, platform: "macos")
        XCTAssertEqual(normalized?.modifiers, [.control, .shift, .meta])
    }

    func testChordKeysAreSortedSoEitherDeclarationOrderMatches() {
        let forwards = ShortcutBinding(code: "KeyB", secondCode: "KeyA", modifiers: [.primary])
        let backwards = ShortcutBinding(code: "KeyA", secondCode: "KeyB", modifiers: [.primary])
        let a = ShortcutModel.normalize(forwards, platform: "macos")
        let b = ShortcutModel.normalize(backwards, platform: "macos")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a?.code, "KeyA")
        XCTAssertEqual(a?.secondCode, "KeyB")
    }

    func testUnsupportedCodeIsRejected() {
        XCTAssertNil(ShortcutModel.normalize(ShortcutBinding(code: "KeyQ1"), platform: "macos"))
        XCTAssertNil(ShortcutModel.normalize(ShortcutBinding(code: "F25"), platform: "macos"))
        XCTAssertNil(ShortcutModel.normalize(ShortcutBinding(code: "Unidentified"), platform: "macos"))
    }

    func testIdenticalChordKeysAreRejected() {
        let binding = ShortcutBinding(code: "KeyA", secondCode: "KeyA", modifiers: [.meta])
        XCTAssertNil(ShortcutModel.normalize(binding, platform: "macos"))
    }

    func testSupportedCodesMatchTheShippedSet() {
        for code in ["KeyA", "KeyZ", "Digit0", "Digit9", "F1", "F24",
                     "Slash", "Comma", "Period", "Escape", "Enter", "Space",
                     "ArrowUp", "ArrowDown", "Backspace"] {
            XCTAssertTrue(ShortcutModel.isSupportedCode(code), code)
        }
        for code in ["F0", "F25", "keya", "Key", "Digit", "Digit10", ""] {
            XCTAssertFalse(ShortcutModel.isSupportedCode(code), code)
        }
    }

    // MARK: - bindingKey

    func testBindingKeyIsModifiersThenSortedCodes() {
        // Canonical order is dsh's: control, alt, shift, meta — not the order the
        // modifiers were written in, and not the ⌘-first order the menu shows.
        // Both bindings below are normalized, as dsh requires of this argument.
        let binding = ShortcutBinding(code: "KeyB", secondCode: "KeyA",
                                      modifiers: [.control, .meta])
        XCTAssertEqual(ShortcutModel.bindingKey(binding), "control+meta+KeyA+KeyB")
        XCTAssertEqual(ShortcutModel.bindingKey(ShortcutBinding(code: "KeyO",
                                                                 modifiers: [.alt, .meta])),
                       "alt+meta+KeyO")
    }

    // MARK: - bindingIssue

    func testDesktopMacOSHasNoReservedCombinations() {
        // The reason the host asks dsh for its binding table at all: on desktop
        // builds dsh binds ⌘W, ⌘Q and ⌘C, and expects the host to hand them up.
        for code in ["KeyW", "KeyQ", "KeyC", "KeyV", "KeyA", "Escape"] {
            let binding = ShortcutBinding(code: code, modifiers: [.meta])
            XCTAssertNil(ShortcutModel.bindingIssue(binding, runtime: "desktop", platform: "macos"),
                         code)
        }
    }

    func testWebRuntimeStillRejectsReservedAndUnmodifiedCombinations() {
        // ⌘C is reserved on the web, but allowed on desktop — which is why the
        // macOS host must not copy/paste through dsh.
        let clipboard = ShortcutBinding(code: "KeyC", modifiers: [.meta])
        XCTAssertEqual(ShortcutModel.bindingIssue(clipboard, runtime: "web", platform: "macos"),
                       .reserved)
        XCTAssertNil(ShortcutModel.bindingIssue(clipboard, runtime: "desktop", platform: "macos"))
        XCTAssertEqual(
            ShortcutModel.bindingIssue(ShortcutBinding(code: "KeyA"),
                                       runtime: "web", platform: "macos"),
            .modifierRequired)
        XCTAssertEqual(
            ShortcutModel.bindingIssue(ShortcutBinding(code: "KeyA", modifiers: [.shift]),
                                       runtime: "web", platform: "macos"),
            .modifierRequired)
        XCTAssertEqual(
            ShortcutModel.bindingIssue(ShortcutBinding(code: "KeyA", secondCode: "KeyB",
                                                        modifiers: [.primary]),
                                       runtime: "web", platform: "macos"),
            .unsupportedKey)
    }

    // MARK: - overlappingBindings

    func testOverlappingRequiresIdenticalModifiers() {
        let plain = ShortcutBinding(code: "KeyB", modifiers: [.meta])
        let shifted = ShortcutBinding(code: "KeyB", modifiers: [.meta, .shift])
        XCTAssertFalse(ShortcutModel.overlapping(plain, shifted))
        XCTAssertTrue(ShortcutModel.overlapping(plain, plain))
    }

    func testASingleKeyInsideAChordOverlaps() {
        let chord = ShortcutBinding(code: "KeyA", secondCode: "KeyB", modifiers: [.meta])
        let single = ShortcutBinding(code: "KeyB", modifiers: [.meta])
        XCTAssertTrue(ShortcutModel.overlapping(chord, single))
    }

    // MARK: - effectiveShortcuts

    /// The catalog measured from a live dsh session, reduced to the entries that
    /// exercise each rule.
    private var measuredDefinitions: [EffectiveShortcut.Definition] {
        [
            .init(id: "shortcuts.open",
                  defaults: ["desktop:macos": ShortcutBinding(code: "Slash", modifiers: [.primary])]),
            .init(id: "sidebar.left.toggle",
                  defaults: ["desktop:macos": ShortcutBinding(code: "KeyB", modifiers: [.primary])]),
            .init(id: "workspace.openLocal",
                  defaults: ["desktop:macos": ShortcutBinding(code: "KeyO",
                                                               modifiers: [.primary, .alt])]),
            .init(id: "fixed.move",
                  defaults: [:],
                  fixed: [ShortcutBinding(code: "ArrowUp"),
                          ShortcutBinding(code: "ArrowDown")]),
        ]
    }

    func testDefaultsBecomeDispatchKeysOnMacOS() {
        let keys = ShortcutModel.effectiveShortcuts(definitions: measuredDefinitions,
                                                    overrides: [:]).dispatchKeys
        XCTAssertEqual(keys, ["meta+Slash", "meta+KeyB", "alt+meta+KeyO"])
    }

    func testFixedActionsAreNotOfferedAsEditableRows() {
        let effective = ShortcutModel.effectiveShortcuts(definitions: measuredDefinitions,
                                                         overrides: [:])
        XCTAssertFalse(effective.rows.contains { $0.id == "fixed.move" })
        // They still reserve their keys.
        XCTAssertEqual(effective.fixed.count, 2)
    }

    func testAnOverrideDisplacesTheDefault() {
        let override = ShortcutBinding(code: "KeyK", modifiers: [.meta, .shift])
        let effective = ShortcutModel.effectiveShortcuts(
            definitions: measuredDefinitions,
            overrides: ["sidebar.left.toggle": .bound(override)])
        XCTAssertTrue(effective.dispatchKeys.contains("shift+meta+KeyK"))
        XCTAssertFalse(effective.dispatchKeys.contains("meta+KeyB"))
        XCTAssertTrue(effective.rows.first { $0.id == "sidebar.left.toggle" }?.modified == true)
    }

    func testAnExplicitNilUnbindsInsteadOfInheritingTheDefault() {
        let effective = ShortcutModel.effectiveShortcuts(
            definitions: measuredDefinitions,
            overrides: ["sidebar.left.toggle": .unbound])
        XCTAssertFalse(effective.dispatchKeys.contains("meta+KeyB"))
        let row = effective.rows.first { $0.id == "sidebar.left.toggle" }
        XCTAssertNil(row?.binding)
        XCTAssertTrue(row?.modified == true)
    }

    func testABareFixedActionCannotBeOverlappedByAModifiedBinding() {
        // `fixed.move` holds ArrowUp with no modifiers, and overlap requires the
        // same modifier set — so ⌘↑ does not collide with it.
        let effective = ShortcutModel.effectiveShortcuts(
            definitions: measuredDefinitions,
            overrides: ["workspace.openLocal": .bound(ShortcutBinding(code: "ArrowUp",
                                                                        modifiers: [.primary]))])
        XCTAssertEqual(effective.rows.first { $0.id == "workspace.openLocal" }?.conflicts, [])
        XCTAssertTrue(effective.dispatchKeys.contains("meta+ArrowUp"))
    }

    func testAModifiedBindingOverlappingAModifiedFixedActionIsAConflict() {
        let definitions = [
            EffectiveShortcut.Definition(id: "fixed.something", defaults: [:],
                                         fixed: [ShortcutBinding(code: "ArrowUp",
                                                                 modifiers: [.primary])]),
            EffectiveShortcut.Definition(
                id: "sidebar.left.toggle",
                defaults: ["desktop:macos": ShortcutBinding(code: "KeyB", modifiers: [.primary])]),
        ]
        let effective = ShortcutModel.effectiveShortcuts(
            definitions: definitions,
            overrides: ["sidebar.left.toggle": .bound(ShortcutBinding(code: "ArrowUp",
                                                                        modifiers: [.primary]))])
        XCTAssertEqual(effective.rows.first { $0.id == "sidebar.left.toggle" }?.conflicts,
                       ["fixed.something"])
        // dsh consumes a conflicting chord and then refuses to run it, so the
        // host must still swallow it; leaving it out would be a visibly dead key.
        XCTAssertTrue(effective.dispatchKeys.contains("meta+ArrowUp"))
    }

    func testAModifiedRowWinsOverAnUnmodifiedOneRegardlessOfOrder() {
        // dsh's rule is asymmetric: an unmodified row yields to a modified one
        // that overlaps it, so the user's override always wins — and the
        // registration order of the two does not matter.
        for modifiedLast in [true, false] {
            var definitions: [EffectiveShortcut.Definition] = []
            let early = EffectiveShortcut.Definition(
                id: "early.command",
                defaults: ["desktop:macos": ShortcutBinding(code: "KeyK", modifiers: [.primary])])
            let late = EffectiveShortcut.Definition(
                id: "late.command",
                defaults: ["desktop:macos": ShortcutBinding(code: "KeyJ", modifiers: [.primary])])
            definitions = modifiedLast ? [early, late] : [late, early]
            let effective = ShortcutModel.effectiveShortcuts(
                definitions: definitions,
                overrides: ["late.command": .bound(ShortcutBinding(code: "KeyK",
                                                                    modifiers: [.primary]))])
            let modified = effective.rows.first { $0.id == "late.command" }
            let displaced = effective.rows.first { $0.id == "early.command" }
            XCTAssertEqual(modified?.conflicts, [], "modified=\(modifiedLast)")
            XCTAssertEqual(displaced?.conflicts, ["late.command"], "modified=\(modifiedLast)")
        }
    }

    // MARK: - Decoding the catalog dsh sends

    func testCatalogEntryDecodesDefaultsAndFixed() {
        // Shape captured verbatim from the probe's `shortcutsGet` messages.
        let raw: [String: Any] = [
            "id": "workspace.openLocal",
            "defaults": ["desktop:macos": ["code": "KeyO", "modifiers": ["primary", "alt"]],
                         "desktop:windows": ["code": "KeyO", "modifiers": ["primary", "alt"]]],
            "fixed": [["code": "ArrowUp", "modifiers": []]],
        ]
        let definition = EffectiveShortcut.Definition.decode(raw)
        XCTAssertEqual(definition?.id, "workspace.openLocal")
        XCTAssertEqual(definition?.defaults["desktop:macos"],
                       ShortcutBinding(code: "KeyO", modifiers: [.primary, .alt]))
        XCTAssertEqual(definition?.fixed, [ShortcutBinding(code: "ArrowUp")])
    }

    func testAnUnknownModifierNameDropsTheEntryRatherThanWideningIt() {
        // Silently dropping "hyper" would produce a binding with fewer modifiers
        // than declared, which matches chords dsh never registered.
        let raw: [String: Any] = [
            "id": "some.command",
            "defaults": ["desktop:macos": ["code": "KeyB", "modifiers": ["hyper"]]],
        ]
        XCTAssertNotNil(EffectiveShortcut.Definition.decode(raw))
        let effective = ShortcutModel.effectiveShortcuts(
            definitions: [EffectiveShortcut.Definition.decode(raw)!], overrides: [:])
        XCTAssertTrue(effective.dispatchKeys.isEmpty)
    }

    func testAnEntryWithoutAnIdIsDropped() {
        XCTAssertNil(EffectiveShortcut.Definition.decode(["defaults": [:]]))
    }
}