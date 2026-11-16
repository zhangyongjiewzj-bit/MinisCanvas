import Foundation
import Testing
import Darwin
@testable import MinisCore

// NOTE: 本套件运行在 CLT-only toolchain 上，使用 Swift Testing（见 AgentLoopTests.swift 头注释）。
// 运行：cd src/MinisCore && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//            -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks

// MARK: - Concurrency Probe & Barrier（确定性并发断言，不用 sleep 计时）

/// 记录 sendMessage 并发峰值的 actor。
actor OrchestrationProbe {
    private var active = 0
    private(set) var maxActive = 0
    private(set) var prompts: [String?] = []

    func enter(systemPrompt: String? = nil) {
        prompts.append(systemPrompt)
        active += 1
        maxActive = max(maxActive, active)
    }

    func exit() {
        active -= 1
    }
}

/// 集合屏障：前 `expected` 个到达者互相等待，之后到达者立即通过。
/// 用于证明 N 个任务确实同时在飞（而非串行偷跑）。
actor ConcurrentBarrier {
    private let expected: Int
    private var entered = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = max(1, expected)
    }

    func arrive() async {
        entered += 1
        if entered >= expected {
            let pending = waiters
            waiters.removeAll()
            for w in pending { w.resume() }
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

/// 探针 LLM provider：统计并发 + 可选屏障 + 可选失败标记（指令含标记则抛错）。
final class ProbeLLMProvider: LLMProvider {
    var name: String { "Probe" }
    var model: LLMModel
    private let probe: OrchestrationProbe
    private let barrier: ConcurrentBarrier?
    private let failureMarker: String?

    init(
        model: LLMModel = .claudeHaiku45,
        probe: OrchestrationProbe,
        barrier: ConcurrentBarrier? = nil,
        failureMarker: String? = nil
    ) {
        self.model = model
        self.probe = probe
        self.barrier = barrier
        self.failureMarker = failureMarker
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await probe.enter(systemPrompt: systemPrompt)
        if let barrier { await barrier.arrive() }
        await probe.exit()
        if let marker = failureMarker, let first = messages.first, first.content.contains(marker) {
            throw ProbeFailure.failedTask
        }
        return LLMResponse(text: "子任务完成", stopReason: nil, usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

enum ProbeFailure: Error {
    case failedTask
}

/// 空工具执行器（内置子 agent 测试不需要真工具）。
final class NoopToolExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        "ok"
    }
}

/// 可注入的 mock 外部 runner：指令含 `failureMarker` 时抛错。
struct MockExternalRunner: ExternalAgentRunner {
    let name: String
    let failureMarker: String?

    init(name: String, failureMarker: String? = nil) {
        self.name = name
        self.failureMarker = failureMarker
    }

    var isAvailable: Bool { true }

    func run(task: SubAgentTask) async throws -> String {
        if let marker = failureMarker, task.instructions.contains(marker) {
            throw ProbeFailure.failedTask
        }
        return "mock-输出-\(task.id)"
    }
}

// MARK: - Fixture

private func makeTasks(_ ids: [String], agentType: SubAgentAgentType = .builtin) -> [SubAgentTask] {
    ids.map { id in
        SubAgentTask(id: id, title: "任务 \(id)", instructions: "执行 \(id) 的指令", agentType: agentType)
    }
}

// MARK: - F19 (P1-3) Fixtures：子 agent 工具调用测试用 provider / executor

/// 脚本化 envelope provider：按序返回预设响应（可为工具调用 envelope）。
final class ScriptedChildProvider: LLMProvider, @unchecked Sendable {
    var name: String { "ScriptedChild" }
    var model: LLMModel
    var capabilities: Set<ProviderCapability> { [.tools] }
    var responses: [String]
    private(set) var receivedRequests: [[LLMMessage]] = []
    var onFirstRequest: (@Sendable () async throws -> Void)?

    init(model: LLMModel = .claudeHaiku45, responses: [String]) {
        self.model = model
        self.responses = responses
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        if receivedRequests.isEmpty { try await onFirstRequest?() }
        receivedRequests.append(messages)
        let text = responses.isEmpty ? "" : responses.removeFirst()
        return LLMResponse(text: text, stopReason: nil, usage: nil)
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

/// Synthetic provider that asks for the same file from two differently scoped
/// children, then reports whether the actual tool result contained its marker.
final class ScopedReadProbeProvider: LLMProvider, @unchecked Sendable {
    let name = "ScopedReadProbe"
    var model: LLMModel = .claudeHaiku45
    let capabilities: Set<ProviderCapability> = [.tools]
    let path: String
    let marker: String
    private let lock = NSLock()
    private var seen: Set<String> = []
    private var _offeredToolNameSets: [[String]] = []
    private var didInvokeFirstToolOffer = false
    let onFirstToolOffer: (@Sendable () -> Void)?

    var offeredToolNameSets: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return _offeredToolNameSets
    }

    init(path: String, marker: String, onFirstToolOffer: (@Sendable () -> Void)? = nil) {
        self.path = path
        self.marker = marker
        self.onFirstToolOffer = onFirstToolOffer
    }

    private func response(messages: [LLMMessage]) -> LLMResponse {
        let taskKey = messages.first?.content ?? ""
        lock.lock()
        let first = seen.insert(taskKey).inserted
        lock.unlock()
        if first {
            if taskKey.contains("read-no-file") {
                return LLMResponse(text: "no-file-task-finished", stopReason: nil, usage: nil)
            }
            return LLMResponse(text: orchEnvelope(
                id: "scoped-read", name: "file_read",
                input: ["tool_title": "Read scoped test file", "path": path]
            ), stopReason: nil, usage: nil)
        }
        let reachedFile = messages.contains { $0.content.contains(marker) }
        return LLMResponse(text: reachedFile ? "read-ok" : "read-blocked", stopReason: nil, usage: nil)
    }

    private func recordOffered(_ names: [String]) {
        lock.lock()
        _offeredToolNameSets.append(names)
        lock.unlock()
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        response(messages: messages)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        recordOffered(tools.map(\.name))
        let invokeHook = lock.withLock { () -> Bool in
            guard !didInvokeFirstToolOffer else { return false }
            didInvokeFirstToolOffer = true
            return true
        }
        if invokeHook { onFirstToolOffer?() }
        return response(messages: messages)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Records the actual child effect path while forwarding through a wrapper.
final class ScopedForwardingExecutor: ToolCatalogValidatingExecutor,
    BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var currentBase: BuiltinToolExecutor
    private var _invokedNames: [String] = []
    private var _observedShellBudgets: [TimeInterval] = []

    var observedShellBudgets: [TimeInterval] { lock.withLock { _observedShellBudgets } }

    init(base: BuiltinToolExecutor) { currentBase = base }

    func rebind(to base: BuiltinToolExecutor) {
        lock.lock()
        currentBase = base
        lock.unlock()
    }

    private var base: BuiltinToolExecutor {
        lock.lock()
        defer { lock.unlock() }
        return currentBase
    }

    var currentBuiltinOwner: BuiltinToolExecutor? { base.currentBuiltinOwner }

    func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        let commandSeconds = name == "shell_execute" ? ShellCommandTimeoutPolicy.currentBudget?.seconds : nil
        let captured = lock.withLock { () -> BuiltinToolExecutor? in
            guard currentBase === owner else { return nil }
            _invokedNames.append(name)
            if let commandSeconds { _observedShellBudgets.append(commandSeconds) }
            return currentBase
        }
        guard let captured else { throw ToolExecutorError.resourceScopeInvalid }
        return try await captured.executeBoundToBuiltinOwner(owner, name: name, input: input)
    }

    var invokedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _invokedNames
    }

    func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        try base.validateToolCatalog(tools)
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        record(name)
        return try await base.execute(name: name, input: input)
    }

    private func record(_ name: String) {
        lock.lock()
        _invokedNames.append(name)
        lock.unlock()
    }
}

private struct UnprovenBuiltinForwarder: ToolExecutor {
    let base: BuiltinToolExecutor

    func execute(name: String, input: [String: Any]) async throws -> String {
        try await base.execute(name: name, input: input)
    }
}

/// 记录型 executor（线程安全，供并行子 agent 场景使用）。
final class RecordingOrchestratorExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _executedNames: [String] = []
    var executedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _executedNames
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        record(name)
        return "ok-\(name)"
    }

    /// 记录工具名（同步方法内加锁，避免 async 上下文的 NSLock 限制）。
    private func record(_ name: String) {
        lock.lock()
        _executedNames.append(name)
        lock.unlock()
    }
}

/// 构造单工具调用 envelope。
private func orchEnvelope(id: String, name: String, input: [String: Any]) -> String {
    let object: [String: Any] = ["tool_calls": [["id": id, "name": name, "input": input]]]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

// MARK: - F19 (P1-3)：子 agent 不得绕过审批 / 可被中断 / 有循环检测

struct AgentOrchestratorChildControlsTests {

    @Test func productionChildConsumesSixteenthResponseBeforeRejectingNextRequestB03() async throws {
        let root = try minisCoreToolContractRoot("b03-child-request-cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let parentSession = try sessions.createSession(id: "b03-parent-session")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let parent = ParentRuntimeIdentity(
            sessionID: parentSession.id, conversationID: parentSession.id,
            turnID: "turn-handle:\(handle.turnID)", taskID: "b03-parent", actorID: "test"
        )
        let parentTracker = BudgetTracker(RequestBudget(
            maxRequestsPerSession: 32, maxTokensPerSession: 10_000, overBudgetPolicy: .pause
        ))
        for _ in 0..<16 { _ = await parentTracker.record(requestTokens: 100) }
        let before = await parentTracker.budget
        #expect(before.usedRequests == 16)
        #expect(before.maxRequestsPerSession == 32)
        #expect(before.tokensRemaining == 8_400)

        var responses: [String] = []
        for index in 1...16 {
            let file = root.appendingPathComponent("read-\(index).txt")
            try "B03 read \(index)".write(to: file, atomically: true, encoding: .utf8)
            responses.append(orchEnvelope(id: "b03-read-\(index)", name: "file_read", input: [
                "path": file.path
            ]))
        }
        responses.append("Unexpected seventeenth provider response")
        let provider = ScriptedChildProvider(responses: responses)
        provider.onFirstRequest = {
            let binding = try #require(AgentExecutionContext.current?.childToolRuntimeBinding)
            #expect(binding.parent == parent)
            let budget = await binding.boundary.budget.budget
            #expect(budget.maxTokensPerSession == before.tokensRemaining)
        }
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let ledger = try minisCoreToolContractLedger(at: root)
        let orchestrator = AgentOrchestrator(
            maxIterationsPerTask: 18, provider: provider, toolExecutor: owner,
            approvalGate: ApprovalGate(), turnController: controller,
            makeChildBudget: { parentTracker }, boundParentRequestBudget: parentTracker,
            currentConversationID: parentSession.id,
            taskStore: AgentTaskStore(), sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent,
            parentTurnHandle: handle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
            ),
            parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            concreteBuiltinToolExecutorOwner: owner
        )
        let child = SubAgentTask(
            id: "b03-child", title: "B03 child", instructions: "Read the synthetic files",
            requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(
                allowedToolNames: ["file_read"], allowedReadRoots: [root.path]
            )
        )
        let reports = await orchestrator.orchestrate(tasks: [child], strategy: .sequential)
        await handle.finish()
        let after = await parentTracker.budget
        #expect(after.usedRequests == before.usedRequests)
        #expect(after.usedTokens == before.usedTokens)
        #expect(after.tokensRemaining == before.tokensRemaining)
        #expect(provider.receivedRequests.count == 16)
        #expect(provider.responses == ["Unexpected seventeenth provider response"])
        #expect(ledger.facts.filter { $0.toolName == "file_read" && $0.status == .succeeded }
            .map(\.toolCallID) == (1...16).map { "b03-read-\($0)" })
        #expect(reports.count == 1)
        #expect(reports.first?.result.error == AgentLoopError.budgetExhausted.localizedDescription)
    }

    @Test func boundedParentBudgetUsesIndependentChildTrackerB03() async throws {
        let root = try minisCoreToolContractRoot("b03-bounded-parent-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: "b03-bounded-parent")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let parent = ParentRuntimeIdentity(
            sessionID: session.id, conversationID: session.id,
            turnID: "turn-handle:\(handle.turnID)", taskID: "b03-bounded-parent", actorID: "test"
        )
        let parentTracker = BudgetTracker(RequestBudget(
            maxRequestsPerSession: 4, maxTokensPerSession: 1_000, overBudgetPolicy: .pause
        ))
        _ = await parentTracker.record(requestTokens: 100)
        let responses = try (1...3).map { index in
            let file = root.appendingPathComponent("read-\(index).txt")
            try "B03 bounded read \(index)".write(to: file, atomically: true, encoding: .utf8)
            return orchEnvelope(id: "b03-bounded-read-\(index)", name: "file_read", input: ["path": file.path])
        }
        let provider = ScriptedChildProvider(responses: responses + ["Unexpected fourth provider response"])
        provider.onFirstRequest = {
            let binding = try #require(AgentExecutionContext.current?.childToolRuntimeBinding)
            #expect(binding.parent == parent)
            #expect(binding.boundary.budget !== parentTracker)
            let budget = await binding.boundary.budget.budget
            #expect(budget.maxRequestsPerSession == 3)
            #expect(budget.maxTokensPerSession == 900)
        }
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let ledger = try minisCoreToolContractLedger(at: root)
        let orchestrator = AgentOrchestrator(
            maxIterationsPerTask: 5, provider: provider, toolExecutor: owner,
            approvalGate: ApprovalGate(), turnController: controller,
            makeChildBudget: { parentTracker }, boundParentRequestBudget: parentTracker,
            currentConversationID: session.id, taskStore: AgentTaskStore(), sessionStore: sessions,
            toolExecutionFactLedger: ledger, parentID: parent.taskID, parentRuntimeIdentity: parent,
            parentTurnHandle: handle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
            ),
            parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            concreteBuiltinToolExecutorOwner: owner
        )
        let child = SubAgentTask(
            id: "b03-bounded-child", title: "B03 bounded child", instructions: "Read the synthetic file",
            requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read"], allowedReadRoots: [root.path])
        )
        let reports = await orchestrator.orchestrate(tasks: [child], strategy: .sequential)
        await handle.finish()
        let after = await parentTracker.budget
        #expect(after.usedRequests == 1)
        #expect(after.usedTokens == 100)
        #expect(after.tokensRemaining == 900)
        #expect(provider.receivedRequests.count == 3)
        #expect(provider.responses == ["Unexpected fourth provider response"])
        #expect(ledger.facts.filter { $0.toolName == "file_read" && $0.status == .succeeded }
            .map(\.toolCallID) == (1...3).map { "b03-bounded-read-\($0)" })
        #expect(reports.count == 1)
        #expect(reports.first?.result.error == AgentLoopError.budgetExhausted.localizedDescription)
    }

    @Test func parentAtRequestCapStillDiscardsResponseB03() async {
        let tracker = BudgetTracker(RequestBudget(maxRequestsPerSession: 1, overBudgetPolicy: .pause))
        let provider = ScriptedChildProvider(responses: ["Parent cap response must not publish"])
        let loop = AgentLoop(maxIterations: 2, loopDetector: nil, requestBudget: tracker)
        await #expect(throws: AgentLoopError.budgetExhausted) {
            _ = try await loop.run(
                messages: [LLMMessage(role: .user, content: "Parent cap control")],
                systemPrompt: nil, provider: provider, toolExecutor: NoopToolExecutor(), tools: [],
                onMessage: { _, message in
                    #expect(message.role != .assistant)
                }
            )
        }
        #expect(provider.receivedRequests.count == 1)
        #expect(provider.responses.isEmpty)
        #expect(await tracker.budget.usedRequests == 1)
    }

    @Test func childExecutionLimitsAreExplicitAndInherited() {
        let tracker = BudgetTracker(RequestBudget(maxRequestsPerSession: 1, overBudgetPolicy: .pause))
        let orchestrator = AgentOrchestrator()
            .withChildExecutionLimits(
                makeBudget: { tracker },
                timeout: 1.5,
                currentConversationID: "conversation-42"
            )
        #expect(orchestrator.childTimeout == 1.5)
        #expect(orchestrator.currentConversationID == "conversation-42")
        #expect(orchestrator.makeChildBudget != nil)
    }

    @Test func childTaskCanCarryExplicitProviderAndModelBinding() {
        let task = SubAgentTask(
            id: "bound",
            title: "Bound task",
            instructions: "inspect",
            providerID: "provider-b",
            modelID: "model-3"
        )
        #expect(task.providerID == "provider-b")
        #expect(task.modelID == "model-3")
    }

    @Test func childTaskDefaultsToInheritedProviderAndModel() {
        let task = SubAgentTask(id: "inherited", title: "Inherited", instructions: "inspect")
        #expect(task.providerID == nil)
        #expect(task.modelID == nil)
    }

    @Test func childProviderResolverIsOptInAndRetained() {
        let orchestrator = AgentOrchestrator(
            resolveChildProvider: { task, inherited in
                task.providerID == "provider-b" ? inherited : inherited
            }
        )
        #expect(orchestrator.resolveChildProvider != nil)
        #expect(AgentOrchestrator().resolveChildProvider == nil)
    }

    @Test func childDefaultGateBlocksHighRiskTools() async {
        // 默认编排器（未注入 delegate）：子 agent 请求 shell_execute 必须被
        // 默认 ApprovalGate() 拒绝（.alwaysAsk + 无 delegate → deny），
        // 绝不裸奔执行。旧代码裸建 AgentLoop，子代理可零审批执行高危工具。
        _ = OrchestrationProbe()
        let provider = ScriptedChildProvider(responses: [
            orchEnvelope(id: "c1", name: "shell_execute", input: ["command": "echo hi"]),
            "子任务完成",
        ])
        let executor = RecordingOrchestratorExecutor()
        let orchestrator = AgentOrchestrator()
            .withBuiltinExecution(provider: provider, toolExecutor: executor)

        let reports = await orchestrator.orchestrate(tasks: makeTasks(["a"]))

        #expect(reports.count == 1)
        #expect(reports[0].result.isSuccess, "被拒后循环仍应正常收尾")
        #expect(executor.executedNames.isEmpty, "子 agent 的 shell_execute 不得触达执行器")
    }

    @Test func legacyChildDelegateCannotGrantWithoutVerifiedParentIdentity() async throws {
        // 只有 delegate 不等于绑定的父回合身份。legacy 子任务的高风险调用
        // 必须在审批提示前拒绝，不能让无身份的 .approve 触达执行器。
        actor ApproveAllDelegate: ApprovalDelegate {
            private(set) var requestCount = 0

            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                requestCount += 1
                return .approve
            }
        }
        let provider = ScriptedChildProvider(responses: [
            orchEnvelope(id: "c1", name: "shell_execute", input: ["command": "echo hi"]),
            "子任务完成",
        ])
        let executor = RecordingOrchestratorExecutor()
        let delegate = ApproveAllDelegate()
        let root = try minisCoreToolContractRoot("orchestrator-child-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = AgentOrchestrator(
            currentConversationID: "orchestrator-child-gate",
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root),
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools],
                allowedToolNames: ["shell_execute"]
            ),
            parentCapabilities: [.tools]
        )
            .withBuiltinExecution(provider: provider, toolExecutor: executor)
            .withChildControls(approvalGate: ApprovalGate(delegate: delegate))

        let reports = await orchestrator.orchestrate(tasks: makeTasks(["a"]))

        #expect(reports[0].result.isSuccess)
        #expect(await delegate.requestCount == 0)
        #expect(executor.executedNames.isEmpty)
    }

    @Test func childInheritsParentGateWithDelegate() async throws {
        // 真正的父回合、子作用域和绑定回包齐备时，子 agent 继承审批门。
        // 对 file_read 显式收紧为 alwaysAsk，在合成目录读一次文件。
        actor BoundChildApprovalDelegate: ApprovalDelegate {
            private(set) var requests: [ApprovalRequest] = []

            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                requests.append(request)
                return ApprovalDecision(
                    approved: true,
                    confirmed: true,
                    requestID: request.requestID,
                    bindingDigest: request.identityDigest
                )
            }
        }
        let root = try minisCoreToolContractRoot("orchestrator-bound-child-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let parentSession = try sessions.createSession(id: "orchestrator-bound-child-gate")
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        let parent = ParentRuntimeIdentity(
            sessionID: parentSession.id,
            conversationID: parentSession.id,
            turnID: "turn-handle:\(parentHandle.turnID)",
            taskID: "orchestrator-bound-parent",
            actorID: "test"
        )
        let input = root.appendingPathComponent("approved-child.txt")
        try "approved child".write(to: input, atomically: true, encoding: .utf8)
        let provider = ScriptedChildProvider(responses: [
            orchEnvelope(id: "bound-child-call", name: "file_read", input: [
                "path": input.path,
            ]),
            "子任务完成",
        ])
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let delegate = BoundChildApprovalDelegate()
        let ledger = try minisCoreToolContractLedger(at: root)
        let orchestrator = AgentOrchestrator(
            maxIterationsPerTask: 2,
            provider: provider,
            toolExecutor: owner,
            approvalGate: ApprovalGate(policyByTool: ["file_read": .alwaysAsk], delegate: delegate),
            turnController: controller,
            currentConversationID: parentSession.id,
            taskStore: AgentTaskStore(),
            sessionStore: sessions,
            toolExecutionFactLedger: ledger,
            parentID: parent.taskID,
            parentRuntimeIdentity: parent,
            parentTurnHandle: parentHandle,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
            ),
            parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            concreteBuiltinToolExecutorOwner: owner
        )
        let child = SubAgentTask(
            id: "bound-child", title: "Bound child", instructions: "write synthetic fixture",
            requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(
                allowedToolNames: ["file_read"], allowedReadRoots: [root.path]
            )
        )

        let reports = await orchestrator.orchestrate(tasks: [child], strategy: .sequential)
        let requests = await delegate.requests
        #expect(reports.count == 1)
        #expect(reports.first?.result.isSuccess == true, "\(reports.first?.result.error ?? "missing report")")
        #expect(requests.count == 1)
        #expect(requests.first?.binding != nil)
        #expect(requests.first?.taskID == child.id)
        #expect(ledger.facts.filter { $0.toolName == "file_read" && $0.status == .succeeded }.count == 1)
        await parentHandle.finish()
    }

    @Test func childApprovalRejectsWrongControllerAndSiblingIdentity() async throws {
        actor CountingDelegate: ApprovalDelegate {
            private(set) var count = 0

            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                count += 1
                return ApprovalDecision(
                    approved: true,
                    confirmed: true,
                    requestID: request.requestID,
                    bindingDigest: request.identityDigest
                )
            }
        }
        let parentController = TurnController()
        let parentHandle = await parentController.beginTurn()
        let childController = TurnController()
        let childHandle = await childController.beginTurn()
        let wrongController = TurnController()
        let wrongHandle = await wrongController.beginTurn()
        let parent = ParentRuntimeIdentity(
            sessionID: "parent-session", conversationID: "parent-conversation",
            turnID: "turn-handle:\(parentHandle.turnID)",
            taskID: "parent-task", actorID: "test"
        )
        let identity = try ChildRuntimeIdentity.derive(
            parent: parent,
            childSessionID: "child-session", childTaskID: "child-task",
            scopeID: "child-scope",
            requestedCapabilities: [.tools],
            parentCapabilities: [.tools],
            policyCapabilities: [.tools],
            providerSnapshot: ParentContextSnapshotV1(
                providerID: "ScriptedChild", modelID: "synthetic-model",
                configurationFingerprint: "synthetic-fingerprint",
                conversationID: parent.conversationID
            ),
            memoryScopeID: "child-memory",
            workingDirectory: "/synthetic/no-read",
            cancelGeneration: parentHandle.turnID,
            evidenceRoot: "child-evidence",
            parentTurnHandle: parentHandle,
            childExecutionID: "child-execution"
        )
        let generationID = try #require(identity.generationID)
        let delegate = CountingDelegate()
        let gate = ApprovalGate(policyByTool: ["file_read": .alwaysAsk], delegate: delegate)
        let boundary = try AgentChildBoundary(
            identity: identity,
            parentCapabilities: [.tools],
            requestedCapabilities: [.tools],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
            ),
            parentTools: minisCoreToolContractCatalog(["file_read"]),
            budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 2)),
            deadline: Date().addingTimeInterval(30),
            parentTurnHandle: parentHandle,
            childTurnController: childController,
            approvalGate: gate
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: identity.childSessionID,
                turnID: identity.cancelGeneration,
                messageID: identity.childTaskID
            ),
            operationID: generationID,
            attempt: 1
        )
        let provider = ScriptedChildProvider(responses: [])
        func runtime(
            controller: TurnController, handle: TurnController.TurnHandle
        ) -> AgentExecutionContextSnapshot {
            AgentExecutionContextSnapshot(
                provider: provider,
                approvalGate: gate,
                turnController: controller,
                currentConversationID: identity.childSessionID,
                makeChildBudget: nil,
                deadline: Date().addingTimeInterval(30),
                parentTurnHandle: handle,
                parentRuntimeIdentity: parent,
                childRuntimeSnapshot: AgentChildRuntimeSnapshot(identity: identity)
            )
        }
        let input: [String: Any] = ["path": "/synthetic/no-read"]
        let wrongControllerCall = "wrong-controller"
        await #expect(throws: ApprovalError.missingIdentity(requestID: wrongControllerCall)) {
            try await AgentExecutionContext.$current.withValue(
                runtime(controller: wrongController, handle: wrongHandle)
            ) {
                try await gate.gateAgentCall(
                    tool: "file_read", input: input, callID: wrongControllerCall,
                    executionIdentity: executionIdentity, attemptID: generationID,
                    attemptNumber: 1, childBoundary: boundary
                )
            }
        }
        let siblingCall = "sibling-identity"
        let siblingIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "other-child-session",
                turnID: identity.cancelGeneration,
                messageID: identity.childTaskID
            ),
            operationID: generationID,
            attempt: 1
        )
        await #expect(throws: ApprovalError.missingIdentity(requestID: siblingCall)) {
            try await AgentExecutionContext.$current.withValue(
                runtime(controller: childController, handle: childHandle)
            ) {
                try await gate.gateAgentCall(
                    tool: "file_read", input: input, callID: siblingCall,
                    executionIdentity: siblingIdentity, attemptID: generationID,
                    attemptNumber: 1, childBoundary: boundary
                )
            }
        }
        #expect(await delegate.count == 0)
        await childHandle.finish()
        await wrongHandle.finish()
        await parentHandle.finish()
    }

    @Test func builtinChildReceivesSafetyBeforeParentPrompt() async throws {
        let probe = OrchestrationProbe()
        let provider = ProbeLLMProvider(probe: probe)
        let orchestrator = AgentOrchestrator()
            .withBuiltinExecution(provider: provider, toolExecutor: NoopToolExecutor())
        let parentPrompt = "SYNTHETIC_PARENT_CHILD_PROMPT"
        let reports = await orchestrator.orchestrate(tasks: makeTasks(["prompt-safety"]), systemPrompt: parentPrompt)
        try #require(reports.count == 1 && reports[0].result.isSuccess)
        let prompts = await probe.prompts
        try #require(prompts.count == 1)
        let prompt = try #require(prompts[0])
        #expect(prompt.hasPrefix("指令来源："))
        #expect(prompt.contains("不要换一种工具"))
        #expect(prompt.hasSuffix(parentPrompt))
    }

    @Test func pendingInterruptStopsChildBeforeFirstProviderCall() async {
        // 共享 TurnController：停止信号先于编排到达（P2-9 竞态场景）→
        // 子循环在第一次迭代边界即被中断，provider 一次都不被调用。
        let controller = TurnController()
        await controller.interrupt()
        let probe = OrchestrationProbe()
        let provider = ProbeLLMProvider(probe: probe)
        let orchestrator = AgentOrchestrator()
            .withBuiltinExecution(provider: provider, toolExecutor: NoopToolExecutor())
            .withChildControls(approvalGate: ApprovalGate(), turnController: controller)

        let reports = await orchestrator.orchestrate(tasks: makeTasks(["a"]))

        #expect(reports.count == 1)
        #expect(reports[0].result.isSuccess == false)
        #expect(await probe.maxActive == 0, "中断必须先于首个 provider 调用生效")
    }

    @Test func childLoopDetectorBlocksDeadLoop() async throws {
        // 逐子 ToolLoopDetector：子 agent 重复同参调用，第 3 次起被 LOOP BLOCKED，
        // 只烧 2 次真实执行，最终正常收尾（而非跑满 maxIterationsPerTask）。
        let provider = ScriptedChildProvider(responses: [
            orchEnvelope(id: "c1", name: "file_read", input: ["path": "/a"]),
            orchEnvelope(id: "c2", name: "file_read", input: ["path": "/a"]),
            orchEnvelope(id: "c3", name: "file_read", input: ["path": "/a"]),
            orchEnvelope(id: "c4", name: "file_read", input: ["path": "/a"]),
            "收尾",
        ])
        let executor = RecordingOrchestratorExecutor()
        let root = try minisCoreToolContractRoot("orchestrator-child-loop")
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = AgentOrchestrator(
            maxIterationsPerTask: 8,
            currentConversationID: "orchestrator-child-loop",
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root),
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools],
                allowedToolNames: ["file_read"]
            ),
            parentCapabilities: [.tools]
        )
            .withBuiltinExecution(provider: provider, toolExecutor: executor)

        let reports = await orchestrator.orchestrate(tasks: makeTasks(["a"]), strategy: .sequential)

        #expect(reports[0].result.isSuccess)
        #expect(executor.executedNames.count == 2, "前 2 次执行，第 3/4 次被循环检测拦截")
    }
}

