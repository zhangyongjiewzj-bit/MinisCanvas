import Testing
import Foundation
@testable import MinisCore

// Batch2H / U-04：新增供应商表单的预设数据（纯数据，Core 层）。
// 需要新符号：`ProviderPreset`（见各断言用到的成员）。预设数据必须与现有
// EnvVarStore.providerSuggestion / DeepSeekProviderContract 同源，不另抄一份。

@Suite("Batch2H 供应商预设（U-04）")
struct Batch2HProviderPresetTests {

    @Test("预设列表含 DeepSeek / 百炼 / NewAPI，且每项自带 Base URL、协议、凭据名、默认模型")
    func presetsCoverKnownProvidersWithCompleteDefaults() throws {
        let ids = ProviderPreset.all.map(\.id)
        #expect(ids.contains("deepseek"))
        #expect(ids.contains("dashscope"))
        #expect(ids.contains("newapi"))
        #expect(Set(ids).count == ids.count)
        for preset in ProviderPreset.all {
            #expect(!preset.displayName.isEmpty)
            #expect(preset.baseURL.hasPrefix("https://") || ProviderEndpointPolicy.allowsBlankAPIKey(forBaseURL: preset.baseURL))
            #expect(!preset.credentialName.isEmpty)
            #expect(preset.credentialName == EnvVarStore.canonicalName(preset.credentialName))
            // 本机预设的模型名取决于本机已下载的模型，允许留空。
            // Gemini / Kimi / 智谱 / 硅基流动只补地址，模型名用“获取模型列表”选择。
            let addressOnly: Set<String> = ["gemini", "kimi", "zhipu", "siliconflow"]
            #expect(!preset.modelNames.isEmpty || addressOnly.contains(preset.id)
                || ProviderEndpointPolicy.allowsBlankAPIKey(forBaseURL: preset.baseURL))
        }
    }

    @Test("DeepSeek 预设与 DeepSeekProviderContract 同源，凭据名为 DEEPSEEK_API_KEY")
    func deepSeekPresetMatchesContract() throws {
        let preset = try #require(ProviderPreset.all.first { $0.id == "deepseek" })
        #expect(preset.credentialName == "DEEPSEEK_API_KEY")
        #expect(preset.credentialName == DeepSeekProviderContract.apiKeyEnvironmentVariable)
        #expect(preset.baseURL == DeepSeekProviderContract.baseURL)
        #expect(preset.modelNames == DeepSeekProviderContract.supportedModelIDs)
        #expect(preset.protocolType == .openaiCompatible)
    }

    @Test("百炼预设凭据名为 DASHSCOPE_API_KEY")
    func dashScopePresetCredentialName() throws {
        let preset = try #require(ProviderPreset.all.first { $0.id == "dashscope" })
        #expect(preset.credentialName == "DASHSCOPE_API_KEY")
    }

    @Test("预设含 Anthropic、OpenAI、OpenRouter 与本机的 Ollama、LM Studio，本机预设不要 Key")
    func presetsIncludeMainstreamAndLocalServices() throws {
        let ids = Set(ProviderPreset.all.map(\.id))
        #expect(ids.isSuperset(of: ["anthropic", "openai", "openrouter", "ollama", "lmstudio"]))
        let ollama = try #require(ProviderPreset.all.first { $0.id == "ollama" })
        #expect(ollama.baseURL == "http://localhost:11434/v1")
        let lmStudio = try #require(ProviderPreset.all.first { $0.id == "lmstudio" })
        #expect(lmStudio.baseURL == "http://localhost:1234/v1")
        #expect(ProviderEndpointPolicy.allowsBlankAPIKey(forBaseURL: ollama.baseURL))
        #expect(ProviderEndpointPolicy.allowsBlankAPIKey(forBaseURL: "http://192.168.1.8:3000/v1"))
        #expect(!ProviderEndpointPolicy.allowsBlankAPIKey(forBaseURL: "https://api.openai.com/v1"))
        #expect(ProviderPreset.defaultBaseURL(forCredentialName: "openai_api_key") == "https://api.openai.com/v1")
        #expect(ProviderPreset.defaultBaseURL(forCredentialName: "MY_RELAY_KEY") == nil)
    }

    @Test("原有三个预设的 Base URL / 协议 / 模型 = providerSuggestion(for: 凭据名)，不另抄一份")
    func presetsAgreeWithExistingSuggestionTable() throws {
        for preset in ProviderPreset.all where ["deepseek", "dashscope", "newapi"].contains(preset.id) {
            let suggestion = try #require(EnvVarStore.providerSuggestion(for: preset.credentialName))
            #expect(suggestion.baseURL == preset.baseURL, "\(preset.id)")
            #expect(suggestion.modelNames == preset.modelNames, "\(preset.id)")
            #expect(suggestion.protocolType == preset.protocolType, "\(preset.id)")
            #expect(suggestion.providerLabel == preset.displayName, "\(preset.id)")
        }
    }
}
