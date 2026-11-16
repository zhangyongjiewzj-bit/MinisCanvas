import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("P3-CMD-01 持久快捷键规范化")
@MainActor
struct ShortcutOverrideNormalizationTests {
    private let defaultsKey = "miniscanvas.shortcuts.v1"

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "shortcut-normalize-\(UUID().uuidString)")!
    }

    @Test func legacyKeyIdentityIsCanonicalizedAndPersisted() throws {
        let defaults = makeDefaults()
        defaults.set(Data(
            #"{"createPipeline":{"key":" G ","modifiers":{"command":true,"control":false,"option":false,"shift":false}}}"#.utf8
        ), forKey: defaultsKey)

        let store = ShortcutStore(defaults: defaults)
        let canonical = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
        #expect(store.binding(for: .createPipeline) == canonical)
        #expect(ShortcutBinding(key: " RIGHTARROW ", modifiers: ShortcutModifiers.command).key == "rightArrow")

        let data = try #require(defaults.data(forKey: defaultsKey))
        let persisted = try JSONDecoder().decode([String: ShortcutBinding].self, from: data)
        #expect(persisted[ShortcutAction.createPipeline.id] == canonical)
    }

    @Test func restartDropsUnknownReservedAndCanonicalCollisions() throws {
        let defaults = makeDefaults()
        let duplicate = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
        var legacyDuplicate = duplicate
        legacyDuplicate.key = " G " // 模拟绕过新构造器的旧 JSON 值。
        let payload: [String: ShortcutBinding] = [
            ShortcutAction.createPipeline.id: duplicate,
            ShortcutAction.openSettings.id: legacyDuplicate,
            ShortcutAction.newSession.id: ShortcutBinding(key: "q", modifiers: ShortcutModifiers.command),
            "retiredCommand": ShortcutBinding(key: "z", modifiers: ShortcutModifiers.command),
        ]
        defaults.set(try JSONEncoder().encode(payload), forKey: defaultsKey)

        let store = ShortcutStore(defaults: defaults)
        #expect(store.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)
        #expect(store.binding(for: .openSettings) == ShortcutAction.openSettings.defaultBinding)
        #expect(store.binding(for: .newSession) == ShortcutAction.newSession.defaultBinding)

        let data = try #require(defaults.data(forKey: defaultsKey))
        let persisted = try JSONDecoder().decode([String: ShortcutBinding].self, from: data)
        #expect(persisted.isEmpty)
    }

    @Test func fallbackCollisionConvergesWithoutDroppingUnrelatedOverride() throws {
        let defaults = makeDefaults()
        let duplicate = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
        // ⌘Y belongs to approveRequest; use an actually unrelated binding.
        let preserved = ShortcutBinding(key: "u", modifiers: ShortcutModifiers.command)
        let payload: [String: ShortcutBinding] = [
            ShortcutAction.mainPaneChat.id: duplicate,
            ShortcutAction.mainPaneCanvas.id: duplicate,
            ShortcutAction.createPipeline.id: ShortcutAction.mainPaneChat.defaultBinding,
            ShortcutAction.openSettings.id: preserved,
        ]
        defaults.set(try JSONEncoder().encode(payload), forKey: defaultsKey)

        let store = ShortcutStore(defaults: defaults)
        #expect(store.binding(for: .mainPaneChat) == ShortcutAction.mainPaneChat.defaultBinding)
        #expect(store.binding(for: .mainPaneCanvas) == ShortcutAction.mainPaneCanvas.defaultBinding)
        #expect(store.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)
        #expect(store.binding(for: .openSettings) == preserved)

        let data = try #require(defaults.data(forKey: defaultsKey))
        let persisted = try JSONDecoder().decode([String: ShortcutBinding].self, from: data)
        #expect(persisted == [ShortcutAction.openSettings.id: preserved])
        #expect(ShortcutStore(defaults: defaults).binding(for: .openSettings) == preserved)
    }

    @Test func liveConflictAndResetStillUseCanonicalKeys() {
        let store = ShortcutStore(defaults: makeDefaults())
        let collision = ShortcutBinding(key: " 1 ", modifiers: ShortcutModifiers.command)
        #expect(store.setBinding(collision, for: .createPipeline) == .action(.mainPaneChat))
        #expect(store.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)

        let changed = ShortcutBinding(key: " G ", modifiers: ShortcutModifiers.command)
        #expect(store.setBinding(changed, for: .createPipeline) == nil)
        #expect(store.binding(for: .createPipeline).key == "g")
        store.reset(for: .createPipeline)
        #expect(store.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)
    }

    @Test(arguments: [false, true])
    func resetRejectsOccupiedDefaultWithoutChangingLiveOrPersistedBindings(disabled: Bool) throws {
        let defaults = makeDefaults()
        let store = ShortcutStore(defaults: defaults)
        let prior = disabled
            ? ShortcutBinding(key: "", modifiers: ShortcutModifiers.none)
            : ShortcutBinding(key: "u", modifiers: ShortcutModifiers.command)
        let occupiedDefault = ShortcutAction.openSettings.defaultBinding
        #expect(store.setBinding(prior, for: .openSettings) == nil)
        #expect(store.setBinding(occupiedDefault, for: .newSession) == nil)
        let persistedBefore = try #require(defaults.data(forKey: defaultsKey))

        #expect(store.reset(for: .openSettings) == .action(.newSession))
        #expect(store.binding(for: .openSettings) == prior)
        #expect(store.binding(for: .newSession) == occupiedDefault)
        #expect(defaults.data(forKey: defaultsKey) == persistedBefore)

        let reopened = ShortcutStore(defaults: defaults)
        #expect(reopened.binding(for: .openSettings) == prior)
        #expect(reopened.binding(for: .newSession) == occupiedDefault)
        #expect(defaults.data(forKey: defaultsKey) == persistedBefore)

        // Releasing the default makes the same restore valid; no user's other
        // binding is silently cleared to make the rejected restore succeed.
        #expect(store.reset(for: .newSession) == nil)
        #expect(store.reset(for: .openSettings) == nil)
        #expect(store.binding(for: .openSettings) == occupiedDefault)
        #expect(store.binding(for: .newSession) == ShortcutAction.newSession.defaultBinding)
        let restored = ShortcutStore(defaults: defaults)
        #expect(restored.binding(for: .openSettings) == occupiedDefault)
        #expect(restored.binding(for: .newSession) == ShortcutAction.newSession.defaultBinding)
    }

    @Test func paletteResetPreservesLegacyCommandKOwnerAndUsesControlSpaceFallback() throws {
        let defaults = makeDefaults()
        let store = ShortcutStore(defaults: defaults)
        let customPalette = ShortcutBinding(key: "u", modifiers: ShortcutModifiers.command)
        let commandK = ShortcutAction.commandPalette.defaultBinding
        let fallback = ShortcutBinding(key: "space", modifiers: ShortcutModifiers.control)
        #expect(!ShortcutStore.systemReserved.contains(customPalette))
        #expect(ShortcutAction.allCases.allSatisfy { store.binding(for: $0) != customPalette })
        #expect(store.setBinding(customPalette, for: .commandPalette) == nil)
        #expect(store.setBinding(commandK, for: .newSession) == nil)

        #expect(store.reset(for: .commandPalette) == nil)
        #expect(store.binding(for: .commandPalette) == fallback)
        #expect(store.binding(for: .newSession) == commandK)
        let reopened = ShortcutStore(defaults: defaults)
        #expect(reopened.binding(for: .commandPalette) == fallback)
        #expect(reopened.binding(for: .newSession) == commandK)

        #expect(store.reset(for: .newSession) == nil)
        #expect(store.binding(for: .commandPalette) == commandK)
        #expect(store.binding(for: .newSession) == ShortcutAction.newSession.defaultBinding)
        #expect(ShortcutStore(defaults: defaults).binding(for: .commandPalette) == commandK)
    }
}
