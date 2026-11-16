import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("D-APP-08 命令面板默认键与旧改绑")
@MainActor
struct P3AcceptanceM05_CommandPaletteDefaultBindingTests {
    private let defaultsKey = "miniscanvas.shortcuts.v1"
    private let commandK = ShortcutBinding(key: "k", modifiers: ShortcutModifiers.command)
    private let controlSpace = ShortcutBinding(key: "space", modifiers: ShortcutModifiers.control)

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "m05-command-palette-\(UUID().uuidString)")!
    }

    @Test func newDefaultAndResetUseCommandKWithoutOverwritingExplicitPaletteChoice() throws {
        let preferences = defaults()
        let store = ShortcutStore(defaults: preferences)
        #expect(store.binding(for: .commandPalette) == commandK)

        // Simulate a preference written by the previous Ctrl+Space-default version.
        preferences.set(try JSONEncoder().encode([
            ShortcutAction.commandPalette.id: controlSpace
        ]), forKey: defaultsKey)
        let restored = ShortcutStore(defaults: preferences)
        #expect(restored.binding(for: .commandPalette) == controlSpace)
        #expect(restored.binding(for: .commandPalette).displayString == "⌃空格")

        restored.reset(for: .commandPalette)
        #expect(restored.binding(for: .commandPalette) == commandK)
        #expect(restored.binding(for: .commandPalette).displayString == "⌘K")
        #expect(restored.setBinding(controlSpace, for: .commandPalette) == nil)
        #expect(ShortcutStore(defaults: preferences).binding(for: .commandPalette) == controlSpace)
        restored.resetAll()
        #expect(restored.binding(for: .commandPalette) == commandK)
    }

    @Test func oldExplicitCommandKForAnotherActionSurvivesUpgradeAndPaletteReset() throws {
        let preferences = defaults()
        preferences.set(try JSONEncoder().encode([
            ShortcutAction.createPipeline.id: commandK
        ]), forKey: defaultsKey)

        let restored = ShortcutStore(defaults: preferences)
        #expect(restored.binding(for: .createPipeline) == commandK)
        #expect(restored.binding(for: .commandPalette) == controlSpace)
        restored.reset(for: .commandPalette)
        #expect(restored.binding(for: .createPipeline) == commandK)
        #expect(restored.binding(for: .commandPalette) == controlSpace)

        let persisted = try #require(preferences.data(forKey: defaultsKey))
        let overrides = try JSONDecoder().decode([String: ShortcutBinding].self, from: persisted)
        #expect(overrides[ShortcutAction.createPipeline.id] == commandK)
        #expect(overrides[ShortcutAction.commandPalette.id] == nil)

        restored.resetAll()
        #expect(restored.binding(for: .commandPalette) == commandK)
        #expect(restored.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)
    }

    @Test func twoOldExplicitClaimsLeavePaletteUnboundWithoutErasingEitherChoice() throws {
        let preferences = defaults()
        preferences.set(try JSONEncoder().encode([
            ShortcutAction.createPipeline.id: commandK,
            ShortcutAction.newSession.id: controlSpace
        ]), forKey: defaultsKey)

        let restored = ShortcutStore(defaults: preferences)
        #expect(restored.binding(for: .createPipeline) == commandK)
        #expect(restored.binding(for: .newSession) == controlSpace)
        #expect(restored.binding(for: .commandPalette).isEmpty)
        #expect(restored.conflict(for: .commandPalette, to: commandK) == .action(.createPipeline))
        #expect(restored.conflict(for: .commandPalette, to: controlSpace) == .action(.newSession))
    }

    @Test func welcomeDoesNotPromiseAKeyThatTheUserMayHaveRebound() throws {
        let preferences = defaults()
        let shortcuts = ShortcutStore(defaults: preferences)
        #expect(shortcuts.setBinding(controlSpace, for: .commandPalette) == nil)

        let chat = ChatStore()
        let welcome = try #require(chat.messages.first)
        #expect(welcome.role == .assistant)
        #expect(welcome.content.contains("设置 → 快捷键"))
        #expect(!welcome.content.contains("⌘K"))
        #expect(!welcome.content.contains("Ctrl+Space"))
        #expect(shortcuts.binding(for: .commandPalette) == controlSpace)
    }

    @Test func paletteSearchHintTracksTheEffectiveBindingAndItsRemoval() {
        let shortcuts = ShortcutStore(defaults: defaults())
        let view = CommandPaletteView(bridge: BridgeStore(shortcutStore: shortcuts))
        #expect(view.searchPlaceholder == "搜索命令…（⌘K）")

        #expect(shortcuts.setBinding(controlSpace, for: .commandPalette) == nil)
        #expect(view.searchPlaceholder == "搜索命令…（⌃空格）")

        let unbound = ShortcutBinding(key: "", modifiers: .none)
        #expect(shortcuts.setBinding(unbound, for: .commandPalette) == nil)
        #expect(view.searchPlaceholder == "搜索命令…")
    }
}
