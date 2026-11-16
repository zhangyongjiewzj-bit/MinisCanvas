import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class Usage418Observation: @unchecked Sendable {
    private let lock = NSLock()
    private var usageValues: [LLMUsage] = []
    private var budgetValues: [Int] = []
    func usage(_ value: LLMUsage) { lock.lock(); defer { lock.unlock() }; usageValues.append(value) }
    func budget(_ value: Int) { lock.lock(); defer { lock.unlock() }; budgetValues.append(value) }
    var usages: [LLMUsage] { lock.lock(); defer { lock.unlock() }; return usageValues }
    var budgets: [Int] { lock.lock(); defer { lock.unlock() }; return budgetValues }
}

/// Synthetic Provider responses only: no environment, credentials, URLSession or UI.
private struct Usage418Provider: AssistantStreamingLLMProvider {
    let name = "usage418-synthetic"
    var model = LLMModel(id: "usage418-model", displayName: "Usage418", provider: "usage418-synthetic")
    var capabilities: Set<ProviderCapability> { [.tools, .streaming] }
    let usage: LLMUsage
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "synthetic", stopReason: "end_turn", usage: usage)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.yield(.usage(usage)); $0.finish() }
    }
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                                maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        AsyncThrowingStream {
            $0.yield(.completed(LLMResponse(text: "synthetic", stopReason: "end_turn", usage: usage)))
            $0.finish()
        }
    }
}

@Suite("418 用量分母与筛选消费者")
@MainActor
struct UsageRateAndFilterIcons418Tests {
    private func record(read: Int?, input: Int?, provider: String = "synthetic") -> UsageRecord {
        UsageRecord(provider: provider, model: "synthetic-model", inputTokens: 1, outputTokens: 1,
                    cacheReadTokens: read, cacheHitInputTokens: input)
    }

