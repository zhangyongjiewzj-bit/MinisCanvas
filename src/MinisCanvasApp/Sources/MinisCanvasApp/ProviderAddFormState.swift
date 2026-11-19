import Foundation
import MinisCore

/// 新增供应商表单的状态层：预设选择后自动填好除 API Key 外的字段。
struct ProviderAddFormState: Equatable {
    enum Field: Equatable {
        case name, baseURL, modelNames, apiKey
    }

    let presets: [ProviderPreset]
    var showsPresetPicker: Bool
    var name = ""
    var baseURL = ""
    var protocolType: ProviderWireProtocol = .openaiCompatible
    var modelNames: [String] = []
    var apiKey = ""

    static func initial(fromConnectionRoute: Bool) -> ProviderAddFormState {
        ProviderAddFormState(presets: ProviderPreset.all, showsPresetPicker: fromConnectionRoute)
    }

    var missingRequiredFields: [Field] {
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var missing: [Field] = []
        if blank(name) { missing.append(.name) }
        if blank(baseURL) { missing.append(.baseURL) }
        // 本机/局域网服务（Ollama、LM Studio 等）：Key 可留空，模型名可稍后用“获取模型列表”选择。
        let isLocalService = ProviderEndpointPolicy.allowsBlankAPIKey(forBaseURL: baseURL)
        if modelNames.allSatisfy(blank) && !isLocalService { missing.append(.modelNames) }
        if blank(apiKey) && !isLocalService { missing.append(.apiKey) }
        return missing
    }

    mutating func selectPreset(id: String) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        name = preset.credentialName
        baseURL = preset.baseURL
        protocolType = preset.protocolType
        modelNames = preset.modelNames
        showsPresetPicker = false
    }
}
