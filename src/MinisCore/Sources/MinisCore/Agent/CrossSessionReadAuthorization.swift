import Foundation

/// The only data scopes exposed by the read-only cross-session tool.
public enum SessionReadScope: String, CaseIterable, Sendable, Equatable {
    case metadata
    case messages
    /// Metadata-only list of this app's sessions (active, archived, trashed).
    case list
    /// Markdown export of the current session (same text as the sidebar export).
    case export

    /// list/export act on the session list / the current session, not on a target ID.
    public var isSessionLevel: Bool { self == .list || self == .export }
}

/// 生命周期中的一次跨会话只读授权。
///
/// This is intentionally an in-memory capability. It has no `Codable`
/// conformance and the model-facing tool input never contains or creates one.
/// The composition root must issue it for a concrete conversation/turn and
/// pass the typed value to the execution layer.
public struct CrossSessionReadAuthorization: Sendable, Equatable {
    public enum InvalidationReason: String, Sendable, Equatable {
        case stopped
        case turnEnded
        case revoked
        case conversationChanged
    }

    public let currentConversationID: String
    /// Session that issued the capability. This is separate from the
    /// conversation label so a capability cannot be replayed from a sibling
    /// session that happens to share a conversation context.
    public let sourceSessionID: String
    public let authorizedSessionID: String
    /// A capability identity is unique even when two grants happen to carry
    /// identical session/scope fields. The ledger below makes an accidentally
    /// duplicated identity non-replayable across independent values.
    public let capabilityID: UUID
    public let scope: SessionReadScope
    public let turnID: Int
    /// Runtime restart epoch supplied by the composition root. An old
    /// capability must not cross into a new runtime epoch.
    public let restartRevision: String
    public let issuedAt: Date
    public let expiresAt: Date

    private let state: CrossSessionReadAuthorizationState

    public init(
        currentConversationID: String,
        authorizedSessionID: String,
        turnID: Int,
        issuedAt: Date,
        expiresAt: Date,
        scope: SessionReadScope = .metadata,
        sourceSessionID: String? = nil,
        restartRevision: String = "initial",
        capabilityID: UUID = UUID()
    ) {
        self.currentConversationID = currentConversationID
        self.sourceSessionID = sourceSessionID ?? currentConversationID
        self.authorizedSessionID = authorizedSessionID
        self.capabilityID = capabilityID
        self.scope = scope
        self.turnID = turnID
        self.restartRevision = restartRevision
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.state = CrossSessionReadAuthorizationState()
    }

    /// Issue a short-lived capability with a deterministic expiry relative to
    /// the supplied clock. Callers should retain the returned value only for
    /// the active turn.
    public static func issue(
        currentConversationID: String,
        authorizedSessionID: String,
        turnID: Int,
        issuedAt: Date = Date(),
        lifetime: TimeInterval = 60,
        scope: SessionReadScope = .metadata,
        sourceSessionID: String? = nil,
        restartRevision: String = "initial",
        capabilityID: UUID = UUID()
    ) -> CrossSessionReadAuthorization {
        CrossSessionReadAuthorization(
            currentConversationID: currentConversationID,
            authorizedSessionID: authorizedSessionID,
            turnID: turnID,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(max(0, lifetime)),
            scope: scope,
            sourceSessionID: sourceSessionID,
            restartRevision: restartRevision,
            capabilityID: capabilityID
        )
    }

    /// False after an explicit stop/end/revoke. Expiry is checked against the
    /// caller's clock at execution time and is therefore not folded into this
    /// property.
    public var isActive: Bool { state.reason == nil }

    public var invalidationReason: InvalidationReason? { state.reason }

    /// Invalidate this capability. The first reason wins so a stop cannot be
    /// overwritten later by a generic turn cleanup.
    public func invalidate(reason: InvalidationReason = .revoked) {
        state.invalidate(reason: reason)
    }

    /// Mark one authorized target/scope pair as consumed. Keeping this state
    /// on the in-memory capability makes a captured tool call non-replayable
    /// while still allowing a failed target lookup to report its real error.
    func consume(targetSessionID: String, scope: SessionReadScope) -> Bool {
        guard CrossSessionReadAuthorizationLedger.shared.consume(capabilityID: capabilityID) else {
            return false
        }
        return state.consume(targetSessionID: targetSessionID, scope: scope)
    }

