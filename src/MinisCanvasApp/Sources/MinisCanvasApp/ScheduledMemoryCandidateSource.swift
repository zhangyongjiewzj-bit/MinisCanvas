import Foundation

/// The memory candidate grant belongs to a durable scheduler task, not to a
/// command string, task name, or the Scheduler authorization for execution.
enum ScheduledMemoryCandidateSource {
    static func sourceID(taskID: UUID) -> String {
        "scheduler-task:\(taskID.uuidString.lowercased())"
    }

    /// Only the explicit canonical command is a scheduled memory producer.
    /// Ordinary scheduled prose and other slash commands cannot be reclassified
    /// as a memory request by an adapter or by a sourceRef string.
    static func proposalText(command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "/memory.propose"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let remainder = trimmed.dropFirst(prefix.count)
        guard remainder.first?.isWhitespace == true else { return nil }
        let text = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
