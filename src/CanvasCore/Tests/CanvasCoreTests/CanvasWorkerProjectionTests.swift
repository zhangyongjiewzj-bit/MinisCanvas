import Foundation
import Testing
@testable import CanvasCore

struct CanvasWorkerProjectionTests {
    private func identity() -> CanvasExecutionIdentity {
        CanvasExecutionIdentity(
            canvasID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            graphRevision: 7,
            nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            nodeRevision: 3
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

    @Test func projectionFreezesIdentityProviderAndGraphPreconditions() throws {
        let graph = NodeGraph(revision: 7)
        let projection = try CanvasWorkerProjection(
            identity: identity(),
            provider: provider(),
            graph: graph
        )

        #expect(projection.identity == identity())
        #expect(projection.provider == provider())
        #expect(projection.graphRevision == 7)
        #expect(projection.graphFingerprint == graph.fingerprint)
    }

    @Test func projectionRejectsIdentityWhoseRevisionDiffersFromGraph() {
        #expect(throws: CanvasWorkerProjectionError.graphRevisionMismatch(expected: 7, actual: 8)) {
            try CanvasWorkerProjection(
                identity: identity(),
                provider: provider(),
                graph: NodeGraph(revision: 8)
            )
        }
    }

    @Test func projectionRejectsInvalidProviderWithoutInvokingAnything() {
        let invalidProvider = ProviderSnapshot(
            providerID: " ",
            modelID: "test-model",
            capabilities: [],
            configurationFingerprint: "provider-fingerprint"
        )

        #expect(throws: CanvasWorkerProjectionError.invalidProvider) {
            try CanvasWorkerProjection(
                identity: identity(),
                provider: invalidProvider,
                graph: NodeGraph(revision: 7)
            )
        }
    }

    @Test func projectionRoundTripsAsStablePureDTO() throws {
        let graph = NodeGraph(revision: 7)
        let projection = try CanvasWorkerProjection(identity: identity(), provider: provider(), graph: graph)

        let decoded = try JSONDecoder().decode(
            CanvasWorkerProjection.self,
            from: JSONEncoder().encode(projection)
        )

        #expect(decoded == projection)
    }
}
