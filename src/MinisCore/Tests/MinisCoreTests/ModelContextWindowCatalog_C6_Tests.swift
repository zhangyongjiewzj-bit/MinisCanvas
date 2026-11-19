import Testing
@testable import MinisCore

/// C6：内置模型窗口目录。生产构造方式只给 id/displayName/provider（不带 contextWindow），
/// 与 ChatStore.activeProvider 一致，因此窗口必须来自目录而不是常量上的 contextWindow。
/// 数值出处：
/// - gpt-4.1 = 1,047,576：用户/审计 D-04 指定（G_C批设计 §C6）。
/// - Claude 1M 家族 / Haiku 4.5 = 200k：platform.claude.com/docs/en/build-with-claude/context-windows
///   “Context window sizes by model”（2026-11-09 读取）。
/// - 其余沿用 LLMTypes 既有启发式数值，官方出处未核实。
@Suite("C6 模型窗口目录")
struct ModelContextWindowCatalogC6Tests {
    private func produced(_ id: String, provider: String = "OpenAI") -> LLMModel {
        LLMModel(id: id, displayName: id, provider: provider)
    }

    @Test func gpt41ResolvesToItsRealWindow() {
        #expect(produced("gpt-4.1").contextWindowTokens == 1_047_576)
    }

    @Test func gpt41VariantsAreNotSwallowedByGpt4Rule() {
        #expect(produced("gpt-4.1-mini").contextWindowTokens == 1_047_576)
        #expect(produced("gpt-4.1-mini").contextWindowTokens != 8_000)
        #expect(produced("gpt-4.5-preview").contextWindowTokens != 8_000)
    }

    @Test func plainGpt4KeepsItsOldWindowAndGpt4oAndTurboAreNotDemoted() {
        #expect(produced("gpt-4").contextWindowTokens == 8_000)
        #expect(produced("gpt-4o").contextWindowTokens == 128_000)
        #expect(produced("gpt-4o-mini").contextWindowTokens == 128_000)
        #expect(produced("gpt-4-turbo").contextWindowTokens == 128_000)
    }

    @Test func gpt5FamilyKeepsFourHundredK() {
        #expect(produced("gpt-5").contextWindowTokens == 400_000)
        #expect(produced("gpt-5.4").contextWindowTokens == 400_000)
    }

    @Test func unknownClaudeIDDoesNotGetOneMillion() {
        // 保守兜底 200,000：设计 §C6 的 [假设]，待预审/用户裁。
        #expect(produced("claude-not-registered-9", provider: "Anthropic").contextWindowTokens == 200_000)
        #expect(produced("claude-sonnet-4", provider: "Anthropic").contextWindowTokens == 200_000)
    }

    @Test func openRouterVendorPrefixIsNormalised() {
        #expect(produced("anthropic/claude-sonnet-4", provider: "OpenRouter").contextWindowTokens
            == produced("claude-sonnet-4", provider: "Anthropic").contextWindowTokens)
        #expect(produced("openai/gpt-4.1", provider: "OpenRouter").contextWindowTokens == 1_047_576)
        #expect(ModelContextWindowCatalog.window(forModelID: "OpenAI/GPT-4.1") == 1_047_576)
    }

    @Test func everyBuiltInModelWithDeclaredWindowMatchesCatalogWhenBuiltTheProductionWay() {
        let declared = LLMModel.allModels.filter { $0.contextWindow != nil }
        #expect(!declared.isEmpty)
        for model in declared {
            #expect(produced(model.id, provider: model.provider).contextWindowTokens == model.contextWindow,
                    "\(model.id) 目录值与常量漂移")
        }
    }

    @Test func explicitWindowStillWinsOverCatalog() {
        let custom = LLMModel(id: "gpt-4.1", displayName: "x", provider: "OpenAI", contextWindow: 50_000)
        #expect(custom.contextWindowTokens == 50_000)
    }

    @Test func geminiAndUnknownKeepPreviousValues() {
        #expect(produced("gemini-2.5-pro", provider: "Google").contextWindowTokens == 1_000_000)
        #expect(produced("gemini-1.0-pro", provider: "Google").contextWindowTokens == 32_000)
        #expect(produced("some-local-model", provider: "Local").contextWindowTokens == 128_000)
        #expect(ModelContextWindowCatalog.window(forModelID: "some-local-model") == nil)
    }

    @Test func commonLongContextFamiliesAreRecognisedInsteadOfFallingBack() {
        #expect(produced("qwen-long", provider: "DashScope").contextWindowTokens == 10_000_000)
        #expect(produced("glm-4-long", provider: "Zhipu").contextWindowTokens == 1_000_000)
        #expect(produced("glm-4.5-air", provider: "Zhipu").contextWindowTokens == 128_000)
        #expect(produced("kimi-k2-0905-preview", provider: "Moonshot").contextWindowTokens == 256_000)
        #expect(produced("deepseek-chat", provider: "DeepSeek").contextWindowTokens == 128_000)
        #expect(!ModelContextWindowCatalog.usesFallbackWindow(explicitWindow: nil, modelID: "kimi-k2"))
        #expect(ModelContextWindowCatalog.usesFallbackWindow(explicitWindow: nil, modelID: "some-local-model"))
    }
}
