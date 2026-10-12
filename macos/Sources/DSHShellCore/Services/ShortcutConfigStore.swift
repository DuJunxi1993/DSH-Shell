import Foundation

/// One shortcut configuration snapshot, in the shape dsh compares by value.
///
/// Shapes are from `@deepseek-ai/dsh-client-shortcuts/lib/types/persistence.d.ts`
/// and `configuration.d.ts`:
///
/// ```ts
/// ShortcutConfigSnapshot = {
///   revision: ShortcutRevision;          // randomUUID(), minted on every accept
///   sequence: number;                    // monotonic within one storage-owner lifetime
///   document: { schemaVersion: 1 | 2; profiles: Partial<Record<profile, Record<id, ShortcutBinding | null>>> };
///   status: 'loading' | 'ready' | 'unreadable';
///   error: 'read' | 'invalid' | 'future' | null;
///   usingDefaults: boolean;
/// }
/// ```
///
/// Four details are load-bearing and were previously wrong:
///
/// - `profiles[profile][id]` is a **`ShortcutBinding` object or `null`**, not a
///   string. A string cannot express `modifiers`, so it is not a binding dsh can
///   parse and the user's shortcut is silently ignored.
/// - `null` is meaningful: it explicitly **unbinds** a command, which is not
///   the same as absent — absent means "inherit the declared default".
/// - `revision` is **not persisted**. It is minted on every accepted change, so
///   a revision read back after a relaunch is expected to differ.
/// - Only the **document** goes in the file, and on desktop macOS/Windows it is
///   written at `schemaVersion: 2`, because version 1 cannot express chords.
public struct ShortcutSnapshot: Equatable, Sendable {
    public var revision: String
    public var sequence: Int
    public var document: Document
    /// `loading` | `ready` | `unreadable`.
    public var status: String
    /// `read` | `invalid` | `future` | nil.
    public var error: String?
    public var usingDefaults: Bool

    public struct Document: Equatable, Sendable {
        /// Only 1 and 2 exist. Version 1 predates two-key chords, so a
        /// `secondCode` read from a version 1 document is corruption.
        public var schemaVersion: Int
        /// Keyed by `"runtime:platform"`. See `ShortcutOverride` for why an
        /// unbind is a case rather than a nil value.
        public var profiles: [String: [String: ShortcutOverride]]

        public init(schemaVersion: Int = 1, profiles: [String: [String: ShortcutOverride]] = [:]) {
            self.schemaVersion = schemaVersion
            self.profiles = profiles
        }

        var json: [String: Any] {
            var encoded: [String: [String: Any]] = [:]
            for (profile, commands) in profiles {
                var bindings: [String: Any] = [:]
                for (id, override) in commands {
                    switch override {
                    case .unbound: bindings[id] = NSNull()
                    case .bound(let binding): bindings[id] = binding.json
                    }
                }
                encoded[profile] = bindings
            }
            return ["schemaVersion": schemaVersion, "profiles": encoded]
        }
    }

    public init(revision: String = UUID().uuidString,
                sequence: Int = 0,
                document: Document = Document(),
                status: String = "loading",
                error: String? = nil,
                usingDefaults: Bool = true) {
        self.revision = revision
        self.sequence = sequence
        self.document = document
        self.status = status
        self.error = error
        self.usingDefaults = usingDefaults
    }

    public var dictionary: [String: Any] {
        [
            "revision": revision,
            "sequence": sequence,
            "document": document.json,
            "status": status,
            "error": error as Any? ?? NSNull(),
            "usingDefaults": usingDefaults,
        ]
    }

    /// A JSON literal, for splicing into an `evaluateJavaScript` string.
    public var jsLiteral: String {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }
}

extension ShortcutBinding {
    var json: [String: Any] {
        var record: [String: Any] = ["code": code, "modifiers": modifiers.map(\.rawValue)]
        if let secondCode { record["secondCode"] = secondCode }
        return record
    }
}

