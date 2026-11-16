import Foundation

/// Immutable worker handoff for one Canvas execution attempt.
///
/// This local contract deliberately contains only values already owned by CanvasCore.
/// It neither invokes a provider nor schedules work, writes files, or updates Canvas state.
/// A later consumer must validate the frozen identity before accepting any result.
public struct CanvasWorkerProjection: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion

    public let schemaVersion: Int
    public let identity: CanvasExecutionIdentity
    public let provider: ProviderSnapshot
    public let graphRevision: Int
    public let graphFingerprint: String

    public init(
        identity: CanvasExecutionIdentity,
        provider: ProviderSnapshot,
        graph: NodeGraph,
        schemaVersion: Int = CanvasWorkerProjection.currentSchemaVersion
    ) throws {
        try self.init(
            identity: identity,
            provider: provider,
            graphRevision: graph.revision,
            graphFingerprint: graph.fingerprint,
            schemaVersion: schemaVersion
        )
    }

    /// App-layer adapters can pass the already frozen graph revision/fingerprint
    /// without rebuilding a mutable NodeGraph across an async boundary.
    public init(
        identity: CanvasExecutionIdentity,
        provider: ProviderSnapshot,
        graphRevision: Int,
        graphFingerprint: String,
        schemaVersion: Int = CanvasWorkerProjection.currentSchemaVersion
    ) throws {
        try Self.validate(
            identity: identity,
            provider: provider,
            graphRevision: graphRevision,
            graphFingerprint: graphFingerprint
        )
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.provider = provider
        self.graphRevision = graphRevision
        self.graphFingerprint = graphFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, identity, provider, graphRevision, graphFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: container, key: .schemaVersion)
        self.identity = try container.decode(CanvasExecutionIdentity.self, forKey: .identity)
        self.provider = try container.decode(ProviderSnapshot.self, forKey: .provider)
        self.graphRevision = try container.decode(Int.self, forKey: .graphRevision)
        self.graphFingerprint = try container.decode(String.self, forKey: .graphFingerprint)
        try Self.validate(
            identity: identity,
            provider: provider,
            graphRevision: graphRevision,
            graphFingerprint: graphFingerprint
        )
    }

    private static func validate(
        identity: CanvasExecutionIdentity,
        provider: ProviderSnapshot,
        graphRevision: Int,
        graphFingerprint: String
    ) throws {
        guard identity.isValid else { throw CanvasWorkerProjectionError.invalidIdentity }
        guard provider.isValid else { throw CanvasWorkerProjectionError.invalidProvider }
        try CanvasSchema.requireNonNegative(graphRevision, "graphRevision")
        try CanvasSchema.requireNonEmpty(graphFingerprint, "graphFingerprint")
        guard identity.graphRevision == graphRevision else {
            throw CanvasWorkerProjectionError.graphRevisionMismatch(
                expected: identity.graphRevision,
                actual: graphRevision
            )
        }
    }
}

public enum CanvasWorkerProjectionError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentity
    case invalidProvider
    case graphRevisionMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return "Canvas worker projection has an invalid execution identity"
        case .invalidProvider:
            return "Canvas worker projection has an invalid provider snapshot"
        case let .graphRevisionMismatch(expected, actual):
            return "Canvas worker projection graph revision mismatch: expected \(expected), actual \(actual)"
        }
    }
}
