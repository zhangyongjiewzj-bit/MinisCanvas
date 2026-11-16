import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class ExternalContextCapturingEngineR12: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { true }

    private let lock = NSLock()
    private var capturedCalls: [(sessionID: String?, scope: SessionReadScope?)] = []

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeStream()
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        recordCall(sessionID: authorizedSessionReadSessionID, scope: authorizedSessionReadScope)
        return makeStream()
    }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }

    func snapshotCalls() -> [(sessionID: String?, scope: SessionReadScope?)] {
        lock.lock()
        defer { lock.unlock() }
        return capturedCalls
    }

    private nonisolated func recordCall(
        sessionID: String?,
        scope: SessionReadScope?
    ) {
        lock.lock()
        capturedCalls.append((sessionID, scope))
        lock.unlock()
    }

    private func makeStream() -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("ok"))
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
}

/// F-EXT-b: the local `session_read` clarification prompt must not fire for
/// instructions that only talk about external-agent (Codex / Claude Code)
/// sessions. Mixed sentences, ID-shaped targets that are not external-qualified,
/// explicit authorization, and quoted / negated authorization stay fail-closed.
@Suite("R12 external-agent sentence reaches the engine without a session_read capability")
struct ExternalContextSessionReadGuard_R12_Tests {
    @MainActor
    @Test("external-agent sentence reaches the engine and mints no session_read capability")
    func externalSentenceReachesEngineWithoutCapability() async throws {
        let chat = ChatStore()
        let engine = ExternalContextCapturingEngineR12()
        chat.agentEngine = engine
        chat.draftText = "X15 新会话里读取外部会话列表"

        chat.submitComposer()
        var waited = 0
        while engine.snapshotCalls().isEmpty && waited < 100 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }

        let calls = engine.snapshotCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.sessionID == nil)
        #expect(calls.first?.scope == nil)
        #expect(chat.messages.last?.content.contains("需要明确授权及读取范围") == false)
    }
}
