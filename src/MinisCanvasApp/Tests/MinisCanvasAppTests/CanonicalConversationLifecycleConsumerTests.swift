import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Canonical conversation lifecycle consumer")
@MainActor
struct CanonicalConversationLifecycleConsumerTests {
    @Test("production ToolFact preserves the exact receipt")
    func productionToolFactPreservesExactReceipt() async throws {
        let chat = ChatStore()
        chat.agentEngine = ToolFactProducerEngine(mode: .valid)
        chat.draftText = "run a tool"
        chat.sendDraft()
        await waitForIdle(chat)

        let event = try #require(chat.conversationEvents.first)
        #expect(event.toolCallID == "call-l4")
        #expect(event.receiptID == "receipt-l4")
        #expect(event.toolName == "web_search")
        #expect(event.status == .succeeded)
    }

    @Test("aggregate and missing receipt facts fail closed")
    func productionToolFactRejectsAggregateOrMissingReceipt() async throws {
        for mode in [ToolFactProducerEngine.Mode.aggregate, .missingReceipt] {
            let chat = ChatStore()
            chat.agentEngine = ToolFactProducerEngine(mode: mode)
            chat.draftText = "reject invalid tool fact"
            chat.sendDraft()
            await waitForIdle(chat)
            #expect(chat.conversationEvents.isEmpty)
        }
    }

    @Test("duplicate producer facts are idempotent end to end")
    func productionToolFactEndToEndIsIdempotent() async throws {
        let chat = ChatStore()
        chat.agentEngine = ToolFactProducerEngine(mode: .duplicate)
        chat.draftText = "duplicate tool fact"
        chat.sendDraft()
        await waitForIdle(chat)

        #expect(chat.conversationEvents.count == 1)
        let event = try #require(chat.conversationEvents.first)
        #expect(event.receiptID == "receipt-l4")
        #expect(event.status == .succeeded)
    }

    @Test("internally consistent facts from the wrong attempt fail closed")
    func productionToolFactRejectsWrongAttemptID() async throws {
        let chat = ChatStore()
        chat.agentEngine = ToolFactProducerEngine(mode: .wrongAttempt)
        chat.draftText = "wrong attempt"
        chat.sendDraft()
        await waitForIdle(chat)

        #expect(chat.conversationEvents.isEmpty)
    }

    private func waitForIdle(_ chat: ChatStore) async {
        for _ in 0..<200 where chat.isStreaming {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct ToolFactProducerEngine: ChatAgentEngine {
    enum Mode: Sendable, Equatable {
        case valid
        case aggregate
        case missingReceipt
        case duplicate
        case wrongAttempt
    }

    let mode: Mode
    var isAvailable: Bool { true }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeStream(executionIdentity: nil, composerSnapshot: nil)
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeStream(
            executionIdentity: executionIdentity,
            composerSnapshot: composerSnapshot
        )
    }

    func interrupt(turnID: Int) {}
    func interrupt() {}

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(
            messages: history.map { message in
                LLMMessage(
                    role: message.role == .user ? .user : .assistant,
                    content: message.content,
                    images: message.llmImages,
                    audios: message.llmAudios
                )
            },
            summary: nil,
            compactedCount: 0
        )
    }

    private func makeStream(
        executionIdentity: AgentExecutionIdentity?,
        composerSnapshot: ComposerSubmissionSnapshot?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let executionIdentity, let composerSnapshot else {
                continuation.yield(.done(stopReason: .endTurn))
                continuation.finish()
                return
            }

            let callID = mode == .aggregate ? "agent-loop" : "call-l4"
            let receiptID = mode == .missingReceipt ? "" : "receipt-l4"
            let attemptID = mode == .wrongAttempt
                ? "wrong-\(composerSnapshot.attemptID)"
                : composerSnapshot.attemptID
            let fact = ToolExecutionFact(
                toolCallID: callID,
                receiptID: receiptID,
                toolName: "web_search",
                status: .succeeded,
                attemptID: attemptID,
                attemptNumber: executionIdentity.attempt,
                executionIdentity: executionIdentity,
                compositeKey: ToolExecutionCompositeKey(
                    sessionID: executionIdentity.turn.sessionID,
                    turnID: executionIdentity.turn.turnID,
                    messageID: executionIdentity.turn.messageID,
                    operationID: executionIdentity.operationID,
                    attemptID: attemptID,
                    attemptNumber: executionIdentity.attempt,
                    toolCallID: callID
                )
            )
            let event = AgentStreamEvent.toolCallComplete(
                id: callID,
                name: fact.toolName,
                args: [:],
                metadata: ToolCallMetadata(toolExecutionFact: fact)
            )
            continuation.yield(event)
            if mode == .duplicate {
                continuation.yield(event)
            }
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
}
