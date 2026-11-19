import Foundation
import Testing
@testable import MinisCore

// MARK: - F19 (P1-4): RequestBudget 超限强制（接入 AgentLoop，不再只记录）
//
// 旧行为：预算只在 UI 层记录/染色，循环照常烧 token。
// 新行为：AgentLoop 每轮 record usage 并强制执行 policy ——
//   .pause       → 抛 budgetExhausted 中断本回合；预算已耗尽时拒绝开新回合
//   .autoCompact → 压缩历史一次后继续
//   .warn        → 继续（由上层展示）

/// 带可控 usage 的脚本 provider。
private final class BudgetMockProvider: LLMProvider, @unchecked Sendable {
    var name: String { "BudgetMock" }
    var model: LLMModel
    var capabilities: Set<ProviderCapability> { [.tools] }
    var responses: [String]
    /// 每次 sendMessage 返回的 usage（按序消耗，耗尽后返回 nil）。
    var usages: [LLMUsage]
    private(set) var callCount = 0
    /// 记录每次收到的消息历史（断言 compaction 生效）。
    private(set) var receivedHistory: [[LLMMessage]] = []

    init(
        model: LLMModel = .claudeHaiku45,
        responses: [String],
        usages: [LLMUsage] = []
    ) {
        self.model = model
        self.responses = responses
        self.usages = usages
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        callCount += 1
        receivedHistory.append(messages)
        let text = responses.isEmpty ? "" : responses.removeFirst()
        let usage = usages.isEmpty ? nil : usages.removeFirst()
        return LLMResponse(text: text, stopReason: nil, usage: usage)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
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
        AsyncThrowingStream { $0.finish() }
    }
}

