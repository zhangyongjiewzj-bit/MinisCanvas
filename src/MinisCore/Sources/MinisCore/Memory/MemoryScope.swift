import Foundation

// MARK: - MemoryScope

/// Identity scope for persisted memory facts.
///
/// A memory fact is written and read within a `(sessionID, projectID)` scope.
/// Both identifiers must be non-empty: an empty or whitespace-only identifier
/// makes the scope invalid, and every check on an invalid scope fails closed
/// (never matches, always isolated).
///
/// A5 local contract plus production consumer boundary. Persistence and
/// proposal admission remain separate from this value type.
public struct MemoryScope: Codable, Hashable, Sendable, Equatable {
    /// Identifies the conversation session that owns the memory fact.
    public let sessionID: String
    /// Identifies the project that owns the memory fact.
    public let projectID: String

    /// Workspace spelling used by the unified Scope contract. The persisted
    /// field remains `projectID` for compatibility with existing facts.
    public var workspaceID: String { projectID }

    public init(sessionID: String, projectID: String) {
        self.sessionID = sessionID
        self.projectID = projectID
    }

    /// Construct a scope using the product-facing workspace terminology.
    public init(sessionID: String, workspaceID: String) {
        self.init(sessionID: sessionID, projectID: workspaceID)
    }

    /// `true` when both identifiers are non-empty after trimming whitespace.
    public var isValid: Bool {
        !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fail-closed membership check: matches only when this scope is valid and
    /// both identifiers are exactly equal to the requested ones. An invalid
    /// scope, or an empty/whitespace request side, never matches.
    public func matches(sessionID: String, projectID: String) -> Bool {
        guard isValid else { return false }
        return self.sessionID == sessionID && self.projectID == projectID
    }

    /// Fail-closed isolation check: two scopes are isolated unless both are
    /// valid and identical. Invalid scopes never share access with anything,
    /// including other invalid scopes.
    public func isIsolated(from other: MemoryScope) -> Bool {
        !(isValid && other.isValid && self == other)
    }
}

/// Explicit visibility of a newly classified fact. A missing value means an
/// older fact; it is not evidence that the fact is personal or project-wide.
public enum MemoryVisibility: String, Codable, Hashable, Sendable {
    case personal
    case project
    case temporary
}

/// Opaque lifetime chosen by an authorized caller for a temporary fact.
/// Core only compares this identity. It does not choose session/turn duration,
/// expire facts, or delete them when a lifetime ends.
public struct MemoryTemporaryLifetime: Codable, Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public var isValid: Bool {
        !id.isEmpty && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Principal admitted by a product authentication boundary. A user name,
/// model output, current directory, or `local-user` placeholder is not proof.
/// The verifier must be supplied by that boundary, never by recalled content.
public struct MemoryTrustedPrincipal: Hashable, Sendable {
    public let userID: String

    private init(userID: String) {
        self.userID = userID
    }

    public static func validated(
        userID: String,
        by verifier: @Sendable (String) -> Bool
    ) -> MemoryTrustedPrincipal? {
        guard !userID.isEmpty,
              userID == userID.trimmingCharacters(in: .whitespacesAndNewlines),
              userID != "local-user",
              verifier(userID) else { return nil }
        return MemoryTrustedPrincipal(userID: userID)
    }
}

/// Exact runtime scope plus optional authenticated principal and explicitly
/// selected temporary lifetime. The caller must supply the active product
/// scope; Core never derives identity from local machine state.
public struct MemoryInjectionContext: Sendable {
    public let scope: MemoryScope
    public let trustedPrincipal: MemoryTrustedPrincipal?
    public let temporaryLifetime: MemoryTemporaryLifetime?

    public init(
        scope: MemoryScope,
        trustedPrincipal: MemoryTrustedPrincipal? = nil,
        temporaryLifetime: MemoryTemporaryLifetime? = nil
    ) {
        self.scope = scope
        self.trustedPrincipal = trustedPrincipal
        self.temporaryLifetime = temporaryLifetime
    }
}

/// Immutable identity fence captured when a memory proposal is created.
///
/// A proposal can only be consumed when all five facts still agree: session,
/// workspace, proposal identity, source revision hash, and generation. The
/// value is content-free and safe to persist alongside lifecycle receipts.
public struct MemoryProposalBinding: Codable, Hashable, Sendable, Equatable {
    public let sessionID: String
    public let workspaceID: String
    public let proposalID: String
    public let sourceHash: String
    public let generation: Int

    public init(
        sessionID: String,
        workspaceID: String,
        proposalID: String,
        sourceHash: String,
        generation: Int
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.proposalID = proposalID
        self.sourceHash = sourceHash
        self.generation = generation
    }

    public var isValid: Bool {
        !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !proposalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sourceHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && generation >= 0
    }

    public func matches(
        scope: MemoryScope,
        proposalID: String,
        sourceHash: String,
        generation: Int
    ) -> Bool {
        isValid
            && scope.isValid
            && sessionID == scope.sessionID
            && workspaceID == scope.workspaceID
            && self.proposalID == proposalID
            && self.sourceHash == sourceHash
            && self.generation == generation
    }
}

/// Historical opt-in read selector for facts without a visibility marker.
///
/// A session read is exact. Project and user reads are opt-in broader
/// selectors; legacy facts without the required identity never match. New
/// classified facts use `MemoryInjectionContext` and are excluded from these
/// selectors by the store.
public enum MemoryScopeFilter: Codable, Hashable, Sendable, Equatable {
    case session(MemoryScope)
    case project(projectID: String)
    case user(userID: String)

    public var isValid: Bool {
        switch self {
        case .session(let scope):
            return scope.isValid
        case .project(let projectID):
            return !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .user(let userID):
            return !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Match only facts carrying the identity required by this selector.
    /// Missing or invalid metadata fails closed.
    public func matches(
        memoryScope: MemoryScope?,
        ownerUserID: String?
    ) -> Bool {
        guard isValid, let memoryScope, memoryScope.isValid else { return false }

        switch self {
        case .session(let requested):
            return requested.isValid && memoryScope == requested
        case .project(let projectID):
            return memoryScope.projectID == projectID
        case .user(let userID):
            guard let ownerUserID else { return false }
            return ownerUserID != "local-user" && ownerUserID == userID
        }
    }
}
