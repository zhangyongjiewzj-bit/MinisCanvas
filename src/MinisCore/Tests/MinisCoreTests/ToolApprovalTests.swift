import Foundation
import Testing
@testable import MinisCore

// E1 工具审批流: ApprovalGate 策略 / 委托 / 拒绝 + AgentLoop 可选 hook。

// MARK: - Mocks

/// Scripted approval delegate: records every request, returns canned decisions
/// in order (last one repeats).
final class MockApprovalDelegate: ApprovalDelegate, @unchecked Sendable {
    var decisions: [ApprovalDecision]
    private(set) var requests: [ApprovalRequest] = []

    init(decisions: [ApprovalDecision]) {
        self.decisions = decisions
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        let decision = decisions.isEmpty ? .deny : decisions.removeFirst()
        guard request.binding != nil, decision.approved else { return decision }
        return ApprovalDecision(
            approved: true,
            reason: decision.reason,
            confirmed: decision.confirmed,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private final class ApprovalGateTaskBox: @unchecked Sendable {
    var task: Task<ApprovalDecision, Error>?
}

private final class ApprovalReceiptBox: @unchecked Sendable {
    var receipts: [ApprovalReceipt] = []
}

private final class CancelThenApproveDelegate: ApprovalDelegate, @unchecked Sendable {
    let taskBox: ApprovalGateTaskBox

    init(taskBox: ApprovalGateTaskBox) {
        self.taskBox = taskBox
    }

    func requestApproval(_: ApprovalRequest) async -> ApprovalDecision {
        while taskBox.task == nil {
            await Task.yield()
        }
        taskBox.task?.cancel()
        return .approve
    }
}

/// Records every tool call instead of executing it.
final class RecordingToolExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var executedNames: [String] { lock.withLock { names } }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { names.append(name) }
        return "executed \(name)"
    }
}

/// Scripted LLM provider: one canned response per `sendMessage` call.
/// (Renamed to avoid clashing with `MockLLMProvider` in AgentLoopTests.)
final class ToolApprovalMockLLMProvider: LLMProvider {
    var name: String { "Mock" }
    var model: LLMModel
    var capabilities: Set<ProviderCapability> { [.tools] }
    var responses: [String]

