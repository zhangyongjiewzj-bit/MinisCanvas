import Foundation
import Testing
@testable import MinisCore

/// R13: user decision 2026-11-10 — external_session_read is auto-approved even
/// under the global "ask every time" policy; send and every other tool keep asking.
@Suite("R13 external_session_read auto-approve")
struct ExternalSessionReadAutoApproveR13Tests {
    private let read = ExternalSessionToolNames.read
    private let send = ExternalSessionToolNames.send

    @Test("alwaysAsk overrides auto-approve external read")
    func alwaysAskOverrideAutoApprovesRead() {
        #expect(ApprovalGate.policyOverrides(for: .alwaysAsk)[read] == .autoApprove)
    }

    @Test("gate built from alwaysAsk does not ask for a plain external read")
    func gateDoesNotAskForRead() {
        let gate = ApprovalGate(policy: .alwaysAsk)
        #expect(gate.policy(for: read) == .autoApprove)
        #expect(gate.shouldAsk(tool: read, input: ["source": "codex"]) == false)
    }

    @Test("alwaysAsk keeps send and unrelated tools asking")
    func alwaysAskStillAsksOthers() {
        let overrides = ApprovalGate.policyOverrides(for: .alwaysAsk)
        #expect(overrides[send] == .alwaysAsk)
        #expect(overrides["web_fetch"] == .alwaysAsk)
        // 用户 2026-11-16：浏览器只读动作、后台输出查看/停止免卡；副作用动作仍按输入风险询问。
        #expect(overrides["browser"] == .autoApprove)
        // 用户 2026-11-16：授权目录内只读文件工具不弹卡。
        #expect(overrides["file_read"] == .autoApprove)
        #expect(overrides[SessionTodoProgress.toolName] == .autoApprove)
    }

    @Test("deny and never still deny external read")
    func denyPoliciesStillDenyRead() {
        #expect(ApprovalGate.policyOverrides(for: .deny)[read] == .deny)
        #expect(ApprovalGate.policyOverrides(for: .never)[read] == .deny)
    }

    @Test("autoApprove and riskOnlyAsk: read auto, send asks")
    func otherPoliciesUnchanged() {
        for policy in [ApprovalPolicy.autoApprove, .riskOnlyAsk] {
            let overrides = ApprovalGate.policyOverrides(for: policy)
            #expect(overrides[read] == .autoApprove)
            #expect(overrides[send] == .alwaysAsk)
        }
    }
}
