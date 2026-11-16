import Foundation

/// When a `SteerInstruction` should take effect.
public enum SteerApplication: String, Sendable, Equatable {
    /// Apply to the next user turn (the immediate next `run` call).
    case currentTurn
    /// Apply to the turn after the next one.
    case nextTurn
}

/// A Codex-style "steer-turn" instruction: short guidance injected into the
/// system prompt so the model adjusts its behavior (e.g. "从现在起用中文回复").
public struct SteerInstruction: Sendable, Equatable {
    public var text: String
    public var applyTo: SteerApplication

    public init(text: String, applyTo: SteerApplication = .currentTurn) {
        self.text = text
        self.applyTo = applyTo
    }
}

// MARK: - AgentContext steer / edit extensions

public extension AgentContext {
    /// Queue a system-level instruction for a future `run`.
    ///
    /// `currentTurn` applies to the immediate next run. `nextTurn` deliberately
    /// skips one run, then remains active for later turns. Keeping the queue
    /// separate from `systemPrompt` preserves the caller's base prompt and
    /// makes the two scheduling modes observable at the provider boundary.
    mutating func addSteer(_ instruction: SteerInstruction) {
        pendingSteers.append(AgentContext.PendingSteer(
            instruction: instruction,
            skippedRuns: instruction.applyTo == .nextTurn ? 1 : 0
        ))
    }

    /// Replace the content of the last `.user` message in `messages`
    /// (Codex-style edit-last-user-turn). Image/audio attachments are kept.
    ///
    /// - Returns: `true` if a user message was found and replaced.
    @discardableResult
    mutating func editLastUserMessage(_ newText: String) -> Bool {
        guard let index = messages.lastIndex(where: { $0.role == .user }) else {
            return false
        }
        let old = messages[index]
        messages[index] = LLMMessage(
            role: .user,
            content: newText,
            images: old.images,
            audios: old.audios
        )
        return true
    }
}
