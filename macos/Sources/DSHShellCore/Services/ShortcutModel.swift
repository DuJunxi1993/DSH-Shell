import Foundation

/// The shortcut model, ported from dsh 0.2.0-rc.2
/// (`@deepseek-ai/dsh-client-shortcuts`, `lib/client.js`, `lib/types/*.d.ts`).
///
/// ## Why this is a port rather than a guess
///
/// The host has to answer one question before it can forward a keystroke:
/// **will dsh consume this chord?** If the host swallows chords dsh ignores,
/// the composer's text never appears; if it forwards everything, dsh's own
/// bindings fire twice. The answer is not a matter of taste — dsh computes it,
/// from data it hands the host itself.
///
/// `shortcuts.get(definitions)` passes the *live command catalog* to the host on
/// every registration (measured: 28 calls, growing as modules activate). Each
/// entry declares `defaults` per profile, and the host already owns the user's
/// overrides. Together those are everything `effectiveShortcuts` needs, so the
/// host can reproduce dsh's binding table exactly instead of approximating it.
///
/// ## What dsh does with a matched chord
///
/// In `dispatch`, on desktop builds, `priority` is true and `consume()` runs
/// for every matched binding — including conflicting ones, which return
/// `blocked` *after* consuming. An unmatched chord returns `pass` and is never
/// consumed. So the set of chords the host must swallow is exactly
/// `bindings ∪ conflicts`, which is what ``effectiveShortcuts`` returns here.
public enum ShortcutModifier: String, CaseIterable, Sendable {
    /// Expands to `meta` on macOS and `control` elsewhere. Never appears in a
    /// normalized binding or in an input event.
    case primary
    case control
    case alt
    case shift
    case meta

    /// A modifier as it arrives in native input: the four physical flags only.
    ///
    /// `primary` is absent by construction — native input reports the flag that
    /// was physically held, and dsh expands `primary` when it normalizes.
    static let inputOrder = ["control", "alt", "shift", "meta"]
}

/// A stored override for one command.
///
/// An enum rather than `ShortcutBinding?`, because Swift's dictionary cannot
/// hold "present with a nil value": assigning nil to a subscript removes the
/// key. dsh's document distinguishes those two states — absent means "inherit
/// the default", `null` means "unbind" — so the difference has to survive being
/// stored, or an unbound command silently comes back bound.
public enum ShortcutOverride: Equatable, Sendable {
    case unbound
    case bound(ShortcutBinding)
}

/// One physical key, or two held together, plus an exact set of modifiers.
///
/// `modifiers` is a *set*, not a mask to test: dsh's `dispatch` builds a key
/// from the modifiers present and requires an exact match, so ⌘⇧B does not
/// trigger a ⌘B binding.
public struct ShortcutBinding: Equatable, Sendable {
    public var code: String
    public var secondCode: String?
    public var modifiers: [ShortcutModifier]

    public init(code: String, secondCode: String? = nil, modifiers: [ShortcutModifier] = []) {
        self.code = code
        self.secondCode = secondCode
        self.modifiers = modifiers
    }
}

/// One row of the settings UI: a command and what it is currently bound to.
public struct EffectiveShortcut: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var id: String
        public var binding: ShortcutBinding?
        /// Whether the user overrode the declared default.
        public var modified: Bool
        /// `nil` when the binding is usable; otherwise why it is not.
        public var issue: String?
        public var conflicts: [String]
    }

    public var rows: [Row]
    public var fixed: [Row]

    /// The chords dsh will consume, on desktop: enabled bindings plus
    /// conflicting ones.
    ///
    /// Both maps in dsh's `dispatch` lead to `consume()`. A conflicting row is
    /// shown to the user, refuses to run, and still eats the keystroke — so
    /// leaving it out would make the key visibly dead in the shell.
    public var dispatchKeys: Set<String> {
        Set(rows.compactMap { $0.binding.map { ShortcutModel.bindingKey($0) } })
    }
}

