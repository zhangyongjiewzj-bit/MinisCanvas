import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class FrozenUsageRouteEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { true }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.usage(LLMUsage(inputTokens: 5, outputTokens: 2)))
            continuation.yield(.textDelta("synthetic reply"))
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

@Suite("用量筛选设置生产消费")
@MainActor
struct UsageSettingsFilterConsumerTests {
    private struct DefaultsFixture {
        let domain: UsageDefaultsDomain

        init() {
            let name = "UsageSettingsFilterConsumerTests-\(UUID().uuidString)"
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            domain = .suite(name)
        }
    }

    private func makeStore() -> UsageStore {
        UsageStore(domain: DefaultsFixture().domain)
    }

    @Test func settingsTabWiresTheExistingCanonicalUsageStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-parent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsFixture = DefaultsFixture()
        let usage = UsageStore(domain: defaultsFixture.domain)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root),
            memoryStore: MemoryStore(directory: root),
            sessionStore: SessionStore(directory: root),
            logManager: LogManager(directory: root, ringCapacity: 10),
            usageStore: usage
        )
        let chat = ChatStore()
        let sessionA = try #require(chat.activeSessionID).uuidString
        let originalThread = try #require(chat.sessions.first { $0.id.uuidString == sessionA })
        try center.sessionStore.updateSession(originalThread.asPersisted())
        let coldThread = try #require(SessionStore(directory: root).loadSession(id: sessionA))
        #expect(coldThread.createdAt == originalThread.createdAt)
        let secondSession = chat.applyNewSession(title: "N09 separate creation fact")
        #expect(chat.sessions.first { $0.id == secondSession }?.id.uuidString != sessionA)
        try #require(chat.applySwitchSession(id: originalThread.id))
        #expect(chat.sessions.first { $0.id == chat.activeSessionID }?.createdAt == originalThread.createdAt)
        let rendered = try #require(UsageSettingsTab(center: center, chatStore: chat).body as? UsageFilteredSettingsView)
        let sameChat = rendered.chatStore === chat
        #expect(sameChat)
        #expect(rendered.usageStore === center.usageStore)
        usage.recordCall(provider: "Provider", model: "model", inputTokens: 3, outputTokens: 4, providerRecordID: "identity", sessionID: sessionA)
        await settle(usage)
        #expect(UsageFilteredSettingsView.queryResult(from: rendered.usageStore,
            filters: UsageFilteredSettingsFilterState(providerRecordID: "identity"))?.totalTokens == 7)
        let sessionB = UUID().uuidString
        usage.recordCall(provider: "Provider", model: "model", inputTokens: 1, outputTokens: 2, sessionID: sessionB)
        usage.recordCall(provider: "Provider", model: "legacy", inputTokens: 8, outputTokens: 1)
        await settle(usage)
        #expect(UsageFilteredSettingsView.sessionRecords(from: rendered.usageStore, sessionID: sessionA).map(\.totalTokens) == [7])
        #expect(UsageFilteredSettingsView.sessionRecords(from: rendered.usageStore, sessionID: sessionB).map(\.totalTokens) == [3])
        #expect(usage.callHistory.filter { $0.sessionID == nil }.count == 1)
        #expect(UsageFilteredSettingsView.childTokenShare(records: []) == nil)
        let cold = UsageStore(domain: defaultsFixture.domain)
        await settle(cold)
        #expect(cold.callHistory == usage.callHistory)
        let legacy = try #require(usage.callHistory.last)
        var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        oldJSON.removeValue(forKey: "sessionID")
        let decoded = try JSONDecoder().decode(UsageRecord.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        #expect(decoded.sessionID == nil && decoded.totalTokens == 9)
    }

    @Test func filterResetOrDismissalInvalidatesThePendingRefresh() {
        var gate = UsageFilteredSettingsRefreshGate()
        let filters = UsageFilteredSettingsFilterState(models: ["model"])
        let request = gate.begin(for: filters)
        gate.invalidate()
        #expect(!gate.accepts(request, currentFilters: filters))
        let fresh = gate.begin(for: filters)
        #expect(gate.accepts(fresh, currentFilters: filters))
        #expect(!gate.accepts(request, currentFilters: filters))
    }

    private func settle(_ store: UsageStore) async {
        _ = await store.waitForPersistence()
    }

    @Test func combinedProviderDateAndModelFiltersUseTheCanonicalStore() async {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86_400)
        store.recordCall(provider: "Same Name", model: "model-a", inputTokens: 10, outputTokens: 2, providerRecordID: "provider-a", providerDisplaySnapshot: "Same Name", timestamp: start)
        store.recordCall(provider: "Same Name", model: "model-b", inputTokens: 99, outputTokens: 99, providerRecordID: "provider-a", providerDisplaySnapshot: "Same Name", timestamp: end)
        store.recordCall(provider: "Same Name", model: "model-a", inputTokens: 50, outputTokens: 5, providerRecordID: "provider-b", providerDisplaySnapshot: "Same Name", timestamp: start)
        await settle(store)

        let filters = UsageFilteredSettingsFilterState(
            providerRecordID: "provider-a",
            startDate: start,
            endDate: end,
            models: ["model-a"]
        )
        let result = UsageFilteredSettingsView.queryResult(from: store, filters: filters)
        #expect(result?.isKnown == true)
        #expect(result?.records.count == 1)
        #expect(result?.records.first?.providerRecordID == "provider-a")
        #expect(result?.records.first?.model == "model-a")
        #expect(result?.totalTokens == 12)
    }

    @Test func stableProviderOptionsKeepIdenticalNamesSeparateAndLeaveLegacyUnbound() async {
        let store = makeStore()
        store.recordCall(provider: "Same Name", model: "model", inputTokens: 1, outputTokens: 0, providerRecordID: "provider-a", providerDisplaySnapshot: "Same Name")
        store.recordCall(provider: "Same Name", model: "model", inputTokens: 2, outputTokens: 0, providerRecordID: "provider-b", providerDisplaySnapshot: "Same Name")
        store.recordCall(provider: "Same Name", model: "model", inputTokens: 3, outputTokens: 0)
        await settle(store)

        let options = UsageFilteredSettingsView.providerOptions(from: store.providerUsageProjection)
        #expect(options.map(\.recordID) == ["provider-a", "provider-b"])
        #expect(options.map(\.displayName) == ["Same Name", "Same Name"])

        let all = store.query()
        #expect(all.records.count == 3)
        #expect(all.records.contains(where: { $0.providerRecordID == nil }))
        let selected = UsageFilteredSettingsView.queryResult(
            from: store,
            filters: UsageFilteredSettingsFilterState(providerRecordID: "provider-b")
        )
        #expect(selected?.records.count == 1)
        #expect(selected?.records.first?.providerRecordID == "provider-b")
    }

    @Test func renameAndDeleteProjectionKeepsHistoryWhileFilterUsesStableID() async {
        let store = makeStore()
        let timestamp = Date(timeIntervalSince1970: 1_700_100_000)
        store.recordCall(provider: "Before Rename", model: "model", inputTokens: 4, outputTokens: 1, providerRecordID: "provider-history", providerDisplaySnapshot: "Before Rename", timestamp: timestamp)
        store.renameProvider(recordID: "provider-history", displayName: "After Rename", at: timestamp.addingTimeInterval(1))
        store.deleteProvider(recordID: "provider-history", at: timestamp.addingTimeInterval(2))
        await settle(store)

        let projection = store.providerUsageProjection.first
        #expect(projection?.providerRecordID == "provider-history")
        #expect(projection?.providerDisplayName == "After Rename")
        #expect(projection?.status == .deleted)
        #expect(store.query(providerRecordID: "provider-history").records.first?.providerDisplaySnapshot == "Before Rename")

        let option = UsageFilteredSettingsView.providerOptions(from: store.providerUsageProjection).first
        #expect(option?.label == "After Rename（已删除）")
    }

    @Test func servedFallbackOwnsUsageInsteadOfTheSelectedPrimary() async throws {
        let store = makeStore()
        let primary = EnvVarEntry(id: "primary-id", name: "PRIMARY", value: "",
                                  baseURL: "https://primary.example.test/v1", modelNames: ["primary-model"])
        let fallback = EnvVarEntry(id: "fallback-id", name: "FALLBACK", value: "",
                                   baseURL: "https://fallback.example.test/v1", modelNames: ["fallback-model"])
        let route = try ProviderRuntimeSnapshot(
            providerID: "PRIMARY", modelID: "primary-model",
            readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
            applyReceiptID: "provider-readiness-apply:usage-primary",
            fallbackProvenance: [ProviderRuntimeFallback(
                providerID: "FALLBACK", modelID: "fallback-model",
                readinessEvidenceID: "live-settings:" + String(repeating: "b", count: 64),
                applyReceiptID: "provider-readiness-apply:usage-fallback")]
        )
        let observation = ProviderRuntimeRouteObservation(
            routeReceiptID: route.routeReceiptID, servedProviderID: "FALLBACK",
            servedModelID: "fallback-model")
        let attribution = ChatStore.usageProviderAttribution(
            primaryProvider: "PRIMARY", primaryModel: "primary-model",
            route: route, observation: observation,
            candidates: [.custom(primary), .custom(fallback)],
            trustedDirectSelection: .custom(primary))
        store.recordCall(provider: attribution.provider, model: attribution.model,
                         inputTokens: 7, outputTokens: 3,
                         providerRecordID: attribution.recordID,
                         providerDisplaySnapshot: attribution.displaySnapshot)
        await settle(store)
        #expect(store.query(providerRecordID: "fallback-id").totalTokens == 10)
        #expect(store.query(providerRecordID: "primary-id").records.isEmpty)
        #expect(store.query(providerRecordID: "fallback-id").records.first?.model == "fallback-model")

        let unobserved = ChatStore.usageProviderAttribution(
            primaryProvider: "PRIMARY", primaryModel: "primary-model",
            route: route, observation: nil,
            candidates: [.custom(primary), .custom(fallback)],
            trustedDirectSelection: .custom(primary))
        #expect(unobserved.recordID == nil)
        #expect(unobserved.provider == "未确认路由")
        let mismatchedObservation = ProviderRuntimeRouteObservation(
            routeReceiptID: route.routeReceiptID, servedProviderID: "FALLBACK",
            servedModelID: "primary-model")
        let mismatched = ChatStore.usageProviderAttribution(
            primaryProvider: "PRIMARY", primaryModel: "primary-model",
            route: route, observation: mismatchedObservation,
            candidates: [.custom(primary), .custom(fallback)],
            trustedDirectSelection: .custom(primary))
        #expect(mismatched.recordID == nil)
    }

    @Test func directSelectionUsesFrozenIdentityAndUnknownOverrideStaysUnbound() {
        let selected = EnvVarEntry(id: "selected-stable-id", name: "CUSTOM", value: "",
                                   baseURL: "https://example.test/v1", modelNames: ["model"])
        let trusted = ChatStore.usageProviderAttribution(
            primaryProvider: "CUSTOM", primaryModel: "model", route: nil,
            observation: nil, candidates: [.custom(selected)],
            trustedDirectSelection: .custom(selected))
        #expect(trusted.recordID == "selected-stable-id")
        let override = ChatStore.usageProviderAttribution(
            primaryProvider: "CUSTOM", primaryModel: "model", route: nil,
            observation: nil, candidates: [.custom(selected)],
            trustedDirectSelection: nil)
        #expect(override.recordID == nil)
        let mismatched = ChatStore.usageProviderAttribution(
            primaryProvider: "DIFFERENT", primaryModel: "model", route: nil,
            observation: nil, candidates: [.custom(selected)],
            trustedDirectSelection: .custom(selected))
        #expect(mismatched.recordID == nil)
        let builtIn = ChatStore.usageProviderAttribution(
            primaryProvider: ProviderType.openAI.runtimeProviderID, primaryModel: "builtin-model",
            route: nil, observation: nil, candidates: [.builtIn(.openAI)],
            trustedDirectSelection: .builtIn(.openAI))
        #expect(builtIn.recordID == "builtin.openAI")
    }

    @Test func ordinarySendAfterAutoCompactionPreflightRecordsFrozenProviderID() async throws {
        let suite = "usage-frozen-send-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let usage = UsageStore(domain: .suite(suite))
        let chat = ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root, ringCapacity: 10)
        )
        defer { chat.stopAllStreamingForSafety() }
        chat.usageStore = usage
        chat.agentEngine = FrozenUsageRouteEngine()
        let provider = EnvVarEntry(
            id: "frozen-provider-id", name: "SYNTHETIC_PROVIDER", value: "synthetic-only",
            isSecret: true,
            baseURL: "https://example.test/v1", modelNames: ["synthetic-model"]
        )
        chat.selectedCustomProvider = provider
        chat.selectedModelID = "synthetic-model"
        var agent = AgentSettings.default
        agent.autoCompactThreshold = 0.5
        // recordTokens(60_000) 需要越过 50% 阈值：显式钉 10 万（默认值已改为 100 万）。
        agent.maxTokensPerSession = 100_000
        chat.configureBudget(from: agent)
        // The UI budget mirror opens the real frozen-provider preflight. Its
        // authoritative tracker is still below threshold, so no checkpoint is needed.
        chat.recordTokens(60_000)
        chat.draftText = "synthetic ordinary turn"
        chat.submitComposer()

        for _ in 0..<300 where usage.query(providerRecordID: provider.id).totalCalls == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await usage.waitForPersistence())
        #expect(usage.query(providerRecordID: provider.id).totalCalls == 1)
        #expect(usage.query(providerRecordID: provider.id).totalTokens == 7)
        #expect(usage.query().records.count == 1)
        #expect(usage.query().records.first?.providerRecordID == provider.id)
    }

    @Test func confirmedSettingsLifecycleKeepsOldUsageSelectableWithoutGuessingNewUUID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = makeStore()
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root,
                keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            memoryStore: MemoryStore(directory: root),
            sessionStore: SessionStore(directory: root),
            logManager: LogManager(directory: root, ringCapacity: 10),
            usageStore: usage
        )
        #expect(center.saveProvider(name: "BEFORE", apiKey: "synthetic-only",
            baseURL: "https://example.test/v1", modelNames: ["model"],
            protocolType: .openaiCompatible))
        let oldID = try #require(center.providerRecords.first?.id)
        usage.recordCall(provider: "BEFORE", model: "model", inputTokens: 4,
                         outputTokens: 1, providerRecordID: oldID)
        await settle(usage)

        let unconfirmed = try center.previewProviderDeletion(name: "BEFORE")
        #expect(throws: DeletionGateError.firstConfirmationRequired) {
            try center.deleteProvider(name: "BEFORE", intent: unconfirmed)
        }
        await settle(usage)
        #expect(usage.providerUsageProjection.first?.status == .active)

        let rename = try center.previewProviderRename(from: "BEFORE", to: "AFTER")
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try center.renameProvider(from: "BEFORE", to: "AFTER", intent: rename)
        await settle(usage)
        let newID = try #require(center.providerRecords.first?.id)
        #expect(newID != oldID)
        #expect(UsageFilteredSettingsView.providerOptions(
            from: usage.providerUsageProjection).first?.recordID == oldID)
        #expect(usage.providerUsageProjection.first?.providerDisplayName == "AFTER")
        #expect(usage.providerUsageProjection.first?.status == .deleted)
        usage.recordCall(provider: "AFTER", model: "model", inputTokens: 2,
                         outputTokens: 1, providerRecordID: newID)
        await settle(usage)
        #expect(usage.query(providerRecordID: oldID).totalTokens == 5)
        #expect(usage.query(providerRecordID: newID).totalTokens == 3)

        let deletion = try center.previewProviderDeletion(name: "AFTER")
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try center.deleteProvider(name: "AFTER", intent: deletion)
        await settle(usage)
        #expect(usage.providerUsageProjection.first(where: { $0.providerRecordID == newID })?.status == .deleted)
        #expect(usage.query(providerRecordID: oldID).records.count == 1)
    }

    @Test func DateBoundaryZeroAndNoMatchRemainDistinct() async {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_700_200_000)
        let end = start.addingTimeInterval(86_400)
        store.recordCall(provider: "Provider", model: "zero", inputTokens: 0, outputTokens: 0, timestamp: start)
        store.recordCall(provider: "Provider", model: "outside", inputTokens: 10, outputTokens: 1, timestamp: end)
        await settle(store)

        let zero = UsageFilteredSettingsView.queryResult(
            from: store,
            filters: UsageFilteredSettingsFilterState(startDate: start, endDate: end, models: ["zero"])
        )
        #expect(zero?.isKnown == true)
        #expect(zero?.totalCalls == 1)
        #expect(zero?.totalTokens == 0)

        let noMatch = UsageFilteredSettingsView.queryResult(
            from: store,
            filters: UsageFilteredSettingsFilterState(startDate: start, endDate: end, models: ["missing"])
        )
        #expect(noMatch?.isKnown == false)
        #expect(noMatch?.records.isEmpty == true)

        let inverted = UsageFilteredSettingsView.queryResult(
            from: store,
            filters: UsageFilteredSettingsFilterState(startDate: end, endDate: start)
        )
        #expect(inverted == nil)
    }

    @Test func RefreshSeesNewRecordsAndRejectsLateOlderSelection() async {
        let store = makeStore()
        store.recordCall(provider: "Provider", model: "first", inputTokens: 1, outputTokens: 1)
        await settle(store)
        let initial = UsageFilteredSettingsView.queryResult(
            from: store,
            filters: UsageFilteredSettingsFilterState(models: ["first"])
        )
        #expect(initial?.totalCalls == 1)

        store.recordCall(provider: "Provider", model: "second", inputTokens: 2, outputTokens: 2)
        await settle(store)
        let refreshed = UsageFilteredSettingsView.queryResult(
            from: store,
            filters: UsageFilteredSettingsFilterState(models: ["second"])
        )
        #expect(refreshed?.totalCalls == 1)
        #expect(refreshed?.totalTokens == 4)

        var gate = UsageFilteredSettingsRefreshGate()
        let oldFilters = UsageFilteredSettingsFilterState(models: ["first"])
        let newFilters = UsageFilteredSettingsFilterState(models: ["second"])
        let oldRequest = gate.begin(for: oldFilters)
        let newRequest = gate.begin(for: newFilters)
        #expect(!gate.accepts(oldRequest, currentFilters: newFilters))
        #expect(gate.accepts(newRequest, currentFilters: newFilters))
    }
}
