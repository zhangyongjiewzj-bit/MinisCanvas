import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

struct Success419Input: Sendable {
    let commandID: String
    let localizedInput: String
}

/// Both normal Provider entry points and compaction are observed. This
/// synthetic object has no endpoint, credentials or network implementation.
private final class Success419ProviderProbe: LLMProvider, @unchecked Sendable {
    let name = "success419-local-only"
    var model = LLMModel(id: "success419", displayName: "Synthetic local probe", provider: "test")
    private let lock = NSLock()
    private var counts = [0, 0, 0]
    var callCounts: [Int] { lock.withLock { counts } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[0] += 1 }
        return LLMResponse(text: "unexpected provider call", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[1] += 1 }
        return LLMResponse(text: "unexpected tool-aware provider call", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { counts[2] += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class Success419DispatchProbe {
    var requests: [PendingCommandRequest] = []
    var snapshots: [ComposerSubmissionSnapshot] = []
}

/// Reads the existing single receipt field from the actual owned envelope.
/// Restore below also goes through ChatStore, rather than only this decoder.
private struct Success419PersistedReceipt: Decodable {
    let receipt: ComposerCommandReceipt?
}

@Suite("D-COMMAND-08 localized successful command receipt consumer")
@MainActor
struct ComposerSuccessReceipt419Tests {
    private struct Harness {
        let chat: ChatStore
        let center: ComposerCommandAdjudicationCenter
        let registry: CommandRegistry
        let dispatch: Success419DispatchProbe
        let provider: Success419ProviderProbe
    }

    private func harness(root: URL, suffix: String) throws -> Harness {
        let requiredValue561_1 = UserDefaults(suiteName: "success419-\(UUID().uuidString)")
        let defaults561: UserDefaults = try #require(requiredValue561_1)
        let chat = ChatStore(
            preferencesDefaults: defaults561,
            logManager: LogManager(directory: root.appendingPathComponent("logs-\(suffix)"))
        )
        #expect(chat.attachPersistence(SessionStore(directory: root),
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges-\(suffix)"))))
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(registry: registry, chat: chat, center: center))
        let dispatch = Success419DispatchProbe()
        let provider = Success419ProviderProbe()
        chat.streamingProviderOverride = provider
        chat.compactionProviderOverride = provider
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "success419-policy",
            grantEpoch: "success419-epoch", leaseID: "success419-lease",
            expiresAt: Date().addingTimeInterval(600), revoked: false
        ))
        chat.onComposerCommandPolicy = { [weak chat, weak center] request, snapshot in
            dispatch.requests.append(request)
            dispatch.snapshots.append(snapshot)
            guard let chat, let center else { return .reject }
            return center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        return Harness(chat: chat, center: center, registry: registry, dispatch: dispatch, provider: provider)
    }

    @Test("Chinese aliases submit once, survive reload and do not turn an empty resend into a user/model turn",
          arguments: [
            Success419Input(commandID: "help", localizedInput: "/帮助"),
            Success419Input(commandID: "commands", localizedInput: "/命令列表"),
            Success419Input(commandID: "status", localizedInput: "/当前状态"),
            Success419Input(commandID: "tasks", localizedInput: "/任务列表"),
            Success419Input(commandID: "boundary", localizedInput: "/安全边界"),
            Success419Input(commandID: "provider", localizedInput: "/当前提供商"),
          ])
    func localizedSuccessHasOneDurableReceiptWithoutUserOrProvider(input: Success419Input) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("success419-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let store = SessionStore(directory: root)
        let owner = UUID().uuidString
        _ = try store.createSession(id: owner, title: "Synthetic command owner")
        let fixture = try harness(root: root, suffix: "first")
        #expect(fixture.chat.activeSessionID?.uuidString == owner)
        #expect(fixture.chat.lastComposerCommandReceipt == nil)
        let before = fixture.chat.messages
        let persistedBefore = try #require(store.loadSession(id: owner)).messages
        #expect(fixture.chat.registeredComposerCommandRegistry === fixture.registry)
        #expect(fixture.center.commandRegistry === fixture.registry)
        #expect(fixture.registry.command(id: input.commandID)?.requiresConfirmation == false)

        fixture.chat.draftText = input.localizedInput
        fixture.chat.submitComposer() // Actual public consumer, not CommandParser alone.
        await Task.yield()
        let receipt = try #require(fixture.chat.lastComposerCommandReceipt)
        let snapshot = try #require(fixture.chat.lastComposerSubmissionSnapshot)
        let request = try #require(fixture.dispatch.requests.first)
        let projection = try #require(fixture.center.projection)
        #expect(fixture.dispatch.requests.count == 1 && fixture.dispatch.snapshots.count == 1)
        #expect(request.commandID == input.commandID && request.args.isEmpty)
        #expect(receipt.commandID == input.commandID && receipt.args.isEmpty)
        #expect(receipt.disposition == .execute)
        #expect(receipt.requestID == request.id && projection.id == request.id)
        #expect(projection.commandID == input.commandID && !projection.text.isEmpty)
        #expect(receipt.sessionID == owner && receipt.sessionID == snapshot.sessionID)
        #expect(receipt.turnID == snapshot.turnID && receipt.taskID == snapshot.taskID)
        #expect(receipt.attemptID == snapshot.attemptID)
        #expect(fixture.chat.pendingComposerCommand == nil && fixture.center.pendingAdjudication == nil)
        #expect(fixture.chat.composerCommandValidationFailure == nil)
        #expect(fixture.chat.messages == before && fixture.chat.draftText.isEmpty)
        #expect(!fixture.chat.isStreaming && !fixture.chat.isActiveSessionStreaming)
        #expect(fixture.provider.callCounts == [0, 0, 0])
        let persistedAfterSubmission = try #require(store.loadSession(id: owner))
        #expect(persistedAfterSubmission.messages == persistedBefore)
        let stateURL = root.appendingPathComponent("chat-composer-command-state.json")
        let persistedReceiptBytes = try Data(contentsOf: stateURL)
        #expect(try JSONDecoder().decode(Success419PersistedReceipt.self,
            from: persistedReceiptBytes).receipt == receipt)

