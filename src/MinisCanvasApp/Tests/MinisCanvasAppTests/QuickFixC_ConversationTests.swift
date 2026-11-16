import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// 快档修复 线 C：RED（压缩文案/通知次数、重新生成禁用态、指标行供应商显示名）。

private final class QuickFixCRefusingEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { false }
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    func streamReply(provider: any LLMProvider, history: [ChatMessageUI], systemPrompt: String,
                     maxTokens: Int) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func interrupt() {}
    func compactContext(provider: any LLMProvider, history: [ChatMessageUI], systemPrompt: String,
                        keepRecent: Int) async -> CompactionResult {
        lock.withLock { _calls += 1 }
        return CompactionResult(messages: history.map { $0.asLLMMessage() }, summary: nil,
                                compactedCount: 0, refusalReason: .unverifiableInformationLoss)
    }
}

@Suite("QuickFixC 对话与转录")
@MainActor
struct QuickFixCConversationTests {
    private func makeChat() -> ChatStore {
        let chat = ChatStore()
        chat.appendUser("第一条"); chat.appendAssistant("回复一")
        chat.appendUser("第二条"); chat.appendAssistant("回复二")
        chat.appendUser("第三条")
        return chat
    }

    private func compactionNotices(_ chat: ChatStore) -> [String] {
        chat.messages.filter { $0.role == .system
            && ($0.content.contains("压缩失败") || $0.content.contains("没有可压缩的旧内容")
                || $0.content.contains("未压缩")) }.map(\.content)
    }

    // M13 文案：压缩改为模型摘要后，附件、工具往来都不再造成拒绝；
    // 拒绝只剩“没有可压缩的旧内容”，是主动跳过，不是失败。
    @Test("M13：拒绝的文案不说“压缩失败”，说“没有可压缩的旧内容”")
    func refusalCopyIsSkipNotFailure() {
        let text = ChatCompactionSafetyError.compactorRefused.errorDescription ?? ""
        #expect(text.contains("没有可压缩的旧内容"))
        #expect(!text.contains("失败"))
    }

    @Test("M13：保护性跳过时转录和结果区都显示没有可压缩的旧内容，不报失败")
    func refusalNoticeInTranscriptIsSkip() async throws {
        let chat = makeChat()
        let engine = QuickFixCRefusingEngine()
        chat.agentEngine = engine
        await chat.runCompaction(history: chat.messages, keepRecent: 3)
        let notice = try #require(chat.messages.last(where: { $0.role == .system })?.content)
        let expectedNotice = "/compact 已完成：没有可压缩的旧内容"
        #expect(notice == expectedNotice)
        #expect(!notice.contains("压缩失败"))
        let presentation = try #require(chat.compactionPresentation)
        #expect(presentation.state == .skipped(expectedNotice))
        #expect(presentation.message == notice)
    }

    // M13 次数：一次 /compact 只产生一次结果通知；之后的回合不得再追加。
    // 注意：读代码未发现确定的重放路径（只有 ChatAgentEngine.runCompaction 追加该通知，
    // 入口为 compactContext/确认/批准重放），此条是“一次执行一次通知”的行为护栏。
    @Test("M13：一次 compactContext 只产生一条结果通知，后续回合不再追加")
    func oneCompactionProducesOneNotice() async throws {
        let chat = makeChat()
        let engine = QuickFixCRefusingEngine()
        chat.agentEngine = engine
        chat.compactContext(keepRecent: 3)
        var waited = 0.0
        while compactionNotices(chat).isEmpty && waited < 5 {
            try await Task.sleep(for: .milliseconds(50)); waited += 0.05
        }
        #expect(compactionNotices(chat).count == 1)
        chat.appendUser("后续问题"); chat.appendAssistant("后续回答")
        chat.appendUser("再一个问题"); chat.appendAssistant("再一个回答")
        try await Task.sleep(for: .milliseconds(400))
        #expect(compactionNotices(chat).count == 1)
        #expect(engine.calls == 1, "压缩只应被执行一次")
    }

    // 重新生成：禁用态要有可辨外观并直接展示原因（需要新的纯函数）。
    @Test("重新生成：禁用时降低不透明度并直接可见原因文字")
    func regenerationDisabledPresentationIsVisible() {
        let reason = "请等待当前回合结束"
        let disabled = RegenerationButtonPresentation.make(disabledReason: reason)
        #expect(disabled.isDisabled)
        #expect(disabled.opacity < 1.0)
        #expect(disabled.visibleReasonText == reason)
        let enabled = RegenerationButtonPresentation.make(disabledReason: nil)
        #expect(!enabled.isDisabled)
        #expect(enabled.opacity == 1.0)
        #expect(enabled.visibleReasonText == nil)
    }

    // 指标行：使用供应商显示名，不暴露内部记录名。
    @Test("指标行：DEEPSEEK_API_KEY 显示为 DeepSeek")
    func metricsLineUsesProviderDisplayName() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var timing = ChatTurnTimingMetadata(startedAt: started)
        timing.finishedAt = started.addingTimeInterval(2)
        let text = try #require(timing.turnDisplayText(
            providerName: "DEEPSEEK_API_KEY", modelID: "deepseek-chat", now: started.addingTimeInterval(3)))
        #expect(!text.contains("DEEPSEEK_API_KEY"), Comment(rawValue: text))
        #expect(text.contains("服务商 DeepSeek"), Comment(rawValue: text))
    }
    @Test func metricsLineDoesNotExposeUnknownProviderIdentity() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var timing = ChatTurnTimingMetadata(startedAt: started)
        timing.finishedAt = started.addingTimeInterval(2)
        let internalID = "SYNTHETIC_PRIVATE_PROVIDER_ROUTE"
        let text = try #require(timing.turnDisplayText(
            providerName: internalID, modelID: "owned-model"))
        #expect(!text.contains(internalID))
        #expect(text.contains("服务商 自定义"))
        #expect(text.contains("模型 owned-model"))
    }

}
