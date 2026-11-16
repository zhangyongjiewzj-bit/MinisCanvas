import Foundation

/// The portion of an external memory source that may be read.
/// Metadata and messages are separate capabilities.
public enum MemoryReadContent: String, Codable, Hashable, Sendable {
    case metadata
    case messages
}

/// Concrete memory identity plus the content capability being requested.
public struct MemoryReadScope: Codable, Hashable, Sendable, Equatable {
    public let memoryScope: MemoryScope
    public let content: MemoryReadContent

    public init(memoryScope: MemoryScope, content: MemoryReadContent) {
        self.memoryScope = memoryScope
        self.content = content
    }

    public var isValid: Bool {
        memoryScope.isValid
    }
}

public enum ExternalSourceAvailability: String, Codable, Sendable {
    case available
    case unavailable
}

/// Read-only adapter identity. This contract performs no transport work.
public protocol ExternalSourceReadOnly: Sendable {
    var sourceID: String { get }
    var availability: ExternalSourceAvailability { get }
}

public struct ExternalSourceReadAuthorization: Codable, Hashable, Sendable, Equatable {
    public let grantID: String
    public let sourceID: String
    public let scopes: Set<MemoryReadScope>
    public let expiresAt: Date
    public let revokedAt: Date?

    public init(
        grantID: String,
        sourceID: String,
        scopes: Set<MemoryReadScope>,
        expiresAt: Date,
        revokedAt: Date? = nil
    ) {
        self.grantID = grantID
        self.sourceID = sourceID
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }
}

public struct ExternalSourceReadRequest: Sendable, Equatable {
    public let sourceID: String
    public let scope: MemoryReadScope
    public let authorization: ExternalSourceReadAuthorization?
    public let provenance: MemoryProvenance?

    public init(
        sourceID: String,
        scope: MemoryReadScope,
        authorization: ExternalSourceReadAuthorization?,
        provenance: MemoryProvenance? = nil
    ) {
        self.sourceID = sourceID
        self.scope = scope
        self.authorization = authorization
        self.provenance = provenance
    }
}

public enum ExternalSourceAuthorizationError: Error, Equatable, Sendable {
    case unauthorized
    case invalidScope
    case sourceMismatch
    case expired
    case revoked
    case sourceUnavailable
    case scopeNotGranted
    case provenanceMismatch
}

/// Non-content provenance captured when a memory value is admitted from an
/// external source. It is safe to persist and is required for destructive
/// operations to bind to the exact source revision that was reviewed.
public struct MemoryProvenance: Codable, Hashable, Sendable, Equatable {
    public let sourceID: String
    public let grantID: String
    public let scope: MemoryReadScope
    public let contentDigest: String
    public let sourceRevision: Int

    public init(sourceID: String, grantID: String, scope: MemoryReadScope, contentDigest: String, sourceRevision: Int) {
        self.sourceID = sourceID
        self.grantID = grantID
        self.scope = scope
        self.contentDigest = contentDigest
        self.sourceRevision = sourceRevision
    }

    public var isValid: Bool {
        !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !grantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && scope.isValid
            && !contentDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sourceRevision >= 0
    }
}

/// Explicit user confirmation for deleting one provenance-bound memory value.
/// A confirmation cannot be reused for a different target, scope, digest, or
/// source revision.
public struct MemoryDeleteConfirmation: Codable, Hashable, Sendable, Equatable {
    public let confirmationID: String
    public let targetID: String
    public let provenance: MemoryProvenance
    public let actorID: String
    public let confirmedAt: Date
    public let expiresAt: Date?

    public init(
        confirmationID: String,
        targetID: String,
        provenance: MemoryProvenance,
        actorID: String,
        confirmedAt: Date,
        expiresAt: Date? = nil
    ) {
        self.confirmationID = confirmationID
        self.targetID = targetID
        self.provenance = provenance
        self.actorID = actorID
        self.confirmedAt = confirmedAt
        self.expiresAt = expiresAt
    }
}

public enum MemoryDeleteAuthorizationError: Error, Equatable, Sendable {
    case invalidConfirmation
    case targetMismatch
    case provenanceMismatch
    case expired
}

public extension MemoryDeleteConfirmation {
    func validate(
        targetID expectedTargetID: String,
        provenance expectedProvenance: MemoryProvenance,
        now: Date
    ) throws {
        guard !confirmationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !targetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provenance.isValid else {
            throw MemoryDeleteAuthorizationError.invalidConfirmation
        }
        guard targetID == expectedTargetID else {
            throw MemoryDeleteAuthorizationError.targetMismatch
        }
        guard provenance == expectedProvenance else {
            throw MemoryDeleteAuthorizationError.provenanceMismatch
        }
        guard confirmedAt <= now else {
            throw MemoryDeleteAuthorizationError.invalidConfirmation
        }
        guard expiresAt.map({ now < $0 }) ?? true else {
            throw MemoryDeleteAuthorizationError.expired
        }
    }
}

/// Pure, fail-closed authorization gate for external memory reads.
public enum ExternalSourceReadAuthorizer {
    public static func validate(
        _ request: ExternalSourceReadRequest,
        source: any ExternalSourceReadOnly,
        now: Date
    ) throws {
        guard request.scope.isValid else {
            throw ExternalSourceAuthorizationError.invalidScope
        }
        guard source.availability == .available else {
            throw ExternalSourceAuthorizationError.sourceUnavailable
        }
        guard source.sourceID == request.sourceID else {
            throw ExternalSourceAuthorizationError.sourceMismatch
        }
        guard let authorization = request.authorization else {
            throw ExternalSourceAuthorizationError.unauthorized
        }
        guard authorization.sourceID == source.sourceID else {
            throw ExternalSourceAuthorizationError.sourceMismatch
        }
        guard authorization.revokedAt == nil else {
            throw ExternalSourceAuthorizationError.revoked
        }
        guard now < authorization.expiresAt else {
            throw ExternalSourceAuthorizationError.expired
        }
        guard authorization.scopes.contains(request.scope) else {
            throw ExternalSourceAuthorizationError.scopeNotGranted
        }
        if let provenance = request.provenance {
            guard provenance.isValid,
                  provenance.sourceID == source.sourceID,
                  provenance.grantID == authorization.grantID,
                  provenance.scope == request.scope else {
                throw ExternalSourceAuthorizationError.provenanceMismatch
            }
        }
    }
}