/// Validation failures, named as dsh names them so the settings UI can select
/// its own copy without translation.
public enum BindingIssue: String, Sendable {
    case reserved
    case unsupportedBrowser = "unsupported-browser"
    case modifierRequired = "modifier-required"
    case unsupportedKey = "unsupported-key"
}

public enum ShortcutModel {

    /// dsh's `modifierOrder`. The order is also the keycap order, and it is
    /// what makes `bindingKey` stable across registration order.
    public static let modifierOrder: [ShortcutModifier] = [.control, .alt, .shift, .meta]

    /// dsh's `keyNames`: the physical codes that are not `Key*`/`Digit*`/`F*`.
    static let namedCodes: Set<String> = [
        "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash",
        "Semicolon", "Quote", "Enter", "Escape", "Space", "Tab",
        "Backspace", "Delete",
        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
        "Comma", "Period", "Slash", "Backquote",
    ]

    static func isSupportedCode(_ code: String) -> Bool {
        if namedCodes.contains(code) { return true }
        // ^(Key[A-Z]|Digit[0-9]|F([1-9]|1[0-9]|2[0-4]))$
        if code.hasPrefix("Key"), code.count == 4,
           let scalar = code.last, scalar.isASCII, scalar.isUppercase { return true }
        if code.hasPrefix("Digit"), code.count == 6, code.last!.isNumber { return true }
        if code.hasPrefix("F"), let value = Int(code.dropFirst()), (1...24).contains(value) { return true }
        return false
    }

    /// dsh's `normalizeBinding`: sort the keys, expand `primary`, dedupe and
    /// order the modifiers.
    ///
    /// Returns nil for an unsupported code or two identical keys, which is what
    /// dsh throws on. Callers on the write path treat that as a rejected edit
    /// rather than letting a malformed binding into the document.
    public static func normalize(_ binding: ShortcutBinding, platform: String) -> ShortcutBinding? {
        var codes = [binding.code]
        if let second = binding.secondCode { codes.append(second) }
        codes.sort()
        guard codes.allSatisfy(isSupportedCode) else { return nil }
        if codes.count == 2 && codes[0] == codes[1] { return nil }

        var expanded = Set<ShortcutModifier>()
        for modifier in binding.modifiers {
            if modifier == .primary {
                expanded.insert(platform == "macos" ? .meta : .control)
            } else {
                expanded.insert(modifier)
            }
        }
        return ShortcutBinding(code: codes[0],
                               secondCode: codes.count == 2 ? codes[1] : nil,
                               modifiers: modifierOrder.filter { expanded.contains($0) })
    }

    /// dsh's `bindingKey`: modifiers in canonical order, then the sorted keys.
    ///
    /// The argument must be normalized, as it is everywhere in dsh: `primary`
    /// is not a modifier a match can carry, so passing an unexpanded one would
    /// produce a key nothing ever compares equal to.
    public static func bindingKey(_ binding: ShortcutBinding) -> String {
        var codes = [binding.code]
        if let second = binding.secondCode { codes.append(second) }
        codes.sort()
        return (binding.modifiers.map(\.rawValue) + codes).joined(separator: "+")
    }

    /// dsh's `isWebBindingAllowed`.
    ///
    /// Only consulted for the `web` runtime. The desktop path returns before
    /// reaching it, which is why the macOS host never needs this table to be
    /// right about ⌘C or ⌘W.
    public static func isWebBindingAllowed(_ binding: ShortcutBinding, platform: String) -> Bool {
        if binding.secondCode != nil { return false }
        if platform == "windows" || platform == "macos" {
            if binding.modifiers.count >= 3 { return true }
            let primary: ShortcutModifier = platform == "macos" ? .meta : .control
            if binding.modifiers.count == 1,
               (["Comma", "Backslash"].contains(binding.code) && binding.modifiers[0] == primary
                || binding.code == "Backquote" && binding.modifiers[0] == .control) {
                return true
            }
            if binding.modifiers.count == 2,
               binding.modifiers.contains(primary),
               binding.modifiers.contains(.alt) || binding.modifiers.contains(.shift) {
                return true
            }
        }
        // The combinations every browser is allowed to deliver, even where the
        // rules above do not reach.
        let portable = [
            ShortcutBinding(code: "Slash", modifiers: [.primary]),
            ShortcutBinding(code: "Comma", modifiers: [.primary, .shift]),
            ShortcutBinding(code: "Period", modifiers: [.primary, .shift]),
        ]
        return portable.contains { candidate in
            guard let normalized = normalize(candidate, platform: platform) else { return false }
            return bindingKey(normalized) == bindingKey(binding)
        }
    }

