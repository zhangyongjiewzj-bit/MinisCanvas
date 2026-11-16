import Foundation

public struct ParentRuntimeIdentity: Sendable, Equatable, Hashable, Codable {
    public let sessionID: String
    public let conversationID: String
    public let turnID: String
    public let taskID: String
    public let actorID: String

    public init(sessionID: String, conversationID: String, turnID: String, taskID: String, actorID: String) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.turnID = turnID
        self.taskID = taskID
        self.actorID = actorID
    }

    public var isValid: Bool {
        [sessionID, conversationID, turnID, taskID, actorID]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public enum ParentRuntimeIdentitySeedError: Error, Sendable, Equatable {
    case invalidField(String)
    case turnHandleRequired
    case conversationMismatch
    case parentBindingMismatch
}

/// Composition-root identity facts that do not include a turn number.
///
/// Core materializes the turn ID from the exact `TurnHandle` it creates. The
/// composition root therefore cannot smuggle an external/UI turn ID into the
/// Core runtime identity.
public struct ParentRuntimeIdentitySeed: Sendable, Equatable, Hashable, Codable {
    public let sessionID: String
    public let conversationID: String
    public let taskID: String
    public let actorID: String

    public init(sessionID: String, conversationID: String, taskID: String, actorID: String) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.taskID = taskID
        self.actorID = actorID
    }

    public var isValid: Bool {
        [sessionID, conversationID, taskID, actorID]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    internal func makeIdentity(
        using turnHandle: TurnController.TurnHandle
    ) throws -> ParentRuntimeIdentity {
        guard isValid else {
            let fields = [
                ("sessionID", sessionID),
                ("conversationID", conversationID),
                ("taskID", taskID),
                ("actorID", actorID),
            ]
            let invalid = fields.first {
                $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }?.0 ?? "seed"
            throw ParentRuntimeIdentitySeedError.invalidField(invalid)
        }
        guard turnHandle.turnID > 0 else {
            throw ParentRuntimeIdentitySeedError.turnHandleRequired
        }
        return ParentRuntimeIdentity(
            sessionID: sessionID,
            conversationID: conversationID,
            turnID: "turn-handle:\(turnHandle.turnID)",
            taskID: taskID,
            actorID: actorID
        )
    }
}

public enum SessionActionKind: String, Sendable, Equatable, Hashable, Codable {
    case new
    case rename
    case `switch`
    case fork
}

public enum SessionMemoryPolicy: String, Sendable, Equatable, Hashable, Codable {
    case currentSessionOnly
    case explicitProjectScope
}

public enum SessionActionError: Error, Sendable, Equatable {
    case invalidSource
    case sourceTurnMismatch
    case invalidTarget
    case invalidTitle
    case switchNotConfirmed
    case executionFailed
}

public struct SessionAction: Sendable, Equatable, Hashable, Codable {
    public let action: SessionActionKind
    public let targetSessionID: String?
    public let title: String?
    public let projectID: String?
    public let workingDirectory: String?
    public let switchAfterCreate: Bool
    public let memoryPolicy: SessionMemoryPolicy?
    public let source: ParentRuntimeIdentity

    private init(
        action: SessionActionKind,
        targetSessionID: String?,
        title: String?,
        projectID: String?,
        workingDirectory: String?,
        switchAfterCreate: Bool,
        memoryPolicy: SessionMemoryPolicy?,
        source: ParentRuntimeIdentity
    ) {
        self.action = action
        self.targetSessionID = targetSessionID
        self.title = title
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.switchAfterCreate = switchAfterCreate
        self.memoryPolicy = memoryPolicy
        self.source = source
    }

    public static func new(
        title: String,
        projectID: String? = nil,
        workingDirectory: String? = nil,
        switchAfterCreate: Bool = false,
        source: ParentRuntimeIdentity
    ) -> SessionAction {
        SessionAction(
            action: .new,
            targetSessionID: nil,
            title: title,
            projectID: projectID,
            workingDirectory: workingDirectory,
            switchAfterCreate: switchAfterCreate,
            memoryPolicy: nil,
            source: source
        )
    }

    public static func `switch`(sessionID: String, source: ParentRuntimeIdentity) -> SessionAction {
        SessionAction(
            action: .switch,
            targetSessionID: sessionID,
            title: nil,
            projectID: nil,
            workingDirectory: nil,
            switchAfterCreate: false,
            memoryPolicy: nil,
            source: source
        )
    }

    public static func rename(
        sessionID: String,
        title: String,
        source: ParentRuntimeIdentity
    ) -> SessionAction {
        SessionAction(
            action: .rename,
            targetSessionID: sessionID,
            title: title,
            projectID: nil,
            workingDirectory: nil,
            switchAfterCreate: false,
            memoryPolicy: nil,
            source: source
        )
    }

    public static func fork(sessionID: String, source: ParentRuntimeIdentity) -> SessionAction {
        SessionAction(
            action: .fork,
            targetSessionID: sessionID,
            title: nil,
            projectID: nil,
            workingDirectory: nil,
            switchAfterCreate: true,
            memoryPolicy: nil,
            source: source
        )
    }

    public func validate(against current: ParentRuntimeIdentity) throws {
        guard source.isValid else { throw SessionActionError.invalidSource }
        guard source == current else { throw SessionActionError.sourceTurnMismatch }
        switch action {
        case .new:
            guard targetSessionID == nil else {
                throw SessionActionError.invalidTarget
            }
            guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SessionActionError.invalidTitle
            }
        case .rename:
            guard let targetSessionID,
                  !targetSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SessionActionError.invalidTarget
            }
            guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SessionActionError.invalidTitle
            }
        case .switch, .fork:
            guard let targetSessionID,
                  !targetSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SessionActionError.invalidTarget
            }
        }
    }

    public func validateAndReceipt(createdSessionID: String, switched: Bool) throws -> SessionActionReceipt {
        try validate(against: source)
        guard !createdSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionActionError.invalidTarget
        }
        switch action {
        case .new:
            guard targetSessionID == nil else {
                throw SessionActionError.invalidTarget
            }
        case .rename, .switch:
            guard targetSessionID == createdSessionID else {
                throw SessionActionError.invalidTarget
            }
        case .fork:
            guard let targetSessionID,
                  !targetSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  targetSessionID != createdSessionID else {
                throw SessionActionError.invalidTarget
            }
        }
        if switchAfterCreate && !switched { throw SessionActionError.switchNotConfirmed }
        return SessionActionReceipt(
            action: action,
            sessionID: createdSessionID,
            targetSessionID: targetSessionID,
            title: title,
            projectID: projectID,
            workingDirectory: workingDirectory,
            source: source,
            didSwitch: switched
        )
    }
}

public struct SessionActionReceipt: Sendable, Equatable, Codable {
    public let action: SessionActionKind
    public let sessionID: String
    /// The session explicitly targeted by the action. For fork this is the
    /// source session being copied; it must remain distinct from the new child.
    public let targetSessionID: String?
    public let title: String?
    public let projectID: String?
    public let workingDirectory: String?
    public let source: ParentRuntimeIdentity
    public let didSwitch: Bool
}

/// Durable, non-secret provenance for a task-created session action.
///
/// The idempotency key and scope are persisted beside the action so a replay
/// after restart can be compared with the original request instead of being
/// treated as a new project-scoped mutation. `SessionAction` intentionally
/// carries only the typed source identity and session destination facts.
public struct SessionActionCreationMetadata: Sendable, Equatable, Hashable, Codable {
    public let scopeID: String
    public let idempotencyKey: String
    public let action: SessionAction

    public init(scopeID: String, idempotencyKey: String, action: SessionAction) {
        self.scopeID = scopeID
        self.idempotencyKey = idempotencyKey
        self.action = action
    }

    public var source: ParentRuntimeIdentity { action.source }
    public var projectID: String? { action.projectID }
    public var switchAfterCreate: Bool { action.switchAfterCreate }
}