/// 构造单工具调用 envelope（保持循环不提前收尾）。
private func budgetEnvelope(id: String, name: String = "web_search", input: [String: Any] = ["query": "x"]) -> String {
    let object: [String: Any] = ["tool_calls": [["id": id, "name": name, "input": input]]]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

/// 空 executor（预算测试不需要真工具）。
private final class NoopBudgetExecutor: ToolExecutor, @unchecked Sendable {
    private(set) var callCount = 0
    func execute(name: String, input: [String: Any]) async throws -> String {
        callCount += 1
        return "ok"
    }
}

struct RequestBudgetEnforcementTests {

    @Test func pausePolicyHaltsLoopMidTurn() async throws {
        // 第 2 轮 record 越过 token 上限且 policy=.pause → 循环立即抛
        // budgetExhausted，不再发起后续 provider 调用。
        let tracker = BudgetTracker(RequestBudget(maxTokensPerSession: 100, overBudgetPolicy: .pause))
        let mock = BudgetMockProvider(
            responses: [budgetEnvelope(id: "c1"), budgetEnvelope(id: "c2"), "不该看到"],
            usages: [LLMUsage(inputTokens: 30, outputTokens: 30),   // 60 < 100
                     LLMUsage(inputTokens: 30, outputTokens: 30)]  // 120 ≥ 100 → pause
        )
        let root = try minisCoreToolContractRoot("budget-pause")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("budget-pause")
        let loop = AgentLoop(
            maxIterations: 5,
            loopDetector: nil,
            requestBudget: tracker,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )

        await #expect(throws: AgentLoopError.budgetExhausted) {
            _ = try await loop.run(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                provider: mock,
                toolExecutor: NoopBudgetExecutor(),
                tools: minisCoreToolContractCatalog(["web_search"]),
                executionIdentity: identity
            )
        }
        #expect(mock.callCount == 2, "第 2 轮越限即停，不得发起第 3 轮")
        #expect(await tracker.isExhausted)
    }

    @Test func pausePolicyRefusesNewTurnOutright() async throws {
        // 预算已耗尽（之前烧满且 policy=.pause）→ 新回合在首个 provider
        // 调用之前就被拒绝，控制器也不得进入 running / 消耗回合序号。
        var exhausted = RequestBudget(maxTokensPerSession: 10, overBudgetPolicy: .pause)
        _ = exhausted.record(requestTokens: 50) // 越限
        #expect(exhausted.isExhausted)
        let tracker = BudgetTracker(exhausted)
        let mock = BudgetMockProvider(responses: ["重置后放行"])
        let controller = TurnController()
        let loop = AgentLoop(maxIterations: 5, turnController: controller, loopDetector: nil, requestBudget: tracker)

        await #expect(throws: AgentLoopError.budgetExhausted) {
            _ = try await loop.run(
                messages: [], systemPrompt: nil,
                provider: mock, toolExecutor: NoopBudgetExecutor(), tools: []
            )
        }
        #expect(mock.callCount == 0)
        #expect(await controller.isRunning == false, "被拒绝的回合不得置位 isRunning")
        #expect(await controller.turnID == 0, "被拒绝的回合不得消耗回合序号")

        // 重置预算后同一 tracker 放行。
        await tracker.reset()
        let ok = try await loop.run(
            messages: [], systemPrompt: nil,
            provider: mock, toolExecutor: NoopBudgetExecutor(), tools: []
        )
        #expect(ok.messages.last?.content == "重置后放行")
        #expect(mock.callCount == 1)
    }

    @Test func autoCompactSummaryThatDoesNotReduceTheRequestIsRefusedAndHistoryStaysIntact() async throws {
        // Older messages are summarized by the model (lossy). A summary that does
        // not materially shrink the request is never adopted: the run stops with
        // the typed refusal and the next dialogue request is never sent.
        let tracker = BudgetTracker(RequestBudget(maxTokensPerSession: 50, overBudgetPolicy: .autoCompact))
        let compactor = Compactor(keepRecentMessages: 1)
        let mock = BudgetMockProvider(
            // 第 3 个响应是摘要请求的回复：比被摘要的旧消息还长，不会缩小请求。
            responses: [budgetEnvelope(id: "c1"), budgetEnvelope(id: "c2"),
                        String(repeating: "冗长摘要", count: 200), "r3 收尾"],
            usages: [LLMUsage(inputTokens: 20, outputTokens: 10),  // 30 < 50
                     LLMUsage(inputTokens: 20, outputTokens: 10),  // 60 ≥ 50 → 下一轮开始前压缩
                     LLMUsage(inputTokens: 20, outputTokens: 10)]
        )
        let root = try minisCoreToolContractRoot("budget-auto-compact")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("budget-auto-compact", sessionID: "budget-auto-compact")
        let executor = NoopBudgetExecutor()
        let source = [
            LLMMessage(role: .user, content: "旧问题1"),
            LLMMessage(role: .assistant, content: "旧回答1"),
            LLMMessage(role: .user, content: "旧问题2")
        ]
        // web_search 默认要问（11/19）；本测试与审批无关，显式设为自动通过。
        var loop = AgentLoop(
            maxIterations: 5,
            approvalGate: ApprovalGate(policyByTool: ["web_search": .autoApprove]),
            loopDetector: nil,
            requestBudget: tracker,
            compactor: compactor,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )

        loop.automaticCompaction = batch2CanonicalCompaction(source: source, provider: mock)

        await #expect(throws: AgentLoopError.compactionCheckpointUnavailable(
            "no verified request reduction"
        )) {
            _ = try await loop.run(
            messages: source,
            systemPrompt: nil,
            provider: mock,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["web_search"]),
            currentConversationID: identity.turn.sessionID,
            executionIdentity: identity
            )
        }

        // 2 次对话请求 + 1 次摘要请求；压缩在越限那轮的工具执行完之后、下一次对话请求之前进行，
        // 摘要未带来体积缩减，不再发第 3 次对话请求。
        #expect(mock.callCount == 3)
        try #require(mock.receivedHistory.count == 3)
        #expect(executor.callCount == 2)
        // 第 2 轮（压缩前）收到的还是完整历史（5 条，无摘要）。
        #expect(mock.receivedHistory[1].count == 5)
        #expect(!mock.receivedHistory[1].contains { $0.content.contains("<context-summary>") })
        // 第 3 次请求是摘要请求，带着旧消息原文。
        #expect(mock.receivedHistory[2].map(\.content).joined().contains("旧问题1"))
    }

    @Test func warnPolicyContinuesAndOnlyTrackerReflectsState() async throws {
        // .warn：越限不打断循环，正常收尾；tracker 状态如实反映耗尽。
        let tracker = BudgetTracker(RequestBudget(maxRequestsPerSession: 1, overBudgetPolicy: .warn))
        let mock = BudgetMockProvider(
            responses: [budgetEnvelope(id: "c1"), "r2 收尾"],
            usages: [LLMUsage(inputTokens: 1, outputTokens: 1), LLMUsage(inputTokens: 1, outputTokens: 1)]
        )
        let root = try minisCoreToolContractRoot("budget-warn")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("budget-warn")
        let loop = AgentLoop(
            maxIterations: 5,
            loopDetector: nil,
            requestBudget: tracker,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )

        let result = try await loop.run(
            messages: [], systemPrompt: nil,
            provider: mock,
            toolExecutor: NoopBudgetExecutor(),
            tools: minisCoreToolContractCatalog(["web_search"]),
            executionIdentity: identity
        )
        #expect(result.messages.last?.content == "r2 收尾")
        #expect(mock.callCount == 2)
        #expect(await tracker.isExhausted)
        #expect(await tracker.shouldBlockNewRequests == false, ".warn 不阻断新回合")
    }

    @Test func noTrackerKeepsLegacyBehavior() async throws {
        // requestBudget == nil：完全向后兼容，不做任何预算检查。
        let mock = BudgetMockProvider(responses: ["直接收尾"])
        let loop = AgentLoop(maxIterations: 5, loopDetector: nil)
        let result = try await loop.run(
            messages: [], systemPrompt: nil,
            provider: mock, toolExecutor: NoopBudgetExecutor(), tools: []
        )
        #expect(result.messages.last?.content == "直接收尾")
    }

    @Test func budgetTrackerSemantics() async {
        // 单元层：record 返回 policy；shouldBlockNewRequests 只对 pause+耗尽为真。
        let pause = BudgetTracker(RequestBudget(maxRequestsPerSession: 1, overBudgetPolicy: .pause))
        #expect(await pause.record(requestTokens: 5) == .pause)
        #expect(await pause.shouldBlockNewRequests)

        let warn = BudgetTracker(RequestBudget(maxRequestsPerSession: 1, overBudgetPolicy: .warn))
        #expect(await warn.record(requestTokens: 5) == .warn)
        #expect(await warn.isExhausted)
        #expect(await warn.shouldBlockNewRequests == false)

        let under = BudgetTracker(RequestBudget(maxTokensPerSession: 1000))
        #expect(await under.record(requestTokens: 10) == nil)
        #expect(await under.shouldBlockNewRequests == false)

        await pause.reset()
        #expect(await pause.isExhausted == false)
        #expect(await pause.shouldBlockNewRequests == false)
    }
}