    init(model: LLMModel = .claudeHaiku45, responses: [String]) {
        self.model = model
        self.responses = responses
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
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

/// Build a tool-call envelope response string.
private func toolCallEnvelope(id: String, name: String, input: [String: Any]) -> String {
    let object: [String: Any] = ["tool_calls": [["id": id, "name": name, "input": input]]]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

// MARK: - ApprovalGate: 默认策略

struct ToolApprovalGatePolicyTests {

    @Test func externalOrchestrationRequestRequiresHighRiskOneTimeApproval() throws {
        let gate = ApprovalGate(delegate: MockApprovalDelegate(decisions: [.deny]))
        func task(_ id: String, agent: String) -> [String: Any] {
            let isExternal = agent == "external:claude"
            return ["id": id, "title": isExternal ? "External review" : "Internal review",
                    "instructions": isExternal ? "Summarize the synthetic note." : "Return a short summary.", "agent": agent]
        }
        let internalTask = task("internal", agent: "builtin")
        let internalInput: [String: Any] = ["input_version": OrchestrateRequestV1.inputVersion, "tasks": [internalTask]]
        let internalDecoded = try OrchestrateRequestV1.decode(input: internalInput, maxTasks: 2)
        try #require(internalDecoded.tasks.map(\.agent) == ["builtin"])
        let internalRequest = gate.makeRequest(tool: "orchestrate", input: internalInput)
        let mixedInput: [String: Any] = [
            "input_version": OrchestrateRequestV1.inputVersion,
            "tasks": [internalTask, task("external", agent: "external:claude")]
        ]
        let mixedDecoded = try OrchestrateRequestV1.decode(input: mixedInput, maxTasks: 2)
        try #require(mixedDecoded.tasks.map(\.agent) == ["builtin", "external:claude"])
        let mixedRequest = gate.makeRequest(tool: "orchestrate", input: mixedInput)

        #expect(internalRequest.riskLevel == .medium)
        #expect(!internalRequest.requiresSecondConfirmation)
        #expect(mixedRequest.riskLevel == .high)
        #expect(mixedRequest.requiresApproval)
        #expect(!mixedRequest.requiresSecondConfirmation)
        #expect(mixedRequest.persistentAllowOffer == nil)
        let warning = "外部程序以你的用户身份在本机运行，可以读写你有权限访问的文件，不受本应用的文件范围、Hooks 和审批约束。"
        #expect(mixedRequest.inputSummary.contains("启动外部程序：claude"))
        #expect(mixedRequest.inputSummary.contains(warning))
        #expect(mixedRequest.inputSummary.contains("External review（external:claude）：Summarize the synthetic note."))
        #expect(!internalRequest.inputSummary.contains(warning))
    }

    @Test func defaultPolicyHighRiskToolsAsk() {
        let gate = ApprovalGate()
        #expect(gate.shouldAsk(tool: "file_write", input: ["path": "/tmp/a.txt"]))
        #expect(gate.shouldAsk(tool: "file_edit", input: ["path": "/tmp/a.txt"]))
        #expect(gate.shouldAsk(tool: "shell_execute", input: ["command": "echo hi"]))
        #expect(gate.riskLevel(for: "file_write") == .high)
        #expect(gate.riskLevel(for: "file_edit") == .high)
        #expect(gate.riskLevel(for: "shell_execute") == .high)
    }

    @Test func defaultPolicyLowRiskToolsAutoApprove() {
        let gate = ApprovalGate()
        #expect(!gate.shouldAsk(tool: "file_read", input: ["path": "/tmp/a.txt"]))
        #expect(!gate.shouldAsk(tool: "browser", input: ["url": "https://example.com"]))
        #expect(!gate.shouldAsk(tool: "browser_use", input: ["url": "https://example.com"]))
        #expect(!gate.shouldAsk(tool: "speech", input: ["text": "hello"]))
        // Reading another session is asked on every call (card shows target + scope).
        #expect(gate.shouldAsk(tool: "session_read", input: ["session_id": "s1", "scope": "metadata"]))
        #expect(gate.riskLevel(for: "file_read") == .low)
        #expect(gate.riskLevel(for: "speech") == .low)
        #expect(gate.riskLevel(for: "session_read") == .low)
    }

    @Test func unknownToolDefaultsToAskAndMediumRisk() {
        let gate = ApprovalGate()
        #expect(gate.shouldAsk(tool: "mcp_files_rm", input: [:]))
        #expect(gate.riskLevel(for: "mcp_files_rm") == .medium)
    }

    @Test func customPolicyOverridesMergeWithDefaults() {
        let gate = ApprovalGate(policyByTool: ["file_write": .never, "file_read": .alwaysAsk])
        // Overrides applied…
        #expect(gate.shouldAsk(tool: "file_read", input: ["path": "/tmp/a.txt"]))
        // …while untouched defaults survive.
        #expect(!gate.shouldAsk(tool: "speech", input: ["text": "hi"]))
        #expect(gate.policy(for: "file_write") == .never)
    }

    @Test func riskOnlyAskAutoApprovesLowRiskAndAsksHighRisk() async throws {
        let delegate = MockApprovalDelegate(decisions: [.approve])
        let gate = ApprovalGate(policy: .riskOnlyAsk, delegate: delegate)

        #expect(gate.policy(for: "file_read") == .autoApprove)
        #expect(gate.policy(for: "file_write") == .alwaysAsk)
        _ = try await gate.gate(tool: "file_read", input: ["path": "/tmp/a.txt"])
        _ = try await gate.gate(tool: "file_write", input: ["path": "/tmp/a.txt", "content": "x"])

        #expect(delegate.requests.count == 1)
        #expect(delegate.requests.first?.toolName == "file_write")
        // The legacy policy-only entry has no verified turn or attempt to bind.
        // The AgentLoop approval tests below exercise the bound production entry.
        #expect(delegate.requests.first?.binding == nil)
    }

    @Test func denyPolicyRemainsFailClosed() async {
        let gate = ApprovalGate(policy: .deny)
        await #expect(throws: ApprovalError.denied(reason: "Tool 'file_read' is blocked by policy")) {
            try await gate.gate(tool: "file_read", input: ["path": "/tmp/a.txt"])
        }
    }

    @Test func approvedCallEmitsRedactedReceipt() async throws {
        let box = ApprovalReceiptBox()
        let gate = ApprovalGate(
            policy: .riskOnlyAsk,
            delegate: MockApprovalDelegate(decisions: [.approve]),
            onApprovalReceipt: { receipt in
                box.receipts.append(receipt)
            }
        )

        _ = try await gate.gate(
            tool: "file_write",
            input: ["path": "/tmp/a.txt", "content": "secret-body"]
        )

        let receipt = try #require(box.receipts.first)
        #expect(receipt.toolName == "file_write")
        #expect(receipt.policy == .alwaysAsk)
        #expect(!receipt.inputSummary.contains("secret-body"))
        #expect(receipt.inputSummary.contains("<redacted>"))
    }
}

// MARK: - ApprovalGate: gate 放行 / 拒绝

struct ToolApprovalGateDecisionTests {

    @Test func externalOrchestrationHardDenialsSkipDelegate() async throws {
        let input: [String: Any] = ["input_version": OrchestrateRequestV1.inputVersion, "tasks": [
            ["id": "internal", "title": "Internal review", "instructions": "Summarize.", "agent": "builtin"],
            ["id": "external", "title": "External review", "instructions": "Summarize.", "agent": "external:claude"]
        ]]
        let decoded = try OrchestrateRequestV1.decode(input: input, maxTasks: 2)
        try #require(decoded.tasks.map(\.agent) == ["builtin", "external:claude"])

        for policy in [ApprovalPolicy.deny, .never] {
            let blockedDelegate = MockApprovalDelegate(decisions: [.deny])
            let blockedGate = ApprovalGate(policyByTool: ["orchestrate": policy], delegate: blockedDelegate)
            await #expect(throws: ApprovalError.denied(reason: "Tool 'orchestrate' is blocked by policy")) {
                try await blockedGate.gate(tool: "orchestrate", input: input)
            }
            #expect(blockedDelegate.requests.isEmpty)
        }
    }

    @Test func autoApproveSkipsDelegate() async throws {
        let delegate = MockApprovalDelegate(decisions: [])
        let gate = ApprovalGate(delegate: delegate)
        let decision = try await gate.gate(tool: "file_read", input: ["path": "/tmp/a.txt"])
        #expect(decision.approved)
        #expect(delegate.requests.isEmpty) // 低风险工具不打扰委托
    }

    @Test func delegateApprovalLetsCallThrough() async throws {
        let delegate = MockApprovalDelegate(decisions: [ApprovalDecision(approved: true, reason: "ok", confirmed: true)])
        let gate = ApprovalGate(delegate: delegate)
        let decision = try await gate.gate(tool: "file_write", input: ["path": "/tmp/a.txt", "content": "hello"])
        #expect(decision.approved)
        #expect(delegate.requests.count == 1)
        let request = try #require(delegate.requests.first)
        #expect(request.toolName == "file_write")
        #expect(request.requiresApproval)
        #expect(request.riskLevel == .high)
        // 脱敏: content 被遮蔽, path 可见。
        #expect(!request.inputSummary.contains("hello"))
        #expect(request.inputSummary.contains("<redacted>"))
        #expect(request.inputSummary.contains("/tmp/a.txt"))
    }

    @Test func delegateDenialThrowsDenied() async {
        let delegate = MockApprovalDelegate(decisions: [ApprovalDecision(approved: false, reason: "用户拒绝")])
        let gate = ApprovalGate(delegate: delegate)
        await #expect(throws: ApprovalError.denied(reason: "用户拒绝")) {
            try await gate.gate(tool: "file_write", input: ["path": "/tmp/a.txt", "content": "x"])
        }
    }

