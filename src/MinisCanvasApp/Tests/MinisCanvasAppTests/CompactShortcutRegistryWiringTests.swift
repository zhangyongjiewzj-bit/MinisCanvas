import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("D-COMMAND-04 压缩会话快捷键接入")
@MainActor
struct CompactShortcutRegistryWiringTests {
    @Test func compactActionStartsUnboundAndMapsToExistingCommand() {
        let defaults = UserDefaults(suiteName: "compact-shortcut-\(UUID().uuidString)")!
        let shortcuts = ShortcutStore(defaults: defaults)
        let bridge = BridgeStore(shortcutStore: shortcuts)

        #expect(ShortcutAction.compactContext.group == .session)
        #expect(shortcuts.binding(for: .compactContext).isEmpty)
        #expect(AppCommandCatalog.shortcutAction(forCommandID: "ui.chat.compact") == .compactContext)
        #expect(bridge.commandRegistry.command(id: "ui.chat.compact") != nil)
    }

    @Test func configuredCompactBindingPersistsAndUpdatesCommandBadge() {
        let defaults = UserDefaults(suiteName: "compact-shortcut-\(UUID().uuidString)")!
        let shortcuts = ShortcutStore(defaults: defaults)
        let bridge = BridgeStore(shortcutStore: shortcuts)
        let binding = ShortcutBinding(key: "k", modifiers: .commandShift)

        #expect(shortcuts.setBinding(binding, for: .compactContext) == nil)
        #expect(shortcuts.binding(for: .compactContext) == binding)
        #expect(bridge.paletteDisplay["ui.chat.compact"]?.shortcut == binding.displayString)
        #expect(ShortcutStore(defaults: defaults).binding(for: .compactContext) == binding)

        shortcuts.reset(for: .compactContext)
        #expect(shortcuts.binding(for: .compactContext).isEmpty)
    }

    @Test func compactBindingRejectsExistingActionShortcut() {
        let defaults = UserDefaults(suiteName: "compact-shortcut-\(UUID().uuidString)")!
        let shortcuts = ShortcutStore(defaults: defaults)
        let conflict = shortcuts.setBinding(
            ShortcutAction.newSession.defaultBinding,
            for: .compactContext
        )

        #expect(conflict == .action(.newSession))
        #expect(shortcuts.binding(for: .compactContext).isEmpty)
    }

    @Test func contentViewRoutesCompactBindingThroughCommandRegistry() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MinisCanvasApp/ContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("bridge.runCommand(id: \"ui.chat.compact\")"))
        #expect(source.contains(".shortcutKey(shortcut(.compactContext))"))
    }
}
