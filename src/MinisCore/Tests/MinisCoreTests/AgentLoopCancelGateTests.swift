import Foundation
import Testing
@testable import MinisCore

// MARK: - F3 取消闭环：gate 通过后、execute 前复查取消
//
// 场景：审批弹窗挂起期间用户按了停止。ApprovalPromptCenter.stopGeneration 会把
// 挂起的 continuation 按拒绝恢复（gate 抛 denied，走 is_error 回传）；但存在竞态：
// delegate 返回绑定批准时中断信号可能已经生效（用户先点允许、几乎同时按停止，
// 或 Task 被取消）。审批门与 AgentLoop 均需阻止随后执行。本文件覆盖：
//   · controller 中断 → InterruptedError 上抛，工具不执行
//   · Task 取消 → CancellationError 上抛，工具不执行

/// 脚本 Provider：按序返回预设回复。
private final class F3GateCancelMockProvider: LLMProvider, @unchecked Sendable {
    var name: String { "F3GateCancelMock" }
    var model = LLMModel(id: "f3", displayName: "F3", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }
    var responses: [String]

    init(responses: [String]) { self.responses = responses }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
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

/// 记录执行（不真正执行）：断言「工具未被交给执行器」。
private final class F3RecordingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _executedNames: [String] = []
    var executedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _executedNames
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        record(name)
        return "executed \(name)"
    }

    /// 记录工具名（同步方法内加锁，避免 async 上下文的 NSLock 限制）。
    private func record(_ name: String) {
        lock.lock()
        _executedNames.append(name)
        lock.unlock()
    }
}

private actor F3ApprovalProbe {
    private(set) var requests: [ApprovalRequest] = []

    func record(_ request: ApprovalRequest) {
        requests.append(request)
    }
}

/// 审批挂起中先置位中断、再返回绑定的批准 —— 模拟「用户按了停止之后又点了允许」。
private final class F3InterruptThenApproveDelegate: ApprovalDelegate, @unchecked Sendable {
    let controller: TurnController
    let probe: F3ApprovalProbe

    init(controller: TurnController, probe: F3ApprovalProbe) {
        self.controller = controller
        self.probe = probe
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await probe.record(request)
        await controller.interrupt()
        return ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

/// 持有外层 Task 引用：审批挂起中取消外层 Task、再返回 approved。
private final class F3TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTask: Task<AgentLoopResult, Error>?

    var task: Task<AgentLoopResult, Error>? {
        get { lock.withLock { storedTask } }
        set { lock.withLock { storedTask = newValue } }
    }
}

private final class F3CancelTaskThenApproveDelegate: ApprovalDelegate, @unchecked Sendable {
    let box: F3TaskBox
    let probe: F3ApprovalProbe

    init(box: F3TaskBox, probe: F3ApprovalProbe) {
        self.box = box
        self.probe = probe
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await probe.record(request)
        // 等外层测试把 Task 引用装进盒子（避免 task 尚未赋值就取消的竞态）
        for _ in 0..<500 where box.task == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        box.task?.cancel()
        return ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

/// 工具调用 envelope。
private func f3ToolCallEnvelope(id: String, name: String, input: [String: Any]) -> String {
    let object: [String: Any] = ["tool_calls": [["id": id, "name": name, "input": input]]]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

private func f3ParentIdentitySeed(for identity: AgentExecutionIdentity) -> ParentRuntimeIdentitySeed {
    ParentRuntimeIdentitySeed(
        sessionID: identity.turn.sessionID,
        conversationID: identity.turn.sessionID,
        taskID: "task:\(identity.operationID)",
        actorID: "test"
    )
}

struct AgentLoopCancelGateTests {

    @Test func interruptDuringApprovalPreventsExecutionAfterGateApproves() async throws {
        // delegate 返回绑定批准之前发生中断；旧回合必须终止且工具不执行。
        let executor = F3RecordingExecutor()
        let controller = TurnController()
        let probe = F3ApprovalProbe()
        let gate = ApprovalGate(delegate: F3InterruptThenApproveDelegate(controller: controller, probe: probe))
        let root = try minisCoreToolContractRoot("f3-interrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("f3-interrupt")
        let loop = AgentLoop(
            maxIterations: 5,
            approvalGate: gate,
            turnController: controller,
            timeout: 30,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let provider = F3GateCancelMockProvider(responses: [
            f3ToolCallEnvelope(id: "c1", name: "shell_execute", input: ["command": "echo hi"]),
            "完成。",
        ])

        await #expect(throws: InterruptedError.self) {
            _ = try await loop.run(
                messages: [],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: executor,
                tools: minisCoreToolContractCatalog(["shell_execute"]),
                currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: f3ParentIdentitySeed(for: identity),
                executionIdentity: identity
            )
        }
        let requests = await probe.requests
        #expect(requests.count == 1)
        #expect(requests.first?.binding != nil)
        #expect(executor.executedNames.isEmpty, "中断后的绑定批准不得触发工具")
        // 中断的回合应标记结束
        #expect(await controller.isRunning == false)
    }

    @Test func taskCancellationDuringApprovalPreventsExecutionAfterGateApproves() async throws {
        // delegate 返回绑定批准之前发生 Task 取消；工具不得执行。
        let executor = F3RecordingExecutor()
        let box = F3TaskBox()
        let controller = TurnController()
        let probe = F3ApprovalProbe()
        let gate = ApprovalGate(delegate: F3CancelTaskThenApproveDelegate(box: box, probe: probe))
        let root = try minisCoreToolContractRoot("f3-task-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("f3-task-cancel")
        let loop = AgentLoop(
            maxIterations: 5,
            approvalGate: gate,
            turnController: controller,
            timeout: 30,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let provider = F3GateCancelMockProvider(responses: [
            f3ToolCallEnvelope(id: "c1", name: "file_write", input: ["path": "/tmp/x", "content": "y"]),
            "完成。",
        ])

        let task = Task {
            try await loop.run(
                messages: [],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: executor,
                tools: minisCoreToolContractCatalog(["file_write"]),
                currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: f3ParentIdentitySeed(for: identity),
                executionIdentity: identity
            )
        }
        box.task = task

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let requests = await probe.requests
        #expect(requests.count == 1)
        #expect(requests.first?.binding != nil)
        #expect(executor.executedNames.isEmpty, "Task 取消后的绑定批准不得触发工具")
    }

    @Test func approveWithoutCancellationStillExecutes() async throws {
        // 对照：无取消时 approve → 工具正常执行（复查不干扰正常路径）。
        actor F3ApproveAllDelegate: ApprovalDelegate {
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
        let executor = F3RecordingExecutor()
        let controller = TurnController()
        let delegate = F3ApproveAllDelegate()
        let gate = ApprovalGate(delegate: delegate)
        let root = try minisCoreToolContractRoot("agent-loop-cancel-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("agent-loop-cancel-gate")
        let loop = AgentLoop(
            maxIterations: 5,
            approvalGate: gate,
            turnController: controller,
            timeout: 30,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let provider = F3GateCancelMockProvider(responses: [
            f3ToolCallEnvelope(id: "c1", name: "shell_execute", input: ["command": "echo hi"]),
            "完成。",
        ])

        let result = try await loop.run(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["shell_execute"]),
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: f3ParentIdentitySeed(for: identity),
            executionIdentity: identity
        )
        let requests = await delegate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.binding != nil)
        #expect(executor.executedNames == ["shell_execute"])
        #expect(result.toolCallsExecuted == 1)
    }
}
