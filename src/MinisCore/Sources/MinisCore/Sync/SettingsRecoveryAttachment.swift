import Foundation

/// Only preferences that can be restored without a credential or authority.
/// This is an attachment to the existing `.settings` SyncScope, not a new scope.
public struct SettingsRecoveryAttachment: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let shortcutDefaultsKey = "miniscanvas.shortcuts.v1"

    public let version: Int
    public let providers: [ProviderRecoveryMetadata]
    public let shortcutOverrides: [ShortcutRecoveryOverride]

    public init(providers: [ProviderRecoveryMetadata], shortcutOverrides: [ShortcutRecoveryOverride]) throws {
        version = Self.currentVersion
        self.providers = providers
        self.shortcutOverrides = shortcutOverrides
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case version, providers, shortcutOverrides }

    public init(from decoder: Decoder) throws {
        try SettingsRecoveryCoding.rejectUnknown(decoder, allowed: ["version", "providers", "shortcutOverrides"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.version), values.contains(.providers), values.contains(.shortcutOverrides) else {
            throw SettingsRecoveryAttachmentError.invalidFields
        }
        version = try values.decode(Int.self, forKey: .version)
        providers = try values.decode([ProviderRecoveryMetadata].self, forKey: .providers)
        shortcutOverrides = try values.decode([ShortcutRecoveryOverride].self, forKey: .shortcutOverrides)
        try validate()
    }

    public func validate() throws {
        guard version == Self.currentVersion else { throw SettingsRecoveryAttachmentError.unsupportedVersion }
        guard providers.count <= 256, shortcutOverrides.count <= 256 else {
            throw SettingsRecoveryAttachmentError.invalidFields
        }
        var providerIDs = Set<String>()
        var providerNames = Set<String>()
        for provider in providers {
            try provider.validate()
            guard providerIDs.insert(provider.id.lowercased()).inserted,
                  providerNames.insert(provider.name).inserted else {
                throw SettingsRecoveryAttachmentError.duplicateIdentity
            }
        }
        var actions = Set<String>()
        for override in shortcutOverrides {
            try override.validateShape()
            guard actions.insert(override.actionID).inserted else {
                throw SettingsRecoveryAttachmentError.duplicateIdentity
            }
        }
    }
}

/// App-side canonical validation prepares these exact target-domain bytes.
/// Source snapshots contain only `ShortcutRecoveryOverride`, never this plan,
/// the target suite, or old approved-effect records.
public struct ShortcutRecoveryPlan: Sendable {
    public let suiteName: String?
    public let beforeData: Data?
    public let afterData: Data

    public init(suiteName: String?, beforeData: Data?, afterData: Data) {
        self.suiteName = suiteName
        self.beforeData = beforeData
        self.afterData = afterData
    }
}

/// The exact UserDefaults instance already owned by App composition. Core
/// journals one fixed key and reopens the same suite before Store construction.
public final class ShortcutRecoveryTarget: @unchecked Sendable {
    public let defaults: UserDefaults
    public let suiteName: String?

    public init(defaults: UserDefaults, suiteName: String?) {
        self.defaults = defaults
        self.suiteName = suiteName
    }
}

public enum SettingsRecoveryAttachmentError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidFields
    case duplicateIdentity
    case invalidProvider
    case invalidShortcut
}

