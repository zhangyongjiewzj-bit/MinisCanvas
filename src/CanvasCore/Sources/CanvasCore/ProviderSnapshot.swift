import Foundation

/// 提交任务时冻结的 Provider 配置；不包含凭据或 Chat/UI 对象。
public struct ProviderSnapshot: Codable, Equatable, Sendable, Hashable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public let providerID: String
    public let modelID: String
    public let capabilities: Set<CanvasProviderCapability>
    public let configurationFingerprint: String

    public init(
        providerID: String,
        modelID: String,
        capabilities: Set<CanvasProviderCapability>,
        configurationFingerprint: String,
        schemaVersion: Int = ProviderSnapshot.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.modelID = modelID
        self.capabilities = capabilities
        self.configurationFingerprint = configurationFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, providerID, modelID, capabilities, configurationFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: container, key: .schemaVersion)
        self.providerID = try container.decode(String.self, forKey: .providerID)
        self.modelID = try container.decode(String.self, forKey: .modelID)
        self.capabilities = try container.decode(Set<CanvasProviderCapability>.self, forKey: .capabilities)
        self.configurationFingerprint = try container.decode(String.self, forKey: .configurationFingerprint)
        try validate()
    }

    public func validate() throws {
        try CanvasSchema.requireNonEmpty(providerID, "providerID")
        try CanvasSchema.requireNonEmpty(modelID, "modelID")
        try CanvasSchema.requireNonEmpty(configurationFingerprint, "configurationFingerprint")
    }

    public var isValid: Bool { (try? validate()) != nil }
}