    @Test func neverPolicyDeniesWithoutDelegate() async {
        let gate = ApprovalGate(policyByTool: ["shell_execute": .never])
        await #expect(throws: ApprovalError.denied(reason: "Tool 'shell_execute' is blocked by policy")) {
            try await gate.gate(tool: "shell_execute", input: ["command": "rm -rf /"])
        }
    }

    @Test func alwaysAskWithoutDelegateDenies() async {
        let gate = ApprovalGate() // 无 delegate
        await #expect(throws: ApprovalError.denied(reason: "No approval delegate configured for tool 'file_write'")) {
            try await gate.gate(tool: "file_write", input: ["path": "/tmp/a.txt"])
        }
    }

    @Test func cancellationAfterDelegateApprovalDoesNotReturnApproval() async {
        let taskBox = ApprovalGateTaskBox()
        let gate = ApprovalGate(
            delegate: CancelThenApproveDelegate(taskBox: taskBox)
        )
        let task = Task<ApprovalDecision, Error> {
            try await gate.gate(
                tool: "file_write",
                input: ["path": "/tmp/a.txt", "content": "cancelled"]
            )
        }
        taskBox.task = task

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test func inputSummaryMasksSecretsAndTruncates() {
        let summary = ApprovalGate.makeInputSummary([
            "command": "curl -s https://api.example.com/endpoint/with/a/very/long/path/that/keeps/going/and/going/forever",
            "api_key": "sk-123456",
            "path": "/tmp/visible.txt",
            "count": 3,
        ])
        #expect(!summary.contains("sk-123456"))
        #expect(summary.contains("api_key: <redacted>"))
        #expect(summary.contains("/tmp/visible.txt"))
        #expect(summary.contains("…")) // 长字符串被截断
        #expect(ApprovalGate.makeInputSummary([:]) == "(no input)")
    }

    // MARK: P3 live-security slice — content-level redaction of embedded secrets
    // in approval summaries. A non-secret-looking key (command / url / query)
    // can still carry an embedded Bearer / API-key / cookie / userinfo value;
    // the summary must mask the value while preserving non-secret text.

    @Test func inputSummaryRedactsEmbeddedBearerInCommand() {
        let summary = ApprovalGate.makeInputSummary([
            "command": "curl -H 'Authorization: Bearer sk-test1234567890abcdef' https://x.com",
        ])
        #expect(!summary.contains("sk-test1234567890abcdef"))
        #expect(summary.contains("curl"))
        #expect(summary.contains("https://x.com"))
    }

    @Test func inputSummaryRedactsEmbeddedUserinfoInURL() {
        let summary = ApprovalGate.makeInputSummary([
            "url": "https://user:secretpass@example.com/path",
        ])
        #expect(!summary.contains("user:secretpass"))
        #expect(summary.contains("@example.com/path"))
        #expect(summary.contains("https://"))
    }

    @Test func inputSummaryRedactsEmbeddedCookieHeader() {
        let summary = ApprovalGate.makeInputSummary([
            "command": "curl -H 'Cookie: session=abc123def456' https://x.com",
        ])
        #expect(!summary.contains("abc123def456"))
        #expect(summary.contains("Cookie:"))
        #expect(summary.contains("https://x.com"))
    }

    @Test func inputSummaryPreservesNonSecretCommandText() {
        let summary = ApprovalGate.makeInputSummary([
            "command": "ls -la /tmp && echo done",
        ])
        #expect(summary.contains("ls -la /tmp"))
        #expect(summary.contains("echo done"))
    }

    @Test func gateRequestSummaryRedactsEmbeddedSecrets() async throws {
        let delegate = MockApprovalDelegate(decisions: [.deny])
        let gate = ApprovalGate(delegate: delegate)
        _ = try? await gate.gate(
            tool: "shell_execute",
            input: ["command": "curl -H 'Authorization: Bearer sk-test1234567890abcdef' https://api.example.com/v1", "tool_title": "Owned internal title", "cwd": "/owned/fixture", "timeout": 41, "delay": 2]
        )
        let request = try #require(delegate.requests.first)
        #expect(!request.inputSummary.contains("sk-test1234567890abcdef"))
        #expect(request.inputSummary.contains("curl"))
        #expect(!request.inputSummary.contains("tool_title") && !request.inputSummary.contains("Owned internal title")
            && request.inputSummary.contains("cwd: /owned/fixture")
            && request.inputSummary.contains("timeout: 41") && request.inputSummary.contains("delay: 2"))
    }
}

