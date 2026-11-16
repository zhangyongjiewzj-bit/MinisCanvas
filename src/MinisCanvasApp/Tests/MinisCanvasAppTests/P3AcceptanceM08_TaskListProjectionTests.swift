import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-TASK-11 Task Center main-list projection")
struct P3AcceptanceM08_TaskListProjectionTests {
    @Test("session-action control history stays in diagnostics, outside the user task list")
    func sessionActionControlDoesNotBecomeUserTask() throws {
        let store = AgentTaskStore()
        let sourceSessionID = "synthetic-source-session"
        // BridgeStore.performSessionAction records new/switch/rename/fork with
        // this exact task identity and configuration fingerprint.
        let control = try store.enqueue(
            taskID: "session-action:synthetic-control",
            parentID: sourceSessionID,
            providerID: nil,
            modelID: nil,
            configurationFingerprint: "session-action-v1",
            parentContextSnapshotID: "synthetic-source-turn"
        )
        let controlRun = try store.startRun(
            taskID: control.taskID,
            parentID: control.parentID,
            runID: "session-action-run:synthetic-control"
        )
        _ = try store.appendEvent(
            runID: controlRun.runID, kind: .started, detail: "session-action"
        )
        _ = try store.finish(runID: controlRun.runID, outcome: .succeeded)

        let userTask = try store.enqueue(
            taskID: "synthetic-agent-task",
            parentID: sourceSessionID,
            providerID: "offline",
            modelID: "synthetic"
        )
        // The task-ID spelling alone is not provenance. A normal child with
        // the same prefix but no session-action fingerprint remains visible.
        let ordinaryPrefixTask = try store.enqueue(
            taskID: "session-action:ordinary-child",
            parentID: sourceSessionID,
            providerID: "offline",
            modelID: "synthetic",
            configurationFingerprint: "ordinary-child"
        )
        let approvalTask = try store.enqueue(
            taskID: "synthetic-approval-task",
            parentID: sourceSessionID,
            providerID: "offline",
            modelID: "synthetic"
        )
        let approvalRun = try store.startRun(
            taskID: approvalTask.taskID,
            parentID: approvalTask.parentID,
            runID: "synthetic-approval-run"
        )
        _ = try store.appendEvent(
            runID: approvalRun.runID, kind: .approvalRequired, detail: "synthetic approval"
        )
        let now = Date(timeIntervalSince1970: 1_850_000_000)
        let consumer = TaskCenterControlConsumer(store: store)

        // The control event remains inspectable in the canonical ledger.
        #expect(store.snapshot(taskID: control.taskID, parentID: control.parentID)?.status == .succeeded)
        #expect(store.events(runID: controlRun.runID).contains { $0.kind == .started })

        // Both unfiltered and completed-filter projections feed the visible
        // Task Center list. Neither may promote session plumbing to a user task.
        #expect(Set(consumer.receiptRows(now: now).map(\.taskID)) == Set([
            userTask.taskID, ordinaryPrefixTask.taskID, approvalTask.taskID
        ]))
        #expect(consumer.filteredReceiptRows(
            TaskCenterReceiptFilter(status: .waitingApproval), now: now
        ).map(\.taskID) == [approvalTask.taskID])
        #expect(consumer.filteredReceiptRows(
            TaskCenterReceiptFilter(status: .completed), now: now
        ).allSatisfy { $0.taskID != control.taskID })
    }
}
