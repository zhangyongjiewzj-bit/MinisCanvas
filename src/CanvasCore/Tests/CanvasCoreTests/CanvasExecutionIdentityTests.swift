import Testing
import Foundation
@testable import CanvasCore

struct CanvasExecutionIdentityTests {
    private func identity() -> CanvasExecutionIdentity {
        CanvasExecutionIdentity(
            canvasID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            graphRevision: 4,
            nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            nodeRevision: 2
        )
    }

    @Test func matchingIdentityIsAccepted() {
        #expect(validateCanvasWriteback(expected: identity(), actual: identity(), isCancelled: false) == .accepted)
    }

    @Test(arguments: [
        WritebackRejection.canvasMismatch,
        .runMismatch,
        .graphRevisionMismatch,
        .nodeMismatch,
        .nodeRevisionMismatch
    ])
    func mismatchedIdentityIsRejected(_ rejection: WritebackRejection) {
        let expected = identity()
        var actual = expected
        switch rejection {
        case .canvasMismatch: actual = CanvasExecutionIdentity(canvasID: UUID(), runID: expected.runID, graphRevision: expected.graphRevision, nodeID: expected.nodeID, nodeRevision: expected.nodeRevision)
        case .runMismatch: actual = CanvasExecutionIdentity(canvasID: expected.canvasID, runID: UUID(), graphRevision: expected.graphRevision, nodeID: expected.nodeID, nodeRevision: expected.nodeRevision)
        case .graphRevisionMismatch: actual = CanvasExecutionIdentity(canvasID: expected.canvasID, runID: expected.runID, graphRevision: 5, nodeID: expected.nodeID, nodeRevision: expected.nodeRevision)
        case .nodeMismatch: actual = CanvasExecutionIdentity(canvasID: expected.canvasID, runID: expected.runID, graphRevision: expected.graphRevision, nodeID: UUID(), nodeRevision: expected.nodeRevision)
        case .nodeRevisionMismatch: actual = CanvasExecutionIdentity(canvasID: expected.canvasID, runID: expected.runID, graphRevision: expected.graphRevision, nodeID: expected.nodeID, nodeRevision: 3)
        case .cancelled: break
        }
        #expect(validateCanvasWriteback(expected: expected, actual: actual, isCancelled: false) == .rejected(rejection))
    }

    @Test func cancelledWritebackIsRejectedBeforeIdentityChecks() {
        #expect(validateCanvasWriteback(expected: identity(), actual: CanvasExecutionIdentity(canvasID: UUID(), runID: UUID(), graphRevision: 0, nodeID: UUID(), nodeRevision: 0), isCancelled: true) == .rejected(.cancelled))
    }

    @Test func providerSnapshotRoundTrips() throws {
        let snapshot = ProviderSnapshot(providerID: "fake", modelID: "image-v1", capabilities: [.image, .video], configurationFingerprint: "fp")
        let decoded = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test func dagEnvelopeRoundTripsOriginAndWritebackFields() throws {
        let envelope = DAGExecutionEnvelope(
            canvasID: identity().canvasID,
            runID: identity().runID,
            graphRevision: identity().graphRevision,
            graphFingerprint: "graph-fingerprint",
            cancellationGeneration: 3,
            providerSnapshotFingerprint: "provider-fingerprint",
            idempotencyKey: "run-key"
        )

        try envelope.validate()
        let decoded = try JSONDecoder().decode(
            DAGExecutionEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )

        #expect(decoded == envelope)
        #expect(
            envelope.identity(
                for: identity().nodeID,
                nodeRevision: identity().nodeRevision
            ) == identity()
        )
    }

