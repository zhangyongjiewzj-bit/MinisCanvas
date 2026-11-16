import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-02 registered palette opener consumers", .serialized)
@MainActor
struct CommandPaletteRegistry2908ConsumerTests {
    private func fixture() throws -> (BridgeStore, LogManager, UserDefaults, String) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("command2908-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let suite = "command2908-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let bridge = BridgeStore(shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: log,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("Canvas disabled in owned fixture") },
            canvasRuntimeState: .disabled, canvasFeatureLane: .phase3NonCanvas)
        #expect(ProductionCommandRegistryWiring.bind(
            bridge: bridge, center: ComposerCommandAdjudicationCenter()))
        return (bridge, log, defaults, suite)
    }

    @MainActor private final class Counter { var effects = 0 }

    private func paletteRow(_ bridge: BridgeStore, defaults: UserDefaults) throws -> PaletteCommand {
        let palette = CommandPaletteModel(registry: bridge.commandRegistry,
            display: bridge.paletteDisplay,
            favorites: FavoriteCommandsStore(defaults: defaults),
            debounceInterval: .zero)
        return try #require(palette.sections.flatMap(\.commands)
            .first { $0.id == AppCommandCatalog.commandPaletteID })
    }

    fileprivate enum Entry: CaseIterable, Sendable { case slash, palette, menuOrShortcut }

    @Test("every opener consumer preserves the registered presentation effect",
          arguments: Entry.allCases)
    fileprivate func openingSurvivesRunnerCompletion(_ entry: Entry) async throws {
        let (bridge, log, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        var ordinaryProviderSubmissions = 0
        bridge.chat.onSendCommand = { _, _ in ordinaryProviderSubmissions += 1; return true }
        let before = bridge.chat.messages
        let command = try #require(bridge.commandRegistry.command(id: AppCommandCatalog.commandPaletteID))
        #expect(command.currentAvailability == .enabled)
        #expect(AppCommandCatalog.shortcutAction(forCommandID: command.id) == .commandPalette)
        switch entry {
        case .slash:
            bridge.chat.draftText = "/" + command.id
            bridge.chat.submitComposer()
        case .palette:
            bridge.runCommand(id: try paletteRow(bridge, defaults: defaults).id)
        case .menuOrShortcut:
            let row = try #require(AppCommandMenuBuilder.command(id: command.id,
                registry: bridge.commandRegistry, display: bridge.paletteDisplay))
            bridge.runCommand(id: row.id)
        }
        for _ in 0..<100 {
            if bridge.isCommandPalettePresented { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bridge.isCommandPalettePresented)
        // Keep reading after the async runner's normal completion. The effect
        // cannot be mistaken for an intermediate true subsequently dismissed.
        await Task.yield()
        #expect(bridge.isCommandPalettePresented)
        #expect(bridge.chat.messages == before)
        #expect(ordinaryProviderSubmissions == 0)
        #expect(bridge.chat.draftText.isEmpty)
        log.minimumLevel = .info
        bridge.runCommand(id: "log.level", args: ["level": "debug"])
        for _ in 0..<100 {
            if log.minimumLevel == .debug && !bridge.isCommandPalettePresented { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.minimumLevel == .debug)
        #expect(!bridge.isCommandPalettePresented)
        #expect(ordinaryProviderSubmissions == 0)
    }

    @Test("live shortcut rebinding and registry mutation reach palette menu slash and buttons")
    func liveRegisteredFactsHaveOneOriginAndDisabledRunnerCannotOpen() async throws {
        let (bridge, _, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = AppCommandCatalog.commandPaletteID
        let binding = ShortcutBinding(key: "j", modifiers: ShortcutModifiers.commandShift)
        #expect(bridge.shortcutStore.setBinding(binding, for: .commandPalette) == nil)
        let palette = try paletteRow(bridge, defaults: defaults)
        let menu = try #require(AppCommandMenuBuilder.command(id: id,
            registry: bridge.commandRegistry, display: bridge.paletteDisplay))
        #expect(palette.shortcut == binding.displayString)
        #expect(menu.shortcut == binding.displayString)
        #expect(palette.title == menu.title && palette.id == menu.id)
        let counter = Counter()
        bridge.commandRegistry.register(CommandDefinition(id: id, title: "合成禁用面板",
            category: .session, availability: { .disabled(reason: "合成当前阻断") }) { _ in
                await MainActor.run { counter.effects += 1 }
                return .success("")
            })
        let changedPalette = try paletteRow(bridge, defaults: defaults)
        let changedMenu = try #require(AppCommandMenuBuilder.command(id: id,
            registry: bridge.commandRegistry, display: bridge.paletteDisplay))
        let slash = try #require(ComposerSlashCommandMenu.entries(
            matching: "/" + id, registry: bridge.commandRegistry).first { $0.id == id })
        #expect(changedPalette.title == "合成禁用面板")
        #expect(changedMenu.title == changedPalette.title)
        #expect(!changedPalette.isEnabled && !changedMenu.isEnabled)
        #expect(changedMenu.disabledReason == "合成当前阻断")
        #expect(slash.state == .blocked(reason: "合成当前阻断"))
        bridge.runCommand(id: id)
        for _ in 0..<100 {
            if bridge.chat.messages.last?.content.contains("合成当前阻断") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(counter.effects == 0)
        #expect(!bridge.isCommandPalettePresented)
        #expect(bridge.chat.messages.last?.content.contains("合成当前阻断") == true)
    }
}
