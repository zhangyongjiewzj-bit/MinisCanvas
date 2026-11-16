import Foundation
import Testing
@testable import MinisCore

@Suite("BL6 conversation_settings rollback without changes key")
struct BL6RollbackMissingChangesTests {
    private func decode(_ json: String) throws -> BL6SettingsApprovedInput {
        try JSONDecoder().decode(BL6SettingsApprovedInput.self, from: Data(json.utf8))
    }

    @Test("rollback without changes key decodes, changes empty, passes approved-effect validation")
    func rollbackMissingChangesIsAccepted() throws {
        let parsed = try decode(#"{"operation":"rollback","expectedRevision":"rev-1","undoReceiptID":"receipt-1"}"#)
        #expect(parsed.operation == .rollback)
        #expect(parsed.changes.isEmpty)
        #expect(parsed.undoReceiptID == "receipt-1")
        try parsed.validateForApprovedEffect()
    }

    @Test("rollback with explicit empty changes still accepted (existing working form)")
    func rollbackExplicitEmptyChangesStillAccepted() throws {
        let parsed = try decode(#"{"operation":"rollback","expectedRevision":"rev-1","undoReceiptID":"receipt-1","changes":{}}"#)
        try parsed.validateForApprovedEffect()
    }

    @Test("apply without changes is still rejected as invalidIntent")
    func applyMissingChangesStillRejected() {
        do {
            let parsed = try decode(#"{"operation":"apply","expectedRevision":"rev-1"}"#)
            try parsed.validateForApprovedEffect()
            Issue.record("apply without changes must be rejected")
        } catch let error as BL6SettingsDispatchError {
            guard case .invalidIntent = error else {
                Issue.record("expected invalidIntent, got \(error)")
                return
            }
        } catch {
            // Decode failure is also a rejection: production maps it to invalidIntent.
            #expect(error is DecodingError)
        }
    }
}
