import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center child settlement consistency")
struct TaskCenterSettlementConsistency1742Tests {
    @Test func concurrentSettlementsAndLateCancellationNeverMixResultWithRunningRow() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory
            .appendingPathComponent("task-center-1742-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledger)
        var successes: [ChildResultEnvelope] = []
        for index in 0..<16 {
            let task = try store.enqueue(
                taskID: "child-\(index)", parentID: "parent-1742",
                providerID: "synthetic", modelID: "synthetic"
            )
            let run = try store.startRun(
                taskID: task.taskID, parentID: task.parentID,
                runID: "run-1742-\(index)"
            )
            let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
            successes.append(ChildResultEnvelope(
                taskID: task.taskID, runID: run.runID, attemptID: attemptID,
                parentContextSnapshotID: task.parentContextSnapshotID,
                childExecutionID: "execution-1742-\(index)", outcome: .succeeded,
                outputDigest: "digest-1742-\(index)"
            ))
        }
        let cancelTask = try store.enqueue(
            taskID: "cancel-1742", parentID: "parent-1742",
            providerID: "synthetic", modelID: "synthetic"
        )
        let cancelRun = try store.startRun(
            taskID: cancelTask.taskID, parentID: cancelTask.parentID,
            runID: "cancel-run-1742"
        )
        let cancelAttempt = try #require(store.canonicalAttemptID(runID: cancelRun.runID))
        let lateSuccess = ChildResultEnvelope(
            taskID: cancelTask.taskID, runID: cancelRun.runID,
            attemptID: cancelAttempt,
            parentContextSnapshotID: cancelTask.parentContextSnapshotID,
            childExecutionID: "cancel-execution-1742", outcome: .succeeded,
            outputDigest: "late-digest-1742"
        )
        let consumer = TaskCenterControlConsumer(store: store)
        let admittedSuccesses = successes
        let writer = Task.detached { () async throws -> Bool in
            for envelope in admittedSuccesses {
                _ = try store.settleChildResult(envelope)
                try await Task.sleep(for: .milliseconds(1))
            }
            _ = try store.finish(runID: cancelRun.runID, outcome: .cancelled)
            do {
                _ = try store.settleChildResult(lateSuccess)
                return false
            } catch AgentTaskStoreError.childResultCancelled {
                return true
            }
        }

        for _ in 0..<80 {
            for row in consumer.receiptRows() {
                if let envelope = row.childResultEnvelope {
                    #expect(envelope.outcome == .succeeded)
                    #expect(row.taskState == .completed)
                    #expect(row.lifecycleState == .completed)
                    #expect(row.succeededBacklink != nil)
                }
                if row.taskID == cancelTask.taskID, row.taskState == .cancelled {
                    #expect(row.childResultEnvelope == nil)
                    #expect(row.succeededBacklink == nil)
                }
            }
            await Task.yield()
        }
        #expect(try await writer.value)

        let reopened = try AgentTaskStore(persistenceURL: ledger)
        let rows = TaskCenterControlConsumer(store: reopened).receiptRows()
        #expect(rows.count == 17)
        #expect(rows.filter { $0.taskState == .completed }.count == 16)
        #expect(rows.filter { $0.taskState == .completed }.allSatisfy {
            $0.childResultEnvelope != nil && $0.succeededBacklink != nil
        })
        let cancelled = try #require(rows.first { $0.taskID == cancelTask.taskID })
        #expect(cancelled.taskState == .cancelled)
        #expect(cancelled.childResultEnvelope == nil)
        #expect(cancelled.succeededBacklink == nil)
        #expect(reopened.receipt(runID: cancelRun.runID)?.outcome == .cancelled)
        #expect(throws: AgentTaskStoreError.childResultCancelled) {
            try reopened.settleChildResult(lateSuccess)
        }
        #expect(TaskCenterControlConsumer(store: reopened).receiptRows()
            .first { $0.taskID == cancelTask.taskID } == cancelled)
    }
}
