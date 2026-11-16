import Foundation
import Testing
@testable import MinisCore

/// Static/fixture coverage for the settings -> readiness -> picker contract.
/// No live endpoint, credential, Keychain, or network is used here.
@Suite("V425 DeepSeek settings readiness picker contract")
struct DeepSeekProviderContractTests {
    @Test("current Flash text ID is additive; legacy defaults and unknown-ID exclusion remain")
    func currentFlashIsAnAdditiveTextOnlyCatalogEntry() {
        let oldIDs = ["deepseek-chat", "deepseek-reasoner", "deepseek-v4-flash", "deepseek-v4-pro"]
        #expect(LLMModel.allDeepSeek.map(\.id) == oldIDs + ["deepseek-flash"])
        #expect(ProviderType.deepSeek.builtInModels == LLMModel.allDeepSeek)
        #expect(LLMModel.allModels.contains(.deepSeekFlash))
        #expect(DeepSeekProviderContract.supportedModelIDs == [
            "deepseek-v4-flash", "deepseek-v4-pro", "deepseek-chat", "deepseek-reasoner", "deepseek-flash"
        ])
        #expect(DeepSeekProviderContract.preferredModelID == "deepseek-v4-flash")
        #expect(DeepSeekProvider(apiKey: "[configured locally]").model.id == "deepseek-v4-flash")
        #expect(LLMModel.deepSeekFlash.capabilities.supportedModalities == .textOnly)
        #expect(LLMModel.deepSeekFlash.contextWindow == LLMModel.deepSeekV4Flash.contextWindow)
        #expect(LLMModel.deepSeekFlash.maxOutputTokens == LLMModel.deepSeekV4Flash.maxOutputTokens)
        #expect(LLMModel.deepSeekFlash.supportsReasoning == nil)
        #expect(LLMModel.deepSeekFlash.interleavedReasoningField == nil)
        #expect(!DeepSeekProviderContract.supportedModelIDs.contains("deepseek-flash-unregistered"))
    }

    @Test("canonical identity and settings defaults are stable")
    func canonicalDefaults() throws {
        #expect(DeepSeekProviderContract.providerID == "deepseek")
        #expect(DeepSeekProviderContract.apiKeyEnvironmentVariable == "DEEPSEEK_API_KEY")
        #expect(DeepSeekProviderContract.baseURL == "https://api.deepseek.com")
        #expect(DeepSeekProviderContract.preferredModelID == "deepseek-v4-flash")
        #expect(DeepSeekProviderContract.supportedModelIDs.first == "deepseek-v4-flash")
        #expect(DeepSeekProviderContract.modelsPath == "/models")
        #expect(DeepSeekProviderContract.chatCompletionsPath == "/chat/completions")
        #expect(
            EnvVarStore.providerSuggestion(for: "DEEPSEEK_API_KEY")?.baseURL
                == DeepSeekProviderContract.baseURL
        )
        #expect(
            EnvVarStore.providerSuggestion(for: "DEEPSEEK_API_KEY")?.modelNames
                == DeepSeekProviderContract.supportedModelIDs
        )
    }

    @Test("legacy credential aliases converge on the canonical picker identity")
    func aliasesConverge() {
        for alias in [
            "deepseek",
            "DeepSeek",
            "DEEPSEEK_API_KEY",
            "HERMES_CUSTOM_DEEPSEEK_API_KEY",
        ] {
            #expect(DeepSeekProviderContract.canonicalProviderID(for: alias) == "deepseek")
        }
        #expect(DeepSeekProviderContract.canonicalProviderID(for: "OPENAI_API_KEY") == nil)
        #expect(DeepSeekProviderContract.canonicalProviderID(for: "  ") == nil)
    }

    @Test("canonical routes contain no version drift or credential material")
    func routesAreExactAndSecretFree() throws {
        let models = try #require(
            DeepSeekProviderContract.endpointURL(route: .models)
        )
        let chat = try #require(
            DeepSeekProviderContract.endpointURL(route: .chatCompletions)
        )
        #expect(models.absoluteString == "https://api.deepseek.com/models")
        #expect(chat.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(models.path == DeepSeekProviderContract.modelsPath)
        #expect(chat.path == DeepSeekProviderContract.chatCompletionsPath)
        #expect(DeepSeekProviderContract.endpointURL(
            baseURL: "https://api.deepseek.com?api_key=fixture",
            route: .models
        ) == nil)
    }

    @Test("picker receipt never serializes the API key")
    func pickerReceiptIsSecretFree() throws {
        let secret = "fixture-deepseek-secret"
        let receipt = ChatModelPickerApplyReceipt(
            providerID: DeepSeekProviderContract.providerID,
            modelID: DeepSeekProviderContract.preferredModelID,
            evidenceID: "fixture-evidence",
            applyReceiptID: "fixture-receipt"
        )
        let data = try JSONEncoder().encode(receipt)
        let serialized = String(decoding: data, as: UTF8.self)
        #expect(serialized.contains(secret) == false)
        #expect(serialized.contains("api_key") == false)
        #expect(serialized.contains("Authorization") == false)
    }
}