// MARK: - F19 (P1-1): ToolLoopDetector 生产默认接线
//
// AgentLoop.init 的 loopDetector 默认从 nil 改为 ToolLoopDetector()：
// 生产聊天引擎构造 AgentLoop(maxIterations:approvalGate:turnController:)
// 时不再显式传 loopDetector，默认值保证生产路径自动获得死循环防护。

struct LoopDetectorDefaultWiringTests {

    @Test func defaultInitHasDetector() {
        // 任意生产构造形态都默认带检测器。
        #expect(AgentLoop().loopDetector != nil)
        #expect(AgentLoop(maxIterations: 10).loopDetector != nil)
        let gate = ApprovalGate(policyByTool: [:], delegate: nil)
        let controller = TurnController()
        // ChatAgentEngine 的生产构造形态（未显式传 loopDetector）。
        #expect(AgentLoop(maxIterations: 10, approvalGate: gate, turnController: controller).loopDetector != nil)
    }

    @Test func productionShapeLoopBlocksDeadToolLoop() async throws {
        // 以生产引擎的构造形态（gate + controller，未显式传 loopDetector）
        // 重复同参调用：第 3 次起必须被 LOOP BLOCKED —— 证明生产路径已接线。
        let executor = NoopBudgetExecutor()
        let mock = BudgetMockProvider(responses: [
            budgetEnvelope(id: "c1"),
            budgetEnvelope(id: "c2"),
            budgetEnvelope(id: "c3"),
            "改道完成",
        ])
        let root = try minisCoreToolContractRoot("loop-default")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("loop-default")
        let loop = AgentLoop(
            maxIterations: 6,
            approvalGate: ApprovalGate(policyByTool: ["web_search": .autoApprove]),
            turnController: TurnController(),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let result = try await loop.run(
            messages: [], systemPrompt: nil,
            provider: mock,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["web_search"]),
            executionIdentity: identity
        )
        let blocked = result.messages.flatMap { msg in
            msg.toAgentContentParts().compactMap { part -> String? in
                if case .toolResult(_, _, let content, let isError, _, _, _, _) = part,
                   isError, content.contains("[LOOP BLOCKED]") { return content }
                return nil
            }
        }
        #expect(blocked.count == 1, "默认阈值 3：前 2 次执行、第 3 次被拦截")
        #expect(result.toolCallsExecuted == 2)
        #expect(result.messages.last?.content == "改道完成")
    }

    @Test func explicitNilOptsOutOfDetection() async throws {
        // 显式 loopDetector: nil → 回到旧行为，重复调用不拦截（只靠 maxIterations 兜底）。
        let executor = NoopBudgetExecutor()
        let mock = BudgetMockProvider(responses: [
            budgetEnvelope(id: "c1"),
            budgetEnvelope(id: "c2"),
            budgetEnvelope(id: "c3"),
            "收尾",
        ])
        let root = try minisCoreToolContractRoot("loop-explicit-nil")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("loop-explicit-nil")
        // web_search 默认要问（11/19）；本测试与审批无关，显式设为自动通过。
        let loop = AgentLoop(
            maxIterations: 6,
            approvalGate: ApprovalGate(policyByTool: ["web_search": .autoApprove]),
            loopDetector: nil,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let result = try await loop.run(
            messages: [], systemPrompt: nil,
            provider: mock,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["web_search"]),
            executionIdentity: identity
        )
        let blocked = result.messages.flatMap { msg in
            msg.toAgentContentParts().compactMap { part -> String? in
                if case .toolResult(_, _, let content, _, _, _, _, _) = part,
                   content.contains("[LOOP BLOCKED]") { return content }
                return nil
            }
        }
        #expect(blocked.isEmpty, "显式 opt-out 后不得拦截")
        #expect(result.toolCallsExecuted == 3)
    }
}