        fixture.chat.submitComposer() // Empty input must not create a second dispatch/receipt.
        await Task.yield()
        #expect(fixture.dispatch.requests == [request])
        #expect(fixture.dispatch.snapshots.count == 1)
        #expect(fixture.chat.lastComposerCommandReceipt == receipt)
        #expect(fixture.center.projection == projection)
        #expect(try Data(contentsOf: stateURL) == persistedReceiptBytes)
        #expect(fixture.chat.messages == before && fixture.provider.callCounts == [0, 0, 0])

        let restored = try harness(root: root, suffix: "restored")
        #expect(restored.chat.activeSessionID?.uuidString == owner)
        #expect(restored.chat.lastComposerCommandReceipt == receipt)
        #expect(restored.chat.pendingComposerCommand == nil)
        #expect(restored.dispatch.requests.isEmpty && restored.provider.callCounts == [0, 0, 0])
        #expect(restored.center.projection == nil) // Installing/restoring does not execute or replay.
        #expect(restored.chat.messages == before)
        restored.chat.newSession()
        let other = try #require(restored.chat.activeSessionID)
        #expect(other.uuidString != owner)
        restored.chat.submitComposer()
        #expect(restored.chat.lastComposerCommandReceipt == receipt)
        #expect(restored.chat.lastComposerCommandReceipt?.sessionID != other.uuidString)
        #expect(restored.dispatch.requests.isEmpty && restored.provider.callCounts == [0, 0, 0])
        let persistedAfterSessionSwitch = try #require(store.loadSession(id: owner))
        #expect(persistedAfterSessionSwitch.messages == persistedBefore)
        // Keep the owned fixture; no real store, network or native window is used.
        // This finite increment does not close all successful-command/compact contracts.
    }
}
