import Foundation
import MinisCore

/// The five durable state classes used by the phase-3 settings contract.
enum PersistentStateClass: String, Codable, CaseIterable, Sendable {
    case canonicalSetting = "canonical_setting"
    case sessionEffectiveSetting = "session_effective_setting"
    case viewState = "view_state"
    case historyCache = "history_cache"
    case diagnosticState = "diagnostic_state"
}

/// A typed ownership and precedence declaration for one persistent state.
///
/// `mayOverrideEffectiveValue` is deliberately fixed to false for every
/// descriptor. View and cache state may affect presentation, never policy.
struct PersistentStateDescriptor: Codable, Equatable, Sendable {
    let stateClass: PersistentStateClass
    let owner: String
    let priority: Int
    let scope: String
    let defaultValue: String
    let reset: String
    let persistence: String
    let restart: String
    let validation: String
    let consumer: String
    let settingsKey: String?
    let effectiveSource: String?
    /// SettingsCenter binding names whose write path lands on exactly this
    /// descriptor's persisted state (P3-SET-01 lane 155). Non-empty when the
    /// UI proxy name differs from the persisted field (e.g. `browserViewportMode`
    /// → `browser.viewportMode`) or when several toggles share one atomic
    /// payload (Safe Mode / Kill Switch). Never a second persistence truth.
    let uiBindings: [String]
    let mayOverrideEffectiveValue: Bool

    init(
        stateClass: PersistentStateClass,
        owner: String,
        priority: Int,
        scope: String = "app",
        defaultValue: String = "declared by owner",
        reset: String,
        persistence: String,
        restart: String = "immediate",
        validation: String = "owner validates",
        consumer: String,
        settingsKey: String? = nil,
        effectiveSource: String? = nil,
        uiBindings: [String] = []
    ) {
        self.stateClass = stateClass
        self.owner = owner
        self.priority = priority
        self.scope = scope
        self.defaultValue = defaultValue
        self.reset = reset
        self.persistence = persistence
        self.restart = restart
        self.validation = validation
        self.consumer = consumer
        self.settingsKey = settingsKey
        self.effectiveSource = effectiveSource
        self.uiBindings = uiBindings
        mayOverrideEffectiveValue = false
    }
}

enum SettingsProjectionApplyState: String, Codable, Equatable, Sendable {
    case liveApplied = "live_applied"
    case restartRequired = "restart_required"
}

/// Stable provider identity for Settings projections. Metadata changes update
/// the revision, while credentials remain represented only by presence.
struct SettingsProviderProjectionIdentity: Codable, Equatable, Sendable {
    let providerID: String
    let metadataRevision: String

    var id: String { providerID }
}

/// Bounded applied-state projection consumed by SettingsView. The lists are
/// descriptor identities, not values, so refreshes cannot lose provider or
/// setting ownership and no secret can enter the UI projection.
struct SettingsAppliedStateProjection: Codable, Equatable, Sendable {
    let settingsRevision: String
    let providers: [SettingsProviderProjectionIdentity]
    let liveAppliedSettingKeys: [String]
    let restartRequiredSettingKeys: [String]

    var liveAppliedCount: Int { liveAppliedSettingKeys.count }
    var restartRequiredCount: Int { restartRequiredSettingKeys.count }
    var state: SettingsProjectionApplyState {
        restartRequiredSettingKeys.isEmpty ? .liveApplied : .restartRequired
    }

    var statusLabel: String {
        switch state {
        case .liveApplied:
            return "设置均可实时生效"
        case .restartRequired:
            return "设置按实时与下次运行组合分层生效"
        }
    }
}

/// Provider-local state exposed to Settings after a credential read.
///
/// This projection is deliberately secret-free.  A failed legacy Keychain
/// read blocks only the provider identified by `providerID`; the recovery
/// action remains an explicit replacement entered by the user.
enum SettingsProviderState: String, Equatable, Sendable {
    case ready
    case blocked
}

enum SettingsProviderRecoveryAction: String, Equatable, Sendable {
    case none
    case replaceAPIKey = "replace_api_key"
}

enum SettingsProviderCredentialFailure: String, Equatable, Sendable {
    case missing
    case denied
    case failed
    case other

    var message: String {
        switch self {
        case .missing:
            return "无法从钥匙串读取当前 API Key：未找到；请直接输入新 Key 替换。"
        case .denied:
            return "无法从钥匙串读取当前 API Key：访问被拒绝；请检查钥匙串权限，或直接输入新 Key 替换。"
        case .failed:
            return "无法从钥匙串读取当前 API Key：读取失败；请重试，或直接输入新 Key 替换。"
        case .other:
            return "当前 API Key 不可用；请直接输入新 Key 替换。"
        }
    }
}

struct ProviderStateClassification: Equatable, Sendable {
    let providerID: String
    let state: SettingsProviderState
    let failure: SettingsProviderCredentialFailure?
    let recoveryAction: SettingsProviderRecoveryAction

    var isBlocked: Bool { state == .blocked }
    var isActionable: Bool { recoveryAction != .none }
    var message: String? { failure?.message }

    /// Short, non-secret status text for Settings rows and VoiceOver.
    var statusLabel: String {
        switch state {
        case .ready:
            return "就绪"
        case .blocked:
            return "受阻"
        }
    }

    /// Recovery copy is intentionally explicit: a blocked provider never
    /// implies that an old credential can be reused or silently repaired.
    var recoveryLabel: String? {
        switch recoveryAction {
        case .none:
            return nil
        case .replaceAPIKey:
            return "直接输入新 Key 替换"
        }
    }

    /// Stable, secret-free AX value for a provider readiness row.
    var accessibilityValue: String {
        guard let message else { return statusLabel }
        return "\(statusLabel)：\(message)"
    }
}

/// Validation state for one persisted provider record.
///
/// This projection is metadata-only: the credential is represented by the
/// Keychain-backed environment-variable name, never by its value.  It is
/// intentionally separate from readiness, because a valid factory contract
/// still needs a later, typed readiness check before ChatStore can use it.
enum SettingsProviderConfigurationState: String, Codable, Equatable, Sendable {
    case ready
    case missingCredentialReference = "missing_credential_reference"
    case missingModel = "missing_model"
    case missingBaseURL = "missing_base_url"
    case invalidBaseURL = "invalid_base_url"
    case unsupportedProtocol = "unsupported_protocol"
    case factoryUnavailable = "factory_unavailable"

    var label: String {
        switch self {
        case .ready: return "配置有效"
        case .missingCredentialReference: return "API Key 引用缺失"
        case .missingModel: return "模型未配置"
        case .missingBaseURL: return "Base URL 未配置"
        case .invalidBaseURL: return "Base URL 无效"
        case .unsupportedProtocol: return "协议暂不支持"
        case .factoryUnavailable: return "ProviderFactory 未接入"
        }
    }

