import Foundation
import Testing
@testable import MinisCore

/// Pins the behavior of the unified async terminal rules through the real
/// production entry points: the supervised attempt actor and the durable
/// task/run settlement store. These tests deliberately exercise
/// `ChildSupervisor` and `AgentTaskStore` APIs rather than calling
/// `AsyncTerminalStateRules` as isolated pure functions.
@Suite("Async terminal state rules production enforcement")
struct AsyncTerminalStateRulesTests {

    // MARK: - Attempt domain

    @Test("terminal success freezes the supervised attempt against late writebacks")
    func terminalSuccessRejectsLateWritebacks() async throws {
        let supervisor = ChildSupervisor(childID: "async243-child")
        let started = try await supervisor.start()
        _ = try await supervisor.heartbeat(attemptID: started.attemptID, sequence: 7)
        #expect(try await supervisor.settleSuccess(attemptID: started.attemptID, sequence: 9))

        #expect(try await supervisor.acceptWriteback(attemptID: started.attemptID, sequence: 40) == false)
        #expect(try await supervisor.settleSuccess(attemptID: started.attemptID, sequence: 41) == false)
        let lateEnvelope = ChildResultEnvelope(
            taskID: "async243-child",
            runID: "async243-run",
            attemptID: started.attemptID,
            parentContextSnapshotID: nil,
            childExecutionID: "async243-exec",
            outcome: .succeeded,
            resultDigest: "sha256:async243-late-success"
        )
        #expect(try await supervisor.acceptResultEnvelope(lateEnvelope) == false)

        // A live signal after terminal fails closed through the same freeze.
        await #expect(throws: ChildSupervisorError.staleSequence) {
            try await supervisor.heartbeat(attemptID: started.attemptID, sequence: 42)
        }
        await #expect(throws: ChildSupervisorError.invalidLifecycle) {
            try await supervisor.cancel(attemptID: started.attemptID)
        }

        let frozen = try #require(await supervisor.snapshot())
        #expect(frozen.status == .succeeded)
        #expect(frozen.sequence == 9)
        // A succeeded decision is final: the lease stays released and restart
        // cannot reopen it.
        await #expect(throws: ChildSupervisorError.invalidLifecycle) {
            try await supervisor.restart()
        }
    }

    @Test("cancellation is sticky in the supervised attempt domain")
    func cancellationIsStickyInSupervisor() async throws {
        let supervisor = ChildSupervisor(childID: "async243-cancel")
        let started = try await supervisor.start()
        #expect(try await supervisor.cancelIfRunning(attemptID: started.attemptID))

        let lateEnvelope = ChildResultEnvelope(
            taskID: "async243-cancel",
            runID: "async243-cancel-run",
            attemptID: started.attemptID,
            parentContextSnapshotID: nil,
            childExecutionID: "async243-cancel-exec",
            outcome: .succeeded,
            resultDigest: "sha256:async243-cancel-late"
        )
        #expect(try await supervisor.acceptResultEnvelope(lateEnvelope) == false)
        #expect(try await supervisor.acceptWriteback(attemptID: started.attemptID, sequence: 3) == false)
        #expect(try await supervisor.settleSuccess(attemptID: started.attemptID, sequence: 4) == false)

        let cancelled = try #require(await supervisor.snapshot())
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.sequence == 0)

        // Restart is legal only because cancellation (not success) won; the
        // previous attempt's identity keeps being rejected afterwards.
        let restarted = try await supervisor.restart()
        #expect(restarted.attemptNumber == 2)
        #expect(try await supervisor.acceptWriteback(attemptID: started.attemptID, sequence: 5) == false)
        await #expect(throws: ChildSupervisorError.staleAttempt) {
            try await supervisor.heartbeat(attemptID: started.attemptID, sequence: 6)
        }
        let current = try #require(await supervisor.snapshot())
        #expect(current.attemptID == restarted.attemptID)
        #expect(current.status == .running)
    }

    @Test("envelope outcome decides the supervised status through the unified mapping")
    func envelopeOutcomeDecidesSupervisedStatus() async throws {
        let supervisor = ChildSupervisor(childID: "async243-envelope")
        let started = try await supervisor.start()
        let envelope = ChildResultEnvelope(
            taskID: "async243-envelope",
            runID: "async243-envelope-run",
            attemptID: started.attemptID,
            parentContextSnapshotID: nil,
            childExecutionID: "async243-envelope-exec",
            outcome: .failed(reason: "synthetic-provider-failure"),
            resultDigest: "sha256:async243-envelope-failed"
        )
        #expect(try await supervisor.acceptResultEnvelope(envelope))
        let settled = try #require(await supervisor.snapshot())
        #expect(settled.status == .failed)
        #expect(settled.sequence == envelope.sequence)
        // Exact replay remains idempotent even though the attempt is frozen.
        #expect(try await supervisor.acceptResultEnvelope(envelope))
        // A different envelope cannot rewrite the decided terminal fact.
        let drifted = ChildResultEnvelope(
            taskID: "async243-envelope",
            runID: envelope.runID,
            attemptID: started.attemptID,
            parentContextSnapshotID: nil,
            childExecutionID: "async243-envelope-exec",
            outcome: .succeeded,
            resultDigest: "sha256:async243-envelope-drift"
        )
        #expect(try await supervisor.acceptResultEnvelope(drifted) == false)
        let stillFailed = try #require(await supervisor.snapshot())
        #expect(stillFailed.status == .failed)
    }

    // MARK: - Durable settlement domain

    @Test("durable settlement freezes the run and routes late writes through the unified rules")
    func durableSettlementFreezesRun() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "async243-store-task",
            parentID: "async243-store-parent",
            providerID: "provider",
            modelID: "model",
            parentContextSnapshotID: "async243-store-snapshot"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "async243-store-run"
        )
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))

        // Terminal event kinds never enter through the ordinary event path.
        #expect(throws: AgentTaskStoreError.terminalEventRequiresSettlement) {
            try store.appendEvent(runID: run.runID, kind: .completed, detail: "late")
        }

        let envelope = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "async243-store-exec",
            outcome: .succeeded,
            resultDigest: "sha256:async243-store-success"
        )
        let receipt = try store.settleChildResult(envelope)

        // Exact replay returns the stored receipt unchanged (no second write).
        #expect(try store.settleChildResult(envelope) == receipt)

        // Divergent payload after terminal fails closed as a conflict.
        let divergent = ChildResultEnvelope(
            taskID: envelope.taskID,
            runID: envelope.runID,
            attemptID: envelope.attemptID,
            parentContextSnapshotID: envelope.parentContextSnapshotID,
            childExecutionID: envelope.childExecutionID,
            outcome: .failed(reason: "async243-store-drift"),
            resultDigest: "sha256:async243-store-drift"
        )
        #expect(throws: AgentTaskStoreError.childResultIdempotencyConflict) {
            try store.settleChildResult(divergent)
        }

        // Once terminal, the run admits no further events at all.
        #expect(throws: AgentTaskStoreError.runClosed) {
            try store.appendEvent(runID: run.runID, kind: .progress, detail: "late")
        }
        #expect(store.receipt(runID: run.runID) == receipt)
        #expect(store.allReceipts() == [receipt])
        #expect(store.taskSnapshot(runID: run.runID)?.status == .succeeded)
    }

    @Test("cancellation stays sticky against later child result envelopes")
    func cancelledSettlementStaysSticky() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "async243-sticky-task",
            parentID: "async243-sticky-parent",
            providerID: "provider",
            modelID: "model"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "async243-sticky-run"
        )
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        _ = try store.finish(runID: run.runID, outcome: .cancelled)

        let lateSuccess = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "async243-sticky-exec",
            outcome: .succeeded,
            resultDigest: "sha256:async243-sticky-late"
        )
        #expect(throws: AgentTaskStoreError.childResultCancelled) {
            try store.settleChildResult(lateSuccess)
        }
        let lateCancellation = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "async243-sticky-exec",
            outcome: .cancelled,
            resultDigest: "sha256:async243-sticky-cancel"
        )
        #expect(throws: AgentTaskStoreError.childResultCancelled) {
            try store.settleChildResult(lateCancellation)
        }
        #expect(store.receipt(runID: run.runID)?.outcome == .cancelled)
        #expect(store.taskSnapshot(runID: run.runID)?.status == .cancelled)
    }

    @Test("both domains freeze on the same terminal fact for one child execution")
    func supervisorAndStoreFreezeConsistently() async throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "async243-cross-task",
            parentID: "async243-cross-parent",
            providerID: "provider",
            modelID: "model"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "async243-cross-run"
        )
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        let supervisor = ChildSupervisor(childID: task.taskID, attemptID: attemptID)
        let started = try await supervisor.start()
        #expect(started.attemptID == attemptID)

        let envelope = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "async243-cross-exec",
            outcome: .succeeded,
            resultDigest: "sha256:async243-cross-success"
        )
        #expect(try await supervisor.acceptResultEnvelope(envelope))
        let receipt = try store.settleChildResult(envelope)

        // Late duplicates stay rejected in both domains after the freeze.
        #expect(try await supervisor.acceptResultEnvelope(envelope))
        #expect(try store.settleChildResult(envelope) == receipt)
        let lateOtherOutcome = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "async243-cross-exec",
            outcome: .cancelled,
            resultDigest: "sha256:async243-cross-late-cancel"
        )
        #expect(try await supervisor.acceptResultEnvelope(lateOtherOutcome) == false)
        #expect(throws: AgentTaskStoreError.childResultIdempotencyConflict) {
            try store.settleChildResult(lateOtherOutcome)
        }
        let supervisorFact = try #require(await supervisor.snapshot())
        #expect(supervisorFact.status == .succeeded)
        #expect(store.receipt(runID: run.runID) == receipt)
    }
}
