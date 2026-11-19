import Foundation

/// Persistable provider selection with separate, transient execution inputs.
public struct ProviderConfig: Identifiable, Codable, Hashable, Sendable {
    public static let deepSeekEnvironmentAliases: Set<String> = ["DEEPSEEK_API_KEY", "HERMES_CUSTOM_DEEPSEEK_API_KEY"]

    public let id: String
    public var label: String
    public let providerType: ProviderType
    public var runtimeProviderID: String?
    public let credentialType: ProviderCredential
    public var isEnabled: Bool
    public let createdAt: Date
    public var customBaseURL: String?
    public var appendV1Suffix: Bool
    public var apiKeyEnvVar: String?
    public var apiKey: String?
    public var attemptCheckpointDirectory: URL?
    public var controlledFieldLoopbackOnly: Bool
    /// 自定义请求头与代理；缺省 = 无自定义头、跟随系统代理。
    public var networkOptions: ProviderNetworkOptions = .default

    public init(
        id: String = UUID().uuidString,
        label: String,
        providerType: ProviderType,
        runtimeProviderID: String? = nil,
        credentialType: ProviderCredential = .apiKey,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        customBaseURL: String? = nil,
        appendV1Suffix: Bool = true,
        apiKeyEnvVar: String? = nil,
        apiKey: String? = nil,
        attemptCheckpointDirectory: URL? = nil
    ) {
        self.id = id
        self.label = label
        self.providerType = providerType
        self.runtimeProviderID = runtimeProviderID
        self.credentialType = credentialType
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.customBaseURL = customBaseURL
        self.appendV1Suffix = appendV1Suffix
        self.apiKeyEnvVar = Self.nonemptyTrimmed(apiKeyEnvVar)
        self.apiKey = apiKey
        self.attemptCheckpointDirectory = attemptCheckpointDirectory
        self.controlledFieldLoopbackOnly = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, providerType, runtimeProviderID, credentialType, isEnabled
        case createdAt, customBaseURL, appendV1Suffix, apiKeyEnvVar, networkOptions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        let encodedProvider = try values.decode(String.self, forKey: .providerType)
        providerType = Self.canonicalProviderType(from: encodedProvider)
        runtimeProviderID = try values.decodeIfPresent(String.self, forKey: .runtimeProviderID)
        credentialType = try values.decodeIfPresent(ProviderCredential.self, forKey: .credentialType) ?? .apiKey
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        customBaseURL = try values.decodeIfPresent(String.self, forKey: .customBaseURL)
        appendV1Suffix = try values.decodeIfPresent(Bool.self, forKey: .appendV1Suffix) ?? true
        let reference = try values.decodeIfPresent(String.self, forKey: .apiKeyEnvVar)
        apiKeyEnvVar = Self.nonemptyTrimmed(reference)
        if apiKeyEnvVar == nil, Self.isDeepSeekAlias(encodedProvider) {
            apiKeyEnvVar = encodedProvider
        }
        networkOptions = try values.decodeIfPresent(ProviderNetworkOptions.self, forKey: .networkOptions) ?? .default
        apiKey = nil
        attemptCheckpointDirectory = nil
        controlledFieldLoopbackOnly = false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(label, forKey: .label)
        try values.encode(providerType.rawValue, forKey: .providerType)
        try values.encodeIfPresent(runtimeProviderID, forKey: .runtimeProviderID)
        try values.encode(credentialType, forKey: .credentialType)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(customBaseURL, forKey: .customBaseURL)
        try values.encode(appendV1Suffix, forKey: .appendV1Suffix)
        try values.encodeIfPresent(apiKeyEnvVar, forKey: .apiKeyEnvVar)
        // 只在非默认时写，保持旧配置字节形态不变。
        if !networkOptions.isDefault { try values.encode(networkOptions, forKey: .networkOptions) }
    }

    public static func canonicalProviderType(from value: String) -> ProviderType {
        isDeepSeekAlias(value) ? .deepSeek : ProviderType.decoded(value)
    }

    public static func canonicalEnvironmentVariable(_ value: String?) -> String? {
        guard let reference = nonemptyTrimmed(value) else { return nil }
        return isDeepSeekAlias(reference) ? "DEEPSEEK_API_KEY" : reference
    }

    public var canonicalProviderRecordKey: String {
        if providerType == .deepSeek || apiKeyEnvVar.map(Self.isDeepSeekAlias) == true {
            return "deepseek"
        }
        return id
    }

    public static func mergeCanonical(_ records: [Self]) -> [Self] {
        var positions: [String: Int] = [:]
        var result: [Self] = []
        for record in records {
            let key = record.canonicalProviderRecordKey
            if let index = positions[key] {
                result[index] = result[index].merged(with: record)
            } else {
                positions[key] = result.count
                result.append(record)
            }
        }
        return result
    }

    public func merged(with other: Self) -> Self {
        guard canonicalProviderRecordKey == other.canonicalProviderRecordKey else { return self }
        var result = self
        if Self.nonemptyTrimmed(label) == nil { result.label = other.label }
        result.runtimeProviderID = runtimeProviderID ?? other.runtimeProviderID
        result.customBaseURL = customBaseURL ?? other.customBaseURL
        result.isEnabled = isEnabled || other.isEnabled
        if apiKeyEnvVar == nil || other.apiKeyEnvVar == "HERMES_CUSTOM_DEEPSEEK_API_KEY" {
            result.apiKeyEnvVar = other.apiKeyEnvVar
        }
        if Self.nonemptyTrimmed(apiKey) == nil { result.apiKey = other.apiKey }
        if networkOptions.isDefault { result.networkOptions = other.networkOptions }
        return result
    }

    public func effectiveAPIKey() -> String? {
        Self.nonemptyTrimmed(apiKey) ?? EnvCredentials.apiKey(envVar: apiKeyEnvVar)
    }

    public var effectiveCustomBaseURL: String? { Self.nonemptyTrimmed(customBaseURL) }

    public func resolvedBaseURL(default defaultURL: String) -> (url: String, appendV1: Bool) {
        guard let custom = effectiveCustomBaseURL else {
            return (Self.withoutFinalVersion(defaultURL), true)
        }
        return appendV1Suffix ? (Self.withoutFinalVersion(custom), true) : (custom, false)
    }

    public var runtimeConfigurationMaterial: String {
        let suffix = "|append-v1=\(appendV1Suffix ? "true" : "false")"
        switch providerType {
        case .local:
            return providerType.rawValue + "|" + (effectiveCustomBaseURL ?? "http://127.0.0.1:11434") + suffix
        case .openAI, .openAIResponses:
            return (effectiveCustomBaseURL ?? providerType.rawValue) + suffix
        case .openRouter:
            return effectiveCustomBaseURL.map { $0 + "|append-v1=false" }
                ?? "https://openrouter.ai/api|append-v1=true"
        default:
            return effectiveCustomBaseURL ?? providerType.rawValue
        }
    }

    private static func nonemptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func isDeepSeekAlias(_ value: String) -> Bool {
        value == "DEEPSEEK_API_KEY" || value == "HERMES_CUSTOM_DEEPSEEK_API_KEY"
    }

    /// Exactly one trailing slash is removed before exactly one terminal /v1.
    private static func withoutFinalVersion(_ value: String) -> String {
        var result = value
        if result.hasSuffix("/") { result.removeLast() }
        if result.hasSuffix("/v1") { result.removeLast(3) }
        return result
    }
}