    var message: String {
        switch self {
        case .ready:
            return "配置有效；API Key 仅通过 Keychain 引用在运行时解析。"
        case .missingCredentialReference:
            return "API Key 引用无效；请重新保存供应商并输入新 Key。"
        case .missingModel:
            return "尚未配置模型；请至少添加一个模型后再用于聊天。"
        case .missingBaseURL:
            return "尚未配置 Base URL；请填写供应商 API 地址后再检查就绪状态。"
        case .invalidBaseURL:
            return "Base URL 无效；请使用 https:// 或 http:// 开头、不含用户名、密码或查询密钥的地址。"
        case .unsupportedProtocol:
            return "当前协议没有真实 ProviderFactory/chat consumer；请选择 OpenAI 兼容或 Anthropic。"
        case .factoryUnavailable:
            return "当前 Provider 尚未接入真实 ProviderFactory；请重新选择已支持的协议。"
        }
    }
}

/// A durable, secret-free snapshot consumed by the non-Canvas chat path.
///
/// `credentialReference` is the canonical environment-variable/Keychain
/// account name. `providerConfig` is reconstructed only after validation and
/// contains that reference, never a direct API key. This gives Settings a
/// stable reopen projection while leaving actual credential resolution to the
/// existing ChatStore -> ProviderFactory boundary.
struct SettingsProviderConfigurationSnapshot: Codable, Equatable, Sendable {
    let providerID: String
    let modelIDs: [String]
    let baseURL: String?
    let protocolType: ProviderWireProtocol
    let credentialReference: String?
    let providerType: ProviderType?
    let state: SettingsProviderConfigurationState

    var isValid: Bool { state == .ready }

    var statusLabel: String { state.label }

    var statusMessage: String { state.message }

    /// The only credential-bearing field here is a Keychain reference name.
    /// The returned ProviderConfig is safe to persist or hand to the factory;
    /// callers still need a readiness receipt before invoking chat.
    var providerConfig: ProviderConfig? {
        guard isValid, let providerType, let credentialReference else { return nil }
        return ProviderConfig(
            id: providerID,
            label: providerID,
            providerType: providerType,
            runtimeProviderID: providerID,
            customBaseURL: baseURL,
            appendV1Suffix: protocolType == .openaiResponses
                || (protocolType == .openaiCompatible
                    && !DeepSeekProviderContract.isCanonicalBaseURL(baseURL ?? "")),
            apiKeyEnvVar: credentialReference
        )
    }

    init(entry: EnvVarEntry) {
        let normalizedProviderID = EnvVarStore.canonicalName(entry.name)
        let credentialReference: String? = entry.isSecret && entry.valueInKeychain
            && EnvVarStore.isValidName(normalizedProviderID)
            ? normalizedProviderID
            : nil
        let modelIDs = Self.normalizedModelIDs(entry.modelNames)
        let trimmedBaseURL = entry.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)

        let mappedProviderType: ProviderType?
        switch entry.protocolType {
        case .openaiCompatible:
            mappedProviderType = .openAI
        case .openaiResponses:
            mappedProviderType = .openAIResponses
        case .anthropic:
            mappedProviderType = .anthropic
        case .other:
            mappedProviderType = nil
        }

        let state: SettingsProviderConfigurationState
        if credentialReference == nil {
            state = .missingCredentialReference
        } else if modelIDs.isEmpty {
            state = .missingModel
        } else if entry.protocolType == .other {
            state = .unsupportedProtocol
        } else if let trimmedBaseURL, !trimmedBaseURL.isEmpty,
                  (try? CustomProviderURL.validate(trimmedBaseURL)) == nil {
            state = .invalidBaseURL
        } else if trimmedBaseURL?.isEmpty != false {
            state = .missingBaseURL
        } else if let mappedProviderType,
                  !ProviderFactory.shared.hasBuilder(for: mappedProviderType) {
            state = .factoryUnavailable
        } else {
            state = .ready
        }

        self.providerID = normalizedProviderID
        self.modelIDs = modelIDs
        self.baseURL = trimmedBaseURL?.isEmpty == true ? nil : trimmedBaseURL
        self.protocolType = entry.protocolType
        self.credentialReference = credentialReference
        self.providerType = mappedProviderType
        self.state = state
    }

    private static func normalizedModelIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let modelID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, seen.insert(modelID).inserted else { return nil }
            return modelID
        }
    }
}

/// The narrow handoff shape expected by the real ChatStore consumer.
/// Settings persists/reopens this identity; ChatStore remains responsible for
/// readiness gating and calling `ProviderFactory.makeProvider` at runtime.
struct SettingsProviderChatConsumerContract: Codable, Equatable, Sendable {
    let providerID: String
    let modelID: String
    let credentialReference: String
    let providerConfig: ProviderConfig

    init?(snapshot: SettingsProviderConfigurationSnapshot, modelID: String) {
        guard snapshot.isValid,
              let credentialReference = snapshot.credentialReference,
              let providerConfig = snapshot.providerConfig else { return nil }
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.modelIDs.contains(normalizedModelID), !normalizedModelID.isEmpty else {
            return nil
        }
        self.providerID = snapshot.providerID
        self.modelID = normalizedModelID
        self.credentialReference = credentialReference
        self.providerConfig = providerConfig
    }
}

/// Production state contract for Settings, Browser, Terminal and diagnostics.
///
/// This is metadata only: it does not persist a second copy of any setting.
enum SettingsStateClassification {
    static func providerProjectionIdentity(
        for entry: EnvVarEntry
    ) -> SettingsProviderProjectionIdentity {
        let providerID = EnvVarStore.canonicalName(entry.name)
        let metadata = [
            providerID,
            entry.baseURL ?? "",
            entry.modelNames.sorted().joined(separator: "\u{1f}"),
            entry.protocolType.rawValue,
            entry.valueInKeychain ? "keychain" : "metadata"
        ].joined(separator: "\u{1e}")
        return SettingsProviderProjectionIdentity(
            providerID: providerID,
            metadataRevision: DeletionGate.fingerprint(metadata)
        )
    }

    static func applyState(for descriptor: PersistentStateDescriptor) -> SettingsProjectionApplyState {
        descriptor.restart.lowercased().hasPrefix("immediate")
            ? .liveApplied
            : .restartRequired
    }

    static func classifyMigration(
        _ provenance: SettingsMigrationProvenance?,
        currentVersion: Int = AppSettings.currentVersion
    ) -> SettingsSchemaClassification {
        guard let provenance else { return .unavailable }
        guard provenance.isMonotonic else { return .invalid }
        if provenance.toVersion > currentVersion { return .futureVersion }
        if provenance.didNormalizeLegacyReferences || provenance.toVersion > provenance.fromVersion {
            return .migrated
        }
        return .current
    }

    /// Classify one provider without throwing or collapsing sibling providers.
    /// Keychain failures are intentionally mapped to an actionable replacement
    /// state; the caller may classify every provider independently.
    static func classifyProviderCredential(
        providerID: String,
        persistenceError: EnvVarPersistenceError?
    ) -> ProviderStateClassification {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure: SettingsProviderCredentialFailure?
        switch persistenceError {
        case .keychainReadMissing:
            failure = .missing
        case .keychainReadDenied:
            failure = .denied
        case .keychainReadFailed:
            failure = .failed
        case nil:
            failure = nil
        default:
            // Preserve a provider-local blocked state for an unexpected
            // persistence failure.  It must never become an App-wide crash or
            // silently claim that the credential is usable.
            failure = .other
        }
        return ProviderStateClassification(
            providerID: normalizedProviderID,
            state: failure == nil ? .ready : .blocked,
            failure: failure,
            recoveryAction: failure == nil ? .none : .replaceAPIKey
        )
    }

