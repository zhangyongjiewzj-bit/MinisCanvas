import Foundation

/// 一次迁移的结果。
public struct SettingsMigrationResult: Sendable {
    /// 迁移（或原样）后的设置。
    public let settings: AppSettings
    /// 是否发生了实际迁移（版本号提升或 provider reference 被规范化）。
    public let migrated: Bool
    /// Typed provenance for diagnostics and reopen projections.  It never
    /// contains a credential value.
    public let provenance: SettingsMigrationProvenance
}

public struct SettingsMigrationProvenance: Sendable, Equatable, Codable {
    public let fromVersion: Int
    public let toVersion: Int
    public let normalizedLegacyReferences: [String]

    public var isMonotonic: Bool { toVersion >= fromVersion }
    public var didNormalizeLegacyReferences: Bool { !normalizedLegacyReferences.isEmpty }

    public init(
        fromVersion: Int,
        toVersion: Int,
        normalizedLegacyReferences: [String] = []
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.normalizedLegacyReferences = normalizedLegacyReferences
    }
}

public enum SettingsMigrationError: Error, Sendable, Equatable {
    case invalidSchemaVersion(Int)
    case ambiguousLegacyValue(String)
}

/// 设置 schema 版本迁移。
///
/// 加载流程：先以宽容解码（缺失字段回落默认值）读入 `AppSettings`，
/// 再按 `settingsVersion` 逐版本补齐新字段默认值并提升版本号。
///
/// - v1 → v2：新增 `agent.concurrentToolLimit`（4）、
///   `agent.autoCompactThreshold`（0.8）、`agent.fallbackEnabled`（true）、
///   `storage.memoryLimitMB`（nil）、`storage.autoDeleteOldSessions`（false）。
///   （E19 `general.modelSpeedTier` 由宽容解码兜底默认值，无需 bump 版本。）
/// - v2 → v3：新增 `typography.uiBaseFontSize`（14）。
/// - v3 → v4：新增 `general.themePreset`，并把旧的
///   `general.appearance` × `general.accentTheme` 任意组合收敛为
///   该预设的派生投影（SETTINGS-27 / THEME-01 / THEME-05）。
public enum SettingsMigration {
    /// Stable provider identity used by the settings boundary.  This is a
    /// route/record identity, not a generated EnvVarEntry UUID.
    public static let deepSeekProviderID = "deepseek"

    /// Typed, finite aliases accepted from pre-successor settings.  The
    /// values are references only; no credential value is carried by this
    /// migration layer.
    public enum DeepSeekCredentialAlias: String, CaseIterable, Codable, Sendable {
        case official = "DEEPSEEK_API_KEY"
        case hermesCustom = "HERMES_CUSTOM_DEEPSEEK_API_KEY"

        public var providerID: String { SettingsMigration.deepSeekProviderID }
    }

    /// The provider-scoped namespace used by `ProviderModelReference` for the
    /// built-in DeepSeek route.  Keeping it explicit prevents a legacy env-var
    /// name from being interpreted as a newly generated custom-record ID.
    public static let deepSeekTypedProviderID = "builtin.deepSeek"

    private static let metadataAliasKey = "credentialAlias"
    private static let metadataAliasesKey = "credentialAliases"
    private static let metadataReferenceKey = "credentialReference"
    private static let metadataSecretReferenceKey = "secretReference"
    private static let safeProviderMetadataKeys: Set<String> = [
        "baseurl", "model", "modelnames", "models", "protocol", "protocoltype",
        "label", "displayname", "enabled", "timeout", "resolution", "duration"
    ]

    /// 从 JSON 数据解码并迁移到当前版本。
    public static func migrate(data: Data) throws -> SettingsMigrationResult {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        let from = decoded.settingsVersion
        guard from > 0 else { throw SettingsMigrationError.invalidSchemaVersion(from) }
        try rejectAmbiguousLegacyValues(in: decoded)
        let legacyReferences = legacyReferenceNames(in: decoded)
        let migrated = applyingMigrations(to: decoded, fromVersion: from)
        let provenance = SettingsMigrationProvenance(
            fromVersion: from,
            toVersion: migrated.settingsVersion,
            normalizedLegacyReferences: migrated != decoded ? legacyReferences : []
        )
        return SettingsMigrationResult(
            settings: migrated,
            // Provider reference normalization is a migration even when the
            // surrounding schema version stays unchanged.
            migrated: migrated != decoded,
            provenance: provenance
        )
    }

