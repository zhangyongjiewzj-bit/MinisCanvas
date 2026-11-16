import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("2095 shortcut Store typed adapter", .serialized)
@MainActor
struct ShortcutStoreTypedCatalogAdapter2095Tests {
    private func makeDefaults() throws -> (String, UserDefaults) {
        let name = "ShortcutTyped2095.\(UUID().uuidString)"
        return (name, try #require(UserDefaults(suiteName: name)))
    }

    private func value(_ key: String, command: Bool = false,
                       control: Bool = false, option: Bool = false,
                       shift: Bool = false) -> BL6SettingValue {
        .object([
            "key": .text(key),
            "modifiers": .object([
                "command": .toggle(command),
                "control": .toggle(control),
                "option": .toggle(option),
                "shift": .toggle(shift),
            ]),
        ])
    }

    @Test("typed snapshot uses the live Store and a successful write survives reopen")
    func applyAndReopen() throws {
        let (domain, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ShortcutStore(defaults: defaults)
        let id = ShortcutStoreTypedCatalogAdapter.settingID(for: .createPipeline)
        let proposed = value("g", command: true)
        let beforeSnapshot = ShortcutStoreTypedCatalogAdapter.snapshot(from: store)
        #expect(beforeSnapshot.count == ShortcutAction.allCases.count)
        // Canvas pipeline has no default shortcut; typed snapshot must preserve
        // that disabled binding before applying the isolated custom key.
        #expect(beforeSnapshot[id] == value(""))

        guard case .success(let preview) = ShortcutStoreTypedCatalogAdapter.preview(
            settingID: id, value: proposed, in: store
        ) else {
            Issue.record("A free canonical binding must preview successfully")
            return
        }
        #expect(preview.before == ShortcutAction.createPipeline.defaultBinding)
        #expect(preview.proposed == ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command))
        #expect(store.binding(for: .createPipeline) == preview.before)

        guard case .success(let effect) = ShortcutStoreTypedCatalogAdapter.apply(
            settingID: id, value: proposed, to: store
        ) else {
            Issue.record("A free canonical binding must apply through ShortcutStore")
            return
        }
        #expect(effect.before == preview.before)
        #expect(effect.after == preview.proposed)
        #expect(ShortcutStoreTypedCatalogAdapter.snapshot(from: store)[id] == proposed)
        let reopened = ShortcutStore(defaults: defaults)
        #expect(reopened.binding(for: .createPipeline) == effect.after)
        #expect(ShortcutStoreTypedCatalogAdapter.snapshot(from: reopened)[id] == proposed)

        guard case .success(let reset) = ShortcutStoreTypedCatalogAdapter.reset(
            settingID: id, in: reopened
        ) else {
            Issue.record("Reset must delegate to ShortcutStore")
            return
        }
        #expect(reset.before == effect.after)
        #expect(reset.after == ShortcutAction.createPipeline.defaultBinding)
        #expect(ShortcutStore(defaults: defaults).binding(for: .createPipeline) == reset.after)
    }

    @Test("action collisions and system-reserved keys reject without persistence")
    func conflictsDoNotWrite() throws {
        let (domain, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ShortcutStore(defaults: defaults)
        let id = ShortcutStoreTypedCatalogAdapter.settingID(for: .createPipeline)
        let before = ShortcutStoreTypedCatalogAdapter.snapshot(from: store)

        for (input, expected) in [
            (value("1", command: true), ShortcutConflict.action(.mainPaneChat)),
            (value("space", command: true), ShortcutConflict.system),
        ] {
            guard case .failure(.conflict(let reason)) = ShortcutStoreTypedCatalogAdapter.preview(
                settingID: id, value: input, in: store
            ) else {
                Issue.record("Existing Store conflict must reach typed preview")
                return
            }
            #expect(reason == expected)
            guard case .failure(.conflict(let appliedReason)) = ShortcutStoreTypedCatalogAdapter.apply(
                settingID: id, value: input, to: store
            ) else {
                Issue.record("Existing Store conflict must reject typed apply")
                return
            }
            #expect(appliedReason == expected)
        }
        #expect(ShortcutStoreTypedCatalogAdapter.snapshot(from: store) == before)
        #expect(ShortcutStoreTypedCatalogAdapter.snapshot(from: ShortcutStore(defaults: defaults)) == before)
    }

    @Test("unknown or malformed typed keys fail closed; disabled binding remains valid")
    func typedValidation() throws {
        let (domain, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ShortcutStore(defaults: defaults)
        let id = ShortcutStoreTypedCatalogAdapter.settingID(for: .createPipeline)
        let before = ShortcutStoreTypedCatalogAdapter.snapshot(from: store)
        let malformed: [BL6SettingValue] = [
            .text("g"),
            value("LONG", command: true),
            value("", command: true),
            .object(["key": .text("g")]),
        ]
        for input in malformed {
            guard case .failure(.invalidValue(let rejectedID)) = ShortcutStoreTypedCatalogAdapter.apply(
                settingID: id, value: input, to: store
            ) else {
                Issue.record("Malformed typed binding must be rejected")
                return
            }
            #expect(rejectedID == id)
        }
        guard case .failure(.unknownSetting(let unknown)) = ShortcutStoreTypedCatalogAdapter.apply(
            settingID: "shortcuts.unknown", value: value("g", command: true), to: store
        ) else {
            Issue.record("Unknown action must be rejected")
            return
        }
        #expect(unknown == "shortcuts.unknown")
        #expect(ShortcutStoreTypedCatalogAdapter.snapshot(from: store) == before)

        guard case .success(let disabled) = ShortcutStoreTypedCatalogAdapter.apply(
            settingID: id, value: value(""), to: store
        ) else {
            Issue.record("Existing Store permits a genuinely empty binding")
            return
        }
        #expect(disabled.after.isEmpty)
        #expect(ShortcutStore(defaults: defaults).binding(for: .createPipeline).isEmpty)
    }
}
