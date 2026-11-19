import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// D-CHAT-03 / D-PERF-01: exercise the actual store consumer with a bounded,
/// manually driven producer. No cloud calls, UI, or durable session data.
@Suite("ChatStore stream frame coalescing")
@MainActor
struct ChatStoreStreamFrameCoalescingTests {
    @Test func firstTextAndQuietTailAreVisibleBeforeProducerCompletes() async throws {
        let (chat, engine) = try await startChat()
        let firstStarted = ContinuousClock.now
        engine.continuation.yield(.textDelta("首字🙂"))
        #expect(try await waitUntil { chat.messages.last?.content == "首字🙂" })
        let firstVisible = ContinuousClock.now - firstStarted
        #expect(chat.isStreaming, "首段必须在 producer 终态之前可见")
        engine.continuation.yield(.textDelta("安静前的尾块e\u{301}👨‍👩‍👧‍👦"))
        #expect(try await waitUntil {
            chat.messages.last?.content == "首字🙂安静前的尾块e\u{301}👨‍👩‍👧‍👦"
        })
        #expect(chat.isStreaming, "producer 暂静时也必须 flush，不能等终态")
        print("SYNTHETIC_STREAM first_visible=\(firstVisible) producer_open=true")
        engine.continuation.finish()
        #expect(try await waitUntil { !chat.isStreaming })
    }

    @Test func tinyBurstCompletesWithoutAnArtificialDelayPerEvent() async throws {
        let (chat, engine) = try await startChat()
        let chunks = (0..<128).map { _ in "字" }
        let started = ContinuousClock.now
        for chunk in chunks { engine.continuation.yield(.textDelta(chunk)) }
        engine.continuation.yield(.done(stopReason: .endTurn))
        engine.continuation.finish()
        // Old consumer needs >=128*16ms even though the producer is already
        // finished. One second leaves ample device-load margin for frame merge.
        let completed = try await waitUntil(timeout: .seconds(1)) { !chat.isStreaming }
        let content = chat.messages.last?.content
        let elapsed = ContinuousClock.now - started
        if !completed { chat.stopStreaming() }
        print("SYNTHETIC_STREAM tiny_events=128 completion=\(elapsed) completed=\(completed)")
        #expect(completed, "消费者仍按每个微分片强加 16ms 等待")
        #expect(content == chunks.joined(), "末帧必须 flush 所有已收到字符")
    }

    @Test func stopFreezesVisibleTextAndRejectsLateChunksAndTerminal() async throws {
        let (chat, engine) = try await startChat()
        engine.continuation.yield(.textDelta("已显示"))
        #expect(try await waitUntil { chat.messages.last?.content == "已显示" })
        engine.continuation.yield(.textDelta("等待下一帧"))
        await Task.yield()
        chat.stopStreaming()
        let frozen = chat.messages.last?.content
        #expect(!chat.isStreaming)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(chat.messages.last?.wasInterrupted == true)
        #expect(frozen?.hasPrefix("已显示") == true)
        engine.continuation.yield(.textDelta("迟到块不得写回"))
        engine.continuation.yield(.done(stopReason: .endTurn))
        engine.continuation.finish()
        try await Task.sleep(for: .milliseconds(100))
        #expect(chat.messages.last?.content == frozen)
        #expect(!chat.isStreaming)
    }

    @Test func providerErrorFlushesReceivedTailBeforeTheErrorMarker() async throws {
        let (chat, engine) = try await startChat()
        engine.continuation.yield(.textDelta("首"))
        #expect(try await waitUntil { chat.messages.last?.content == "首" })
        engine.continuation.yield(.textDelta("错误前收到的尾块"))
        engine.continuation.finish(throwing: SyntheticStreamFailure())
        #expect(try await waitUntil { !chat.isStreaming })
        #expect(chat.messages.last?.content.hasPrefix("首错误前收到的尾块\n\n**错误**") == true)
        #expect(chat.messages.last?.isStreaming == false)
    }

    @Test func toolBarrierKeepsTextToolAndNextTextInProducerOrder() async throws {
        let (chat, engine) = try await startChat()
        engine.continuation.yield(.textDelta("先"))
        #expect(try await waitUntil { chat.messages.last?.content == "先" })
        let identity = try #require(engine.executionIdentity)
        let snapshot = try #require(engine.composerSnapshot)
        let key = ToolExecutionCompositeKey(
            sessionID: identity.turn.sessionID, turnID: identity.turn.turnID,
            messageID: identity.turn.messageID, operationID: identity.operationID,
            attemptID: snapshot.attemptID, attemptNumber: identity.attempt,
            toolCallID: "frame-order-tool"
        )
        let fact = ToolExecutionFact(
            toolCallID: key.toolCallID, receiptID: "synthetic-frame-order-receipt",
            toolName: "file_read", status: .succeeded,
            attemptID: snapshot.attemptID, attemptNumber: identity.attempt,
            executionIdentity: identity, compositeKey: key
        )
        engine.continuation.yield(.textDelta("待显"))
        engine.continuation.yield(.toolCallComplete(
            id: key.toolCallID, name: "file_read", args: [:],
            metadata: ToolCallMetadata(toolExecutionFact: fact)
        ))
        #expect(try await waitUntil {
            chat.conversationEvents.contains { $0.kind == .tool && $0.toolCallID == key.toolCallID }
        })
        // The tool is a structured event; its visibility still barriers preceding text.
        #expect(chat.messages.last?.content == "先待显")
        engine.continuation.yield(.textDelta("后"))
        engine.continuation.finish()
        #expect(try await waitUntil { !chat.isStreaming })
        #expect(chat.messages.last?.content == "先待显后")
    }

    private func startChat() async throws -> (ChatStore, ControlledFrameStreamEngine) {
        let chat = ChatStore()
        let engine = ControlledFrameStreamEngine()
        chat.agentEngine = engine
        chat.draftText = "合成消费者时序验证"
        chat.sendDraft()
        #expect(try await waitUntil { engine.executionIdentity != nil })
        return (chat, engine)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }
}

private struct SyntheticStreamFailure: Error {}

final class ControlledFrameStreamEngine: ComposerSnapshotForwardingTestEngine, Sendable {
    let stream: AsyncThrowingStream<AgentStreamEvent, Error>
    let continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    @MainActor private(set) var executionIdentity: AgentExecutionIdentity?
    @MainActor private(set) var composerSnapshot: ComposerSubmissionSnapshot?
    var isAvailable: Bool { false }

    init() {
        let pair = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> { stream }

    @MainActor func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int, conversationID: String?,
        authorizedSessionReadSessionID: String?, authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?, composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        self.executionIdentity = executionIdentity
        self.composerSnapshot = composerSnapshot
        return stream
    }

    func interrupt() {}
    func compactContext(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}
