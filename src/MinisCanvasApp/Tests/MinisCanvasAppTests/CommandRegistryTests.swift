import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class SlashCountingProvider: LLMProvider, @unchecked Sendable {
    let name = "slash-test-provider"
    var model = LLMModel(id: "slash-test", displayName: "Slash Test", provider: "test")
    private(set) var callCount = 0

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        callCount += 1
        return LLMResponse(text: "unused", stopReason: "end_turn", usage: nil)
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
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

@Suite("Composer slash production boundary")
@MainActor
struct CommandRegistryTests {
    @Test func compactIsCanonicalAndRequiresPolicy() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let parsed = MinisCore.CommandParser().parse("/compact", registry: registry)
        let request = registry.makePendingRequest(for: parsed)

        #expect(parsed.command?.id == "compact")
        #expect(parsed.disposition == .command)
        #expect(request?.commandID == "compact")
        #expect(request?.requiresPolicyApproval == true)
    }

    @Test func pendingSlashNeverAppendsTranscriptOrCallsProvider() {
        let provider = SlashCountingProvider()
        let chat = ChatStore()
        chat.compactionProviderOverride = provider
        chat.draftText = "/compact"
        chat.onComposerCommandPolicy = { _, _ in .pending }
        let before = chat.messages

        chat.submitComposer()

        #expect(chat.messages == before)
        #expect(chat.pendingComposerCommand?.commandID == "compact")
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(provider.callCount == 0)
    }

    @Test func canonicalAliasIsConsumedBeforeProviderPath() {
        let provider = SlashCountingProvider()
        let chat = ChatStore()
        chat.streamingProviderOverride = provider
        chat.draftText = "/status"

        chat.submitComposer()

        #expect(chat.messages.allSatisfy { !$0.content.contains("/status") })
        #expect(chat.lastComposerCommandReceipt?.commandID == "status")
        #expect(provider.callCount == 0)
    }
}
