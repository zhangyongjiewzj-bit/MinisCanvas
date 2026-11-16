import Foundation

/// Non-secret producer facts, never a turn handle, permission or launch grant.
/// A decoded intent cannot recreate a continuation or authorize dispatch.
public struct ChildLaunchRequestIntent: Codable, Equatable, Sendable {
    public let intentID: String
    public let taskID: String
    public let parent: ParentRuntimeIdentity
    public let executionID: String?
    public let parentContextSnapshotID: String?
    public let runID: String?
    public let attemptID: String?
    public let recoveredFromIntentID: String?

    public init(intentID: String, taskID: String, parent: ParentRuntimeIdentity,
                executionID: String? = nil, parentContextSnapshotID: String? = nil,
                runID: String? = nil, attemptID: String? = nil,
                recoveredFromIntentID: String? = nil) {
        self.intentID = intentID
        self.taskID = taskID
        self.parent = parent
        self.executionID = executionID
        self.parentContextSnapshotID = parentContextSnapshotID
        self.runID = runID
        self.attemptID = attemptID
        self.recoveredFromIntentID = recoveredFromIntentID
    }

    public var isWellFormed: Bool {
        parent.isValid && !intentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [executionID, parentContextSnapshotID, runID, attemptID, recoveredFromIntentID]
                .allSatisfy { $0 == nil || !$0!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && ((runID == nil) == (attemptID == nil))
            && (runID == nil || executionID != nil)
            && recoveredFromIntentID != intentID
    }
}

public enum ChildLaunchIntentStatus: String, Codable, Equatable, Sendable {
    case queued
    /// A real new request was admitted. On restart its effect is unknown;
    /// never consume this record as another queued launch.
    case admitted
    case notAdmitted
}

public struct ChildLaunchIntentRecord: Codable, Equatable, Sendable {
    public let intent: ChildLaunchRequestIntent
    /// Only the task's original bounded request, not a copied parent transcript.
    public let task: SubAgentTask
    public let parentBinding: ParentContextSnapshotV1?
    public let parentGoal: GoalEnvelope?
    public let status: ChildLaunchIntentStatus
    public let createdAt: Date

    public var isWellFormed: Bool {
        intent.isWellFormed && intent.taskID == task.id
            && (status == .admitted || (intent.runID == nil && intent.attemptID == nil))
    }
}

public enum ChildLaunchIntentError: Error, Equatable, Sendable {
    case invalidIntent
    case conflictingIntent
    case previousEffectRequiresReview
}
