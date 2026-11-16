import SwiftUI

struct PlanApprovalCard: View {
    let proposal: PlanApprovalProposal
    let autoEditDisabledReason: String?
    let manualDisabledReason: String?
    let onDecision: (PlanApprovalDecision) -> Void
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        InlineInteractionCard(title: "计划已就绪", sourceLabel: "计划模式") {
            MarkdownTextView(text: proposal.markdown,
                             baseSize: typography?.transcriptBodySize ?? 13)
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            if let reason = autoEditDisabledReason {
                Text("自动编辑不可用：\(reason)")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            }
            if let reason = manualDisabledReason, reason != autoEditDisabledReason {
                Text("逐项审批不可用：\(reason)")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("plan.approval.card")
    }

    @ViewBuilder private var actions: some View {
        Button("批准并自动编辑") { onDecision(.approveAutoEdit) }
            .buttonStyle(.borderedProminent)
            .disabled(autoEditDisabledReason != nil)
            .help(autoEditDisabledReason ?? "自动编辑文件，其它操作仍按现有审批策略确认")
            .accessibilityIdentifier("plan.approval.autoEdit")
        Button("批准并逐项审批") { onDecision(.approveManual) }
            .buttonStyle(.bordered)
            .disabled(manualDisabledReason != nil)
            .help(manualDisabledReason ?? "新开执行回合，工具操作按现有审批策略确认")
            .accessibilityIdentifier("plan.approval.manual")
        Button("继续规划") { onDecision(.continuePlanning) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("plan.approval.continue")
    }
}
