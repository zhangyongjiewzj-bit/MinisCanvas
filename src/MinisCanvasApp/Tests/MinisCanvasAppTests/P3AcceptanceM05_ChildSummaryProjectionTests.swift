import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3 D-AGENT-08 child summary from canonical receipts")
struct P3AcceptanceM05_ChildSummaryProjectionTests {
    @Test("one parent receives live child counts, states, and honest event progress")
    func childSummaryReprojectsCanonicalTaskChanges() throws {
        let store = AgentTaskStore()
        let parentID = "active-agent"
        let queued = try enqueue("queued-child", parentID: parentID, store: store)
        let running = try enqueue("running-child", parentID: parentID, store: store)
        let approval = try enqueue("approval-child", parentID: parentID, store: store)
        let failed = try enqueue("failed-child", parentID: parentID, store: store)
        let completed = try enqueue("completed-child", parentID: parentID, store: store)
        _ = try enqueue("foreign-child", parentID: "other-agent", store: store)

        let consumer = TaskCenterControlConsumer(store: store)
        let initial = TaskSummaryChildProjection(
            currentTaskID: parentID,
            receiptRows: consumer.receiptRows()
        )
        #expect(initial.rows.count == 5)
        #expect(initial.runningCount == 0)
        #expect(initial.otherCount == 5)
        #expect(TaskSummaryChildProjection(
            currentTaskID: nil,
            receiptRows: consumer.receiptRows()
        ).rows.isEmpty)

        let runningRun = try store.startRun(
            taskID: running.taskID,
            parentID: running.parentID,
            runID: "running-child-run"
        )
        _ = try store.appendEvent(
            runID: runningRun.runID,
            kind: .progress,
            detail: "current step"
        )
        let approvalRun = try store.startRun(
            taskID: approval.taskID,
            parentID: approval.parentID,
            runID: "approval-child-run"
        )
        _ = try store.appendEvent(
            runID: approvalRun.runID,
            kind: .approvalRequired,
            detail: "waiting for approval"
        )
        let failedRun = try store.startRun(
            taskID: failed.taskID,
            parentID: failed.parentID,
            runID: "failed-child-run"
        )
        _ = try store.finish(runID: failedRun.runID, outcome: .failed(reason: "execution-failed"))
        let completedRun = try store.startRun(
            taskID: completed.taskID,
            parentID: completed.parentID,
            runID: "completed-child-run"
        )
        _ = try store.finish(runID: completedRun.runID, outcome: .succeeded)

        let current = TaskSummaryChildProjection(
            currentTaskID: parentID,
            receiptRows: consumer.receiptRows()
        )
        #expect(current.rows.count == 5)
        #expect(current.runningCount == 1)
        #expect(current.approvalCount == 1)
        #expect(current.failedCount == 1)
        #expect(current.completedCount == 1)
        #expect(current.otherCount == 1)
        #expect(current.staleCount == 0)
        #expect(current.summaryTitle.contains("子智能体 5 个"))
        #expect(current.summaryTitle.contains("待审批 1"))

        let runningRow = try #require(current.rows.first { $0.taskID == running.taskID })
        let approvalRow = try #require(current.rows.first { $0.taskID == approval.taskID })
        let queuedRow = try #require(current.rows.first { $0.taskID == queued.taskID })
        #expect(runningRow.lastEventKind == .progress)
        #expect(current.progressTitle(for: runningRow).contains("事件"))
        #expect(approvalRow.lifecycleState == .approvalRequired)
        #expect(current.progressTitle(for: approvalRow).contains("等待审批"))
        #expect(current.progressTitle(for: queuedRow) == "进度未知")
        #expect(!current.rows.contains { $0.taskID == "foreign-child" })
    }

    private func enqueue(
        _ taskID: String,
        parentID: String,
        store: AgentTaskStore
    ) throws -> AgentTaskSnapshot {
        try store.enqueue(
            taskID: taskID,
            parentID: parentID,
            providerID: "offline",
            modelID: "test"
        )
    }
}
