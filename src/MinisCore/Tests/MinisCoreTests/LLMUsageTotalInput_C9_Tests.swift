import Testing
@testable import MinisCore

/// C9（Core 部分）：同一份“实际总输入”，三家 wire 形态得到相同的 `totalInputTokens`。
/// `inputTokens` 语义不变，由 ProviderUsageAccounting418Tests 继续钉住。
/// App 侧消费方（预算结算、用量页、子任务汇总）的用例归 C-L4（AT/UsageTotalsUseTotalInput_C9_Tests）。
@Suite("C9 总输入口径")
struct LLMUsageTotalInputC9Tests {
    @Test func anthropicTotalIsFreshPlusCacheReadPlusCacheWrite() {
        let usage = AnthropicProvider.parseMessagesUsage([
            "input_tokens": 6, "output_tokens": 1,
            "cache_read_input_tokens": 3, "cache_creation_input_tokens": 1,
        ])
        #expect(usage.inputTokens == 6)
        #expect(usage.totalInputTokens == 10)
    }

    @Test func chatCompletionsTotalIsPromptTokensNotFreshOnly() {
        let usage = OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 10, "completion_tokens": 2,
            "prompt_tokens_details": ["cached_tokens": 4],
        ])
        #expect(usage.inputTokens == 6)
        #expect(usage.totalInputTokens == 10)
    }

    @Test func deepSeekHitFieldTotalIsPromptTokens() {
        let usage = OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 3470, "completion_tokens": 31, "prompt_cache_hit_tokens": 3328,
        ])
        #expect(usage.totalInputTokens == 3470)
    }

    @Test func responsesTotalIsInclusiveInputTokens() throws {
        let usage = try #require(ResponsesAPIResponseParser.parseUsage([
            "input_tokens": 12, "output_tokens": 7,
            "input_tokens_details": ["cached_tokens": 4],
        ]))
        #expect(usage.totalInputTokens == 12)
    }

    @Test func threeWireShapesOfTheSameRequestAgree() throws {
        let anthropic = AnthropicProvider.parseMessagesUsage([
            "input_tokens": 2, "output_tokens": 5,
            "cache_read_input_tokens": 7, "cache_creation_input_tokens": 1,
        ])
        let chat = OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 10, "completion_tokens": 5,
            "prompt_tokens_details": ["cached_tokens": 7],
        ])
        let responses = try #require(ResponsesAPIResponseParser.parseUsage([
            "input_tokens": 10, "output_tokens": 5,
            "input_tokens_details": ["cached_tokens": 7],
        ]))
        #expect(anthropic.totalInputTokens == 10)
        #expect(chat.totalInputTokens == 10)
        #expect(responses.totalInputTokens == 10)
    }

    @Test func usageWithoutDenominatorKeepsInputTokensAndNeverInventsCache() {
        let usage = LLMUsage(inputTokens: 5, outputTokens: 1)
        #expect(usage.totalInputTokens == 5)
        let withCacheFieldsButNoDenominator = LLMUsage(
            inputTokens: 5, outputTokens: 1, cacheCreationInputTokens: 2, cacheReadInputTokens: 3)
        #expect(withCacheFieldsButNoDenominator.totalInputTokens == 5)
    }
}
