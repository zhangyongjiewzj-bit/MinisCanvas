import AppKit
import MinisCore
import UniformTypeIdentifiers

/// Explicit local exports share the transcript's content/credential/path policy.
@MainActor
enum SessionMarkdownExport {
    static func markdown(title: String, messages: [ChatMessageUI], redactor: ChatTranscriptRedactor,
                         includeToolSummary: Bool = false, events: [MinisCore.ConversationEvent] = []) -> String {
        let heading = redactor.redactVisibleConversationBody(title)
        let sections = messages.map { message in
            let role: String
            switch message.role {
            case .user: role = "用户"
            case .assistant: role = "助手"
            case .system: role = "系统"
            case .tool: role = "工具"
            }
            return "## \(role)\n\n" + redactor.redactVisibleConversationBody(message.content)
        }
        let body = "# \(heading)\n\n" + sections.joined(separator: "\n\n---\n\n") + "\n"
        guard includeToolSummary else { return body }
        let rows = events.filter { $0.kind == .tool }.map { event in
            let action = ToolEventCard.safeToolActionLabel(event.toolName) ?? "工具调用"
            let elapsed = MinisCore.ConversationEventProjection.display(for: event).elapsed
            // Only fixed action labels, enum status and numeric elapsed are consumed.
            // Never export summary/target/arguments/results or approval/execution IDs.
            return "- \(action)：\(event.status.label)；耗时 \(elapsed)"
        }
        let summary = rows.isEmpty ? "暂无工具记录。" : rows.joined(separator: "\n")
        return body + "\n## 工具摘要\n\n" + redactor.redactVisibleConversationBody(summary) + "\n"
    }

    static func write(markdown: String, to destination: URL) throws {
        try markdown.write(to: destination, atomically: true, encoding: .utf8)
    }

    static func replyText(nth: Int, messages: [ChatMessageUI], redactor: ChatTranscriptRedactor) -> String? {
        guard nth > 0 else { return nil }
        let replies = messages.filter { $0.role == .assistant && !$0.isStreaming && $0.content != ChatStore.welcomeText }
        guard nth <= replies.count else { return nil }
        return redactor.redactVisibleConversationBody(replies[replies.count - nth].content)
    }

    static func chooseDestination(title: String, messages: [ChatMessageUI],
                                  redactor: ChatTranscriptRedactor,
                                  events: [MinisCore.ConversationEvent]) -> String {
        let panel = NSSavePanel()
        let option = NSButton(checkboxWithTitle: "包含工具摘要", target: nil, action: nil)
        option.state = .off
        option.setAccessibilityIdentifier("chat.session.export-markdown.include-tools")
        option.toolTip = "仅包含工具动作、状态和耗时，不包含参数、结果正文或审批身份"
        panel.accessoryView = option
        return chooseDestination(panel: panel) {
            markdown(title: title, messages: messages, redactor: redactor,
                     includeToolSummary: option.state == .on, events: events)
        }
    }

    private static func chooseDestination(panel: NSSavePanel, content: () -> String) -> String {
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "会话.md"
        guard panel.runModal() == .OK, let destination = panel.url else { return "已取消导出。" }
        do {
            try write(markdown: content(), to: destination)
            return "会话已导出为 Markdown。"
        } catch {
            return "会话导出失败，请重新选择保存位置。"
        }
    }
}
