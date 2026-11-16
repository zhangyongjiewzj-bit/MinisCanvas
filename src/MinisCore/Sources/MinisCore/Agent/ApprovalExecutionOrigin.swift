import Foundation

/// Execution provenance only; never an approval or a capability grant.
public enum ApprovalExecutionOrigin: String, Sendable {
    case interactive
    case scheduledTask
    case backgroundSubtask

    public var isUnattended: Bool { self != .interactive }
}

public enum ApprovalExecutionOriginContext {
    @TaskLocal public static var current: ApprovalExecutionOrigin = .interactive
}