/// Six safe fields plus the optional per-model context windows (C8); `EnvVarEntry`
/// value, Keychain linkage and readiness do not have a representation in this
/// type or its encoder.
public struct ProviderRecoveryMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let baseURL: String?
    public let modelNames: [String]
    public let protocolType: ProviderWireProtocol
    /// Absent in snapshots written before C8; nil restores as "no custom windows".
    public let modelContextWindows: [String: Int]?

    public init(id: String, name: String, createdAt: Date, baseURL: String?,
                modelNames: [String], protocolType: ProviderWireProtocol,
                modelContextWindows: [String: Int]? = nil) throws {
        self.id = id; self.name = name; self.createdAt = createdAt
        self.baseURL = baseURL; self.modelNames = modelNames; self.protocolType = protocolType
        self.modelContextWindows = modelContextWindows
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, baseURL, modelNames, protocolType, modelContextWindows
        static let allRequired: [Self] = [.id, .name, .createdAt, .baseURL, .modelNames, .protocolType]
    }

    public init(from decoder: Decoder) throws {
        try SettingsRecoveryCoding.rejectUnknown(
            decoder, allowed: ["id", "name", "createdAt", "baseURL", "modelNames", "protocolType", "modelContextWindows"]
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard CodingKeys.allRequired.allSatisfy(values.contains) else {
            throw SettingsRecoveryAttachmentError.invalidFields
        }
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL)
        modelNames = try values.decode([String].self, forKey: .modelNames)
        let wire = try values.decode(String.self, forKey: .protocolType)
        guard let protocolType = ProviderWireProtocol(rawValue: wire) else {
            throw SettingsRecoveryAttachmentError.invalidProvider
        }
        self.protocolType = protocolType
        modelContextWindows = try values.decodeIfPresent([String: Int].self, forKey: .modelContextWindows)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(createdAt, forKey: .createdAt)
        if let baseURL { try values.encode(baseURL, forKey: .baseURL) }
        else { try values.encodeNil(forKey: .baseURL) }
        try values.encode(modelNames, forKey: .modelNames)
        try values.encode(protocolType.rawValue, forKey: .protocolType)
        try values.encodeIfPresent(modelContextWindows, forKey: .modelContextWindows)
    }

    public func validate() throws {
        if let modelContextWindows {
            guard !modelContextWindows.isEmpty,
                  modelContextWindows.allSatisfy({ modelNames.contains($0.key) && $0.value > 0 }) else {
                throw SettingsRecoveryAttachmentError.invalidProvider
            }
        }
        guard UUID(uuidString: id) != nil,
              name == EnvVarStore.canonicalName(name), EnvVarStore.isValidName(name),
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              modelNames.count <= 256,
              modelNames.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw SettingsRecoveryAttachmentError.invalidProvider
        }
        if let baseURL {
            guard !baseURL.isEmpty, baseURL == baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                  baseURL.utf8.count <= 4_096,
                  (try? ProviderEndpointPolicy.canonicalize(baseURL)) != nil else {
                throw SettingsRecoveryAttachmentError.invalidProvider
            }
        }
        guard baseURL != nil || !modelNames.isEmpty else {
            throw SettingsRecoveryAttachmentError.invalidProvider
        }
    }
}

/// An App-owned known action and its user override; defaults and source-side
/// approval history are deliberately absent. The App ShortcutStore validates
/// the complete table against canonical key and collision rules.
public struct ShortcutRecoveryOverride: Codable, Equatable, Sendable {
    public let actionID: String
    public let key: String
    public let command: Bool
    public let control: Bool
    public let option: Bool
    public let shift: Bool

    public init(actionID: String, key: String, command: Bool, control: Bool, option: Bool, shift: Bool) {
        self.actionID = actionID; self.key = key; self.command = command
        self.control = control; self.option = option; self.shift = shift
    }

    private enum CodingKeys: String, CodingKey {
        case actionID, key, command, control, option, shift
        static let allCases: [Self] = [.actionID, .key, .command, .control, .option, .shift]
    }

    public init(from decoder: Decoder) throws {
        try SettingsRecoveryCoding.rejectUnknown(
            decoder, allowed: ["actionID", "key", "command", "control", "option", "shift"]
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard CodingKeys.allCases.allSatisfy(values.contains) else {
            throw SettingsRecoveryAttachmentError.invalidFields
        }
        actionID = try values.decode(String.self, forKey: .actionID)
        key = try values.decode(String.self, forKey: .key)
        command = try values.decode(Bool.self, forKey: .command)
        control = try values.decode(Bool.self, forKey: .control)
        option = try values.decode(Bool.self, forKey: .option)
        shift = try values.decode(Bool.self, forKey: .shift)
        try validateShape()
    }

    public func validateShape() throws {
        guard !actionID.isEmpty, actionID.utf8.count <= 128,
              actionID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              key.utf8.count <= 32,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SettingsRecoveryAttachmentError.invalidShortcut
        }
    }
}

private enum SettingsRecoveryCoding {
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func rejectUnknown(_ decoder: Decoder, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw SettingsRecoveryAttachmentError.invalidFields
        }
    }
}
