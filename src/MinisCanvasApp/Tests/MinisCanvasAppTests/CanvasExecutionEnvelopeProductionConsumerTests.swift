import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

@Suite("Canvas execution envelope production consumer")
struct CanvasExecutionEnvelopeProductionConsumerTests {
    @Test("production scope begin publishes the frozen run envelope")
    func productionScopeBeginPublishesFrozenRunEnvelope() {
        let scope = CanvasExecutionScopeBox()
        let canvasID = UUID()
        let runID = UUID()
        let graphRevision = 12
        let graphFingerprint = "production-frozen-graph"

        scope.begin(
            canvasID: canvasID,
            runID: runID,
            graphRevision: graphRevision,
            graphFingerprint: graphFingerprint
        )

        #expect(
            scope.executionEnvelope() == DAGExecutionEnvelope(
                canvasID: canvasID,
                runID: runID,
                graphRevision: graphRevision,
                graphFingerprint: graphFingerprint
            )
        )
    }
}
