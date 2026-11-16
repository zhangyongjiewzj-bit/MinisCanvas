import Testing
import Foundation
import Darwin
@testable import MinisCanvasApp

// MARK: - 波4 用量统计（UsageStore）
//
// 覆盖：
//   1. recordCall 累加总消耗（in/out/调用次数）与分模型聚合；
//   2. 分模型聚合按 provider+model 维度正确合并；
//   3. UserDefaults 持久化（重载存活）；
//   4. clear 清空；
//   5. 近期调用上限与负 token 钳制。

@Suite("波4 用量统计 UsageStore")
@MainActor
struct TESTREG613LegacyUsageStoreTests {

    /// Test-only holder keeps direct fixture mutation local while the app
    /// store receives only the Sendable suite descriptor.
    private struct TestDefaults {
        let domain: UsageDefaultsDomain
        let suiteName: String

        func data(forKey key: String) -> Data? {
            UserDefaults(suiteName: suiteName)?.data(forKey: key)
        }
        func set(_ value: Any?, forKey key: String) {
            UserDefaults(suiteName: suiteName)?.set(value, forKey: key)
        }
        func removePersistentDomain(forName name: String) {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: name)
        }
    }

    /// 创建临时 UserDefaults suite（每次唯一，避免跨测试污染）。
    private func makeStore() -> TestDefaults {
        let name = "UsageStoreTests-\(UUID().uuidString)"
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        return TestDefaults(domain: .suite(name), suiteName: name)
    }

    private func settle(_ stores: UsageStore...) async {
        for store in stores { _ = await store.waitForPersistence() }
    }

    @Test func recordAggregatesTotalsAndModelUsage() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)

        store.recordCall(provider: "OpenAI", model: "gpt-4o-mini", inputTokens: 100, outputTokens: 50)
        store.recordCall(provider: "OpenAI", model: "gpt-4o-mini", inputTokens: 200, outputTokens: 60)
        store.recordCall(provider: "Anthropic", model: "claude-3-5", inputTokens: 400, outputTokens: 100)
        await settle(store)

        #expect(store.totalCalls == 3)
        #expect(store.totalInputTokens == 700)
        #expect(store.totalOutputTokens == 210)
        #expect(store.totalTokens == 910)

        // 分模型聚合：gpt-4o-mini 两轮合并，claude 单独
        #expect(store.sortedModelUsage.count == 2)
        let gpt = store.sortedModelUsage.first { $0.model == "gpt-4o-mini" }
        #expect(gpt?.callCount == 2)
        #expect(gpt?.inputTokens == 300)
        #expect(gpt?.outputTokens == 110)
        #expect(gpt?.totalTokens == 410)
        let claude = store.sortedModelUsage.first { $0.model == "claude-3-5" }
        #expect(claude?.callCount == 1)
        #expect(claude?.totalTokens == 500)

        // 近期调用：最新在前
        #expect(store.recentCalls.count == 3)
        #expect(store.recentCalls.first?.model == "claude-3-5")
    }

    @Test func sortedModelUsageDescendsByTotalTokens() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        store.recordCall(provider: "A", model: "small", inputTokens: 10, outputTokens: 10)
        store.recordCall(provider: "A", model: "big", inputTokens: 1000, outputTokens: 1000)
        store.recordCall(provider: "A", model: "mid", inputTokens: 100, outputTokens: 100)
        await settle(store)

        let models = store.sortedModelUsage.map(\.model)
        #expect(models == ["big", "mid", "small"])
    }

    @Test func sortedModelUsageTiesAreStableByProviderAndModel() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        store.recordCall(
            provider: "Provider Z", model: "model-b", inputTokens: 10, outputTokens: 10,
            providerRecordID: "provider-z"
        )
        store.recordCall(
            provider: "Provider A", model: "model-c", inputTokens: 10, outputTokens: 10,
            providerRecordID: "provider-a"
        )
        store.recordCall(
            provider: "Provider A", model: "model-a", inputTokens: 10, outputTokens: 10,
            providerRecordID: "provider-a"
        )
        await settle(store)

        let rows = store.sortedModelUsage.map { ($0.providerRecordID, $0.model) }
        #expect(rows.map { $0.0 ?? "" } == ["provider-a", "provider-a", "provider-z"])
        #expect(rows.map { $0.1 } == ["model-a", "model-c", "model-b"])
    }

    @Test func persistsAcrossReinit() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        store.recordCall(provider: "DeepSeek", model: "deepseek-chat", inputTokens: 300, outputTokens: 40)
        await settle(store)

        // 重新从同一 suite 构造，验证持久化恢复
        let reloaded = UsageStore(domain: defaults.domain)
        await settle(reloaded)
        #expect(reloaded.totalCalls == 1)
        #expect(reloaded.totalInputTokens == 300)
        #expect(reloaded.totalOutputTokens == 40)
        #expect(reloaded.sortedModelUsage.count == 1)
        #expect(reloaded.recentCalls.count == 1)
    }

    @Test func usageQueryStateDistinguishesDurableEmptyAndReady() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        await settle(store)
        #expect(store.usageQueryState == .empty)
        #expect(store.usageQueryState.isDurable)

        store.recordCall(
            provider: "DeepSeek",
            model: "deepseek-chat",
            inputTokens: 12,
            outputTokens: 8
        )
        await settle(store)
        #expect(store.usageQueryState == .ready)
        #expect(store.usageQueryState.isDurable)

        let reloaded = UsageStore(domain: defaults.domain)
        await settle(reloaded)
        #expect(reloaded.usageQueryState == .ready)

        #expect(await reloaded.clearAndWait())
        #expect(reloaded.usageQueryState == .empty)
        #expect(reloaded.usageQueryState.isDurable)
    }

    @Test func separateStoresMergeUsageBeforePersisting() async {
        let defaults = makeStore()
        let first = UsageStore(domain: defaults.domain)
        let second = UsageStore(domain: defaults.domain)

        first.recordCall(provider: "Provider A", model: "model-a", inputTokens: 100, outputTokens: 10)
        // The second instance was created before the first write. Its next
        // mutation must refresh the shared snapshot instead of overwriting A.
        second.recordCall(provider: "Provider B", model: "model-b", inputTokens: 200, outputTokens: 20)
        await settle(first, second)

        let reloaded = UsageStore(domain: defaults.domain)
        await settle(reloaded)
        #expect(reloaded.totalCalls == 2)
        #expect(reloaded.totalInputTokens == 300)
        #expect(reloaded.totalOutputTokens == 30)
        #expect(reloaded.sortedModelUsage.map(\.model) == ["model-b", "model-a"])
    }

    @Test func barrierConcurrentStoresPreserveBothWrites() async {
        let defaults = makeStore()
        let first = UsageStore(domain: defaults.domain)
        let second = UsageStore(domain: defaults.domain)

        let firstTask = Task { @MainActor in
            first.recordCall(provider: "Provider A", model: "model-a", inputTokens: 100, outputTokens: 10)
        }
        let secondTask = Task { @MainActor in
            second.recordCall(provider: "Provider B", model: "model-b", inputTokens: 200, outputTokens: 20)
        }
        await firstTask.value
        await secondTask.value
        await settle(first, second)

        let reloaded = UsageStore(domain: defaults.domain)
        await settle(reloaded)
        #expect(reloaded.totalCalls == 2)
        #expect(reloaded.totalInputTokens == 300)
        #expect(reloaded.totalOutputTokens == 30)
    }

    @Test func partialPrimarySnapshotRecoversLastValidSnapshot() async {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.recovery.partial"
        let store = UsageStore(domain: defaults.domain, storageKey: storageKey)
        store.recordCall(provider: "OpenAI", model: "gpt-4o-mini", inputTokens: 100, outputTokens: 20)
        store.recordCall(provider: "DeepSeek", model: "deepseek-chat", inputTokens: 300, outputTokens: 40)
        await settle(store)

        let backupKey = storageKey + ".backup"
        let previousValidSnapshot = defaults.data(forKey: backupKey)
        #expect(previousValidSnapshot != nil)

        // Simulate a torn write containing only a prefix of the JSON payload.
        defaults.set(Data("{\"totalCalls\":2".utf8), forKey: storageKey)

        let recovered = UsageStore(domain: defaults.domain, storageKey: storageKey)
        await settle(recovered)
        #expect(recovered.totalCalls == 1)
        #expect(recovered.totalInputTokens == 100)
        #expect(recovered.totalOutputTokens == 20)
        #expect(recovered.sortedModelUsage.map(\.model) == ["gpt-4o-mini"])
        #expect(defaults.data(forKey: storageKey) == previousValidSnapshot)
        #expect(recovered.lastPersistenceError == nil)
    }

    @Test func corruptPrimarySnapshotRecoversLastValidSnapshot() async throws {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.recovery.corrupt"
        let store = UsageStore(domain: defaults.domain, storageKey: storageKey)
        store.recordCall(provider: "Provider A", model: "model-a", inputTokens: 10, outputTokens: 10)
        store.recordCall(provider: "Provider B", model: "model-b", inputTokens: 20, outputTokens: 20)
        await settle(store)

        let backupKey = storageKey + ".backup"
        let previousValidSnapshot = defaults.data(forKey: backupKey)
        #expect(previousValidSnapshot != nil)

        // This is valid JSON but invalid persisted state; it must not replace
        // the last good snapshot with negative usage values.
        let invalidSnapshot = UsageSnapshot(
            totalCalls: -1,
            totalInputTokens: -1,
            totalOutputTokens: 0,
            totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0,
            modelUsage: [:],
            recentCalls: [],
            callHistory: [],
            providerHistory: [:]
        )
        let invalidData = try JSONEncoder().encode(invalidSnapshot)
        defaults.set(invalidData, forKey: storageKey)

        let recovered = UsageStore(domain: defaults.domain, storageKey: storageKey)
        await settle(recovered)
        #expect(recovered.totalCalls == 1)
        #expect(recovered.totalTokens == 20)
        #expect(recovered.sortedModelUsage.map(\.model) == ["model-a"])
        #expect(defaults.data(forKey: storageKey) == previousValidSnapshot)
    }

    @Test func inconsistentPrimarySnapshotRecoversLastValidSnapshot() async throws {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.recovery.inconsistent"
        let store = UsageStore(domain: defaults.domain, storageKey: storageKey)
        store.recordCall(provider: "Provider A", model: "model-a", inputTokens: 10, outputTokens: 10)
        store.recordCall(provider: "Provider A", model: "model-a", inputTokens: 5, outputTokens: 5)
        await settle(store)

        let backupKey = storageKey + ".backup"
        let previousValidSnapshot = defaults.data(forKey: backupKey)
        #expect(previousValidSnapshot != nil)

        // The payload decodes, but its totals disagree with its history and
        // model projection. It must be rejected without an integer overflow.
        let inconsistentSnapshot = UsageSnapshot(
            totalCalls: 2,
            totalInputTokens: 999,
            totalOutputTokens: 10,
            totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0,
            modelUsage: [
                "Provider A|model-a": ModelUsageStats(
                    provider: "Provider A", providerRecordID: nil,
                    providerDisplaySnapshot: "Provider A", model: "model-a",
                    callCount: 1, inputTokens: 10, outputTokens: 10,
                    cacheReadTokens: 0, cacheCreationTokens: 0
                )
            ],
            recentCalls: [],
            callHistory: [],
            providerHistory: [:]
        )
        defaults.set(try JSONEncoder().encode(inconsistentSnapshot), forKey: storageKey)

        let recovered = UsageStore(domain: defaults.domain, storageKey: storageKey)
        await settle(recovered)
        #expect(recovered.totalCalls == 1)
        #expect(recovered.totalTokens == 20)
        #expect(defaults.data(forKey: storageKey) == previousValidSnapshot)
    }

    @Test func legacyNilAndTruncatedHistoryRemainReadable() async throws {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.recovery.legacy-history"
        let record = UsageRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            provider: "Legacy Provider", model: "legacy-model", inputTokens: 7, outputTokens: 3
        )
        let stats = ModelUsageStats(
            provider: "Legacy Provider", providerRecordID: nil,
            providerDisplaySnapshot: "Legacy Provider", model: "legacy-model",
            callCount: 1, inputTokens: 7, outputTokens: 3,
            cacheReadTokens: 0, cacheCreationTokens: 0
        )
        let base = UsageSnapshot(
            totalCalls: 1,
            totalInputTokens: 7,
            totalOutputTokens: 3,
            totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0,
            modelUsage: ["Legacy Provider|legacy-model": stats],
            recentCalls: [record],
            callHistory: nil,
            providerHistory: nil
        )
        defaults.set(try JSONEncoder().encode(base), forKey: storageKey)
        let nilHistory = UsageStore(domain: defaults.domain, storageKey: storageKey)
        await settle(nilHistory)
        #expect(nilHistory.totalTokens == 10)
        #expect(nilHistory.callHistory == [record])
        // Legacy records have no stable provider ID, so nil provider history
        // remains readable without inventing lifecycle metadata.
        #expect(nilHistory.providerHistory.isEmpty)

        let truncated = UsageSnapshot(
            totalCalls: 1,
            totalInputTokens: 7,
            totalOutputTokens: 3,
            totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0,
            modelUsage: ["Legacy Provider|legacy-model": stats],
            recentCalls: [record],
            callHistory: [],
            providerHistory: nil
        )
        defaults.set(try JSONEncoder().encode(truncated), forKey: storageKey)
        let truncatedHistory = UsageStore(domain: defaults.domain, storageKey: storageKey)
        await settle(truncatedHistory)
        #expect(truncatedHistory.totalCalls == 1)
        #expect(truncatedHistory.callHistory.isEmpty)
    }

    @Test func overflowingPersistedAggregateRecoversBackupWithoutTrap() async throws {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.recovery.overflow"
        let store = UsageStore(domain: defaults.domain, storageKey: storageKey)
        store.recordCall(provider: "Provider A", model: "model-a", inputTokens: 10, outputTokens: 1)
        store.recordCall(provider: "Provider A", model: "model-a", inputTokens: 20, outputTokens: 2)
        await settle(store)
        let backup = defaults.data(forKey: storageKey + ".backup")
        #expect(backup != nil)

        let overflowing = UsageSnapshot(
            totalCalls: 2,
            totalInputTokens: Int.max,
            totalOutputTokens: 0,
            totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0,
            modelUsage: [
                "a": ModelUsageStats(
                    provider: "A", providerRecordID: nil, providerDisplaySnapshot: "A", model: "a",
                    callCount: 1, inputTokens: Int.max, outputTokens: 0,
                    cacheReadTokens: 0, cacheCreationTokens: 0
                ),
                "b": ModelUsageStats(
                    provider: "B", providerRecordID: nil, providerDisplaySnapshot: "B", model: "b",
                    callCount: 1, inputTokens: Int.max, outputTokens: 0,
                    cacheReadTokens: 0, cacheCreationTokens: 0
                )
            ],
            recentCalls: [],
            callHistory: nil,
            providerHistory: nil
        )
        defaults.set(try JSONEncoder().encode(overflowing), forKey: storageKey)

        let recovered = UsageStore(domain: defaults.domain, storageKey: storageKey)
        await settle(recovered)
        #expect(recovered.totalCalls == 1)
        #expect(recovered.totalTokens == 11)
        #expect(defaults.data(forKey: storageKey) == backup)
    }

    @Test func overflowingCombinedSnapshotTotalsRecoverBackup() async throws {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.recovery.combined-overflow"
        let store = UsageStore(domain: defaults.domain, storageKey: storageKey)
        store.recordCall(provider: "Provider A", model: "model-a", inputTokens: 10, outputTokens: 1)
        store.recordCall(provider: "Provider A", model: "model-a", inputTokens: 20, outputTokens: 2)
        await settle(store)
        let backup = defaults.data(forKey: storageKey + ".backup")
        #expect(backup != nil)

        let overflowing = UsageSnapshot(
            totalCalls: 1,
            totalInputTokens: Int.max,
            totalOutputTokens: 1,
            totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0,
            modelUsage: [
                "overflow": ModelUsageStats(
                    provider: "Provider", providerRecordID: nil, providerDisplaySnapshot: "Provider", model: "overflow",
                    callCount: 1, inputTokens: Int.max, outputTokens: 1,
                    cacheReadTokens: 0, cacheCreationTokens: 0
                )
            ],
            recentCalls: [],
            callHistory: nil,
            providerHistory: nil
        )
        defaults.set(try JSONEncoder().encode(overflowing), forKey: storageKey)

        let recovered = UsageStore(domain: defaults.domain, storageKey: storageKey)
        await settle(recovered)
        #expect(recovered.totalCalls == 1)
        #expect(recovered.totalTokens == 11)
        #expect(defaults.data(forKey: storageKey) == backup)
    }

    @Test func selfHealingAndConcurrentWriterKeepBothUpdates() async {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.recovery.self-heal-race"
        let seed = UsageStore(domain: defaults.domain, storageKey: storageKey)
        seed.recordCall(provider: "Seed", model: "seed", inputTokens: 10, outputTokens: 1)
        seed.recordCall(provider: "Seed", model: "seed", inputTokens: 20, outputTokens: 2)
        await settle(seed)
        defaults.set(Data("{\"totalCalls\":2".utf8), forKey: storageKey)

        let recoveryTask = Task { @MainActor in
            let recovered = UsageStore(domain: defaults.domain, storageKey: storageKey)
            _ = await recovered.recordCallAndWait(
                provider: "Recovery", model: "recovery", inputTokens: 30, outputTokens: 3
            )
        }
        let writerTask = Task { @MainActor in
            let writer = UsageStore(domain: defaults.domain, storageKey: storageKey)
            _ = await writer.recordCallAndWait(
                provider: "Writer", model: "writer", inputTokens: 40, outputTokens: 4
            )
        }
        await recoveryTask.value
        await writerTask.value

        let reloaded = UsageStore(domain: defaults.domain, storageKey: storageKey)
        await settle(reloaded)
        #expect(reloaded.totalCalls == 3)
        // The backup is the last committed snapshot before the torn primary
        // (the first seed call); both post-recovery writes must survive.
        #expect(reloaded.totalInputTokens == 80)
        #expect(reloaded.totalOutputTokens == 8)
    }

    @Test func clearResetsEverything() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        store.recordCall(provider: "OpenAI", model: "gpt-4o", inputTokens: 10, outputTokens: 5)
        await settle(store)

        store.clear()
        await settle(store)

        #expect(store.totalCalls == 0)
        #expect(store.totalTokens == 0)
        #expect(store.sortedModelUsage.isEmpty)
        #expect(store.recentCalls.isEmpty)

        // 清空后重载仍为空
        let reloaded = UsageStore(domain: defaults.domain)
        await settle(reloaded)
        #expect(reloaded.totalCalls == 0)
    }

    @Test func recentCallsCappedAtMax() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        for i in 0..<(UsageStore.maxRecentCalls + 20) {
            store.recordCall(provider: "P", model: "m", inputTokens: i, outputTokens: 0)
        }
        await settle(store)
        #expect(store.recentCalls.count == UsageStore.maxRecentCalls)
        // 最新一条在最前
        #expect(store.recentCalls.first?.inputTokens == UsageStore.maxRecentCalls + 19)
        #expect(store.totalCalls == UsageStore.maxRecentCalls + 20)
    }

    @Test func negativeTokensAreClamped() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        store.recordCall(provider: "P", model: "m", inputTokens: -5, outputTokens: -3)
        await settle(store)
        #expect(store.totalInputTokens == 0)
        #expect(store.totalOutputTokens == 0)
        #expect(store.totalCalls == 1)
    }

    // MARK: - 缓存命中率与分模型缓存明细

    @Test func cacheHitRateAndPerModelCache() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)

        // 两次调用：in=300 + 700，缓存读=100 + 500
        store.recordCall(
            provider: "OpenAI", model: "gpt-4o-mini",
            inputTokens: 300, outputTokens: 30,
            cacheReadTokens: 100, cacheCreationTokens: 200
        )
        store.recordCall(
            provider: "OpenAI", model: "gpt-4o-mini",
            inputTokens: 700, outputTokens: 70,
            cacheReadTokens: 500, cacheCreationTokens: 100
        )
        await settle(store)

        #expect(store.totalCacheReadTokens == 600)
        #expect(store.totalCacheCreationTokens == 300)
        // 命中率 = 缓存读 / 总输入 = 600 / 1000
        #expect(store.cacheHitRate == 0.6)

        // 分模型缓存明细聚合
        let gpt = store.sortedModelUsage.first { $0.model == "gpt-4o-mini" }
        #expect(gpt?.cacheRead == 600)
        #expect(gpt?.totalTokens == 1100)
    }

    @Test func cacheHitRateIsZeroWhenNoInput() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        #expect(store.cacheHitRate == 0)
        #expect(store.cacheHitRate.isFinite)
        store.recordCall(provider: "P", model: "m", inputTokens: 0, outputTokens: 0, cacheReadTokens: 10)
        await settle(store)
        #expect(store.cacheHitRate == 0)
        #expect(store.cacheHitRate.isFinite)
    }

    @Test func cachePersistsAcrossReinit() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        store.recordCall(
            provider: "Anthropic", model: "claude-3-5",
            inputTokens: 1000, outputTokens: 100,
            cacheReadTokens: 400, cacheCreationTokens: 600
        )
        await settle(store)

        let reloaded = UsageStore(domain: defaults.domain)
        await settle(reloaded)
        #expect(reloaded.totalCacheReadTokens == 400)
        #expect(reloaded.totalCacheCreationTokens == 600)
        #expect(reloaded.cacheHitRate == 0.4)
        let claude = reloaded.sortedModelUsage.first { $0.model == "claude-3-5" }
        #expect(claude?.cacheRead == 400)
    }

    @Test func queryUsesStableProviderDateBucketAndModelFilters() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(86_400)

        store.recordCall(
            provider: "Old Label",
            model: "model-a",
            inputTokens: 0,
            outputTokens: 0,
            providerRecordID: "provider-1",
            providerDisplaySnapshot: "Old Label",
            timestamp: first
        )
        store.recordCall(
            provider: "New Label",
            model: "model-b",
            inputTokens: 120,
            outputTokens: 30,
            providerRecordID: "provider-1",
            providerDisplaySnapshot: "New Label",
            timestamp: second
        )
        store.recordCall(
            provider: "Other",
            model: "model-b",
            inputTokens: 900,
            outputTokens: 0,
            providerRecordID: "provider-2",
            providerDisplaySnapshot: "Other",
            timestamp: second
        )
        await settle(store)

        let filtered = store.query(
            providerRecordID: "provider-1",
            dayBucket: UsageStore.dayBucket(for: second),
            models: ["model-b"]
        )
        #expect(filtered.isKnown)
        #expect(filtered.totalCalls == 1)
        #expect(filtered.totalTokens == 150)
        #expect(filtered.providerDisplaySnapshots == ["New Label"])

        let knownZero = store.query(
            providerRecordID: "provider-1",
            dateInterval: DateInterval(start: first, duration: 1),
            models: ["model-a"]
        )
        #expect(knownZero.isKnown)
        #expect(knownZero.totalCalls == 1)
        #expect(knownZero.totalTokens == 0)

        let unknown = store.query(
            providerRecordID: "provider-1",
            dayBucket: UsageStore.dayBucket(for: first.addingTimeInterval(172_800))
        )
        #expect(!unknown.isKnown)
        #expect(unknown.totalCalls == 0)
        #expect(unknown.totalTokens == 0)
    }

    @Test func providerRenameDeleteHistoryPersistsAcrossReload() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(60)
        let third = second.addingTimeInterval(60)

        store.recordCall(
            provider: "Before Rename",
            model: "model",
            inputTokens: 10,
            outputTokens: 2,
            providerRecordID: "provider-history",
            providerDisplaySnapshot: "Before Rename",
            timestamp: first
        )
        store.renameProvider(recordID: "provider-history", displayName: "After Rename", at: second)
        store.deleteProvider(recordID: "provider-history", at: third)
        await settle(store)

        let reloaded = UsageStore(domain: defaults.domain)
        await settle(reloaded)
        let history = reloaded.providerHistory["provider-history"]
        #expect(history?.displaySnapshots == ["Before Rename", "After Rename"])
        #expect(history?.isDeleted == true)
        #expect(history?.events.map(\.kind) == [.renamed, .deleted])
        #expect(history?.events.map(\.timestamp) == [second, third])
        #expect(reloaded.query(providerRecordID: "provider-history").providerDisplaySnapshots == ["Before Rename"])
    }

    @Test func providerUsageProjectionRebindsIdentityAcrossReloadAndRecovery() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        let first = Date(timeIntervalSince1970: 1_700_100_000)

        store.recordCall(
            provider: "Legacy Provider",
            model: "model-a",
            inputTokens: 40,
            outputTokens: 10,
            cacheReadTokens: 4,
            cacheCreationTokens: 6,
            providerRecordID: "provider-projection",
            providerDisplaySnapshot: "Legacy Provider",
            timestamp: first
        )
        store.renameProvider(
            recordID: "provider-projection",
            displayName: "Current Provider",
            at: first.addingTimeInterval(60)
        )
        store.deleteProvider(
            recordID: "provider-projection",
            at: first.addingTimeInterval(120)
        )
        await settle(store)

        let reloaded = UsageStore(domain: defaults.domain)
        await settle(reloaded)
        let projection = reloaded.providerUsageProjection
        #expect(projection.count == 1)
        #expect(projection.first?.providerRecordID == "provider-projection")
        #expect(projection.first?.providerDisplayName == "Current Provider")
        #expect(projection.first?.status == .deleted)
        #expect(projection.first?.model == "model-a")
        #expect(projection.first?.callCount == 1)
        #expect(projection.first?.totalTokens == 50)
        #expect(projection.first?.cacheReadTokens == 4)
        #expect(projection.first?.cacheCreationTokens == 6)

        // A valid backup/reopen keeps the same identity projection; no
        // credential or endpoint data is involved in the recovery surface.
        let recovered = UsageStore(domain: defaults.domain)
        await settle(recovered)
        #expect(recovered.providerUsageProjection == projection)
    }

    @Test func queryNormalizesModelStateAndRejectsInvalidDateRange() async {
        let defaults = makeStore()
        let store = UsageStore(domain: defaults.domain)
        let first = Date(timeIntervalSince1970: 1_700_200_000)
        let second = first.addingTimeInterval(86_400)
        store.recordCall(
            provider: "Provider",
            model: "model-a",
            inputTokens: 3,
            outputTokens: 2,
            timestamp: first
        )
        store.recordCall(
            provider: "Provider",
            model: "model-b",
            inputTokens: 7,
            outputTokens: 1,
            timestamp: second
        )
        await settle(store)

        let filtered = store.query(
            dateInterval: DateInterval(start: first, duration: 86_400),
            models: [" model-a ", ""]
        )
        #expect(filtered.isKnown)
        #expect(filtered.modelIDs == ["model-a"])
        #expect(filtered.dayBuckets == [UsageStore.dayBucket(for: first)])
        #expect(filtered.totalTokens == 5)

        let invalid = store.query(
            startDate: second,
            endDate: first,
            models: ["model-a"]
        )
        #expect(!invalid.isKnown)
        #expect(invalid.records.isEmpty)
    }

    // MARK: - Cross-process/file-lock safety

    @Test func lockTimeoutIsBoundedAndVisibleToCaller() async {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.lock-timeout-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: UsageStore.persistenceLockDirectoryPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = UsageStore.persistenceLockPath(for: storageKey)
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            try? FileManager.default.removeItem(atPath: path)
        }
        #expect(flock(descriptor, LOCK_EX) == 0)

        let store = UsageStore(
            domain: defaults.domain, storageKey: storageKey,
            persistenceLockTimeout: UsageStore.persistenceLockTimeout
        )
        let started = ContinuousClock.now
        let result = await store.recordCallAndWait(
            provider: "Timeout", model: "timeout", inputTokens: 1, outputTokens: 1
        )
        let elapsed = started.duration(to: .now)

        #expect(!result)
        #expect(elapsed >= UsageStore.persistenceLockTimeout)
        #expect(store.lastPersistenceError == .lockAcquireTimedOut)
        #expect(store.usageQueryState == .error)
        #expect(store.usageQueryState.isDurable)
        #expect(store.persistenceFailureCount > 0)
        #expect(store.totalCalls == 0)
    }

    @Test func symlinkedLockPathIsRejectedBeforeMutation() async throws {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.lock-symlink-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: UsageStore.persistenceLockDirectoryPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = UsageStore.persistenceLockPath(for: storageKey)
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests.lock-target-\(UUID().uuidString)")
        try Data("not a lock".utf8).write(to: target)
        var existingLock = stat()
        if lstat(path, &existingLock) == 0 {
            try FileManager.default.removeItem(atPath: path)
        } else {
            let failure = errno
            if failure != ENOENT {
                throw NSError(
                    domain: "UsageStoreTests.symlink",
                    code: Int(failure),
                    userInfo: [NSLocalizedDescriptionKey: "lstat failed before symlink setup"]
                )
            }
        }
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        var linkStat = stat()
        #expect(lstat(path, &linkStat) == 0)
        #expect((linkStat.st_mode & S_IFMT) == S_IFLNK)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == target.path)

        let store = UsageStore(domain: defaults.domain, storageKey: storageKey)
        let result = await store.recordCallAndWait(
            provider: "Symlink", model: "blocked", inputTokens: 1, outputTokens: 1
        )
        #expect(!result)
        #expect(store.lastPersistenceError != nil)
        #expect(store.totalCalls == 0)
    }

    @Test func bothCorruptSnapshotsExposeTypedDiagnostic() async {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.both-corrupt-\(UUID().uuidString)"
        defaults.set(Data("{bad-primary".utf8), forKey: storageKey)
        defaults.set(Data("{bad-backup".utf8), forKey: storageKey + ".backup")

        let store = UsageStore(domain: defaults.domain, storageKey: storageKey)
        await settle(store)
        #expect(store.lastPersistenceError == .primaryAndBackupCorrupt)
        let result = await store.recordCallAndWait(
            provider: "Corrupt", model: "blocked", inputTokens: 1, outputTokens: 1
        )
        #expect(!result)
        #expect(store.lastPersistenceError == .primaryAndBackupCorrupt)
        #expect(store.totalCalls == 0)
    }

    @Test func selfHealLockSymlinkFailsClosed() async throws {
        let defaults = makeStore()
        let storageKey = "UsageStoreTests.self-heal-lock-replacement-\(UUID().uuidString)"
        let seed = UsageStore(domain: defaults.domain, storageKey: storageKey)
        _ = await seed.recordCallAndWait(
            provider: "Seed", model: "seed", inputTokens: 10, outputTokens: 1
        )
        _ = await seed.recordCallAndWait(
            provider: "Seed", model: "seed", inputTokens: 20, outputTokens: 2
        )
        let tornPrimary = Data("{\"totalCalls\":2".utf8)
        defaults.set(tornPrimary, forKey: storageKey)

        try FileManager.default.createDirectory(
            atPath: UsageStore.persistenceLockDirectoryPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockPath = UsageStore.persistenceLockPath(for: storageKey)
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests.self-heal-lock-target-\(UUID().uuidString)")
        try Data("replacement".utf8).write(to: target)
        defer {
            try? FileManager.default.removeItem(atPath: lockPath)
            try? FileManager.default.removeItem(at: target)
        }
        // Seed writes leave a regular lock file. Replace it explicitly and
        // verify the fixture is truly a symlink before exercising self-heal.
        try FileManager.default.removeItem(atPath: lockPath)
        try FileManager.default.createSymbolicLink(
            atPath: lockPath, withDestinationPath: target.path
        )
        var linkStat = stat()
        #expect(lstat(lockPath, &linkStat) == 0)
        #expect((linkStat.st_mode & S_IFMT) == S_IFLNK)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: lockPath) == target.path)

        let recovered = UsageStore(domain: defaults.domain, storageKey: storageKey)
        await settle(recovered)
        #expect(recovered.lastPersistenceError != nil)
        #expect(defaults.data(forKey: storageKey) == tornPrimary)
    }

    /// This fixture is inert during the parent test run and is selected only
    /// by the helper subprocess below.
    @Test func usageHelperProcessWriterFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MINISCANVAS_USAGE_HELPER_MODE"] == "1" else {
            print("MINISCANVAS_TEST_SKIP test=usageHelperProcessWriterFixture reason=subprocess-only-writer-fixture MINISCANVAS_USAGE_HELPER_MODE!=1")
            return
        }
        guard let suiteName = environment["MINISCANVAS_USAGE_HELPER_SUITE"],
              let storageKey = environment["MINISCANVAS_USAGE_HELPER_KEY"],
              let provider = environment["MINISCANVAS_USAGE_HELPER_PROVIDER"],
              let input = Int(environment["MINISCANVAS_USAGE_HELPER_INPUT"] ?? ""),
              let evidencePath = environment["MINISCANVAS_USAGE_HELPER_EVIDENCE"] else {
            throw NSError(
                domain: "UsageStoreTests.helper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "helper mode missing required environment"]
            )
        }
        let store = UsageStore(domain: .suite(suiteName), storageKey: storageKey)
        let didPersist = await store.recordCallAndWait(
            provider: provider, model: provider.lowercased(),
            inputTokens: input, outputTokens: input / 10
        )
        let expectsFailure = environment["MINISCANVAS_USAGE_HELPER_EXPECT_FAILURE"] == "1"
        if expectsFailure {
            #expect(!didPersist)
            #expect(store.lastPersistenceError != nil)
        } else {
            #expect(didPersist)
        }
        let evidence = "executed=1\npersisted=\(didPersist ? 1 : 0)\n"
        try Data(evidence.utf8).write(
            to: URL(fileURLWithPath: evidencePath), options: .atomic
        )
    }

    @Test func helperProcessesSpawnTogetherBeforeWaiting() async throws {
        let suiteName = "UsageStoreTests.helper-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storageKey = "UsageStoreTests.helper.self-heal"
        let seed = UsageStore(domain: .suite(suiteName), storageKey: storageKey)
        _ = await seed.recordCallAndWait(provider: "Seed", model: "seed", inputTokens: 10, outputTokens: 1)
        _ = await seed.recordCallAndWait(provider: "Seed", model: "seed", inputTokens: 20, outputTokens: 2)
        defaults.set(Data("{\"totalCalls\":2".utf8), forKey: storageKey)

        let firstEvidencePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests.helper-a-\(UUID().uuidString)").path
        let secondEvidencePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests.helper-b-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: firstEvidencePath)
            try? FileManager.default.removeItem(atPath: secondEvidencePath)
        }
        let first = try makeUsageHelper(
            suiteName: suiteName, storageKey: storageKey, provider: "ProcessA", input: 30,
            evidencePath: firstEvidencePath
        )
        let second = try makeUsageHelper(
            suiteName: suiteName, storageKey: storageKey, provider: "ProcessB", input: 40,
            evidencePath: secondEvidencePath
        )
        // Barrier: both real helper processes are running before either wait.
        try first.run()
        try second.run()
        first.waitUntilExit()
        second.waitUntilExit()
        #expect(first.terminationStatus == 0)
        #expect(second.terminationStatus == 0)
        #expect(try String(contentsOfFile: firstEvidencePath, encoding: .utf8)
            == "executed=1\npersisted=1\n")
        #expect(try String(contentsOfFile: secondEvidencePath, encoding: .utf8)
            == "executed=1\npersisted=1\n")
        let reloaded = UsageStore(domain: .suite(suiteName), storageKey: storageKey)
        await settle(reloaded)
        #expect(reloaded.totalCalls == 3)
        #expect(reloaded.totalInputTokens == 80)
        #expect(reloaded.totalOutputTokens == 8)
        #expect(reloaded.callHistory.contains {
            $0.provider == "ProcessA" && $0.inputTokens == 30
        })
        #expect(reloaded.callHistory.contains {
            $0.provider == "ProcessB" && $0.inputTokens == 40
        })
    }

    @Test func helperProcessLockFailureUsesExpectFailurePath() async throws {
        let suiteName = "UsageStoreTests.helper-failure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storageKey = "UsageStoreTests.helper.failure"
        try FileManager.default.createDirectory(
            atPath: UsageStore.persistenceLockDirectoryPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(
            UsageStore.persistenceLockPath(for: storageKey),
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        #expect(flock(descriptor, LOCK_EX) == 0)

        let evidencePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests.helper-failure-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: evidencePath) }
        let helper = try makeUsageHelper(
            suiteName: suiteName, storageKey: storageKey,
            provider: "ExpectedFailure", input: 1, expectFailure: true,
            evidencePath: evidencePath
        )
        try helper.run()
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 0)
        #expect(try String(contentsOfFile: evidencePath, encoding: .utf8)
            == "executed=1\npersisted=0\n")
    }

    private func makeUsageHelper(
        suiteName: String, storageKey: String, provider: String, input: Int,
        expectFailure: Bool = false, evidencePath: String
    ) throws -> Process {
        let process = Process()
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode.app/Contents/Developer"
        let developerURL = URL(fileURLWithPath: developerDirectory)
            .resolvingSymlinksInPath().standardizedFileURL
        let toolchainURL = developerURL
            .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain")
            .standardizedFileURL
        let testingHelperURL = toolchainURL
            .appendingPathComponent("usr/libexec/swift/pm/swiftpm-testing-helper")
            .standardizedFileURL
        let helperPath = try validatedHelperExecutable(
            testingHelperURL, toolchainRoot: toolchainURL
        )
        let fixture = "TESTREG613LegacyUsageStoreTests/usageHelperProcessWriterFixture"
        if Bundle.main.bundleURL.pathExtension == "app" {
            process.executableURL = URL(fileURLWithPath: try currentNativeUsageHelperExecutable(
                from: Bundle.main.bundleURL))
            process.arguments = ["--testing-library", "swift-testing", "--filter", fixture]
        } else {
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = [
                "--test-bundle-path", try testBundlePathForHelper(),
                "--testing-library", "swift-testing",
                "--filter", fixture
            ]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["MINISCANVAS_USAGE_HELPER_SUITE"] = suiteName
        environment["MINISCANVAS_USAGE_HELPER_KEY"] = storageKey
        environment["MINISCANVAS_USAGE_HELPER_PROVIDER"] = provider
        environment["MINISCANVAS_USAGE_HELPER_INPUT"] = String(input)
        environment["MINISCANVAS_USAGE_HELPER_EXPECT_FAILURE"] = expectFailure ? "1" : "0"
        environment["MINISCANVAS_USAGE_HELPER_EVIDENCE"] = evidencePath
        environment["MINISCANVAS_USAGE_HELPER_MODE"] = "1"
        process.environment = environment
        return process
    }

    /// Only the running formal native host may be re-executed. No scratch search.
    private func currentNativeUsageHelperExecutable(from source: URL) throws -> String {
        let root = source.standardizedFileURL
        var info = stat()
        guard root == Bundle.main.bundleURL.standardizedFileURL,
              root.pathExtension == "app",
              root.resolvingSymlinksInPath() == root,
              lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              let running = Bundle.main.executableURL?.standardizedFileURL else {
            throw helperError(code: 16, message: "native helper source is not the current real app host")
        }
        let data = try Data(contentsOf: root.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as? [String: Any]
        guard let name = plist?["CFBundleExecutable"] as? String,
              name == "MinisCanvasOriginalAppMain" else {
            throw helperError(code: 17, message: "native helper host executable identity mismatch")
        }
        let expected = root.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
            .standardizedFileURL
        guard running == expected,
              URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardizedFileURL == expected else {
            throw helperError(code: 18, message: "native helper is not the running host executable")
        }
        return try validatedBundleExecutable(expected, bundleRoot: root)
    }

    @Test func nativeUsageHelperRejectsUnboundSources() {
        // Neither an arbitrary app nor a binary/directory fallback is admissible.
        for source in [URL(fileURLWithPath: "/tmp/Other.app"),
                       URL(fileURLWithPath: "/tmp/MinisCanvasOriginalAppMain"),
                       Bundle.main.bundleURL.appendingPathComponent("Contents")] {
            #expect(throws: (any Error).self) {
                try currentNativeUsageHelperExecutable(from: source)
            }
        }
    }

    private func testBundlePathForHelper() throws -> String {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        var explicitBundleValues: [String] = []
        for index in arguments.indices where arguments[index] == "--test-bundle-path" {
            guard arguments.index(after: index) < arguments.endIndex else {
                throw helperError(code: 4, message: "--test-bundle-path has no value")
            }
            explicitBundleValues.append(arguments[arguments.index(after: index)])
        }
        if explicitBundleValues.count > 1 {
            throw helperError(code: 5, message: "ambiguous --test-bundle-path arguments")
        }

        let sourcePath: String
        if let explicitBundleValue = explicitBundleValues.first {
            sourcePath = explicitBundleValue
        } else {
            let argumentBundles = arguments.filter {
                $0.hasSuffix(".xctest") && FileManager.default.fileExists(atPath: $0)
            }
            if argumentBundles.count > 1 {
                throw helperError(code: 15, message: "ambiguous .xctest bundle arguments")
            }
            sourcePath = argumentBundles.first ?? Bundle.main.bundlePath
        }
        return try resolvedTestBundleExecutable(from: URL(fileURLWithPath: sourcePath))
    }

    private func resolvedTestBundleExecutable(from sourceURL: URL) throws -> String {
        let standardizedSource = sourceURL.standardizedFileURL
        var sourceStat = stat()
        guard lstat(standardizedSource.path, &sourceStat) == 0 else {
            throw helperError(code: 6, message: "test bundle source lstat failed")
        }
        let sourceIsBundleDirectory = standardizedSource.pathExtension == "xctest"
        if sourceIsBundleDirectory {
            guard (sourceStat.st_mode & S_IFMT) == S_IFDIR else {
                throw helperError(code: 6, message: "test bundle source is not a real directory")
            }
        } else {
            guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
                throw helperError(code: 7, message: "test binary source is not a regular file")
            }
        }
        let source = standardizedSource.resolvingSymlinksInPath().standardizedFileURL
        if sourceIsBundleDirectory {
            guard source.path == standardizedSource.path else {
                throw helperError(code: 6, message: "test bundle source resolves through a symlink")
            }
        }
        let bundleURL: URL
        let suppliedBinary: URL?
        if source.pathExtension == "xctest" {
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw helperError(code: 6, message: "test bundle directory is unavailable")
            }
            bundleURL = source
            suppliedBinary = nil
        } else {
            let macOSURL = source.deletingLastPathComponent()
            let contentsURL = macOSURL.deletingLastPathComponent()
            let candidateBundle = contentsURL.deletingLastPathComponent()
            guard macOSURL.lastPathComponent == "MacOS",
                  contentsURL.lastPathComponent == "Contents",
                  candidateBundle.pathExtension == "xctest" else {
                throw helperError(code: 7, message: "test binary is outside an .xctest bundle")
            }
            bundleURL = candidateBundle
            suppliedBinary = standardizedSource
        }

        let bundleRoot = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let bundleName = bundleRoot.deletingPathExtension().lastPathComponent
        guard !bundleName.isEmpty else {
            throw helperError(code: 8, message: "test bundle has no executable basename")
        }
        let infoURL = bundleRoot.appendingPathComponent("Contents/Info.plist")
        let executableName: String
        if FileManager.default.fileExists(atPath: infoURL.path) {
            let infoData = try Data(contentsOf: infoURL)
            let plist = try PropertyListSerialization.propertyList(
                from: infoData, options: [], format: nil
            ) as? [String: Any]
            guard let value = plist?["CFBundleExecutable"] as? String,
                  !value.isEmpty, !value.contains("/") else {
                throw helperError(code: 9, message: "CFBundleExecutable is invalid")
            }
            executableName = value
        } else {
            executableName = bundleName
        }
        let macOSRoot = bundleRoot.appendingPathComponent("Contents/MacOS")
        let expectedBinary = macOSRoot.appendingPathComponent(executableName)
            .standardizedFileURL
        if let suppliedBinary {
            guard suppliedBinary.standardizedFileURL.path == expectedBinary.path else {
                throw helperError(code: 10, message: "test binary is not the bundle executable")
            }
        }
        return try validatedBundleExecutable(expectedBinary, bundleRoot: bundleRoot)
    }

    private func validatedHelperExecutable(
        _ url: URL, toolchainRoot: URL
    ) throws -> String {
        let canonical = try validatedRegularExecutable(url, code: 11)
        let root = toolchainRoot.standardizedFileURL.path
        guard canonical.hasPrefix(root + "/") else {
            throw helperError(code: 12, message: "helper is outside the expected Xcode toolchain")
        }
        return canonical
    }

    private func validatedBundleExecutable(
        _ url: URL, bundleRoot: URL
    ) throws -> String {
        let canonical = try validatedRegularExecutable(url, code: 13)
        let expectedRoot = bundleRoot.appendingPathComponent("Contents/MacOS")
            .standardizedFileURL.path
        guard canonical.hasPrefix(expectedRoot + "/") else {
            throw helperError(code: 14, message: "test binary is outside Contents/MacOS")
        }
        return canonical
    }

    private func validatedRegularExecutable(_ url: URL, code: Int) throws -> String {
        let standardized = url.standardizedFileURL
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path == standardized.path else {
            throw helperError(code: code, message: "executable path resolves through a symlink")
        }
        var fileStat = stat()
        guard lstat(standardized.path, &fileStat) == 0 else {
            throw helperError(code: code, message: "executable lstat failed")
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: canonical.path) else {
            throw helperError(code: code, message: "executable is not a regular executable file")
        }
        return canonical.path
    }

    private func helperError(code: Int, message: String) -> NSError {
        NSError(
            domain: "UsageStoreTests.helper",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
