import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// S5（MC0-P1-09）：app 终端面板的 allow-list 分类不得被复合 shell 语法扩大。
/// 负例：分号链/管道/重定向/命令替换/后台/分组/换行一律不得按首个可执行文件
/// 自动放行；必须进入确认或拒绝，且未确认前无任何副作用。
@Suite("S5 shell 复合语法 fail-closed")
struct S5ShellCompoundSyntaxTests {

    @Test func semicolonChainNeverAutoAllowed() {
        let kind = TerminalGuard.classify("ls; touch /tmp/s5-marker").kind
        #expect(kind != .allowed, "分号链不得自动放行")
        #expect(kind == .confirmation)
    }

    @Test func pipelineNeverAutoAllowed() {
        let kind = TerminalGuard.classify("cat /etc/hostname | grep local").kind
        #expect(kind != .allowed, "管道不得自动放行")
        #expect(kind == .confirmation)
    }

    @Test func redirectNeverAutoAllowed() {
        let kind = TerminalGuard.classify("echo PWN > /tmp/s5-marker").kind
        #expect(kind != .allowed, "重定向不得自动放行")
        #expect(kind == .confirmation)
    }

    @Test func commandSubstitutionNeverAutoAllowed() {
        #expect(TerminalGuard.classify("echo $(id)").kind != .allowed)
        #expect(TerminalGuard.classify("echo `id`").kind != .allowed)
    }

    @Test func backgroundAndGroupingNeverAutoAllowed() {
        #expect(TerminalGuard.classify("sleep 5 &").kind != .allowed)
        #expect(TerminalGuard.classify("(ls)").kind != .allowed)
    }

    @Test func newlineSeparatorNeverAutoAllowed() {
        #expect(TerminalGuard.classify("ls\nrm -rf /tmp/s5-x").kind != .allowed)
        #expect(TerminalGuard.classify("ls\nrm -rf /tmp/s5-x").kind == .confirmation)
    }

    @Test func compoundContainingDeniedExecutableIsDenied() {
        #expect(TerminalGuard.classify("ls && halt rm -rf /").kind == .denied)
    }

    /// 副作用判据（store 层）：自动提交复合命令不得执行、必须进确认条。
    @MainActor
    @Test func submitDoesNotAutoRunCompoundCommand() {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("s5-marker-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }

        // TerminalStore.submit requires a bound workdir before command classification.
        let store = TerminalStore(contextSnapshot: TerminalContextSnapshot(
            sessionID: "s5-compound-session", turnID: "s5-compound-turn",
            taskID: "s5-compound-task", projectID: "s5-compound-project",
            workdir: marker.deletingLastPathComponent().path
        ))
        store.input = "ls; touch \(marker.path)"
        store.submit()

        #expect(store.pendingConfirmation != nil, "复合命令必须进入确认条")
        #expect(!store.isRunning, "未确认不得启动执行")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "未确认不得产生副作用")
    }
}

/// Agent `shell_execute` 路径回归锁（lane 032 danger-syntax 统一后的后继合同）。
///
/// 旧版本直接调用 `BuiltinToolExecutor.execute`（位于生产审批 gate 之下）并
/// pin "executor 对一切复合语法在 spawn 前 hard throw、零副作用"。该合同已被
/// D-TERMINAL-04 统一映射替代：guard-rejected 且 snapshot 不 deny 的复合语法
/// 属于确认类，executor 只有在通过结构上不可跳过的 per-call `shell_execute`
/// 审批（ApprovalGate，input risk 恒为 .high）之后才允许执行。此套件因此改为
/// pin 新映射的等价安全不变量，判据全部来自生产同一入口：
/// - `.denied`（含复合内嵌硬拒名）仍在任何 spawn 前 throw，零副作用；
/// - guard-rejected 语法在唯一 snapshot 上只会得到确认类，绝不 `.allowed`；
/// - 确认类必须落到 per-call approval：最宽松用户策略也必须逐条弹审，
///   无 delegate 的 gate 直接 deny，`.never` 策略 deny；
/// - nil gate 在 AgentLoop 中 fail-closed（AgentLoop.swift `isCataloguedLowRisk`
///   判定的三张策略表在此被钉住，shell_execute 永远不满足 autonomous 条件）；
/// - well-formed `.unknown` 与 malformed 语法仍 fail-closed。
@Suite("S5 agent shell_execute 复合语法锁")
struct S5AgentShellExecuteCompoundLockTests {

