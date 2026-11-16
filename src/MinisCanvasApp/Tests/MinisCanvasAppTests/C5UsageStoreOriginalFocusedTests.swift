import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp
@Suite(.serialized)
@MainActor
struct UsageStoreTests {
    @Test func localDateFilterIncludesLocalMidnightAndExcludesNextMidnight() async throws {
        let timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = Date(timeIntervalSince1970: 1_729_440_000) // 2024-10-21 00:00 +08
        let fixture = try C5OriginalOwnedFixture()
        defer { fixture.cleanup() }
        let store = UsageStore(domain: fixture.domain)
        store.recordCall(provider: "Provider", model: "before", inputTokens: 1, outputTokens: 0, timestamp: start.addingTimeInterval(-1))
        store.recordCall(provider: "Provider", model: "inside", inputTokens: 2, outputTokens: 0, timestamp: start)
        store.recordCall(provider: "Provider", model: "after", inputTokens: 4, outputTokens: 0, timestamp: start.addingTimeInterval(86_400))
        await settle(store)
        let filters = UsageFilteredSettingsFilterState(startDate: start, endDate: start.addingTimeInterval(86_400), timeZone: timeZone)
        let result = UsageFilteredSettingsView.queryResult(from: store, filters: filters)
        #expect(result?.records.map(\.model) == ["inside"])
        #expect(UsageStore.dayBucket(for: start, timeZone: timeZone) == "2024-10-21")
        #expect(UsageStore.dayBucket(for: start.addingTimeInterval(-1), timeZone: timeZone) == "2024-10-20")
    }

    @Test func localDateRangeHonorsDaylightSavingDayLength() throws {
        let timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let start = Date(timeIntervalSince1970: 1_710_057_600) // 2024-03-10 00:00 -08
        let end = start.addingTimeInterval(23 * 3600)
        let filters = UsageFilteredSettingsFilterState(startDate: start, endDate: end, timeZone: timeZone)
        #expect(filters.normalizedDateInterval?.duration == TimeInterval(23 * 3600))
        #expect(UsageStore.dayBucket(for: end, timeZone: timeZone) == "2024-03-11")
    }