// MARK: - Orchestrator: 并行 / 串行 / 限流 / 失败隔离

struct AgentOrchestratorTests {

    @Test func builtinParallelRunsAllTasksConcurrently() async {
        let probe = OrchestrationProbe()
        let barrier = ConcurrentBarrier(expected: 4)
        let provider = ProbeLLMProvider(probe: probe, barrier: barrier)
        let tasks = makeTasks(["a", "b", "c", "d"])

        let orchestrator = AgentOrchestrator(defaultMaxConcurrent: 4)
            .withBuiltinExecution(provider: provider, toolExecutor: NoopToolExecutor())

        let reports = await orchestrator.orchestrate(tasks: tasks, strategy: .parallelWithLimit(limit: 4))

        #expect(reports.count == 4)
        #expect(await probe.maxActive == 4, "4 个任务应同时在飞")
        #expect(reports.allSatisfy { $0.result.isSuccess })
        #expect(reports.map(\.taskID) == ["a", "b", "c", "d"], "报告应保持输入顺序")
        #expect(reports.allSatisfy { $0.agentType == .builtin })
    }

    @Test func parallelLimitIsRespected() async {
        let probe = OrchestrationProbe()
        let barrier = ConcurrentBarrier(expected: 2)
        let provider = ProbeLLMProvider(probe: probe, barrier: barrier)
        let tasks = makeTasks(["a", "b", "c", "d"])

        let orchestrator = AgentOrchestrator(defaultMaxConcurrent: 4)
            .withBuiltinExecution(provider: provider, toolExecutor: NoopToolExecutor())

        let reports = await orchestrator.orchestrate(tasks: tasks, strategy: .parallelWithLimit(limit: 2))

        #expect(reports.count == 4)
        #expect(await probe.maxActive == 2, "并发上限应为 2")
        #expect(reports.allSatisfy { $0.result.isSuccess })
        #expect(reports.map(\.taskID) == ["a", "b", "c", "d"])
    }

    @Test func sequentialRunsOneTaskAtATime() async {
        let probe = OrchestrationProbe()
        let provider = ProbeLLMProvider(probe: probe)
        let tasks = makeTasks(["a", "b", "c"])

        let orchestrator = AgentOrchestrator()
            .withBuiltinExecution(provider: provider, toolExecutor: NoopToolExecutor())

        let reports = await orchestrator.orchestrate(tasks: tasks, strategy: .sequential)

        #expect(reports.count == 3)
        #expect(await probe.maxActive == 1, "串行模式下并发峰值应为 1")
        #expect(reports.allSatisfy { $0.result.isSuccess })
        #expect(reports.map(\.taskID) == ["a", "b", "c"])
    }

    @Test func defaultParallelUsesDefaultMaxConcurrent() async {
        // 不指定 strategy → .parallel，上限取 defaultMaxConcurrent（默认 4）。
        let probe = OrchestrationProbe()
        let barrier = ConcurrentBarrier(expected: 3)
        let provider = ProbeLLMProvider(probe: probe, barrier: barrier)
        let tasks = makeTasks(["a", "b", "c"])

        let orchestrator = AgentOrchestrator()
            .withBuiltinExecution(provider: provider, toolExecutor: NoopToolExecutor())

        let reports = await orchestrator.orchestrate(tasks: tasks)

        #expect(reports.count == 3)
        #expect(await probe.maxActive == 3)
        #expect(reports.allSatisfy { $0.result.isSuccess })
    }

    @Test func builtinFailureIsolation() async {
        // 一个任务失败不阻塞兄弟任务；orchestrate 本身不抛错。
        let probe = OrchestrationProbe()
        let provider = ProbeLLMProvider(probe: probe, failureMarker: "boom")
        let tasks = [
            SubAgentTask(id: "ok", title: "正常", instructions: "正常任务"),
            SubAgentTask(id: "bad", title: "失败", instructions: "boom 任务"),
            SubAgentTask(id: "ok2", title: "正常2", instructions: "另一个正常任务"),
        ]

        let orchestrator = AgentOrchestrator()
            .withBuiltinExecution(provider: provider, toolExecutor: NoopToolExecutor())

        let reports = await orchestrator.orchestrate(tasks: tasks)

        #expect(reports.count == 3)
        let byID = Dictionary(uniqueKeysWithValues: reports.map { ($0.taskID, $0) })
        #expect(byID["ok"]?.result.isSuccess == true)
        #expect(byID["ok2"]?.result.isSuccess == true)
        #expect(byID["bad"]?.result.isSuccess == false)
        #expect(byID["bad"]?.result.error?.isEmpty == false)
        #expect(byID["bad"]?.duration ?? 0 >= 0)
    }

    @Test func builtinWithoutProviderMarkedFailed() async {
        let orchestrator = AgentOrchestrator() // 未配 provider / executor
        let tasks = makeTasks(["a"])

        let reports = await orchestrator.orchestrate(tasks: tasks)

        #expect(reports.count == 1)
        #expect(reports[0].result.isSuccess == false)
        #expect(reports[0].result.error?.contains("LLMProvider") == true)
    }

    @Test func emptyTasksReturnEmpty() async {
        let orchestrator = AgentOrchestrator()
        #expect(await orchestrator.orchestrate(tasks: []) == [])
        #expect(await orchestrator.orchestrate(tasks: [], strategy: .sequential) == [])
    }

    // MARK: 外部 runner 桥

    @Test func capabilityRoutingDoesNotInferFromRunnerName() async {
        let mock = MockExternalRunner(name: "codex")
        let task = SubAgentTask(
            id: "needs-tools",
            title: "needs-tools",
            instructions: "inspect",
            agentType: .external(name: "codex"),
            requiredCapabilities: [.tools]
        )
        let reports = await AgentOrchestrator()
            .withExternalRunner(mock)
            .orchestrate(tasks: [task], strategy: .sequential)

        #expect(reports.count == 1)
        #expect(reports[0].result == .failed(error: "CAPABILITY_UNAVAILABLE"))
    }

    @Test func externalRunnerInjectedIsUsed() async {
        let mock = MockExternalRunner(name: "codex")
        let tasks = makeTasks(["a", "b"], agentType: .external(name: "codex"))

        let orchestrator = AgentOrchestrator().withExternalRunner(mock)

        let reports = await orchestrator.orchestrate(tasks: tasks)

        #expect(reports.count == 2)
        #expect(reports.allSatisfy { $0.result.isSuccess })
        #expect(reports.allSatisfy { $0.agentType == .external(name: "codex") })
        #expect(reports[0].result.output == "mock-输出-a")
        #expect(reports[1].result.output == "mock-输出-b")
    }

    @Test func inheritedBindingPersistsCanonicalRouteReceipt() async throws {
        let store = AgentTaskStore()
        let parent = ParentContextSnapshotV1(
            providerID: "parent-provider",
            modelID: "parent-model",
            configurationFingerprint: "parent-fingerprint",
            conversationID: "parent-conversation"
        )
        let orchestrator = AgentOrchestrator(
            externalRunners: ["bound": MockExternalRunner(name: "bound")],
            taskStore: store,
            parentID: "parent-task",
            parentBinding: parent
        )

        let reports = await orchestrator.orchestrate(tasks: [
            SubAgentTask(
                id: "inherited-route",
                title: "inherited-route",
                instructions: "inspect",
                agentType: .external(name: "bound")
            )
        ], strategy: .sequential)

        let snapshot = try #require(store.snapshot(taskID: "inherited-route", parentID: "parent-task"))
        #expect(reports.first?.result.isSuccess == true)
        #expect(snapshot.providerID == parent.providerID)
        #expect(snapshot.modelID == parent.modelID)
        #expect(snapshot.configurationFingerprint == parent.configurationFingerprint)
        #expect(snapshot.routeReceiptID == "route:parent-provider:parent-model:parent-fingerprint")
    }

    @Test func lifecycleEnvelopeCarriesGeneratedExecutionIdentity() async throws {
        let store = AgentTaskStore()
        let task = SubAgentTask(
            id: "execution-identity",
            title: "execution-identity",
            instructions: "inspect",
            agentType: .external(name: "identity-runner")
        )
        let orchestrator = AgentOrchestrator(
            externalRunners: ["identity-runner": MockExternalRunner(name: "identity-runner")],
            taskStore: store,
            parentID: "identity-parent"
        )

        let reports = await orchestrator.orchestrate(tasks: [task], strategy: .sequential)

        let receipt = try #require(store.allReceipts().first)
        let envelope = try #require(receipt.childResultEnvelope)
        #expect(reports.first?.result.isSuccess == true)
        #expect(envelope.taskID == task.id)
        #expect(envelope.childExecutionID != task.id)
        #expect(envelope.childExecutionID.hasPrefix("identity-parent:execution:"))
        #expect(envelope.runID == receipt.runID)
        #expect(envelope.attemptID == receipt.attemptID)
    }