// MARK: - AgentLoop 接线

struct ToolApprovalAgentLoopTests {
    @Test func globalAutoApproveStillAsksForEachNonComposerFileDelete() async throws {
        let delegate = MockApprovalDelegate(decisions: [.deny, .deny])
        let gate = ApprovalGate(policy: .autoApprove, delegate: delegate)
        #expect(gate.policy(for: "file_delete") == .alwaysAsk)
        #expect(gate.policy(for: "file_write") == .autoApprove)
        #expect(gate.policy(for: "file_edit") == .autoApprove)
        let root = try minisCoreToolContractRoot("tool-approval-delete-auto")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("tool-approval-delete-auto")
        let loop = AgentLoop(
            maxIterations: 5, approvalGate: gate,
            turnController: TurnController(), timeout: 30,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let executor = RecordingToolExecutor()
        let input: [String: Any] = ["path": root.appendingPathComponent("synthetic.txt").path]
        let provider = ToolApprovalMockLLMProvider(responses: [
            toolCallEnvelope(id: "delete_1", name: "file_delete", input: input),
            toolCallEnvelope(id: "delete_2", name: "file_delete", input: input),
            "denied twice"
        ])
        let result = try await loop.run(
            messages: [], systemPrompt: "test", provider: provider,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_delete"]),
            maxTokens: 1024,
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID,
                taskID: "task:tool-approval-delete-auto", actorID: "test"
            ),
            executionIdentity: identity
        )
        #expect(delegate.requests.count == 2)
        #expect(delegate.requests.allSatisfy { $0.toolName == "file_delete" && $0.binding != nil })
        #expect(executor.executedNames.isEmpty)
        #expect(result.toolCallsExecuted == 0)
    }