    @Test func configuredPricesEstimateFourTokenClassesWithoutInventingMissingRates() throws {
        let record = UsageRecord(provider: "Provider", model: "model", inputTokens: 10, outputTokens: 5,
            cacheReadTokens: 70, cacheCreationTokens: 20, cacheHitInputTokens: 100)
        let price = UsageModelPricing(currency: "USD", inputPerMillion: 2, outputPerMillion: 8,
            cacheReadPerMillion: 0.5, cacheWritePerMillion: 3)
        let amount = try #require(price.estimate(record))
        #expect(abs(amount - 0.000155) < 0.000000000001)
        #expect(UsageModelPricing.display(records: [record], prices: [:]) == "1 次无法估算（未配置单价、路由未确认或用量字段不足）")
        let cnyRecord = UsageRecord(provider: "Other", model: "model", inputTokens: 10, outputTokens: 5,
            cacheReadTokens: 70, cacheCreationTokens: 20, cacheHitInputTokens: 100)
        let unknown = UsageRecord(provider: "未确认路由", model: "未确认模型", inputTokens: 10, outputTokens: 5,
            cacheReadTokens: 70, cacheCreationTokens: 20, cacheHitInputTokens: 100)
        let cny = UsageModelPricing(currency: "CNY", inputPerMillion: 2, outputPerMillion: 8,
            cacheReadPerMillion: 0.5, cacheWritePerMillion: 3)
        let prices = [UsageStore.key(provider: "Provider", model: "model"): price,
            UsageStore.key(provider: "Other", model: "model"): cny,
            UsageStore.key(provider: "未确认路由", model: "未确认模型"): price]
        #expect(UsageModelPricing.display(records: [record, cnyRecord, unknown], prices: prices)
            == "CNY 0.000155 · USD 0.000155 · 1 次无法估算（未配置单价、路由未确认或用量字段不足）")
        #expect(!UsageModelPricing.canPrice(provider: unknown.provider, model: unknown.model))
        #expect(!UsageModelPricing(currency: "USD", inputPerMillion: -.infinity, outputPerMillion: 8,
            cacheReadPerMillion: 0, cacheWritePerMillion: 0).isValid)
    }

    @Test func realChildUsageAndBoundedMCPRecordsPersistWithConfiguredPrices() async throws {
        let fixture = try C5OriginalOwnedFixture()
        defer { fixture.cleanup() }
        let store = UsageStore(domain: fixture.domain)
        _ = try await recordRealChild(provider: C5UsageProvider(), store: store)
        let key = UsageStore.key(provider: "Provider", model: "model")
        let price = UsageModelPricing(currency: "CNY", inputPerMillion: 1, outputPerMillion: 2,
            cacheReadPerMillion: 0, cacheWritePerMillion: 0)
        store.setModelPricing(price, for: key)
        await settle(store)
        #expect(store.totalCalls == 1)
        #expect(store.callHistory.first?.attribution?.kind == .subagent)
        #expect(store.callHistory.first?.attribution?.label == "子智能体 · 身份未验证")
        #expect(store.callHistory.first?.provider == "UsageProbe")
        #expect(store.callHistory.first?.model == "usage-probe")
        let mcpConsumer = MCP03ActualStdioProvider3098Tests()
        let mcp = try mcpConsumer.fixture("usage-n09")
        defer { mcp.registry.disconnectAll() }
        try #require(try await mcpConsumer.discover(mcp))
        let output = try await UsageTelemetryContext.$observer.withValue({ observation in
            await MainActor.run { store.recordTelemetry(observation) }
        }) {
            try await mcp.registry.callMCPTool(fullName: mcp.fullName,
                arguments: ["value": "owned usage greet"])
        }
        #expect(output.contains("owned stdio result"))
        let wire = try mcpConsumer.wire(mcp)
        #expect(wire.filter { $0["method"] as? String == "tools/call" }.count == 1)
        await settle(store)
        #expect(store.mcpCalls.count == 1)
        let actualMCP = try #require(store.mcpCalls.first)
        #expect(actualMCP.serverID == mcp.server.id && actualMCP.fullName == mcp.fullName && actualMCP.succeeded)
        let realMCPReloaded = UsageStore(domain: fixture.domain)
        await settle(realMCPReloaded)
        #expect(realMCPReloaded.mcpCalls == [actualMCP])
        #expect(UsageFilteredSettingsView.mcpServerShare(serverID: mcp.server.id, records: realMCPReloaded.mcpCalls) == 1)
        #expect(UsageFilteredSettingsView.mcpServerShare(serverID: mcp.server.id, records: []) == nil)
        // The original synthetic ring below tests retention only. It naturally
        // evicts this actual stdio record; it does not stand for 51 MCP calls.
        for index in 0...UsageStore.maxRecentCalls {
            store.recordMCPCall(UsageMCPCallRecord(timestamp: Date(timeIntervalSince1970: Double(index)),
                serverID: "server-a", fullName: "tool-\(index)", succeeded: true))
        }
        await settle(store)
        #expect(store.mcpCalls.count == UsageStore.maxRecentCalls)
        #expect(store.mcpCalls.first?.fullName == "tool-1")
        #expect(store.mcpCalls.last?.fullName == "tool-\(UsageStore.maxRecentCalls)")
        let reloaded = UsageStore(domain: fixture.domain)
        await settle(reloaded)
        #expect(reloaded.callHistory == store.callHistory)
        #expect(reloaded.mcpCalls == store.mcpCalls)
        #expect(reloaded.modelPricing[key] == price)
        store.clear()
        await settle(store)
        #expect(store.mcpCalls.isEmpty && store.callHistory.isEmpty)
        #expect(store.modelPricing[key] == price)
    }

    @Test func factoryAnthropicPreservesTheRuntimeIdentityOfItsDirectTransport() throws {
        let config = ProviderConfig(label: "synthetic", providerType: .anthropic,
            runtimeProviderID: "synthetic-anthropic", apiKey: "synthetic-not-a-secret")
        let provider = try ProviderFactory().makeProvider(for: config)
        let route = try #require(UsageTelemetryContext.directRoute(of: provider))
        #expect(route.provider == "synthetic-anthropic")
        #expect(route.model == provider.model.id)
    }

    @Test(arguments: C5DirectTransport.allCases)
    private func knownDirectTransportsExposeTheirExecutedBinding(_ transport: C5DirectTransport) throws {
        let provider: any LLMProvider
        switch transport {
        case .anthropic: provider = AnthropicProvider(apiKey: "synthetic-not-a-secret")
        case .compatible: provider = OpenAICompatibleProvider(apiKey: "synthetic-not-a-secret")
        case .responses: provider = OpenAIResponsesProvider(apiKey: "synthetic-not-a-secret")
        case .deepSeek: provider = DeepSeekProvider(apiKey: "synthetic-not-a-secret")
        case .dashScope: provider = DashScopeProvider(apiKey: "synthetic-not-a-secret")
        case .local:
            provider = LocalOpenAIProvider(model: .gpt4oMini,
                baseURL: try #require(URL(string: "http://127.0.0.1:11434")))
        }
        let route = try #require(UsageTelemetryContext.directRoute(of: provider))
        #expect(route.provider == provider.name)
        #expect(route.model == provider.model.id)
    }

    @Test func childFallbackUsageRecordsTheActualServedBackup() async throws {
        let fixture = try C5OriginalOwnedFixture()
        defer { fixture.cleanup() }
        let store = UsageStore(domain: fixture.domain)
        let route = try makeUsageFallbackRoute()
        _ = try await recordRealChild(provider: route, store: store)
        await settle(store)
        #expect(store.totalCalls == 1)
        #expect(store.callHistory.first?.provider == "backup")
        #expect(store.callHistory.first?.model == "backup-model")
        #expect(store.callHistory.first?.attribution?.kind == .subagent)
    }

    @Test func childFallbackWithoutServedObservationStaysUnknown() async throws {
        let fixture = try C5OriginalOwnedFixture()
        defer { fixture.cleanup() }
        let store = UsageStore(domain: fixture.domain)
        let opaque = C5UnobservedFallbackProvider(base: try makeUsageFallbackRoute())
        _ = try await recordRealChild(provider: opaque, store: store)
        await settle(store)
        #expect(store.totalCalls == 1)
        #expect(store.callHistory.first?.provider == "子智能体")
        #expect(store.callHistory.first?.model == "服务路由未确认")
        #expect(store.callHistory.first?.attribution?.kind == .subagent)
    }

    private func makeUsageFallbackRoute() throws -> ProviderRuntimeRoute {
        let snapshot = try ProviderRuntimeSnapshot(providerID: "primary", modelID: "primary-model",
            readinessEvidenceID: "mock-primary", applyReceiptID: "provider-readiness-apply:primary",
            fallbackProvenance: [ProviderRuntimeFallback(providerID: "backup", modelID: "backup-model",
                readinessEvidenceID: "mock-backup", applyReceiptID: "provider-readiness-apply:backup")])
        return try ProviderRuntimeRoute(snapshot: snapshot,
            primary: C5UsageProvider(name: "primary", modelID: "primary-model", rejects: true),
            fallbacks: [C5UsageProvider(name: "backup", modelID: "backup-model")])
    }

    private func recordRealChild(provider: any LLMProvider, store: UsageStore) async throws -> RequestBudget {
        let budget = BudgetTracker(RequestBudget(maxRequestsPerSession: AgentOrchestrator.hardMaxChildBudgetRequests,
            maxTokensPerSession: 100, overBudgetPolicy: .pause))
        let recorded = C5UsageTokenBox()
        let wrapped = BudgetRecordingProvider(base: provider, onRecorded: { recorded.add($0) })
        let orchestrator = AgentOrchestrator(makeChildBudget: { budget })
            .withBuiltinExecution(provider: wrapped, toolExecutor: C5UsageNoopExecutor())
        let reports = await UsageTelemetryContext.$observer.withValue({ observation in
            await MainActor.run { store.recordTelemetry(observation) }
        }) {
            await orchestrator.orchestrate(tasks: [SubAgentTask(id: "child-a", title: "usage child", instructions: "synthetic")],
                strategy: .sequential)
        }
        #expect(reports.count == 1 && reports.first?.result.isSuccess == true)
        #expect(recorded.total == 15)
        let settledBudget = await budget.budget
        #expect(settledBudget.usedRequests == 1 && settledBudget.usedTokens == 15)
        return settledBudget
    }

    private func settle(_ stores: UsageStore...) async { for store in stores { _ = await store.waitForPersistence() } }
    @Test
    func clearResetsEverything() async throws {
        let c5 = try C5OriginalOwnedFixture()
        defer { c5.cleanup() }
        let defaults = c5
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

    @Test
    func persistsAcrossReinit() async throws {
        let c5 = try C5OriginalOwnedFixture()
        defer { c5.cleanup() }
        let defaults = c5
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
}

private struct C5UsageNoopExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String { "unused" }
}

private final class C5UsageTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add(_ tokens: Int) { lock.lock(); defer { lock.unlock() }; value += tokens }
    var total: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private struct C5UsageProvider: UsageRouteIdentityProviding, LLMProvider {
    let name: String
    var model: LLMModel
    let rejects: Bool
    init(name: String = "UsageProbe", modelID: String = "usage-probe", rejects: Bool = false) {
        self.name = name
        self.model = LLMModel(id: modelID, displayName: modelID, provider: name)
        self.rejects = rejects
    }
    var usageRouteIdentity: UsageServedRoute? { UsageServedRoute(provider: name, model: model.id) }
    var capabilities: Set<ProviderCapability> { [.tools] }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        if rejects { throw LLMError.invalidAPIKey() }
        return LLMResponse(text: "ok", stopReason: "end_turn", usage: LLMUsage(inputTokens: 10, outputTokens: 5))
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Simulates a wrapper that does not deliver served telemetry. Its configured
/// primary name is deliberately not a confirmed route identity.
private struct C5UnobservedFallbackProvider: LLMProvider {
    var base: ProviderRuntimeRoute
    var name: String { base.name }
    var model: LLMModel { get { base.model } set { base.model = newValue } }
    var capabilities: Set<ProviderCapability> { base.capabilities }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await UsageTelemetryContext.$servedRouteCapture.withValue(nil) {
            try await base.sendMessage(messages: messages, systemPrompt: systemPrompt,
                maxTokens: maxTokens, temperature: temperature)
        }
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await UsageTelemetryContext.$servedRouteCapture.withValue(nil) {
            try await base.sendMessage(messages: messages, systemPrompt: systemPrompt, tools: tools,
                maxTokens: maxTokens, temperature: temperature)
        }
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private enum C5DirectTransport: CaseIterable, Sendable {
    case anthropic, compatible, responses, deepSeek, dashScope, local
}
