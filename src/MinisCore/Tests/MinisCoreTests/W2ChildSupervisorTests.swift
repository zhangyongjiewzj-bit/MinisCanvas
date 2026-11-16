import Foundation
import Testing
@testable import MinisCore

@Suite("W2 child supervisor")
struct W2ChildSupervisorTests {
    @Test("heartbeat and progress share one monotonic sequence")
    func heartbeatAndProgressAreOrdered() async throws {
        let supervisor = ChildSupervisor(childID: "child-a")
        let started = try await supervisor.start()

        let heartbeat = try await supervisor.heartbeat(
            attemptID: started.attemptID,
            sequence: 1
        )
        let progress = try await supervisor.progress(
            attemptID: started.attemptID,
            sequence: 2,
            detail: "working"
        )

        #expect(heartbeat.sequence == 1)
        #expect(progress.sequence == 2)
        #expect(progress.status == .running)
        #expect(await supervisor.leaseState() == .active)
        await #expect(throws: ChildSupervisorError.staleSequence) {
            try await supervisor.heartbeat(
                attemptID: started.attemptID,
                sequence: 2
            )
        }
    }

    @Test("pause, fail, and cancel are terminally explicit and release the lease")
    func lifecycleReleasesLease() async throws {
        let paused = ChildSupervisor(childID: "child-paused")
        let pausedAttempt = try await paused.start()
        let pausedSnapshot = try await paused.pause(attemptID: pausedAttempt.attemptID)
        #expect(pausedSnapshot.status == .paused)
        #expect(await paused.leaseState() == .active)

        let failed = ChildSupervisor(childID: "child-failed")
        let failedAttempt = try await failed.start()
        let failedSnapshot = try await failed.fail(attemptID: failedAttempt.attemptID)
        #expect(failedSnapshot.status == .failed)
        #expect(await failed.leaseState() == .released)

        let cancelled = ChildSupervisor(childID: "child-cancelled")
        let cancelledAttempt = try await cancelled.start()
        let cancelledSnapshot = try await cancelled.cancel(attemptID: cancelledAttempt.attemptID)
        #expect(cancelledSnapshot.status == .cancelled)
        #expect(await cancelled.leaseState() == .released)
    }

    @Test("restart creates one new attempt and rejects old late writeback")
    func restartRejectsLateOldAttempt() async throws {
        let supervisor = ChildSupervisor(childID: "child-retry")
        let first = try await supervisor.start()
        _ = try await supervisor.fail(attemptID: first.attemptID)

        let second = try await supervisor.restart()
        #expect(second.attemptID != first.attemptID)
        #expect(second.attemptNumber == 2)
        #expect(second.status == .running)
        #expect(await supervisor.leaseState() == .active)

        #expect(try await supervisor.acceptWriteback(
            attemptID: first.attemptID,
            sequence: 99
        ) == false)
        #expect(try await supervisor.acceptWriteback(
            attemptID: second.attemptID,
            sequence: 1
        ))
        await #expect(throws: ChildSupervisorError.staleAttempt) {
            try await supervisor.releaseLease(attemptID: first.attemptID)
        }
    }

    @Test("a single child cannot restart while its current attempt is active")
    func restartRequiresTerminalAttempt() async throws {
        let supervisor = ChildSupervisor(childID: "child-single")
        _ = try await supervisor.start()

        await #expect(throws: ChildSupervisorError.invalidLifecycle) {
            try await supervisor.restart()
        }
    }

    @Test("result envelopes use the active attempt and sequence fence")
    func resultEnvelopeRejectsStaleWriteback() async throws {
        let supervisor = ChildSupervisor(childID: "child-envelope")
        let started = try await supervisor.start(attemptID: "run:attempt:1")
        let envelope = ChildResultEnvelope(
            taskID: "child-envelope",
            runID: "run",
            attemptID: started.attemptID,
            parentContextSnapshotID: "parent-snapshot",
            childExecutionID: "child-execution",
            outcome: .succeeded,
            resultDigest: "sha256:result",
            evidenceRefs: ["evidence://result"]
        )

        #expect(try await supervisor.acceptResultEnvelope(envelope))
        #expect(await supervisor.snapshot()?.status == .succeeded)
        #expect(await supervisor.leaseState() == .released)
        #expect(try await supervisor.acceptResultEnvelope(envelope))
        let drifted = ChildResultEnvelope(
            taskID: envelope.taskID,
            runID: envelope.runID,
            attemptID: envelope.attemptID,
            sequence: envelope.sequence,
            parentContextSnapshotID: envelope.parentContextSnapshotID,
            childExecutionID: envelope.childExecutionID,
            outcome: .failed(reason: "drift"),
            resultDigest: "sha256:drift",
            evidenceRefs: envelope.evidenceRefs
        )
        #expect(try await supervisor.acceptResultEnvelope(drifted) == false)
        let malformed = ChildResultEnvelope(
            taskID: envelope.taskID,
            runID: envelope.runID,
            attemptID: envelope.attemptID,
            sequence: envelope.sequence,
            parentContextSnapshotID: envelope.parentContextSnapshotID,
            childExecutionID: envelope.childExecutionID,
            outcome: .succeeded,
            resultDigest: "",
            evidenceRefs: []
        )
        #expect(try await supervisor.acceptResultEnvelope(malformed) == false)
    }
}
