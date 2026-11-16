import Foundation
import CryptoKit
import MinisCore

/// Secret-free validation failures for the chat-internal provider editor.
/// These cases intentionally do not carry the rejected input, so diagnostics
/// cannot accidentally echo a credential or a URL containing userinfo.
public enum ChatProviderSettingsValidationError: Error, Equatable, Sendable {
    case emptyProviderID
    case invalidProviderID
    case emptyModelList
    case invalidModelID
    case invalidBaseURL
    case unsupportedProtocol
    case emptyRevision
    case emptyRequestID
    case emptyCredentialHandle
}

/// A typed, reviewable provider edit. The credential is represented only by
/// the existing BL6 opaque-handle contract; no raw key can enter this value.
public struct ChatProviderSettingsPreview: Codable, Equatable, Sendable {
    public let requestID: String
    public let providerID: String
    public let baseURL: String
    public let modelIDs: [String]
    public let protocolType: ProviderWireProtocol
    public let credential: BL6ProviderCredentialMutation
    public let expectedRevision: String
    /// Metadata CAS fence. Nil is allowed for callers that intentionally edit
    /// a provider that did not exist when the preview was created.
    public let expectedProviderRevision: String?

    public init(
        requestID: String = UUID().uuidString,
        providerID: String,
        baseURL: String,
        modelIDs: [String],
        protocolType: ProviderWireProtocol,
        credential: BL6ProviderCredentialMutation = .keepExisting,
        expectedRevision: String,
        expectedProviderRevision: String? = nil
    ) throws {
        let requestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestID.isEmpty else { throw ChatProviderSettingsValidationError.emptyRequestID }
        let providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty else { throw ChatProviderSettingsValidationError.emptyProviderID }
        guard providerID.count <= 128,
              providerID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
        else { throw ChatProviderSettingsValidationError.invalidProviderID }
        let models = modelIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !models.isEmpty else { throw ChatProviderSettingsValidationError.emptyModelList }
        guard models.allSatisfy({ !$0.isEmpty && $0.count <= 256 && $0.allSatisfy { !$0.isNewline && !$0.isWhitespace } })
        else { throw ChatProviderSettingsValidationError.invalidModelID }
        guard Set(models).count == models.count else { throw ChatProviderSettingsValidationError.invalidModelID }
        guard let safeURL = try? CustomProviderURL.validate(baseURL) else {
            throw ChatProviderSettingsValidationError.invalidBaseURL
        }
        let expectedRevision = expectedRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedRevision.isEmpty else { throw ChatProviderSettingsValidationError.emptyRevision }
        let expectedProviderRevision = expectedProviderRevision?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expectedProviderRevision, expectedProviderRevision.isEmpty {
            throw ChatProviderSettingsValidationError.emptyRevision
        }
        if case let .opaqueHandle(handle) = credential,
           handle.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ChatProviderSettingsValidationError.emptyCredentialHandle
        }
        self.requestID = requestID
        self.providerID = providerID
        self.baseURL = safeURL.absoluteString
        self.modelIDs = models
        self.protocolType = protocolType
        self.credential = credential
        self.expectedRevision = expectedRevision
        self.expectedProviderRevision = expectedProviderRevision
    }
}

/// Reopen projection for the chat provider editor. It is deliberately made
/// from metadata only; `EnvVarEntry.value` is never inspected here.
public struct ChatProviderSettingsReopenProjection: Codable, Equatable, Sendable {
    public let providerID: String
    public let baseURL: String
    public let modelIDs: [String]
    public let protocolType: ProviderWireProtocol
    public let credentialPresent: Bool
    public let metadataRevision: String

    public init(
        providerID: String,
        baseURL: String,
        modelIDs: [String],
        protocolType: ProviderWireProtocol,
        credentialPresent: Bool
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.modelIDs = modelIDs
        self.protocolType = protocolType
        self.credentialPresent = credentialPresent
        self.metadataRevision = [
            providerID, baseURL, protocolType.rawValue,
            modelIDs.joined(separator: ","), credentialPresent ? "1" : "0"
        ].joined(separator: "|")
    }

