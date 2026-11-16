import Testing
@testable import MinisCore

@Suite("418 Provider 缓存分母事实")
struct ProviderUsageAccounting418Tests {
    @Test func classicAndDeepSeekKeepFreshBudgetAndFullInputDenominator() {
        let classic = OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 10, "completion_tokens": 2,
            "prompt_tokens_details": ["cached_tokens": 4],
        ])
        #expect(classic.inputTokens == 6)
        #expect(classic.cacheReadInputTokens == 4)
        #expect(classic.cacheHitInputTokens == 10)
        let deepSeek = OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 3470, "completion_tokens": 31, "prompt_cache_hit_tokens": 3328,
        ])
        #expect(deepSeek.inputTokens == 142)
        #expect(deepSeek.outputTokens == 31)
        #expect(deepSeek.inputTokens + deepSeek.outputTokens == 173)
        #expect(deepSeek.cacheReadInputTokens == 3328)
        #expect(deepSeek.cacheHitInputTokens == 3470)
    }

    @Test func responsesKeepInclusiveNumericContract() throws {
        let usage = try #require(ResponsesAPIResponseParser.parseUsage([
            "input_tokens": 12, "output_tokens": 7,
            "input_tokens_details": ["cached_tokens": 4],
        ]))
        #expect(usage.inputTokens == 12)
        #expect(usage.outputTokens == 7)
        #expect(usage.cacheReadInputTokens == 4)
        #expect(usage.cacheHitInputTokens == 12)
    }

    @Test func anthropicBufferedAndStreamMergePreserveFreshCacheContract() throws {
        let raw: [String: Any] = ["input_tokens": 6, "output_tokens": 1,
            "cache_read_input_tokens": 3, "cache_creation_input_tokens": 1]
        let buffered = AnthropicProvider.parseMessagesUsage(raw)
        let start = try #require(AnthropicStreamDecoder.parseUsage(raw))
        let delta = try #require(AnthropicStreamDecoder.parseUsage(["output_tokens": 7]))
        let merged = try #require(AnthropicProvider.mergedAssistantStreamUsage(messageUsage: start, deltaUsage: delta))
        #expect(buffered.inputTokens == 6)
        #expect(buffered.cacheHitInputTokens == 10)
        #expect(merged.inputTokens == 6)
        #expect(merged.outputTokens == 7)
        #expect(merged.cacheHitInputTokens == 10)
        let response = AnthropicProvider.assistantStreamCompletedResponse(
            blockOrder: [], blocks: [:], stopReason: "end_turn", messageUsage: start, deltaUsage: delta)
        #expect(response.usage == merged)
    }

    @Test func outputOnlyAndUntypedUsageNeverInventKnownInput() throws {
        #expect(LLMUsage(inputTokens: 6, outputTokens: 7).cacheHitInputTokens == nil)
        #expect(AnthropicProvider.parseMessagesUsage(["output_tokens": 7]).cacheHitInputTokens == nil)
        let delta = try #require(AnthropicStreamDecoder.parseUsage(["output_tokens": 7]))
        let response = AnthropicProvider.assistantStreamCompletedResponse(
            blockOrder: [], blocks: [:], stopReason: "end_turn", messageUsage: nil, deltaUsage: delta)
        #expect(response.usage?.outputTokens == 7)
        #expect(response.usage?.cacheHitInputTokens == nil)
        #expect(ResponsesAPIResponseParser.parseUsage(["output_tokens": 7])?.cacheHitInputTokens == nil)
    }

    @Test func invalidCacheAndOverflowKeepDenominatorUnknown() {
        let classic = OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 142, "completion_tokens": 31, "prompt_cache_hit_tokens": 3328,
        ])
        #expect(classic.inputTokens == 142) // Original fallback numeric contract.
        #expect(classic.cacheHitInputTokens == nil)
        #expect(OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 10, "prompt_cache_hit_tokens": -1,
        ]).cacheHitInputTokens == nil)
        #expect(ResponsesAPIResponseParser.parseUsage([
            "input_tokens": 12, "input_tokens_details": ["cached_tokens": 13],
        ])?.cacheHitInputTokens == nil)
        #expect(AnthropicProvider.parseMessagesUsage([
            "input_tokens": Int.max, "cache_read_input_tokens": 1,
        ]).cacheHitInputTokens == nil)
        #expect(AnthropicStreamDecoder.parseUsage([
            "input_tokens": 1, "cache_creation_input_tokens": -1,
        ])?.cacheHitInputTokens == nil)
    }
}
