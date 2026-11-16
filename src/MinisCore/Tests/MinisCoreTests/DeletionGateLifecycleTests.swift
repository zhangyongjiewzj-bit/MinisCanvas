import Foundation
import Testing
@testable import MinisCore

struct DeletionGateLifecycleTests {
    private let clock = Date(timeIntervalSince1970: 1_000)

    private func intent(ttl: TimeInterval = 30) -> OperationIntent {
        DeletionGate.preview(
            targetID: "session-1",
            targetType: "session",
            targetName: "A session",
            affectedCount: 1,
            impactSummary: "Move to trash",
            scopeID: "session:session-1:active",
            revision: 7,
            fingerprint: DeletionGate.fingerprint("session-v1"),
            now: clock,
            ttl: ttl
        )
        .withFirstConfirmation("I reviewed the exact preview")
        .withSecondConfirmation("I confirm deletion")
    }

    @Test func expiredIntentCannotMutate() throws {
        var mutationCount = 0
        #expect(throws: DeletionGateError.expired) {
            try DeletionGate.execute(
                intent(ttl: 10),
                currentRevision: 7,
                currentFingerprint: DeletionGate.fingerprint("session-v1"),
                now: clock.addingTimeInterval(11)
            ) { _ in mutationCount += 1 }
        }
        #expect(mutationCount == 0)
    }

    @Test func cancelledIntentCannotMutate() throws {
        let deletion = intent()
        var mutationCount = 0
        try DeletionGate.cancel(deletion)
        #expect(throws: DeletionGateError.cancelled) {
            try DeletionGate.execute(
                deletion,
                currentRevision: 7,
                currentFingerprint: DeletionGate.fingerprint("session-v1"),
                now: clock
            ) { _ in mutationCount += 1 }
        }
        #expect(mutationCount == 0)
    }

    @Test func successfulOperationIsConsumedAndReplayIsRejected() throws {
        let deletion = intent()
        var mutationCount = 0
        let receipt = try DeletionGate.execute(
            deletion,
            currentRevision: 7,
            currentFingerprint: DeletionGate.fingerprint("session-v1"),
            now: clock
        ) { _ in mutationCount += 1 }
        #expect(receipt.operationID == deletion.operationID)
        #expect(receipt.createdAt == clock)
        #expect(mutationCount == 1)
        #expect(throws: DeletionGateError.alreadyConsumed) {
            try DeletionGate.execute(
                deletion,
                currentRevision: 7,
                currentFingerprint: DeletionGate.fingerprint("session-v1"),
                now: clock
            ) { _ in mutationCount += 1 }
        }
        #expect(mutationCount == 1)
    }

    @Test func failedMutationDoesNotMintReceiptAndCanRetry() throws {
        let deletion = intent()
        var mutationCount = 0
        #expect(throws: TestDeletionError.failed) {
            try DeletionGate.execute(
                deletion,
                currentRevision: 7,
                currentFingerprint: DeletionGate.fingerprint("session-v1"),
                now: clock
            ) { _ in
                mutationCount += 1
                throw TestDeletionError.failed
            }
        }
        let receipt = try DeletionGate.execute(
            deletion,
            currentRevision: 7,
            currentFingerprint: DeletionGate.fingerprint("session-v1"),
            now: clock
        ) { _ in mutationCount += 1 }
        #expect(receipt.operationID == deletion.operationID)
        #expect(mutationCount == 2)
    }

    @Test func intentWithoutExpiryCannotMutate() throws {
        let deletion = OperationIntent(
            operationType: .delete,
            targetID: "session-legacy",
            targetType: "session",
            targetName: "Legacy",
            affectedCount: 1,
            impactSummary: "Delete",
            reversible: true,
            scopeID: "session:session-legacy:active",
            revision: 1,
            fingerprint: DeletionGate.fingerprint("legacy")
        )
        var mutationCount = 0
        #expect(throws: DeletionGateError.expired) {
            try DeletionGate.execute(
                deletion.withFirstConfirmation("reviewed").withSecondConfirmation("confirmed"),
                currentRevision: 1,
                currentFingerprint: DeletionGate.fingerprint("legacy"),
                now: clock
            ) { _ in mutationCount += 1 }
        }
        #expect(mutationCount == 0)
    }
}

private enum TestDeletionError: Error, Equatable { case failed }
