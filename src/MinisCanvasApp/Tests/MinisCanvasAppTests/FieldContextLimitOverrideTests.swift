import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Field 测试档上下文上限覆盖")
@MainActor
struct FieldContextLimitOverrideTests {
    private let key = FieldContextLimitOverride.environmentKey
    private let fieldEnv = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1"]
    private let fieldArgs = ["MinisCanvasApp", RuntimeIsolationProfile.fieldActivationArgument]

    private func env(_ value: String?, field: Bool = true) -> [String: String] {
        var result = field ? fieldEnv : [:]
        if let value { result[key] = value }
        return result
    }

    @Test func nonFieldChatStoreKeepsProductionCap() {
        let chat = ChatStore()
        chat.configureBudget(from: .default, processEnvironment: env("3000", field: false),
                             processArguments: ["MinisCanvasApp"])
        #expect(chat.budgetCapTokens == 1_000_000)
        chat.configureBudget(from: .default, processEnvironment: env("3000"),
            processArguments: fieldArgs + [RuntimeIsolationProfile.fieldActivationArgument])
        #expect(chat.budgetCapTokens == 1_000_000)
    }

    @Test func displayAndOverLimitShareTheOverriddenCap() async {
        let chat = ChatStore()
        chat.configureBudget(from: .default, processEnvironment: env("3000"), processArguments: fieldArgs)
        #expect(chat.budgetCapTokens == 3_000)
        #expect(chat.requestBudget.maxTokensPerSession == 3_000)
        #expect(await chat.budgetTracker.budget.maxTokensPerSession == 3_000)
        #expect(ChatStore.tokenUsageLabel(used: chat.budgetUsedTokens, cap: chat.budgetCapTokens)
                == ChatStore.tokenUsageLabel(used: 0, cap: 3_000))
        #expect(chat.warningFraction == 0.8)
        chat.recordTokens(2_399)
        #expect(!chat.budgetIsWarning)
        chat.recordTokens(1)
        #expect(chat.budgetIsWarning)
        #expect(!chat.budgetIsOverLimit)
        chat.recordTokens(599)
        #expect(!chat.budgetIsOverLimit)
        chat.recordTokens(1)
        #expect(chat.budgetIsOverLimit)
        #expect(chat.canContinueAfterContextLimit)
    }

}