    func validate(
        targetSessionID: String,
        scope: SessionReadScope,
        context: SessionReadExecutionContext,
        now: Date
    ) throws {
        guard Self.isValidBindingIdentifier(currentConversationID),
              Self.isValidBindingIdentifier(sourceSessionID),
              Self.isValidBindingIdentifier(authorizedSessionID),
              Self.isValidBindingIdentifier(targetSessionID),
              Self.isValidBindingIdentifier(restartRevision)
        else {
            throw CrossSessionReadAuthorizationError.invalidIdentity
        }
        if let reason = state.reason {
            switch reason {
            case .stopped:
                throw CrossSessionReadAuthorizationError.stopped
            case .turnEnded:
                throw CrossSessionReadAuthorizationError.turnEnded
            case .revoked:
                throw CrossSessionReadAuthorizationError.revoked
            case .conversationChanged:
                throw CrossSessionReadAuthorizationError.conversationChanged
            }
        }
        guard Self.exactIdentifierMatch(context.currentConversationID, currentConversationID) else {
            // A capability must not become valid again merely because a caller
            // later supplies the original conversation context. Once the
            // execution context has switched conversations, revoke it.
            state.invalidate(reason: .conversationChanged)
            throw CrossSessionReadAuthorizationError.conversationMismatch
        }
        guard Self.exactIdentifierMatch(context.sourceSessionID, sourceSessionID) else {
            throw CrossSessionReadAuthorizationError.sourceSessionMismatch
        }
        guard Self.exactIdentifierMatch(context.restartRevision, restartRevision) else {
            throw CrossSessionReadAuthorizationError.restartRevisionMismatch
        }
        guard context.turnID == turnID else {
            throw CrossSessionReadAuthorizationError.turnMismatch
        }
        guard !context.isStopped else {
            throw CrossSessionReadAuthorizationError.stopped
        }
        guard now >= issuedAt else {
            throw CrossSessionReadAuthorizationError.notYetValid
        }
        guard now < expiresAt else {
            throw CrossSessionReadAuthorizationError.expired
        }
        guard Self.exactIdentifierMatch(targetSessionID, authorizedSessionID) else {
            throw CrossSessionReadAuthorizationError.sessionNotAuthorized
        }
        guard scope == self.scope else {
            throw CrossSessionReadAuthorizationError.scopeNotAuthorized
        }
    }

    func validate(
        targetSessionID: String,
        context: SessionReadExecutionContext,
        now: Date
    ) throws {
        try validate(
            targetSessionID: targetSessionID,
            scope: scope,
            context: context,
            now: now
        )
    }

    public static func == (
        lhs: CrossSessionReadAuthorization,
        rhs: CrossSessionReadAuthorization
    ) -> Bool {
        exactIdentifierMatch(lhs.currentConversationID, rhs.currentConversationID)
            && exactIdentifierMatch(lhs.sourceSessionID, rhs.sourceSessionID)
            && exactIdentifierMatch(lhs.authorizedSessionID, rhs.authorizedSessionID)
            && lhs.capabilityID == rhs.capabilityID
            && lhs.scope == rhs.scope
            && lhs.turnID == rhs.turnID
            && exactIdentifierMatch(lhs.restartRevision, rhs.restartRevision)
            && lhs.issuedAt == rhs.issuedAt
            && lhs.expiresAt == rhs.expiresAt
    }

    private static func exactIdentifierMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func isValidBindingIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value != "."
            && value != ".."
            && value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil
    }
}

/// Runtime context supplied by the composition root for one tool execution.
/// It is deliberately separate from model input and carries the current turn
/// and stop state used to validate a capability.
public struct SessionReadExecutionContext: Sendable, Equatable {
    public let currentConversationID: String
    public let sourceSessionID: String
    public let turnID: Int
    public let isStopped: Bool
    public let restartRevision: String

