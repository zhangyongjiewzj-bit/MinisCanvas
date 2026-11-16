import SwiftUI
import MinisCore

/// The single dispatch point above every GlobalComposer (main and companion).
/// Later N03/N13 consumers attach here instead of creating a second card host.
@MainActor
struct InlineInteractionHost: View {
    @Bindable var chat: ChatStore
    @State private var ceilingRequestOwner = UUID()
    var body: some View {
        Group {
            SessionTodoProgressView(chat: chat).id(chat.activeSessionID)
            if let proposal = chat.activePlanApproval {
                PlanApprovalCard(proposal: proposal,
                    autoEditDisabledReason: chat.planApprovalDisabledReason(for: .autoEdit, allowsCeilingConfirmation: true),
                    manualDisabledReason: chat.planApprovalDisabledReason(for: .manual)) { decision in
                    Task { @MainActor in await chat.requestPlanApproval(decision, proposalID: proposal.id, owner: ceilingRequestOwner) }
                }
            }
            if let proposal = chat.activePlanApproval,
               let request = chat.composerCeilingRequest, request.owner == ceilingRequestOwner,
               request.sessionID == proposal.sessionID, request.proposalID == proposal.id {
                Text(request.confirmationText).font(.caption)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("提高最高模式并执行计划") {
                        Task { @MainActor in await chat.confirmPlanApprovalCeiling(proposalID: proposal.id, owner: ceilingRequestOwner) }
                    }
                    Button("取消") { chat.cancelComposerCeilingRequest(owner: ceilingRequestOwner) }
                }
            }
            if let value = chat.mcpElicitations.pending(for: chat.activeSessionID) {
                MCPElicitationCard(center: chat.mcpElicitations, value: value).id(value.id)
            }
            if let value = chat.userQuestions.pending(for: chat.activeSessionID) {
                UserQuestionCard(center: chat.userQuestions, value: value)
                    .id(value.id)
            }
        }
    }
}

@MainActor
private struct UserQuestionCard: View {
    @Bindable var center: SessionQuestionCenter
    let value: SessionQuestionCenter.Pending
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        InlineInteractionCard(title: "澄清问题", sourceLabel: "由模型提出 · 内容不可信", icon: .help) {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择仅作为回答返回模型，不会执行选项中的链接、命令或审批建议。")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(value.request.questions, id: \.question) { question in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: question.header).font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                                Text(verbatim: question.question)
                                if question.multiSelect { Text("可多选").font(typography?.caption ?? .caption) }
                                ForEach(question.options, id: \.label) { option in
                                    Button {
                                        center.select(sessionID: value.sessionID, id: value.id,
                                            question: question.question, label: option.label)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: option.label)
                                            Text(verbatim: option.description)
                                                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(!value.usesOther.contains(question.question)
                                        && (value.selections[question.question] ?? []).contains(option.label) ? .accentColor : .secondary)
                                }
                                Button("其他…") {
                                    center.setOther(sessionID: value.sessionID, id: value.id, question: question.question,
                                        text: value.otherText[question.question] ?? "")
                                }.buttonStyle(.bordered)
                                if value.usesOther.contains(question.question) {
                                    TextField("输入你自己的回答", text: Binding(
                                        get: { value.otherText[question.question] ?? "" },
                                        set: { center.setOther(sessionID: value.sessionID, id: value.id,
                                            question: question.question, text: $0) }))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
                Text("默认一直等待回答；切换会话或窗口失焦不会自动继续。其他回答最多1000字。")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                if let feedback = value.feedback {
                    Text(verbatim: feedback).font(typography?.caption ?? .caption).modifier(ReadableStatusForeground(status: .danger))
                }
                HStack {
                    Button("取消澄清") { center.resolve(sessionID: value.sessionID, id: value.id, status: .cancelled) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("提交回答") { center.resolve(sessionID: value.sessionID, id: value.id, status: .answered) }
                        .buttonStyle(.borderedProminent).disabled(!value.isComplete)
                }
            }
        }
        .accessibilityIdentifier("composer.ask-user")
        .onExitCommand { center.resolve(sessionID: value.sessionID, id: value.id, status: .cancelled) }
    }
}
