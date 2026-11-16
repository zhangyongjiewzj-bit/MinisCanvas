import Testing
import MinisCore
@testable import MinisCanvasApp

struct P3AcceptanceM02_CompactionRetentionTests {
    private final class NaturalSummaryProvider: LLMProvider {
        let name = "synthetic-natural-summary"
        var model = LLMModel(id: "synthetic-summary", displayName: "Fixture", provider: "fixture")
        var requests: [[LLMMessage]] = []

        func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                         maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            requests.append(messages)
            return LLMResponse(text: "The assistant compared several draft options; no actions were executed.",
                               stopReason: nil, usage: nil)
        }

        func streamMessage(messages: [LLMMessage], systemPrompt: String?,
                           maxTokens: Int, temperature: Double?) async throws
            -> AsyncThrowingStream<LLMStreamChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    // 压缩改为“旧内容由模型摘要（有损）”：旧用户轮次不再逐字保留，只保证
    // 请求体积下降、最近消息原样、摘要来自模型。

    @Test func nonRepeatingHistoryIsSummarizedByTheModelAndShrinksTheRequest() async throws {
        let provider = NaturalSummaryProvider()
        var history: [ChatMessageUI] = []
        for i in 1...8 {
            history.append(ChatMessageUI(role: .user, content: "Compare option \(i); do not execute any action."))
            history.append(ChatMessageUI(role: .assistant,
                content: "Option \(i): " + (1...16).map { "Detail \(i)-\($0) is explanatory." }.joined(separator: " ")))
        }
        history.append(ChatMessageUI(role: .user, content: "Keep the comparison as background."))
        let result = try await FallbackChatEngine().compactContext(
            provider: provider, history: history, systemPrompt: "test", keepRecent: 1
        )
        #expect(result.refusalReason == nil)
        #expect(provider.requests.count == 1)
        #expect(result.isLossySummary)
        #expect(result.compactedCount == history.count - 1)
        #expect(result.messages.first?.content.contains("The assistant compared several draft options") == true)
        #expect(Compactor.hasMaterialRequestReduction(
            from: history.map { $0.asLLMMessage() }, to: result.messages
        ))
        #expect(result.messages.last == history.last?.asLLMMessage())
    }

    @Test func oldLongTextIsSummarizedByTheModelNotRefused() async throws {
        let marker = "必须保留这项约束"
        let history = [
            ChatMessageUI(role: .user, content: String(repeating: "前", count: 600) + marker),
            ChatMessageUI(role: .assistant, content: "最近回复")
        ]
        let provider = NaturalSummaryProvider()

        let result = try await FallbackChatEngine().compactContext(
            provider: provider, history: history,
            systemPrompt: "test", keepRecent: 1
        )

        #expect(result.refusalReason == nil)
        #expect(result.compactedCount == 1)
        #expect(result.summary != nil)
        // The old long text went to the summary model whole, not truncated.
        #expect(provider.requests.first?.map(\.content).joined().contains(marker) == true)
        #expect(result.messages.last == history.last?.asLLMMessage())
    }

    @Test func displayOnlyModelIdentityDoesNotBlockCompaction() async throws {
        let history = [
            ChatMessageUI(role: .assistant, content: "旧回复", turnProviderName: "原模型"),
            ChatMessageUI(role: .user, content: "最近提问")
        ]

        let result = try await FallbackChatEngine().compactContext(
            provider: NaturalSummaryProvider(), history: history,
            systemPrompt: "test", keepRecent: 1
        )

        #expect(result.refusalReason == nil)
        #expect(result.compactedCount == 1)
        #expect(result.messages.last == history.last?.asLLMMessage())
    }

    @Test func shortPlainTextAlsoCompactsThroughTheSummaryProvider() async throws {
        let history = [
            ChatMessageUI(role: .user, content: "目标：完成验收"),
            ChatMessageUI(role: .assistant, content: "最近回复")
        ]
        let provider = NaturalSummaryProvider()

        let result = try await FallbackChatEngine().compactContext(
            provider: provider, history: history,
            systemPrompt: "test", keepRecent: 1
        )

        #expect(result.refusalReason == nil)
        #expect(provider.requests.count == 1)
        #expect(result.compactedCount == 1)
        #expect(result.summary?.contains("The assistant compared several draft options") == true)
        #expect(result.messages.last == history.last?.asLLMMessage())
    }
}