/// The device-local shortcut preferences dsh reads and writes through us.
///
/// A port of `ShortcutPersistence` plus its `ShortcutStorage` file adapter,
/// synchronised. It is a class rather than a struct because the accepted state
/// is deliberately in-memory: `revision` and `sequence` belong to "one storage
/// owner lifetime" and are re-minted on every accept, exactly as dsh does. A
/// struct would either re-read the file per call or silently share mutable
/// state with its copies.
///
/// Not `localStorage`: dsh's rule is "Desktop never falls back to browser
/// storage", and a per-origin store would be exactly that fallback — two copies
/// of the user's keybindings, disagreeing.
public final class ShortcutConfigStore {
    public static var defaultPath: String {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DSHShell/keybindings.json").path
    }

    public let url: URL
    private let runtime: String
    private let platform: String

    /// The raw file content behind ``accepted``. Compared on every read so an
    /// unchanged file keeps its revision instead of minting a new one.
    private var raw: String?
    private var accepted: ShortcutSnapshot
    private var definitions: [EffectiveShortcut.Definition] = []

    public init(url: URL = URL(fileURLWithPath: ShortcutConfigStore.defaultPath),
                runtime: String = "desktop",
                platform: String = "macos") {
        self.url = url
        self.runtime = runtime
        self.platform = platform
        // dsh's `initialShortcutConfig`: loading, empty document, no error. It
        // becomes `ready` on the first read, and `edit` refuses everything until
        // then.
        self.accepted = .init(status: "loading", usingDefaults: true)
    }

    /// The catalog dsh passed with the latest `shortcuts.get`.
    ///
    /// Required before any edit can be accepted: dsh refuses to bind a command it
    /// has not published a definition for, because an unknown id would be
    /// written to the file and never resolve to a command.
    public func setDefinitions(_ definitions: [EffectiveShortcut.Definition]) {
        self.definitions = definitions
    }