    @Test func typedUsagePersistsReopensAndFiltersSameDenominator() async throws {
        let domain = UsageDefaultsDomain.suite("Usage418-\(UUID().uuidString)")
        let key = "usage418.\(UUID().uuidString)"
        let store = UsageStore(domain: domain, storageKey: key)
        let deepSeek = OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 3470, "completion_tokens": 31, "prompt_cache_hit_tokens": 3328,
        ])
        store.recordCall(provider: "Synthetic DeepSeek", model: "flash", usage: deepSeek,
                         providerRecordID: "synthetic-deepseek", timestamp: Date(timeIntervalSince1970: 100))
        let firstPersisted = await store.waitForPersistence()
        #expect(firstPersisted)
        #expect(store.totalCalls == 1)
        #expect(store.totalInputTokens == 142)
        #expect(store.totalOutputTokens == 31)
        #expect(store.totalTokens == 173)
        #expect(store.cacheHitRateText == "95.9%")
        let responses = try #require(ResponsesAPIResponseParser.parseUsage([
            "input_tokens": 12, "output_tokens": 7, "input_tokens_details": ["cached_tokens": 4],
        ]))
        store.recordCall(provider: "Synthetic Responses", model: "responses", usage: responses,
                         providerRecordID: "synthetic-responses", timestamp: Date(timeIntervalSince1970: 200))
        let secondPersisted = await store.waitForPersistence()
        #expect(secondPersisted)
        let reloaded = UsageStore(domain: domain, storageKey: key)
        let loaded = await reloaded.waitForPersistence()
        #expect(loaded)
        #expect(reloaded.totalCalls == 2)
        #expect(reloaded.totalTokens == 192)
        #expect(reloaded.callHistory.contains { $0.cacheHitInputTokens == 3470 })
        #expect(reloaded.callHistory.contains { $0.cacheHitInputTokens == 12 })
        #expect(reloaded.cacheHitProjection.rate == Double(3332) / Double(3482))
        let filtered = reloaded.query(providerRecordID: "synthetic-deepseek",
            dateInterval: DateInterval(start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 150)),
            models: ["flash"])
        #expect(filtered.totalCalls == 1)
        #expect(filtered.totalTokens == 3501)
        #expect(filtered.totalInputTokens == 3470)
        #expect(filtered.records.first?.totalTokens == 173)
        #expect(UsageCacheHitProjection(records: filtered.records).text == "95.9%")
    }

    @Test func legacyDecodeAndMixedUnknownNeverGuessOrClamp() throws {
        let original = record(read: 4, input: 10, provider: "DeepSeek")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "cacheHitInputTokens") // Legacy owned fixture, not a real preferences file.
        let legacy = try JSONDecoder().decode(UsageRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.cacheHitInputTokens == nil)
        #expect(UsageCacheHitProjection(records: [legacy]).text == "—")
        #expect(UsageCacheHitProjection(records: [original, legacy]).rate == nil)
        #expect(UsageCacheHitProjection(records: [record(read: nil, input: 10)]).rate == nil)
        #expect(UsageCacheHitProjection(records: [record(read: 13, input: 12)]).text == "—")
        let roundTrip = try JSONDecoder().decode(UsageRecord.self, from: JSONEncoder().encode(legacy))
        #expect(roundTrip == legacy)
    }

    @Test func weightedAllCachedZeroAndOverflowStayFiniteOrUnknown() {
        #expect(UsageCacheHitProjection(records: [record(read: 100, input: 100)]).text == "100.0%")
        #expect(UsageCacheHitProjection(records: [record(read: 0, input: 0)]).text == "—")
        #expect(UsageCacheHitProjection(records: []).rate == nil)
        #expect(UsageCacheHitProjection(records: [record(read: 4, input: 10), record(read: 0, input: 90)]).rate == 0.04)
        #expect(UsageCacheHitProjection(records: [record(read: 0, input: Int.max), record(read: 0, input: 1)]).rate == nil)
        #expect(UsageCacheHitProjection(records: [record(read: Int.max, input: Int.max), record(read: 1, input: 1)]).rate == nil)
    }

    @Test func integerAPIKeepsInclusiveContractWhileTypedDefaultIsUnknown() async {
        let store = UsageStore(domain: .suite("Usage418-Inclusive-\(UUID().uuidString)"))
        store.recordCall(provider: "synthetic", model: "inclusive", inputTokens: 1000, outputTokens: 100,
                         cacheReadTokens: 600, cacheCreationTokens: 300)
        let persisted = await store.waitForPersistence()
        #expect(persisted)
        #expect(store.cacheHitRate == 0.6)
        store.recordCall(provider: "synthetic", model: "unknown",
                         usage: LLMUsage(inputTokens: 5, outputTokens: 2, cacheReadInputTokens: 3))
        let secondPersisted = await store.waitForPersistence()
        #expect(secondPersisted)
        #expect(store.totalCalls == 2)
        #expect(store.totalTokens == 1107)
        #expect(store.cacheHitRateText == "—")
        let reloaded = UsageStore(domain: store.defaultsDomain)
        let loaded = await reloaded.waitForPersistence()
        #expect(loaded)
        #expect(reloaded.totalCalls == 2)
        #expect(reloaded.cacheHitRateText == "—")
    }

    @Test func incompleteLegacyHistoryIsUnknownGloballyButKnownForSelectedRecords() async throws {
        let suite = "Usage418-LegacyRecent-\(UUID().uuidString)"
        let key = "usage418.legacy"
        let recent = UsageRecord(provider: "synthetic", model: "legacy", inputTokens: 10, outputTokens: 1,
                                 cacheReadTokens: 4, cacheCreationTokens: 0, cacheHitInputTokens: 10)
        let snapshot = UsageSnapshot(totalCalls: 2, totalInputTokens: 20, totalOutputTokens: 2,
            totalCacheReadTokens: 8, totalCacheCreationTokens: 0,
            modelUsage: [UsageStore.key(provider: "synthetic", model: "legacy"):
                ModelUsageStats(provider: "synthetic", providerRecordID: nil, providerDisplaySnapshot: nil,
                    model: "legacy", callCount: 2, inputTokens: 20, outputTokens: 2,
                    cacheReadTokens: 8, cacheCreationTokens: 0)],
            recentCalls: [recent], callHistory: nil, providerHistory: nil)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode(snapshot), forKey: key)
        let store = UsageStore(domain: .suite(suite), storageKey: key)
        let loaded = await store.waitForPersistence()
        #expect(loaded)
        #expect(store.totalCalls == 2)
        #expect(store.callHistory.count == 1)
        #expect(store.cacheHitRateText == "—")
        // Unfiltered "total consumption" has the global count contract.
        #expect(UsageCacheHitProjection(records: store.callHistory, expectedCallCount: store.totalCalls).text == "—")
        let selected = store.query(models: ["legacy"])
        #expect(UsageCacheHitProjection(records: selected.records).text == "40.0%")
    }

    @Test func budgetWrapperForwardsFullUsageAcrossBufferedAndStreaming() async throws {
        let usage = OpenAICompatibleProvider.parseChatCompletionsUsage([
            "prompt_tokens": 3470, "completion_tokens": 31, "prompt_cache_hit_tokens": 3328,
        ])
        let observation = Usage418Observation()
        let wrapped = BudgetRecordingProvider(base: Usage418Provider(usage: usage),
            onRecorded: { observation.budget($0) }, onUsageRecorded: { observation.usage($0) })
        let buffered = try await wrapped.sendMessage(messages: [], systemPrompt: nil, maxTokens: 100, temperature: nil)
        #expect(buffered.usage == usage)
        let withTools = try await wrapped.sendMessage(messages: [], systemPrompt: nil, tools: [], maxTokens: 100, temperature: nil)
        #expect(withTools.usage == usage)
        var legacyUsage: LLMUsage?
        let legacyStream = try await wrapped.streamMessage(messages: [], systemPrompt: nil, maxTokens: 100, temperature: nil)
        for try await chunk in legacyStream {
            if case .usage(let value) = chunk { legacyUsage = value }
        }
        #expect(legacyUsage == usage)
        var assistantUsage: LLMUsage?
        let assistantStream = try await wrapped.streamAssistantMessage(messages: [], systemPrompt: nil, tools: [], maxTokens: 100, temperature: nil)
        for try await event in assistantStream {
            if case .completed(let response) = event { assistantUsage = response.usage }
        }
        #expect(assistantUsage == usage)
        #expect(observation.usages == [usage, usage, usage])
        #expect(observation.budgets == [3501, 3501, 3501, 3501])
    }
    // Menu sizing requires a future real-package native UI check. These headless
    // consumer tests do not claim that static source proves visual layout.
}
