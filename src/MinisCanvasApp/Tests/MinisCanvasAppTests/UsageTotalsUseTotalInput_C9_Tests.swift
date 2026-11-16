import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

/// C9（L4b）：用量页按总输入口径（未缓存 + 缓存读 + 缓存写），缓存另列；无明细的旧记录保持旧含义。
/// 依赖 C-L1 的 `LLMUsage.totalInputTokens`；子任务汇总的 `totalInputTokens` 字段依赖 C-L2 的 `ChildResultTokenUsage`。
@Suite("C9 用量页总输入口径")
@MainActor
struct UsageTotalsUseTotalInput_C9_Tests {
    private func record(input: Int, output: Int, read: Int?, write: Int?, allInput: Int?) -> UsageRecord {
        UsageRecord(provider: "synthetic", model: "m", inputTokens: input, outputTokens: output,
                    cacheReadTokens: read, cacheCreationTokens: write, cacheHitInputTokens: allInput)
    }

    @Test func recordTotalInputIsAllInputWhenProducerEstablishedIt() {
        // Anthropic 形态：新鲜 6 + 缓存读 3 + 缓存写 1 = 10
        let anthropic = record(input: 6, output: 2, read: 3, write: 1, allInput: 10)
        #expect(anthropic.totalInputTokens == 10)
        #expect(anthropic.totalTokensIncludingCache == 12)
        // 旧口径字段保持不变
        #expect(anthropic.inputTokens == 6 && anthropic.totalTokens == 8)
    }

    @Test func legacyRecordWithoutDenominatorKeepsOldMeaning() {
        let legacy = record(input: 7, output: 3, read: nil, write: nil, allInput: nil)
        #expect(legacy.totalInputTokens == 7)
        #expect(legacy.totalTokensIncludingCache == 10)
    }

    @Test func queryResultTotalsSumTotalInputAndKeepCacheSeparate() {
        let records = [
            record(input: 2_000, output: 100, read: 80_000, write: 0, allInput: 82_000),
            record(input: 5, output: 1, read: nil, write: nil, allInput: nil),
        ]
        let result = UsageQueryResult(availability: .known, records: records)
        #expect(result.totalInputTokens == 82_005)
        #expect(result.totalTokens == 82_106)
        #expect(records.reduce(0) { $0 + ($1.cacheReadTokens ?? 0) } == 80_000)
    }
}
