import Foundation
import Testing
@testable import MinisCore

/// R6: an OpenAI-compatible endpoint that reports only `prompt_tokens` (no
/// cached-token detail) still reported the full prompt input, so the context
/// denominator must be known. Before the fix `cacheHitInputTokens` was nil for
/// this shape, which left the App's occupancy chip at "—" and gave the
/// compaction trigger no anchor.
@Suite("R6 Chat Completions prompt-only usage keeps the input denominator")
struct ChatCompletionsPromptOnlyUsageR6Tests {
    @Test func promptTokensWithoutCacheDetailIsTheFullInput() {
        let usage = OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 32_000, "completion_tokens": 50,
        ])
        #expect(usage.inputTokens == 32_000)
        #expect(usage.outputTokens == 50)
        #expect(usage.cacheHitInputTokens == 32_000)
        #expect(usage.cacheReadInputTokens == nil)
    }

    @Test func streamUsageChunkWithoutCacheDetailKeepsTheDenominator() {
        let chunk = OpenAIStreamDecoder.decodeChunk([
            "choices": [],
            "usage": ["prompt_tokens": 94_720, "completion_tokens": 7, "total_tokens": 94_727],
        ])
        #expect(chunk?.usage?.cacheHitInputTokens == 94_720)
    }

    @Test func outputOnlyChatUsageStillNeverInventsKnownInput() {
        let usage = OpenAICompatibleProvider.parseChatCompletionsUsage(["completion_tokens": 7])
        #expect(usage.cacheHitInputTokens == nil)
    }

    @Test func zeroPromptTokensWithoutCacheDetailYieldsNoAnchor() {
        let usage = OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 0, "completion_tokens": 5,
        ])
        #expect(usage.cacheHitInputTokens == nil)
    }
}
