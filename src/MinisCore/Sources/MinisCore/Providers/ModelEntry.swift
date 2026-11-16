import Foundation

public struct ModelOverrides: Codable, Hashable, Sendable {
    public var displayName: String?
    public var maxOutputTokens: Int?
    public var modalityOverride: ModelModality?
    public var contextWindow: Int?
    public var supportsReasoning: Bool?
    public var maxThinkingLevel: ThinkingLevel?

    public init(displayName: String? = nil, maxOutputTokens: Int? = nil,
                modalityOverride: ModelModality? = nil, contextWindow: Int? = nil,
                supportsReasoning: Bool? = nil, maxThinkingLevel: ThinkingLevel? = nil) {
        self.displayName = displayName
        self.maxOutputTokens = maxOutputTokens
        self.modalityOverride = modalityOverride
        self.contextWindow = contextWindow
        self.supportsReasoning = supportsReasoning
        self.maxThinkingLevel = maxThinkingLevel
    }
    public var isEmpty: Bool {
        displayName == nil && maxOutputTokens == nil && modalityOverride == nil && contextWindow == nil
            && supportsReasoning == nil && maxThinkingLevel == nil
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, maxOutputTokens, modalityOverride, contextWindow, supportsReasoning, maxThinkingLevel
    }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try fields.decodeIfPresent(String.self, forKey: .displayName)
        maxOutputTokens = try fields.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        modalityOverride = try fields.decodeIfPresent(ModelModality.self, forKey: .modalityOverride)
        contextWindow = try fields.decodeIfPresent(Int.self, forKey: .contextWindow)
        supportsReasoning = try fields.decodeIfPresent(Bool.self, forKey: .supportsReasoning)
        maxThinkingLevel = try fields.decodeIfPresent(String.self, forKey: .maxThinkingLevel).map(ThinkingLevel.decoded)
    }
}

public struct ModelEntry: Identifiable, Codable, Hashable, Sendable {
    public let uuid: String
    public let providerInstanceId: String
    public let baseModel: LLMModel
    public var overrides: ModelOverrides
    public var isCustom: Bool
    public var isHidden: Bool

    public init(uuid: String = UUID().uuidString, providerInstanceId: String, model: LLMModel,
                overrides: ModelOverrides = ModelOverrides(), isCustom: Bool = false, isHidden: Bool = false) {
        self.uuid = uuid
        self.providerInstanceId = providerInstanceId
        self.baseModel = model
        self.overrides = overrides
        self.isCustom = isCustom
        self.isHidden = isHidden
    }
    public var id: String { compositeKey }
    public var compositeKey: String { providerInstanceId + "/" + baseModel.id }
    public var isUserModified: Bool { isCustom || isHidden || !overrides.isEmpty }
    public var model: LLMModel {
        LLMModel(id: baseModel.id, displayName: overrides.displayName ?? baseModel.displayName,
                 provider: baseModel.provider, modalityOverride: overrides.modalityOverride ?? baseModel.modalityOverride,
                 contextWindow: overrides.contextWindow ?? baseModel.contextWindow,
                 maxOutputTokens: overrides.maxOutputTokens ?? baseModel.maxOutputTokens,
                 supportsReasoning: overrides.supportsReasoning ?? baseModel.supportsReasoning,
                 interleavedReasoningField: baseModel.interleavedReasoningField)
    }
    public var effectiveMaxThinkingLevel: ThinkingLevel { overrides.maxThinkingLevel ?? model.catalogMaxThinkingLevel }

    public var selectionReference: ProviderModelSelectionReference {
        ProviderModelSelectionReference(providerID: providerInstanceId, modelID: baseModel.id)
    }

    public func selectionCandidate(isConfigured: Bool, status: ProviderReadinessPersistenceStatus,
                                   readinessState: ProviderReadinessState, credentialVersion: String? = nil,
                                   health: ProviderModelSelectionHealth = .supported, aliases: [String] = []) -> ProviderModelSelectionCandidate {
        ProviderModelSelectionCandidate(providerID: providerInstanceId, modelID: baseModel.id, aliases: aliases,
                                        isConfigured: isConfigured, status: status, readinessState: readinessState,
                                        credentialVersion: credentialVersion, health: health)
    }

    public var selectionAccessibilityIdentifier: String {
        func segment(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            var rendered = ""
            var inReplacement = false
            for scalar in trimmed.unicodeScalars {
                let v = scalar.value
                let allowed = (65...90).contains(v) || (97...122).contains(v) || (48...57).contains(v)
                    || v == 46 || v == 95 || v == 45
                if allowed {
                    rendered.unicodeScalars.append(scalar)
                    inReplacement = false
                } else if !inReplacement {
                    rendered += "_"
                    inReplacement = true
                }
            }
            return rendered.isEmpty ? "unknown" : rendered
        }
        return "model-picker." + segment(providerInstanceId) + "." + segment(baseModel.id)
    }

    private enum CodingKeys: String, CodingKey { case uuid, providerInstanceId, model, overrides, isCustom, isHidden }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try fields.decodeIfPresent(String.self, forKey: .uuid) ?? UUID().uuidString
        providerInstanceId = try fields.decode(String.self, forKey: .providerInstanceId)
        baseModel = try fields.decode(LLMModel.self, forKey: .model)
        overrides = try fields.decodeIfPresent(ModelOverrides.self, forKey: .overrides) ?? ModelOverrides()
        isCustom = try fields.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        isHidden = try fields.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(uuid, forKey: .uuid)
        try fields.encode(providerInstanceId, forKey: .providerInstanceId)
        try fields.encode(baseModel, forKey: .model)
        try fields.encode(isCustom, forKey: .isCustom)
        try fields.encode(isHidden, forKey: .isHidden)
        if !overrides.isEmpty { try fields.encode(overrides, forKey: .overrides) }
    }
}
