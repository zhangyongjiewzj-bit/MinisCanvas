import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class M05LocalCommandProviderProbe: LLMProvider, @unchecked Sendable {
    let name = "m05-local-command-probe"
    var model = LLMModel(id: "m05-local-command-probe", displayName: "Local Command Probe", provider: "test")
    private(set) var callCount = 0

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        callCount += 1
        return LLMResponse(text: "unexpected provider call", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        callCount += 1
        return AsyncThrowingStream { continuation in continuation.finish() }
    }
}

@Suite("D-COMMAND-08 local command receipt boundary")
@MainActor
struct P3AcceptanceM05OneReceiptNoProviderTests {
    @Test(arguments: ["/help", "/commands", "/status", "/tasks", "/boundary", "/provider"])
    func successfulLocalCommandHasOneReceiptWithoutProviderOrUserTurn(input: String) async throws {
        let defaults = UserDefaults(suiteName: "m05-one-receipt-\(UUID().uuidString)")!
        let chat = ChatStore(preferencesDefaults: defaults)
        let center = ComposerCommandAdjudicationCenter()
        let provider = M05LocalCommandProviderProbe()
        chat.streamingProviderOverride = provider
        chat.compactionProviderOverride = provider
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID,
            revision: "m05-one-receipt-policy", grantEpoch: "m05-one-receipt-epoch",
            leaseID: "m05-one-receipt-lease", expiresAt: Date().addingTimeInterval(600),
            revoked: false
        ))
        var policyEvaluations = 0
        chat.onComposerCommandPolicy = { request, snapshot in
            policyEvaluations += 1
            return center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        let messagesBefore = chat.messages

        chat.draftText = input
        chat.submitComposer()

        let receipt = try #require(chat.lastComposerCommandReceipt)
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(policyEvaluations == 1)
        #expect(receipt.commandID == String(input.dropFirst()))
        #expect(receipt.disposition == .execute)
        #expect(receipt.sessionID == snapshot.sessionID)
        #expect(receipt.turnID == snapshot.turnID)
        #expect(receipt.taskID == snapshot.taskID)
        #expect(receipt.attemptID == snapshot.attemptID)
        #expect(center.projection?.id == receipt.requestID)
        #expect(chat.pendingComposerCommand == nil)
        #expect(chat.messages == messagesBefore)
        #expect(chat.draftText.isEmpty)
        #expect(!chat.isActiveSessionStreaming)

        // The now-empty composer cannot create a second command receipt or a
        // user turn. Both Provider paths are instrumented, including compaction.
        chat.submitComposer()
        await Task.yield()
        #expect(policyEvaluations == 1)
        #expect(chat.lastComposerCommandReceipt?.requestID == receipt.requestID)
        #expect(chat.messages == messagesBefore)
        #expect(provider.callCount == 0)
    }
}
