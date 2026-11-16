import Foundation
import MinisCore

/// Typed view of the separately persisted shortcut settings. ShortcutStore
/// remains the only writer and the only owner of defaults and collision rules.
/// These keys are not part of BL6SettingsCatalog.production until its snapshot
/// and dispatch owners wire the same Store into one admitted settings turn.
@MainActor
enum ShortcutStoreTypedCatalogAdapter {
    enum Failure: Error, Equatable {
        case unknownSetting(String)
        case invalidValue(String)
        case conflict(ShortcutConflict)
    }

    struct Preview: Equatable {
        let settingID: String
        let action: ShortcutAction
        let before: ShortcutBinding
        let proposed: ShortcutBinding
    }

    /// `after` is observed from ShortcutStore after its synchronous write.
    /// It is not a cross-Store transaction or a durable-write receipt.
    struct Effect: Equatable {
        let settingID: String
        let before: ShortcutBinding
        let after: ShortcutBinding
    }

    static func settingID(for action: ShortcutAction) -> String {
        "shortcuts.\(action.rawValue)"
    }

    static func snapshot(from store: ShortcutStore) -> [String: BL6SettingValue] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { action in
            (settingID(for: action), value(for: store.binding(for: action)))
        })
    }

    static func preview(
        settingID: String,
        value: BL6SettingValue,
        in store: ShortcutStore
    ) -> Result<Preview, Failure> {
        guard let action = action(for: settingID) else {
            return .failure(.unknownSetting(settingID))
        }
        guard let proposed = binding(from: value) else {
            return .failure(.invalidValue(settingID))
        }
        if let conflict = store.conflict(for: action, to: proposed) {
            return .failure(.conflict(conflict))
        }
        return .success(Preview(
            settingID: settingID,
            action: action,
            before: store.binding(for: action),
            proposed: proposed
        ))
    }

    /// Revalidate on the Store's actor immediately before applying; a prior
    /// preview is informational and never authorizes a later changed binding.
    static func apply(
        settingID: String,
        value: BL6SettingValue,
        to store: ShortcutStore
    ) -> Result<Effect, Failure> {
        switch preview(settingID: settingID, value: value, in: store) {
        case .failure(let error):
            return .failure(error)
        case .success(let plan):
            if let conflict = store.setBinding(plan.proposed, for: plan.action) {
                return .failure(.conflict(conflict))
            }
            return .success(Effect(
                settingID: settingID,
                before: plan.before,
                after: store.binding(for: plan.action)
            ))
        }
    }

    /// Delegate reset semantics to the same Store. In particular, a reset
    /// conflicting with another user's override is rejected without writing.
    static func reset(
        settingID: String,
        in store: ShortcutStore
    ) -> Result<Effect, Failure> {
        guard let action = action(for: settingID) else {
            return .failure(.unknownSetting(settingID))
        }
        let before = store.binding(for: action)
        if let conflict = store.reset(for: action) {
            return .failure(.conflict(conflict))
        }
        return .success(Effect(
            settingID: settingID,
            before: before,
            after: store.binding(for: action)
        ))
    }

    private static func action(for settingID: String) -> ShortcutAction? {
        guard settingID.hasPrefix("shortcuts.") else { return nil }
        return ShortcutAction(rawValue: String(settingID.dropFirst("shortcuts.".count)))
    }

    private static func value(for binding: ShortcutBinding) -> BL6SettingValue {
        .object([
            "key": .text(binding.key),
            "modifiers": .object([
                "command": .toggle(binding.modifiers.command),
                "control": .toggle(binding.modifiers.control),
                "option": .toggle(binding.modifiers.option),
                "shift": .toggle(binding.modifiers.shift),
            ]),
        ])
    }

    private static func binding(from value: BL6SettingValue) -> ShortcutBinding? {
        guard case .object(let fields) = value,
              Set(fields.keys) == ["key", "modifiers"],
              case .text(let key)? = fields["key"],
              case .object(let modifiers)? = fields["modifiers"],
              Set(modifiers.keys) == ["command", "control", "option", "shift"],
              case .toggle(let command)? = modifiers["command"],
              case .toggle(let control)? = modifiers["control"],
              case .toggle(let option)? = modifiers["option"],
              case .toggle(let shift)? = modifiers["shift"] else {
            return nil
        }
        let flags = ShortcutModifiers(
            command: command, control: control, option: option, shift: shift
        )
        let normalized = ShortcutBinding(key: key, modifiers: flags)
        // Accept only the Store's exact canonical identity. A key with no
        // character but active modifiers is not a usable SwiftUI shortcut.
        guard key == normalized.key,
              !key.isEmpty || flags == .none else {
            return nil
        }
        return normalized
    }
}
