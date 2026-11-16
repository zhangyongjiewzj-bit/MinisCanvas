import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - E8 会话 token 用量状态行（RequestBudget 接线）

@Suite("E8 token 用量状态行")
@MainActor
struct BudgetStatusTests {
    /// 这些用例测的是占比/警告/超限，不是默认值：显式钉 10 万上限（用户 11/9 把默认值改为 100 万）。
    private func chatWith100kCap() -> ChatStore {
        let chat = ChatStore()
        var agent = AgentSettings.default
        agent.maxTokensPerSession = 100_000
        chat.configureBudget(from: agent)
        return chat
    }

    @Test func defaultBudgetCapIs1M() {
        let chat = ChatStore()
        #expect(chat.budgetCapTokens == 1_000_000)
        #expect(chat.budgetUsageFraction == 0)
        #expect(chat.budgetRequestCount == 0)
        #expect(!chat.budgetIsWarning)
        #expect(!chat.budgetIsOverLimit)
    }

    @Test func recordTokensAccumulatesUsageAndRequests() {
        let chat = chatWith100kCap()
        chat.recordTokens(1_200)
        chat.recordTokens(800)
        #expect(chat.budgetUsedTokens == 2_000)
        #expect(chat.budgetRequestCount == 2)
        #expect(abs(chat.budgetUsageFraction - 0.02) < 0.0001)
    }

    @Test func newSessionAndSwitchResetBudget() async throws {
        let chat = ChatStore()
        let firstID = try #require(chat.activeSessionID)
        let firstTracker = chat.budgetTracker
        let firstLease = try await firstTracker.beginRequest()
        _ = await firstTracker.completeRequest(firstLease, usage: LLMUsage(inputTokens: 5_000, outputTokens: 0))
        await chat.syncBudgetStatus(for: firstID)
        #expect(chat.budgetUsedTokens == 5_000)
        chat.newSession()
        #expect(chat.budgetUsedTokens == 0)
        #expect(chat.budgetRequestCount == 0)
        let secondLease = try await chat.budgetTracker.beginRequest()
        _ = await chat.budgetTracker.completeRequest(secondLease, usage: LLMUsage(inputTokens: 3_000, outputTokens: 0))
        chat.switchSession(id: firstID)
        await chat.syncBudgetStatus(for: firstID)
        // P03 cumulative quota survives returning to the same SID; a new SID is still fresh.
        #expect(chat.budgetTracker === firstTracker)
        #expect(chat.budgetUsedTokens == 5_000)
        #expect(chat.budgetRequestCount == 1)
    }

    @Test func overLimitShowsRedState() {
        let chat = chatWith100kCap()
        chat.recordTokens(100_000)
        #expect(chat.budgetIsOverLimit)
        #expect(chat.budgetUsageFraction == 1.0)
        #expect(!chat.budgetIsWarning) // 已超限不再归为「接近上限」
    }

    @Test func configureBudgetFromAgentSettingsReusesAutoCompactThreshold() {
        let chat = ChatStore()
        var agent = AgentSettings.default
        agent.autoCompactThreshold = 0.5
        agent.maxTokensPerSession = 100_000
        chat.configureBudget(from: agent)

        // 上限：agent.maxTokensPerSession（此处显式钉 100k，默认值已改为 1M）
        #expect(chat.budgetCapTokens == 100_000)
        // 警告阈值：复用 agent.autoCompactThreshold
        #expect(chat.warningFraction == 0.5)

        chat.recordTokens(60_000)
        #expect(chat.budgetIsWarning)
        #expect(!chat.budgetIsOverLimit)
        #expect(chat.budgetUsageFraction == 0.6)
    }

    @Test func tokenCountFormatting() {
        #expect(ChatStore.formatTokenCount(0) == "0")
        #expect(ChatStore.formatTokenCount(999) == "999")
        #expect(ChatStore.formatTokenCount(1_200) == "1.2k")
        #expect(ChatStore.formatTokenCount(100_000) == "100k")
        #expect(ChatStore.formatTokenCount(1_234_567) == "1.2m")
    }

