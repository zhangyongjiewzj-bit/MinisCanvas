import Foundation
import Testing
@testable import MinisCore

/// 第三波 G2：权限审批流程里用户能感到的行为。
@Suite("Third wave permission flow")
struct ThirdWavePermissionFlowTests {
    // MARK: 只有不可逆操作才二次确认

    @Test("only irreversible operations need the second confirmation")
    func onlyIrreversibleOperationsNeedSecondConfirmation() {
        #expect(ApprovalGate.isIrreversibleOperation(tool: "file_delete", input: ["path": "/tmp/a.txt"]))
        #expect(ApprovalGate.isIrreversibleOperation(tool: "shell_execute", input: ["command": "git push --force origin main"]))
        #expect(ApprovalGate.isIrreversibleOperation(tool: "shell_execute", input: ["command": "git reset --hard HEAD~1"]))
        #expect(ApprovalGate.isIrreversibleOperation(tool: "shell_execute", input: ["command": "rm -rf build"]))
        #expect(!ApprovalGate.isIrreversibleOperation(tool: "file_write", input: ["path": "/tmp/a.txt"]))
        #expect(!ApprovalGate.isIrreversibleOperation(tool: "shell_execute", input: ["command": "git push origin main"]))
        #expect(!ApprovalGate.isIrreversibleOperation(tool: "shell_execute", input: ["command": "swift build"]))
        let gate = ApprovalGate()
        #expect(!gate.makeRequest(tool: "shell_execute", input: ["command": "swift build"]).requiresSecondConfirmation)
        #expect(gate.makeRequest(tool: "file_delete", input: ["path": "/tmp/a.txt"]).requiresSecondConfirmation)
    }

    @Test("MCP server and scheduled task add/remove stay two-step")
    func mcpAndSchedulerManagementStayTwoStep() {
        let tool = BL6SettingsToolApproval.toolName
        #expect(ApprovalGate.isIrreversibleOperation(tool: tool, input: ["changes": ["mcp.servers.remove": [:] as [String: Any]]]))
        #expect(ApprovalGate.isIrreversibleOperation(tool: tool, input: ["changes": ["scheduler.tasks.add": [:] as [String: Any]]]))
        #expect(!ApprovalGate.isIrreversibleOperation(tool: tool, input: ["changes": ["session.current.title": [:] as [String: Any]]]))
    }

    // MARK: 只读辅助工具不弹卡

    @Test("background output, stop and browser reads skip the card under ask-every-time")
    func helperToolsSkipCardUnderAlwaysAsk() {
        let policies = ApprovalGate.policyOverrides(for: .alwaysAsk)
        #expect(policies["shell_output"] == .autoApprove)
        #expect(policies["shell_stop"] == .autoApprove)
        #expect(policies["browser"] == .autoApprove)
        #expect(policies["file_write"] == .alwaysAsk)
        // 浏览器的副作用动作仍然要问。
        let gate = ApprovalGate()
        #expect(gate.shouldAsk(tool: "browser", input: ["action": "click", "selector": "#buy"]))
    }

    // MARK: 英文内部原因转中文

    @Test("internal English denial reasons are shown in Chinese")
    func denialReasonsAreChinese() {
        let text = ApprovalError.denied(reason: "Tool 'shell_execute' is blocked by policy").errorDescription ?? ""
        #expect(text.contains("已被审批策略禁用"))
        #expect(!text.contains("is blocked by policy"))
        let expired = ComposerAuthorizationError.factsExpired.errorDescription ?? ""
        #expect(expired.contains("4 小时") && !expired.contains("Composer"))
    }

    // MARK: 当前会话读自己免卡

