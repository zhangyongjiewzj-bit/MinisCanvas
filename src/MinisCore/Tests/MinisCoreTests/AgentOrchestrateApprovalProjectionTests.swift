import Foundation
import Testing
@testable import MinisCore

// NOTE: P3-AGENT-01（DEV-219R）— orchestrate 审批投影与 child 真实创建。
// 运行：cd src/MinisCore && swift test --filter AgentOrchestrateApprovalProjectionTests
//
// 缺口（head e7ab1966 实测）：`orchestrate` 随 MinisCore 出货
// （OrchestrationToolExecutor.toolName / makeDefinition），但
// ApprovalGate.defaultPolicies 未投影它，任何 default-shaped 门
// （SecureAgentLoopFactory.swift:31/:100、AgentOrchestrator 默认
// ApprovalGate()）都会在 isKnownTool 处先于 delegate 失败闭合
// （"Unknown capability 'orchestrate' is blocked"），肯定审批无法送达，
// executor 不执行，child=0。本套件钉住修复后的最小语义：
// known + .alwaysAsk + .medium，肯定审批可达 delegate，否定/缺席仍 fail-closed，
// 且审批通过后 child 被真实创建。

// MARK: - File-local fixtures（唯一命名 D219R*，避免与其它套件全局 fixture 重名）

/// 记录每一次 ApprovalRequest 的委托；按序号回放预置决策，耗尽后一律拒绝。
final class D219RRecordingDelegate: ApprovalDelegate, @unchecked Sendable {
    private let decisions: [ApprovalDecision]
    private let lock = NSLock()
    private var _requests: [ApprovalRequest] = []

    init(decisions: [ApprovalDecision]) {
        self.decisions = decisions
    }

    var requests: [ApprovalRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        let index = lock.withLock { () -> Int in
            _requests.append(request)
            return _requests.count - 1
        }
        return index < decisions.count ? decisions[index] : .deny
    }
}

/// 记录收到的 child 任务的 mock 外部 runner（真实 child 创建的可观测面）。
final class D219RRunner: ExternalAgentRunner, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var _receivedTasks: [SubAgentTask] = []

    init(name: String) {
        self.name = name
    }

    var isAvailable: Bool { true }

    var receivedTasks: [SubAgentTask] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedTasks
    }

    func run(task: SubAgentTask) async throws -> String {
        lock.withLock { _receivedTasks.append(task) }
        return "OUT-" + task.id
    }
}

// MARK: - Tests

/// P3-AGENT-01 审批投影：default-shaped gate 必须知道 orchestrate 且永不自主执行。
struct AgentOrchestrateApprovalProjectionTests {

    private static let tool = OrchestrationToolExecutor.toolName

    private static func explicitTask(_ id: String) -> [String: Any] {
        [
            "id": id,
            "title": "标题-" + id,
            "instructions": "指令-" + id,
            "agent": "external:d219r-runner",
            "model_binding": [
                "kind": "explicit",
                "provider_id": "parent-provider",
                "model_id": "parent-model",
                "configuration_fingerprint": "parent-fingerprint",
            ],
        ]
    }

    private static var v1Input: [String: Any] {
        [
            "input_version": 1,
            "tasks": [explicitTask("t1"), explicitTask("t2")],
        ]
    }

    // MARK: 默认策略投影

    @Test func defaultGateProjectsOrchestrateAsKnownAlwaysAsk() {
        let gate = ApprovalGate()
        #expect(ApprovalGate.defaultPolicies[Self.tool] == .alwaysAsk)
        #expect(gate.isKnownTool(Self.tool))
        #expect(gate.policy(for: Self.tool) == .alwaysAsk)
        #expect(gate.riskLevel(for: Self.tool) == .medium)
        // 邻近未注册能力仍必须在 isKnownTool 处失败闭合：加性投影不得外溢。
        #expect(!gate.isKnownTool("orchestrate_extra"))
        #expect(!gate.isKnownTool(Self.tool + "_x"))
    }

    @Test func globalPolicyExpansionsIncludeOrchestrate() {
        // policyOverrides(for:) 以 defaultPolicies.keys 为展开域；orchestrate
        // 必须随四种用户策略一起被投影（medium 风险在 riskOnlyAsk 下非 high）。
        #expect(ApprovalGate.policyOverrides(for: .alwaysAsk)[Self.tool] == .alwaysAsk)
        #expect(ApprovalGate.policyOverrides(for: .autoApprove)[Self.tool] == .autoApprove)
        #expect(ApprovalGate.policyOverrides(for: .riskOnlyAsk)[Self.tool] == .autoApprove)
        #expect(ApprovalGate.policyOverrides(for: .deny)[Self.tool] == .deny)
        #expect(ApprovalGate.policyOverrides(for: .never)[Self.tool] == .deny)
    }

    // MARK: 肯定审批可达 delegate（原缺口：审批在 prompt 前即被吞成拒绝）