    @Test(arguments: [
        DAGWritebackRejection.runMismatch,
        .graphRevisionMismatch,
        .graphFingerprintMismatch,
        .cancellationGenerationMismatch,
        .providerSnapshotMismatch,
        .idempotencyMismatch
    ])
    func dagEnvelopeRejectsLateCompletionWithoutCanvasFallback(
        _ rejection: DAGWritebackRejection
    ) {
        let expected = DAGExecutionEnvelope(
            canvasID: identity().canvasID,
            runID: identity().runID,
            graphRevision: identity().graphRevision,
            graphFingerprint: "graph-fingerprint",
            cancellationGeneration: 1,
            providerSnapshotFingerprint: "provider-fingerprint",
            idempotencyKey: "run-key"
        )
        var actual = expected
        switch rejection {
        case .runMismatch:
            actual = DAGExecutionEnvelope(
                canvasID: expected.canvasID,
                runID: UUID(),
                graphRevision: expected.graphRevision,
                graphFingerprint: expected.graphFingerprint,
                cancellationGeneration: expected.cancellationGeneration,
                providerSnapshotFingerprint: expected.providerSnapshotFingerprint,
                idempotencyKey: expected.idempotencyKey
            )
        case .graphRevisionMismatch:
            actual = DAGExecutionEnvelope(
                canvasID: expected.canvasID,
                runID: expected.runID,
                graphRevision: expected.graphRevision + 1,
                graphFingerprint: expected.graphFingerprint,
                cancellationGeneration: expected.cancellationGeneration,
                providerSnapshotFingerprint: expected.providerSnapshotFingerprint,
                idempotencyKey: expected.idempotencyKey
            )
        case .graphFingerprintMismatch:
            actual = DAGExecutionEnvelope(
                canvasID: expected.canvasID,
                runID: expected.runID,
                graphRevision: expected.graphRevision,
                graphFingerprint: "other-graph",
                cancellationGeneration: expected.cancellationGeneration,
                providerSnapshotFingerprint: expected.providerSnapshotFingerprint,
                idempotencyKey: expected.idempotencyKey
            )
        case .cancellationGenerationMismatch:
            actual = DAGExecutionEnvelope(
                canvasID: expected.canvasID,
                runID: expected.runID,
                graphRevision: expected.graphRevision,
                graphFingerprint: expected.graphFingerprint,
                cancellationGeneration: expected.cancellationGeneration + 1,
                providerSnapshotFingerprint: expected.providerSnapshotFingerprint,
                idempotencyKey: expected.idempotencyKey
            )
        case .providerSnapshotMismatch:
            actual = DAGExecutionEnvelope(
                canvasID: expected.canvasID,
                runID: expected.runID,
                graphRevision: expected.graphRevision,
                graphFingerprint: expected.graphFingerprint,
                cancellationGeneration: expected.cancellationGeneration,
                providerSnapshotFingerprint: "other-provider",
                idempotencyKey: expected.idempotencyKey
            )
        case .idempotencyMismatch:
            actual = DAGExecutionEnvelope(
                canvasID: expected.canvasID,
                runID: expected.runID,
                graphRevision: expected.graphRevision,
                graphFingerprint: expected.graphFingerprint,
                cancellationGeneration: expected.cancellationGeneration,
                providerSnapshotFingerprint: expected.providerSnapshotFingerprint,
                idempotencyKey: "other-run-key"
            )
        default:
            break
        }

        #expect(
            validateDAGWriteback(expected: expected, actual: actual, isCancelled: false)
                == .rejected(rejection)
        )
        #expect(
            validateDAGWriteback(expected: expected, actual: actual, isCancelled: true)
                == .rejected(.cancelled)
        )
        let unsupported = CanvasExecutionIdentity(
            canvasID: identity().canvasID,
            runID: identity().runID,
            graphRevision: identity().graphRevision,
            nodeID: identity().nodeID,
            nodeRevision: identity().nodeRevision,
            schemaVersion: CanvasExecutionIdentity.currentSchemaVersion + 1
        )
        #expect(!unsupported.isValid)
    }

    @Test func schemaVersionMalformedForwardAndFallbackIdentityFailClosed() throws {
        let malformedSchema = Data(#"{"schemaVersion":"1","canvasID":"00000000-0000-0000-0000-000000000001","runID":"00000000-0000-0000-0000-000000000002","graphRevision":4,"nodeID":"00000000-0000-0000-0000-000000000003","nodeRevision":2}"#.utf8)
        var malformedRejected = false
        do {
            _ = try JSONDecoder().decode(CanvasExecutionIdentity.self, from: malformedSchema)
        } catch {
            malformedRejected = true
        }
        #expect(malformedRejected)

        let forward = CanvasExecutionIdentity(
            canvasID: identity().canvasID,
            runID: identity().runID,
            graphRevision: identity().graphRevision,
            nodeID: identity().nodeID,
            nodeRevision: identity().nodeRevision,
            schemaVersion: CanvasExecutionIdentity.currentSchemaVersion + 1
        )
        #expect(!forward.isValid)
        #expect(
            validateCanvasWriteback(
                expected: identity(),
                actual: forward,
                isCancelled: false
            ) == .rejected(.graphRevisionMismatch)
        )

        let fallback = CanvasExecutionIdentity(
            canvasID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            runID: identity().runID,
            graphRevision: identity().graphRevision,
            nodeID: identity().nodeID,
            nodeRevision: identity().nodeRevision
        )
        #expect(!fallback.isValid)
        #expect(
            validateCanvasWriteback(
                expected: identity(),
                actual: fallback,
                isCancelled: false
            ) == .rejected(.graphRevisionMismatch)
        )
    }
}