    /// The current accepted snapshot, reading the file only when it changed.
    public func readCurrent() -> ShortcutSnapshot {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            if raw != nil {
                // The file disappeared under us: dsh treats that as "no
                // preferences", not as corruption.
                raw = nil
                accept(.init(), status: "ready", usingDefaults: true)
            } else if accepted.status == "loading" {
                accept(.init(), status: "ready", usingDefaults: true)
            }
            return accepted
        }
        guard contents != raw else { return accepted }
        raw = contents
        switch Self.parseDocument(contents) {
        case .success(let document):
            accept(document, status: "ready", usingDefaults: false)
        case .failure(let failure):
            // The document is left as last accepted, so a transient read problem
            // does not discard preferences the user cannot restore.
            Log.error("""
                keybindings.json is \(failure == .future ? "from a newer schema" : "corrupt"); \
                preferences are disabled and the file is left alone
                """)
            accept(accepted.document, status: "unreadable", error: failure.rawValue)
        }
        return accepted
    }

    /// dsh's `accept`: bump the sequence and mint a fresh identity.
    private func accept(_ document: ShortcutSnapshot.Document,
                        status: String,
                        error: String? = nil,
                        usingDefaults: Bool? = nil) {
        accepted = .init(
            revision: UUID().uuidString,
            sequence: accepted.sequence + 1,
            document: document,
            status: status,
            error: error,
            usingDefaults: usingDefaults ?? accepted.usingDefaults
        )
    }

    /// The chords dsh will consume, or `nil` while the catalog is unknown.
    ///
    /// Returning `nil` rather than an empty set matters: an empty set would be
    /// the claim "dsh binds nothing", which would leave the keyboard dead for
    /// the whole session.
    public func dispatchKeys() -> Set<String>? {
        let snapshot = readCurrent()
        guard !definitions.isEmpty, snapshot.status == "ready" else { return nil }
        return ShortcutModel.effectiveShortcuts(
            definitions: definitions,
            overrides: snapshot.document.profiles["\(runtime):\(platform)"] ?? [:],
            runtime: runtime,
            platform: platform
        ).dispatchKeys
    }

    // MARK: - Reading the file

    /// The classification of a stored file, mirroring `parseShortcutDocument`:
    /// a document, or the reason it is unusable.
    public enum ReadFailure: String, Error, Equatable, Sendable {
        case invalid
        case future
    }

    public static func parseDocument(_ raw: String) -> Result<ShortcutSnapshot.Document, ReadFailure> {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(.invalid) }
        // Unknown fields are rejected rather than dropped: a rewrite would
        // delete preferences this version does not understand.
        guard object.keys.allSatisfy({ $0 == "schemaVersion" || $0 == "profiles" }) else {
            return .failure(.invalid)
        }
        guard let schemaVersion = object["schemaVersion"] as? Int else { return .failure(.invalid) }
        if schemaVersion > 2 { return .failure(.future) }
        guard schemaVersion == 1 || schemaVersion == 2 else { return .failure(.invalid) }
        guard let rawProfiles = object["profiles"] as? [String: Any] else { return .failure(.invalid) }

        var profiles: [String: [String: ShortcutOverride]] = [:]
        for (profile, rawOverrides) in rawProfiles {
            guard isProfileName(profile), let overrides = rawOverrides as? [String: Any] else {
                return .failure(.invalid)
            }
            var bindings: [String: ShortcutOverride] = [:]
            for (id, rawBinding) in overrides {
                guard isCommandId(id) else { return .failure(.invalid) }
                if rawBinding is NSNull {
                    bindings[id] = .unbound
                    continue
                }
                guard let binding = parseBinding(rawBinding) else { return .failure(.invalid) }
                if schemaVersion == 1, binding.secondCode != nil { return .failure(.invalid) }
                // Reject a binding dsh itself would refuse to register, rather
                // than storing it and having every later read reject the file.
                guard ShortcutModel.normalize(binding, platform: "macos") != nil else {
                    return .failure(.invalid)
                }
                bindings[id] = .bound(binding)
            }
            profiles[profile] = bindings
        }
        return .success(.init(schemaVersion: schemaVersion, profiles: profiles))
    }

    /// dsh's `parseBinding`: unknown fields are rejected to prevent lossy
    /// rewrites.
    static func parseBinding(_ value: Any) -> ShortcutBinding? {
        guard let record = value as? [String: Any],
              record.keys.allSatisfy({ ["code", "secondCode", "modifiers"].contains($0) }),
              let code = record["code"] as? String,
              let rawModifiers = record["modifiers"] as? [String],
              rawModifiers.allSatisfy({ ShortcutModifier(rawValue: $0) != nil })
        else { return nil }
        return ShortcutBinding(code: code,
                               secondCode: record["secondCode"] as? String,
                               modifiers: rawModifiers.compactMap { ShortcutModifier(rawValue: $0) })
    }

    /// `^(desktop|web):(macos|windows|linux)$`
    static func isProfileName(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 2 else { return false }
        return ["desktop", "web"].contains(String(parts[0]))
            && ["macos", "windows", "linux"].contains(String(parts[1]))
    }

    /// `^[a-z][a-zA-Z0-9-]*(\.[a-zA-Z][a-zA-Z0-9]*)+$`
    static func isCommandId(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        func isHead(_ segment: Substring) -> Bool {
            guard let first = segment.first, first.isASCII, first.isLowercase else { return false }
            return segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        func isTail(_ segment: Substring) -> Bool {
            guard let first = segment.first, first.isASCII, first.isLetter else { return false }
            return segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
        return isHead(parts[0]) && parts.dropFirst().allSatisfy(isTail)
    }

    private func readRaw() -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Writes the document only — never the snapshot.
    ///
    /// dsh's adapter does `JSON.stringify(document, null, 2) + "\n"`, and its
    /// parser rejects unknown top-level keys, so writing `revision` and
    /// `sequence` here would make the host reject its own file on the next
    /// launch.
    ///
    /// - Returns: the exact bytes written, which ``readCurrent`` then caches.
    ///   Without that, the next read sees "changed" content and mints a second
    ///   revision for one edit.
    private func write(_ document: ShortcutSnapshot.Document) -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: document.json,
                                                  options: [.prettyPrinted, .sortedKeys])
            let contents = String(decoding: data + Data("\n".utf8), as: UTF8.self)
            // Atomic: a half-written keybindings file reads back as corrupt on
            // the next launch and silently resets the user's shortcuts.
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
            return contents
        } catch {
            Log.error("cannot write \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Editing

    /// The outcome of an edit, matching `ShortcutSaveResult`.
    public struct SaveResult: Equatable, Sendable {
        /// `saved` | `stale` | `unreadable` | `write-failed` | `not-ready` | `conflict`
        public var status: String
        public var snapshot: ShortcutSnapshot
        public var issue: BindingIssue?
        public var conflicts: [String]

        public var resultDictionary: [String: Any] {
            var record: [String: Any] = ["status": status, "snapshot": snapshot.dictionary]
            if let issue { record["issue"] = issue.rawValue }
            if !conflicts.isEmpty { record["conflicts"] = conflicts }
            return record
        }
    }

    /// Apply one of dsh's constrained preference operations.
    ///
    /// ```ts
    /// { type: 'set', id, binding: ShortcutBinding | null }
    /// { type: 'reset', id }
    /// { type: 'reset-all' }
    /// ```
    ///
    /// A stale revision is refused rather than merged, because two surfaces
    /// (dsh's settings page and the shell's own menu) can be looking at the same
    /// configuration.
    public func applyEdit(_ edit: [String: Any],
                          against revision: String?) -> SaveResult {
        let current = readCurrent()
        func result(_ status: String,
                    issue: BindingIssue? = nil,
                    conflicts: [String] = []) -> SaveResult {
            .init(status: status, snapshot: current, issue: issue, conflicts: conflicts)
        }

        guard current.status != "loading" else { return result("not-ready") }
        if let revision, revision != current.revision { return result("stale") }
        guard current.status == "ready" else { return result("unreadable") }
        guard let kind = edit["type"] as? String else { return result("not-ready") }

        // dsh refuses a command it has no definition for: the id would be written
        // to the file and never resolve to anything.
        if kind == "set" || kind == "reset" {
            guard let id = edit["id"] as? String,
                  definitions.contains(where: { $0.id == id && $0.fixed == nil })
            else { return result("not-ready") }
        }

        guard let candidate = candidateDocument(for: edit, kind: kind, from: current.document) else {
            return result("not-ready")
        }

        let rows = ShortcutModel.effectiveShortcuts(definitions: definitions,
                                                    overrides: candidate.profiles["\(runtime):\(platform)"] ?? [:],
                                                    runtime: runtime,
                                                    platform: platform).rows
        let affected = kind == "reset-all" ? rows : rows.filter { $0.id == edit["id"] as? String }
        let invalid = affected.first { ($0.issue != nil || !$0.conflicts.isEmpty) && $0.binding != nil }
        let displaced = kind == "set"
            ? rows.first { $0.conflicts.contains(edit["id"] as? String ?? "") }
            : nil
        if invalid != nil || displaced != nil {
            let conflicts = invalid.flatMap { row in row.conflicts.isEmpty ? nil : row.conflicts }
                ?? displaced.map { [$0.id] } ?? []
            return result("conflict",
                          issue: invalid?.issue.flatMap(BindingIssue.init(rawValue:)),
                          conflicts: conflicts)
        }

        guard let contents = write(candidate) else { return result("write-failed") }
        raw = contents
        accept(candidate, status: "ready", error: nil, usingDefaults: false)
        return .init(status: "saved", snapshot: accepted, conflicts: [])
    }

    /// dsh's `editShortcutDocument`: applies the operation to this profile only,
    /// leaving other profiles and dormant overrides untouched.
    private func candidateDocument(for edit: [String: Any],
                                   kind: String,
                                   from document: ShortcutSnapshot.Document) -> ShortcutSnapshot.Document? {
        // Desktop macOS/Windows write version 2, because version 1 cannot
        // express the two-key chords the catalog allows.
        let schemaVersion = (runtime == "desktop" && (platform == "macos" || platform == "windows"))
            ? 2
            : document.schemaVersion
        let profile = "\(runtime):\(platform)"
        var overrides = document.profiles[profile] ?? [:]
        switch kind {
        case "set":
            guard let id = edit["id"] as? String else { return nil }
            let raw = edit["binding"]
            if raw is NSNull {
                overrides[id] = .unbound
            } else {
                guard let binding = Self.parseBinding(raw),
                      let normalized = ShortcutModel.normalize(binding, platform: platform)
                else { return nil }
                overrides[id] = .bound(normalized)
            }
        case "reset":
            guard let id = edit["id"] as? String else { return nil }
            overrides.removeValue(forKey: id)
        case "reset-all":
            overrides = [:]
        default:
            return nil
        }
        var profiles = document.profiles
        profiles[profile] = overrides
        return .init(schemaVersion: schemaVersion, profiles: profiles)
    }
}