    private func tempRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("s5-agent-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func marker(in root: URL, name: String = "s5-agent-marker.txt") -> URL {
        root.appendingPathComponent(name)
    }

    // MARK: 1. denied 内嵌复合 → spawn 前 hard throw、零副作用（分号链锁的后继）

    @Test func nestedDenyInsideCompoundThrowsBeforeSpawnWithZeroSideEffects() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = BuiltinToolExecutor(allowedRoot: root)
        let theSnapshot = TerminalPolicySnapshot.default

        // 判据先于行为：同一条命令在终端与 Agent 共用的唯一 snapshot 上就是
        // .denied（内嵌 halt / 内嵌 dd 均由整行 policyWords 捕获）。
        let battery = [
            "echo PWN > \(marker(in: root).path); halt true",
            "printf seed > \(marker(in: root).path) && dd if=/dev/zero of=\(marker(in: root).path)",
        ]
        for command in battery {
            #expect(!MinisCore.TerminalGuard.inspect(command).isAllowed,
                    "fixture must stay guard-rejected: \(command)")
            #expect(theSnapshot.classify(command: command) == .denied,
                    "nested hard-deny name must classify .denied: \(command)")
            await #expect(throws: ToolExecutorError.shellRejected("command denied by terminal policy")) {
                _ = try await executor.execute(name: "shell_execute", input: ["command": command])
            }
            // 复合的第一段（重定向写 marker）也被拒绝：证明零 spawn、零副作用。
            #expect(!FileManager.default.fileExists(atPath: marker(in: root).path),
                    "denied-class compound must leave no side effect: \(command)")
        }
    }

    // MARK: 2. guard-rejected 语法绝不自动放行（管道锁的后继：分类层）

    @Test func guardRejectedSyntaxNeverClassifiesAllowed() {
        let theSnapshot = TerminalPolicySnapshot.default
        let battery = [
            "ls; touch /tmp/s5-agent-chain-marker",        // 原分号链样本
            "cat /etc/hostname | touch /tmp/s5-agent-marker", // 原管道样本
            "echo PWN > /tmp/s5-agent-marker",              // 原重定向样本
            "echo $(id)", "echo `id`", "sleep 5 &", "(ls)", "ls\nrm marker",
            "printf '%s",                                    // malformed：仍进确认类，绝不放行
        ]
        for command in battery {
            #expect(!MinisCore.TerminalGuard.inspect(command).isAllowed,
                    "fixture must stay guard-rejected: \(command)")
            let disposition = theSnapshot.classify(command: command)
            #expect(disposition != .allowed,
                    "guard-rejected syntax must never auto-allow: \(command)")
            // lane 020 不变量：非 denied 的 danger 语法统一落确认类。
            #expect(disposition == .confirmation,
                    "non-denied danger syntax is the confirmation class: \(command)")
        }
        // 内嵌硬拒名则整体 denied，绝不因语法被拒而降格成确认类。
        #expect(theSnapshot.classify(command: "ls && halt touch /tmp/s5-marker") == .denied)
    }

    // MARK: 3. 确认类必须逐条落到 per-call approval，gate 不可跳过（重定向锁的后继：审批层）

    private final class RecordingDelegate: ApprovalDelegate, @unchecked Sendable {
        private(set) var requests: [ApprovalRequest] = []
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            requests.append(request)
            return ApprovalDecision(approved: true, reason: "fixture", confirmed: true)
        }
    }

    @Test func confirmationClassAlwaysReachesPerCallApprovalAndGateCannotBeSkipped() async throws {
        let dangerCommands = [
            "ls; touch /tmp/s5-agent-chain-marker",
            "cat /etc/hostname | touch /tmp/s5-agent-marker",
            "echo PWN > /tmp/s5-agent-marker",
            "printf '%s",
        ]

        // (a) 最宽松的用户策略 `.autoApprove` 也必须为每条命令显式弹审一次。
        let delegate = RecordingDelegate()
        let autoGate = ApprovalGate(policy: .autoApprove, delegate: delegate)
        for command in dangerCommands {
            let decision = try await autoGate.gate(tool: "shell_execute", input: ["command": command])
            #expect(decision.approved, "fixture delegate approves; the gate must still have asked")
        }
        #expect(delegate.requests.count == dangerCommands.count,
                "every danger-syntax shell_execute input needs its own approval prompt")

        // (b) 无 delegate 的 gate 对同一输入 fail-closed deny（绝不静默放行）。
        let silentGate = ApprovalGate(policy: .autoApprove)
        for command in dangerCommands {
            await #expect(throws: ApprovalError.denied(
                reason: "Input requires approval for tool 'shell_execute'"
            )) {
                _ = try await silentGate.gate(tool: "shell_execute", input: ["command": command])
            }
        }

        // (c) deny 用户策略整体拒绝，不依赖输入形状。
        let denyGate = ApprovalGate(policy: .never)
        await #expect(throws: ApprovalError.denied(reason: "Tool 'shell_execute' is blocked by policy")) {
            _ = try await denyGate.gate(
                tool: "shell_execute",
                input: ["command": "echo PWN > /tmp/s5-agent-marker"]
            )
        }

        // (d) 审批底线是结构性的：任何 command 文本（含空串）的 input risk
        // 固定 .high，requiresApproval 恒真——没有文本形态能绕过确认。
        for probe in dangerCommands + ["", "ls", "qqq"] {
            #expect(ApprovalGate.inputRiskLevel(tool: "shell_execute", input: ["command": probe]) == .high,
                    "shell_execute input risk must stay .high for probe: \(probe.debugDescription)")
            let request = autoGate.makeRequest(tool: "shell_execute", input: ["command": probe])
            #expect(request.requiresApproval,
                     "shell_execute request must require approval for probe: \(probe.debugDescription)")
        }
    }

    // MARK: 4. nil gate 在 AgentLoop 中 fail-closed 的表层判据

    @Test func shellExecuteNeverQualifiesForGatelessAutonomousExecution() {
        // AgentLoop（AgentLoop.swift:803-811）在 approvalGate 缺失时仅对
        // `isCataloguedLowRisk` 的调用保持自治：
        //   defaultPolicies[tool] == .autoApprove && riskByTool[tool] == .low
        //     && inputRiskLevel(tool:input:) == .low
        // Current finite read-only policy defaults to autoApprove, but the static
        // high risk still excludes shell_execute from this conjunction. Thus nil gate uses
        // ToolExecutorError.approvalRequired —— gate 缺席不等于批准。
        #expect(ApprovalGate.defaultPolicies["shell_execute"] == .autoApprove)
        #expect(ApprovalGate.riskByTool["shell_execute"] == .high)
    }

    // MARK: 5. unknown 审批后执行，denied 仍拒绝

    @Test func approvedUnknownExecutesWhileDeniedCommandsStillThrow() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = BuiltinToolExecutor(allowedRoot: root)
        let theSnapshot = TerminalPolicySnapshot.default

        #expect(theSnapshot.classify(command: "qqqnotacommand") == .unknown)
        let unknownInput: [String: Any] = ["command": "qqqnotacommand"]
        let capture = ApprovedShellReceiptCapture()
        var gate = ApprovalGate(delegate: S5UnknownShellDelegate())
        gate.onApprovalReceipt = { capture.record($0) }
        _ = try await gate.gate(tool: "shell_execute", input: unknownInput)
        let capturedReceipt: ApprovalReceipt = try #require(capture.load())
        let unknownResult = try await ApprovedShellCallScope.$currentLegacyReceipt.withValue(capturedReceipt) {
            try await executor.execute(name: "shell_execute", input: unknownInput)
        }
        let unknownEnvelope = try #require(try JSONSerialization.jsonObject(with: Data(unknownResult.utf8)) as? [String: Any])
        #expect((unknownEnvelope["exit_code"] as? Int) == 127)

        #expect(theSnapshot.classify(command: "halt ls") == .denied)
        await #expect(throws: ToolExecutorError.shellRejected("command denied by terminal policy")) {
            _ = try await executor.execute(name: "shell_execute", input: ["command": "halt ls"])
        }
        // fail-closed throw 不得留下任何执行痕迹。
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                "rejected commands must not touch the working root")
    }
}

private struct S5UnknownShellDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true, requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}
