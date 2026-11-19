import Foundation
import Testing
@testable import MinisCore

// 第三波 G7：长会话、压缩与记忆。

@Suite("G7 token budget default migration")
struct G7TokenBudgetMigrationTests {
    private func decode(_ json: String) throws -> AgentSettings {
        try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
    }

    @Test func oldDefaultOfOneHundredThousandMovesToOneMillionOnce() throws {
        let migrated = try decode(#"{"maxTokensPerSession":100000}"#)
        #expect(migrated.maxTokensPerSession == 1_000_000)
        // 迁移后落盘带标记：用户之后自己设回 10 万不会再被改掉。
        let reloaded = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(
            {
                var s = migrated
                s.maxTokensPerSession = 100_000
                return s
            }()))
        #expect(reloaded.maxTokensPerSession == 100_000)
    }

    @Test func otherStoredValuesAreKept() throws {
        #expect(try decode(#"{"maxTokensPerSession":250000}"#).maxTokensPerSession == 250_000)
        #expect(try decode("{}").maxTokensPerSession == 1_000_000)
    }
}

@Suite("G7 context estimate")
struct G7ContextEstimateTests {
    @Test func cjkCountsAboutOneTokenPerCharacter() {
        #expect(AgentContextTokenBudget.estimatedTextTokens(String(repeating: "中", count: 400)) == 400)
        #expect(AgentContextTokenBudget.estimatedTextTokens(String(repeating: "a", count: 400)) == 100)
    }

    @Test func toolDefinitionsAreAddedToTheLocalEstimateButNotToAnAnchor() {
        let messages = [LLMMessage(role: .user, content: "你好，请帮我看看")]
        let plain = AgentContextTokenBudget.estimatedInputCost(messages, systemPrompt: "")
        let withTools = AgentContextTokenBudget.estimatedInputCost(messages, systemPrompt: "", toolSchemaTokens: 500)
        #expect((withTools ?? 0) - (plain ?? 0) == 500)
        let anchor = ContextWindowPolicy.Anchor(sentMessageCount: 1, reportedTotalInput: 1000, reportedOutput: 10)
        #expect(ContextWindowPolicy.estimateInput(messages: messages, systemPrompt: "", anchor: anchor,
                                                  toolSchemaTokens: 500)
            == ContextWindowPolicy.estimateInput(messages: messages, systemPrompt: "", anchor: anchor))
    }
}

@Suite("G7 second compaction keeps the previous summary tail")
struct G7SummaryRenderTests {
    @Test func previousSummaryIsRenderedWholeWithoutRepeatedBlocks() {
        let tail = "下一步：" + String(repeating: "继续迁移。", count: 2_000) + "END_OF_NEXT_STEP"
        let previous = """
            \(LossySummaryCompaction.summaryOpen)
            以下是此前对话的摘要（由模型生成，会有损）。\(LossySummaryCompaction.backgroundNotice)
            \(tail)

            \(LossySummaryCompaction.userQuotesOpen)
            - 用户原话一
            \(LossySummaryCompaction.userQuotesClose)

            事实清单 · 执行过的工具：file_read（/a）

            \(LossySummaryCompaction.continuationNotice)
            \(LossySummaryCompaction.summaryClose)
            """
        let body = LossySummaryCompaction.previousSummaryBody(previous)
        #expect(body.contains("END_OF_NEXT_STEP"))
        #expect(!body.contains("用户原话一"))
        #expect(!body.contains("事实清单"))
        #expect(!body.contains(LossySummaryCompaction.continuationNotice))
    }
}