    init(entry: EnvVarEntry) {
        self.init(
            providerID: entry.name,
            baseURL: entry.baseURL ?? "",
            modelIDs: entry.modelNames,
            protocolType: entry.protocolType,
            // Presence is inferred from the Keychain-backed metadata bit;
            // the potentially sensitive in-memory value is never read.
            credentialPresent: entry.valueInKeychain
        )
    }
}

/// Metadata-only rollback token. A credential change is never silently
/// reversed because the previous secret is intentionally unavailable here.
public struct ChatProviderSettingsRollbackToken: Codable, Equatable, Sendable {
    public let providerID: String
    public let previous: ChatProviderSettingsReopenProjection?
    public let expectedProviderRevision: String?
    public let expectedSettingsRevision: String

    public init(
        providerID: String,
        previous: ChatProviderSettingsReopenProjection?,
        expectedSettingsRevision: String
    ) {
        self.providerID = providerID
        self.previous = previous
        self.expectedProviderRevision = previous?.metadataRevision
        self.expectedSettingsRevision = expectedSettingsRevision
    }
}

/// Secret-free reopen/retry state for provider configuration errors.
public enum ChatProviderSettingsRecoveryState: String, Codable, Equatable, Sendable {
    case retryable
    case reopenRequired
    case blockedTransactionUnknown
}

public enum ChatProviderSettingsRollbackError: Error, Equatable, Sendable {
    case credentialStateChanged
    case metadataChanged
    case dispatch(BL6SettingsDispatchError)
}

// MARK: - P3-UI-02（N-UI02-WIRE）主题预设目录消费适配器

/// `ThemePresetCatalog` / `ThemePresetCatalogMigration`（MinisCore，
/// BATCH1 unit 10 / DEV-245 落头）在 BL6 typed-settings 双腿上的 App 侧
/// 消费适配器：投影腿（`publishedThemePresetValue`）与收敛腿
/// （`convergedAppearancePreset`，BL6SettingsCenterDispatch 的
/// general.theme-preset 派发段调用）。
///
/// 硬约束遵循（派工单 §3）：
/// - 不发明豁免：`ThemePresetCatalog.darkBranchAdjudication` /
///   `systemBranchAdjudication` 的 `.pending` 裁决状态原样保留。迁移的
///   `.fixedDark` / `.systemMirror` / `.fixedHighContrast` 只还原外观预设（ThemePreset
///   明暗轴），不推导任何暗侧色值，也不新增 12% 之外的占比规则。
/// - 不发明色值：只消费目录既有定义（`selectableIDs` / `entry(for:)` /
///   `migrate`）。warmCoralA7A 在目录中 `lightAccent == nil`
///   （pendingColorMaterial），因此恒不在 `selectableIDs` 内，本适配器
///   永不为它具色。
/// - `.pending` 下失败关闭：`rejected`、`indeterminate`（无明确分支）、
///   目录外预设一律落到旧组合确定性映射（`ThemePreset.nearest`），
///   与原 `ThemePreset.converging` 语义逐输入一致，绝不静默给未批准材料。
enum BL6ThemePresetCatalogConsumer {
    /// 投影腿：发布 `general.theme-preset` 的存储词。
    ///
    /// 1115用户范围：发布仅产品 light 与原生 system。
    /// 历史 dark/highContrast 分支仍可识别，但只投影为 system，
    /// 不能借旧命令或持久化词重新发布退休主题。
    static func publishedThemePresetValue(for preset: ThemePreset) -> String {
        let migrated = ThemePresetCatalogMigration.migrate(storedValue: preset.rawValue)
        guard migrated.status == .migrated,
              let catalogID = migrated.presetID,
              ThemePresetCatalog.selectableIDs.contains(catalogID),
              let branch = migrated.branch else {
            return preset.rawValue
        }
        switch branch {
        case .fixedLight: return ThemePreset.light.rawValue
        case .fixedDark: return ThemePreset.system.rawValue
        case .systemMirror: return ThemePreset.system.rawValue
        case .fixedHighContrast: return ThemePreset.system.rawValue
        case .indeterminate: return preset.rawValue
        }
    }