    public init(
        currentConversationID: String,
        turnID: Int,
        isStopped: Bool = false,
        sourceSessionID: String? = nil,
        restartRevision: String = "initial"
    ) {
        self.currentConversationID = currentConversationID
        self.sourceSessionID = sourceSessionID ?? currentConversationID
        self.turnID = turnID
        self.isStopped = isStopped
        self.restartRevision = restartRevision
    }
}

/// Explicit authorization failures for the session-read execution boundary.
public enum CrossSessionReadAuthorizationError: Error, LocalizedError, Equatable, Sendable {
    case capabilityRequired
    case invalidIdentity
    case conversationMismatch
    case sourceSessionMismatch
    case restartRevisionMismatch
    case sessionNotAuthorized
    case scopeNotAuthorized
    case replayed
    case turnMismatch
    case notYetValid
    case expired
    case stopped
    case turnEnded
    case revoked
    case conversationChanged

    public var errorDescription: String? {
        switch self {
        case .capabilityRequired:
            return "session_read requires an execution capability"
        case .invalidIdentity:
            return "session_read capability contains an invalid identity"
        case .conversationMismatch:
            return "session_read capability is bound to another conversation"
        case .sourceSessionMismatch:
            return "session_read capability is bound to another source session"
        case .restartRevisionMismatch:
            return "session_read capability belongs to another runtime revision"
        case .sessionNotAuthorized:
            return "session_read capability does not authorize this session"
        case .scopeNotAuthorized:
            return "session_read capability does not authorize this scope"
        case .replayed:
            return "session_read capability has already been consumed for this request"
        case .turnMismatch:
            return "session_read capability is bound to another turn"
        case .notYetValid:
            return "session_read capability is not valid yet"
        case .expired:
            return "session_read capability has expired"
        case .stopped:
            return "session_read capability was stopped"
        case .turnEnded:
            return "session_read capability belongs to an ended turn"
        case .revoked:
            return "session_read capability was revoked"
        case .conversationChanged:
            return "session_read capability was invalidated by a conversation switch"
        }
    }
}

/// Core interface for the eventual ToolExecutor composition.
///
/// It keeps the typed capability out of `[String: Any]`. The current
/// BuiltinToolExecutor call site is intentionally left unchanged for the
/// total controller to wire in the shared composition root.
public protocol SessionReadCapabilityAwareToolExecutor: ToolExecutor {
    func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String
}

private final class CrossSessionReadAuthorizationState: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidation: CrossSessionReadAuthorization.InvalidationReason?
    private var consumedRequests: Set<String> = []

    var reason: CrossSessionReadAuthorization.InvalidationReason? {
        lock.lock()
        defer { lock.unlock() }
        return invalidation
    }

    func invalidate(reason: CrossSessionReadAuthorization.InvalidationReason) {
        lock.lock()
        if invalidation == nil {
            invalidation = reason
        }
        lock.unlock()
    }

    func consume(targetSessionID: String, scope: SessionReadScope) -> Bool {
        let key = "\(targetSessionID)\u{0}\(scope.rawValue)"
        lock.lock()
        defer { lock.unlock() }
        // Revocation and consumption share one admission point. Validation may
        // already have returned before another task invalidates this value.
        guard invalidation == nil else { return false }
        guard consumedRequests.insert(key).inserted else { return false }
        return true
    }
}

/// Process-local identity ledger. Capabilities are intentionally in-memory,
/// so a restart cannot restore an old object; a repeated identity in one
/// runtime is nevertheless rejected before the target is read.
private final class CrossSessionReadAuthorizationLedger: @unchecked Sendable {
    static let shared = CrossSessionReadAuthorizationLedger()
    private static let capacity = 4_096

    private let lock = NSLock()
    private var consumedIDs: Set<UUID> = []
    private var insertionOrder: [UUID] = []

    func consume(capabilityID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard consumedIDs.insert(capabilityID).inserted else { return false }
        insertionOrder.append(capabilityID)
        if insertionOrder.count > Self.capacity,
           let retired = insertionOrder.first {
            insertionOrder.removeFirst()
            consumedIDs.remove(retired)
        }
        return true
    }
}
