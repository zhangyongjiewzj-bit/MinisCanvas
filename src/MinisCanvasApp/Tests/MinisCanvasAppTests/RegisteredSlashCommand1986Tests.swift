import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("COMMAND02 registered slash and menu share production command", .serialized)
@MainActor
struct RegisteredSlashCommand1986Tests {
    private func fixture() throws -> (BridgeStore, LogManager, URL, UserDefaults, String) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("command02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let suite = "command02-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: log,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("Canvas is disabled in this fixture") },
            canvasRuntimeState: .disabled, canvasFeatureLane: .phase3NonCanvas
        )
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(bridge: bridge, center: center))
        return (bridge, log, root, defaults, suite)
    }

    @Test func logLevelCompletionRetainsTypedArgumentAndUsesCanonicalRegistry() throws {
        let (bridge, _, _, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = bridge.commandRegistry
        let allRows = ComposerSlashCommandMenu.entries(matching: "/", registry: registry)
        let rowIDs = allRows.map(\.id)
        let declared = Set(CommandRegistry.composerCommandMetadata.map(\.id))
            .union(registry.allCommands().map(\.id))
        #expect(Set(rowIDs) == declared && rowIDs.count == declared.count)
        let row = try #require(GlobalComposer.visibleSlashEntries(
            for: "/log.level", registry: registry, sessionState: .neutral,
            canvasAvailable: false
        ).first { $0.id == "log.level" })
        #expect(row.routedCommand?.id == registry.command(id: "log.level")?.id)
        #expect(row.descriptor.risk == nil)
        #expect(!row.shouldSendOnAccept)
        let incomplete = GlobalComposer.acceptedSlashDraft(
            current: "/log.level", entry: row, registry: registry
        )
        #expect(incomplete.text == "/log.level" && !incomplete.shouldSend)
        let complete = GlobalComposer.acceptedSlashDraft(
            current: "/log.level debug", entry: row, registry: registry
        )
        #expect(complete.text == "/log.level debug" && complete.shouldSend)
        #expect(GlobalComposer.visibleSlashEntries(
            for: "/log.level debug", registry: registry, sessionState: .neutral,
            canvasAvailable: false
        ).contains { $0.id == "log.level" })
    }

    @Test func typedLogLevelRunsMenuExecutorBeforeTranscriptAndUnknownProseStaysChat() async throws {
        let (bridge, log, _, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        log.minimumLevel = .info
        let before = bridge.chat.messages
        bridge.chat.draftText = "/log.level debug"
        bridge.chat.submitComposer()
        for _ in 0..<100 {
            if log.minimumLevel == .debug { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.minimumLevel == .debug)
        #expect(bridge.chat.draftText.isEmpty)
        #expect(!bridge.chat.messages.contains { $0.role == .user && $0.content.contains("/log.level") })
        #expect(bridge.chat.messages.count >= before.count)

        var ordinarySubmissions = 0
        bridge.chat.onSendCommand = { _, _ in ordinarySubmissions += 1; return true }
        let prose = "/notacommand is quoted prose"
        bridge.chat.draftText = prose
        bridge.chat.submitComposer()
        #expect(ordinarySubmissions == 1)
        #expect(bridge.chat.messages.contains { $0.role == .user && $0.content == prose })
        #expect(log.minimumLevel == .debug)
    }

    @Test func productionReadinessKeepsRegisteredPresetSlashActionable() throws {
        let (bridge, _, _, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = bridge.chat.registeredComposerCommandRegistry
        #expect(registry === bridge.commandRegistry)

        let reasons = GlobalComposer.commandReadinessReasons(
            registry: registry, bridge: bridge
        )
        #expect(reasons["log.level"] == nil)
        #expect(reasons["settings.open"] == nil)

        let state = ComposerSlashSessionState(
            unavailableReasonsByCommandID: reasons
        )
        let logRow = try #require(GlobalComposer.visibleSlashEntries(
            for: "/log.level debug", registry: registry,
            sessionState: state, canvasAvailable: false
        ).first { $0.id == "log.level" })
        #expect(logRow.state == .available)
        #expect(GlobalComposer.acceptedSlashDraft(
            current: "/log.level debug", entry: logRow, registry: registry
        ).shouldSend)

        let confirmationRow = try #require(GlobalComposer.visibleSlashEntries(
            for: "/settings.reset", registry: registry,
            sessionState: state, canvasAvailable: false
        ).first { $0.id == "settings.reset" })
        #expect(confirmationRow.state == .blocked(reason: "此命令当前没有确认执行入口"))
        #expect(!GlobalComposer.acceptedSlashDraft(
            current: "/settings.reset", entry: confirmationRow, registry: registry
        ).shouldSend)
    }

    @Test func composerPolicyCommandsAndDisabledCanvasNeverUsePresetExecutor() throws {
        let (bridge, log, _, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        log.minimumLevel = .warn
        var ordinarySubmissions = 0
        bridge.chat.onSendCommand = { _, _ in ordinarySubmissions += 1; return true }
        let before = bridge.chat.messages
        bridge.chat.draftText = "/boundary.set path=/synthetic"
        bridge.chat.submitComposer()
        #expect(bridge.chat.composerCommandValidationFailure?.commandID == "boundary.set"
            || bridge.chat.lastComposerCommandReceipt?.commandID == "boundary.set")
        #expect(ordinarySubmissions == 0 && bridge.chat.messages == before)
        #expect(log.minimumLevel == .warn)
        let canvas = try #require(GlobalComposer.visibleSlashEntries(
            for: "/canvas.run", registry: bridge.commandRegistry,
            sessionState: .neutral, canvasAvailable: false
        ).first { $0.id == "canvas.run" })
        #expect(!canvas.shouldSendOnAccept)
    }

}
