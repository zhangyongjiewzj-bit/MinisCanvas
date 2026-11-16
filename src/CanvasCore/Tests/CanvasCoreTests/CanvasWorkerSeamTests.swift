import Foundation
import Testing
@testable import CanvasCore

struct CanvasWorkerSeamTests {
    private func identity(
        canvasID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
        runID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
        graphRevision: Int = 7,
        nodeID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
        nodeRevision: Int = 3
    ) -> CanvasExecutionIdentity {
        CanvasExecutionIdentity(
            canvasID: canvasID,
            runID: runID,
            graphRevision: graphRevision,
            nodeID: nodeID,
            nodeRevision: nodeRevision
        )
    }

    private func provider() -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "test-provider",
            modelID: "test-model",
            capabilities: [.image],
            configurationFingerprint: "provider-fingerprint"
        )
    }

    private func projection(graph: NodeGraph = NodeGraph(revision: 7)) throws -> CanvasWorkerProjection {
        try CanvasWorkerProjection(identity: identity(), provider: provider(), graph: graph)
    }

    @Test func acceptReturnsDeterministicReceiptForFrozenProjection() throws {
        let projection = try projection()

        let decision = CanvasWorkerSeam.accept(projection)

        #expect(decision == .accepted(CanvasWorkerRequestReceipt(projection: projection)))
    }

    @Test func writebackPreconditionAcceptsOnlyExactFrozenIdentityAndGraph() throws {
        let projection = try projection()

        let decision = CanvasWorkerSeam.validateWriteback(
            projection: projection,
            actualIdentity: identity(),
            actualGraphRevision: 7,
            actualGraphFingerprint: projection.graphFingerprint
        )

        #expect(decision == .accepted(CanvasWorkerResultWritebackPrecondition(projection: projection)))
    }

    @Test func writebackPreconditionFailsClosedForIdentityMismatch() throws {
        let projection = try projection()
        let differentRun = identity(runID: UUID(uuidString: "00000000-0000-0000-0000-000000000024")!)

        let decision = CanvasWorkerSeam.validateWriteback(
            projection: projection,
            actualIdentity: differentRun,
            actualGraphRevision: 7,
            actualGraphFingerprint: projection.graphFingerprint
        )

        #expect(decision == .rejected(.runMismatch))
    }

    @Test func writebackPreconditionFailsClosedForGraphRevisionMismatch() throws {
        let projection = try projection()

        let decision = CanvasWorkerSeam.validateWriteback(
            projection: projection,
            actualIdentity: identity(graphRevision: 8),
            actualGraphRevision: 8,
            actualGraphFingerprint: projection.graphFingerprint
        )

        #expect(decision == .rejected(.graphRevisionMismatch))
    }

    @Test func writebackPreconditionFailsClosedForGraphFingerprintMismatch() throws {
        let projection = try projection()

        let decision = CanvasWorkerSeam.validateWriteback(
            projection: projection,
            actualIdentity: identity(),
            actualGraphRevision: 7,
            actualGraphFingerprint: "other-graph"
        )

        #expect(decision == .rejected(.graphFingerprintMismatch))
    }

    @Test func acceptsLocalResultAndReturnsReceiptBoundToFrozenProjection() throws {
        let projection = try projection()

        let decision = CanvasWorkerSeam.acceptResult(
            projection: projection,
            resultFingerprint: "local-result-fingerprint",
            actualIdentity: identity(),
            actualGraphRevision: 7,
            actualGraphFingerprint: projection.graphFingerprint
        )

        #expect(decision == .accepted(CanvasWorkerResultReceipt(
            projection: projection,
            resultFingerprint: "local-result-fingerprint"
        )))
    }

    @Test func resultAcceptanceFailsClosedForWritebackIdentityOrGraphDivergence() throws {
        let projection = try projection()

        let identityDecision = CanvasWorkerSeam.acceptResult(
            projection: projection,
            resultFingerprint: "local-result-fingerprint",
            actualIdentity: identity(nodeRevision: 4),
            actualGraphRevision: 7,
            actualGraphFingerprint: projection.graphFingerprint
        )
        let graphDecision = CanvasWorkerSeam.acceptResult(
            projection: projection,
            resultFingerprint: "local-result-fingerprint",
            actualIdentity: identity(),
            actualGraphRevision: 7,
            actualGraphFingerprint: "different-graph"
        )

        #expect(identityDecision == .rejected(.nodeRevisionMismatch))
        #expect(graphDecision == .rejected(.graphFingerprintMismatch))
    }

    @Test func resultAcceptanceRejectsBlankLocalResultFingerprint() throws {
        let projection = try projection()

        let decision = CanvasWorkerSeam.acceptResult(
            projection: projection,
            resultFingerprint: " \n",
            actualIdentity: identity(),
            actualGraphRevision: 7,
            actualGraphFingerprint: projection.graphFingerprint
        )

        #expect(decision == .rejected(.invalidResultFingerprint))
    }
}