    @Test func externalMissingRunnerMarkedFailed() async {
        let tasks = makeTasks(["a"], agentType: .external(name: "nope"))

        let orchestrator = AgentOrchestrator() // 未注入任何 runner

        let reports = await orchestrator.orchestrate(tasks: tasks)

        #expect(reports.count == 1)
        #expect(reports[0].result.isSuccess == false)
        #expect(reports[0].result.error?.contains("nope") == true)
    }

    @Test func externalRunnerFailureIsolation() async {
        let mock = MockExternalRunner(name: "claude", failureMarker: "boom")
        let tasks = [
            SubAgentTask(id: "bad", title: "失败", instructions: "boom 任务", agentType: .external(name: "claude")),
            SubAgentTask(id: "ok", title: "正常", instructions: "正常任务", agentType: .external(name: "claude")),
        ]

        let orchestrator = AgentOrchestrator().withExternalRunner(mock)

        let reports = await orchestrator.orchestrate(tasks: tasks)

        #expect(reports.count == 2)
        let byID = Dictionary(uniqueKeysWithValues: reports.map { ($0.taskID, $0) })
        #expect(byID["ok"]?.result.isSuccess == true)
        #expect(byID["bad"]?.result.isSuccess == false)
    }

    @Test func mixedBuiltinAndExternal() async {
        let probe = OrchestrationProbe()
        let provider = ProbeLLMProvider(probe: probe)
        let mock = MockExternalRunner(name: "codex")
        let tasks = [
            SubAgentTask(id: "in", title: "内置", instructions: "内置任务"),
            SubAgentTask(id: "ex", title: "外部", instructions: "外部任务", agentType: .external(name: "codex")),
        ]

        let orchestrator = AgentOrchestrator()
            .withBuiltinExecution(provider: provider, toolExecutor: NoopToolExecutor())
            .withExternalRunner(mock)

        let reports = await orchestrator.orchestrate(tasks: tasks)

        #expect(reports.count == 2)
        #expect(reports[0].agentType == .builtin)
        #expect(reports[0].result.isSuccess)
        #expect(reports[1].agentType == .external(name: "codex"))
        #expect(reports[1].result.output == "mock-输出-ex")
    }

    // MARK: 外部 CLI 桥（不调真 CLI，只验证检测与自建 fake 可执行文件）

    @Test func codexMissingBinaryReportedUnavailable() {
        let runner = CodexAgentRunner(binaryPath: "/definitely/not/installed/codex")
        #expect(runner.isAvailable == false)
    }

    @Test func hermesAndClaudeMissingBinaryReportedUnavailable() {
        #expect(HermesAgentRunner(binaryPath: "/definitely/not/installed/hermes").isAvailable == false)
        #expect(ClaudeAgentRunner(binaryPath: "/definitely/not/installed/claude").isAvailable == false)
    }