    @Test func deniedToolNeverReachesExecutor() async throws {
        let delegate = MockApprovalDelegate(decisions: [.deny])
        let gate = ApprovalGate(delegate: delegate)
        let root = try minisCoreToolContractRoot("tool-approval-denied")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("tool-approval-denied")
        let loop = AgentLoop(
            maxIterations: 5,
            approvalGate: gate,
            turnController: TurnController(),
            timeout: 30,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let executor = RecordingToolExecutor()
        let mock = ToolApprovalMockLLMProvider(responses: [
            toolCallEnvelope(id: "call_1", name: "file_write", input: ["path": "/tmp/a.txt", "content": "x"]),
            "已收到,不再写入。",
        ])

        let result = try await loop.run(
            messages: [],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_write"]),
            maxTokens: 1024,
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID,
                taskID: "task:tool-approval-denied",
                actorID: "test"
            ),
            executionIdentity: identity
        )

        // 拒绝的工具没有执行。
        #expect(executor.executedNames.isEmpty)
        // 被拒绝的调用从未到达执行器 → 不计入 toolCallsExecuted。
        #expect(result.toolCallsExecuted == 0)
        // 循环没有崩溃,模型收到 is_error 结果后继续。
        #expect(result.messages.count == 3) // assistant(envelope) + user(tool_result) + assistant(final)
        #expect(result.messages.last?.role == .assistant)
        #expect(result.messages.last?.content == "已收到,不再写入。")
        // 回传的是带拒绝信息的 is_error tool_result。
        let deniedResults = result.messages.compactMap { msg -> String? in
            for part in msg.toAgentContentParts() {
                if case .toolResult(_, _, let content, let isError, _, _, _, _) = part, isError {
                    return content
                }
            }
            return nil
        }
        #expect(deniedResults.count == 1)
        #expect(deniedResults.first?.contains("审批被拒绝") == true)
        // 委托确实收到了请求。
        #expect(delegate.requests.count == 1)
        #expect(delegate.requests.first?.toolName == "file_write")
    }

    @Test func approvedToolExecutesNormally() async throws {
        let delegate = MockApprovalDelegate(decisions: [.approve])
        let gate = ApprovalGate(delegate: delegate)
        let root = try minisCoreToolContractRoot("tool-approval-approved")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("tool-approval-approved")
        let loop = AgentLoop(
            maxIterations: 5,
            approvalGate: gate,
            turnController: TurnController(),
            timeout: 30,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let executor = RecordingToolExecutor()
        let mock = ToolApprovalMockLLMProvider(responses: [
            toolCallEnvelope(id: "call_1", name: "file_write", input: ["path": "/tmp/a.txt", "content": "x"]),
            "写入完成。",
        ])

        let result = try await loop.run(
            messages: [],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_write"]),
            maxTokens: 1024,
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID,
                taskID: "task:tool-approval-approved",
                actorID: "test"
            ),
            executionIdentity: identity
        )

        #expect(executor.executedNames == ["file_write"])
        #expect(result.toolCallsExecuted == 1)
        #expect(result.messages.last?.content == "写入完成。")
        #expect(delegate.requests.count == 1)
        #expect(delegate.requests.first?.binding != nil)
        // 成功结果以非 error tool_result 回传。
        let okResults = result.messages.compactMap { msg -> String? in
            for part in msg.toAgentContentParts() {
                if case .toolResult(_, _, let content, let isError, _, _, _, _) = part, !isError {
                    return content
                }
            }
            return nil
        }
        #expect(okResults == ["executed file_write"])
    }

    @Test func noGateAllowsCanonicalLowRiskBehavior() async throws {
        // approvalGate == nil: custom executor 只允许 canonical 低风险工具；
        // 高风险能力必须有显式 gate。
        let root = try minisCoreToolContractRoot("tool-approval-no-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("tool-approval-no-gate")
        let loop = AgentLoop(
            maxIterations: 5,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let executor = RecordingToolExecutor()
        let mock = ToolApprovalMockLLMProvider(responses: [
            toolCallEnvelope(id: "call_1", name: "file_read", input: ["path": "/tmp/a.txt"]),
            "done",
        ])

        _ = try await loop.run(
            messages: [],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_read"]),
            maxTokens: 1024,
            executionIdentity: identity
        )

        #expect(executor.executedNames == ["file_read"])
    }
}