    private func controller(mode: ComposerTaskMode, sessionID: String) -> ComposerAuthorizationController {
        let snapshot = ComposerSubmissionSnapshot(
            mode: mode, approvalScope: .session, effort: .standard,
            sessionID: sessionID, turnID: 1, taskID: "t1", attemptID: "a1", messageID: "m1",
            workspaceID: "workspace-g2", createdAt: Date(),
            policyRevision: "policy-g2", grantEpoch: "epoch-g2", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [SessionReadTool.toolName], grantedCapabilities: [SessionReadTool.toolName],
            allowedWriteRoots: [], workspaceID: "workspace-g2", revision: "policy-g2",
            grantEpoch: "epoch-g2", leaseID: "lease-g2",
            expiresAt: Date().addingTimeInterval(600), autonomyCeiling: .l3)
        return ComposerAuthorizationController(snapshot: snapshot, facts: facts)
    }

    @Test("reading the current session's own messages needs no card; other sessions still ask")
    func currentSessionReadSkipsCard() async throws {
        let c = controller(mode: .manual, sessionID: "session-g2")
        let own = try ComposerToolInput(["scope": "messages", "session_id": "session-g2"])
        #expect(try await c.authorize(capability: SessionReadTool.toolName, input: own) == .execute)
        let meta = try ComposerToolInput(["scope": "metadata", "session_id": "session-g2"])
        #expect(try await c.authorize(capability: SessionReadTool.toolName, input: meta) == .execute)
        let other = try ComposerToolInput(["scope": "messages", "session_id": "session-other"])
        #expect(try await c.authorize(capability: SessionReadTool.toolName, input: other)
                == .requestApproval(requiresSecondConfirmation: false))
        let list = try ComposerToolInput(["scope": "list"])
        #expect(try await c.authorize(capability: SessionReadTool.toolName, input: list)
                == .requestApproval(requiresSecondConfirmation: false))
    }

    // MARK: MCP readOnlyHint

    @Test("readOnlyHint is parsed but does not change the tool digest")
    func readOnlyHintParsedWithoutChangingDigest() throws {
        let json = #"{"name":"lookup","description":"d","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}}"#
        let tool = try JSONDecoder().decode(MCPTool.self, from: Data(json.utf8))
        #expect(tool.readOnlyHint)
        let plain = MCPTool(name: "lookup", description: "d", inputSchema: .object(["type": .string("object")]))
        #expect(!plain.readOnlyHint)
        #expect(MCPDiscoverySnapshot.toolDigest(for: tool) == MCPDiscoverySnapshot.toolDigest(for: plain))
    }

    // MARK: 审批呈现设置落盘

    @Test("approval presentation settings default to inline and survive a round trip")
    func approvalPresentationSettingsPersist() throws {
        let legacy = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(legacy.approvalInlineEnabled)
        #expect(legacy.approvalTimeoutSeconds == 300)
        var neverWait = AgentSettings.default
        neverWait.approvalTimeoutSeconds = 0
        let reloadedNeverWait = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(neverWait))
        #expect(reloadedNeverWait.approvalTimeoutSeconds == 0)
        var changed = AgentSettings.default
        changed.approvalInlineEnabled = false
        changed.approvalTimeoutSeconds = 120
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(changed))
        #expect(!decoded.approvalInlineEnabled)
        #expect(decoded.approvalTimeoutSeconds == 120)
    }

    @Test("an old stored approval timeout of 0 migrates once to 300 and a later 0 is kept")
    func approvalTimeoutZeroMigratesOnce() throws {
        // 旧版本落盘：没有迁移标记、值为 0（旧默认“一直等”）→ 一次性改成 300。
        let old = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"approvalTimeoutSeconds":0}"#.utf8))
        #expect(old.approvalTimeoutSeconds == 300)
        // 没有标记、值是用户设过的非 0 数：保持。
        let custom = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"approvalTimeoutSeconds":120}"#.utf8))
        #expect(custom.approvalTimeoutSeconds == 120)
        // 迁移后落盘带标记；用户再设为 0（一直等）重新加载仍为 0。
        var migrated = old
        migrated.approvalTimeoutSeconds = 0
        let reloaded = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(migrated))
        #expect(reloaded.approvalTimeoutSeconds == 0)
    }
}