    /// dsh's `bindingIssue`.
    ///
    /// The first line is the reason this whole filter is worth having: on
    /// desktop macOS and Windows **there are no reserved combinations**, so
    /// dsh will happily bind ⌘W or ⌘Q and expects the host to give them up.
    /// Every reservation below applies to the web runtime only.
    public static func bindingIssue(_ binding: ShortcutBinding,
                                    runtime: String,
                                    platform: String) -> BindingIssue? {
        if runtime == "desktop", platform == "windows" || platform == "macos" { return nil }
        if binding.secondCode != nil { return .unsupportedKey }
        let modifiers = binding.modifiers
        if modifiers.isEmpty || modifiers.allSatisfy({ $0 == .shift }) { return .modifierRequired }
        if (platform == "windows" || platform == "macos"), modifiers.count >= 3 { return nil }
        if runtime == "web", (platform == "windows" || platform == "macos"),
           isWebBindingAllowed(binding, platform: platform) { return nil }
        let primary = modifiers.contains(platform == "macos" ? .meta : .control)
        let structural: Set<String> = [
            "Escape", "Tab", "Space", "Backspace", "Delete",
            "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
        ]
        if structural.contains(binding.code) { return .reserved }
        if binding.code == "Enter", !modifiers.contains(.alt) { return .reserved }
        if primary, ["KeyC", "KeyV", "KeyX", "KeyZ", "KeyY", "KeyQ", "KeyH"].contains(binding.code) {
            return .reserved
        }
        if primary, binding.code == "KeyA", !modifiers.contains(.shift) { return .reserved }
        if platform != "macos",
           modifiers.contains(.meta) || (modifiers.contains(.alt) && ["F4", "F2"].contains(binding.code)) {
            return .reserved
        }
        if platform == "macos", modifiers.contains(.control), modifiers.contains(.meta) { return .reserved }
        if platform == "macos", modifiers.contains(.alt), !primary { return .reserved }
        return nil
    }

    /// dsh's `overlappingBindings`: identical combinations, or one key of a
    /// two-key chord held by the other binding.
    public static func overlapping(_ left: ShortcutBinding, _ right: ShortcutBinding) -> Bool {
        if left.modifiers != right.modifiers { return false }
        if left.secondCode != nil && right.secondCode != nil {
            return bindingKey(left) == bindingKey(right)
        }
        let leftCodes = [left.code, left.secondCode].compactMap { $0 }
        return leftCodes.contains { $0 == right.code || $0 == right.secondCode }
    }

