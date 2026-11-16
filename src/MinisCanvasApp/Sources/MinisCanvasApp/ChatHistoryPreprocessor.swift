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

    /// Only the provider candidate copy omits display-only interrupted rows.
    /// Canonical compaction readers continue using the complete projection.
    static func projectProviderHistory(_ history: [ChatMessageUI]) throws -> [LLMMessage] {
        try history.compactMap { message in
            try Task.checkCancellation()
            return isStatusOnlyInterrupted(message) ? nil : message.asLLMMessage()
        }
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
