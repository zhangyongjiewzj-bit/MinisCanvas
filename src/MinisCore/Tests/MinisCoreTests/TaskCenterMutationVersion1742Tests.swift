import Foundation
import Testing
@testable import MinisCore

@Suite("Task Center committed ledger version")
struct TaskCenterMutationVersion1742Tests {
    @Test func terminalCommitAdvancesVersionButExactReplayAndInvalidIdentityDoNot() throws {
        let store = AgentTaskStore()
        let initial = store.taskCenterReadVersion()
        let task = try store.enqueue(
            taskID: "version1742-child", parentID: "version1742-parent",
            providerID: "synthetic", modelID: "synthetic"
        )
        let run = try store.startRun(
            taskID: task.taskID, parentID: task.parentID, runID: "version1742-run"
        )
        let beforeSettlement = store.taskCenterReadVersion()
        #expect(beforeSettlement > initial)
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        let envelope = ChildResultEnvelope(
            taskID: task.taskID, runID: run.runID, attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "version1742-execution", outcome: .succeeded,
            outputDigest: "version1742-digest"
        )
        let receipt = try store.settleChildResult(envelope)
        let terminalVersion = store.taskCenterReadVersion()
        #expect(terminalVersion > beforeSettlement)
        #expect(try store.settleChildResult(envelope) == receipt)
        #expect(store.taskCenterReadVersion() == terminalVersion)

        let stale = ChildResultEnvelope(
            taskID: task.taskID, runID: run.runID,
            attemptID: "version1742-foreign-attempt",
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "version1742-execution", outcome: .succeeded,
            outputDigest: "version1742-digest"
        )
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            try store.settleChildResult(stale)
        }
        #expect(store.taskCenterReadVersion() == terminalVersion)
        #expect(store.allReceipts() == [receipt])
    }
}