    /// 收敛腿：把入站 `general.theme-preset` 存储值经目录迁移全函数收敛为
    /// 外观预设。
    ///
    /// 与原 `ThemePreset.converging(raw, fallback: nearest(旧组合))` 对照：
    /// - 键缺失 / 空值 / `rejected` / `alreadyCurrent`（目录规范词不含明暗
    ///   轴）/ `indeterminate` → 与原先相同，落到 `nearest` 确定性映射；
    /// - 旧外观存储值 → 保留历史迁移分支，当前预设收敛为 light/system；
    /// - 新增识别（canonical `:361`「旧值迁移」验收腿）：`"<appearance>|
    ///   <accent>"` 形态的旧 18 组合串被目录迁移识别并携带中性明暗分支，
    ///   据此还原外观预设，与「显式预设键优先于旧组合推导」的既有
    ///     lane 125 终态语义一致，而不是当作不可解析值丢弃。
    /// `.highContrast` 显式词经 fixedHighContrast 识别后收敛为 system；
    /// `migrated` 结果还必须命中 `selectableIDs`（当前仅
    /// keylineOrangeA7A）才被采信，目录外预设失败关闭。
    static func convergedAppearancePreset(
        storedRawValue raw: String?,
        legacyAppearance appearance: Appearance,
        legacyAccentTheme accentTheme: AccentTheme
    ) -> ThemePreset {
        let fallback = ThemePreset.nearest(for: appearance, accentTheme: accentTheme)
        guard let raw, !raw.isEmpty else { return fallback }
        let migrated = ThemePresetCatalogMigration.migrate(storedValue: raw)
        guard migrated.status == .migrated,
              let catalogID = migrated.presetID,
              ThemePresetCatalog.selectableIDs.contains(catalogID),
              let branch = migrated.branch else {
            return fallback
        }
        switch branch {
        case .fixedLight: return .light
        case .fixedDark: return .system
        case .systemMirror: return .system
        case .fixedHighContrast: return .system
        case .indeterminate: return fallback
        }
    }
}

/// SettingsCenter's single BL6 projection consumer. It exposes effective,
/// typed values while reducing every credential entry to presence metadata.
extension SettingsCenter {
    /// Read the currently persisted provider configuration without touching a
    /// credential. This is the sole reopen projection consumed by chat.
    func chatProviderSettingsProjection(providerID: String) -> ChatProviderSettingsReopenProjection? {
        guard let entry = providerRecords.first(where: {
            $0.name.caseInsensitiveCompare(providerID) == .orderedSame && $0.isProviderRecord
        }) else {
            return nil
        }
        return ChatProviderSettingsReopenProjection(entry: entry)
    }

