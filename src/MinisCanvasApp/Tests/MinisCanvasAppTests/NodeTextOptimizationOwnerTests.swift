import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("Node text optimization owner")
struct NodeTextOptimizationOwnerTests {
    @Test("A late result cannot write a different selected node")
    func switchedNodeRejectsLateResult() {
        let firstNode = UUID()
        let secondNode = UUID()
        let requestID = UUID()
        let owner = NodeTextOptimizationOwner(
            nodeID: firstNode, requestID: requestID, submittedText: "first draft"
        )

        #expect(owner.canApply(
            visibleNodeID: firstNode,
            activeRequestID: requestID,
            currentDraft: "first draft"
        ))
        #expect(!owner.canApply(
            visibleNodeID: secondNode,
            activeRequestID: requestID,
            currentDraft: "first draft"
        ))
        #expect(!owner.canApply(
            visibleNodeID: firstNode,
            activeRequestID: UUID(),
            currentDraft: "first draft"
        ))
        #expect(!owner.canApply(
            visibleNodeID: firstNode,
            activeRequestID: requestID,
            currentDraft: "new manual edit"
        ))
    }
}
