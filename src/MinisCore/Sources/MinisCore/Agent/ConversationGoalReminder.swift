import Foundation

/// The next local reminder for an unresolved user's goal blocker.
public struct ConversationGoalReminder: Codable, Hashable, Sendable {
    private enum Stage: String, Codable, Sendable {
        case immediate, first, second, later

        var delay: TimeInterval {
            switch self {
            case .immediate: 0
            case .first: 30 * 60
            case .second: 60 * 60
            case .later: 2 * 60 * 60
            }
        }

        var next: Self {
            switch self {
            case .immediate: .first
            case .first: .second
            case .second, .later: .later
            }
        }
    }

    private let stage: Stage
    public let dueAt: Date
    private let awaitingAcknowledgment: Bool?
    var isAwaitingAcknowledgment: Bool {
        awaitingAcknowledgment ?? (stage == .immediate || stage == .second || stage == .later)
    }

    init(startingAt date: Date, immediate: Bool = false) {
        self.init(stage: immediate ? .immediate : .first, startingAt: date,
                  awaitingAcknowledgment: immediate)
    }

    private init(stage: Stage, startingAt date: Date, awaitingAcknowledgment: Bool) {
        self.stage = stage
        self.awaitingAcknowledgment = awaitingAcknowledgment
        dueAt = date.addingTimeInterval(stage.delay)
    }

    func consuming(at date: Date) -> Self? {
        guard dueAt <= date else { return nil }
        return Self(stage: stage.next, startingAt: date, awaitingAcknowledgment: true)
    }
}