    static let descriptors: [PersistentStateDescriptor] = [
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/browser",
            defaultValue: "BrowserSettings.default",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json",
            restart: "immediate for new and existing BrowserSession",
            validation: "BrowserSettings.resolvedUserAgent/resolvedViewport",
            consumer: "BrowserTabView -> BrowserSession",
            settingsKey: "browser",
            effectiveSource: "SettingsCenter.effectiveBrowserSettings",
            // P3-SET-01 lane 155 ruling: the six UI field proxies keep the
            // aggregate row as their persistence/effective truth because UA and
            // viewport resolution are cross-field (resolvedUserAgent/resolvedViewport).
            uiBindings: [
                "userAgentPreset", "customUserAgent", "browserViewportMode",
                "customViewportWidth", "customViewportHeight", "idleTabTimeoutMinutes"
            ]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/safety",
            defaultValue: "Safe Mode=false; Kill Switch=false",
            reset: "SettingsCenter.restoreSafetyControlDefaults()",
            persistence: "SettingsStore.providerSettings",
            restart: "immediate",
            validation: "SafetyRuntimeSnapshot.isEnabled",
            consumer: "BridgeStore.SafetyRuntimeToolGate + TerminalContextPanelAdapter",
            settingsKey: SafetyControlState.settingsKey,
            effectiveSource: "SettingsCenter.safetyRuntimeSnapshot",
            // P3-SET-01 lane 155 ruling: Safe Mode and Kill Switch are one
            // atomic providerSettings payload written through setSafeMode/
            // setKillSwitch; each UI toggle is declared as a binding proxy of
            // this row instead of a second persistence identity.
            uiBindings: ["safeModeEnabled", "killSwitchEnabled"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "4",
            reset: "SettingsCenter.resetChildConcurrencyToDefaults()",
            persistence: "SettingsStore.settings.json",
            restart: "next production composition",
            validation: "ChildConcurrencySelection 1...40",
            consumer: "SettingsCenter -> BridgeStore -> AgentOrchestrator",
            settingsKey: "agent.childConcurrencyUserSelected",
            effectiveSource: "SettingsCenter.childConcurrencySelection"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "1",
            reset: "SettingsCenter.resetChildConcurrencyToDefaults()",
            persistence: "SettingsStore.settings.json",
            restart: "next production composition",
            validation: "ChildConcurrencySelection enabledSessionCount 1...40 (user-side 166-B key; model-supplied values stay rejected by the ceiling-rejection contract)",
            consumer: "SettingsCenter -> BridgeStore -> ChildConcurrencyGovernor global budget",
            settingsKey: "agent.childConcurrencyEnabledSessionCount",
            effectiveSource: "SettingsCenter.childConcurrencySelection"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter -> EnvVarStore",
            priority: 100,
            scope: "app/provider",
            defaultValue: "no custom provider",
            reset: "delete provider metadata and Keychain reference explicitly",
            persistence: "envvars.json metadata + Keychain credential reference",
            restart: "reopen projects metadata; runtime provider resolves per chat turn",
            validation: "SettingsProviderConfigurationSnapshot + typed readiness receipt",
            consumer: "ChatStore.makeCustomProvider -> ProviderFactory",
            settingsKey: "provider.records",
            effectiveSource: "SettingsCenter.providerRecords"
        ),
        // P3-SET-01 lane 136: the three canonical settings that landed through
        // lanes 081 (SessionSidebarWidthContract), 123 (ThemePreset convergence)
        // and 076 (memoryLimitMB consumer) without their matrix binding. The
        // sidebar entry is merged verbatim per lane 081's integration recipe
        // step 1; no field text was re-authored here.
        SessionSidebarWidthContract.descriptor,
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/appearance",
            defaultValue: "GeneralSettings.default.themePreset (.light 产品主题；旧文件里的 .system 经一次性迁移改为产品主题)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json",
            restart: "immediate; ThemeTokenProvider/Theme re-project from settingsMirror",
            validation: "GeneralSettings.setThemePreset: 未验收预设经 ThemePreset.nearest 收敛，不可存储",
            consumer: "ThemeTokenProvider + Theme.colorSchemePreference + SettingsView Picker(主题预设)",
            settingsKey: "general.themePreset",
            effectiveSource: "SettingsCenter.themePreset"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/appearance",
            defaultValue: "GeneralSettings.default.appearance (.system 跟随系统；旧文件里使用产品主题的用户一次性迁移为 .light)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json general.appearance",
            restart: "immediate; Theme.colorSchemePreference 与主题令牌按浅色/深色/跟随系统重新投影",
            validation: "Appearance 枚举（浅色/深色/跟随系统）；与配色预设相互独立，换配色不改明暗",
            consumer: "Theme.colorSchemePreference + SettingsView Picker(明暗)",
            settingsKey: "general.appearance",
            effectiveSource: "SettingsCenter.appearance"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/storage",
            defaultValue: "nil (记忆体积不设上限)",
            reset: "设置页清空输入回落 nil；整体重置走 SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json",
            restart: "immediate for new cache admissions; already-cached entries follow NSCache best-effort trimming",
            validation: "MemoryLimitCachePolicy.effectiveTotalCostBytes: min(baseline, configured); 非正值回落 baseline",
            consumer: "MemoryLimitCachePolicy-driven NSCache sites (AttributedCache/AssetImageLoader/VideoThumbnail/FileTreePreview)",
            settingsKey: "storage.memoryLimitMB",
            effectiveSource: "SettingsCenter.memoryLimitMB"
        ),
        // P3-SET-01 lane 155: binding-granularity coverage ruling for the
        // frozen lane-148 tolerances. Every row below is the canonical matrix
        // identity of one already-persisted SettingsCenter setting; no row
        // invents state. Defaults/persistence cite the MinisCore settings
        // contracts; consumers/effective sources were verified against the
        // production call sites recorded in the lane-155 receipt.
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/general",
            defaultValue: "GeneralSettings.default.defaultProviderID (nil)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json general.defaultProviderID",
            restart: "next chat composition; ChatStore re-resolves defaults on reload",
            validation: "ChatStore.applyDefaultProvider: unknown provider/model falls back fail-closed",
            consumer: "ChatStore default-provider selection (ChatStore.swift general snapshot)",
            settingsKey: "general.defaultProviderID",
            effectiveSource: "SettingsCenter.defaultProviderID"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/general",
            defaultValue: "GeneralSettings.default.defaultModelID (nil)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json general.defaultModelID",
            restart: "next chat composition",
            validation: "ChatStore binds only models present in the selected provider record",
            consumer: "ChatStore default-model selection",
            settingsKey: "general.defaultModelID",
            effectiveSource: "SettingsCenter.defaultModelID"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/general",
            defaultValue: "nil (sub model inherits the main model)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json general.subModelReference (legacy subModelID kept unresolved only)",
            restart: "immediate; lightweightModelReferenceSource reads the live mirror per call",
            validation: "GeneralSettings.subModelID setter promotes only into a provider-scoped subModelReference",
            consumer: "ChatStore.lightweightModelReferenceSource (MinisCanvasApp composition)",
            settingsKey: "general.subModelID",
            effectiveSource: "SettingsCenter.subModelID"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/general",
            defaultValue: ".balanced",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json general.modelSpeedTier",
            restart: "immediate for new turns; ChatStore speed projection updates on change",
            validation: "ModelSpeedTier enum raw value; decode failure falls back to default",
            consumer: "ChatStore modelSpeedTier + ModelMenuButton + LLMTypes tier routing",
            settingsKey: "general.modelSpeedTier",
            effectiveSource: "SettingsCenter.modelSpeedTier"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/general",
            defaultValue: ".normal",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json general.chatOutputMode",
            restart: "immediate; restoreOutputMode/onOutputModeChanged keep ChatStore in sync",
            validation: "ChatOutputMode enum raw value; decode failure falls back to default",
            consumer: "ChatStore output-mode restoration at composition (MinisCanvasApp wiring)",
            settingsKey: "general.chatOutputMode",
            effectiveSource: "SettingsCenter.chatOutputMode"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/general",
            defaultValue: "\"zh-Hans\"",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json general.language",
            restart: "next speech runtime composition; recognizers keep the bound locale until rebuild",
            validation: "SpeechLocaleResolver.runtimeLocale: invalid or missing fails closed to nil",
            consumer: "BridgeStore speech recognizer/SpeechTool + SettingsCenter.effectiveSpeechLocale",
            settingsKey: "general.language",
            effectiveSource: "SettingsCenter.language"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "50",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.maxLoopIterations",
            restart: "next agent-loop composition (BridgeStore AgentLoop.maxIterations)",
            validation: "Int 1...100 at init/decode/encode and execution; legacy 10 kept until explicit notice choice",
            consumer: "BridgeStore agent-loop construction maxIterations",
            settingsKey: "agent.maxLoopIterations",
            effectiveSource: "SettingsCenter.maxLoopIterations"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "1000000",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.maxTokensPerSession",
            restart: "same session cap update; current usage and in-flight leases retained",
            validation: "Positive Int at init/decode/encode; no model mutation key",
            consumer: "SettingsCenter.maxTokensPerSession -> ChatStore.setTokenBudgetLimit finite value when unlimited is false -> same BudgetTracker",
            settingsKey: "agent.maxTokensPerSession",
            effectiveSource: "SettingsCenter.maxTokensPerSession",
            uiBindings: ["maxTokensPerSession"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting, owner: "SettingsCenter", priority: 100,
            scope: "app/agent user-only control", defaultValue: "false",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.tokenBudgetUnlimited",
            restart: "same session cap update; counters and leases retained",
            validation: "Explicit Bool; missing defaults false; finite Int remains positive",
            consumer: "SettingsCenter.tokenBudgetUnlimited -> ChatStore.setTokenBudgetLimit explicit optional-cap selection -> same BudgetTracker",
            settingsKey: "agent.tokenBudgetUnlimited", effectiveSource: "SettingsCenter.tokenBudgetUnlimited",
            uiBindings: ["tokenBudgetUnlimited"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "false",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.stripModelShellCredentials",
            restart: "next model shell environment snapshot",
            validation: "User-only Bool; not exposed as a model-mutable setting; does not disclose credential values",
            consumer: "SettingsCenter.configureModelShellEnvironment -> ModelShellEnvironment credential stripping",
            settingsKey: "agent.stripModelShellCredentials",
            effectiveSource: "SettingsCenter.stripModelShellCredentials",
            uiBindings: ["stripModelShellCredentials"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.modelShellNoninteractive",
            restart: "next model shell environment snapshot",
            validation: "User-only Bool; not exposed as a model-mutable setting; credentials remain separately controlled",
            consumer: "SettingsCenter.configureModelShellEnvironment -> noninteractive model shell snapshot",
            settingsKey: "agent.modelShellNoninteractive",
            effectiveSource: "SettingsCenter.modelShellNoninteractive",
            uiBindings: ["modelShellNoninteractive"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.approvalInlineEnabled",
            restart: "applied when production services are attached",
            validation: "User-only Bool; not exposed as a model-mutable setting; presentation only, never changes what needs approval",
            consumer: "BridgeStore.commitProductionServices -> ApprovalPromptCenter.applyPersistedPresentation(inline:)",
            settingsKey: "agent.approvalInlineEnabled",
            effectiveSource: "SettingsCenter.approvalInlineEnabledSetting"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "0 (wait for the user, never auto-deny)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.approvalTimeoutSeconds",
            restart: "applied when production services are attached",
            validation: "User-only finite number clamped to 0...3600 seconds; presentation only",
            consumer: "BridgeStore.commitProductionServices -> ApprovalPromptCenter.applyPersistedPresentation(expiration:)",
            settingsKey: "agent.approvalTimeoutSeconds",
            effectiveSource: "SettingsCenter.approvalTimeoutSecondsSetting",
            uiBindings: ["expirationInterval"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.browserWriteEnabled",
            restart: "next admitted browser action",
            validation: "Bool; backup import forces false; every action still needs approval including bypass",
            consumer: "BridgeStore browser write preference -> BrowserSession write gate",
            settingsKey: "agent.browserWriteEnabled",
            effectiveSource: "SettingsCenter.browserWriteEnabled",
            uiBindings: ["browserWriteEnabled"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.maxLoopIterationsNoticeAcknowledged",
            restart: "immediate notice visibility",
            validation: "Legacy stored 10 without acknowledgement is false; UI Pending is the inverse; explicit acknowledgement persists once",
            consumer: "SettingsView old-10 choice -> SettingsCenter.acknowledgeLoopLimitNotice",
            settingsKey: "agent.maxLoopIterationsNoticeAcknowledged",
            effectiveSource: "SettingsCenter.maxLoopIterationsNoticePending",
            uiBindings: ["maxLoopIterationsNoticePending"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "300",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.toolTimeoutSeconds",
            restart: "next tool-executor composition (assembler injects the value)",
            validation: "Int stored as configured; timeout applied by the assembler-built executor",
            consumer: "AgentLoopChatEngine non-command toolTimeoutSeconds; shell uses command-specific policy",
            settingsKey: "agent.toolTimeoutSeconds",
            effectiveSource: "SettingsCenter.toolTimeoutSeconds"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "120",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.shellCommandTimeoutSeconds",
            restart: "next tool-executor composition",
            validation: "Int UI 1...600; command resolver enforces finite positive request timeout with cap 600",
            consumer: "BridgeStore command execution policy and shell watchdog",
            settingsKey: "agent.shellCommandTimeoutSeconds",
            effectiveSource: "SettingsCenter.shellCommandTimeoutSeconds",
            uiBindings: ["shellCommandTimeoutSeconds"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "4",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.concurrentToolLimit",
            restart: "next tool-executor composition; >1 wraps ConcurrentToolLimitingExecutor",
            validation: "Int stored as configured; wrapper installed only when limit > 1",
            consumer: "AgentLoopChatEngine concurrentToolLimit + BridgeStore orchestration",
            settingsKey: "agent.concurrentToolLimit",
            effectiveSource: "SettingsCenter.concurrentToolLimit"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "0.8",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.autoCompactThreshold",
            restart: "next session-meter load (ContextWindowMeter warningFraction)",
            validation: "ChatStore clamps warningFraction to min(value, 1); <= 0 disables the warning",
            consumer: "ChatStore ContextWindowMeter warning + MinisCore RequestBudget",
            settingsKey: "agent.autoCompactThreshold",
            effectiveSource: "SettingsCenter.autoCompactThreshold"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "nil (0 in UI: use current model metadata)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.contextLengthTokens",
            restart: "next turn ContextTurnSettingsSnapshot; active turn retains its frozen value",
            validation: "nonnegative UI integer; 0 persists nil; turn admission validates against the selected model context window",
            consumer: "AgentLoopChatEngine ContextTurnSettingsSnapshot.contextLengthTokens",
            settingsKey: "agent.contextLengthTokens",
            effectiveSource: "SettingsCenter.contextLengthTokens"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "nil (0 in UI: include all history turns)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.historyTurnLimit",
            restart: "next turn ContextTurnSettingsSnapshot; active turn retains its frozen value",
            validation: "nonnegative UI integer; 0 persists nil; positive limit includes the current user turn",
            consumer: "AgentLoopChatEngine ContextTurnSettingsSnapshot.historyTurnLimit",
            settingsKey: "agent.historyTurnLimit",
            effectiveSource: "SettingsCenter.historyTurnLimit"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.fallbackEnabled",
            restart: "next fallback-router composition (also gated by external-network admission)",
            validation: "Bool; BridgeStore ANDs it with productionExternalNetworkAllowed",
            consumer: "AgentLoopChatEngine fallbackEnabled + BridgeStore makeFallbackRouter",
            settingsKey: "agent.fallbackEnabled",
            effectiveSource: "SettingsCenter.fallbackEnabled"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.memoryEnabled",
            restart: "immediate for new turns; snapshot taken when the turn is created",
            validation: "Bool; nil provider means not assembled (no injection)",
            consumer: "ChatStore memoryEnabledProvider per-turn memory injection gate",
            settingsKey: "agent.memoryEnabled",
            effectiveSource: "SettingsCenter.memoryEnabled"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.globalInstructionsEnabled",
            restart: "immediate for new turns; snapshot taken when the turn is created",
            validation: "Bool; missing legacy value defaults to true",
            consumer: "ChatStore globalInstructionsEnabledProvider per-turn global instructions gate",
            settingsKey: "agent.globalInstructionsEnabled",
            effectiveSource: "SettingsCenter.globalInstructionsEnabled"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.fileCheckpointsEnabled",
            restart: "existing file-access runtime rebind",
            validation: "Bool; user UI only, no model mutation key; disabled keeps durable records",
            consumer: "BuiltinToolExecutor file checkpoint capture + ChatStore restore entry",
            settingsKey: "agent.fileCheckpointsEnabled",
            effectiveSource: "SettingsCenter.fileCheckpointsEnabled",
            uiBindings: ["fileCheckpointsEnabled"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.backgroundAutoContinueEnabled",
            restart: "immediate; read each time a background task completion is considered",
            validation: "Bool; missing legacy value defaults to true; user UI only, no model mutation key; consecutive auto-continuations are capped per session and never bypass budget, permission mode or approval",
            consumer: "ChatStore backgroundAutoContinueEnabledProvider (background command/child completion auto-continue gate)",
            settingsKey: "agent.backgroundAutoContinueEnabled",
            effectiveSource: "SettingsCenter.backgroundAutoContinueEnabled",
            uiBindings: ["backgroundAutoContinueEnabled"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.childMutationsEnabled",
            restart: "immediate for new turns; in-flight turns retain their frozen child mutation ceiling",
            validation: "Bool; absent explicit-selection marker migrates legacy false to true; explicit false stays off; parent policy and approvals remain authoritative",
            consumer: "MinisCanvasApp runtime rebind -> AgentLoopChatEngine.withChildMutationsEnabled -> child execution guard",
            settingsKey: "agent.childMutationsEnabled",
            effectiveSource: "SettingsCenter.childMutationsEnabled",
            uiBindings: ["childMutationsEnabled"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "false",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.childModelOverridesEnabled",
            restart: "immediate for subsequent child dispatches; existing tasks retain their frozen policy",
            validation: "Bool; local user control only, no model mutation key; selected models must be configured and ready",
            consumer: "ChatStore.childModelMetadata -> ChildModelBindingPolicy.allowsOverrides -> child dispatch selection",
            settingsKey: "agent.childModelOverridesEnabled",
            effectiveSource: "SettingsCenter.childModelOverridesEnabled"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "nil (selected model maximum)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.childModelThinkingLevelCeiling",
            restart: "immediate for subsequent child dispatches; existing tasks retain their frozen policy",
            validation: "Optional ThinkingLevel; local user control only, no model mutation key; effective thinking is bounded by the selected model and this ceiling",
            consumer: "ChildModelBindingPolicy.thinkingLevelCeiling -> ChildModelBindingPolicy.resolve -> frozen child reasoningConfiguration",
            settingsKey: "agent.childModelThinkingLevelCeiling",
            effectiveSource: "SettingsCenter.childModelThinkingLevelCeiling"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "false",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.childDeletionAutoReviewEnabled",
            restart: "immediate for new production attachments; child tasks already running keep their reviewer",
            validation: "Bool; explicit user control only, no model mutation key (absent from BL6SettingsCatalog); human approval remains the fallback",
            consumer: "SettingsCenter file-access rebind -> ProductionOrchestrationDefaults.attachCurrentProductionConfiguration -> ChildDeletionReviewSettings.configuration -> ChildDeletionReviewer enabled flag",
            settingsKey: "agent.childDeletionAutoReviewEnabled",
            effectiveSource: "SettingsCenter.childDeletionAutoReviewEnabled",
            uiBindings: ["childDeletionAutoReviewEnabled"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent user-only control",
            defaultValue: "[]",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.childDeletionAutoReviewWhitelist",
            restart: "immediate for new production attachments; child tasks already running keep their reviewer",
            validation: "Absolute canonical real directories, de-duplicated, capped; add/remove through SettingsCenter only, no model mutation key; a directory that is no longer the same real directory is dropped when the configuration is built",
            consumer: "SettingsCenter file-access rebind -> ProductionOrchestrationDefaults.attachCurrentProductionConfiguration -> ChildDeletionReviewSettings.configuration -> ChildDeletionReviewer whitelistDirectories",
            settingsKey: "agent.childDeletionAutoReviewWhitelist",
            effectiveSource: "SettingsCenter.childDeletionAutoReviewWhitelist"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: ".alwaysAsk",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.approvalPolicy",
            restart: "immediate; onApprovalPolicyChanged pushes the live update into BridgeStore",
            validation: "Native choices are alwaysAsk, riskOnlyAsk, and deny; persisted autoApprove migrates to riskOnlyAsk",
            consumer: "BridgeStore approval policy at agent construction + updateApprovalPolicy callback",
            settingsKey: "agent.approvalPolicy",
            effectiveSource: "SettingsCenter.approvalPolicy",
            uiBindings: ["toolsDisabled"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "false",
            reset: "Explicit approval policy change, compatibility dismissal, or settings reset",
            persistence: "SettingsStore.settings.json agent.legacyAutomaticApprovalCompatibilityActive",
            restart: "Retains the local decision on reopen",
            validation: "Only legacy autoApprove migration activates compatibility",
            consumer: "Existing automatic schedule and project session approval",
            settingsKey: "agent.legacyAutomaticApprovalCompatibilityActive",
            effectiveSource: "SettingsCenter.legacyAutomaticApprovalCompatibilityActive",
            uiBindings: ["legacyAutomaticApprovalCompatibilityActive"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "nil",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.legacyApprovalPolicyOriginal",
            restart: "retained after acknowledgment",
            validation: "records only the former autoApprove value",
            consumer: "AgentSettings approval migration",
            settingsKey: "agent.legacyApprovalPolicyOriginal",
            effectiveSource: "AgentSettings.legacyApprovalPolicyOriginal"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "false",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.legacyApprovalPolicyNoticePending",
            restart: "pending until acknowledged",
            validation: "pending only with a recorded legacy policy",
            consumer: "SettingsView approval policy migration notice",
            settingsKey: "agent.legacyApprovalPolicyNoticePending",
            effectiveSource: "SettingsCenter.legacyApprovalPolicyNoticePending",
            uiBindings: ["legacyApprovalPolicyNoticePending"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "false",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.legacyApprovalScopeNoticePending",
            restart: "pending until acknowledged",
            validation: "missing field derives pending from a non-request legacy scope",
            consumer: "SettingsView approval scope migration notice",
            settingsKey: "agent.legacyApprovalScopeNoticePending",
            effectiveSource: "SettingsCenter.legacyApprovalScopeNoticePending",
            uiBindings: ["legacyApprovalScopeNoticePending"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "[] (empty = unrestricted)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.availableModelWhitelist",
            restart: "immediate; modelAllowlistProvider closure reads the live mirror per request",
            validation: "[String]; ChatStore keeps the request-boundary check authoritative",
            consumer: "ChatStore modelAllowlistProvider request boundary (MinisCanvasApp composition)",
            settingsKey: "agent.availableModelWhitelist",
            effectiveSource: "SettingsCenter.availableModelWhitelist"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "false (new input queues during generation)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.newMessageInterruptsGeneration",
            restart: "immediate for the next interruption check",
            validation: "Bool; closure defaults to false; explicit saved preference survives",
            consumer: "ChatStore generation queue or explicit interruption preference",
            settingsKey: "agent.newMessageInterruptsGeneration",
            effectiveSource: "SettingsCenter.newMessageInterruptsGeneration"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "ComposerPolicySettings.default",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.composerPolicy",
            restart: "immediate for new Composer and unattended submissions; existing turns keep their immutable snapshot",
            validation: "Composer requests cannot widen agent.policyRuntimeDefaults boundaries",
            consumer: "ChatStore restoreComposerPolicy and unattended submission snapshots",
            settingsKey: "agent.composerPolicy",
            effectiveSource: "SettingsCenter.composerPolicy"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "ProductionPolicyDefaults.default (budget 10000, horizon 4h, autonomy l1, no network domains)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.policyRuntimeDefaults",
            restart: "immediate for new production turns after durable save; in-flight turns retain their frozen policy",
            validation: "SettingsCenter.updatePolicyRuntimeDefaults requires a ready transaction and validates nonnegative budget, finite nonnegative horizon and deadline, and domain syntax",
            consumer: "ProductionOrchestrationDefaults.attachProductionServices -> BridgeStore PolicyRuntime defaults",
            settingsKey: "agent.policyRuntimeDefaults",
            effectiveSource: "SettingsCenter.policyRuntimeDefaults"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "false",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json agent.personaEnabled",
            restart: "immediate for new turns; system prompt rebuilt from the persona snapshot",
            validation: "Bool; ChatStore.applyPersona ignores no-op writes",
            consumer: "ChatStore persona injection into system prompt (turn snapshot)",
            settingsKey: "agent.personaEnabled",
            effectiveSource: "SettingsCenter.personaEnabled"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "PersonaPreset.professional",
            reset: "SettingsCenter.resetToDefaults(); applyPersonaPreset also refills agent.persona",
            persistence: "SettingsStore.settings.json agent.personaPreset",
            restart: "SettingsCenter/UI immediate; ChatStore production restore on next composition; live turn adoption unverified",
            validation: "PersonaPreset enum; SettingsView Picker calls applyPersonaPreset",
            consumer: "SettingsView preset Picker -> SettingsCenter.applyPersonaPreset -> agent.persona",
            settingsKey: "agent.personaPreset",
            effectiveSource: "SettingsCenter.personaPreset"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "PersonaPreset.professional.defaultPersona",
            reset: "SettingsCenter.resetToDefaults(); applyPersonaPreset refills from the preset",
            persistence: "SettingsStore.settings.json agent.persona",
            restart: "immediate for new turns",
            validation: "Codable Persona struct; content edits are free-form, preset is the reset anchor",
            consumer: "ChatStore/ChatAgentEngine persona projection + MemoryFileStore SOUL sync",
            settingsKey: "agent.persona",
            effectiveSource: "SettingsCenter.persona"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/agent",
            defaultValue: "TerminalPolicySettings.default",
            reset: "SettingsCenter.resetTerminalPolicyToDefaults()",
            persistence: "SettingsStore.settings.json agent.terminalPolicy",
            restart: "immediate for new execution boundaries; onTerminalPolicyChanged re-projects the snapshot",
            validation: "TerminalPolicySettings.normalized() on every write; Core hard-deny set is immutable",
            consumer: "TerminalPolicySnapshot -> BridgeStore/visible Terminal + FallbackRouter",
            settingsKey: "agent.terminalPolicy",
            effectiveSource: "SettingsCenter.terminalPolicySnapshot",
            uiBindings: ["terminalPolicySettings"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/privacy",
            defaultValue: "true",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json privacy.redactEnvValues",
            restart: "no behavioural application at this head (EnvVarRedactor runs unconditionally)",
            validation: "Bool",
            consumer: "BL6SettingsCenterProjection 'privacy.redact-env-values'（11/18 设置页开关已移除：功能未启用，不展示）",
            settingsKey: "privacy.redactEnvValues",
            effectiveSource: "SettingsCenter.redactEnvValues"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/privacy",
            defaultValue: "false",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json privacy.collectAnalytics",
            restart: "no behavioural application at this head (no analytics pipeline exists)",
            validation: "Bool",
            consumer: "BL6SettingsCenterProjection 'privacy.collect-analytics'（11/18 设置页开关已移除：功能未启用，不展示）",
            settingsKey: "privacy.collectAnalytics",
            effectiveSource: "SettingsCenter.collectAnalytics"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter -> LogManager",
            priority: 100,
            scope: "app/privacy",
            defaultValue: ".info",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json privacy.logLevel",
            restart: "immediate; both UI proxies write LogManager.minimumLevel",
            validation: "SettingsLogLevel enum; liveLogLevel reads LogManager as the runtime authority",
            consumer: "LogManager ring admission + SettingsView privacy/logs pages",
            settingsKey: "privacy.logLevel",
            effectiveSource: "SettingsCenter.liveLogLevel",
            // One persisted level, two documented UI entry points (privacy page
            // and logs page); the log-page getter is the runtime authority.
            uiBindings: ["privacyLogLevel", "liveLogLevel"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/privacy",
            defaultValue: "nil (production uses the default allowed root)",
            reset: "SettingsCenter.resetFileAccessRoots() or resetToDefaults()",
            persistence: "SettingsStore.settings.json privacy.allowedRootPath",
            restart: "immediate reapply of production file-access executor for next turns; disposable profile retains its isolated root",
            validation: "SettingsCenter.setFileAccessAllowedRoot accepts nil or an absolute path",
            consumer: "MinisCanvasApp reapplyProductionFileAccessBoundary -> BuiltinToolExecutor.allowedRoot",
            settingsKey: "privacy.allowedRootPath",
            effectiveSource: "SettingsCenter.effectiveAllowedRoot",
            uiBindings: ["fileAccessAllowedRoot"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/privacy",
            defaultValue: "[] (production uses default denied roots)",
            reset: "SettingsCenter.resetFileAccessRoots() or resetToDefaults()",
            persistence: "SettingsStore.settings.json privacy.deniedRootPaths",
            restart: "immediate reapply of production file-access executor for next turns; in-flight turns retain their snapshot",
            validation: "SettingsCenter.addFileAccessDeniedRoot requires an absolute path and deduplicates",
            consumer: "MinisCanvasApp reapplyProductionFileAccessBoundary -> BuiltinToolExecutor.deniedRoots",
            settingsKey: "privacy.deniedRootPaths",
            effectiveSource: "SettingsCenter.effectiveDeniedRoots",
            uiBindings: ["fileAccessDeniedRoots"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/privacy",
            defaultValue: "[] (no additional mounted roots)",
            reset: "SettingsCenter.resetToDefaults() or unmountFolder",
            persistence: "SettingsStore.settings.json privacy.mountedFolderPaths",
            restart: "immediate reapply of production file-access executor for next turns; disposable profile remains isolated",
            validation: "SettingsCenter.mountFolder requires absolute path, deduplicates and caps at PrivacySettings.maxMountedFolders",
            consumer: "MinisCanvasApp reapplyProductionFileAccessBoundary -> BuiltinToolExecutor.additionalAllowedRoots",
            settingsKey: "privacy.mountedFolderPaths",
            effectiveSource: "SettingsCenter.effectiveMountedFolders",
            uiBindings: ["mountedFolderPaths"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/privacy",
            defaultValue: "true (read-only, redacted access to <home>/.codex/sessions and <home>/.claude/projects for external session tools)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json privacy.allowLocalAgentSessionRead",
            restart: "immediate reapply of production file-access executor for next turns; disposable profile remains isolated",
            validation: "Bool; file tools never gain these directories",
            consumer: "MinisCanvasApp reapplyProductionFileAccessBoundary -> BuiltinToolExecutor.localAgentSessionHome",
            settingsKey: "privacy.allowLocalAgentSessionRead",
            effectiveSource: "SettingsCenter.allowLocalAgentSessionRead",
            uiBindings: ["allowLocalAgentSessionRead"]
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/storage",
            defaultValue: "30",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json storage.sessionRetentionDays",
            restart: "immediate for the next retention preview/execution",
            validation: "Int cutoff; deletion still requires the two-step OperationIntent gate",
            consumer: "SettingsCenter retention batch (previewSessionsOlderThanRetention/delete…)",
            settingsKey: "storage.sessionRetentionDays",
            effectiveSource: "SettingsCenter.sessionRetentionDays"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/storage",
            defaultValue: "false (auto cleanup off)",
            reset: "SettingsCenter.resetToDefaults()",
            persistence: "SettingsStore.settings.json storage.autoDeleteOldSessions",
            restart: "immediate for the next retention offer evaluation",
            validation: "Bool; only ever offers cleanup — execution keeps the confirmed-trash path",
            consumer: "SettingsView storage page auto-cleanup offer (gated by this flag)",
            settingsKey: "storage.autoDeleteOldSessions",
            effectiveSource: "SettingsCenter.autoDeleteOldSessions"
        ),
        PersistentStateDescriptor(
            stateClass: .canonicalSetting,
            owner: "SettingsCenter",
            priority: 100,
            scope: "app/typography",
            defaultValue: "TypographySettings.defaultBaseFontSize (14)",
            reset: "SettingsCenter.resetTypographyToDefaults()",
            persistence: "SettingsStore.settings.json typography.uiBaseFontSize",
            restart: "immediate; TypographyTokenProvider re-projects from the live value",
            validation: "TypographySettings.clamp to the contract range on every write",
            consumer: "TypographyTokenProvider + environment typographyContentScale",
            settingsKey: "typography.uiBaseFontSize",
            effectiveSource: "SettingsCenter.uiBaseFontSize"
        ),
        PersistentStateDescriptor(
            stateClass: .sessionEffectiveSetting,
            owner: "SettingsCenter -> runtime composition",
            priority: 80,
            scope: "session/turn",
            defaultValue: "inherits canonical safety snapshot",
            reset: "new session or safety default",
            persistence: "session runtime only",
            restart: "per request",
            validation: "safety snapshot and cancellation epoch",
            consumer: "Agent shell_execute and visible Terminal",
            effectiveSource: "SettingsCenter.safetyRuntimeSnapshot"
        ),
        PersistentStateDescriptor(
            stateClass: .viewState,
            owner: "ContextPanelView",
            priority: 40,
            scope: "window",
            defaultValue: "node tab",
            reset: "node tab",
            persistence: "in-memory view state",
            restart: "resets with view",
            validation: "presentation only",
            consumer: "ContextPanelView.content"
        ),
        PersistentStateDescriptor(
            stateClass: .historyCache,
            owner: "BrowserSession",
            priority: 20,
            scope: "browser session",
            defaultValue: "empty history",
            reset: "new BrowserSession",
            persistence: "WKWebView in-memory history",
            restart: "resets with session",
            validation: "navigation delegate",
            consumer: "BrowserTabView navigation controls"
        ),
        PersistentStateDescriptor(
            stateClass: .diagnosticState,
            owner: "TerminalBoundary",
            priority: 10,
            scope: "execution",
            defaultValue: "no receipt",
            reset: "new execution receipt",
            persistence: "ephemeral receipt",
            restart: "per execution",
            validation: "TerminalBoundary result",
            consumer: "TerminalTabView output and diagnostics"
        ),
    ]

    static func descriptors(
        for stateClass: PersistentStateClass
    ) -> [PersistentStateDescriptor] {
        descriptors.filter { $0.stateClass == stateClass }
    }

    static func canonicalDescriptor(for settingsKey: String) -> PersistentStateDescriptor? {
        descriptors.first {
            $0.stateClass == .canonicalSetting && $0.settingsKey == settingsKey
        }
    }

    static var stateClasses: [PersistentStateClass] {
        PersistentStateClass.allCases
    }
}

enum SettingsSchemaClassification: String, Codable, Equatable, Sendable {
    case unavailable
    case current
    case migrated
    case futureVersion = "future_version"
    case invalid
}

typealias SettingsStateDescriptor = PersistentStateDescriptor

/// Projects provider diagnostics into text that is safe for Settings UI and
/// accessibility output.  Readiness transports may receive arbitrary server
/// errors, response bodies, URLs, or header values; none of those are display
/// contracts.  Only a small typed summary is retained and sensitive-looking
/// lines are reduced to a status/category plus a generic recovery hint.
enum ProviderStatusTextProjection {
    static let hiddenDetail = "敏感详情已隐藏"
    static let fallback = "供应商错误详情已隐藏；请检查配置或直接替换 API Key。"

    static func project(_ raw: String, knownSecrets: [String] = []) -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        var source = raw
        for secret in knownSecrets where !secret.isEmpty {
            source = source.replacingOccurrences(of: secret, with: "<redacted-secret>")
        }

        let projectedLines = source
            .components(separatedBy: .newlines)
            .compactMap { projectLine($0) }
        return projectedLines.isEmpty ? fallback : projectedLines.joined(separator: "\n")
    }

    private static func projectLine(_ rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let category = safeCategory(in: line)
        if containsSensitiveSyntax(line) {
            return hiddenSummary(category: category, httpStatus: httpStatus(in: line))
        }

        // Preserve only typed readiness/keychain summaries.  Arbitrary
        // response text is deliberately dropped even when it happens not to
        // contain an obvious credential marker.
        guard let category else { return nil }
        if let httpStatus = httpStatus(in: line) {
            return "\(category)（HTTP \(httpStatus)）\(httpHint(category: category, status: httpStatus))"
        }
        return category == line ? line : category
    }

    /// 应用自己写死的完整提示（保存失败原因、获取模型列表的具体原因）。不含用户或
    /// 服务端内容，原样显示，不再被裁成笼统的类别或兜底文案（11/16 现场 F1、F3）。
    static let appAuthoredMessages: [String] = ProviderSaveFailureCategory.allMessages + [
        "获取模型列表失败：API Key 不能为空",
        "获取模型列表失败：Base URL 不能为空",
        "获取模型列表失败：当前运行配置不允许联网",
        "获取模型列表失败：连接超时，请检查 Base URL 或网络",
        "获取模型列表失败：无法连接服务器，请检查 Base URL 或网络",
        "获取模型列表失败：该服务没有 /models 接口，请手动填写模型名称",
        "获取模型列表失败：返回的模型列表格式无法识别，请手动填写模型名称",
    ] + CustomProviderURL.Failure.allFixedMessages.map { "获取模型列表失败：" + $0 }

    /// HTTP 状态码对应的一句话原因和下一步，只用固定文字。
    private static func httpHint(category: String, status: Int) -> String {
        let actionable = ["获取模型列表失败", "最小请求失败", "鉴权失败", "模型发现失败"]
        guard actionable.contains(category) else { return "" }
        switch status {
        case 401, 403: return "：API Key 无效或没有权限，请检查或直接替换 API Key"
        case 404: return "：地址或模型不存在，请检查 Base URL 和模型名称"
        case 429: return "：请求过多或额度不足，请稍后重试"
        case 500...599: return "：服务端出错，请稍后重试"
        default: return ""
        }
    }

    private static func hiddenSummary(category: String?, httpStatus: Int?) -> String {
        if let category, let httpStatus {
            return "\(category)（HTTP \(httpStatus)）；\(hiddenDetail)"
        }
        if let category {
            return "\(category)；\(hiddenDetail)"
        }
        if let httpStatus {
            return "HTTP \(httpStatus)；\(hiddenDetail)"
        }
        return hiddenDetail
    }

    private static func containsSensitiveSyntax(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        let hasQuery = line.contains("?") && line.contains("=")
        let hasBodyShape = line.contains("{") || line.contains("}")
        let sensitiveMarkers = [
            "authorization", "bearer ", "request body", "response body",
            "requestbody", "responsebody", "api_key", "api-key", "apikey",
            "access_token", "access-token", "refresh_token", "client_secret",
            "secret", "password", "token", "query", "body", "payload",
            "headers", "<redacted-secret>"
        ]
        return hasQuery || hasBodyShape || sensitiveMarkers.contains {
            lowercased.contains($0)
        } || containsOpaqueToken(line)
    }

    private static func containsOpaqueToken(_ line: String) -> Bool {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet.punctuationCharacters)
            .union(CharacterSet.symbols)
        return line.components(separatedBy: separators).contains { token in
            guard token.count >= 24 else { return false }
            let hasLetter = token.unicodeScalars.contains {
                CharacterSet.letters.contains($0)
            }
            let hasNumber = token.unicodeScalars.contains {
                CharacterSet.decimalDigits.contains($0)
            }
            return hasLetter && hasNumber
        }
    }

    private static func safeCategory(in line: String) -> String? {
        if let message = appAuthoredMessages.first(where: { line == $0 || line == $0 + "。" }) {
            return line == message ? message : message + "。"
        }
        let categories = [
            "无法从钥匙串读取当前 API Key：访问被拒绝",
            "无法从钥匙串读取当前 API Key：读取失败",
            "无法从钥匙串读取当前 API Key：未找到",
            "旧 API Key 不在钥匙串中",
            "钥匙串拒绝读取旧 API Key",
            "读取旧 API Key 时发生钥匙串错误",
            "获取模型列表失败",
            "模型发现返回空目录",
            "最小请求失败",
            "最小请求通过",
            "模型发现失败",
            "鉴权失败",
            "鉴权通过",
            "配置失败",
            "配置通过",
            "不可达",
            "可达",
            "目录为空",
            "已取消",
            "钥匙串",
            "模型发现"
        ]
        return categories.first { line.contains($0) }
    }

    private static func httpStatus(in line: String) -> Int? {
        guard let range = line.range(of: "HTTP", options: [.caseInsensitive]) else {
            return nil
        }
        let suffix = line[range.upperBound...]
            .drop(while: { $0 == " " || $0 == "\t" })
        let digits = suffix.prefix(while: { $0.isNumber })
        guard digits.count == 3, let status = Int(String(digits)) else { return nil }
        return status
    }
}
