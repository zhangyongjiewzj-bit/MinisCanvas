import Foundation
import Testing
@testable import MinisCore

@Suite("AgentTaskCommandService", .serialized)
struct AgentTaskCommandServiceTests {
    @Test func cancelIsReadOnlyAndExplicitlyNeedsProductionExecutor() throws {
        let store = AgentTaskStore()
        let snapshot = try store.enqueue(
            taskID: "task-cancel",
            parentID: "parent",
            providerID: "provider",
            modelID: "model"
        )
        let service = AgentTaskCommandService(store: store)

        let receipt = try service.submit(request(for: snapshot, key: "cancel-1", command: .cancel))

        #expect(receipt.decision == .needsProductionExecutor)
        #expect(store.snapshot(taskID: snapshot.taskID, parentID: snapshot.parentID) == snapshot)
    }

    @Test func allTypedCommandsAreRepresentedWithoutPretendingToExecute() throws {
        let store = AgentTaskStore()
        let snapshot = try store.enqueue(taskID: "task-commands", parentID: "parent", providerID: nil, modelID: nil)
        let run = try store.startRun(taskID: snapshot.taskID, parentID: snapshot.parentID, runID: "run-commands")
        _ = try store.appendEvent(runID: run.runID, kind: .approvalRequired, detail: "ignored")
        let service = AgentTaskCommandService(store: store)

        let approve = try service.submit(request(for: snapshotAfter(store, snapshot), key: "approve-1", command: .approve, runID: run.runID))
        let reject = try service.submit(request(for: snapshotAfter(store, snapshot), key: "reject-1", command: .reject(reason: "user-declined"), runID: run.runID))

        _ = try store.finish(runID: run.runID, outcome: .failed(reason: "failed"))
        let failed = try #require(store.snapshot(taskID: snapshot.taskID, parentID: snapshot.parentID))
        let retry = try service.submit(request(for: failed, key: "retry-1", command: .retry, runID: run.runID))

        #expect(approve.command == .approve)
        #expect(reject.command == .reject(reason: "user-declined"))
        #expect(retry.command == .retry)
        #expect(approve.decision == .needsProductionExecutor)
        #expect(reject.decision == .needsProductionExecutor)
        #expect(retry.decision == .needsProductionExecutor)
    }

    @Test func provideInputRequiresTypedInputEventAndReturnsExecutorDecision() throws {
        let store = AgentTaskStore()
        let queued = try store.enqueue(taskID: "task-input", parentID: "parent", providerID: nil, modelID: nil)
        let run = try store.startRun(taskID: queued.taskID, parentID: queued.parentID, runID: "run-input")
        _ = try store.appendEvent(runID: run.runID, kind: .inputRequired, detail: "ignored")
        let running = try #require(store.snapshot(taskID: queued.taskID, parentID: queued.parentID))

        let receipt = try AgentTaskCommandService(store: store).submit(
            request(for: running, key: "input-1", command: .provideInput("user answer"), runID: run.runID)
        )

        #expect(receipt.decision == .needsProductionExecutor)
        #expect(store.snapshot(taskID: queued.taskID, parentID: queued.parentID)?.status == .running)
    }

