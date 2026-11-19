import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Metadata477Provider: LLMProvider, @unchecked Sendable {
    let name = "metadata477-no-transport"
    var model = LLMModel(id: "metadata477", displayName: "Local synthetic probe", provider: "test")
    private let lock = NSLock()
    private var counts = [0, 0, 0]
    var calls: [Int] { lock.withLock { counts } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[0] += 1 }
        return LLMResponse(text: "unexpected", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[1] += 1 }
        return LLMResponse(text: "unexpected", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { counts[2] += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class Metadata477Counts {
    var canvasFactory = 0
    var coordinatorFactory = 0
    var policyRequests: [PendingCommandRequest] = []
}

@Suite("D-COMMAND-01 disabled Canvas metadata in the real Chat catalog")
@MainActor
struct CanvasCommandMetadataConsumer477Tests {
    private struct Fixture {
        let bridge: BridgeStore
        let registry: CommandRegistry
        let center: ComposerCommandAdjudicationCenter
        let counts: Metadata477Counts
        let provider: Metadata477Provider
    }

    private func fixture() throws -> Fixture {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("metadata477-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "metadata477-\(UUID().uuidString)"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let workflow = WorkflowStore(storeDirectory: root.appendingPathComponent("workflows"))
        let counts = Metadata477Counts()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: log, workflowStore: workflow,
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in
                counts.canvasFactory += 1
                preconditionFailure("Disabled metadata must never construct CanvasStore")
            },
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
            memoryStore: memory,
            canvasMutationCoordinatorFactory: { _ in
                counts.coordinatorFactory += 1
                preconditionFailure("Disabled metadata must never construct Canvas coordinator")
            },
            canvasFeatureLane: .phase3NonCanvas
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
        _ = try sessions.createSession(id: UUID().uuidString, title: "Synthetic metadata owner")
        #expect(bridge.chat.attachPersistence(sessions,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let backendConfigs = Dictionary(uniqueKeysWithValues: LocalBackendKind.allCases.map {
            ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
        })
        let dependencies = CommandDependencies(
            env: EnvVarStore(directory: root.appendingPathComponent("environment"),
                             keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            log: log, backends: LocalBackends(configs: backendConfigs), sessions: sessions,
            memory: memory, workflows: workflow
        )
        // Actual production assembly; no manually manufactured Canvas definitions.
        let registry = AppCommandCatalog.assembled(bridge: bridge, dependencies: dependencies).registry
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(registry: registry, chat: bridge.chat, center: center))
        let provider = Metadata477Provider()
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.compactionProviderOverride = provider
        bridge.chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: bridge.chat.composerWorkspaceID, revision: "metadata477-policy",
            grantEpoch: "metadata477-epoch", leaseID: "metadata477-lease",
            expiresAt: Date().addingTimeInterval(600), revoked: false
        ))
        bridge.chat.onComposerCommandPolicy = { [weak bridge, weak center] request, snapshot in
            counts.policyRequests.append(request)
            guard let bridge, let center else { return .reject }
            return center.evaluate(request: request, snapshot: snapshot, facts: bridge.chat.composerPolicyFacts)
        }
        return Fixture(bridge: bridge, registry: registry, center: center, counts: counts, provider: provider)
    }

    @Test func originalVocabularyHasRealMetadataRowsAndSpecificReadonlyHelp() throws {
        let fixture = try fixture()
        let declared = CommandRegistry.composerCommandMetadata
        let expectedIDs: Set<String> = ["help", "commands", "boundary", "boundary.set", "add-dir", "status", "copy", "tasks",
                "stop", "compact", "retry", "canvas.run", "canvas.cancel", "canvas.minimap", "provider",
                "provider.use", "model", "workflow", "approve", "reject", "memory", "memory.propose",
                "skills", "permissions", "mcp", "context", "clear", "rewind", "undo", "diff", "doctor", "usage", "export",
                "rename", "resume", "plan", "shortcuts"]
        #expect(Set(declared.map(\.id)) == expectedIDs)
        #expect(declared.count == expectedIDs.count)
        #expect(declared.filter { $0.id == "model" }.count == 1) // Extra existing model row, not a replacement.
        let rows = GlobalComposer.visibleSlashEntries(for: "/", registry: fixture.registry,
            sessionState: .neutral, canvasAvailable: false)
        let visibleIDs = Set(rows.map(\.id))
        // The complete approved vocabulary must remain visible, while the shared
        // registry may expose other legitimate commands through this menu.
        #expect(Set(declared.map(\.id)).isSubset(of: visibleIDs))
        #expect(rows.count == visibleIDs.count)
        for row in rows {
            #expect(row.routedCommand?.id == row.id)
            #expect(fixture.registry.command(id: row.id) != nil)
        }
        for metadata in declared {
            let command = try #require(fixture.registry.command(id: metadata.id))
            let row = try #require(rows.first { $0.id == metadata.id })
            #expect(command.title == metadata.zhTitle && command.argumentSpecs == metadata.argumentSpecs)
            #expect(command.requiresConfirmation == metadata.requiresPolicyApproval)
            #expect(row.descriptor.enTitle == metadata.enTitle)
            #expect(row.descriptor.zhSummary == metadata.zhSummary && row.descriptor.enSummary == metadata.enSummary)
            #expect(row.descriptor.risk == ComposerSlashCommandRisk(metadata.risk))
            #expect(row.descriptor.argumentSummary == metadata.parameterSummary)
        }
        let canvasCommands = fixture.registry.allCommands().filter { $0.category == .canvas }
        #expect(Set(canvasCommands.map(\.id)) == ["canvas.run", "canvas.cancel", "canvas.minimap"])
        // An enabled registration is not metadata-only and remains hidden by
        // the old Phase 3 gate. Phase 4's original display remains unchanged.
        let enabledRegistry = CommandRegistry()
        enabledRegistry.registerComposerCommands()
        let enabledInPhase3 = GlobalComposer.visibleSlashEntries(for: "/canvas", registry: enabledRegistry,
            sessionState: .neutral, canvasAvailable: false)
        let enabledInPhase4 = GlobalComposer.visibleSlashEntries(for: "/canvas", registry: enabledRegistry,
            sessionState: .neutral, canvasAvailable: true)
        #expect(enabledInPhase3.isEmpty)
        #expect(Set(enabledInPhase4.map(\.id)) == Set(canvasCommands.map(\.id)))
        let before = fixture.bridge.chat.messages
        for command in canvasCommands {
            guard case .disabled(let reason) = command.currentAvailability else {
                Issue.record("Canvas metadata must not be enabled in Phase 3")
                continue
            }
            let row = try #require(rows.first { $0.id == command.id })
            #expect(reason == ComposerCommandAdjudicationCenter.missingExecutorReason(for: command.id))
            #expect(row.state == .blocked(reason: reason) && !row.shouldSendOnAccept)
            fixture.bridge.chat.draftText = "/help \(command.id)"
            fixture.bridge.chat.submitComposer()
            let metadata = try #require(CommandRegistry.composerMetadata(for: command.id))
            let text = try #require(fixture.center.projection?.text)
            #expect(fixture.center.projection?.commandID == "help")
            #expect(text.contains("/\(command.id)") && text.contains(metadata.zhTitle) && text.contains(metadata.enTitle))
            #expect(text.contains(metadata.zhSummary) && text.contains(metadata.enSummary))
            #expect(text.contains(metadata.parameterSummary) && text.contains(metadata.risk.displayLabel))
            #expect(text.contains("当前阻断：\(reason)"))
            #expect(fixture.bridge.chat.lastComposerCommandReceipt?.disposition == .execute)
        }
        #expect(fixture.counts.policyRequests.map(\.commandID) == ["help", "help", "help"])
        #expect(fixture.bridge.chat.messages == before && fixture.provider.calls == [0, 0, 0])
        assertRuntimeStillAbsent(fixture)
    }

    @Test(arguments: ["canvas.run", "canvas.cancel", "canvas.minimap"])
    func canvasCannotBecomePendingOrExecuteEvenWithConfirmation(id: String) async throws {
        let fixture = try fixture()
        let command = try #require(fixture.registry.command(id: id))
        guard case .disabled(let reason) = command.currentAvailability else {
            Issue.record("Expected disabled metadata")
            return
        }
        let parsed = CommandParser().parse("/\(id)", registry: fixture.registry)
        switch fixture.registry.validatedComposerPendingRequest(for: parsed) {
        case .failure(let error): #expect(error == .disabled(commandID: id, reason: reason))
        case .success: Issue.record("Disabled Canvas must not form a pending request")
        }
        do {
            _ = try await fixture.registry.execute(id: id, confirmation: true)
            Issue.record("Confirmation must not activate a disabled Canvas definition")
        } catch let error as CommandExecutionError {
            #expect(error == .disabled(commandID: id, reason: reason))
        }
        let chat = fixture.bridge.chat
        let before = chat.messages
        chat.draftText = "/\(id)"
        chat.submitComposer() // Actual App consumer, not a validator-only substitute.
        await Task.yield()
        let failure = try #require(chat.composerCommandValidationFailure)
        #expect(failure.commandID == id)
        #expect(failure.message == CommandExecutionError.disabled(commandID: id, reason: reason).errorDescription)
        #expect(chat.draftText == "/\(id)" && chat.messages == before)
        #expect(chat.pendingComposerCommand == nil && chat.lastComposerCommandReceipt == nil)
        #expect(fixture.center.pendingAdjudication == nil && fixture.center.projection == nil)
        #expect(fixture.counts.policyRequests.isEmpty && fixture.provider.calls == [0, 0, 0])
        #expect(!chat.isStreaming && fixture.bridge.composerCanvasDispatchCount == 0)
        assertRuntimeStillAbsent(fixture)
    }

    private func assertRuntimeStillAbsent(_ fixture: Fixture) {
        #expect(fixture.counts.canvasFactory == 0 && fixture.counts.coordinatorFactory == 0)
        #expect(fixture.bridge.canvasIfAvailable == nil && fixture.bridge.canvasBoundaryIfAvailable == nil)
        #expect(fixture.bridge.canvasMutationReceipts.isEmpty)
        #expect(fixture.bridge.productionChatComposition.canvasCapabilities.isEmpty)
        let ids = Set(fixture.registry.allCommands().map(\.id))
        #expect(!ids.contains("ui.pipeline") && !ids.contains("ui.layout.canvas") && !ids.contains("ui.canvas.run"))
        #expect(!ids.contains(where: { $0.hasPrefix("ui.add-node.") }))
    }
}
