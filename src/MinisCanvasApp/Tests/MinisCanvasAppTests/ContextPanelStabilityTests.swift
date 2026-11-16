import Testing
@testable import MinisCanvasApp

@Suite("ContextPanel previewDivider cursor 配对")
struct ContextPanelStabilityTests {

    @Test func repeatedHoverEnterDoesNotPushTwice() {
        var gate = PreviewCursorPairingGate()

        #expect(gate.enter() == true)
        #expect(gate.enter() == false)
        #expect(gate.isPushed)
    }

    @Test func leaveAndDisappearOnlyPopOnce() {
        var gate = PreviewCursorPairingGate()

        #expect(gate.enter() == true)
        #expect(gate.leave() == true)
        #expect(gate.leave() == false)
        #expect(gate.isPushed == false)
    }
}