    /// dsh's `effectiveShortcuts`.
    ///
    /// - Parameters:
    ///   - definitions: the catalog dsh passed to `shortcuts.get`, in
    ///     registration order.
    ///   - overrides: the user's bindings for `runtime:platform`, where an
    ///     explicit `nil` means unbound.
    public static func effectiveShortcuts(
        definitions: [EffectiveShortcut.Definition],
        overrides: [String: ShortcutOverride],
        runtime: String = "desktop",
        platform: String = "macos"
    ) -> EffectiveShortcut {
        // Fixed actions reserve their combinations outright, and are excluded
        // from the editable rows entirely — `fixed === undefined` is the test.
        let fixed = definitions.flatMap { definition -> [EffectiveShortcut.Row] in
            (definition.fixed ?? []).compactMap { binding in
                guard let normalized = normalize(binding, platform: platform) else { return nil }
                return .init(id: definition.id, binding: normalized, modified: false,
                             issue: nil, conflicts: [])
            }
        }
        let profile = "\(runtime):\(platform)"
        let rows = definitions.filter { $0.fixed == nil }.map { definition -> EffectiveShortcut.Row in
            // `keys.contains`, not `overrides[id] != nil`: the dictionary's value
            // type is itself optional, and an explicit `null` — an unbind — is
            // present-and-nil, which must count as modified.
            let modified = overrides.keys.contains(definition.id)
            let candidate: ShortcutBinding? = modified
                ? overrides[definition.id].flatMap { override in
                    guard case .bound(let binding) = override else { return nil }
                    return binding
                }
                : definition.defaults[profile]
            let binding = candidate.flatMap { normalize($0, platform: platform) }
            let issue = binding.flatMap { bindingIssue($0, runtime: runtime, platform: platform) }
            return .init(id: definition.id, binding: binding, modified: modified,
                         issue: issue?.rawValue, conflicts: [])
        }
        // Conflict resolution runs over the finished rows, because it is order
        // independent: an unmodified row loses to a modified one, so a user's
        // override always wins regardless of registration order.
        let resolved = rows.map { row -> EffectiveShortcut.Row in
            guard let binding = row.binding else { return row }
            var ids: [String] = []
            for other in rows where other.id != row.id {
                guard let otherBinding = other.binding,
                      other.issue == nil,
                      overlapping(otherBinding, binding),
                      !row.modified || other.modified
                else { continue }
                ids.append(other.id)
            }
            for other in fixed where overlapping(other.binding!, binding) {
                ids.append(other.id)
            }
            var seen = Set<String>()
            let unique = ids.filter { seen.insert($0).inserted }
            return .init(id: row.id, binding: binding, modified: row.modified,
                         issue: row.issue, conflicts: unique)
        }
        return EffectiveShortcut(rows: resolved, fixed: fixed)
    }
}

// MARK: - The catalog dsh sends

extension EffectiveShortcut {
    /// One entry of `shortcuts.get(definitions)`.
    public struct Definition: Equatable, Sendable {
        public var id: String
        /// Bindings per `"runtime:platform"`, e.g. `"desktop:macos"`.
        public var defaults: [String: ShortcutBinding]
        /// Present only for fixed actions: combinations reserved by the owner
        /// and not offered to the user.
        public var fixed: [ShortcutBinding]?

        public init(id: String, defaults: [String: ShortcutBinding], fixed: [ShortcutBinding]? = nil) {
            self.id = id
            self.defaults = defaults
            self.fixed = fixed
        }

        /// Decodes one catalog entry. An entry that does not parse is dropped
        /// rather than fatal: dsh sends the catalog incrementally as modules
        /// register, and a host that throws on entry 14 of 28 has a dead
        /// keyboard for the rest of the session.
        public static func decode(_ value: [String: Any]) -> Definition? {
            guard let id = value["id"] as? String else { return nil }
            var defaults: [String: ShortcutBinding] = [:]
            if let raw = value["defaults"] as? [String: Any] {
                for (profile, binding) in raw {
                    if let binding = decodeBinding(binding) { defaults[profile] = binding }
                }
            }
            var fixed: [ShortcutBinding]?
            if let raw = value["fixed"] as? [Any] {
                let bindings = raw.compactMap { $0 as? [String: Any] }.compactMap(decodeBinding)
                if !bindings.isEmpty { fixed = bindings }
            }
            return Definition(id: id, defaults: defaults, fixed: fixed)
        }

        static func decodeBinding(_ value: Any) -> ShortcutBinding? {
            guard let record = value as? [String: Any],
                  let code = record["code"] as? String,
                  let rawModifiers = record["modifiers"] as? [String]
            else { return nil }
            let modifiers = rawModifiers.compactMap { ShortcutModifier(rawValue: $0) }
            // An unknown modifier name would silently widen the set if ignored.
            guard modifiers.count == rawModifiers.count else { return nil }
            return ShortcutBinding(code: code,
                                   secondCode: record["secondCode"] as? String,
                                   modifiers: modifiers)
        }
    }
}