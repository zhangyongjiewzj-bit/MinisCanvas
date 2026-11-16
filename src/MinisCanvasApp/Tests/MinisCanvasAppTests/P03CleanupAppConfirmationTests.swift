import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("P03 cleanup explicit one-shot confirmation")
struct P03CleanupAppConfirmationTests {
    @Test("Unknown, cancelled, superseded and replayed confirmations never admit an effect")
    func confirmationCannotBeReplayed() {
        var gate = P03CleanupConfirmationGate()
        let unknownConsumed: Bool = gate.consume(UUID())
        #expect(!unknownConsumed)
        let cancelled = gate.issue()
        gate.cancel()
        let cancelledConsumed: Bool = gate.consume(cancelled)
        #expect(!cancelledConsumed)
        let old = gate.issue()
        let current = gate.issue()
        let supersededConsumed: Bool = gate.consume(old)
        #expect(!supersededConsumed)
        let currentConsumed: Bool = gate.consume(current)
        #expect(currentConsumed)
        let replayConsumed: Bool = gate.consume(current)
        #expect(!replayConsumed)
    }

    @MainActor @Test("No captured real lifecycle resource means no synthetic cleanup request")
    func missingResourceCannotPrepareOrConfirm() async {
        let controller = P03CleanupAppController()
        await controller.prepare(UUID())
        controller.confirm(UUID())
        #expect(controller.rows.isEmpty)
        #expect(controller.confirmation == nil)
    }
}
