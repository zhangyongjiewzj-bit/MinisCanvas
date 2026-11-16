import Testing
import Foundation
@testable import MinisCore

struct DeletionGateTests {
    private func intent(reversible: Bool = false) -> OperationIntent {
        OperationIntent(operationType: .permanentDelete, targetID: "asset-1", targetType: "asset", targetName: "cover.png", affectedCount: 1, impactSummary: "删除资产及其本地文件", reversible: reversible, scopeID: "canvas:a", revision: 4, fingerprint: "fp")
    }

    @Test func deletionRequiresTwoConfirmations() {
        let raw = intent()
        #expect(DeletionGate.prepare(raw, currentRevision: 4, currentFingerprint: "fp") == .failure(.firstConfirmationRequired))
        let first = raw.withFirstConfirmation("了解风险")
        #expect(DeletionGate.prepare(first, currentRevision: 4, currentFingerprint: "fp") == .failure(.secondConfirmationRequired))
        let oldPhrase = first.withSecondConfirmation("PERMANENTLY DELETE")
        #expect(DeletionGate.prepare(oldPhrase, currentRevision: 4, currentFingerprint: "fp") == .failure(.irreversibleRequiresPhrase))
        let phrase = first.withSecondConfirmation("永久删除")
        #expect(DeletionGate.prepare(phrase, currentRevision: 4, currentFingerprint: "fp").isSuccess)
    }

    @Test func changedTargetInvalidatesConfirmation() {
        let confirmed = intent(reversible: true).withFirstConfirmation("ok").withSecondConfirmation("ok")
        #expect(DeletionGate.prepare(confirmed, currentRevision: 5, currentFingerprint: "fp") == .failure(.targetChanged))
        #expect(DeletionGate.prepare(confirmed, currentRevision: 4, currentFingerprint: "changed") == .failure(.targetChanged))
    }

    @Test func receiptContainsNoSensitivePayload() {
        let confirmed = intent(reversible: true).withFirstConfirmation("ok").withSecondConfirmation("ok")
        let receipt = DeletionGate.receipt(for: confirmed, now: Date(timeIntervalSince1970: 0))
        #expect(receipt.operationID == confirmed.operationID)
        #expect(receipt.affectedCount == 1)
        #expect(receipt.outcome == "deleted")
    }
}

private extension Result where Success == OperationIntent, Failure == DeletionGateError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
