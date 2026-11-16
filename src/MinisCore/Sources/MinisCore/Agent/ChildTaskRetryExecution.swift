import Foundation

/// A process-local retry capability issued by an actual child producer. The
/// original work and owner stay in its private operation; decoded ledger facts
/// cannot construct this capability or restore its authority after restart.
public final class ChildTaskRetryExecution: Sendable {
    public let taskID: String
    public let parentID: String
    public let originalRunID: String
    private let storeIdentity: ObjectIdentifier
    private let agentType: SubAgentAgentType
    private let liveOwner: @Sendable () -> Bool
    private let operation: @Sendable (String, String) async -> SubAgentReport
    private let claims = RetryRunClaims()

    init(store: AgentTaskStore, taskID: String, parentID: String, originalRunID: String,
         agentType: SubAgentAgentType, liveOwner: @escaping @Sendable () -> Bool,
         operation: @escaping @Sendable (String, String) async -> SubAgentReport) {
        self.storeIdentity = ObjectIdentifier(store)
        self.taskID = taskID
        self.parentID = parentID
        self.originalRunID = originalRunID
        self.agentType = agentType
        self.liveOwner = liveOwner
        self.operation = operation
    }

    /// Consults the original turn lifecycle and policy deadline, never current
    /// selection labels. The runner revalidates again at actual dispatch.
    public func belongs(to store: AgentTaskStore) -> Bool { storeIdentity == ObjectIdentifier(store) }

    public var hasLiveOwner: Bool { liveOwner() }

    public func resume(resultingRunID: String, durableIdempotencyKey: String) async -> SubAgentReport {
        guard await claims.claim(resultingRunID) else {
            return SubAgentReport(taskID: taskID, agentType: agentType, duration: 0,
                                  result: .failed(error: "RETRY_ALREADY_DISPATCHED"))
        }
        return await operation(resultingRunID, durableIdempotencyKey)
    }
}

private actor RetryRunClaims {
    private var claimed: Set<String> = []
    func claim(_ runID: String) -> Bool { claimed.insert(runID).inserted }
}
