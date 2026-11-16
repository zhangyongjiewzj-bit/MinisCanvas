import Foundation

/// Immutable identity captured before a session recovery callback starts.
/// The creation timestamp and lineage distinguish a recreated session that
/// happens to reuse the same file identifier.
public struct SessionRecoveryIdentity: Equatable, Hashable, Sendable {
    public let sessionID: String
    public let createdAt: Date
    public let lineageIdentity: SessionLineageIdentity

    public init(
        sessionID: String,
        createdAt: Date,
        lineageIdentity: SessionLineageIdentity
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.lineageIdentity = lineageIdentity
    }
}

/// Process-local admission token for one session restore attempt.
public struct SessionRecoveryToken: Equatable, Sendable {
    public let sessionID: String
    public let generation: UInt64
    public let expectedIdentity: SessionRecoveryIdentity?
    /// False means the preimage could not be decoded. Recovery must remain
    /// fail-closed instead of treating an unreadable file as absent.
    public let baselineReadable: Bool

    init(
        sessionID: String,
        generation: UInt64,
        expectedIdentity: SessionRecoveryIdentity?,
        baselineReadable: Bool = true
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.expectedIdentity = expectedIdentity
        self.baselineReadable = baselineReadable
    }
}

public extension ChatSession {
    /// Identity fields used by SessionStore's late-recovery fence.
    var sessionRecoveryIdentity: SessionRecoveryIdentity {
        SessionRecoveryIdentity(
            sessionID: id,
            createdAt: createdAt,
            lineageIdentity: lineageIdentity
        )
    }
}

/// Coordinates snapshot restore admission and application through the
/// SessionStore generation/identity fence.
public final class SessionRecoveryCoordinator: @unchecked Sendable {
    public let store: SessionStore

    public init(store: SessionStore) {
        self.store = store
    }

    /// Starts one token per session identifier. Duplicate snapshot entries
    /// share the first token and are rejected by the restore caller before
    /// application, so one payload cannot write the same ID twice.
    public func begin(_ sessions: [ChatSession]) -> [String: SessionRecoveryToken] {
        var tokens: [String: SessionRecoveryToken] = [:]
        for session in sessions where tokens[session.id] == nil {
            tokens[session.id] = store.beginSessionRecovery(for: session.id)
        }
        return tokens
    }

    /// Applies one snapshot entry and returns false when its token is stale or
    /// its destination identity has changed.
    @discardableResult
    public func apply(
        _ session: ChatSession,
        token: SessionRecoveryToken
    ) throws -> Bool {
        try store.applyRecoveredSession(session, token: token)
    }
}
