import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// No transport, endpoint or credentials. Any accidental Provider entry is counted.
private final class Alias470ProviderProbe: LLMProvider, @unchecked Sendable {
    let name = "alias470-local-only"
    var model = LLMModel(id: "alias470", displayName: "Synthetic local probe", provider: "test")
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
        return LLMResponse(text: "unexpected tool provider call", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { counts[2] += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class Alias470PolicyProbe {
    var requests: [PendingCommandRequest] = []
}

@Suite("D-COMMAND-07 English alias actual dispatch")
@MainActor
struct ComposerMultiwordAliasDispatch470Tests {
    private struct Harness {
        let chat: ChatStore
        let center: ComposerCommandAdjudicationCenter
        let registry: CommandRegistry
        let policy: Alias470PolicyProbe
        let provider: Alias470ProviderProbe
        let store: SessionStore
    }

    private func harness() throws -> Harness {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("alias470-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let store = SessionStore(directory: root)
        _ = try store.createSession(id: UUID().uuidString, title: "Synthetic alias owner")
        let requiredValue561_1 = UserDefaults(suiteName: "alias470-\(UUID().uuidString)")
        let defaults561: UserDefaults = try #require(requiredValue561_1)
        let chat = ChatStore(preferencesDefaults: defaults561,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        #expect(chat.attachPersistence(store,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(registry: registry, chat: chat, center: center))
        let policy = Alias470PolicyProbe()
        let provider = Alias470ProviderProbe()
        chat.streamingProviderOverride = provider
        chat.compactionProviderOverride = provider
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "alias470-policy",
            grantEpoch: "alias470-epoch", leaseID: "alias470-lease",
            expiresAt: Date().addingTimeInterval(600), revoked: false
        ))
        chat.onComposerCommandPolicy = { [weak chat, weak center] request, snapshot in
            policy.requests.append(request)
            guard let chat, let center else { return .reject }
            return center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        return Harness(chat: chat, center: center, registry: registry,
                       policy: policy, provider: provider, store: store)
    }

    @Test(arguments: ["/boundary set", "/boundary.set", "/设置安全边界"])
    func missingProfileIsTheSameLocalErrorBeforePolicy(input: String) async throws {
        let fixture = try harness()
        let owner = try #require(fixture.chat.activeSessionID)
        let before = fixture.chat.messages
        let persistedBefore = try #require(fixture.store.loadSession(id: owner.uuidString))
        let palette = try #require(CommandPaletteView.resolveSubmission(
            query: input, registry: fixture.registry, fallbackID: nil))
        #expect(palette.id == "boundary.set" && palette.args.isEmpty)
        fixture.chat.draftText = input
        fixture.chat.submitComposer() // Real public command-dispatch consumer.
        await Task.yield()
        let failure = try #require(fixture.chat.composerCommandValidationFailure)
        #expect(failure.commandID == "boundary.set" && failure.sessionID == owner)
        #expect(failure.message == CommandExecutionError.missingArgument(
            commandID: "boundary.set", argument: "profile").errorDescription)
        #expect(fixture.chat.draftText == input && fixture.chat.messages == before)
        #expect(fixture.chat.pendingComposerCommand == nil && fixture.chat.lastComposerCommandReceipt == nil)
        #expect(fixture.policy.requests.isEmpty && fixture.center.pendingAdjudication == nil)
        #expect(fixture.center.projection == nil) // Must not display the shorter readonly boundary card.
        #expect(fixture.provider.callCounts == [0, 0, 0] && !fixture.chat.isStreaming)
        let persistedAfter = try #require(fixture.store.loadSession(id: owner.uuidString))
        #expect(persistedAfter.messages == persistedBefore.messages)
        // Owned fixtures are retained. This does not change any admission rule.
    }

    @Test func completeAliasRetainsTheExistingUnsupportedRouteRejection() async throws {
        let fixture = try harness()
        let before = fixture.chat.messages
        fixture.chat.draftText = "/boundary set profile=strict"
        fixture.chat.submitComposer()
        await Task.yield()
        let request = try #require(fixture.policy.requests.first)
        let receipt = try #require(fixture.chat.lastComposerCommandReceipt)
        #expect(fixture.policy.requests.count == 1)
        #expect(request.commandID == "boundary.set" && request.args == ["profile": "strict"])
        #expect(request.requiresPolicyApproval) // Alias matching never removes approval requirements.
        #expect(receipt.requestID == request.id && receipt.commandID == "boundary.set")
        #expect(receipt.args == request.args && receipt.disposition == .reject)
        #expect(!fixture.center.supportsApproval(commandID: "boundary.set"))
        #expect(fixture.chat.pendingComposerCommand == nil && fixture.center.pendingAdjudication == nil)
        #expect(fixture.center.projection?.commandID == "boundary.set")
        #expect(fixture.chat.messages == before && fixture.provider.callCounts == [0, 0, 0])
        #expect(fixture.chat.composerCommandValidationFailure == nil)
    }
}