    @Test func sameRequestIsIdempotentAndDifferentPayloadConflicts() throws {
        let store = AgentTaskStore()
        let snapshot = try store.enqueue(taskID: "task-idempotent", parentID: "parent", providerID: nil, modelID: nil)
        let service = AgentTaskCommandService(store: store)
        let firstRequest = request(for: snapshot, key: "same-key", command: .cancel)

        let first = try service.submit(firstRequest)
        let replay = try service.submit(firstRequest)
        #expect(replay == first)

        #expect(throws: AgentTaskCommandServiceError.idempotencyKeyConflict) {
            _ = try service.submit(request(for: snapshot, key: "same-key", command: .retry))
        }
    }

    @Test func staleOrMismatchedIdentityFailsClosedBeforeDecision() throws {
        let store = AgentTaskStore()
        let queued = try store.enqueue(taskID: "task-stale", parentID: "parent", providerID: nil, modelID: nil)
        let service = AgentTaskCommandService(store: store)
        let staleRequest = request(for: queued, key: "stale-1", command: .cancel)
        _ = try store.startRun(taskID: queued.taskID, parentID: queued.parentID, runID: "run-stale")

        #expect(throws: AgentTaskCommandServiceError.snapshotIdentityMismatch) {
            _ = try service.submit(staleRequest)
        }

        let wrongParentRequest = AgentTaskCommandRequest(
            taskID: queued.taskID,
            parentID: "other-parent",
            expectedSnapshotIdentity: AgentTaskSnapshotIdentity(snapshot: queued),
            idempotencyKey: "wrong-parent",
            command: .cancel
        )
        #expect(throws: AgentTaskCommandServiceError.invalidRequest(.expectedIdentityDoesNotMatchRequest)) {
            _ = try service.submit(wrongParentRequest)
        }
    }

    @Test func recoverOfRecoveredRunningTaskNeedsUserReviewAndNeverRedispatches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskCommandService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = try AgentTaskStore(persistenceURL: persistenceURL)
        let queued = try firstStore.enqueue(taskID: "task-recover", parentID: "parent", providerID: nil, modelID: nil)
        _ = try firstStore.startRun(taskID: queued.taskID, parentID: queued.parentID, runID: "run-recover")

        let recoveredStore = try AgentTaskStore(persistenceURL: persistenceURL)
        let running = try #require(recoveredStore.snapshot(taskID: queued.taskID, parentID: queued.parentID))
        let receipt = try AgentTaskCommandService(store: recoveredStore).submit(
            request(for: running, key: "recover-1", command: .recover, runID: "run-recover")
        )

        #expect(receipt.decision == .needsUserReview(reason: .recoveredRunningTask))
        #expect(recoveredStore.snapshot(taskID: queued.taskID, parentID: queued.parentID)?.status == .running)
        #expect(recoveredStore.attempts(runID: "run-recover").count == 1)
    }

    @Test func unknownExternalSubmissionNeedsReviewForCancelAndRetry() throws {
        let store = AgentTaskStore()
        let queued = try store.enqueue(taskID: "task-unknown", parentID: "parent", providerID: nil, modelID: nil)
        let run = try store.startRun(taskID: queued.taskID, parentID: queued.parentID, runID: "run-unknown")
        try store.markExternalSubmissionUnknown(runID: run.runID)
        let running = try #require(store.snapshot(taskID: queued.taskID, parentID: queued.parentID))
        let service = AgentTaskCommandService(store: store)

        let cancel = try service.submit(request(for: running, key: "cancel-unknown", command: .cancel, runID: run.runID))
        #expect(cancel.decision == .needsUserReview(reason: .externalSubmissionUnknown))

        _ = try store.finish(runID: run.runID, outcome: .failed(reason: "failed"))
        let failed = try #require(store.snapshot(taskID: queued.taskID, parentID: queued.parentID))
        let retry = try service.submit(request(for: failed, key: "retry-unknown", command: .retry, runID: run.runID))
        #expect(retry.decision == .needsUserReview(reason: .externalSubmissionUnknown))
    }

    @Test func invalidInputsAndMissingLifecycleEvidenceFailClosed() throws {
        let store = AgentTaskStore()
        let snapshot = try store.enqueue(taskID: "task-invalid", parentID: "parent", providerID: nil, modelID: nil)
        let service = AgentTaskCommandService(store: store)

        #expect(throws: AgentTaskCommandServiceError.invalidRequest(.blankInput)) {
            _ = try service.submit(request(for: snapshot, key: "empty-input", command: .provideInput(" ")))
        }
        #expect(throws: AgentTaskCommandServiceError.missingRunID) {
            _ = try service.submit(request(for: snapshot, key: "approve-without-run", command: .approve))
        }
        #expect(throws: AgentTaskCommandServiceError.commandNotApplicable(.retry, .queued)) {
            _ = try service.submit(request(for: snapshot, key: "retry-queued", command: .retry))
        }
    }

    @Test func runningCancelRequiresKnownRunOwnedByTheTask() throws {
        let store = AgentTaskStore()
        let queued = try store.enqueue(
            taskID: "task-run-identity",
            parentID: "parent",
            providerID: nil,
            modelID: nil
        )
        _ = try store.startRun(
            taskID: queued.taskID,
            parentID: queued.parentID,
            runID: "run-owned"
        )
        let running = try #require(store.snapshot(taskID: queued.taskID, parentID: queued.parentID))
        let service = AgentTaskCommandService(store: store)

        #expect(throws: AgentTaskCommandServiceError.missingRunID) {
            _ = try service.submit(request(for: running, key: "cancel-missing-run", command: .cancel))
        }
        #expect(throws: AgentTaskCommandServiceError.unknownRun) {
            _ = try service.submit(
                request(for: running, key: "cancel-unknown-run", command: .cancel, runID: "run-missing")
            )
        }

        let other = try store.enqueue(
            taskID: "task-other",
            parentID: "parent",
            providerID: nil,
            modelID: nil
        )
        _ = try store.startRun(
            taskID: other.taskID,
            parentID: other.parentID,
            runID: "run-other"
        )
        #expect(throws: AgentTaskCommandServiceError.unknownRun) {
            _ = try service.submit(
                request(for: running, key: "cancel-wrong-owner", command: .cancel, runID: "run-other")
            )
        }
    }

    @Test func retryWithUnknownExplicitRunFailsClosedBeforeReviewDecision() throws {
        let store = AgentTaskStore()
        let queued = try store.enqueue(
            taskID: "task-retry-identity",
            parentID: "parent",
            providerID: nil,
            modelID: nil
        )
        let run = try store.startRun(
            taskID: queued.taskID,
            parentID: queued.parentID,
            runID: "run-retry"
        )
        _ = try store.finish(runID: run.runID, outcome: .failed(reason: "failed"))
        let failed = try #require(store.snapshot(taskID: queued.taskID, parentID: queued.parentID))

        #expect(throws: AgentTaskCommandServiceError.unknownRun) {
            _ = try AgentTaskCommandService(store: store).submit(
                request(for: failed, key: "retry-unknown-run", command: .retry, runID: "run-missing")
            )
        }
    }

    private func request(
        for snapshot: AgentTaskSnapshot,
        key: String,
        command: AgentTaskCommand,
        runID: String? = nil
    ) -> AgentTaskCommandRequest {
        AgentTaskCommandRequest(
            taskID: snapshot.taskID,
            parentID: snapshot.parentID,
            expectedSnapshotIdentity: AgentTaskSnapshotIdentity(snapshot: snapshot),
            idempotencyKey: key,
            command: command,
            runID: runID
        )
    }

    private func snapshotAfter(_ store: AgentTaskStore, _ snapshot: AgentTaskSnapshot) -> AgentTaskSnapshot {
        store.snapshot(taskID: snapshot.taskID, parentID: snapshot.parentID) ?? snapshot
    }
}
