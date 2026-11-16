import Foundation

/// A pure local acceptance boundary for a frozen Canvas worker request.
///
/// This type deliberately does not schedule or execute work. It has no provider,
/// network, GUI, filesystem, or asynchronous dependency.
public enum CanvasWorkerSeam {
    public static func accept(_ projection: CanvasWorkerProjection) -> CanvasWorkerRequestDecision {
        guard projection.identity.isValid else { return .rejected(.invalidIdentity) }
        guard projection.provider.isValid else { return .rejected(.invalidProvider) }
        guard projection.identity.graphRevision == projection.graphRevision else {
            return .rejected(.graphRevisionMismatch)
        }
        guard !projection.graphFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.invalidGraphFingerprint)
        }
        return .accepted(CanvasWorkerRequestReceipt(projection: projection))
    }

    public static func validateWriteback(
        projection: CanvasWorkerProjection,
        actualIdentity: CanvasExecutionIdentity,
        actualGraphRevision: Int,
        actualGraphFingerprint: String
    ) -> CanvasWorkerWritebackDecision {
        switch accept(projection) {
        case .rejected(let rejection):
            return .rejected(rejection)
        case .accepted:
            break
        }

        guard actualIdentity.isValid else { return .rejected(.invalidIdentity) }
        guard projection.identity.canvasID == actualIdentity.canvasID else { return .rejected(.canvasMismatch) }
        guard projection.identity.runID == actualIdentity.runID else { return .rejected(.runMismatch) }
        guard projection.identity.nodeID == actualIdentity.nodeID else { return .rejected(.nodeMismatch) }
        guard projection.identity.nodeRevision == actualIdentity.nodeRevision else {
            return .rejected(.nodeRevisionMismatch)
        }
        guard projection.graphRevision == actualGraphRevision,
              projection.identity.graphRevision == actualIdentity.graphRevision else {
            return .rejected(.graphRevisionMismatch)
        }
        guard projection.graphFingerprint == actualGraphFingerprint else {
            return .rejected(.graphFingerprintMismatch)
        }
        return .accepted(CanvasWorkerResultWritebackPrecondition(projection: projection))
    }

    /// Accepts a local worker result only after the frozen writeback preconditions hold.
    /// This is an in-memory contract and deliberately performs no work beyond validation.
    public static func acceptResult(
        projection: CanvasWorkerProjection,
        resultFingerprint: String,
        actualIdentity: CanvasExecutionIdentity,
        actualGraphRevision: Int,
        actualGraphFingerprint: String
    ) -> CanvasWorkerResultDecision {
        switch validateWriteback(
            projection: projection,
            actualIdentity: actualIdentity,
            actualGraphRevision: actualGraphRevision,
            actualGraphFingerprint: actualGraphFingerprint
        ) {
        case .rejected(let rejection):
            return .rejected(rejection)
        case .accepted:
            break
        }

        guard !resultFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.invalidResultFingerprint)
        }
        return .accepted(CanvasWorkerResultReceipt(
            projection: projection,
            resultFingerprint: resultFingerprint
        ))
    }
}

public struct CanvasWorkerRequestReceipt: Codable, Equatable, Sendable {
    public let projection: CanvasWorkerProjection

    public init(projection: CanvasWorkerProjection) {
        self.projection = projection
    }
}

public enum CanvasWorkerRequestDecision: Equatable, Sendable {
    case accepted(CanvasWorkerRequestReceipt)
    case rejected(CanvasWorkerSeamRejection)
}

public struct CanvasWorkerResultWritebackPrecondition: Codable, Equatable, Sendable {
    public let projection: CanvasWorkerProjection

    public init(projection: CanvasWorkerProjection) {
        self.projection = projection
    }
}

public enum CanvasWorkerWritebackDecision: Equatable, Sendable {
    case accepted(CanvasWorkerResultWritebackPrecondition)
    case rejected(CanvasWorkerSeamRejection)
}

/// Immutable proof that a local worker result passed the frozen writeback checks.
public struct CanvasWorkerResultReceipt: Codable, Equatable, Sendable {
    public let projection: CanvasWorkerProjection
    public let resultFingerprint: String

    public init(projection: CanvasWorkerProjection, resultFingerprint: String) {
        self.projection = projection
        self.resultFingerprint = resultFingerprint
    }
}

public enum CanvasWorkerResultDecision: Equatable, Sendable {
    case accepted(CanvasWorkerResultReceipt)
    case rejected(CanvasWorkerSeamRejection)
}

public enum CanvasWorkerSeamRejection: String, Codable, Equatable, Sendable {
    case invalidIdentity
    case invalidProvider
    case invalidGraphFingerprint
    case invalidResultFingerprint
    case canvasMismatch
    case runMismatch
    case graphRevisionMismatch
    case graphFingerprintMismatch
    case nodeMismatch
    case nodeRevisionMismatch
}
