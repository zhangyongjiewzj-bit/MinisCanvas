import Foundation

/// Canonical, immutable identity carried by a task-creation request and its
/// durable receipt. The child task is always linked to the exact parent turn;
/// parent ID or an idempotency key alone is insufficient provenance.
public struct AgentTaskCreationIdentity: Sendable, Equatable, Hashable, Codable {
    public let taskID: String
    public let parentID: String
    public let sourceSessionID: String
    public let sourceConversationID: String
    public let sourceTurnID: String
    public let scopeID: String
    public let idempotencyKey: String

    public init(request: AgentTaskCreationRequest) {
        taskID = request.taskID
        parentID = request.parentID
        sourceSessionID = request.source.sessionID
        sourceConversationID = request.source.conversationID
        sourceTurnID = request.source.turnID
        scopeID = request.scopeID
        idempotencyKey = request.idempotencyKey
    }

    public init(receipt: AgentTaskCreationReceipt) {
        self.init(request: receipt.request)
    }

    public var isValid: Bool {
        [
            taskID,
            parentID,
            sourceSessionID,
            sourceConversationID,
            sourceTurnID,
            scopeID,
            idempotencyKey
        ].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Narrow consumer boundary for the session/task creation path.
///
/// The command service remains the only validator/store admission path. This
/// consumer adds the canonical identity check at the caller boundary and
/// returns the durable service receipt without switching the current session
/// or writing any projection.
public final class AgentTaskCreationConsumer: @unchecked Sendable {
    private let commandService: AgentTaskCommandService

    public init(commandService: AgentTaskCommandService) {
        self.commandService = commandService
    }

    public init(
        store: AgentTaskStore,
        knownProjectIDs: Set<String>,
        authorizedScopeIDs: Set<String>
    ) {
        commandService = AgentTaskCommandService(
            store: store,
            knownProjectIDs: knownProjectIDs,
            authorizedScopeIDs: authorizedScopeIDs
        )
    }

    /// Consumes one request exactly once. Replays return the original durable
    /// task receipt; a changed payload under the same key fails closed in the
    /// underlying service. No UI/session switch or projection mutation occurs.
    public func consume(_ request: AgentTaskCreationRequest) throws -> AgentTaskCreationReceipt {
        let requestIdentity = AgentTaskCreationIdentity(request: request)
        func nonblank(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard nonblank(request.taskID) else {
            throw AgentTaskCommandServiceError.invalidCreationRequest(.blankTaskID)
        }
        guard nonblank(request.parentID) else {
            throw AgentTaskCommandServiceError.invalidCreationRequest(.blankParentID)
        }
        guard nonblank(request.scopeID) else {
            throw AgentTaskCommandServiceError.invalidCreationRequest(.blankScopeID)
        }
        guard nonblank(request.idempotencyKey) else {
            throw AgentTaskCommandServiceError.invalidCreationRequest(.blankIdempotencyKey)
        }
        guard request.source.isValid else {
            throw AgentTaskCommandServiceError.invalidCreationRequest(.invalidSource)
        }
        guard request.source.taskID == request.parentID else {
            throw AgentTaskCommandServiceError.invalidCreationRequest(.sourceParentMismatch)
        }

        let receipt = try commandService.create(request)
        let receiptIdentity = AgentTaskCreationIdentity(receipt: receipt)
        guard receiptIdentity == requestIdentity,
              receipt.snapshot.taskID == request.taskID,
              receipt.snapshot.parentID == request.parentID,
              receipt.snapshot.creation?.source == request.source,
              receipt.snapshot.creation?.scopeID == request.scopeID,
              receipt.snapshot.creation?.idempotencyKey == request.idempotencyKey,
              receipt.action.switchAfterCreate == false else {
            throw AgentTaskCommandServiceError.creationIdempotencyConflict
        }
        return receipt
    }
}
