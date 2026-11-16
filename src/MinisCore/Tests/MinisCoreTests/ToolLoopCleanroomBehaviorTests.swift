import Testing
@testable import MinisCore

struct ToolLoopCleanroomBehaviorTests {
    @Test func nonFiniteNumbersRemainRecordableDescriptions() {
        let parameters: [String: Any] = ["first": Double.nan, "second": Double.infinity]
        let signature = ToolLoopDetector.signature(tool: "synthetic", input: parameters)
        let detector = ToolLoopDetector()
        let recorded = detector.recordInvocation(tool: "synthetic", input: parameters)
        #expect(recorded == signature)
        #expect(signature.lowercased().contains("nan"))
        #expect(signature.lowercased().contains("inf"))
        #expect(detector.historySnapshot().count == 1)
    }
}
