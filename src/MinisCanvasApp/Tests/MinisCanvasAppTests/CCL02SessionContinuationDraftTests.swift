import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("L02 editable continuation summary")
@MainActor struct CCL02SessionContinuationDraftTests {
    @Test func compactorUsesModelSummaryThenAcceptsUserEditsAsBackground() async {
        let source = UUID()
        let draft = SessionContinuationDraft(sourceSessionID: source)
        await draft.generate(messages: [.init(role: .user, content: "Finish synthetic task")],
            provider: CCL02SummaryProvider(fails: false))
        #expect(draft.sourceSessionID == source)
        // 2026-11-16：摘要改为“有损摘要”格式（由模型生成、会有损，原话以用户为准）；
        // 不再断言整段文字，只验证来源标注与模型摘要正文。
        // 交接摘要只给摘要正文（不带“续做”提示和原话块），供用户审阅后作为新会话背景。
        #expect(!draft.previewText.hasPrefix("以下是此前对话的摘要"))
        #expect(draft.previewText.contains("model handoff"))
        #expect(draft.failureMessage == nil)
        #expect(!draft.isGenerating)
        draft.previewText = "User corrected the next step"
        #expect(draft.confirmedBackgroundText?.hasSuffix("User corrected the next step") == true)
        #expect(draft.confirmedBackgroundText?.contains("不授予执行权限") == true)
    }

    @Test func providerFailureDoesNotPresentLegacyLocalFallbackAsModelSummary() async {
        let draft = SessionContinuationDraft(sourceSessionID: UUID())
        await draft.generate(messages: [.init(role: .user, content: "synthetic history")],
            provider: CCL02SummaryProvider(fails: true))
        #expect(draft.failureMessage != nil)
        #expect(draft.previewText.isEmpty)
        #expect(draft.confirmedBackgroundText == nil)
        #expect(!draft.isGenerating)
        draft.previewText = "manual summary after failure"
        #expect(draft.confirmedBackgroundText?.hasSuffix("manual summary after failure") == true)
    }

    @Test func dismissedGenerationCannotOverwriteAUserEditedDraft() async {
        let started = AsyncStream<Void>.makeStream()
        let gate = CCL02SummaryGate(started: started.continuation)
        let draft = SessionContinuationDraft(sourceSessionID: UUID())
        draft.markGenerationPending()
        #expect(draft.isGenerating)
        let generation = Task {
            await draft.generate(messages: [.init(role: .user, content: "synthetic history")],
                provider: CCL02DelayedSummaryProvider(gate: gate))
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        draft.cancelGeneration()
        draft.previewText = "manual text after dismiss"
        await gate.release()
        await generation.value
        started.continuation.finish()
        #expect(draft.previewText == "manual text after dismiss")
        #expect(!draft.isGenerating)
    }

    @Test func staleSourceReportsInsidePreviewWithoutChangingEditedSummary() {
        let draft = SessionContinuationDraft(sourceSessionID: UUID())
        draft.previewText = "user edited background"
        let background = draft.confirmedBackgroundText
        draft.reportSourceRevisionChanged()
        #expect(draft.failureMessage == "原会话已变化，请重新生成摘要。")
        #expect(draft.previewText == "user edited background")
        #expect(draft.confirmedBackgroundText == background)
        #expect(!draft.isGenerating)
    }

    @Test func whitespaceOnlyEditingAllowsExplicitEmptyContinuation() {
        let draft = SessionContinuationDraft(sourceSessionID: UUID())
        draft.previewText = " \n "
        #expect(draft.confirmedBackgroundText == nil)
    }
}

private struct CCL02SummaryProvider: LLMProvider {
    let fails: Bool
    let name = "synthetic-continuation"
    var model = LLMModel(id: "synthetic", displayName: "synthetic", provider: "synthetic-continuation")
    enum Failure: Error { case unavailable }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        if fails { throw Failure.unavailable }
        return LLMResponse(text: "model handoff", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor CCL02SummaryGate {
    let started: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    init(started: AsyncStream<Void>.Continuation) { self.started = started }
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.yield(())
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private struct CCL02DelayedSummaryProvider: LLMProvider {
    let gate: CCL02SummaryGate
    let name = "synthetic-delayed-continuation"
    var model = LLMModel(id: "synthetic", displayName: "synthetic", provider: "synthetic-delayed-continuation")
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        await gate.wait()
        return LLMResponse(text: "late model summary", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
