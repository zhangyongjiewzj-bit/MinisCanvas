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
            #expect(preset.baseURL.hasPrefix("https://"))
            #expect(!preset.credentialName.isEmpty)
            #expect(preset.credentialName == EnvVarStore.canonicalName(preset.credentialName))
            #expect(!preset.modelNames.isEmpty)
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

    @Test("每个预设的 Base URL / 协议 / 模型 = providerSuggestion(for: 凭据名)，不另抄一份")
    func presetsAgreeWithExistingSuggestionTable() throws {
        for preset in ProviderPreset.all {
            let suggestion = try #require(EnvVarStore.providerSuggestion(for: preset.credentialName))
            #expect(suggestion.baseURL == preset.baseURL, "\(preset.id)")
            #expect(suggestion.modelNames == preset.modelNames, "\(preset.id)")
            #expect(suggestion.protocolType == preset.protocolType, "\(preset.id)")
            #expect(suggestion.providerLabel == preset.displayName, "\(preset.id)")
        }
    }
}
