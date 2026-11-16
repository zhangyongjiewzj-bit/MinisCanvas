import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center filter and archive consumer")
struct TaskCenterFilterArchiveConsumerTests {
    @Test func filtersByLifecycleAndCanonicalSourceSession() throws {
        let store = AgentTaskStore()
        let completed = try makeTask(
            store: store,
            taskID: "completed-task",
            parentID: "parent-completed",
            sourceSessionID: "source-a"
        )
        let completedRun = try store.startRun(
            taskID: completed.taskID,
            parentID: completed.parentID,
            runID: "completed-run"
        )
        _ = try store.finish(runID: completedRun.runID, outcome: .succeeded)

        let failed = try makeTask(
            store: store,
            taskID: "failed-task",
            parentID: "parent-failed",
            sourceSessionID: "source-b"
        )
        let failedRun = try store.startRun(
            taskID: failed.taskID,
            parentID: failed.parentID,
            runID: "failed-run"
        )
        _ = try store.finish(runID: failedRun.runID, outcome: .failed(reason: "redacted"))

        let running = try makeTask(
            store: store,
            taskID: "running-task",
            parentID: "parent-running",
            sourceSessionID: "source-a"
        )
        _ = try store.startRun(
            taskID: running.taskID,
            parentID: running.parentID,
            runID: "running-run"
        )

        let waiting = try makeTask(
            store: store,
            taskID: "waiting-task",
            parentID: "parent-waiting",
            sourceSessionID: "source-b"
        )
        let waitingRun = try store.startRun(
            taskID: waiting.taskID,
            parentID: waiting.parentID,
            runID: "waiting-run"
        )
        _ = try store.appendEvent(runID: waitingRun.runID, kind: .approvalRequired, detail: "approval")

        let consumer = TaskCenterControlConsumer(store: store)
        #expect(
            consumer.filteredReceiptRows(
                TaskCenterReceiptFilter(status: .inProgress, sourceSessionID: "source-a")
            ).map(\.taskID) == [running.taskID]
        )
        #expect(
            consumer.filteredReceiptRows(
                TaskCenterReceiptFilter(status: .waitingApproval, sourceSessionID: "source-b")
            ).map(\.taskID) == [waiting.taskID]
        )
        #expect(
            consumer.filteredReceiptRows(
                TaskCenterReceiptFilter(status: .failed, sourceSessionID: "source-b")
            ).map(\.taskID) == [failed.taskID]
        )
        #expect(
            consumer.filteredReceiptRows(
                TaskCenterReceiptFilter(status: .completed, sourceSessionID: "source-a")
            ).map(\.taskID) == [completed.taskID]
        )
        #expect(
            consumer.filteredReceiptRows(
                TaskCenterReceiptFilter(status: .completed, sourceSessionID: "parent-completed")
            ).isEmpty
        )
    }

    @Test func completedArchiveIsHiddenByDefaultAndRestorableWithoutRedispatch() throws {
        let store = AgentTaskStore()
        let task = try makeTask(
            store: store,
            taskID: "archive-task",
            parentID: "archive-parent",
            sourceSessionID: "archive-source"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "archive-run"
        )
        _ = try store.finish(runID: run.runID, outcome: .succeeded)

        let consumer = TaskCenterControlConsumer(store: store)
        let before = try #require(consumer.receiptRows().first)
        #expect(before.archiveAvailable)
        #expect(before.restoreAvailable == false)

        _ = try consumer.applyArchive(
            TaskCenterArchiveRequest(
                taskID: task.taskID,
                parentID: task.parentID,
                actorID: "consumer-test",
                idempotencyKey: "consumer-archive",
                action: .archive
            )
        )
        #expect(consumer.receiptRows().isEmpty)
        let archived = try #require(
            consumer.filteredReceiptRows(
                TaskCenterReceiptFilter(
                    status: .completed,
                    sourceSessionID: "archive-source",
                    includeArchived: true
                )
            ).first
        )
        #expect(archived.isArchived)
        #expect(archived.restoreAvailable)
        #expect(store.snapshot(taskID: task.taskID, parentID: task.parentID)?.status == .succeeded)
        #expect(store.canonicalAttemptID(runID: run.runID) == "archive-run:attempt:1")

        _ = try consumer.applyArchive(
            TaskCenterArchiveRequest(
                taskID: task.taskID,
                parentID: task.parentID,
                actorID: "consumer-test",
                idempotencyKey: "consumer-restore",
                action: .restore
            )
        )
        let restored = try #require(consumer.receiptRows().first)
        #expect(restored.isArchived == false)
        #expect(restored.archiveAvailable)
        #expect(store.snapshot(taskID: task.taskID, parentID: task.parentID)?.status == .succeeded)
    }

    private func makeTask(
        store: AgentTaskStore,
        taskID: String,
        parentID: String,
        sourceSessionID: String
    ) throws -> AgentTaskSnapshot {
        let source = ParentRuntimeIdentity(
            sessionID: sourceSessionID,
            conversationID: "conversation-\(sourceSessionID)",
            turnID: "turn-\(sourceSessionID)",
            taskID: parentID,
            actorID: "actor-\(sourceSessionID)"
        )
        let creation = SessionActionCreationMetadata(
            scopeID: "scope-\(sourceSessionID)",
            idempotencyKey: "creation-\(taskID)",
            action: .new(
                title: "Task \(taskID)",
                projectID: "project-\(sourceSessionID)",
                source: source
            )
        )
        return try store.enqueueIdempotent(
            taskID: taskID,
            parentID: parentID,
            providerID: "offline",
            modelID: "test",
            creation: creation
        ).snapshot
    }
}