    @Test func affirmativeApprovalReachesDelegateInsteadOfUnknownCapability() async throws {
        let delegate = D219RRecordingDelegate(decisions: [.approve])
        let gate = ApprovalGate(delegate: delegate)
        let decision = try await gate.gate(tool: Self.tool, input: Self.v1Input)
        #expect(decision.approved)
        #expect(delegate.requests.count == 1)
        #expect(delegate.requests.first?.toolName == Self.tool)
        // 0845：含 external: 子任务的编排按高风险处理，需要二次确认，不提供持久放行。
        #expect(delegate.requests.first?.riskLevel == .high)
        #expect(delegate.requests.first?.requiresSecondConfirmation == true)
        #expect(delegate.requests.first?.persistentAllowOffer == nil)
    }

    @Test(arguments: [true, false])
    func approvalShowsCompleteRequestedScopeWithoutTaskProse(encodedTasks: Bool) async throws {
        let root = "/synthetic/owned/" + String(repeating: "long-scope-component/", count: 8) + "exact-final-root"
        let tasks: [[String: Any]] = [[
            "id": "scope-case", "title": "PRIVATE_TITLE", "instructions": "PRIVATE_INSTRUCTIONS",
            "context": "PRIVATE_CONTEXT_SECRET",
            "metadata": ["secret": "PRIVATE_NESTED_SECRET"],
            "allowed_tool_names": ["file_write", "file_read"],
            "allowed_read_roots": [root + "/read"],
            "allowed_write_roots": [root, root + "/second"],
            "working_directory": root,
            "password": "PRIVATE_PASSWORD",
        ], [
            "id": "inherited", "title": "inherited", "instructions": "inherited",
        ], [
            "id": "empty", "title": "empty", "instructions": "empty",
            "allowed_tool_names": [String](), "allowed_read_roots": [String](),
            "allowed_write_roots": [String](),
        ], [
            "id": "empty-read-inherited-tools", "title": "empty read", "instructions": "empty read",
            "allowed_read_roots": [String](),
        ]]
        // Non-scope fields, including nested secrets, never enter this display.
        let payload: Any = encodedTasks
            ? String(decoding: try JSONSerialization.data(withJSONObject: tasks), as: UTF8.self)
            : tasks
        let input: [String: Any] = ["input_version": 2, "tasks": payload]
        let delegate = D219RRecordingDelegate(decisions: [.deny])
        let gate = ApprovalGate(delegate: delegate)
        await #expect(throws: ApprovalError.denied(reason: "Denied by user")) {
            _ = try await gate.gate(tool: Self.tool, input: input)
        }
        let summary = try #require(delegate.requests.first?.inputSummary)
        let summaryPrefix = "输入摘要（已脱敏）：\n" + ApprovalGate.makeInputSummary(input) + "\n\n"
        try #require(summary.hasPrefix(summaryPrefix))
        // Pretty-printed empty arrays contain blank lines inside the JSON.
        // Remove the known summary prefix rather than splitting that JSON.
        let scopeSection = summary.dropFirst(summaryPrefix.count)
        let jsonStart = try #require(scopeSection.firstIndex(of: "\n"))
        let rows = try #require(JSONSerialization.jsonObject(
            with: Data(scopeSection[scopeSection.index(after: jsonStart)...].utf8)) as? [[String: Any]])
        let row = try #require(rows.first)
        #expect(row["allowed_write_roots"] as? [String] == [root, root + "/second"])
        #expect(row["allowed_read_roots"] as? [String] == [root + "/read"])
        #expect(row["allowed_tool_names"] as? [String] == ["file_write", "file_read"])
        #expect(row["working_directory"] as? String == root)
        #expect(!scopeSection.contains("PRIVATE_"))
        #expect(row["task_index"] as? Int == 1)
        #expect(row["task_id_summary"] as? String == "id: scope-case")
        #expect(rows[1]["allowed_tool_names"] as? String == "未指定，继承父已授权工具")
        #expect(rows[1]["allowed_write_roots"] as? String == "未指定，继承父工作目录作为写根，仍受父授权范围限制")
        #expect(rows[2]["allowed_tool_names"] as? [String] == [])
        #expect(rows[2]["allowed_write_roots"] as? [String] == [])
        #expect(rows[2]["allowed_write_roots_rule"] as? String == "显式 []：无写根，不继承")
        #expect(rows[2]["allowed_read_roots_rule"] as? String == "读根使用所列数组；未指定解码为空数组，不继承读根")
        #expect(rows[3]["allowed_read_roots"] as? [String] == [])
        #expect(rows[3]["allowed_read_roots_rule"] as? String == "读根为空且工具范围未指定时，继承父工作目录；显式 [] 也适用")
        #expect(delegate.requests.first?.riskLevel == .medium)
    }

    @Test func approvalScopeRedactsEmbeddedCredentialsAndMarksUnparseableInput() async throws {
        let delegate = D219RRecordingDelegate(decisions: [.deny, .deny])
        let gate = ApprovalGate(delegate: delegate)
        let tasks: [[String: Any]] = [[
            "id": "redaction", "title": "title", "instructions": "PRIVATE_INSTRUCTIONS",
            "allowed_tool_names": ["file_write"],
            "allowed_write_roots": ["/synthetic/owned?password=scope-credential-value"],
        ]]
        let inputs: [[String: Any]] = [
            ["input_version": 2, "tasks": tasks],
            ["input_version": 2, "tasks": "PRIVATE_INVALID_JSON"],
        ]
        for input in inputs {
            await #expect(throws: ApprovalError.denied(reason: "Denied by user")) {
                _ = try await gate.gate(tool: Self.tool, input: input)
            }
        }
        let summary = try #require(delegate.requests.first?.inputSummary)
        #expect(!summary.contains("scope-credential-value"))
        let scopeSection = try #require(summary.components(separatedBy: "\n\n").last)
        #expect(!scopeSection.contains("PRIVATE_INSTRUCTIONS"))
        #expect(scopeSection.contains("范围值含敏感内容，已脱敏；显示值不是完整原值"))
        #expect(delegate.requests.last?.inputSummary.contains("范围未能提取") == true)
        #expect(delegate.requests.last?.inputSummary.components(separatedBy: "\n\n").last?.contains("PRIVATE_INVALID_JSON") == false)
    }

    @Test func explicitDelegateDenialStillThrowsDenied() async {
        let delegate = D219RRecordingDelegate(decisions: [.deny])
        let gate = ApprovalGate(delegate: delegate)
        await #expect(throws: ApprovalError.denied(reason: "Denied by user")) {
            _ = try await gate.gate(tool: Self.tool, input: Self.v1Input)
        }
        // 用户被真实询问过一次；否定来自用户，而不是 Unknown capability。
        #expect(delegate.requests.count == 1)
    }

    @Test func missingDelegateFailsClosedWithoutAnyPrompt() async {
        let gate = ApprovalGate()
        await #expect(throws: ApprovalError.denied(
            reason: "No approval delegate configured for tool 'orchestrate'"
        )) {
            _ = try await gate.gate(tool: Self.tool, input: Self.v1Input)
        }
        // 无 delegate 的 default-shaped gate 绝不静默放行 orchestrate。
    }

    // MARK: 审批通过 → child 真实创建

    @Test func approvedOrchestrateCallCreatesRealChildrenThroughExecutor() async throws {
        let runner = D219RRunner(name: "d219r-runner")
        let parent = ParentContextSnapshotV1(
            providerID: "parent-provider",
            modelID: "parent-model",
            configurationFingerprint: "parent-fingerprint",
            conversationID: "parent-conversation"
        )
        let orchestrator = AgentOrchestrator(
            externalRunners: ["d219r-runner": runner],
            taskStore: AgentTaskStore(),
            parentID: "parent",
            parentBinding: parent
        )
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        let delegate = D219RRecordingDelegate(decisions: [.approve])
        let gate = ApprovalGate(delegate: delegate)
        _ = try await gate.gate(tool: Self.tool, input: Self.v1Input)

        let output = try await executor.execute(name: Self.tool, input: Self.v1Input)
        let response = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(response["version"] as? Int == 1)
        let rows = try #require(response["results"] as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows.compactMap { $0["task_id"] as? String } == ["t1", "t2"])
        #expect(rows.compactMap { $0["status"] as? String } == ["succeeded", "succeeded"])
        #expect(rows.compactMap { $0["summary"] as? String } == ["OUT-t1", "OUT-t2"])
        for row in rows {
            let duration = try #require(row["duration_seconds"] as? Double)
            #expect(duration.isFinite && duration >= 0)
            let reference = try #require(row["output_ref"] as? [String: String])
            let taskID = try #require(row["task_id"] as? String)
            let receipt = try #require(orchestrator.taskStore?.allReceipts().first(where: {
                $0.childResultEnvelope?.taskID == taskID
            }))
            let envelope = try #require(receipt.childResultEnvelope)
            #expect(reference == ["task_id": taskID, "parent_id": "parent",
                "run_id": receipt.runID, "attempt_id": envelope.attemptID])
        }
        #expect(runner.receivedTasks.count == 2)
        let receivedIDs = Set(runner.receivedTasks.map(\.id))
        #expect(receivedIDs == ["t1", "t2"])
    }

    @Test func deniedOrchestrateCallCreatesNoChildren() async {
        let runner = D219RRunner(name: "d219r-runner")
        let parent = ParentContextSnapshotV1(
            providerID: "parent-provider",
            modelID: "parent-model",
            configurationFingerprint: "parent-fingerprint",
            conversationID: "parent-conversation"
        )
        let orchestrator = AgentOrchestrator(
            externalRunners: ["d219r-runner": runner],
            taskStore: AgentTaskStore(),
            parentID: "parent",
            parentBinding: parent
        )
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        let gate = ApprovalGate(delegate: D219RRecordingDelegate(decisions: [.deny]))
        do {
            _ = try await gate.gate(tool: Self.tool, input: Self.v1Input)
            Issue.record("denied approval must throw ApprovalError.denied")
        } catch {
            #expect(error is ApprovalError)
        }
        // 审批被否定后没有 child 被创建（executor 未被调用即缺口不存在的证明）。
        #expect(runner.receivedTasks.isEmpty)
        _ = executor
    }
}
