import AppKit
import MinisCore
import UniformTypeIdentifiers

/// Explicit local exports share the transcript's content/credential/path policy.
@MainActor
enum SessionMarkdownExport {
    private static let maxPastedMaterialCharacters = 20_000

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 每条消息的小标题：角色、时间，助手回复再加模型。
    static func sectionHeader(for message: ChatMessageUI) -> String {
        let role: String
        switch message.role {
        case .user: role = "用户"
        case .assistant: role = "助手"
        case .system: role = "系统"
        case .tool: role = "工具"
        }
        var header = "## \(role) · " + timeFormatter.string(from: message.timestamp)
        if message.role == .assistant, let model = message.turnModelID, !model.isEmpty {
            header += " · " + model
        }
        return header
    }

    static func markdown(title: String, messages: [ChatMessageUI], redactor: ChatTranscriptRedactor,
                         includeToolSummary: Bool = false, events: [MinisCore.ConversationEvent] = []) -> String {
        let heading = redactor.redactVisibleConversationBody(title)
        // 与界面显示一致：用显示内容（带附件的用户消息不导出附件全文），并去掉欢迎语。
        let sections = messages.filter { !($0.role == .assistant && ChatStore.isWelcomeText($0.content)) }.map { message in
            var section = sectionHeader(for: message) + "\n\n"
                + redactor.redactVisibleConversationBody(message.displayContent)
            // 附件只列文件名；粘贴材料导出原文（脱敏、封顶），避免导出里只剩一句指令。
            if message.role == .user, !message.attachments.isEmpty {
                let names = message.attachments.map { ($0.fileName as NSString).lastPathComponent }
                section += "\n\n附件：" + redactor.redactVisibleConversationBody(names.joined(separator: "、"))
            }
            if message.role == .user, let card = message.referenceCard {
                let material = redactor.redactVisibleConversationBody(card.material)
                let clipped = material.count > maxPastedMaterialCharacters
                    ? String(material.prefix(maxPastedMaterialCharacters)) + "\n……（已截断，原文共 \(material.count) 字）"
                    : material
                section += "\n\n粘贴材料：\n\n```text\n" + clipped + "\n```"
            }
            return section
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
        let replies = messages.filter { $0.role == .assistant && !$0.isStreaming && !ChatStore.isWelcomeText($0.content) }
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
        return chooseDestination(panel: panel, title: title, redactor: redactor) {
            markdown(title: title, messages: messages, redactor: redactor,
                     includeToolSummary: option.state == .on, events: events)
        }
    }

    /// 默认文件名：脱敏后的会话标题 + 日期，去掉路径分隔符等不能用的字符。
    static func suggestedFileName(title: String, redactor: ChatTranscriptRedactor, now: Date = Date()) -> String {
        let cleaned = redactor.redactVisibleConversationBody(title)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "会话" : String(cleaned.prefix(40))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return "\(base)-\(formatter.string(from: now)).md"
    }

    private static func chooseDestination(panel: NSSavePanel, title: String, redactor: ChatTranscriptRedactor? = nil,
                                          content: () -> String) -> String {
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFileName(
            title: title, redactor: redactor ?? ChatTranscriptRedactor(secretValues: []))
        guard panel.runModal() == .OK, let destination = panel.url else { return "已取消导出。" }
        do {
            try write(markdown: content(), to: destination)
            return "会话已导出为 Markdown。"
        } catch {
            return "会话导出失败，请重新选择保存位置。"
        }
    }
}