    @Test func codexDetectsExecutableFakeBinary() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E23Bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bin = dir.appendingPathComponent("fake-codex")
        try "#!/bin/sh\necho fake-codex-ok\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        #expect(CodexAgentRunner(binaryPath: bin.path).isAvailable == true)
    }

    @Test func codexRunnerThrowsWhenBinaryMissing() async {
        let runner = CodexAgentRunner(binaryPath: "/definitely/not/installed/codex")
        let task = SubAgentTask(id: "t1", title: "t", instructions: "hi")
        await #expect(throws: ExternalAgentError.binaryNotFound("/definitely/not/installed/codex")) {
            try await runner.run(task: task)
        }
    }

    @Test func codexRunnerExecutesFakeBinaryAndParsesStdout() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E23Bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bin = dir.appendingPathComponent("fake-codex")
        try "#!/bin/sh\necho fake-codex-ok\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let runner = CodexAgentRunner(binaryPath: bin.path, workingDirectory: dir, timeoutSeconds: 10)
        let task = SubAgentTask(id: "t1", title: "t", instructions: "随便什么指令")
        let output = try await runner.run(task: task)
        #expect(output.contains("fake-codex-ok"))
    }

    @Test func codexRunnerReportsNonZeroExit() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E23Bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bin = dir.appendingPathComponent("fake-fail")
        try "#!/bin/sh\necho oops >&2\nexit 3\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let runner = CodexAgentRunner(binaryPath: bin.path, timeoutSeconds: 10)
        let task = SubAgentTask(id: "t1", title: "t", instructions: "hi")
        await #expect(throws: ExternalAgentError.nonZeroExit(3, "oops\n")) {
            try await runner.run(task: task)
        }
    }

    @Test func codexRunnerTimesOut() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E23Bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bin = dir.appendingPathComponent("fake-sleep")
        try "#!/bin/sh\nsleep 30\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let runner = CodexAgentRunner(binaryPath: bin.path, timeoutSeconds: 1)
        let task = SubAgentTask(id: "t1", title: "t", instructions: "hi")
        await #expect(throws: ExternalAgentError.timeout(bin.path)) {
            try await runner.run(task: task)
        }
    }

    @Test func codexRunnerTimeoutKillsDescendantHoldingPipe() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E23DescendantTimeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidFile = dir.appendingPathComponent("helper.pid")
        let entryFile = dir.appendingPathComponent("entered.txt")
        let bin = dir.appendingPathComponent("fake-descendant")
        let script = """
        #!/bin/sh
        printf entered > "\(entryFile.path)"
        sleep 30 &
        helper=$!
        trap 'kill "$helper" 2>/dev/null; wait "$helper" 2>/dev/null; exit 143' TERM INT
        printf '%s' "$helper" > "\(pidFile.path)"
        wait "$helper"
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        // An earlier 1-second timeout completed without an observed entry
        // marker. Require the child and helper to become
        // ready before judging descendant cleanup, while retaining a bounded
        // real timeout and completion deadline for the pipe-holding case.
        let runner = CodexAgentRunner(binaryPath: bin.path, timeoutSeconds: 4.0)
        let task = SubAgentTask(id: "descendant-timeout", title: "descendant-timeout", instructions: "hi")
        let started = Date()
        let invocation = Task { try await runner.run(task: task) }
        defer { invocation.cancel() }
        let readyDeadline = Date().addingTimeInterval(3)
        var helperPID: pid_t?
        var enteredBeforeTimeout = false
        var readyPollCount = 0
        var firstReadyPoll: TimeInterval?
        var lastReadyPoll: TimeInterval?
        while Date() < readyDeadline {
            let elapsed = Date().timeIntervalSince(started)
            readyPollCount += 1
            if firstReadyPoll == nil { firstReadyPoll = elapsed }
            lastReadyPoll = elapsed
            enteredBeforeTimeout = FileManager.default.fileExists(atPath: entryFile.path)
            if let value = try? String(contentsOf: pidFile),
               let parsed = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                helperPID = parsed
            }
            if enteredBeforeTimeout, helperPID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let readyBeforeTimeout = enteredBeforeTimeout && helperPID != nil
        let readyObservationEndedAt = Date().timeIntervalSince(started)
        await #expect(throws: ExternalAgentError.timeout(bin.path)) {
            try await invocation.value
        }
        #expect(Date().timeIntervalSince(started) < 5, "timeout must not wait for a descendant-held pipe")
        if !readyBeforeTimeout {
            func markerElapsed(_ file: URL) -> String {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let modified = attributes[.modificationDate] as? Date else { return "missing" }
                return String(modified.timeIntervalSince(started))
            }
            Issue.record("synthetic descendant fixture did not become ready before the timeout window; polls=\(readyPollCount) firstPoll=\(String(describing: firstReadyPoll)) lastPoll=\(String(describing: lastReadyPoll)) readyObservationEnd=\(readyObservationEndedAt) entryMTime=\(markerElapsed(entryFile)) helperPIDMTime=\(markerElapsed(pidFile)) helperObserved=\(helperPID != nil)")
        }

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, helperPID == nil {
            if let value = try? String(contentsOf: pidFile),
               let parsed = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                helperPID = parsed
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        if let helperPID {
            // A terminated child may briefly remain a zombie while its parent
            // is being reaped; allow that short handoff before asserting gone.
            let goneDeadline = Date().addingTimeInterval(1)
            while Date() < goneDeadline, kill(helperPID, 0) == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(kill(helperPID, 0) != 0, "timeout must terminate descendant helpers")
        } else {
            Issue.record("descendant helper did not publish its pid")
        }
    }

    @Test func cancellationBeforeProcessRegistrationTerminatesInvocation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("E23CancelBeforeRegister-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("fake-cancel-before-register")
        try "#!/bin/sh\nsleep 30\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let runner = CodexAgentRunner(binaryPath: bin.path, timeoutSeconds: 10)
        let task = SubAgentTask(id: "pre-cancel", title: "pre-cancel", instructions: "hi", executionID: "pre-registration-\(UUID().uuidString)")
        await runner.cancel(task: task)
        let started = Date()
        do {
            _ = try await runner.run(task: task)
            #expect(Bool(false), "pre-registration cancellation must terminate the invocation")
        } catch {
            #expect(error is ExternalAgentError)
        }
        #expect(Date().timeIntervalSince(started) < 5, "pre-registration cancellation must not wait for the CLI timeout")
    }

    @Test func nonZeroExitCleansRegistryForSubsequentInvocation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("E23CancelCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let failing = dir.appendingPathComponent("fake-fail-cleanup")
        try "#!/bin/sh\necho failure >&2\nexit 3\n".write(to: failing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failing.path)
        let succeeding = dir.appendingPathComponent("fake-success-cleanup")
        try "#!/bin/sh\necho recovered\n".write(to: succeeding, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: succeeding.path)

        let executionID = "cleanup-reuse-\(UUID().uuidString)"
        let task = SubAgentTask(id: "cleanup", title: "cleanup", instructions: "hi", executionID: executionID)
        do {
            _ = try await CodexAgentRunner(binaryPath: failing.path, timeoutSeconds: 10).run(task: task)
            #expect(Bool(false), "failing process should throw")
        } catch let error as ExternalAgentError {
            #expect(error == .nonZeroExit(3, "failure\n"))
        }
        let output = try await CodexAgentRunner(binaryPath: succeeding.path, timeoutSeconds: 10).run(task: task)
        #expect(output.contains("recovered"), "an exception path must not poison the next registry generation")
    }

    @Test func spawnFailureAfterPreCancellationCleansRegistryForNextInvocation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("E23SpawnCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let invalid = dir.appendingPathComponent("invalid-executable")
        try "not an executable format".write(to: invalid, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: invalid.path)
        let succeeding = dir.appendingPathComponent("valid-executable")
        try "#!/bin/sh\necho recovered-after-spawn-failure\n".write(to: succeeding, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: succeeding.path)

        let executionID = "spawn-cleanup-reuse-\(UUID().uuidString)"
        let task = SubAgentTask(id: "spawn-cleanup", title: "spawn-cleanup", instructions: "hi", executionID: executionID)
        let invalidRunner = CodexAgentRunner(binaryPath: invalid.path, timeoutSeconds: 10)
        await invalidRunner.cancel(task: task)
        await #expect(throws: ExternalAgentError.self) {
            _ = try await invalidRunner.run(task: task)
        }

        let output = try await CodexAgentRunner(binaryPath: succeeding.path, timeoutSeconds: 10).run(task: task)
        #expect(output.contains("recovered-after-spawn-failure"), "spawn failure must clear the cancelled registry generation")
    }

    @Test func parentCancelAndTimeoutRaceTerminatesExternalCLI() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("E23CancelTimeoutRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("fake-race")
        try "#!/bin/sh\nsleep 30\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let controller = TurnController()
        let store = AgentTaskStore()
        let runner = CodexAgentRunner(binaryPath: bin.path, timeoutSeconds: 0.05)
        let orchestrator = AgentOrchestrator(
            externalRunners: [runner.name: runner],
            taskStore: store,
            parentID: "race-parent"
        ).withChildControls(approvalGate: nil, turnController: controller)
        let task = SubAgentTask(id: "race", title: "race", instructions: "hi", agentType: .external(name: runner.name))
        let started = Date()
        let operation = Task { await orchestrator.orchestrate(tasks: [task], strategy: .sequential) }
        try await Task.sleep(for: .milliseconds(50))
        await controller.interrupt()
        let reports = await operation.value
        let receipt = try #require(store.allReceipts().first)
        let events = store.events(runID: receipt.runID)
        let terminalEvents = events.filter { event in
            event.kind == AgentTaskEventKind.completed
                || event.kind == AgentTaskEventKind.failed
                || event.kind == AgentTaskEventKind.cancelled
        }

        #expect(reports.count == 1)
        #expect(terminalEvents.count == 1, "timeout and parent cancellation must share one terminal settlement")
        switch receipt.outcome {
        case .cancelled:
            #expect(reports[0].result == SubAgentResult.failed(error: "任务已取消"))
            #expect(terminalEvents[0].kind == AgentTaskEventKind.cancelled)
        case .failed:
            #expect(reports[0].result.error?.contains("执行超时") == true)
            #expect(terminalEvents[0].kind == AgentTaskEventKind.failed)
        case .succeeded:
            Issue.record("timeout/cancellation race must not succeed")
        }
        #expect(Date().timeIntervalSince(started) < 5, "parent cancellation must win or safely race timeout without hanging")
    }

    @Test func harnessRunnerPreservesModelBindingAndDelegatesTask() async throws {
        let runner = HarnessAgentRunner(modelID: "deepseek-v4-pro") { task in
            "HARNESS_ADAPTER_OK:\(task.id)"
        }
        let task = SubAgentTask(id: "adapter-task", title: "adapter", instructions: "probe")

        #expect(runner.name == "harness:deepseek-v4-pro")
        #expect(runner.isAvailable)
        #expect(try await runner.run(task: task) == "HARNESS_ADAPTER_OK:adapter-task")
    }

    @Test func harnessModelBindingsRunAsIndependentExternalRunners() async {
        let runners: [String: any ExternalAgentRunner] = [
            "harness:deepseek-v4-pro": HarnessAgentRunner(modelID: "deepseek-v4-pro") { _ in "HARNESS_V4_OK" },
            "harness:deepseek-v3.2": HarnessAgentRunner(modelID: "deepseek-v3.2") { _ in "HARNESS_V32_OK" },
        ]
        let orchestrator = AgentOrchestrator(externalRunners: runners)
        let reports = await orchestrator.orchestrate(tasks: [
            SubAgentTask(id: "v4", title: "v4", instructions: "probe", agentType: .external(name: "harness:deepseek-v4-pro")),
            SubAgentTask(id: "v32", title: "v32", instructions: "probe", agentType: .external(name: "harness:deepseek-v3.2")),
        ])

        #expect(reports.count == 2)
        #expect(reports[0].result.output == "HARNESS_V4_OK")
        #expect(reports[1].result.output == "HARNESS_V32_OK")
    }

    @Test func hermesDefaultRunnerUsesSupportedOneShotFlag() {
        let task = SubAgentTask(id: "hermes-args", title: "hermes", instructions: "A1_PROBE")
        let runner = HermesAgentRunner()

        #expect(runner.argumentBuilder(task) == ["-z", "A1_PROBE"])
    }

    @Test func defaultRunnersIncludeCodexHermesClaude() {
        let runners = AgentOrchestrator.makeDefaultRunners()
        #expect(runners["codex"] != nil)
        #expect(runners["hermes"] != nil)
        #expect(runners["claude"] != nil)
    }

    @Test func parentSnapshotIdentityIncludesAllBindingMetadata() {
        let base = ParentContextSnapshotV1(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "fp-a",
            profileID: "profile-a",
            baseHost: "api.example.test",
            wireAPI: "responses",
            reasoningConfiguration: "high",
            conversationID: "conversation-a"
        )
        let changedWire = ParentContextSnapshotV1(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "fp-a",
            profileID: "profile-a",
            baseHost: "api.example.test",
            wireAPI: "chat-completions",
            reasoningConfiguration: "high",
            conversationID: "conversation-a"
        )

        #expect(base.snapshotID != changedWire.snapshotID)
        #expect(base.matches(base))
        #expect(!base.matches(changedWire))
    }

    @Test func productionChildMutationsExplicitlyDisabledBeforeProvider() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("goal18-default-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provider = ScriptedChildProvider(responses: ["must not start"])
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let orchestrator = AgentOrchestrator(
            provider: provider, toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            turnController: controller, taskStore: AgentTaskStore(), parentID: "goal18-default-parent",
            parentTurnHandle: turn, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools],
                allowedToolNames: ["file_read", "file_write", "file_edit", "file_delete", "shell_execute"]),
            parentCapabilities: [.tools], childMutationsEnabled: false)
        #expect(orchestrator.childMutationsEnabled == false)
        let tasks = ["file_write", "file_edit", "file_delete", "shell_execute"].map { name in
            SubAgentTask(id: name, title: name, instructions: "must not execute", requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(allowedToolNames: [name], allowedReadRoots: [root.path]))
        }
        let reports = await orchestrator.orchestrate(tasks: tasks, strategy: .sequential)
        #expect(reports.count == 4)
        #expect(reports.allSatisfy { $0.result.error == "CHILD_MUTATIONS_DISABLED" })
        #expect(provider.receivedRequests.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func disabledLiveChildContextKeepsRetryMutationsDisabledBeforeProvider() async throws {
        final class CapturedContext: @unchecked Sendable {
            private let lock = NSLock()
            private var value: AgentExecutionContextSnapshot?
            func record(_ context: AgentExecutionContextSnapshot) { lock.withLock { value = context } }
            var snapshot: AgentExecutionContextSnapshot? { lock.withLock { value } }
        }
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("disabled-child-retry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "disabled-child-retry-source")
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id, conversationID: source.id,
            taskID: "disabled-child-retry-parent", actorID: "owned-fixture").makeIdentity(using: turn)
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let ledger = try minisCoreToolContractLedger(at: root)
        let captured = CapturedContext()
        let provider = ScopedReadProbeProvider(path: root.appendingPathComponent("unused.txt").path,
            marker: "unused", onFirstToolOffer: {
                guard let context = AgentExecutionContext.current else {
                    Issue.record("real child provider must receive its execution context")
                    return
                }
                captured.record(context)
            })
        let policy = AgentCapabilityPolicy(allowedCapabilities: [.tools],
            allowedToolNames: ["file_read", "file_write"])
        let orchestrator = AgentOrchestrator(provider: provider, toolExecutor: owner,
            turnController: controller, currentConversationID: source.id,
            taskStore: AgentTaskStore(), sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentTurnHandle: turn,
            runtimeMode: .production, capabilityPolicy: policy, parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner), childMutationsEnabled: false)
        let reports = await orchestrator.orchestrate(tasks: [SubAgentTask(id: "read-only-child",
            title: "read-only child", instructions: "read-no-file", requiredCapabilities: [.tools])], strategy: .sequential)
        #expect(reports.first?.result.isSuccess == true)
        let context = try #require(captured.snapshot)
        #expect(!context.childMutationsEnabled)
        #expect(provider.offeredToolNameSets == [["file_read"]])
        let retryProvider = ScriptedChildProvider(responses: ["must not start"])
        // The App's retry factory consumes this actual child context field.
        // Keep a live parent handle for this synthetic retry; no file tool runs.
        let retry = AgentOrchestrator(provider: retryProvider, toolExecutor: owner,
            turnController: controller, currentConversationID: source.id,
            taskStore: AgentTaskStore(), sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentTurnHandle: turn,
            runtimeMode: .production, capabilityPolicy: policy, parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            childMutationsEnabled: context.childMutationsEnabled)
        let retried = await retry.orchestrate(tasks: [SubAgentTask(id: "disabled-retry",
            title: "disabled retry", instructions: "must not execute", requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_write"],
                allowedReadRoots: [root.path], allowedWriteRoots: [root.path]))], strategy: .sequential)
        #expect(retried.first?.result.error == "CHILD_MUTATIONS_DISABLED")
        #expect(retryProvider.receivedRequests.isEmpty)
        #expect(ledger.facts.isEmpty)
    }

    @Test func childResultPagesAreReadOnlyBoundedAndComplete() throws {
        let output = String(repeating: "结果🙂", count: 4_000)
        let envelope = ChildResultEnvelope(taskID: "child", runID: "run", attemptID: "attempt",
            parentContextSnapshotID: nil, childExecutionID: "execution", outcome: .succeeded,
            outputDigest: "digest", output: output)
        var offset = 0
        var recovered = ""
        repeat {
            let text = try OrchestrationToolExecutor.makeResultPage(envelope: envelope, offset: offset)
            let page = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let content = try #require(page["content"] as? String)
            #expect(content.count <= OrchestrationToolExecutor.resultPageCharacters)
            #expect(content.utf8.count <= 16_384)
            #expect(page["read_only"] as? Bool == true)
            #expect(page["run_id"] as? String == "run")
            #expect(text.utf8.count < MCPOutputLimiter.defaultMaximumCharacters)
            recovered += content
            guard let next = page["next_offset"] as? Int else { break }
            #expect(next > offset)
            offset = next
        } while true
        #expect(recovered == output)
        #expect(throws: ToolExecutorError.invalidParameter("offset")) {
            try OrchestrationToolExecutor.makeResultPage(envelope: envelope, offset: -1)
        }
        #expect(throws: ToolExecutorError.invalidParameter("offset")) {
            try OrchestrationToolExecutor.makeResultPage(envelope: envelope, offset: output.count + 1)
        }
    }

    @Test func childResultExplicitByteLimitPreservesGraphemesAndSentenceSummary() throws {
        let sentence = "这是一条有真实内容的合成结果，说明完成事项与下一步。"
        let output = String(repeating: sentence, count: 180) + "结尾🙂e\u{301}。"
        let envelope = ChildResultEnvelope(taskID: "child", runID: "run", attemptID: "attempt",
            parentContextSnapshotID: nil, childExecutionID: "execution", outcome: .succeeded,
            outputDigest: "digest", output: output)
        var offset = 0, recovered = ""
        repeat {
            let raw = try OrchestrationToolExecutor.makeResultPage(envelope: envelope, offset: offset, limit: 137)
            let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            let content = try #require(object["content"] as? String)
            #expect(!content.isEmpty && content.utf8.count <= 137)
            recovered += content
            guard let next = object["next_offset"] as? Int else { break }
            #expect(next == offset + content.count && next > offset)
            offset = next
        } while true
        #expect(recovered == output)
        let summary = OrchestrationToolExecutor.resultSummary(output)
        #expect(summary.utf8.count >= 1_024 && summary.utf8.count <= 3_072)
        #expect(summary.hasSuffix("。\n可用 child_result 取全文。"))
        #expect(!summary.contains("长句节选"))
        #expect(OrchestrationToolExecutor.resultSummary("短结果。") == "短结果。")
        for limit in [0, 16_385] {
            #expect(throws: ToolExecutorError.invalidParameter("limit")) {
                try OrchestrationToolExecutor.makeResultPage(envelope: envelope, offset: 0, limit: limit)
            }
        }
        // Historical records have no measurements. Decode must not invent zero.
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(ChildResultEnvelope.self, from: data)
        #expect(decoded.tokenUsage == nil)
    }

    @Test func fullResultKeepsTrailingTextWhenShortPathRedactionExpands() throws {
        let envelope = ChildResultEnvelope(taskID: "child", runID: "run", attemptID: "attempt",
            parentContextSnapshotID: nil, childExecutionID: "execution", outcome: .succeeded,
            outputDigest: "digest", output: "/a /b final-tail")
        let result = try OrchestrationToolExecutor.makeResultPage(envelope: envelope, offset: 0)
        let page = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let content = try #require(page["content"] as? String)
        #expect(content.hasSuffix("final-tail"))
        #expect(!content.contains("/a") && !content.contains("/b"))
    }

    @Test func childResultToolRejectsUnboundCallerWithoutDispatch() async {
        let provider = ScriptedChildProvider(responses: ["must not start"])
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator(provider: provider))
        do {
            _ = try await executor.execute(name: OrchestrationToolExecutor.resultToolName,
                input: ["task_id": "child", "parent_id": "parent", "run_id": "run"])
            Issue.record("unbound read must fail closed")
        } catch { #expect(error as? ToolExecutorError == .invalidParameter("child_result_owner")) }
        #expect(provider.receivedRequests.isEmpty)
    }

    @Test func physicalFileLeaseCanBeBorrowedOnlyOnceByExactReceipt() {
        let receipt = ToolExecutionReceipt(toolCallID: "call", receiptID: "receipt", toolName: "file_write",
            attemptID: "attempt", attemptNumber: 1)
        let foreign = ToolExecutionReceipt(toolCallID: "foreign", receiptID: "foreign", toolName: "file_write",
            attemptID: "attempt", attemptNumber: 1)
        let lease = ToolFileMutationLease(key: "/owned/file", token: UUID(), receipt: receipt)
        #expect(!lease.claimBuiltinUse(key: "/owned/sibling", receipt: receipt))
        #expect(!lease.claimBuiltinUse(key: "/owned/file", receipt: foreign))
        #expect(lease.claimBuiltinUse(key: "/owned/file", receipt: receipt))
        #expect(!lease.claimBuiltinUse(key: "/owned/file", receipt: receipt))
        let expired = ToolFileMutationLease(key: "/owned/file", token: UUID(), receipt: receipt)
        expired.invalidate()
        #expect(!expired.claimBuiltinUse(key: "/owned/file", receipt: receipt))
    }

    @Test func childMutationRolloutGateSurvivesCompositionCopies() {
        let original = AgentOrchestrator(childMutationsEnabled: true)
        let controlled = original.withChildControls(approvalGate: nil, turnController: nil)
        #expect(controlled.childMutationsEnabled)
        let defaultControlled = AgentOrchestrator().withChildControls(approvalGate: nil, turnController: nil)
        #expect(defaultControlled.childMutationsEnabled)
    }

    @Test func productionBuiltinScopeRejectsEmptyAndEscapingDeclarationsBeforeProvider() async {
        let probe = OrchestrationProbe()
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        let root = URL(fileURLWithPath: "/tmp/dev154-parent", isDirectory: true)
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        let provider = ProbeLLMProvider(probe: probe)
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: [denied]),
            turnController: controller,
            taskStore: AgentTaskStore(), parentID: "scope-parent",
            parentTurnHandle: parentHandle,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
            ),
            parentCapabilities: [.tools]
        )
        let tasks = [
            SubAgentTask(id: "empty-tools", title: "empty-tools", instructions: "read", requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(allowedToolNames: [], allowedReadRoots: [])),
            SubAgentTask(id: "sibling", title: "sibling", instructions: "read", requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read"], allowedReadRoots: ["/tmp/dev154-sibling"])),
            SubAgentTask(id: "denied", title: "denied", instructions: "read", requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read"], allowedReadRoots: ["/tmp/dev154-parent/denied"])),
            SubAgentTask(id: "duplicate", title: "duplicate", instructions: "read", requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read", "file_read"], allowedReadRoots: ["/tmp/dev154-parent/a"])),
            SubAgentTask(id: "unknown", title: "unknown", instructions: "read", requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(allowedToolNames: ["unknown_tool"], allowedReadRoots: [])),
            SubAgentTask(id: "empty-roots", title: "empty-roots", instructions: "read", requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read"], allowedReadRoots: [])),
            SubAgentTask(id: "traversal", title: "traversal", instructions: "read", requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read"], allowedReadRoots: ["/tmp/dev154-parent/../escape"])),
            SubAgentTask(id: "no-tools", title: "no-tools", instructions: "read",
                resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read"], allowedReadRoots: ["/tmp/dev154-parent/a"]))
        ]
        let reports = await orchestrator.orchestrate(tasks: tasks, strategy: .sequential)
        #expect(reports.count == tasks.count)
        #expect(reports[0].result.error == "TASK_RESOURCE_SCOPE_INVALID")
        #expect(reports[1].result.error == "TASK_RESOURCE_SCOPE_INVALID")
        #expect(reports[2].result.error == "TASK_RESOURCE_SCOPE_INVALID")
        #expect(reports[3].result.error == "TASK_RESOURCE_SCOPE_INVALID")
        #expect(reports[4].result.error == "TASK_RESOURCE_SCOPE_INVALID")
        #expect(reports[5].result.error?.contains("TASK_RESOURCE_SCOPE_REQUIRED") == true)
        #expect(reports[6].result.error == "TASK_RESOURCE_SCOPE_INVALID")
        #expect(reports[7].result.error == "TASK_RESOURCE_SCOPE_INVALID")
        #expect(await probe.maxActive == 0)
    }

    @Test func productionBuiltinScopeRejectsSymlinkOutsideParent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreScopeSymlink-\(UUID().uuidString)", isDirectory: true)
        let parentRoot = directory.appendingPathComponent("parent", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: parentRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = parentRoot.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        let provider = ProbeLLMProvider(probe: OrchestrationProbe())
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: BuiltinToolExecutor(allowedRoot: parentRoot, deniedRoots: []),
            turnController: controller,
            taskStore: AgentTaskStore(), parentID: "symlink-parent",
            parentTurnHandle: parentHandle,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
            ), parentCapabilities: [.tools]
        )
        let task = SubAgentTask(id: "escape", title: "escape", instructions: "read",
            requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(
                allowedToolNames: ["file_read"], allowedReadRoots: [link.path]))
        let reports = await orchestrator.orchestrate(tasks: [task], strategy: .sequential)
        #expect(reports[0].result.error == "TASK_RESOURCE_SCOPE_INVALID")
    }

    @Test("effect recovery preserves original child identity without authorizing a retry")
    func pendingEffectOriginAndLegacyRecovery842() throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("effect842-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("facts.json")
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let parent = ParentRuntimeIdentity(sessionID: "842-parent-session", conversationID: "842-conversation",
            turnID: "turn-handle:3", taskID: "842-parent-task", actorID: "owned-test")
        let locator = ChildTranscriptLocator(childSessionID: "842-child-session", parentSessionID: parent.sessionID,
            taskID: "842-child-task", parentID: parent.taskID, runID: "842-run", attemptID: "842-canonical-attempt",
            childExecutionID: "842-child-execution", parentContextSnapshotID: "842-context")
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: locator.childSessionID,
            turnID: 3, messageID: locator.taskID), operationID: "842-operation", attempt: 1)
        let pending = try ledger.mint(toolCallID: "842-uncertain", toolName: "file_write",
            attemptID: "842-tool-attempt", attemptNumber: 1, executionIdentity: identity,
            parentRuntimeIdentity: parent, childTranscriptLocator: locator)
        // Simulate durable takeover at the pending barrier, not a claim that no
        // external effect occurred. Recovery cannot make the same call executable.
        let reopened = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reopened.recoveredPendingReceipts == [pending])
        #expect(reopened.facts.isEmpty)
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID(pending.toolCallID)) {
            try reopened.mint(toolCallID: pending.toolCallID, toolName: pending.toolName,
                attemptID: pending.attemptID, attemptNumber: pending.attemptNumber,
                executionIdentity: identity, parentRuntimeIdentity: parent, childTranscriptLocator: locator)
        }
        #expect(throws: ToolExecutionFactLedgerError.staleWriter) {
            try ledger.settle(pending, status: .succeeded)
        }
        #expect(throws: ToolExecutionFactLedgerError.externalOutcomeUnverified) {
            try reopened.reconcilePending()
        }
        #expect(reopened.pendingReceipts == [pending] && reopened.facts.isEmpty)
        #expect(reopened.pendingReceipts.first?.parentRuntimeIdentity == parent)
        #expect(reopened.pendingReceipts.first?.childTranscriptLocator == locator)
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID(pending.toolCallID)) {
            try reopened.mint(toolCallID: pending.toolCallID, toolName: pending.toolName,
                attemptID: pending.attemptID, attemptNumber: pending.attemptNumber, executionIdentity: identity)
        }
        let legacy = try reopened.mint(toolCallID: "842-legacy", toolName: "file_read",
            attemptID: "842-tool-attempt", attemptNumber: 1, executionIdentity: identity)
        let legacyFact = try #require(try reopened.settle(legacy, status: .succeeded))
        #expect(legacyFact.parentRuntimeIdentity == nil && legacyFact.childTranscriptLocator == nil)
        let final = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(final.facts == [legacyFact] && final.pendingReceipts == [pending])
    }

    @Test("foreign or partial child provenance fails before mint and on durable reopen")
    func foreignEffectOriginFailsClosed842() throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("effect842-foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("facts.json")
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let parent = ParentRuntimeIdentity(sessionID: "842-source", conversationID: "842-source",
            turnID: "turn-handle:2", taskID: "842-parent", actorID: "owned-test")
        let foreign = ParentRuntimeIdentity(sessionID: parent.sessionID, conversationID: parent.conversationID,
            turnID: parent.turnID, taskID: "842-other-parent", actorID: parent.actorID)
        let locator = ChildTranscriptLocator(childSessionID: "842-child-session", parentSessionID: parent.sessionID,
            taskID: "842-child", parentID: parent.taskID, runID: "842-run", attemptID: "842-task-attempt",
            childExecutionID: "842-execution", parentContextSnapshotID: nil)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: locator.childSessionID,
            turnID: 2, messageID: locator.taskID), operationID: "842-operation", attempt: 1)
        let foreignTurn = ParentRuntimeIdentity(sessionID: parent.sessionID, conversationID: parent.conversationID,
            turnID: "turn-handle:99", taskID: parent.taskID, actorID: parent.actorID)
        for origin in [Optional(foreign), Optional(foreignTurn), nil] {
            #expect(throws: ToolExecutionFactLedgerError.invalidCanonicalIdentity) {
                try ledger.mint(toolCallID: "842-invalid", toolName: "file_write", attemptID: "842-tool-attempt",
                    attemptNumber: 1, executionIdentity: identity,
                    parentRuntimeIdentity: origin, childTranscriptLocator: locator)
            }
        }
        #expect(ledger.pendingReceipts.isEmpty && ledger.facts.isEmpty)
        let receipt = try ledger.mint(toolCallID: "842-valid", toolName: "file_write", attemptID: "842-tool-attempt",
            attemptNumber: 1, executionIdentity: identity, parentRuntimeIdentity: parent, childTranscriptLocator: locator)
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var pending = try #require(payload["pending"] as? [String: Any])
        let key = try #require(pending.keys.first)
        var record = try #require(pending[key] as? [String: Any])
        record["parentRuntimeIdentity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(foreign))
        pending[key] = record; payload["pending"] = pending
        let corrupt = root.appendingPathComponent("foreign-copy.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: corrupt)
        #expect(throws: ToolExecutionFactLedgerError.corruptLedger) {
            _ = try ToolExecutionFactLedger(persistenceURL: corrupt)
        }
        #expect(try ToolExecutionFactLedger(persistenceURL: url).pendingReceipts == [receipt])
    }

    @Test(arguments: [false, true])
    func productionEffectRetainsCanonicalChildOrigin842(replay: Bool) async throws {
        actor Approval: ApprovalDelegate {
            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                ApprovalDecision(approved: true, confirmed: true,
                    requestID: request.requestID, bindingDigest: request.identityDigest)
            }
        }
        struct Origin: Decodable {
            let parentRuntimeIdentity: ParentRuntimeIdentity?
            let childTranscriptLocator: ChildTranscriptLocator?
        }
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("effect842-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "842-source")
        let taskURL = root.appendingPathComponent("tasks.json")
        let factURL = root.appendingPathComponent("facts.json")
        let tasks = try AgentTaskStore(persistenceURL: taskURL)
        let ledger = try ToolExecutionFactLedger(persistenceURL: factURL)
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id,
            conversationID: source.id, taskID: "842-parent", actorID: "owned-test")
            .makeIdentity(using: turn)
        let output = root.appendingPathComponent("effect.txt")
        try "owned read effect842\n".write(to: output, atomically: true, encoding: .utf8)
        let call = orchEnvelope(id: "842-one-effect", name: "file_read",
            input: ["path": output.path])
        let provider = ScriptedChildProvider(responses: replay ? [call, call, "done"] : [call, "done"])
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let reader = ScopedForwardingExecutor(base: builtin)
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 3,
            provider: provider, toolExecutor: reader,
            approvalGate: ApprovalGate(policyByTool: ["file_read": .alwaysAsk, "file_write": .alwaysAsk], delegate: Approval()),
            turnController: controller, makeLoopDetector: { nil }, currentConversationID: source.id,
            taskStore: tasks, sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentTurnHandle: turn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: ["file_read", "file_write"]),
            parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: builtin),
            concreteBuiltinToolExecutorOwner: builtin)
        let reports = await orchestrator.orchestrate(tasks: [SubAgentTask(id: "842-child",
            title: "owned effect", instructions: "read owned file", requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read"],
                allowedReadRoots: [root.path]))], strategy: .sequential)
        #expect(reports.count == 1 && reports.first?.result.isSuccess == true)
        #expect(try String(contentsOf: output, encoding: .utf8) == "owned read effect842\n")
        #expect(reader.invokedNames == ["file_read"])
        #expect(provider.receivedRequests.count == (replay ? 3 : 2))
        let received = try #require(provider.receivedRequests.dropFirst().first?.last)
        let parts = try #require(JSONSerialization.jsonObject(with: Data(received.content.utf8)) as? [[String: Any]])
        #expect(parts.count == 1 && parts.first?["tool_use_id"] as? String == "842-one-effect")
        #expect(parts.first?["content"] as? String == "owned read effect842\n")
        #expect(parts.first?["is_error"] as? Bool == false)
        if replay {
            let late = try #require(provider.receivedRequests.last?.last)
            let denied = try #require(JSONSerialization.jsonObject(with: Data(late.content.utf8)) as? [[String: Any]])
            #expect(denied.count == 1 && denied.first?["tool_use_id"] as? String == "842-one-effect")
            #expect(denied.first?["is_error"] as? Bool == true)
            #expect(denied.first?["content"] as? String == "Error executing tool file_read: 审批已被消费（请求 842-one-effect），请重新发起")
        }
        #expect(ledger.facts.count == 1 && ledger.pendingReceipts.isEmpty)
        let fact = try #require(ledger.facts.first)
        #expect(fact.status == .succeeded && fact.toolCallID == "842-one-effect")
        let childReceipt = try #require(tasks.allReceipts().first)
        let locator = try #require(childReceipt.childResultEnvelope?.childTranscriptLocator)
        let origin = try JSONDecoder().decode(Origin.self, from: JSONEncoder().encode(fact))
        #expect(origin.parentRuntimeIdentity == parent)
        #expect(origin.childTranscriptLocator == locator)
        let activities = tasks.childToolActivities(taskID: locator.taskID, parentID: locator.parentID, runID: locator.runID)
        #expect(activities.count == (replay ? 2 : 1))
        #expect(activities.allSatisfy { $0.toolName == "file_read" && $0.phase == "requested" && $0.attemptID == locator.attemptID })
        #expect(tasks.childToolActivities(taskID: locator.taskID, parentID: "foreign-parent", runID: locator.runID).isEmpty)
        let resultReader = OrchestrationToolExecutor(orchestrator: orchestrator)
        // Registered production definition -> actual Composer classifier. Plan
        // returns dryRun for effects; execute here proves the read-only lane.
        let resultDefinition = try #require(AgentToolCatalog.makeTools(
            orchestration: OrchestrationToolExecutor.makeDefinition()).first {
                $0.name == OrchestrationToolExecutor.resultToolName
            })
        let resultInput: [String: Any] = ["task_id": locator.taskID, "parent_id": locator.parentID,
            "run_id": locator.runID, "attempt_id": locator.attemptID]
        let stamp = Date()
        let readFacts = ComposerPolicyFactSource(knownCapabilities: [resultDefinition.name, "file_write"],
            grantedCapabilities: [resultDefinition.name, "file_write"], allowedWriteRoots: [root.path],
            workspaceID: root.path, revision: "result842", leaseID: "result842",
            expiresAt: stamp.addingTimeInterval(60), autonomyCeiling: .l3)
        let readSnapshot = ComposerSubmissionSnapshot(mode: .plan, approvalScope: .request, effort: .standard,
            sessionID: source.id, turnID: 1, taskID: parent.taskID, messageID: "result842",
            workspaceID: root.path, createdAt: stamp, policyRevision: "result842", autonomyCeiling: .l3)
        let classification = ComposerAuthorizationController(snapshot: readSnapshot, facts: readFacts, now: { stamp })
        let typedReadInput = try ComposerToolInput(resultInput)
        let typedWriteInput = try ComposerToolInput(["path": output.path, "content": "never-written"])
        #expect(try await classification.authorize(capability: resultDefinition.name, input: typedReadInput) == .execute)
        #expect(try await classification.authorize(capability: "file_write", input: typedWriteInput) == .dryRun)
        let readGate = ApprovalGate()
        #expect(readGate.isKnownTool(resultDefinition.name))
        #expect(readGate.riskLevel(for: resultDefinition.name) == .low)
        #expect(!readGate.shouldAsk(tool: resultDefinition.name, input: resultInput))
        let readDecision = try await readGate.gate(tool: resultDefinition.name, input: resultInput)
        #expect(readDecision.approved)
        let readContext = AgentExecutionContextSnapshot(provider: provider, approvalGate: nil,
            turnController: controller, currentConversationID: source.id, makeChildBudget: nil, deadline: nil,
            parentTurnHandle: turn, parentRuntimeIdentity: parent)
        let receiptsBeforeRead = tasks.allReceipts()
        let resultText = try await AgentExecutionContext.$current.withValue(readContext) {
            try await resultReader.execute(name: OrchestrationToolExecutor.resultToolName,
                input: resultInput)
        }
        let resultPage = try #require(JSONSerialization.jsonObject(with: Data(resultText.utf8)) as? [String: Any])
        #expect(resultPage["content"] as? String == reports.first?.result.output)
        #expect(tasks.allReceipts() == receiptsBeforeRead)
        do {
            _ = try await AgentExecutionContext.$current.withValue(readContext) {
                try await resultReader.execute(name: OrchestrationToolExecutor.resultToolName,
                    input: ["task_id": locator.taskID, "parent_id": "foreign-parent", "run_id": locator.runID, "attempt_id": locator.attemptID])
            }
            Issue.record("foreign parent cannot read child output")
        } catch { #expect(error as? ToolExecutorError == .invalidParameter("child_result_owner")) }
        // Keep the exact real task/run/attempt and change only the caller's
        // genuinely different owner session. An ID from another session is
        // not made readable by knowing its complete output_ref.
        let foreignSID = UUID().uuidString
        _ = try sessions.createSession(id: foreignSID, title: "foreign owner842")
        let foreignParent = try ParentRuntimeIdentitySeed(sessionID: foreignSID,
            conversationID: foreignSID, taskID: parent.taskID, actorID: "foreign-owned-test")
            .makeIdentity(using: turn)
        let foreignContext = AgentExecutionContextSnapshot(provider: provider, approvalGate: nil,
            turnController: controller, currentConversationID: foreignSID, makeChildBudget: nil, deadline: nil,
            parentTurnHandle: turn, parentRuntimeIdentity: foreignParent)
        #expect(foreignContext.hasVerifiedParentRuntime)
        let requestsBeforeForeign = provider.receivedRequests.count
        let factsBeforeForeign = ledger.facts
        let bytesBeforeForeign = try Data(contentsOf: output)
        do {
            _ = try await AgentExecutionContext.$current.withValue(foreignContext) {
                try await resultReader.execute(name: resultDefinition.name, input: resultInput)
            }
            Issue.record("foreign owner session cannot read an owned child's exact output_ref")
        } catch { #expect(error as? ToolExecutorError == .invalidParameter("child_result_owner")) }
        #expect(tasks.allReceipts() == receiptsBeforeRead)
        #expect(provider.receivedRequests.count == requestsBeforeForeign)
        #expect(reader.invokedNames == ["file_read"])
        #expect(ledger.facts == factsBeforeForeign && ledger.pendingReceipts.isEmpty)
        #expect(try Data(contentsOf: output) == bytesBeforeForeign)
        #expect(fact.compositeKey?.sessionID == locator.childSessionID)
        #expect(fact.compositeKey?.messageID == locator.taskID)
        #expect(fact.attemptID != locator.attemptID)
        // An explicit empty write ceiling still denies before the Provider,
        // even though inherited writes are now supported.
        let priorRequests = provider.receivedRequests.count
        let deniedWrite = await orchestrator.orchestrate(tasks: [SubAgentTask(id: "842-write-denied",
            title: "must remain denied", instructions: "must not write", requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_write"], allowedReadRoots: [],
                allowedWriteRoots: []))],
            strategy: .sequential)
        #expect(deniedWrite.first?.result.isSuccess == false)
        #expect(provider.receivedRequests.count == priorRequests && reader.invokedNames == ["file_read"])
        #expect(ledger.facts == [fact] && ledger.pendingReceipts.isEmpty)
        // Original run ownership remains exact even when the task's current locator is cleared.
        _ = try tasks.startRun(taskID: locator.taskID, parentID: locator.parentID, runID: "842-next-run")
        #expect(tasks.taskSnapshot(runID: "842-next-run")?.childTranscriptLocator == nil)
        let reopenedTasks = try AgentTaskStore(persistenceURL: taskURL)
        let reopenedFacts = try ToolExecutionFactLedger(persistenceURL: factURL)
        #expect(reopenedFacts.facts == [fact])
        #expect(reopenedTasks.historicalRunIdentity(runID: locator.runID,
            taskID: locator.taskID, parentID: locator.parentID)?.attemptID == locator.attemptID)
        let reopenedOrigin = try JSONDecoder().decode(Origin.self, from: JSONEncoder().encode(try #require(reopenedFacts.facts.first)))
        #expect(reopenedOrigin.parentRuntimeIdentity == parent && reopenedOrigin.childTranscriptLocator == locator)
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID(fact.toolCallID)) {
            try reopenedFacts.mint(toolCallID: fact.toolCallID, toolName: fact.toolName,
                attemptID: fact.attemptID, attemptNumber: fact.attemptNumber, executionIdentity: fact.executionIdentity)
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == "owned read effect842\n")
    }

    @Test func productionBuiltinFileReadUsesEachTasksOwnRoot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTaskScope-\(UUID().uuidString)", isDirectory: true)
        let own = directory.appendingPathComponent("own", isDirectory: true)
        let sibling = directory.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "DEV154_SCOPE_MARKER_\(UUID().uuidString)"
        let file = own.appendingPathComponent("fixture.txt")
        try marker.write(to: file, atomically: true, encoding: .utf8)

        let sessions = SessionStore(directory: directory)
        let source = try sessions.createSession(id: "scope-source")
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        let parent = ParentRuntimeIdentity(
            sessionID: source.id, conversationID: source.id,
            turnID: "turn-handle:\(parentHandle.turnID)",
            taskID: "scope-parent", actorID: "synthetic-test"
        )
        let provider = ScopedReadProbeProvider(path: file.path, marker: marker)
        let concrete = BuiltinToolExecutor(allowedRoot: directory, deniedRoots: [])
        let wrapped = ScopedForwardingExecutor(base: concrete)
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: wrapped,
            turnController: controller, currentConversationID: source.id,
            taskStore: AgentTaskStore(), sessionStore: sessions,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: directory),
            parentID: parent.taskID, parentRuntimeIdentity: parent,
            parentTurnHandle: parentHandle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read", "session_read"]
            ),
            parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: concrete),
            concreteBuiltinToolExecutorOwner: concrete
        )
        let tasks = [
            SubAgentTask(id: "own", title: "own", instructions: "read-own",
                requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(
                    allowedToolNames: ["file_read"], allowedReadRoots: [own.path])),
            SubAgentTask(id: "cross", title: "cross", instructions: "read-cross",
                requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(
                    allowedToolNames: ["file_read"], allowedReadRoots: [sibling.path])),
            SubAgentTask(id: "no-file-tool", title: "no-file-tool", instructions: "read-no-file",
                requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(
                    allowedToolNames: ["session_read"], allowedReadRoots: []))
        ]
        let reports = await orchestrator.orchestrate(tasks: tasks, strategy: .sequential)
        #expect(reports.map { $0.result.output ?? "" } == ["read-ok", "read-blocked", "no-file-task-finished"])
        #expect(provider.offeredToolNameSets.contains(["file_read"]))
        #expect(provider.offeredToolNameSets.contains(["session_read"]))
        #expect(!provider.offeredToolNameSets.contains(["file_read", "session_read"]))
        #expect(wrapped.invokedNames == ["file_read"])
    }

    @Test(arguments: [false, true])
    func productionBuiltinFrozenReadRootCannotFollowRetargetedDirectory(_ retargetRoot: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreFrozenChildRoot436-\(UUID().uuidString)", isDirectory: true)
        let own = directory.appendingPathComponent("own", isDirectory: true)
        let preservedOwn = directory.appendingPathComponent("original-own", isDirectory: true)
        let sibling = directory.appendingPathComponent("own-peer", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let allowedMarker = "CHILD_ALLOWED_\(UUID().uuidString)"
        let outsideMarker = "CHILD_UNDECLARED_\(UUID().uuidString)"
        let requestedFile = own.appendingPathComponent("fixture.txt")
        let siblingFile = sibling.appendingPathComponent("fixture.txt")
        try allowedMarker.write(to: requestedFile, atomically: true, encoding: .utf8)
        try outsideMarker.write(to: siblingFile, atomically: true, encoding: .utf8)

        let sessions = SessionStore(directory: directory)
        let source = try sessions.createSession(id: "frozen-root-source")
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        defer { Task { await parentHandle.finish() } }
        let parent = ParentRuntimeIdentity(
            sessionID: source.id, conversationID: source.id,
            turnID: "turn-handle:\(parentHandle.turnID)",
            taskID: "frozen-root-parent", actorID: "synthetic-test"
        )
        // Run after the real child catalog and executor have been constructed,
        // before the provider's tool call. No timing race or sleeps are needed.
        let provider = ScopedReadProbeProvider(
            path: requestedFile.path, marker: retargetRoot ? outsideMarker : allowedMarker
        ) {
            guard retargetRoot else { return }
            do {
                try FileManager.default.moveItem(at: own, to: preservedOwn)
                try FileManager.default.createSymbolicLink(at: own, withDestinationURL: sibling)
            } catch {
                Issue.record("Synthetic root retarget failed: \(error)")
            }
        }
        let owner = BuiltinToolExecutor(allowedRoot: directory, deniedRoots: [])
        let wrapped = ScopedForwardingExecutor(base: owner)
        let orchestrator = AgentOrchestrator(
            provider: provider, toolExecutor: wrapped,
            turnController: controller, currentConversationID: source.id,
            taskStore: AgentTaskStore(), sessionStore: sessions,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: directory),
            parentID: parent.taskID, parentRuntimeIdentity: parent,
            parentTurnHandle: parentHandle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read", "session_read"]
            ), parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            concreteBuiltinToolExecutorOwner: owner
        )
        let task = SubAgentTask(
            id: "frozen-root", title: "frozen-root", instructions: "read declared file",
            requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(
                allowedToolNames: ["file_read"], allowedReadRoots: [own.path]
            )
        )
        let reports = await orchestrator.orchestrate(tasks: [task], strategy: .sequential)
        #expect(reports.first?.result.output == (retargetRoot ? "read-blocked" : "read-ok"))
        #expect(!provider.offeredToolNameSets.isEmpty)
        #expect(provider.offeredToolNameSets.allSatisfy { $0 == ["file_read"] })
        #expect(wrapped.invokedNames == (retargetRoot ? [] : ["file_read"]))
        if retargetRoot {
            #expect(own.resolvingSymlinksInPath().path == sibling.resolvingSymlinksInPath().path)
            let preserved = try String(contentsOf: preservedOwn.appendingPathComponent("fixture.txt"), encoding: .utf8)
            #expect(preserved == allowedMarker)
        }
        let outside = try String(contentsOf: siblingFile, encoding: .utf8)
        #expect(outside == outsideMarker)
    }

    @Test func productionBuiltinAncestorRootEnforcesCeilingDeniedDescendant() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreCeilingDescendant-\(UUID().uuidString)", isDirectory: true)
        let denied = directory.appendingPathComponent("secret", isDirectory: true)
        let sibling = directory.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let deniedMarker = "CEILING_DENIED_MARKER_\(UUID().uuidString)"
        let allowedMarker = "CEILING_ALLOWED_MARKER_\(UUID().uuidString)"
        let deniedFile = denied.appendingPathComponent("fixture.txt")
        let siblingFile = sibling.appendingPathComponent("fixture.txt")
        try deniedMarker.write(to: deniedFile, atomically: true, encoding: .utf8)
        try allowedMarker.write(to: siblingFile, atomically: true, encoding: .utf8)

        let sessions = SessionStore(directory: directory)
        let source = try sessions.createSession(id: "ceiling-descendant-source")
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        let owner = BuiltinToolExecutor(allowedRoot: directory, deniedRoots: [])
        let wrapped = ScopedForwardingExecutor(base: owner)
        let ledger = try minisCoreToolContractLedger(at: directory)
        let ceiling = ChildParentFileAccessCeiling(
            allowedRoot: directory, additionalAllowedRoots: [], deniedRoots: [denied]
        )
        func orchestrator(provider: ScopedReadProbeProvider, parentID: String) -> AgentOrchestrator {
            let parent = ParentRuntimeIdentity(
                sessionID: source.id, conversationID: source.id,
                turnID: "turn-handle:\(parentHandle.turnID)",
                taskID: parentID, actorID: "synthetic-test"
            )
            return AgentOrchestrator(
                provider: provider, toolExecutor: wrapped,
                turnController: controller, currentConversationID: source.id,
                taskStore: AgentTaskStore(), sessionStore: sessions,
                toolExecutionFactLedger: ledger,
                parentID: parentID, parentRuntimeIdentity: parent,
                parentTurnHandle: parentHandle, runtimeMode: .production,
                capabilityPolicy: AgentCapabilityPolicy(
                    allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
                ), parentCapabilities: [.tools],
                parentFileAccessCeiling: ceiling,
                concreteBuiltinToolExecutorOwner: owner
            )
        }
        func task(_ id: String) -> SubAgentTask {
            SubAgentTask(id: id, title: id, instructions: id,
                requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(
                    allowedToolNames: ["file_read"], allowedReadRoots: [directory.path]))
        }

        let deniedProvider = ScopedReadProbeProvider(path: deniedFile.path, marker: deniedMarker)
        let deniedReport = await orchestrator(provider: deniedProvider, parentID: "ceiling-denied-parent")
            .orchestrate(tasks: [task("denied-descendant")], strategy: .sequential)
        #expect(deniedProvider.offeredToolNameSets.contains(["file_read"]))
        #expect(deniedReport.first?.result.output == "read-blocked")
        #expect(wrapped.invokedNames.isEmpty)

        let allowedProvider = ScopedReadProbeProvider(path: siblingFile.path, marker: allowedMarker)
        let allowedReport = await orchestrator(provider: allowedProvider, parentID: "ceiling-sibling-parent")
            .orchestrate(tasks: [task("allowed-sibling")], strategy: .sequential)
        #expect(allowedProvider.offeredToolNameSets.contains(["file_read"]))
        #expect(allowedReport.first?.result.output == "read-ok")
        #expect(wrapped.invokedNames == ["file_read"])
    }

    @Test func wrappedBuiltinScopeNeedsCurrentConcreteOwnerAndBothCeilings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreWrappedOwner-\(UUID().uuidString)", isDirectory: true)
        let own = directory.appendingPathComponent("own", isDirectory: true)
        let sibling = directory.appendingPathComponent("sibling", isDirectory: true)
        let denied = own.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let concrete = BuiltinToolExecutor(allowedRoot: own, deniedRoots: [denied])
        let widerDirect = BuiltinToolExecutor(allowedRoot: directory, deniedRoots: [])
        let wrapped = ScopedForwardingExecutor(base: concrete)
        let reboundWrapper = ScopedForwardingExecutor(base: concrete)
        let ceiling = ChildParentFileAccessCeiling(executor: concrete)
        let broadCeiling = ChildParentFileAccessCeiling(executor: widerDirect)
        let probe = OrchestrationProbe()
        let provider = ProbeLLMProvider(probe: probe)
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()

        func orchestrator(
            executor: any ToolExecutor,
            owner: BuiltinToolExecutor?,
            ceiling: ChildParentFileAccessCeiling?
        ) -> AgentOrchestrator {
            AgentOrchestrator(
                provider: provider, toolExecutor: executor,
                turnController: controller,
                taskStore: AgentTaskStore(), parentID: "wrapped-owner-parent",
                parentTurnHandle: parentHandle,
                runtimeMode: .production,
                capabilityPolicy: AgentCapabilityPolicy(
                    allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
                ),
                parentCapabilities: [.tools], parentFileAccessCeiling: ceiling,
                concreteBuiltinToolExecutorOwner: owner
            )
        }
        func task(_ id: String, root: URL) -> SubAgentTask {
            SubAgentTask(id: id, title: id, instructions: "read", requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(
                    allowedToolNames: ["file_read"], allowedReadRoots: [root.path]))
        }
        let configured = orchestrator(executor: wrapped, owner: concrete, ceiling: ceiling)
        let cases: [(AgentOrchestrator, SubAgentTask)] = [
            (orchestrator(executor: wrapped, owner: nil, ceiling: ceiling), task("missing-owner", root: own)),
            (orchestrator(executor: UnprovenBuiltinForwarder(base: concrete), owner: concrete, ceiling: ceiling),
                task("missing-proof", root: own)),
            (orchestrator(executor: wrapped, owner: concrete, ceiling: nil), task("missing-ceiling", root: own)),
            (orchestrator(executor: widerDirect, owner: concrete, ceiling: ceiling), task("mismatched-direct", root: own)),
            (orchestrator(executor: wrapped, owner: concrete, ceiling: broadCeiling), task("broad-ceiling", root: sibling)),
            (orchestrator(executor: wrapped, owner: concrete, ceiling: broadCeiling), task("denied", root: denied)),
            (configured.withBuiltinExecution(provider: provider, toolExecutor: reboundWrapper),
                task("rebound-wrapper", root: own))
        ]
        for (subject, requestedTask) in cases {
            let report = await subject.orchestrate(tasks: [requestedTask], strategy: .sequential)
            #expect(report.first?.result.error == "TASK_RESOURCE_SCOPE_INVALID")
        }
        let directRebound = configured.withBuiltinExecution(provider: provider, toolExecutor: widerDirect)
        let directReport = await directRebound.orchestrate(
            tasks: [task("direct-rebound", root: sibling)], strategy: .sequential
        )
        // The new direct executor supplied its own boundary; this probe has
        // no tools capability, so capability admission is the next failure.
        #expect(directReport.first?.result.error == "CAPABILITY_UNAVAILABLE")
        let sameExecutorCopy = configured.withCapabilityPolicy(AgentCapabilityPolicy(
            allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
        ))
        let copiedReport = await sameExecutorCopy.orchestrate(
            tasks: [task("same-executor-copy", root: own)], strategy: .sequential
        )
        #expect(copiedReport.first?.result.error == "CAPABILITY_UNAVAILABLE")
        #expect(await probe.maxActive == 0)
        #expect(wrapped.invokedNames.isEmpty)
        #expect(reboundWrapper.invokedNames.isEmpty)
    }

    @Test func wrappedBuiltinUnderlyingRebindCannotReuseVerifiedOwner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreWrappedRebind-\(UUID().uuidString)", isDirectory: true)
        let own = directory.appendingPathComponent("own", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "WRAPPED_OWNER_MARKER_\(UUID().uuidString)"
        let file = own.appendingPathComponent("fixture.txt")
        try marker.write(to: file, atomically: true, encoding: .utf8)

        let sessions = SessionStore(directory: directory)
        let source = try sessions.createSession(id: "wrapped-rebind-source")
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        let parent = ParentRuntimeIdentity(
            sessionID: source.id, conversationID: source.id,
            turnID: "turn-handle:\(parentHandle.turnID)",
            taskID: "wrapped-rebind-parent", actorID: "synthetic-test"
        )
        let provider = ScopedReadProbeProvider(path: file.path, marker: marker)
        let owner = BuiltinToolExecutor(allowedRoot: own, deniedRoots: [])
        let widerBase = BuiltinToolExecutor(allowedRoot: directory, deniedRoots: [])
        let wrapped = ScopedForwardingExecutor(base: owner)
        let orchestrator = AgentOrchestrator(
            provider: provider, toolExecutor: wrapped,
            turnController: controller, currentConversationID: source.id,
            taskStore: AgentTaskStore(), sessionStore: sessions,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: directory),
            parentID: parent.taskID, parentRuntimeIdentity: parent,
            parentTurnHandle: parentHandle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
            ), parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            concreteBuiltinToolExecutorOwner: owner
        )
        func task(_ id: String) -> SubAgentTask {
            SubAgentTask(id: id, title: id, instructions: id, requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(
                    allowedToolNames: ["file_read"], allowedReadRoots: [own.path]))
        }

        let approved = await orchestrator.orchestrate(
            tasks: [task("before-rebind")], strategy: .sequential
        )
        #expect(approved.first?.result.output == "read-ok")
        #expect(wrapped.invokedNames == ["file_read"])
        let offeredBeforeRebind = provider.offeredToolNameSets

        wrapped.rebind(to: widerBase)
        let rejected = await orchestrator.orchestrate(
            tasks: [task("after-rebind")], strategy: .sequential
        )
        #expect(rejected.first?.result.error == "TASK_RESOURCE_SCOPE_INVALID")
        #expect(provider.offeredToolNameSets == offeredBeforeRebind)
        #expect(wrapped.invokedNames == ["file_read"])
        let persistedMarker = try String(contentsOf: file, encoding: .utf8)
        #expect(persistedMarker == marker)
    }

    @Test func wrappedBuiltinRebindAfterAdmissionCannotReachToolEffect() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreWrappedUseRebind-\(UUID().uuidString)", isDirectory: true)
        let own = directory.appendingPathComponent("own", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "BOUND_OWNER_MARKER_\(UUID().uuidString)"
        let file = own.appendingPathComponent("fixture.txt")
        try marker.write(to: file, atomically: true, encoding: .utf8)
        let owner = BuiltinToolExecutor(allowedRoot: own, deniedRoots: [])
        let wrapped = ScopedForwardingExecutor(base: owner)
        let provider = ScopedReadProbeProvider(path: file.path, marker: marker) {
            wrapped.rebind(to: BuiltinToolExecutor(allowedRoot: directory, deniedRoots: []))
        }
        let sessions = SessionStore(directory: directory)
        let source = try sessions.createSession(id: "wrapped-use-rebind-source")
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        let parent = ParentRuntimeIdentity(
            sessionID: source.id, conversationID: source.id,
            turnID: "turn-handle:\(parentHandle.turnID)",
            taskID: "wrapped-use-rebind-parent", actorID: "synthetic-test"
        )
        let orchestrator = AgentOrchestrator(
            provider: provider, toolExecutor: wrapped,
            turnController: controller, currentConversationID: source.id,
            taskStore: AgentTaskStore(), sessionStore: sessions,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: directory),
            parentID: parent.taskID, parentRuntimeIdentity: parent,
            parentTurnHandle: parentHandle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
            ), parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            concreteBuiltinToolExecutorOwner: owner
        )
        let task = SubAgentTask(
            id: "during-rebind", title: "during-rebind", instructions: "read",
            requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(
                allowedToolNames: ["file_read"], allowedReadRoots: [own.path]
            )
        )
        let report = await orchestrator.orchestrate(tasks: [task], strategy: .sequential)
        #expect(report.first?.result.output == "read-blocked")
        #expect(provider.offeredToolNameSets.contains(["file_read"]))
        #expect(wrapped.invokedNames.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == marker)
    }

    @Test func taskResourceRequestSurvivesExecutionAndBindingCopies() {
        let request = SubAgentResourceRequest(
            allowedToolNames: ["file_read"], allowedReadRoots: ["/tmp/dev154-parent/a"]
        )
        let task = SubAgentTask(id: "copy", title: "copy", instructions: "read",
            requiredCapabilities: [.tools], resourceRequest: request)
        #expect(task.withExecutionID("execution").resourceRequest == request)
        #expect(task.resolvedBinding(
            providerID: "p", modelID: "m", configurationFingerprint: "f", source: .inherited
        ).resourceRequest == request)
    }

    @Test func reportSummaryLineFormats() {
        let ok = SubAgentReport(
            taskID: "a", agentType: .builtin, duration: 1.25,
            result: .succeeded(output: "结果文本")
        )
        #expect(ok.summaryLine.contains("[a]"))
        #expect(ok.summaryLine.contains("成功"))

        let bad = SubAgentReport(
            taskID: "b", agentType: .external(name: "codex"), duration: 0.5,
            result: .failed(error: "boom")
        )
        #expect(bad.summaryLine.contains("[b]"))
        #expect(bad.summaryLine.contains("失败"))
        #expect(bad.summaryLine.contains("boom"))
    }
    @Test("child uses inherited Composer mode through real policy and builtin write", arguments: [
        "manual-approve", "manual-deny", "manual-edit-approve", "manual-edit-deny", "manual-shell-approve", "manual-shell-deny", "manual-unknown", "manual-owner-swapped", "manual-wrong-identity", "manual-cancel", "manual-revoked", "bypass-own", "bypass-outside", "bypass-outside-switch-off", "auto-outside", "plan", "narrowed", "expired"
    ])
    func childWriteInheritsModeWithoutParentCallGrant(_ scenario: String) async throws {
        actor Decision: ApprovalDelegate {
            let approve: Bool
            private(set) var requests: [ApprovalRequest] = []
            let pause: Bool
            private var parked: CheckedContinuation<Void, Never>?
            private var pendingRelease = false
            private var observed: [CheckedContinuation<Void, Never>] = []
            private(set) var isValid = true
            private(set) var observedNavigation = false
            private(set) var fileLeaseOwned = false
            private(set) var rejectedMissingRuntime = false
            private(set) var rejectedWrongPresentation = false
            let corruptIdentity: Bool
            let onDecision: (@Sendable () -> Void)?
            init(_ approve: Bool, pause: Bool, onDecision: (@Sendable () -> Void)? = nil, corruptIdentity: Bool = false) {
                self.approve = approve; self.pause = pause; self.onDecision = onDecision; self.corruptIdentity = corruptIdentity
            }
            func waitForRequest() async {
                if !requests.isEmpty { return }
                let deadline = ContinuousClock.now + .seconds(5)
                while requests.isEmpty && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            func revoke() { isValid = false }
            func release() {
                if let continuation = parked {
                    parked = nil
                    continuation.resume()
                } else {
                    pendingRelease = true
                }
            }
            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                requests.append(request)
                if let context = AgentExecutionContext.current,
                   let child = context.childToolRuntimeBinding?.boundary.identity,
                   let store = context.taskStore,
                   let navigation = store.currentPendingApprovalBinding(taskID: child.childTaskID, parentID: child.parentTaskID),
                   let presentation = ApprovalPresentationContext.current {
                    observedNavigation = true
                    if let lease = ToolFileMutationLease.current {
                        let owns = await ToolFileMutationSerialiser.shared.owns(key: lease.key, token: lease.token)
                        fileLeaseOwned = owns && lease.matchesApprovalContext(presentation)
                    }
                    func retry() throws -> AgentTaskApprovalNavigationBinding {
                        try store.beginPendingChildApproval(taskRunID: navigation.taskRunID,
                            taskAttemptID: navigation.taskAttemptID, childIdentity: child, request: request)
                    }
                    do { _ = try AgentExecutionContext.$current.withValue(nil) { try retry() } }
                    catch AgentTaskStoreError.approvalNavigationIdentityMismatch { rejectedMissingRuntime = true }
                    catch { }
                    let k = presentation.compositeKey
                    let wrong = ToolExecutionCompositeKey(sessionID: k.sessionID, turnID: k.turnID,
                        messageID: k.messageID, operationID: k.operationID, attemptID: k.attemptID,
                        attemptNumber: k.attemptNumber, toolCallID: "foreign-call")
                    let bad = ApprovalPresentationContext(compositeKey: wrong,
                        executionIdentity: presentation.executionIdentity, toolName: presentation.toolName, eventSink: { _ in })
                    do { _ = try ApprovalPresentationContext.$current.withValue(bad) { try retry() } }
                    catch AgentTaskStoreError.approvalNavigationIdentityMismatch { rejectedWrongPresentation = true }
                    catch { }
                    #expect(store.currentPendingApprovalBinding(taskID: child.childTaskID, parentID: child.parentTaskID) == navigation)
                }
                for waiter in observed { waiter.resume() }
                observed.removeAll()
                if pause {
                    if pendingRelease {
                        pendingRelease = false
                    } else {
                        await withCheckedContinuation { parked = $0 }
                    }
                }
                onDecision?()
                return ApprovalDecision(approved: approve, confirmed: approve,
                    requestID: corruptIdentity ? "foreign-request" : request.requestID, bindingDigest: request.identityDigest)
            }
        }
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child-write-mode-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 用户 2026-10-22 决定：父会话为已确认绕过且「子任务写入」开关打开时，子任务文件跟随父会话，
        // 可写项目根之外（bypass-outside）；开关关闭（bypass-outside-switch-off，子任务没有写工具）
        // 或父会话不是绕过（auto-outside）时仍被拒绝。
        let target = (scenario.contains("outside") ? root : project).appendingPathComponent("owned.txt")
        let toolName = scenario.contains("-edit-") ? "file_edit" : scenario.contains("-shell-") ? "shell_execute"
            : scenario == "manual-unknown" ? "unknown_child_tool" : "file_write"
        let toolInput: [String: Any]
        if toolName == "file_edit" {
            try "seed".write(to: target, atomically: true, encoding: .utf8)
            toolInput = ["path": target.path, "old_string": "seed", "new_string": "child owned bytes"]
        } else if toolName == "shell_execute" {
            let quoted = "'" + target.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            toolInput = ["command": "/usr/bin/printf 'child owned bytes' > " + quoted]
        } else { toolInput = ["path": target.path, "content": "child owned bytes"] }
        let provider = ScriptedChildProvider(responses: [orchEnvelope(id: "owned-child-write", name: toolName,
            input: toolInput), "done"])
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "owned-parent")
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id, conversationID: source.id,
            taskID: "owned-parent-task", actorID: "owned-test").makeIdentity(using: turn)
        let goal = GoalEnvelope(scopeID: "owned-child", allowedCapabilities: ["file_write", "file_edit", "shell_execute", "file_read"],
            fileRoots: [project.path], budget: 20, deadline: Date().addingTimeInterval(60),
            concurrencyLimit: 2, autonomyLevel: .l3)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: Date(), expiresAt: goal.deadline)
        let builtin = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [])
        let ledger = try minisCoreToolContractLedger(at: root)
        let forwarding = ScopedForwardingExecutor(base: builtin)
        let policy = PolicyEnforcedToolExecutor(base: forwarding, goal: goal, lease: lease,
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder)
        let replacementOwner = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [])
        let replaceOwner: @Sendable () -> Void = { forwarding.rebind(to: replacementOwner) }
        let decision = Decision(!scenario.hasSuffix("-deny"), pause: scenario == "manual-cancel" || scenario == "manual-revoked",
            onDecision: scenario == "manual-owner-swapped" ? replaceOwner : nil,
            corruptIdentity: scenario == "manual-wrong-identity")
        let mode: ComposerTaskMode = scenario == "plan" ? .plan
            : scenario.hasPrefix("bypass") ? .bypassPermission
            : scenario.hasPrefix("auto") ? .auto : .manual
        let snapshot = ComposerSubmissionSnapshot(mode: mode, approvalScope: .request, effort: .standard,
            sessionID: source.id, turnID: 99, taskID: "parent-only-task",
            attemptID: "parent-only-attempt", messageID: "parent-only-message",
            workspaceID: "owned-workspace", createdAt: Date(), policyRevision: "owned-revision",
            grantEpoch: "owned-epoch", bypassModeConfirmed: mode == .bypassPermission, autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write", "file_edit", "shell_execute", "file_read"], grantedCapabilities: ["file_write", "file_edit", "shell_execute", "file_read"],
            allowedWriteRoots: [project.path], workspaceID: "owned-workspace", revision: "owned-revision",
            grantEpoch: "owned-epoch", leaseID: "owned-lease", expiresAt: scenario == "expired" ? .distantPast : goal.deadline, autonomyCeiling: .l3)
        let tasks = AgentTaskStore()
        // Production child loops intentionally have no optional UI lifecycle
        // observer installed. Their canonical approval context must still exist.
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 3, provider: provider, toolExecutor: policy,
            approvalGate: ApprovalGate(policyByTool: ["file_write": .alwaysAsk, "file_edit": .alwaysAsk, "shell_execute": .alwaysAsk], delegate: decision),
            turnController: controller, makeLoopDetector: { nil }, currentConversationID: source.id,
            taskStore: tasks, sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentGoal: goal, parentTurnHandle: turn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: ["file_write", "file_edit", "shell_execute", "file_read"]),
            parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: builtin),
            parentWorkingDirectory: project.path, childMutationsEnabled: scenario != "bypass-outside-switch-off",
            parentComposerSnapshot: snapshot, parentComposerFacts: facts,
            parentAuthorityCheck: { await decision.isValid },
            concreteBuiltinToolExecutorOwner: builtin, requiresPolicyRuntime: true)
        let task = SubAgentTask(id: "owned-child", title: "Owned child",
            instructions: "write the owned synthetic file", requiredCapabilities: [.tools],
            resourceRequest: scenario == "narrowed" ? SubAgentResourceRequest(
                allowedToolNames: ["file_read"], allowedReadRoots: [project.path]) : nil)
        let running = Task { await orchestrator.orchestrate(tasks: [task], strategy: .sequential) }
        if scenario == "manual-cancel" || scenario == "manual-revoked" {
            await decision.waitForRequest()
            if scenario == "manual-cancel" { await controller.interrupt() }
            else { await decision.revoke() }
            await decision.release()
        }
        let reports = await running.value
        #expect(reports.count == 1)
        let shouldWrite = scenario.hasSuffix("-approve") || scenario == "bypass-own" || scenario == "bypass-outside"
        #expect(FileManager.default.fileExists(atPath: target.path) == (shouldWrite || toolName == "file_edit"))
        if toolName == "file_edit" && !shouldWrite { #expect(try String(contentsOf: target, encoding: .utf8) == "seed") }
        if shouldWrite {
            #expect(try String(contentsOf: target, encoding: .utf8) == "child owned bytes")
            let fact = try #require(ledger.facts.first { $0.toolName == toolName })
            #expect(fact.executionIdentity?.turn.sessionID != source.id)
            #expect(fact.childTranscriptLocator?.taskID == "owned-child")
            #expect(fact.parentRuntimeIdentity == parent)
        }
        let prompts = await decision.requests
        #expect(prompts.count == (scenario.hasPrefix("manual") && scenario != "manual-unknown" ? 1 : 0))
        if !prompts.isEmpty {
            #expect(await decision.observedNavigation)
            #expect(await decision.rejectedMissingRuntime)
            #expect(await decision.rejectedWrongPresentation)
            #expect(await decision.fileLeaseOwned == (toolName != "shell_execute"))
        }
        if scenario == "manual-unknown" { #expect(ledger.facts.isEmpty) }
        if let prompt = prompts.first {
            #expect(prompt.sourceTaskTitle == "Owned child")
            #expect(prompt.taskID == "owned-child")
            #expect(prompt.sessionID != source.id && prompt.attemptID != "parent-only-attempt")
        }
        if scenario == "plan" || scenario == "narrowed" { #expect(ledger.facts.isEmpty) }
        if scenario == "narrowed" { #expect(!provider.receivedRequests.isEmpty) }
        if scenario == "expired" { #expect(provider.receivedRequests.isEmpty && ledger.facts.isEmpty) }
    }

    @Test("V2 defaults to inherited tools and supports only narrowing resource data")
    func childV2InheritedAndNarrowedResourceContract() throws {
        let base: [String: Any] = ["id": "owned", "title": "Owned", "instructions": "owned work"]
        let inherited = try OrchestrateRequestV1.decode(input: ["input_version": 2, "tasks": [base]], maxTasks: 10)
        #expect(inherited.tasks.first?.requiredCapabilities == ["tools"])
        #expect(inherited.tasks.first?.resourceRequest == nil)
        var raw = base
        raw["allowed_tool_names"] = ["file_write"]
        raw["allowed_write_roots"] = ["/owned/project/out"]
        raw["working_directory"] = "/owned/project/out"
        let narrowed = try OrchestrateRequestV1.decode(input: ["input_version": 2, "tasks": [raw]], maxTasks: 10)
        let scope = try #require(narrowed.tasks.first?.resourceRequest)
        #expect(scope.allowedToolNames == ["file_write"] && !scope.inheritsToolNames)
        #expect(scope.allowedWriteRoots == ["/owned/project/out"])
        #expect(scope.workingDirectory == "/owned/project/out")
        let encoded = try JSONEncoder().encode(scope)
        #expect(try JSONDecoder().decode(SubAgentResourceRequest.self, from: encoded) == scope)
        // V1 remains tool-less; V2-only scope data cannot silently migrate V1.
        #expect(throws: (any Error).self) {
            try OrchestrateRequestV1.decode(input: ["input_version": 1, "tasks": [raw]], maxTasks: 10)
        }
    }

    @Test("real file edits serialize physical aliases without losing independent updates")
    func physicalFileMutationAliasesKeepEveryEdit() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child-file-rmw-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("shared.txt")
        let alias = root.appendingPathComponent("alias.txt")
        try (0..<24).map { "old-\($0)-line\n" }.joined().write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    _ = try await executor.execute(name: "file_edit", input: [
                        "path": (index.isMultiple(of: 2) ? file : alias).path,
                        "old_string": "old-\(index)-line", "new_string": "new-\(index)-line"
                    ])
                }
            }
            try await group.waitForAll()
        }
        let result = try String(contentsOf: file, encoding: .utf8)
        for index in 0..<24 {
            #expect(result.contains("new-\(index)-line\n"))
            #expect(!result.contains("old-\(index)-line\n"))
        }
    }

    @Test("cancelled or parent-revoked lock waiter cannot write; different file proceeds", arguments: [false, true])
    func fileMutationWaitCancellationAndIndependentPath(_ revokeParent: Bool) async throws {
        actor Rights {
            private(set) var active = true
            func revoke() { active = false }
        }
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child-file-wait-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("held.txt")
        let other = root.appendingPathComponent("independent.txt")
        try "unchanged".write(to: file, atomically: true, encoding: .utf8)
        let key = PolicyRuntimePathBoundary.foldedForPathComparison(try #require(PolicyRuntimePathBoundary.canonicalPath(file.path)))
        let token = UUID()
        _ = try await ToolFileMutationSerialiser.shared.acquire(key: key, token: token)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let rights = Rights()
        let physicalRoot = try #require(PolicyRuntimePathBoundary.canonicalPath(root.path))
        let scope = ChildToolWorkspaceScope(readRoots: [physicalRoot], writeRoots: [physicalRoot],
            workingDirectory: physicalRoot, deniedRoots: [], parentAuthorityCheck: { await rights.active })
        let waiter = Task {
            try await ChildToolWorkspaceScope.$current.withValue(scope) {
                try await executor.execute(name: "file_write", input: ["path": file.path, "content": "must not commit"])
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while await ToolFileMutationSerialiser.shared.waitingCount(key: key) == 0 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await ToolFileMutationSerialiser.shared.waitingCount(key: key) == 1)
        _ = try await executor.execute(name: "file_write", input: ["path": other.path, "content": "independent committed"])
        #expect(try String(contentsOf: other, encoding: .utf8) == "independent committed")
        if revokeParent {
            await rights.revoke()
            await ToolFileMutationSerialiser.shared.release(key: key, token: token)
        } else { waiter.cancel() }
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(try String(contentsOf: file, encoding: .utf8) == "unchanged")
        await ToolFileMutationSerialiser.shared.release(key: key, token: token)
        _ = try await executor.execute(name: "file_write", input: ["path": file.path, "content": "next owner committed"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "next owner committed")
    }

    @Test("child shell uses trusted cwd and parent cancellation retires its owned process group", arguments: ["cwd", "outside-cwd", "cancel", "deadline"])
    func childShellWorkspaceAndOwnedCancellation(_ scenario: String) async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child-shell-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("project")
        let subdirectory = project.appendingPathComponent("owned-child-directory")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = subdirectory.appendingPathComponent("owned-group.json")
        let script = subdirectory.appendingPathComponent("owned-sleeper.py")
        try """
        import json,os,signal,sys,time
        child=os.fork()
        if child == 0:
            time.sleep(999)
            os._exit(0)
        def stop(signum, frame):
            os.waitpid(child,0)
            sys.exit(0)
        signal.signal(signal.SIGTERM,stop)
        temporary_marker='\(marker.path).pending'
        with open(temporary_marker,'w') as f:
            json.dump({'group':os.getpgrp(),'child':child},f)
        os.replace(temporary_marker,'\(marker.path)')
        print("SYNTHETIC_CHILD_PARTIAL", flush=True)
        time.sleep(999)
        """.write(to: script, atomically: true, encoding: .utf8)
        let command = (scenario == "cancel" || scenario == "deadline") ? "python3 \(script.path)" : "pwd"
        let provider = ScriptedChildProvider(responses: [orchEnvelope(id: "owned-child-shell", name: "shell_execute",
            input: ["command": command]), "done"])
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "owned-shell-parent")
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id, conversationID: source.id,
            taskID: "shell-parent-task", actorID: "owned-test").makeIdentity(using: turn)
        let goal = GoalEnvelope(scopeID: "owned-shell", allowedCapabilities: ["shell_execute"],
            fileRoots: [project.path], budget: 20, deadline: Date().addingTimeInterval(scenario == "deadline" ? 1 : 30),
            concurrencyLimit: 2, autonomyLevel: .l3)
        let builtin = BuiltinToolExecutor(allowedRoot: project, defaultShellTimeout: 45, deniedRoots: [])
        let observed = ScopedForwardingExecutor(base: builtin)
        let policy = PolicyEnforcedToolExecutor(base: observed, goal: goal,
            lease: AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: Date(), expiresAt: goal.deadline),
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder)
        let ledger = try minisCoreToolContractLedger(at: root)
        let delegate = D219RRecordingDelegate(decisions: [])
        let snapshot = ComposerSubmissionSnapshot(mode: .bypassPermission, approvalScope: .request, effort: .standard,
            sessionID: source.id, turnID: 9, taskID: "parent-shell-only", attemptID: "parent-shell-attempt",
            messageID: "parent-shell-message", workspaceID: "owned-shell", createdAt: Date(),
            policyRevision: "owned-shell-policy", grantEpoch: "owned-shell-epoch",
            bypassModeConfirmed: true, autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["shell_execute"], grantedCapabilities: ["shell_execute"],
            allowedWriteRoots: [project.path], workspaceID: "owned-shell", revision: "owned-shell-policy",
            grantEpoch: "owned-shell-epoch", leaseID: "owned-shell-lease", expiresAt: goal.deadline, autonomyCeiling: .l3)
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 3, provider: provider, toolExecutor: policy,
            approvalGate: ApprovalGate(delegate: delegate), turnController: controller,
            makeLoopDetector: { nil }, childTimeout: 25,
            deadline: scenario == "deadline" ? goal.deadline : nil, currentConversationID: source.id,
            taskStore: AgentTaskStore(), sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentGoal: goal, parentTurnHandle: turn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: ["shell_execute"]),
            parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: builtin),
            parentWorkingDirectory: project.path, childMutationsEnabled: true,
            parentComposerSnapshot: snapshot, parentComposerFacts: facts,
            concreteBuiltinToolExecutorOwner: builtin, requiresPolicyRuntime: true)
        let request = SubAgentTask(id: "owned-shell-child", title: "Owned shell child", instructions: "execute the synthetic command",
            requiredCapabilities: [.tools], resourceRequest: SubAgentResourceRequest(allowedToolNames: ["shell_execute"],
                allowedReadRoots: [], allowedWriteRoots: [subdirectory.path],
                workingDirectory: scenario == "outside-cwd" ? root.path : subdirectory.path))
        let running = Task { await orchestrator.orchestrate(tasks: [request], strategy: .sequential) }
        do {
        if scenario == "deadline" {
            let started = Date()
            let reports = await running.value
            let error = try #require(reports.first?.result.error)
            #expect(error.hasPrefix("DEADLINE_EXCEEDED"))
            #expect(error.contains("SYNTHETIC_CHILD_PARTIAL"))
            #expect(reports.first?.result.isSuccess == false)
            #expect(provider.receivedRequests.count == 1, "deadline drain must not admit another model request")
            #expect(Date().timeIntervalSince(started) < 12, "the cleanup bound never becomes a new execution budget")
            let data = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Int])
            let group = try #require(data["group"])
            #expect(group > 1 && group != Int(getpgrp()))
            let cleanup = ContinuousClock.now + .seconds(4)
            while kill(-Int32(group), 0) == 0 && ContinuousClock.now < cleanup {
                try await Task.sleep(for: .milliseconds(20))
            }
            let processProbe = kill(-Int32(group), 0)
            let processProbeErrno = errno
            #expect(processProbe == -1 && processProbeErrno == ESRCH,
                Comment(rawValue: "group=\(group) probe=\(processProbe) errno=\(processProbeErrno) expected=\(ESRCH)"))
            #expect(ledger.pendingReceipts.isEmpty)
            #expect(ledger.facts.contains { $0.toolName == "shell_execute" && $0.status == .failed })
        } else if scenario == "cancel" {
            let deadline = ContinuousClock.now + .seconds(8)
            while !FileManager.default.fileExists(atPath: marker.path) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let bytes = try Data(contentsOf: marker)
            let data = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Int])
            let group = try #require(data["group"])
            #expect(group > 1 && group != Int(getpgrp()))
            let liveGroupProbe = kill(-Int32(group), 0)
            let liveGroupProbeErrno = errno
            #expect(liveGroupProbe == 0,
                Comment(rawValue: "owned live group=\(group) probe=\(liveGroupProbe) errno=\(liveGroupProbeErrno)"))
            await controller.interrupt()
            _ = await running.value
            let cleanup = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < cleanup {
                let observation = kill(-Int32(group), 0)
                let observationErrno = errno
                if observation == -1 && observationErrno == ESRCH { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let processProbe = kill(-Int32(group), 0)
            let processProbeErrno = errno
            func exactGroupObservation() -> String {
                let sampledAt = Date()
                do {
                    let ps = Process()
                    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                    ps.arguments = ["-axo", "pid=,ppid=,pgid=,state="]
                    ps.environment = [:]
                    let output = Pipe()
                    ps.standardOutput = output
                    ps.standardError = FileHandle.nullDevice
                    try ps.run()
                    let bytes = output.fileHandleForReading.readDataToEndOfFile()
                    ps.waitUntilExit()
                    let rows = String(decoding: bytes, as: UTF8.self).split(separator: "\n").filter { line in
                        let fields = line.split(whereSeparator: \.isWhitespace)
                        return fields.count == 4 && Int(fields[2]) == group
                    }
                    return "exactPGID=\(group) sampledAt=\(sampledAt) psExit=\(ps.terminationStatus) fields=pid,ppid,pgid,state rows=\(rows.map(String.init))"
                } catch { return "exactPGID=\(group) sampledAt=\(sampledAt) psError=\(error)" }
            }
            let processObservation = processProbe == -1 && processProbeErrno == ESRCH
                ? "not sampled: ESRCH" : exactGroupObservation()
            #expect(processProbe == -1 && processProbeErrno == ESRCH,
                Comment(rawValue: "group=\(group) probe=\(processProbe) errno=\(processProbeErrno) expected=\(ESRCH); \(processObservation)"))
            #expect(ledger.pendingReceipts.isEmpty)
            #expect(ledger.facts.allSatisfy { $0.childTranscriptLocator?.taskID == "owned-shell-child" })
        } else {
            let reports = await running.value
            if scenario == "outside-cwd" {
                #expect(reports.first?.result.error == "TASK_RESOURCE_SCOPE_INVALID")
                #expect(provider.receivedRequests.isEmpty && ledger.facts.isEmpty)
            } else {
                #expect(reports.first?.result.isSuccess == true)
                let returned = try #require(provider.receivedRequests.dropFirst().first?.last?.content)
                #expect(returned.contains("owned-child-directory"))
                let fact = try #require(ledger.facts.first { $0.toolName == "shell_execute" })
                #expect(fact.childTranscriptLocator?.taskID == "owned-shell-child")
                #expect(fact.parentRuntimeIdentity == parent)
            }
        }
        } catch {
            running.cancel()
            await controller.interrupt()
            _ = await running.value
            throw error
        }
        #expect(delegate.requests.isEmpty)
        if scenario != "outside-cwd" { #expect(observed.observedShellBudgets == [45]) }
    }

    @Test("legal sibling children keep independent identities and real effects while running together")
    func siblingChildrenShareParentModeWithoutSharingCallGrant() async throws {
        final class Provider: LLMProvider, @unchecked Sendable {
            let name = "OwnedSiblings"
            var model = LLMModel.claudeHaiku45
            var capabilities: Set<ProviderCapability> { [.tools] }
            let root: URL
            let barrier = ConcurrentBarrier(expected: 2)
            let lock = NSLock()
            var calls: [String: Int] = [:]
            init(root: URL) { self.root = root }
            func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                             temperature: Double?) async throws -> LLMResponse {
                let id = messages.contains { $0.content.contains("sibling-a") } ? "sibling-a" : "sibling-b"
                let count = lock.withLock { calls[id, default: 0] += 1; return calls[id]! }
                if count == 1 {
                    await barrier.arrive()
                    return LLMResponse(text: orchEnvelope(id: "write-" + id, name: "file_write",
                        input: ["path": root.appendingPathComponent(id + ".txt").path, "content": id]), stopReason: nil, usage: nil)
                }
                return LLMResponse(text: "completed " + id, stopReason: nil, usage: nil)
            }
            func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                             maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
                try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                                      maxTokens: maxTokens, temperature: temperature)
            }
            func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                               temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child-siblings-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "sibling-parent")
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id, conversationID: source.id,
            taskID: "sibling-parent-task", actorID: "owned").makeIdentity(using: turn)
        let goal = GoalEnvelope(scopeID: "siblings", allowedCapabilities: ["file_write"], fileRoots: [root.path],
            budget: 20, deadline: Date().addingTimeInterval(30), concurrencyLimit: 2, autonomyLevel: .l3)
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let policy = PolicyEnforcedToolExecutor(base: owner, goal: goal,
            lease: AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: Date(), expiresAt: goal.deadline))
        let snapshot = ComposerSubmissionSnapshot(mode: .bypassPermission, approvalScope: .request, effort: .standard,
            sessionID: source.id, turnID: 1, taskID: "parent", attemptID: "parent-attempt", messageID: "parent-message",
            workspaceID: "siblings", createdAt: Date(), policyRevision: "sibling-policy", grantEpoch: "sibling-epoch",
            bypassModeConfirmed: true, autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [root.path], workspaceID: "siblings", revision: "sibling-policy",
            grantEpoch: "sibling-epoch", leaseID: "parent-lease", expiresAt: goal.deadline, autonomyCeiling: .l3)
        let ledger = try minisCoreToolContractLedger(at: root)
        let orchestrator = AgentOrchestrator(defaultMaxConcurrent: 2, provider: Provider(root: root), toolExecutor: policy,
            turnController: controller, currentConversationID: source.id, taskStore: AgentTaskStore(), sessionStore: sessions,
            toolExecutionFactLedger: ledger, parentID: parent.taskID, parentRuntimeIdentity: parent,
            parentGoal: goal, parentTurnHandle: turn, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: ["file_write"]),
            parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            parentWorkingDirectory: root.path, childMutationsEnabled: true,
            parentComposerSnapshot: snapshot, parentComposerFacts: facts,
            parentAuthorityCheck: { true }, concreteBuiltinToolExecutorOwner: owner, requiresPolicyRuntime: true)
        let ids = ["sibling-a", "sibling-b"]
        let reports = await orchestrator.orchestrate(tasks: ids.map {
            SubAgentTask(id: $0, title: $0, instructions: $0, requiredCapabilities: [.tools])
        }, strategy: .parallelWithLimit(limit: 2))
        #expect(reports.count == 2 && reports.allSatisfy { $0.result.isSuccess },
            "Actual canonical sibling reports: \(reports.map { "\($0.taskID): \($0.result)" })")
        for id in ids { #expect(try String(contentsOf: root.appendingPathComponent(id + ".txt"), encoding: .utf8) == id) }
        #expect(ledger.facts.count == 2)
        #expect(Set(ledger.facts.compactMap { $0.childTranscriptLocator?.taskID }) == Set(ids))
        #expect(Set(ledger.facts.compactMap { $0.executionIdentity?.turn.sessionID }).count == 2)
        #expect(Set(ledger.facts.map(\.receiptID)).count == 2)
    }

}


extension AgentOrchestratorTests {
    @Test(arguments: ["file_grep", "file_glob"])
    func childSearchUsesReadRootsWithEmptyWriteRoots(_ toolName: String) async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child-search-scope-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let denied = allowed.appendingPathComponent("blocked", isDirectory: true)
        for directory in [allowed, outside, denied] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let filename = "S5_ALLOWED_MATCH.txt"
        let contents = "S5_ALLOWED_MATCH body remains unchanged"
        let files = [allowed, outside, denied].map { $0.appendingPathComponent(filename) }
        for file in files { try contents.write(to: file, atomically: true, encoding: .utf8) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "search-source")
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        defer { Task { await parentHandle.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id, conversationID: source.id,
            taskID: "search-parent", actorID: "scope-test").makeIdentity(using: parentHandle)
        for (scenario, target) in [("allowed", allowed), ("outside", outside), ("denied", denied)] {
            let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [denied])
            let wrapped = ScopedForwardingExecutor(base: owner)
            let ledgerRoot = root.appendingPathComponent(scenario + "-ledger")
            try FileManager.default.createDirectory(at: ledgerRoot, withIntermediateDirectories: true)
            let ledger = try minisCoreToolContractLedger(at: ledgerRoot)
            let provider = ScriptedChildProvider(responses: [orchEnvelope(id: "search-" + scenario, name: toolName,
                input: ["path": target.path, "pattern": toolName == "file_grep" ? "S5_ALLOWED_MATCH" : "*.txt"]),
                orchEnvelope(id: "forbidden-write-" + scenario, name: "file_write", input: [
                    "path": allowed.appendingPathComponent("unexpected-write.txt").path, "content": "must-not-write"]), "done"])
            let orchestrator = AgentOrchestrator(maxIterationsPerTask: 3,
                provider: provider, toolExecutor: wrapped,
                turnController: controller, currentConversationID: source.id,
                taskStore: AgentTaskStore(), sessionStore: sessions, toolExecutionFactLedger: ledger,
                parentID: parent.taskID, parentRuntimeIdentity: parent,
                parentTurnHandle: parentHandle, runtimeMode: .production,
                capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: [toolName]),
                parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
                concreteBuiltinToolExecutorOwner: owner)
            #expect(orchestrator.childMutationsEnabled)
            let task = SubAgentTask(id: "search-" + scenario, title: scenario, instructions: "search the declared directory",
                requiredCapabilities: [.tools], resourceRequest: SubAgentResourceRequest(
                    allowedToolNames: [toolName], allowedReadRoots: [allowed.path], allowedWriteRoots: []))
            let reports = await orchestrator.orchestrate(tasks: [task], strategy: .sequential)
            #expect(reports.first?.result.isSuccess == true)
            let delivered = provider.receivedRequests.dropFirst().flatMap { $0 }.map(\.content).joined(separator: "\n")
            #expect(delivered.contains(filename) == (scenario == "allowed"))
            let fact = try #require(ledger.facts.first { $0.toolName == toolName })
            #expect(fact.status == (scenario == "allowed" ? .succeeded : .failed))
            #expect(wrapped.invokedNames == (scenario == "allowed" ? [toolName] : []))
            #expect(ledger.facts.allSatisfy { $0.toolName == toolName })
            for file in files { #expect(try String(contentsOf: file, encoding: .utf8) == contents) }
            #expect(!FileManager.default.fileExists(atPath: allowed.appendingPathComponent("unexpected-write.txt").path))
        }
    }
}


extension AgentOrchestratorTests {
    @Test func childV2OmissionInheritsOnlyLiveParentCatalogAndExplicitEmptyStaysEmpty() async throws {
        actor ParentApproval: ApprovalDelegate {
            private(set) var tools: [String] = []
            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                tools.append(request.toolName)
                return ApprovalDecision(approved: true, confirmed: true,
                    requestID: request.requestID, bindingDigest: request.identityDigest)
            }
        }
        final class LiveAdmission: @unchecked Sendable {
            private let lock = NSLock()
            private var value: AgentChildToolRuntimeBinding?
            func record(_ binding: AgentChildToolRuntimeBinding) { lock.withLock { value = binding } }
            var binding: AgentChildToolRuntimeBinding? { lock.withLock { value } }
        }
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child-v2-inheritance-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "INHERITED_PARENT_READ_MARKER"
        let file = root.appendingPathComponent("fixture.txt")
        try marker.write(to: file, atomically: true, encoding: .utf8)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "v2-inheritance-source")
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        defer { Task { await parentHandle.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id, conversationID: source.id,
            taskID: "v2-inheritance-parent", actorID: "owned-fixture").makeIdentity(using: parentHandle)
        let approval = ParentApproval()
        let gate = ApprovalGate(policyByTool: ["file_read": .alwaysAsk], delegate: approval)
        let parentTools: Set<String> = ["file_read", "file_glob"]
        for scenario in ["omitted", "narrowed", "widened", "empty-profile", "empty-capabilities"] {
            #expect(await parentHandle.isActive())
            var raw: [String: Any] = ["id": scenario, "title": scenario,
                "instructions": scenario == "empty-capabilities" ? "read-no-file" : "read fixture"]
            if scenario == "empty-capabilities" { raw["required_capabilities"] = [String]() }
            if ["narrowed", "widened", "empty-profile"].contains(scenario) {
                raw["allowed_tool_names"] = scenario == "narrowed" ? ["file_read"]
                    : scenario == "widened" ? ["file_read", "file_grep"] : [String]()
                raw["allowed_read_roots"] = [root.path]
            }
            let input: [String: Any] = ["input_version": 2, "tasks": [raw], "strategy": "sequential"]
            let decoded = try #require(OrchestrateRequestV1.decode(input: input, maxTasks: 1).tasks.first)
            #expect(decoded.requiredCapabilities == (scenario == "empty-capabilities" ? [] : ["tools"]))
            if scenario == "omitted" { #expect(decoded.resourceRequest == nil) }
            if scenario == "empty-profile" {
                #expect(decoded.resourceRequest?.allowedToolNames == [])
                #expect(decoded.resourceRequest?.inheritsToolNames == false)
            }
            let store = AgentTaskStore()
            let admission = LiveAdmission()
            let provider = ScopedReadProbeProvider(path: file.path, marker: marker, onFirstToolOffer: {
                guard let context = AgentExecutionContext.current,
                      let binding = context.childToolRuntimeBinding,
                      let snapshot = context.childRuntimeSnapshot,
                      let running = store.snapshot(taskID: scenario, parentID: parent.taskID) else {
                    Issue.record("actual provider admission must carry its canonical child runtime")
                    return
                }
                let child = binding.boundary.identity
                #expect(child.isValid && (try? child.requireVerifiedGeneration()) != nil)
                #expect(snapshot.identity == child && snapshot.matches(binding.boundary))
                #expect(binding.parent == parent)
                #expect(child.parentSessionID == parent.sessionID)
                #expect(child.parentConversationID == parent.conversationID)
                #expect(child.parentTurnID == parent.turnID && child.cancelGeneration == parentHandle.turnID)
                #expect(child.parentTaskID == parent.taskID)
                // Goal-scoped root metadata is absent on this no-Goal path;
                // the immediate parent remains the exact verified identity.
                #expect(child.rootParentIdentity == nil)
                #expect(child.parentGoalID == nil && child.parentGoalScopeID == nil)
                #expect(binding.boundary.parentTurnHandle?.turnID == parentHandle.turnID)
                #expect(binding.boundary.approvalGate.policy(for: "file_read") == gate.policy(for: "file_read"))
                #expect(running.status == .running && running.parentRuntimeIdentity == parent)
                #expect(running.childTranscriptLocator == binding.locator)
                #expect(binding.locator.childSessionID == child.childSessionID && binding.locator.taskID == scenario)
                #expect(store.canonicalAttemptID(runID: binding.locator.runID) == binding.locator.attemptID)
                #expect(context.childMutationsEnabled)
                admission.record(binding)
            })
            #expect(provider.capabilities.contains(.tools))
            let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            let wrapped = ScopedForwardingExecutor(base: owner)
            let ledgerRoot = root.appendingPathComponent(scenario + "-ledger")
            try FileManager.default.createDirectory(at: ledgerRoot, withIntermediateDirectories: true)
            let ledger = try minisCoreToolContractLedger(at: ledgerRoot)
            let orchestrator = AgentOrchestrator(maxIterationsPerTask: 2,
                provider: provider, toolExecutor: wrapped, approvalGate: gate,
                turnController: controller, currentConversationID: source.id,
                taskStore: store, sessionStore: sessions, toolExecutionFactLedger: ledger,
                parentID: parent.taskID, parentRuntimeIdentity: parent,
                parentTurnHandle: parentHandle, runtimeMode: .production,
                capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: parentTools),
                parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
                concreteBuiltinToolExecutorOwner: owner)
            #expect(orchestrator.childMutationsEnabled)
            let output = try await OrchestrationToolExecutor(orchestrator: orchestrator)
                .execute(name: "orchestrate", input: input)
            let envelope = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            let rows = try #require(envelope["results"] as? [[String: Any]])
            #expect(envelope["version"] as? Int == 1 && rows.count == 1)
            let row = try #require(rows.first)
            #expect(row["task_id"] as? String == scenario)
            let shouldRead = scenario == "omitted" || scenario == "narrowed"
            if shouldRead {
                let expected = scenario == "omitted" ? parentTools : Set(["file_read"])
                #expect(!provider.offeredToolNameSets.isEmpty)
                #expect(provider.offeredToolNameSets.allSatisfy { Set($0) == expected && Set($0).isSubset(of: parentTools) })
                #expect(row["status"] as? String == "succeeded" && row["summary"] as? String == "read-ok")
                #expect(wrapped.invokedNames == ["file_read"])
                #expect(ledger.facts.count == 1 && ledger.facts.first?.status == .succeeded)

            } else if scenario == "empty-capabilities" {
                #expect(provider.offeredToolNameSets.flatMap { $0 }.isEmpty)
                #expect(row["status"] as? String == "succeeded")
                #expect(row["summary"] as? String == "no-file-task-finished")

                #expect(wrapped.invokedNames.isEmpty && ledger.facts.isEmpty)
            } else {
                #expect(row["status"] as? String == "failed")
                #expect(row["summary"] as? String == "TASK_RESOURCE_SCOPE_INVALID")
                #expect(provider.offeredToolNameSets.isEmpty && wrapped.invokedNames.isEmpty && ledger.facts.isEmpty)
                #expect(admission.binding == nil)
            }
            if shouldRead || scenario == "empty-capabilities" {
                let live = try #require(admission.binding)
                let terminal = try #require(store.snapshot(taskID: scenario, parentID: parent.taskID))
                let locator = try #require(terminal.childTranscriptLocator)
                let receipt = try #require(store.receipt(runID: locator.runID))
                let result = try #require(receipt.childResultEnvelope)
                #expect(live.parent == parent)
                #expect(live.boundary.identity.rootParentIdentity == nil)
                #expect(live.boundary.identity.parentGoalID == nil && live.boundary.identity.parentGoalScopeID == nil)
                #expect(live.locator == locator && terminal.parentRuntimeIdentity == parent)
                #expect(terminal.status == .succeeded && receipt.outcome == .succeeded)
                #expect(result.childTranscriptLocator == locator && result.childExecutionID == locator.childExecutionID)
                #expect(result.runID == locator.runID && result.attemptID == locator.attemptID)
                #expect(live.boundary.identity.matchesVerifiedExecutionID(locator.childExecutionID))
                #expect(await live.boundary.parentTurnHandle?.isActive() == true)
                if shouldRead {
                    let fact = try #require(ledger.facts.first)
                    #expect(fact.parentRuntimeIdentity == parent && fact.childTranscriptLocator == locator)
                }
            }
        }
        #expect(await approval.tools == ["file_read", "file_read"])
        #expect(try String(contentsOf: file, encoding: .utf8) == marker)
    }
}

@Suite("N01 child clarification contract")
struct N01ChildClarificationTests {
    @Test func childQuestionReturnsStructuredNeedsClarificationToItsParent() async throws {
        let root = try minisCoreToolContractRoot("n01-child-question")
        defer { try? FileManager.default.removeItem(at: root) }
        let request = UserQuestionRequest(questions: [.init(question: "Choose?", header: "Choice", options: [
            .init(label: "A", description: "first"), .init(label: "B", description: "second")])])
        let json = String(decoding: try JSONEncoder().encode(request.questions), as: UTF8.self)
        let provider = ScriptedChildProvider(responses: [orchEnvelope(id: "child-question", name: "ask_user",
            input: ["questions_json": json])])
        let reports = await AgentOrchestrator()
            .withBuiltinExecution(provider: provider, toolExecutor: BuiltinToolExecutor(allowedRoot: root))
            .orchestrate(tasks: [SubAgentTask(id: "child", title: "needs decision", instructions: "synthetic")], strategy: .sequential)
        let error = try #require(reports.first?.result.error)
        let result = try JSONDecoder().decode(UserQuestionResult.self, from: Data(error.utf8))
        #expect(result.status == .needsClarification && result.answers.isEmpty)
        #expect(result.questions == request.questions)
        #expect(provider.receivedRequests.count == 1)
    }

    @Test func questionWithoutMultiSelectParsesAsSingleChoice() throws {
        // 第七版真实旅程：DeepSeek 省略 multiSelect，旧解码报 keyNotFound（界面显示“数据丢失”）。
        let json = #"[{"question":"负数怎么处理？","header":"负数","options":[{"label":"报错","description":"传负数直接抛异常"},{"label":"按 0 处理","description":"负数视为 0"}]}]"#
        let request = try AskUserQuestionTool.parse(["questions_json": json])
        #expect(request.questions.count == 1)
        #expect(request.questions[0].multiSelect == false)
        let explicit = #"[{"question":"选哪些？","header":"多选","options":[{"label":"A","description":"a"},{"label":"B","description":"b"}],"multiSelect":true}]"#
        #expect(try AskUserQuestionTool.parse(["questions_json": explicit]).questions[0].multiSelect == true)
    }

    @Test func questionLimitsRejectInvalidQuestionAndOptionCounts() throws {
        let options: [UserQuestionRequest.Option] = [.init(label: "A", description: "first"), .init(label: "B", description: "second")]
        let valid = UserQuestionRequest.Question(question: "Choose?", header: "Choice", options: options)
        try UserQuestionRequest(questions: [valid]).validate()
        #expect(throws: AskUserQuestionTool.InputError.self) { try UserQuestionRequest(questions: []).validate() }
        let five = (0..<5).map { UserQuestionRequest.Question(question: "Question \($0)", header: "Choice", options: options) }
        #expect(throws: AskUserQuestionTool.InputError.self) { try UserQuestionRequest(questions: five).validate() }
        let oneOption = UserQuestionRequest.Question(question: "Choose?", header: "Choice", options: Array(options.prefix(1)))
        #expect(throws: AskUserQuestionTool.InputError.self) { try UserQuestionRequest(questions: [oneOption]).validate() }
        let fiveOptions = (1...5).map { UserQuestionRequest.Option(label: "Option \($0)", description: "distinct") }
        let invalid: [[UserQuestionRequest.Question]] = [
            [.init(question: "Choose?", header: "Choice", options: fiveOptions)],
            [.init(question: "Choose?", header: String(repeating: "h", count: 13), options: options)],
            [valid, valid],
            [.init(question: "Choose?", header: "Choice", options: [options[0], options[0]])],
            [.init(question: String(repeating: "q", count: 401), header: "Choice", options: options)],
            [.init(question: "Choose?", header: "Choice", options: [
                .init(label: String(repeating: "l", count: 81), description: "description"), options[1]])],
            [.init(question: "Choose?", header: "Choice", options: [
                .init(label: "A", description: String(repeating: "d", count: 401)), options[1]])]
        ]
        for questions in invalid {
            #expect(throws: AskUserQuestionTool.InputError.self) { try UserQuestionRequest(questions: questions).validate() }
        }
        let oversizedAnswer = UserQuestionResult(status: .answered, request: .init(questions: [valid]),
            answers: ["Choose?": [String(repeating: "x", count: 1001)]])
        #expect(throws: AskUserQuestionTool.InputError.self) { try oversizedAnswer.encoded() }
    }
}

extension AgentOrchestratorTests {
    /// Exercises the production append -> appendLocked -> SessionStore path.
    private func storedTodoChildTranscript(_ messages: [LLMMessage]) throws -> [LLMMessage] {
        let root = try minisCoreToolContractRoot("n02-child-transcript")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let parentSession = try sessions.createSession(id: "n02-parent-session")
        let parent = ParentRuntimeIdentity(sessionID: parentSession.id, conversationID: parentSession.id,
            turnID: "turn-handle:1", taskID: "n02-parent-task", actorID: "owned-test")
        let identity = try ChildRuntimeIdentity.derive(parent: parent,
            childSessionID: "n02-child-session", childTaskID: "n02-child-task", scopeID: "n02-scope",
            requestedCapabilities: [.tools], parentCapabilities: [.tools], policyCapabilities: [.tools],
            providerSnapshot: ParentContextSnapshotV1(providerID: "synthetic", modelID: "synthetic",
                configurationFingerprint: "synthetic", conversationID: parentSession.id),
            memoryScopeID: "n02-memory", workingDirectory: root.path, cancelGeneration: 1,
            evidenceRoot: root.path, childExecutionID: "n02-execution")
        let tasks = AgentTaskStore()
        _ = try tasks.enqueue(taskID: identity.childTaskID, parentID: parent.taskID,
            providerID: "synthetic", modelID: "synthetic", parentRuntimeIdentity: parent)
        let run = try tasks.startRun(taskID: identity.childTaskID, parentID: parent.taskID, runID: "n02-run")
        let snapshot = try #require(tasks.snapshot(taskID: identity.childTaskID, parentID: parent.taskID))
        let writer = try AgentOrchestrator.ChildTranscriptWriter(store: sessions, taskStore: tasks,
            task: SubAgentTask(id: identity.childTaskID, title: "待办", instructions: "记录进度",
                executionID: "n02-execution"),
            taskSnapshot: snapshot, runID: run.runID, attemptID: "n02-run:attempt:1", childIdentity: identity)
        _ = try tasks.bindChildTranscript(writer.locator)
        for (index, message) in messages.enumerated() {
            try writer.append(index: index, message: message)
        }
        return try #require(sessions.loadSession(id: identity.childSessionID)).messages
    }

    private func todoWriterCall(_ id: String, name: String = "todo_write") -> LLMMessage {
        LLMMessage(role: .assistant, content: "", toolCalls: [
            LLMToolCall(id: id, name: name, rawArguments: "{\"private\":\"not-retained\"}",
                arguments: ["private": "not-retained"])
        ])
    }

    @Test func childWriterRetainsOnlyMatchedSuccessfulNativeTodoResults() throws {
        let payload = try SessionTodoProgress.execute(input: ["progress": ["todos": [
            ["content": "读取报表 /Users/private/report.txt", "status": "in_progress"]
        ]]])
        let stored = try storedTodoChildTranscript([
            .init(role: .user, content: "整理报表"),
            todoWriterCall("other", name: "file_read"),
            .init(role: .tool, content: "private-file-result", toolCallID: "other"),
            todoWriterCall("error"),
            .init(role: .tool, content: "tool execution failed: private-error", toolCallID: "error"),
            todoWriterCall("expected"),
            .init(role: .tool, content: payload, toolCallID: "wrong-id"),
            todoWriterCall("success"),
            .init(role: .tool, content: payload, toolCallID: "success")
        ])
        for index in [2, 4, 6] { #expect(stored[index].content == "[工具结果内容已省略]") }
        #expect(stored[8].content.contains("读取报表"))
        #expect(!stored[8].content.contains("/Users/private/report.txt"))
        #expect(SessionTodoProgress.latest(in: stored)?.currentItem?.content == "读取报表 <path>")
        #expect(stored.filter { $0.role == .assistant }.flatMap(\.toolCalls).allSatisfy {
            $0.rawArguments == "{}" && $0.arguments.isEmpty
        })
    }

    @Test func childWriterLegacyUserResultsKeepOnlySuccessfulMatchedTodo() throws {
        let payload = try SessionTodoProgress.execute(input: ["progress": ["todos": [
            ["content": "读取报表", "status": "in_progress"]
        ]]])
        func result(_ id: String, error: Bool = false) throws -> LLMMessage {
            .init(role: .user, content: String(decoding: try JSONSerialization.data(withJSONObject: [[
                "type": "tool_result", "tool_use_id": id, "content": payload, "is_error": error
            ]]), as: UTF8.self))
        }
        func call(_ id: String, name: String = "todo_write") -> LLMMessage {
            .init(role: .assistant, content: orchEnvelope(id: id, name: name, input: [:]))
        }
        let stored = try storedTodoChildTranscript([
            .init(role: .user, content: "整理报表"),
            call("other", name: "file_read"), try result("other"),
            call("error"), try result("error", error: true),
            call("expected"), try result("wrong-id"),
            call("success"), try result("success")
        ])
        for index in [2, 4, 6] { #expect(stored[index].content == "[工具结果内容已省略]") }
        #expect(stored[8].content.contains("读取报表"))
        #expect(SessionTodoProgress.latest(in: stored)?.summary == "0/1 · 正在：读取报表")
        #expect(stored[7].toolCalls.first?.rawArguments == "{}")
    }
}
