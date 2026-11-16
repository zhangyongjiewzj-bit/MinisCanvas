import SwiftUI
import MinisCore

/// Both the Composer strip and Task Center use SessionTodoProgress.latest;
/// disclosure state belongs to this session's presentation only.
struct SessionTodoProgressView: View {
    let chat: ChatStore

    var body: some View {
        if let progress = SessionTodoProgress.latest(in: chat.messages.map { $0.asLLMMessage() }),
           !progress.todos.isEmpty {
            SessionTodoChecklist(progress: progress)
        }
    }
}

private struct SessionTodoChecklist: View {
    let progress: SessionTodoProgress
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        InlineInteractionCard(title: ProductRedactionPolicy.redact(progress.summary),
                              sourceLabel: "会话待办", icon: .check) {
            InspectorSection(identifier: "composer.todo.checklist", title: "步骤",
                             icon: "", catalogIcon: .check, initiallyExpanded: false) {
                ForEach(Array(progress.todos.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        if item.status == .completed {
                            MinisIconView(.check, size: 12)
                                .foregroundPalette(theme?.statusSuccess ?? .green)
                                .accessibilityHidden(true)
                        }
                        Text(statusLabel(item.status))
                            .foregroundStyle(item.status == .in_progress
                                ? (theme?.statusRunning ?? .accentColor) : .secondary)
                        Text(ProductRedactionPolicy.redact(item.content))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .font(typography?.caption ?? .caption)
                }
            }
        }
        .accessibilityIdentifier("composer.todo.progress")
    }

    private func statusLabel(_ status: SessionTodoProgress.Status) -> String {
        switch status {
        case .pending: return "待办"
        case .in_progress: return "进行中"
        case .completed: return "完成"
        }
    }
}
