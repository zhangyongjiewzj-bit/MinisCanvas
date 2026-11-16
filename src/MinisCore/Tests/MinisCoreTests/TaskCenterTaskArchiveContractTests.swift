import Foundation
import Testing
@testable import MinisCore

@Suite("Task Center task archive contract")
struct TaskCenterTaskArchiveContractTests {
    @Test func onlyCanonicalSucceededReceiptCanArchiveAndRestore() throws {
        let store = AgentTaskStore()
        let source = ParentRuntimeIdentity(
            sessionID: "source-session-a",
            conversationID: "conversation-a",
            turnID: "turn-a",
            taskID: "parent-a",
            actorID: "actor-a"
        )
        let creation = SessionActionCreationMetadata(
            scopeID: "scope-a",
            idempotencyKey: "creation-a",
            action: .new(title: "created session", source: source)
        )
        let task = try store.enqueueIdempotent(
            taskID: "task-a",
            parentID: "parent-a",
            providerID: "offline",
            modelID: "test",
            creation: creation
        ).snapshot
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "run-a"
        )
        _ = try store.finish(runID: run.runID, outcome: .succeeded)

        let completed = try #require(store.snapshot(taskID: task.taskID, parentID: task.parentID))
        let event = try #require(store.events(runID: run.runID).last)
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        let request = AgentTaskArchiveRequest(
            taskID: task.taskID,
            parentID: task.parentID,
            expectedSnapshotIdentity: AgentTaskSnapshotIdentity(snapshot: completed),
            runID: run.runID,
            attemptID: attemptID,
            eventSequence: event.sequence,
            sourceSessionID: source.sessionID,
            actorID: "task-center-test",
            idempotencyKey: "archive-a",
            action: .archive
        )

        let archived = try store.applyArchive(request, now: Date(timeIntervalSince1970: 1_850_000_001))
        #expect(archived.didChange)
        #expect(store.taskCenterSnapshots(includeArchived: false).isEmpty)
        #expect(store.taskArchive(taskID: task.taskID, parentID: task.parentID)?.runID == run.runID)

        let replay = try store.applyArchive(request, now: Date(timeIntervalSince1970: 1_850_000_999))
        #expect(!replay.didChange)
        #expect(replay.archive == archived.archive)

        let restore = AgentTaskArchiveRequest(
            taskID: task.taskID,
            parentID: task.parentID,
            expectedSnapshotIdentity: AgentTaskSnapshotIdentity(
                snapshot: try #require(store.snapshot(taskID: task.taskID, parentID: task.parentID))
            ),
            runID: run.runID,
            attemptID: attemptID,
            eventSequence: event.sequence,
            sourceSessionID: source.sessionID,
            actorID: "task-center-test",
            idempotencyKey: "restore-a",
            action: .restore
        )
        #expect(try store.applyArchive(restore).didChange)
        #expect(store.taskCenterSnapshots(includeArchived: false).map(\.taskID) == [task.taskID])
    }

    @Test func runningAndFailedRecordsRejectArchiveWithoutChangingState() throws {
        let store = AgentTaskStore()
        let running = try store.enqueue(
            taskID: "running-task",
            parentID: "parent",
            providerID: "offline",
            modelID: "test"
        )
        let runningRun = try store.startRun(
            taskID: running.taskID,
            parentID: running.parentID,
            runID: "running-run"
        )
        let runningSnapshot = try #require(store.snapshot(taskID: running.taskID, parentID: running.parentID))
        let runningRequest = AgentTaskArchiveRequest(
            taskID: running.taskID,
            parentID: running.parentID,
            expectedSnapshotIdentity: AgentTaskSnapshotIdentity(snapshot: runningSnapshot),
            runID: runningRun.runID,
            attemptID: "running-run:attempt:1",
            eventSequence: 1,
            sourceSessionID: nil,
            actorID: "test",
            idempotencyKey: "archive-running",
            action: .archive
        )
        #expect(throws: AgentTaskStoreError.archiveNotEligible) {
            try store.applyArchive(runningRequest)
        }
        #expect(store.snapshot(taskID: running.taskID, parentID: running.parentID)?.status == .running)

        let failed = try store.enqueue(
            taskID: "failed-task",
            parentID: "parent",
            providerID: "offline",
            modelID: "test"
        )
        let failedRun = try store.startRun(
            taskID: failed.taskID,
            parentID: failed.parentID,
            runID: "failed-run"
        )
        _ = try store.finish(runID: failedRun.runID, outcome: .failed(reason: "redacted"))
        let failedSnapshot = try #require(store.snapshot(taskID: failed.taskID, parentID: failed.parentID))
        let failedEvent = try #require(store.events(runID: failedRun.runID).last)
        let failedRequest = AgentTaskArchiveRequest(
            taskID: failed.taskID,
            parentID: failed.parentID,
            expectedSnapshotIdentity: AgentTaskSnapshotIdentity(snapshot: failedSnapshot),
            runID: failedRun.runID,
            attemptID: "failed-run:attempt:1",
            eventSequence: failedEvent.sequence,
            sourceSessionID: nil,
            actorID: "test",
            idempotencyKey: "archive-failed",
            action: .archive
        )
        #expect(throws: AgentTaskStoreError.archiveNotEligible) {
            try store.applyArchive(failedRequest)
        }
        #expect(store.taskArchive(taskID: failed.taskID, parentID: failed.parentID) == nil)
    }

    @Test func archiveLedgerSurvivesStoreReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-center-archive-\(UUID().uuidString)", isDirectory: true)
        let ledgerURL = directory.appendingPathComponent("tasks.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let taskID = "persisted-task"
        let parentID = "persisted-parent"
        let runID = "persisted-run"
        do {
            let store = try AgentTaskStore(persistenceURL: ledgerURL)
            let task = try store.enqueue(taskID: taskID, parentID: parentID, providerID: "offline", modelID: "test")
            _ = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: runID)
            _ = try store.finish(runID: runID, outcome: .succeeded)
            let completed = try #require(store.snapshot(taskID: taskID, parentID: parentID))
            let event = try #require(store.events(runID: runID).last)
            let request = AgentTaskArchiveRequest(
                taskID: taskID,
                parentID: parentID,
                expectedSnapshotIdentity: AgentTaskSnapshotIdentity(snapshot: completed),
                runID: runID,
                attemptID: "\(runID):attempt:1",
                eventSequence: event.sequence,
                sourceSessionID: nil,
                actorID: "test",
                idempotencyKey: "persisted-archive",
                action: .archive
            )
            _ = try store.applyArchive(request, now: Date(timeIntervalSince1970: 1_850_000_100))
        }

        let reloaded = try AgentTaskStore(persistenceURL: ledgerURL)
        #expect(reloaded.taskCenterSnapshots(includeArchived: false).isEmpty)
        #expect(reloaded.taskCenterSnapshots(includeArchived: true).first?.isArchived == true)
        #expect(reloaded.archiveReceipt(idempotencyKey: "persisted-archive") != nil)
    }
}