    /// Per-record directory from the same persisted projection as the local
    /// provider editor. URLs and its raw revision never cross this boundary;
    /// neither a credential resolver nor an environment-value read is used.
    /// The approved model writer still rejects configure_provider.
    func conversationProviderRecordDirectory() throws -> [String: BL6SettingValue] {
        var values: [String: BL6SettingValue] = [:]
        var admittedNames = Set<String>()
        for entry in providerRecords.sorted(by: { $0.id < $1.id }) {
            guard entry.isProviderRecord,
                  admittedNames.insert(entry.name.lowercased()).inserted,
                  let projection = chatProviderSettingsProjection(providerID: entry.name),
                  projection.providerID == entry.name else {
                throw ConversationSettingsToolError.ownerUnavailable
            }
            let identity = SHA256.hash(data: Data(entry.id.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let id = "provider.record." + identity
            guard values[id] == nil else { throw ConversationSettingsToolError.ownerUnavailable }
            let revision = SHA256.hash(data: Data(projection.metadataRevision.utf8))
                .map { String(format: "%02x", $0) }.joined()
            values[id] = .object([
                "providerID": .text(projection.providerID),
                "modelIDs": .list(projection.modelIDs),
                "protocolType": .text(projection.protocolType.rawValue),
                "credential": .redactedSecret(present: projection.credentialPresent),
                "metadataRevision": .text(revision)
            ])
        }
        return values
    }

    /// Capture the metadata/settings fences before showing the confirmation
    /// surface. A missing provider is a valid snapshot and is represented by
    /// `previous == nil`, never by an empty or synthetic secret value.
    func captureChatProviderSettingsRollbackToken(
        providerID: String
    ) -> Result<ChatProviderSettingsRollbackToken, BL6SettingsDispatchError> {
        guard let snapshot = bl6EffectiveSettingsSnapshot else {
            return .failure(.invalidIntent("effective settings unavailable"))
        }
        return .success(ChatProviderSettingsRollbackToken(
            providerID: providerID,
            previous: chatProviderSettingsProjection(providerID: providerID),
            expectedSettingsRevision: snapshot.catalogRevision
        ))
    }

    /// Canonical P3-SET-01 projection. It is built directly from the
    /// observable settings mirror (never a ChatStore cache); nested settings
    /// remain typed objects and credential values are presence-only.
    func bl6Values(
        from s: AppSettings,
        credentialPresent: Bool
    ) -> [String: BL6SettingValue] {
        let g = s.general
        let a = s.agent
        let p = s.privacy
        let st = s.storage
        let b = s.browser
        let persona: BL6SettingValue = .object([
            "name": .text(a.persona.name),
            "summary": .text(a.persona.summary),
            "tone": .text(a.persona.tone),
            "abilities": .text(a.persona.abilities)
        ])
        let composer: BL6SettingValue = .object([
            "mode": .text(a.composerPolicy.mode.rawValue),
            "approvalScope": .text(a.composerPolicy.approvalScope.rawValue),
            "effort": .text(a.composerPolicy.effort.rawValue),
            "bypassModeConfirmed": .toggle(a.composerPolicy.bypassModeConfirmed)
        ])
        let runtime: BL6SettingValue = .object([
            "budget": .integer(max(0, a.policyRuntimeDefaults.budget)),
            "deadlineHorizon": .decimal(max(0, a.policyRuntimeDefaults.deadlineHorizon)),
            "autonomyLevel": .integer(a.policyRuntimeDefaults.autonomyLevel.rawValue),
            "networkDomains": .list(a.policyRuntimeDefaults.networkDomains.sorted())
        ])
        let terminalPolicy = a.terminalPolicy.normalized()
        let terminal: BL6SettingValue = .object([
            "automaticAllowCommands": .list(terminalPolicy.automaticAllowCommands),
            "confirmationCommands": .list(terminalPolicy.confirmationCommands),
            "userDeniedCommands": .list(terminalPolicy.userDeniedCommands),
            "explicitConfirmationCommands": .list(terminalPolicy.explicitConfirmationCommands),
            "confirmationProvenanceVersion": .integer(terminalPolicy.confirmationProvenanceVersion ?? 0)
        ])
        let reference = g.subModelReference.map { "\($0.providerID)/\($0.modelID)" } ?? ""
        return [
            // SETTINGS-27/THEME-01 consumer contract (lanes 125 + 140): the converged
            // preset is published below as a first-class typed-settings key
            // `"general.theme-preset": .text(g.themePreset.rawValue)` instead of only
            // through its two legacy projections. The value has a single source of
            // truth, `ThemePreset.rawValue` on the live model; no literal is authored
            // here. The key is registered in BL6SettingsCatalog.production (MinisCore
            // BL6TypedConversationSettings.swift) and counted by the
            // BL6TypedConversationSettingsProductionTests pins in the same unit:
            // effectiveSnapshot fails closed in BOTH directions (unknownSetting for a
            // projected key the catalog lacks, missingSetting for a catalog entry the
            // projection omits) and either single-sided edit permanently locks
            // bl6SettingsSnapshotGuard and closes the P3-SET-01 boundary for the
            // session, so all three must stay coordinated.
            //
            // P3-UI-02 (N-UI02-WIRE): the emitted value now reads preset
            // semantics through the catalog — `ThemePresetCatalogMigration`
            // round-trips the live preset and republishes the branch-neutral
            // appearance word, so every accepted-preset pin above is
            // byte-identical while production provably consumes the catalog.
            // Fail-closed pass-through preserves `ThemePreset.rawValue` on the
            // live model as the single source of truth for anything the v1
            // catalog does not migrate (no literal is authored here).
            "general.appearance": .text(g.appearance.rawValue),
            "general.accent-theme": .text(g.accentTheme.rawValue),
            "general.theme-preset": .text(
                BL6ThemePresetCatalogConsumer.publishedThemePresetValue(for: g.themePreset)
            ),
            "general.default-provider-id": .text(g.defaultProviderID ?? ""),
            "general.default-model-id": .text(g.defaultModelID ?? ""),
            "general.sub-model-reference": .text(reference),
            "general.model-speed-tier": .text(g.modelSpeedTier.rawValue),
            "general.chat-output-mode": .text(g.chatOutputMode.rawValue),
            "general.language": .text(g.language),
            "agent.max-loop-iterations": .integer(a.maxLoopIterations),
            "agent.tool-timeout-seconds": .integer(a.toolTimeoutSeconds),
            "agent.concurrent-tool-limit": .integer(a.concurrentToolLimit),
            "agent.child-concurrency-user-selected": .integer(a.childConcurrencyUserSelected),
            "agent.child-concurrency-enabled-session-count": .integer(a.childConcurrencyEnabledSessionCount),
            "agent.auto-compact-threshold": .decimal(a.autoCompactThreshold),
            "agent.fallback-enabled": .toggle(a.fallbackEnabled),
            "agent.persona-enabled": .toggle(a.personaEnabled),
            "agent.persona-preset": .text(a.personaPreset.rawValue),
            "agent.persona": persona,
            "agent.memory-enabled": .toggle(a.memoryEnabled),
            "agent.approval-policy": .text(a.approvalPolicy.rawValue),
            "agent.available-model-whitelist": .list(a.availableModelWhitelist),
            "agent.new-message-interrupts-generation": .toggle(a.newMessageInterruptsGeneration),
            "agent.composer-policy": composer,
            "agent.policy-runtime-defaults": runtime,
            "agent.terminal-policy": terminal,
            "privacy.redact-env-values": .toggle(p.redactEnvValues),
            "privacy.log-level": .text(p.logLevel.rawValue),
            "privacy.collect-analytics": .toggle(p.collectAnalytics),
            "privacy.allowed-root-path": .text(p.allowedRootPath ?? ""),
            "privacy.denied-root-paths": .list(p.deniedRootPaths),
            "privacy.mounted-folder-paths": .list(p.mountedFolderPaths),
            "storage.session-retention-days": .integer(st.sessionRetentionDays),
            "storage.memory-limit-mb": .integer(st.memoryLimitMB ?? 0),
            "storage.auto-delete-old-sessions": .toggle(st.autoDeleteOldSessions),
            "browser.user-agent-preset": .text(b.userAgentPreset.rawValue),
            "browser.custom-user-agent": .text(b.customUserAgent),
            "browser.viewport-mode": .text(b.viewportMode.rawValue),
            "browser.custom-viewport-width": .integer(b.customViewportWidth),
            "browser.custom-viewport-height": .integer(b.customViewportHeight),
            "browser.idle-tab-timeout-minutes": .integer(b.idleTabTimeoutMinutes),
            "typography.ui-base-font-size": .integer(s.typography.uiBaseFontSize),
            "credential.provider-api-key": .redactedSecret(present: credentialPresent)
        ]
    }

    fileprivate var bl6ProjectedValues: [String: BL6SettingValue] {
        let hasProviderCredential = providerRecords.contains {
            // `value` may contain a legacy plaintext credential.  The BL6
            // projection is metadata-only, so presence is derived solely from
            // the persisted Keychain ownership bit and never from bytes.
            $0.isProviderRecord && $0.valueInKeychain
        }
        return bl6Values(from: settingsMirror, credentialPresent: hasProviderCredential)
    }

    /// Effective settings are rebuilt from the same live mirror consumed by
    /// the UI. A catalog failure returns nil and permanently closes this
    /// boundary for the lifetime of the SettingsCenter instance.
    var bl6EffectiveSettingsSnapshot: BL6EffectiveSettingsSnapshot? {
        guard bl6SettingsTransactionState == .ready else {
            return nil
        }
        let values = bl6ProjectedValues
        do {
            let revision = try BL6SettingsCatalog.production.revision(for: values)
            return try bl6SettingsSnapshotGuard.apply(revision: revision, values: values)
        } catch let error as BL6SettingsCatalogError {
            bl6SettingsSnapshotGuard.reject(error)
            return nil
        } catch {
            bl6SettingsSnapshotGuard.reject(.emptyRevision)
            // Validation failure is intentionally not replaced with a
            // best-effort/default snapshot: every downstream submit must stop.
            return nil
        }
    }
}
