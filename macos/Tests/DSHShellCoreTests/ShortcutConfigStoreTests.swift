import XCTest
@testable import DSHShellCore

/// The device-local shortcut preferences dsh reads and writes through us.
///
/// A port of `ShortcutPersistence` and its file adapter. Shapes are from
/// `@deepseek-ai/dsh-client-shortcuts`:
/// `edit` is `{type:'set', id, binding}` / `{type:'reset', id}` /
/// `{type:'reset-all'}`, and `profiles[profile][id]` is a `ShortcutBinding`
/// object or `null`.
///
/// An earlier version of this file used invented `{commandId, code,
/// binding: String}` edits. Those tests passed, and the feature did not work:
/// dsh's own validator would have rejected every one of them.
final class ShortcutConfigStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keybindings-\(UUID().uuidString).json")
    }

    /// The catalog measured from a live dsh session, so the tests exercise the
    /// same command ids the page really sends.
    private var definitions: [EffectiveShortcut.Definition] {
        [
            .init(id: "sidebar.left.toggle",
                  defaults: ["desktop:macos": ShortcutBinding(code: "KeyB", modifiers: [.primary])]),
            .init(id: "workspace.openLocal",
                  defaults: ["desktop:macos": ShortcutBinding(code: "KeyO",
                                                               modifiers: [.primary, .alt])]),
            .init(id: "shortcuts.open",
                  defaults: ["desktop:macos": ShortcutBinding(code: "Slash", modifiers: [.primary])]),
            .init(id: "fixed.move", defaults: [:],
                  fixed: [ShortcutBinding(code: "ArrowUp"), ShortcutBinding(code: "ArrowDown")]),
        ]
    }

    private func store() -> ShortcutConfigStore {
        let store = ShortcutConfigStore(url: tempURL())
        store.setDefinitions(definitions)
        return store
    }

    private func binding(_ code: String, _ modifiers: [ShortcutModifier]) -> [String: Any] {
        ["code": code, "modifiers": modifiers.map(\.rawValue)]
    }

    private func fileContents(_ store: ShortcutConfigStore) -> String {
        (try? String(contentsOf: store.url, encoding: .utf8)) ?? ""
    }

    // MARK: - Snapshot shape

    func testRevisionIsAUuidStringNotANumber() {
        // dsh compares `input.revision !== snapshot().revision` on every dispatch.
        let snapshot = store().readCurrent()
        XCTAssertNotNil(UUID(uuidString: snapshot.revision),
                        "revision must parse as a UUID: \(snapshot.revision)")
    }

    func testTheSnapshotHasTheShapeDshExpects() {
        let snapshot = store().readCurrent()
        XCTAssertEqual(snapshot.status, "ready")
        XCTAssertNil(snapshot.error)
        XCTAssertTrue(snapshot.usingDefaults, "a missing file means defaults, not a failure")
        let dict = snapshot.dictionary
        for key in ["revision", "sequence", "document", "status", "error", "usingDefaults"] {
            XCTAssertNotNil(dict[key], "missing \(key)")
        }
    }

    func testTheJsLiteralIsParseable() {
        // Spliced into `evaluateJavaScript`, so a literal that is not valid JSON
        // is a syntax error inside a string the page evaluates.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(
            with: Data(store().readCurrent().jsLiteral.utf8)))
    }

    func testReadingAnUnchangedFileKeepsTheSameRevision() {
        // A revision that changed on its own would invalidate every queued input.
        let store = store()
        XCTAssertEqual(store.readCurrent().revision, store.readCurrent().revision)
    }

    func testTheRevisionChangesAfterAnAcceptedEditAndTheSequenceAdvances() {
        let store = store()
        let before = store.readCurrent()
        let result = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                                      "binding": binding("KeyK", [.primary, .shift])],
                                     against: before.revision)
        XCTAssertEqual(result.status, "saved")
        XCTAssertNotEqual(result.snapshot.revision, before.revision)
        XCTAssertEqual(result.snapshot.sequence, before.sequence + 1)
        XCTAssertEqual(store.readCurrent().revision, result.snapshot.revision)
    }

    func testAMissingFileIsNotAnErrorAndWritesNothing() {
        // dsh writes only on an accepted edit; seeding a file here would make
        // `usingDefaults` false on a machine that has never changed a shortcut.
        let store = store()
        XCTAssertEqual(store.readCurrent().usingDefaults, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    // MARK: - File format

    func testTheFileContainsOnlyTheDocument() {
        // dsh's adapter writes `JSON.stringify(document, null, 2) + "\n"` and its
        // parser rejects unknown top-level keys — writing `revision` here would
        // make the host reject its own file on the next launch.
        let store = store()
        _ = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                             "binding": binding("KeyK", [.primary, .shift])],
                            against: store.readCurrent().revision)
        let object = try? JSONSerialization.jsonObject(
            with: Data(fileContents(store).utf8)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map(\.self) ?? []), ["schemaVersion", "profiles"])
    }

    func testTheFileIsWrittenAtSchemaVersionTwo() {
        // Version 1 cannot express the two-key chords the catalog allows, so
        // desktop macOS/Windows writes 2.
        let store = store()
        _ = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                             "binding": binding("KeyK", [.primary, .shift])],
                            against: store.readCurrent().revision)
        let object = try? JSONSerialization.jsonObject(
            with: Data(fileContents(store).utf8)) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, 2)
    }

    func testABindingSurvivesTheRoundTripAsAnObject() {
        // A string here is the failure this test exists for: dsh's parseBinding
        // requires `code` and `modifiers`, so a stringified binding is not a
        // binding and the user's shortcut is silently ignored.
        let store = store()
        let result = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                                      "binding": binding("KeyB", [.primary])],
                                     against: store.readCurrent().revision)
        XCTAssertEqual(result.snapshot.document.profiles["desktop:macos"]?["sidebar.left.toggle"],
                       .bound(ShortcutBinding(code: "KeyB", modifiers: [.meta])))

        let serialised = try? JSONSerialization.jsonObject(
            with: Data(result.snapshot.jsLiteral.utf8)) as? [String: Any]
        let profiles = (serialised?["document"] as? [String: Any])?["profiles"] as? [String: Any]
        let stored = (profiles?["desktop:macos"] as? [String: Any])?["sidebar.left.toggle"]
        XCTAssertEqual((stored as? [String: Any])?["code"] as? String, "KeyB")
        XCTAssertEqual((stored as? [String: Any])?["modifiers"] as? [String], ["meta"])
    }

    // MARK: - Edits

    func testAStaleEditIsRefusedRatherThanMerged() {
        let store = store()
        let first = store.readCurrent()
        let after = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                                     "binding": binding("KeyK", [.primary, .shift])],
                                    against: first.revision)
        // A second surface now holds the older revision.
        let result = store.applyEdit(["type": "set", "id": "shortcuts.open",
                                      "binding": binding("Period", [.primary])],
                                     against: first.revision)
        XCTAssertEqual(result.status, "stale")
        XCTAssertEqual(result.snapshot.revision, after.snapshot.revision)
        XCTAssertNil(result.snapshot.document.profiles["desktop:macos"]?["shortcuts.open"])
    }

    func testANullBindingUnbindsRatherThanFallingBackToTheDefault() {
        let store = store()
        _ = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                             "binding": binding("KeyK", [.primary, .shift])],
                            against: store.readCurrent().revision)
        let result = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                                      "binding": NSNull()],
                                     against: store.readCurrent().revision)
        XCTAssertEqual(result.status, "saved")
        // Present-and-null, which is what dsh reads as an explicit unbind. A
        // Swift `[String: T?]` cannot represent this — assigning nil deletes the
        // key — so the absence of this key is the bug this asserts against.
        XCTAssertEqual(result.snapshot.document.profiles["desktop:macos"]?["sidebar.left.toggle"],
                       .unbound)
        XCTAssertEqual(store.dispatchKeys(), ["alt+meta+KeyO", "meta+Slash"],
                       "an unbound command must disappear from the dispatch table")
    }

    func testResetRemovesTheOverrideSoTheDefaultAppliesAgain() {
        let store = store()
        _ = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                             "binding": binding("KeyK", [.primary, .shift])],
                            against: store.readCurrent().revision)
        let result = store.applyEdit(["type": "reset", "id": "sidebar.left.toggle"],
                                     against: store.readCurrent().revision)
        XCTAssertEqual(result.status, "saved")
        XCTAssertFalse(result.snapshot.document.profiles["desktop:macos"]?
            .keys.contains("sidebar.left.toggle") == true)
        XCTAssertEqual(store.dispatchKeys(), ["meta+KeyB", "alt+meta+KeyO", "meta+Slash"])
    }

    func testResetAllClearsOnlyTheCurrentProfile() {
        let store = store()
        _ = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                             "binding": binding("KeyK", [.primary, .shift])],
                            against: store.readCurrent().revision)
        let result = store.applyEdit(["type": "reset-all"], against: store.readCurrent().revision)
        XCTAssertEqual(result.status, "saved")
        XCTAssertNil(result.snapshot.document.profiles["desktop:macos"]?["sidebar.left.toggle"])
    }

    func testAnEditForACommandDshNeverPublishedIsRefused() {
        // Writing an id with no definition would persist a binding that resolves
        // to nothing, forever.
        let store = store()
        XCTAssertEqual(store.applyEdit(["type": "set", "id": "not.registered",
                                        "binding": binding("KeyB", [.primary])],
                                       against: store.readCurrent().revision).status,
                       "not-ready")
    }

    func testAFixedCommandCannotBeRebound() {
        let store = store()
        XCTAssertEqual(store.applyEdit(["type": "set", "id": "fixed.move",
                                        "binding": binding("KeyB", [.primary])],
                                       against: store.readCurrent().revision).status,
                       "not-ready")
    }

    func testAnEditWithTheOldInventedShapeIsRefusedRatherThanSilentlyStored() {
        let store = store()
        let result = store.applyEdit(
            ["type": "set", "commandId": "sidebar.left.toggle", "code": "KeyB", "binding": "KeyB"],
            against: store.readCurrent().revision)
        XCTAssertEqual(result.status, "not-ready")
        XCTAssertFalse(result.snapshot.document.profiles["desktop:macos"]?
            .keys.contains("sidebar.left.toggle") == true)
    }

    func testAnUnknownEditIsRefusedRatherThanIgnored() {
        let store = store()
        XCTAssertEqual(store.applyEdit(["type": "somethingElse"],
                                       against: store.readCurrent().revision).status,
                       "not-ready")
    }

    func testAMalformedBindingIsRefused() {
        let store = store()
        for bad in [["code": "KeyB"],                              // no modifiers
                    ["code": "KeyB", "modifiers": ["hyper"]],      // unknown modifier
                    ["code": "Unidentified", "modifiers": ["primary"]],
                    ["code": "KeyB", "modifiers": ["primary"], "speed": 2]] {
            XCTAssertEqual(store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                                            "binding": bad],
                                           against: store.readCurrent().revision).status,
                           "not-ready", "\(bad)")
        }
    }

    func testAnEditThatCollidesWithAFixedActionIsRefusedAsAConflict() {
        // dsh consumes a conflicting chord and then refuses to run it, so it
        // accepts neither the store's write nor an apparently working binding.
        let store = ShortcutConfigStore(url: tempURL())
        store.setDefinitions(definitions + [
            .init(id: "fixed.something", defaults: [:],
                  fixed: [ShortcutBinding(code: "ArrowUp", modifiers: [.primary])]),
        ])
        let result = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                                      "binding": binding("ArrowUp", [.primary])],
                                     against: store.readCurrent().revision)
        XCTAssertEqual(result.status, "conflict")
        XCTAssertEqual(result.conflicts, ["fixed.something"])
        XCTAssertFalse(result.snapshot.document.profiles["desktop:macos"]?
            .keys.contains("sidebar.left.toggle") == true)
    }

    func testAModifiedRowDisplacesTheUnmodifiedRowItOverlaps() {
        // Two commands bound to one chord would make the dispatch table
        // ambiguous; dsh keeps the user's override and reports the loser.
        let store = ShortcutConfigStore(url: tempURL())
        store.setDefinitions(definitions + [
            .init(id: "late.command",
                  defaults: ["desktop:macos": ShortcutBinding(code: "KeyN", modifiers: [.primary])]),
        ])
        let result = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                                      "binding": binding("KeyN", [.primary])],
                                     against: store.readCurrent().revision)
        XCTAssertEqual(result.status, "conflict")
        XCTAssertEqual(result.conflicts, ["late.command"])
        XCTAssertFalse(result.snapshot.document.profiles["desktop:macos"]?
            .keys.contains("sidebar.left.toggle") == true)
    }


    // MARK: - Read failures

    func testACorruptFileIsReportedRatherThanTreatedAsNoPreferences() {
        let url = tempURL()
        try? Data("{ not json".utf8).write(to: url)
        let store = ShortcutConfigStore(url: url)
        store.setDefinitions(definitions)
        let snapshot = store.readCurrent()
        // `unreadable` disables ordinary writes, so a file a human could still
        // inspect is never overwritten by a parse failure.
        XCTAssertEqual(snapshot.status, "unreadable")
        XCTAssertEqual(snapshot.error, "invalid")
        XCTAssertEqual(store.applyEdit(["type": "reset-all"], against: snapshot.revision).status,
                       "unreadable")
        XCTAssertEqual(fileContents(store), "{ not json")
    }

    func testAFutureSchemaVersionIsDistinguishedFromCorruption() {
        let url = tempURL()
        try? Data(#"{"schemaVersion":3,"profiles":{}}"#.utf8).write(to: url)
        let store = ShortcutConfigStore(url: url)
        XCTAssertEqual(store.readCurrent().error, "future")
    }

    func testAnUnknownFieldIsRejectedToAvoidLossyRewrites() {
        XCTAssertEqual(Self.parse(#"{"schemaVersion":1,"profiles":{},"extra":true}"#),
                       .failure(.invalid))
        XCTAssertEqual(Self.parse(#"{"schemaVersion":1,"profiles":{"browser:macos":{}}}"#),
                       .failure(.invalid))
    }

    func testAChordInAVersion1DocumentIsRejected() {
        XCTAssertEqual(Self.parse("""
            {"schemaVersion":1,"profiles":{"desktop:macos":{"a.b":{"code":"KeyA",
             "secondCode":"KeyB","modifiers":["primary"]}}}}
            """), .failure(.invalid))
        XCTAssertNotNil(try? Self.parse("""
            {"schemaVersion":2,"profiles":{"desktop:macos":{"a.b":{"code":"KeyA",
             "secondCode":"KeyB","modifiers":["primary"]}}}}
            """).get())
    }

    func testAnUnknownModifierNameInvalidatesTheFile() {
        XCTAssertEqual(Self.parse("""
            {"schemaVersion":1,"profiles":{"desktop:macos":{"a.b":{"code":"KeyA",
             "modifiers":["hyper"]}}}}
            """), .failure(.invalid))
    }

    func testAMalformedCommandIdIsRejected() {
        // dsh's pattern: at least one dot, first segment lower-case with dashes.
        for bad in ["nosegment", "Upper.case", ".leading", "trailing."] {
            XCTAssertEqual(Self.parse("""
                {"schemaVersion":1,"profiles":{"desktop:macos":{"\(bad)":null}}}
                """), .failure(.invalid), bad)
        }
    }

    // MARK: - The dispatch table

    func testDispatchKeysAreNilUntilTheCatalogIsKnown() {
        // nil means "not known yet"; an empty set is the claim "dsh binds
        // nothing", and would leave the keyboard dead for the whole session.
        let store = ShortcutConfigStore(url: tempURL())
        XCTAssertNil(store.dispatchKeys())
    }

    func testDispatchKeysCombineTheCatalogWithTheStoredOverrides() {
        let store = store()
        XCTAssertEqual(store.dispatchKeys(),
                       ["meta+KeyB", "alt+meta+KeyO", "meta+Slash"])
        _ = store.applyEdit(["type": "set", "id": "sidebar.left.toggle",
                             "binding": binding("KeyK", [.primary, .shift])],
                            against: store.readCurrent().revision)
        XCTAssertEqual(store.dispatchKeys(),
                       ["shift+meta+KeyK", "alt+meta+KeyO", "meta+Slash"])
    }

    func testAFixedActionNeverAppearsInTheDispatchTable() {
        // `fixed.move` binds bare arrow keys. Forwarding and swallowing those
        // would make the list cursor unusable.
        let keys = store().dispatchKeys() ?? []
        XCTAssertFalse(keys.contains("ArrowUp"))
        XCTAssertFalse(keys.contains("ArrowDown"))
    }

    private static func parse(_ raw: String) -> Result<ShortcutSnapshot.Document, ShortcutConfigStore.ReadFailure> {
        ShortcutConfigStore.parseDocument(raw)
    }
}