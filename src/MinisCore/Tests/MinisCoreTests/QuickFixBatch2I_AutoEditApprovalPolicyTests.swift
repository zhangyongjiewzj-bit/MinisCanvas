import Foundation
import Testing
@testable import MinisCore

/// 期望语义：Composer 模式为“自动编辑”时，写文件/编辑文件的审批由模式免除；
/// 设置里“每次询问”与“仅风险操作询问”两档对 file_write/file_edit 行为一致（都不弹卡），
/// 且不放宽：file_delete、shell、敏感/越界路径仍然询问。
/// 依据：SettingsView.approvalPolicyFootnote“把模式切到自动编辑可免写文件和编辑的审批”。
@Suite("Batch2I autoEdit 下三档审批策略对文件写入的语义")
struct QuickFixBatch2IAutoEditApprovalPolicyTests {
    nonisolated(unsafe) private static let writeInput: [String: Any] = ["path": "/tmp/work/a.txt", "content": "x"]
    nonisolated(unsafe) private static let editInput: [String: Any] = ["path": "/tmp/work/a.txt", "old_string": "a", "new_string": "b"]

    @Test("autoEdit 延后全局文件弹卡时，仅风险操作询问不应对 file_write 弹卡")
    func riskOnlyAskDefersFileWriteToAutoEdit() {
        let gate = ApprovalGate(policy: .riskOnlyAsk)
        #expect(gate.shouldAsk(tool: "file_write", input: Self.writeInput,
                               deferringGlobalFilePromptToComposer: true) == false)
    }

    @Test("autoEdit 延后全局文件弹卡时，仅风险操作询问不应对 file_edit 弹卡")
    func riskOnlyAskDefersFileEditToAutoEdit() {
        let gate = ApprovalGate(policy: .riskOnlyAsk)
        #expect(gate.shouldAsk(tool: "file_edit", input: Self.editInput,
                               deferringGlobalFilePromptToComposer: true) == false)
    }

    @Test("autoEdit 下每次询问与仅风险操作询问对文件写入的结果一致")
    func alwaysAskAndRiskOnlyAskAgreeUnderAutoEdit() {
        let always = ApprovalGate(policy: .alwaysAsk)
        let risk = ApprovalGate(policy: .riskOnlyAsk)
        for (tool, input) in [("file_write", Self.writeInput), ("file_edit", Self.editInput)] {
            #expect(
                always.shouldAsk(tool: tool, input: input, deferringGlobalFilePromptToComposer: true)
                == risk.shouldAsk(tool: tool, input: input, deferringGlobalFilePromptToComposer: true)
            )
        }
    }

    @Test("护栏：仅风险操作询问下 file_delete 在 autoEdit 延后时仍询问")
    func riskOnlyAskStillAsksFileDelete() {
        let gate = ApprovalGate(policy: .riskOnlyAsk)
        #expect(gate.shouldAsk(tool: "file_delete", input: ["path": "/tmp/work/a.txt"],
                               deferringGlobalFilePromptToComposer: true) == true)
    }

    @Test("护栏：未处于 autoEdit（不延后）时仅风险操作询问对 file_write 仍询问")
    func riskOnlyAskAsksFileWriteWhenNotDeferred() {
        let gate = ApprovalGate(policy: .riskOnlyAsk)
        #expect(gate.shouldAsk(tool: "file_write", input: Self.writeInput) == true)
    }

    @Test("护栏：对 file_write 单独设为每次询问后，autoEdit 延后不再放行")
    func explicitPerToolAlwaysAskNotDeferred() {
        var gate = ApprovalGate(policy: .riskOnlyAsk)
        gate.setPolicy(.alwaysAsk, for: "file_write")
        #expect(gate.shouldAsk(tool: "file_write", input: Self.writeInput,
                               deferringGlobalFilePromptToComposer: true) == true)
    }
}