    @Test func attachProductionServicesWiresBudgetAndRecorder() async throws {
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-budget-status-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let provider = MockProvider.shared
        let readinessStore = ProviderReadinessStore(directory: sessionDirectory)
        readinessStore.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "Mock",
                modelID: provider.model.id,
                status: .passed,
                readinessState: .mock,
                checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
                evidenceID: "mock-budget-status",
                isApplied: true,
                applyReceiptID: "provider-readiness-apply:mock-budget-status-apply"
            )
        )
        let bridge = BridgeStore(providerReadinessStore: readinessStore)
        let mcpManager = MCPServerManager(
            fileURL: sessionDirectory.appendingPathComponent("mcps.json")
        )
        var agent = AgentSettings.default
        agent.autoCompactThreshold = 0.9
        bridge.attachProductionServices(
            agentSettings: agent,
            sessionDirectory: sessionDirectory,
            mcpManager: mcpManager
        )
        #expect(bridge.chat.warningFraction == 0.9)
        guard let engine = bridge.chat.agentEngine as? AgentLoopChatEngine else {
            Issue.record("生产装配后应使用 AgentLoopChatEngine")
            return
        }
        #expect(engine.requestBudget != nil)
        // Keep the provider explicit: this fixture must not depend on a
        // process-global/default model selection while readiness is installed.
        bridge.chat.streamingProviderOverride = provider
        let selectedProvider = try bridge.chat.activeProvider()
        #expect(selectedProvider.name == provider.name)
        #expect(selectedProvider.model.id == provider.model.id)
        // 引擎已装配用量回调 → 发一条 Mock 消息后请求数 +1
        bridge.chat.draftText = "记录一下"
        bridge.chat.sendDraft()
        // 记录经 Task 回 MainActor，轮询等待首轮 LLM 调用落账
        var waited: TimeInterval = 0
        while bridge.chat.budgetRequestCount == 0 && waited < 5 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(bridge.chat.budgetRequestCount == 1)
        // Mock 无 usage 字段 → token 记为 0（请求数照常累计）
        #expect(bridge.chat.budgetUsedTokens == 0)
        bridge.chat.stopStreaming()
    }
}

// MARK: - Agent 引擎用量记录（E8）

/// 测试用 LLMProvider：sendMessage 返回固定 usage（input 10 + output 5 = 15）。
final class UsageProbeProvider: LLMProvider, @unchecked Sendable {
    var name: String { "UsageProbe" }
    var model: LLMModel = LLMModel(id: "usage-probe", displayName: "Usage Probe", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.streaming, .tools] }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "ok", stopReason: "end_turn", usage: LLMUsage(inputTokens: 10, outputTokens: 5))
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}

/// 跨线程累计 token 的测试盒（引擎回调在非 MainActor 执行器上触发）。
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _total = 0
    func add(_ n: Int) { lock.lock(); _total += n; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return _total }
}

@Suite("E8 Agent 引擎用量记录")
struct AgentEngineUsageTests {
    @Test func agentLoopEngineRecordsUsagePerRoundTrip() async throws {
        let box = TokenBox()
        let engine = AgentLoopChatEngine(onLLMCallRecorded: { box.add($0) })
        let stream = try await engine.streamReply(
            provider: UsageProbeProvider(),
            history: [ChatMessageUI(role: .user, content: "hi")],
            systemPrompt: "test",
            maxTokens: 100,
            conversationID: "budget-recording-test",
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 1
        )
        for try await _ in stream {}
        // 单轮（无工具调用）→ 记录一次 input+output = 15
        #expect(box.total == 15)
    }

    @Test func engineWithoutRecorderDoesNotRecord() async throws {
        let box = TokenBox()
        let engine = AgentLoopChatEngine() // 默认无回调
        let stream = try await engine.streamReply(
            provider: UsageProbeProvider(),
            history: [ChatMessageUI(role: .user, content: "hi")],
            systemPrompt: "test",
            maxTokens: 100,
            conversationID: "budget-no-recorder-test",
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 1
        )
        for try await _ in stream {}
        #expect(box.total == 0)
    }

    @Test func budgetRecordingProviderReadsUsageField() async throws {
        let box = TokenBox()
        let wrapped = BudgetRecordingProvider(base: UsageProbeProvider()) { box.add($0) }
        let response = try await wrapped.sendMessage(
            messages: [], systemPrompt: nil, maxTokens: 10, temperature: nil
        )
        #expect(box.total == 15)
        #expect(response.text == "ok")
        #expect(response.usage?.inputTokens == 10)
    }
}
