import Foundation
import MinisCore

/// Only frozen message values cross this worker boundary. Provider access and
/// turn authority stay with the engine's caller.
struct ChatHistoryPreprocessor: Sendable {
    let projection: @Sendable ([ChatMessageUI]) throws -> [LLMMessage]

    init(projection: @escaping @Sendable ([ChatMessageUI]) throws -> [LLMMessage] = Self.projectProviderHistory) {
        self.projection = projection
    }

    static func isStatusOnlyInterrupted(_ message: ChatMessageUI) -> Bool {
        message.role == .assistant && message.wasInterrupted && !message.isStreaming
            && message.content.isEmpty && message.attachments.isEmpty
            && message.toolCalls.isEmpty && message.toolCallID == nil
            && message.legacyToolOutputSummary == nil && message.inlineToolAnchors.isEmpty
            && message.referenceCard == nil && message.sessionReferenceCard == nil
            && message.composedContentOwnership == nil
    }

    /// Canonical/source checks require every original row and its position.
    static func project(_ history: [ChatMessageUI]) throws -> [LLMMessage] {
        try history.map { message in
            try Task.checkCancellation()
            return message.asLLMMessage()
        }
    }

    /// Only the provider candidate copy omits display-only interrupted rows
    /// and the app-written error line. Canonical compaction readers continue
    /// using the complete projection.
    static func projectProviderHistory(_ history: [ChatMessageUI]) throws -> [LLMMessage] {
        try history.compactMap { message in
            try Task.checkCancellation()
            guard !isStatusOnlyInterrupted(message),
                  let sendable = removingDisplayedErrorLine(message) else { return nil }
            return sendable.asLLMMessage()
        }
    }

    /// 失败时 ChatStore 把"**错误**…"追加到助手消息正文末尾，仅供用户查看；
    /// 发给模型的历史里去掉这一段（界面和导出仍保留）。去掉后若消息已空，整条不发。
    /// 只认"独立成段、且在正文末尾"的错误段，避免误删模型自己写的内容。
    static func removingDisplayedErrorLine(_ message: ChatMessageUI) -> ChatMessageUI? {
        guard message.role == .assistant, !message.isStreaming,
              let marker = message.content.range(of: "**错误**", options: .backwards) else { return message }
        let before = message.content[..<marker.lowerBound]
        let tail = message.content[marker.lowerBound...]
        guard before.isEmpty || before.hasSuffix("\n\n"), !tail.contains("\n\n") else { return message }
        let kept = before.trimmingCharacters(in: .whitespacesAndNewlines)
        if kept.isEmpty {
            let hasOtherPayload = !message.toolCalls.isEmpty || !message.attachments.isEmpty
            return hasOtherPayload ? withContent(message, "") : nil
        }
        return withContent(message, kept)
    }

    private static func withContent(_ message: ChatMessageUI, _ content: String) -> ChatMessageUI {
        var copy = message
        copy.content = content
        return copy
    }

    nonisolated(nonsending) func prepare(_ history: [ChatMessageUI]) async throws -> [LLMMessage] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let messages = try projection(history)
            try Task.checkCancellation()
            return messages
        }
        let messages = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return messages
    }
}
