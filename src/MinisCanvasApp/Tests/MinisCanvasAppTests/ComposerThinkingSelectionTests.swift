import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Composer thinking request capture")
struct ComposerThinkingSelectionTests {
    @Test func defaultDoesNotInventReasoningRequest() {
        #expect(ComposerThinkingSelection.capturedLevel(nil, modelID: "claude-opus-4-6") == nil)
        #expect(ComposerThinkingSelection.options(modelID: nil).first == .some(nil))
    }

    @Test func declaredBoundLimitsChoicesAndFrozenValue() {
        let modelID = "claude-opus-4-6"
        let maximum = ThinkingLevelCatalog.declaredMaxLevel(for: modelID)
        #expect(maximum == .max)
        #expect(!ComposerThinkingSelection.options(modelID: modelID).contains(.ultra))
        #expect(ComposerThinkingSelection.capturedLevel(.ultra, modelID: modelID) == maximum)
        #expect(ComposerThinkingSelection.capturedLevel(.off, modelID: modelID) == .off)
    }

    @Test func undeclaredModelIsARequestWithoutCapabilityClaim() {
        let modelID = "synthetic-unregistered-model"
        #expect(ThinkingLevelCatalog.declaredMaxLevel(for: modelID) == nil)
        #expect(ComposerThinkingSelection.capturedLevel(.ultra, modelID: modelID) == .ultra)
        #expect(ComposerThinkingSelection.help(modelID: modelID).contains("可能被忽略"))
        #expect(ComposerThinkingSelection.help(modelID: modelID).contains("未声明目录上限"))
    }

}
