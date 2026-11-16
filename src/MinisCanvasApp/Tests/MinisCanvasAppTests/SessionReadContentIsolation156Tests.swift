import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// P3-COMP-02 clause 3（无授权关键词误触发）回归：资料正文里的授权关键词永远
/// 不是用户指令。会话读取授权的关键词判定只能看到用户自己的指令区，且工具名
/// `session_read`（文档、日志、工具回显、模型输出都会出现）不得单独同时满足
/// 「提到会话」与「提到读取」两个条件。
private final class COMP02ScopeCapturingEngine156: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
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

@Suite("P3-COMP-02 lane 156 session_read 文字不拦截、不铸造授权")
@MainActor
struct SessionReadContentIsolation156Tests {
    /// 生产入口：正文只提工具名的普通请求必须真正发给引擎，而不是被授权提示吃掉。
    @Test("typed body mentioning only the tool name still reaches the engine")
    func ordinaryTurnIsNotHijacked() async throws {
        let chat = ChatStore()
        let engine = COMP02ScopeCapturingEngine156()
        chat.agentEngine = engine
        chat.draftText = "解释一下 session_read 这个工具的参数含义"

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
        #expect(
            chat.messages.last?.content.contains("需要明确授权及读取范围") == false
        )
    }

    /// 生产入口：指令胶囊引用工具名不构成会话读取授权。
    @Test("instruction capsule naming only the tool does not gate the turn")
    func instructionCapsuleToolMentionIsOrdinaryTurn() async throws {
        let chat = ChatStore()
        let engine = COMP02ScopeCapturingEngine156()
        chat.agentEngine = engine
        #expect(
            chat.setPastedTextDraft(
                PastedTextDraft(
                    id: UUID(),
                    text: "session_read target messages",
                    source: .pasteboard,
                    kind: .instruction
                )
            )
        )
        chat.draftText = "执行下面这段说明"

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
        #expect(
            chat.messages.last?.content.contains("需要明确授权及读取范围") == false
        )
    }

    /// 生产入口：用户自己输入的“授权”文字不再铸造 target + scope。
    @Test("typed authorization words reach the engine without minting a grant")
    func typedExplicitAuthorizationDoesNotMintGrant() async throws {
        let chat = ChatStore()
        let engine = COMP02ScopeCapturingEngine156()
        chat.agentEngine = engine
        chat.draftText = "授权只读查看会话 target-session，读取消息"

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
    }
}