    /// 逐版本应用迁移步骤。
    ///
    /// 宽容解码已保证新字段在旧 JSON 中取到默认值；这里显式写出
    /// v1→v2 的补默认值步骤，作为 schema 演进的文档与测试锚点。
    public static func applyingMigrations(
        to settings: AppSettings,
        fromVersion: Int
    ) -> AppSettings {
        var result = settings
        var version = max(fromVersion, 1)

        if version < 2 {
            // v1 → v2：补齐 v2 引入字段的默认值。
            result.agent.concurrentToolLimit = AgentSettings.default.concurrentToolLimit
            result.agent.autoCompactThreshold = AgentSettings.default.autoCompactThreshold
            result.agent.fallbackEnabled = AgentSettings.default.fallbackEnabled
            result.storage.memoryLimitMB = StorageSettings.default.memoryLimitMB
            result.storage.autoDeleteOldSessions = StorageSettings.default.autoDeleteOldSessions
            version = 2
        }

        if version < 3 {
            // v2 → v3：补齐 UX-01 排版设置，同时保留旧 payload 中已经
            // 出现的字号。AppSettings 的宽容解码已将缺失值设为 14，
            // TypographySettings 再次收敛越界值，因而迁移始终有界。
            result.typography = TypographySettings(
                uiBaseFontSize: result.typography.uiBaseFontSize
            )
            version = 3
        }

        if version < 4 {
            // v3 → v4：SETTINGS-27 / THEME-01 / THEME-05 外观收敛。
            //
            // 宽容解码已经把 themePreset 从旧「外观模式 × 主题色」组合
            // 映射出来（见 GeneralSettings.init(from:)）；这里把它固化为
            // 唯一真值，并把两个旧字段重投影成该预设的派生值。重投影是
            // 幂等的：再次执行只会写回同一组值，因此同一 payload 重复迁移
            // 不会继续漂移。未验收预设（高对比）永不成为迁移目标。
            result.general.setThemePreset(ThemePreset.nearest(
                for: result.general.appearance,
                accentTheme: result.general.accentTheme
            ))
            version = 4
        }

        result.settingsVersion = version
        migrateDeepSeekReferences(in: &result)
        return result
    }

