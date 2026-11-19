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

    @Test func optionsComeFromTheRequestMappingTable() {
        // 映射表没有声明的模型只给“模型默认”，不列选了也无效的档位。
        #expect(ComposerThinkingSelection.options(modelID: "synthetic-unregistered-model").count == 1)
        #expect(ComposerThinkingSelection.options(modelID: "gpt-5.5").contains(.high))
    }

    @MainActor
    @Test func legacyWelcomeTextIsStillRecognized() {
        #expect(ChatStore.isWelcomeText(ChatStore.welcomeText))
        #expect(ChatStore.isWelcomeText(ChatStore.legacyWelcomeTexts[0]))
        #expect(!ChatStore.welcomeText.contains("Mock"))
        #expect(!ChatStore.isWelcomeText("普通回复"))
    }

    @Test func undeclaredModelIsARequestWithoutCapabilityClaim() {
        let modelID = "synthetic-unregistered-model"
        #expect(ThinkingLevelCatalog.declaredMaxLevel(for: modelID) == nil)
        #expect(ComposerThinkingSelection.capturedLevel(.ultra, modelID: modelID) == .ultra)
        #expect(ComposerThinkingSelection.help(modelID: modelID).contains("可能被忽略"))
        #expect(ComposerThinkingSelection.help(modelID: modelID).contains("未声明目录上限"))
    }

    /// MC4-037：档位一律显示中文名，不出现英文枚举值。
    @Test func thinkingLevelLabelsAreChineseAndHelpUsesThem() {
        for level in ThinkingLevel.allCases {
            let label = ComposerThinkingSelection.label(level)
            #expect(label != level.rawValue && label != level.displayName)
        }
        let modelID = "claude-opus-4-6"
        if let maximum = ThinkingLevelCatalog.declaredMaxLevel(for: modelID) {
            let help = ComposerThinkingSelection.help(modelID: modelID)
            #expect(help.contains("当前目录上限：\(ComposerThinkingSelection.label(maximum))"))
            #expect(!help.contains(maximum.displayName + "；"))
        }
    }

}
