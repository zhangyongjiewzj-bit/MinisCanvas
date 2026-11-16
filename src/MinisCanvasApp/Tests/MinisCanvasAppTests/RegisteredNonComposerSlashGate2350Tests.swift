import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-02 registered slash respects the shared execution gate")
@MainActor
struct RegisteredNonComposerSlashGate2350Tests {
    @Test func realConfirmationPresetsAreBlockedInPaletteMenuAndSlash() throws {
        guard let paths = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            Issue.record("Formal test profile is required")
            return
        }
        let root = paths.rootDirectory.appendingPathComponent(
            "command2350-projections-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let defaults = try #require(UserDefaults(suiteName: "command2350-projections-\(UUID().uuidString)"))
        let dependencies = CommandDependencies(
            env: EnvVarStore(directory: root.appendingPathComponent("environment"),
                             keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            log: LogManager(directory: root.appendingPathComponent("logs")),
            backends: LocalBackends(configs: [:]),
            sessions: SessionStore(directory: root.appendingPathComponent("sessions")),
            memory: MemoryStore(directory: root.appendingPathComponent("memory")),
            workflows: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows"))
        )
        let registry = CommandRegistry(commands: PresetCommands.all(dependencies: dependencies))
        let palette = CommandPaletteModel(
            registry: registry, display: [:],
            favorites: FavoriteCommandsStore(defaults: defaults), debounceInterval: .zero
        )
        let menu = AppCommandMenuBuilder.sections(registry: registry, display: [:])
            .flatMap(\.commands)
        for id in ["settings.reset", "workflow.run"] {
            #expect(registry.command(id: id)?.requiresConfirmation == true)
            let paletteRow = try #require(palette.sections.flatMap(\.commands).first { $0.id == id })
            let menuRow = try #require(menu.first { $0.id == id })
            let slashRow = try #require(ComposerSlashCommandMenu.entries(
                matching: "/\(id)", registry: registry
            ).first { $0.id == id })
            #expect(!paletteRow.isEnabled && !menuRow.isEnabled)
            #expect(paletteRow.disabledReason == "此命令当前没有确认执行入口")
            #expect(menuRow.disabledReason == paletteRow.disabledReason)
            #expect(slashRow.state == .blocked(reason: "此命令当前没有确认执行入口"))
        }
    }

    @Test func disabledAndConfirmationOnlyRowsKeepTheDraftBeforeAppDispatch() async throws {
        guard let paths = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            Issue.record("Formal test profile is required")
            return
        }
        let root = paths.rootDirectory.appendingPathComponent(
            "command2350-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let defaults = try #require(UserDefaults(suiteName: "command2350-\(UUID().uuidString)"))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: UUID().uuidString, title: "Synthetic command owner")
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("Canvas is disabled") },
            canvasRuntimeState: .disabled, canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.chat.attachPersistence(
            sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        ))
        let registry = bridge.commandRegistry
        registry.register(CommandDefinition(
            id: "ui.test.disabled", title: "Synthetic disabled", category: .settings,
            availability: { .disabled(reason: "Synthetic gate") }
        ) { _ in .failure("disabled row must never execute") })
        registry.register(CommandDefinition(
            id: "ui.test.confirm", title: "Synthetic confirmation", category: .settings,
            requiresConfirmation: true
        ) { _ in .failure("confirmation row must never execute from slash") })
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(bridge: bridge, center: center))
        let before = bridge.chat.messages

        for (id, expected) in [
            ("ui.test.disabled", "Synthetic gate"),
            ("ui.test.confirm", "确认")
        ] {
            let draft = "/\(id)"
            bridge.chat.draftText = draft
            bridge.chat.submitComposer()
            await Task.yield()
            #expect(bridge.chat.draftText == draft)
            #expect(bridge.chat.composerCommandValidationFailure?.commandID == id)
            #expect(bridge.chat.composerCommandValidationFailure?.message.contains(expected) == true)
            #expect(bridge.chat.lastComposerCommandReceipt == nil)
            #expect(bridge.chat.messages == before)
        }
    }
}