    /// Normalize only the two reviewed DeepSeek credential aliases.  This is
    /// deliberately a pure projection over metadata: it never reads a
    /// Keychain, creates a credential, copies a secret, or invents a random
    /// record ID.
    @discardableResult
    private static func migrateDeepSeekReferences(in settings: inout AppSettings) -> Bool {
        var changed = false

        if let providerID = settings.general.defaultProviderID,
           isDeepSeekReference(providerID),
           providerID != deepSeekProviderID {
            settings.general.defaultProviderID = deepSeekProviderID
            changed = true
        }

        if let reference = settings.general.subModelReference,
           isDeepSeekReference(reference.providerID),
           reference.providerID != deepSeekTypedProviderID {
            settings.general.subModelReference = ProviderModelReference(
                providerID: deepSeekTypedProviderID,
                modelID: reference.modelID
            )
            changed = true
        }

        var providerSettings = settings.providerSettings
        let legacyKeys = providerSettings.keys.filter { isDeepSeekReference($0) }
        guard !legacyKeys.isEmpty else { return changed }

        var stableMetadata = providerSettings[deepSeekProviderID] ?? [:]
        for legacyKey in legacyKeys {
            guard let legacyMetadata = providerSettings.removeValue(forKey: legacyKey) else { continue }
            for (key, value) in legacyMetadata {
                let normalizedKey = key.lowercased()
                if normalizedKey == "apikeyenvvar" || normalizedKey == metadataAliasKey.lowercased()
                    || normalizedKey == metadataReferenceKey.lowercased()
                    || normalizedKey == metadataSecretReferenceKey.lowercased() {
                    // Keep a typed alias only; arbitrary values are not
                    // accepted as credential references.
                    if let alias = DeepSeekCredentialAlias(rawValue: value) {
                        stableMetadata[metadataReferenceKey] = alias.rawValue
                        stableMetadata[metadataSecretReferenceKey] = alias.rawValue
                    }
                    continue
                }
                if normalizedKey.contains("apikey") || normalizedKey.contains("secret")
                    || normalizedKey.contains("token") || normalizedKey == "value" {
                    // Secret-shaped metadata is discarded rather than copied.
                    continue
                }
                if safeProviderMetadataKeys.contains(normalizedKey) {
                    stableMetadata[key] = value
                }
            }
        }
        stableMetadata[metadataAliasKey] = DeepSeekCredentialAlias.official.rawValue
        stableMetadata[metadataAliasesKey] = DeepSeekCredentialAlias.allCases
            .map(\.rawValue)
            .joined(separator: ",")
        // Keep the canonical reference deterministic. The reviewed aliases are
        // retained in `credentialAliases`; the secret itself is never copied.
        stableMetadata[metadataReferenceKey] = DeepSeekCredentialAlias.official.rawValue
        stableMetadata[metadataSecretReferenceKey] = DeepSeekCredentialAlias.official.rawValue
        stableMetadata["recordID"] = deepSeekProviderID
        providerSettings[deepSeekProviderID] = stableMetadata
        if providerSettings != settings.providerSettings {
            settings.providerSettings = providerSettings
            changed = true
        }
        return changed
    }

    private static func legacyReferenceNames(in settings: AppSettings) -> [String] {
        var references: [String] = []
        if let providerID = settings.general.defaultProviderID,
           isDeepSeekReference(providerID), providerID != deepSeekProviderID {
            references.append(providerID)
        }
        if let reference = settings.general.subModelReference,
           isDeepSeekReference(reference.providerID), reference.providerID != deepSeekTypedProviderID {
            references.append(reference.providerID)
        }
        references.append(contentsOf: settings.providerSettings.keys.filter {
            isDeepSeekReference($0) && $0 != deepSeekProviderID
        })
        return Array(Set(references)).sorted()
    }

    /// Legacy credential metadata is accepted only when its value is one of
    /// the reviewed typed aliases.  Silently selecting the official alias
    /// from an arbitrary value would make migration non-deterministic.
    private static func rejectAmbiguousLegacyValues(in settings: AppSettings) throws {
        for providerKey in settings.providerSettings.keys where isDeepSeekReference(providerKey) {
            guard let metadata = settings.providerSettings[providerKey] else { continue }
            var aliases: Set<String> = []
            for (key, value) in metadata {
                let normalizedKey = key.lowercased()
                let isCredentialField = normalizedKey == "apikeyenvvar"
                    || normalizedKey == metadataAliasKey.lowercased()
                    || normalizedKey == metadataReferenceKey.lowercased()
                    || normalizedKey == metadataSecretReferenceKey.lowercased()
                guard isCredentialField else { continue }
                guard DeepSeekCredentialAlias(rawValue: value) != nil else {
                    throw SettingsMigrationError.ambiguousLegacyValue("providerSettings.\(providerKey).\(key)")
                }
                aliases.insert(value)
            }
            guard aliases.count <= 1 else {
                throw SettingsMigrationError.ambiguousLegacyValue("providerSettings.\(providerKey).credentialReference")
            }
        }
    }

    private static func isDeepSeekReference(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if DeepSeekCredentialAlias(rawValue: trimmed) != nil { return true }
        let lowercased = trimmed.lowercased()
        return lowercased == deepSeekProviderID
            || lowercased == "deepseekprovider"
            || lowercased == "builtin.deepseek"
            || lowercased == "builtin.deepseekprovider"
            || lowercased == "custom.deepseek"
            || lowercased == "custom.deepseek_api_key"
            || lowercased == "custom.hermes_custom_deepseek_api_key"
    }
}
