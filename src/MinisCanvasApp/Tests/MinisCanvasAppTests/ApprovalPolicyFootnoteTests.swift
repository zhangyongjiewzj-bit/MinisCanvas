import Foundation
import Testing

@testable import MinisCanvasApp

/// 缺陷：设置→Agent→“工具审批策略”Picker 下没有说明，用户看不出写类工具是否弹卡
/// 还取决于输入框“模式”、自主权上限，且高风险操作仍二次确认。
/// RED 为编译失败型：引用尚不存在的 `SettingsView.approvalPolicyFootnote` /
/// `approvalPolicyFootnoteIdentifier`（沿用 N16 的 `PersistentApprovalRulesSettingsView.title(...)` 静态可测模式）。
@Suite("设置页工具审批策略说明文案")
struct ApprovalPolicyFootnoteTests {
    @Test("高级工具审批说明与安全页停用说明各自对应真实设置")
    func footnoteStatesKeyFacts() {
        let text = SettingsView.approvalPolicyFootnote
        #expect(text.contains("模式"))
        #expect(text.contains("每次询问"))
        #expect(text.contains("只问高风险"))
        #expect(SettingsView.toolsDisabledHelp.contains("拒绝所有工具调用"))
        #expect(text.count <= 220)
    }

    @Test("说明文案有稳定的 accessibilityIdentifier")
    func footnoteIdentifierIsStable() {
        #expect(SettingsView.approvalPolicyFootnoteIdentifier == "settings.agent.approval-policy.footnote")
    }
}
