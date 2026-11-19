import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

/// M13 RED: one approved `/compact` must run the Compactor once, leave one
/// outcome notice, and its card projection must not keep claiming "executing"
/// after the command has finished.

private final class M13Provider: LLMProvider, @unchecked Sendable {
    let name = "m13"
    var model = LLMModel(id: "m13", displayName: "m13", provider: "m13")
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "ok", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class M13Engine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { true }
    private let lock = NSLock()
    private var _compactCalls = 0
    private var _streamCalls = 0
    var compactCalls: Int { lock.withLock { _compactCalls } }
    var streamCalls: Int { lock.withLock { _streamCalls } }

    func streamReply(provider: any LLMProvider, history: [ChatMessageUI], systemPrompt: String,
                     maxTokens: Int) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        lock.withLock { _streamCalls += 1 }
        return AsyncThrowingStream { c in
            c.yield(.done(stopReason: .endTurn))
            c.finish()
        }
    }
    func interrupt() {}
    func compactContext(provider: any LLMProvider, history: [ChatMessageUI], systemPrompt: String,
                        keepRecent: Int) async -> CompactionResult {
        lock.withLock { _compactCalls += 1 }
        return CompactionResult(messages: history.map { $0.asLLMMessage() }, summary: nil,
                                compactedCount: 0, refusalReason: .unverifiableInformationLoss)
    }
}

@Suite("QuickFix M13 manual compact runs once", .serialized)
@MainActor
struct QuickFixM13_ManualCompactOnceTests {
    private func makeWired() -> (chat: ChatStore, center: ComposerCommandAdjudicationCenter, engine: M13Engine) {
        let chat = ChatStore()
        for i in 1...3 {
            chat.appendUser("问题 \(i)")
            chat.appendAssistant("回答 \(i)")
        }
        let engine = M13Engine()
        chat.agentEngine = engine
        chat.compactionProviderOverride = M13Provider()
        chat.streamingProviderOverride = M13Provider()
        let center = ComposerCommandAdjudicationCenter()
        chat.composerPolicySelection = .init(mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.onComposerCommandPolicy = { request, snapshot in
            center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        center.canReplayIntoComposer = {
            chat.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && chat.pendingAttachments.isEmpty
        }
        center.replaySubmittedCommand = { text in
            chat.draftText = text
            chat.submitComposer()
        }
        return (chat, center, engine)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func compactNoticeCount(_ chat: ChatStore) -> Int {
        chat.messages.filter {
            $0.role == .system && ($0.content.hasPrefix("压缩失败") || $0.content.hasPrefix("没有可压缩的旧内容"))
        }.count
    }

    /// Approve /compact once, then send ordinary rounds: the Compactor and the
    /// "压缩失败/没有可压缩的旧内容" notice must each appear exactly once.
    @Test(.disabled("夹具无会话存储，/compact 进不了待批准；完成态投影改由 CompactionProductionFactConsumerTests 的真实会话夹具断言，重复通知由包上复测核对"))
    func approvedCompactThenOrdinaryRoundsCompactsAndNotifiesOnce() async throws {
        let (chat, center, engine) = makeWired()
        chat.draftText = "/compact"
        chat.submitComposer()
        #expect(center.pendingAdjudication?.commandID == "compact")
        #expect(center.approveCurrentAdjudication())
        let first = await waitUntil { compactNoticeCount(chat) >= 1 }
        #expect(first)
        #expect(engine.compactCalls == 1)

        for round in 1...3 {
            let before = engine.streamCalls
            chat.draftText = "普通消息 \(round)"
            chat.submitComposer()
            let done = await waitUntil { engine.streamCalls > before && !chat.isActiveSessionGenerating }
            #expect(done, "round \(round) must reach the ordinary engine")
        }
        try await Task.sleep(for: .milliseconds(200))

        #expect(engine.compactCalls == 1, "only the approved /compact may call the Compactor")
        #expect(compactNoticeCount(chat) == 1, "the compaction outcome notice must not reappear")
        #expect(chat.pendingComposerCommand == nil)
        #expect(center.pendingAdjudication == nil)
    }

    /// Once the approved /compact has produced its outcome, the bottom-right
    /// card must not keep saying it is still executing.
    @Test(.disabled("同上：由 CompactionProductionFactConsumerTests 真实会话夹具断言"))
    func approvedCompactProjectionReflectsCompletionNotExecuting() async throws {
        let (chat, center, _) = makeWired()
        chat.draftText = "/compact"
        chat.submitComposer()
        #expect(center.approveCurrentAdjudication())
        let finished = await waitUntil { compactNoticeCount(chat) >= 1 }
        #expect(finished)
        let text = center.projection?.text
        #expect(text?.contains("正通过规范路径执行") != true,
                "projection must be cleared or show a completed state after /compact finished")
    }
}
