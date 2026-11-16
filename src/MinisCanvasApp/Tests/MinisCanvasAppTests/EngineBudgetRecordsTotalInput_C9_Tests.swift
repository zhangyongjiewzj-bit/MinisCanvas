import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// C9, the engine half: the usage the engine hands to the budget mirror is
/// total input (fresh + cache read + cache write) + output, the same figure
/// `BudgetTracker.completeRequest` settles. `inputTokens` semantics are untouched
/// (`ProviderUsageAccounting418Tests`).
@Suite("C9 engine budget callback charges total input")
struct EngineBudgetRecordsTotalInput_C9_Tests {
    private final class ScriptedProvider: LLMProvider, @unchecked Sendable {
        let name = "c9-script"
        var model = LLMModel(id: "c9-script", displayName: "C9 script", provider: "c9-script")
        private let usage: LLMUsage
        init(usage: LLMUsage) { self.usage = usage }
        func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                         temperature: Double?) async throws -> LLMResponse {
            LLMResponse(text: "ok", stopReason: "stop", usage: usage)
        }
        func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                           temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            throw LLMError.unsupportedCapability(.streaming)
        }
    }

    private final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int] = []
        var values: [Int] { lock.withLock { stored } }
        func append(_ value: Int) { lock.withLock { stored.append(value) } }
    }

    /// Anthropic shape: 2_000 fresh + 80_000 cache read = 82_000 total input.
    @Test func recordedTokensAreTotalInputPlusOutput() async throws {
        let recorded = Recorded()
        let provider = BudgetRecordingProvider(
            base: ScriptedProvider(usage: LLMUsage(inputTokens: 2_000, outputTokens: 500,
                cacheReadInputTokens: 80_000, cacheHitInputTokens: 82_000)),
            onRecorded: { recorded.append($0) })
        _ = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "hello")], systemPrompt: nil,
            maxTokens: 16, temperature: nil)
        #expect(recorded.values == [82_500])
    }

    /// No cache detail: total input falls back to `inputTokens`, nothing invented.
    @Test func usageWithoutCacheDetailKeepsInputTokens() async throws {
        let recorded = Recorded()
        let provider = BudgetRecordingProvider(
            base: ScriptedProvider(usage: LLMUsage(inputTokens: 2_000, outputTokens: 500)),
            onRecorded: { recorded.append($0) })
        _ = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "hello")], systemPrompt: nil,
            maxTokens: 16, temperature: nil)
        #expect(recorded.values == [2_500])
    }
}
