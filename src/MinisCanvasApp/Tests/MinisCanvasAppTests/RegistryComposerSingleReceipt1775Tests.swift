import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Registry1775ProviderSpy: LLMProvider, @unchecked Sendable {
    let name = "registry1775-synthetic"
    var model = LLMModel(id: "registry1775", displayName: "Synthetic", provider: "test")
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { calls += 1 }
        return LLMResponse(text: "unexpected Provider call", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { calls += 1 }
        return LLMResponse(text: "unexpected Provider tool call", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { calls += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

private struct Registry1775PersistedState: Decodable {
    let receipt: ComposerCommandReceipt?
}

@Suite("D-COMMAND-08 registered Composer button and slash share one receipt boundary")
@MainActor
struct RegistryComposerSingleReceipt1775Tests {
    @Test func registryButtonAndTypedSlashUseProductionSubmitWithoutTranscriptOrProvider() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("registry1775-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "registry1775-\(UUID().uuidString)"))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let owner = UUID().uuidString
        _ = try sessions.createSession(id: owner, title: "Synthetic command owner")
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("Canvas is disabled in this fixture") },
            canvasRuntimeState: .disabled, canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.chat.attachPersistence(sessions,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(bridge: bridge, center: center))
        let provider = Registry1775ProviderSpy()
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.compactionProviderOverride = provider
        bridge.chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: bridge.chat.composerWorkspaceID, revision: "registry1775-policy",
            grantEpoch: "registry1775-epoch", leaseID: "registry1775-lease",
            expiresAt: Date().addingTimeInterval(600), revoked: false
        ))
        var policyCalls = 0
        bridge.chat.onComposerCommandPolicy = { request, snapshot in
            policyCalls += 1
            return center.evaluate(request: request, snapshot: snapshot, facts: bridge.chat.composerPolicyFacts)
        }
        let transcriptBefore = bridge.chat.messages
        let persistedBefore = try #require(sessions.loadSession(id: owner)).messages
        bridge.chat.draftText = "untouched draft"

        // This is the actual palette/menu BridgeStore entry, not a direct parser fixture.
        bridge.runCommand(id: "help", args: ["command_id": "status"])
        let buttonReceipt = try #require(bridge.chat.lastComposerCommandReceipt)
        #expect(buttonReceipt.commandID == "help")
        #expect(buttonReceipt.args == ["command_id": "status"])
        #expect(buttonReceipt.disposition == .execute)
        #expect(policyCalls == 1)
        #expect(bridge.chat.draftText == "untouched draft")
        #expect(bridge.chat.messages == transcriptBefore)
        #expect(provider.callCount == 0)
        let stateURL = root.appendingPathComponent("sessions/chat-composer-command-state.json")
        #expect(try JSONDecoder().decode(Registry1775PersistedState.self,
            from: Data(contentsOf: stateURL)).receipt == buttonReceipt)

        // A typed slash uses the same exact request/receipt owner, replacing
        // the single latest receipt only once; empty resend is inert.
        bridge.chat.draftText = "/status"
        bridge.chat.submitComposer()
        let slashReceipt = try #require(bridge.chat.lastComposerCommandReceipt)
        #expect(slashReceipt.commandID == "status" && slashReceipt.disposition == .execute)
        #expect(slashReceipt.requestID != buttonReceipt.requestID)
        #expect(policyCalls == 2)
        bridge.chat.submitComposer()
        await Task.yield()
        #expect(policyCalls == 2)
        #expect(bridge.chat.lastComposerCommandReceipt == slashReceipt)
        #expect(bridge.chat.messages == transcriptBefore)
        #expect(try #require(sessions.loadSession(id: owner)).messages == persistedBefore)
        #expect(provider.callCount == 0)
        #expect(try JSONDecoder().decode(Registry1775PersistedState.self,
            from: Data(contentsOf: stateURL)).receipt == slashReceipt)
    }
}
