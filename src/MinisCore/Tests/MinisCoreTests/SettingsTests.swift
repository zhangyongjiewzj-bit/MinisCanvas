import Foundation
import CryptoKit
import Testing
@testable import MinisCore

// NOTE: Run on the CLT-only toolchain with the documented flags (see
// threads/B1-fix.log):
//   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//              -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-Settings-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class FailingMoveFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func writePendingSettingsRecoveryMarker(
    in directory: URL,
    operationID: UUID,
    sourceName: String = SettingsStore.fileName,
    destinationName: String,
    payloadDigest: String,
    phase: String
) throws -> URL {
    let marker = directory.appendingPathComponent(
        ".settings-recovery-\(operationID.uuidString).pending.json"
    )
    let object: [String: String] = [
        "operationID": operationID.uuidString,
        "scopeID": "settings:\(SettingsStore.fileName)",
        "sourceName": sourceName,
        "destinationName": destinationName,
        "payloadDigest": payloadDigest,
        "phase": phase
    ]
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: marker)
    return marker
}

private func settingsDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct SettingsTests {
    @Test func globalInstructionsSettingDefaultsOnAndPreservesExplicitOff() throws {
        let legacy = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"memoryEnabled":false}"#.utf8))
        #expect(legacy.globalInstructionsEnabled)
        #expect(!legacy.memoryEnabled)
        var settings = legacy
        settings.globalInstructionsEnabled = false
        settings.memoryEnabled = true
        let restored = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(!restored.globalInstructionsEnabled)
        #expect(restored.memoryEnabled)
    }


    // MARK: - 默认值

    @Test func defaultsMatchSpec() {
        let s = AppSettings.defaults
        #expect(s.settingsVersion == AppSettings.currentVersion)

        // general
        #expect(s.general.appearance == .system)
        #expect(s.general.defaultProviderID == nil)
        #expect(s.general.defaultModelID == nil)
        #expect(s.general.language == "zh-Hans")

        // agent
        #expect(s.agent.maxLoopIterations == 50)
        #expect(s.agent.toolTimeoutSeconds == 300)
        #expect(s.agent.concurrentToolLimit == 4)
        #expect(s.agent.autoCompactThreshold == 0.8)
        #expect(s.agent.fallbackEnabled == false)
        #expect(s.agent.composerPolicy == .default)

        // privacy
        #expect(s.privacy.redactEnvValues == true)
        #expect(s.privacy.logLevel == .info)
        #expect(s.privacy.collectAnalytics == false)

        // storage
        #expect(s.storage.sessionRetentionDays == 30)
        #expect(s.storage.memoryLimitMB == nil)
        #expect(s.storage.autoDeleteOldSessions == false)

        // 预留
        #expect(s.providerSettings.isEmpty)
    }

    @Test func legacyNeverApprovalSettingMigratesToRiskOnlyAsk() throws {
        let data = Data(#"{"approvalPolicy":"never"}"#.utf8)
        let settings = try JSONDecoder().decode(AgentSettings.self, from: data)
        #expect(settings.approvalPolicy == .riskOnlyAsk)
    }

    @Test func onlyLegacyAutomaticApprovalTightensOnLoad() throws {
        let cases: [(String, ApprovalPolicy)] = [
            ("autoApprove", .riskOnlyAsk),
            ("alwaysAsk", .alwaysAsk),
            ("riskOnlyAsk", .riskOnlyAsk),
            ("never", .riskOnlyAsk),
            ("deny", .deny)
        ]
        for (rawPolicy, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: ["approvalPolicy": rawPolicy])
            let settings = try JSONDecoder().decode(AgentSettings.self, from: data)
            #expect(settings.approvalPolicy == expected, "stored policy: \(rawPolicy)")
            #expect(settings.legacyApprovalPolicyOriginal == (rawPolicy == "autoApprove" ? .autoApprove : nil))
            #expect(settings.legacyApprovalPolicyNoticePending == (rawPolicy == "autoApprove"))
            #expect(settings.legacyAutomaticApprovalCompatibilityActive == (rawPolicy == "autoApprove"))
            let reopened = try JSONDecoder().decode(
                AgentSettings.self, from: JSONEncoder().encode(settings)
            )
            #expect(reopened == settings)
        }
        let data = Data(#"{"approvalPolicy":"autoApprove","composerPolicy":{"mode":"manual","approvalScope":"session","effort":"standard","bypassModeConfirmed":false}}"#.utf8)
        var migrated = try JSONDecoder().decode(AgentSettings.self, from: data)
        #expect(migrated.composerPolicy.approvalScope == .session)
        #expect(migrated.legacyApprovalScopeNoticePending)
        migrated.legacyApprovalPolicyNoticePending = false
        migrated.legacyApprovalScopeNoticePending = false
        let acknowledged = try JSONDecoder().decode(
            AgentSettings.self, from: JSONEncoder().encode(migrated)
        )
        #expect(acknowledged == migrated)
        #expect(acknowledged.legacyApprovalPolicyOriginal == .autoApprove)
        #expect(acknowledged.legacyAutomaticApprovalCompatibilityActive)
        migrated.legacyAutomaticApprovalCompatibilityActive = false
        let revoked = try JSONDecoder().decode(
            AgentSettings.self, from: JSONEncoder().encode(migrated)
        )
        #expect(revoked.legacyApprovalPolicyOriginal == .autoApprove)
        #expect(!revoked.legacyAutomaticApprovalCompatibilityActive)
        let auditOnly = Data(#"{"approvalPolicy":"riskOnlyAsk","legacyApprovalPolicyOriginal":"autoApprove"}"#.utf8)
        let auditOnlySettings = try JSONDecoder().decode(AgentSettings.self, from: auditOnly)
        #expect(!auditOnlySettings.legacyAutomaticApprovalCompatibilityActive)
        #expect(!AgentSettings.default.legacyApprovalScopeNoticePending)
    }

    @Test func composerPolicyDefaultsWhenLegacyAgentJSONOmitsTheField() throws {
        let data = Data(#"{"maxLoopIterations":7}"#.utf8)
        let settings = try JSONDecoder().decode(AgentSettings.self, from: data)
        #expect(settings.composerPolicy == .default)
    }

    @Test func policyRuntimeDefaultsWhenLegacyAgentJSONOmitsTheField() throws {
        let data = Data(#"{"maxLoopIterations":7}"#.utf8)
        let settings = try JSONDecoder().decode(AgentSettings.self, from: data)
        #expect(settings.policyRuntimeDefaults == .default)
    }

    @Test func enumsRoundTripThroughRawValues() throws {
        #expect(Appearance(rawValue: "dark") == .dark)
        #expect(SettingsLogLevel(rawValue: "warn") == .warn)
        #expect(Appearance.allCases.count == 3)
        #expect(SettingsLogLevel.allCases.count == 4)
    }

    // MARK: - set/get 持久化往返

    @Test func keyPathUpdatePersistsAcrossStoreInstances() throws {
        let dir = try makeTempDir("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.update(\.agent.maxLoopIterations, to: 25)
        store.update(\.privacy.logLevel, to: .warn)
        // 当前合法设置写入口是 preset；appearance 是只读语义的兼容投影。
        guard case .success = store.update(\.general.themePreset, to: .light) else {
            Issue.record("当前产品主题必须成功提交")
            return
        }
        store.update(\.providerSettings["kling"], to: ["resolution": "720p", "duration": "5"])

        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(SettingsStore.fileName).path))

        // 新实例读取同一目录 → 值持久化。
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.agent.maxLoopIterations == 25)
        #expect(reloaded.settings.privacy.logLevel == .warn)
        #expect(reloaded.settings.general.themePreset == .light)
        #expect(reloaded.settings.general.appearance == .system)   // 产品主题跟随系统明暗
        #expect(reloaded.settings.general.accentTheme == .pseudo)
        #expect(reloaded.settings.general == store.settings.general)
        #expect(reloaded.settings.providerSettings["kling"] == ["resolution": "720p", "duration": "5"])
        // 未改动的字段仍是默认值。
        #expect(reloaded.settings.agent.toolTimeoutSeconds == 300)
    }

    @Test func policyRuntimeDefaultsSurviveRoundTrip() throws {
        let dir = try makeTempDir("policy-runtime")
        defer { try? FileManager.default.removeItem(at: dir) }

        let expected = ProductionPolicyDefaults(
            budget: 777,
            deadlineHorizon: 125,
            autonomyLevel: .l2,
            networkDomains: ["api.example.com"]
        )
        let store = SettingsStore(directory: dir)
        store.update(\.agent.policyRuntimeDefaults, to: expected)

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.agent.policyRuntimeDefaults == expected)
    }

    @Test func transformUpdateMutatesNestedValue() throws {
        let dir = try makeTempDir("transform")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.update(\.storage) { storage in
            storage.sessionRetentionDays = 7
            storage.autoDeleteOldSessions = true
        }
        #expect(store.settings.storage.sessionRetentionDays == 7)
        #expect(store.settings.storage.autoDeleteOldSessions == true)

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.storage.sessionRetentionDays == 7)
        #expect(reloaded.settings.storage.autoDeleteOldSessions == true)
    }

    @Test func providerSettingsSurviveRoundTrip() throws {
        let dir = try makeTempDir("provider")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.update(\.providerSettings["jimeng"], to: ["resolution": "1080p"])
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.providerSettings == ["jimeng": ["resolution": "1080p"]])
    }

    // MARK: - AJ-40/P3-SET-01 模型分组（provider-scoped submodel + 白名单）

    /// 默认：subModelReference 为 nil（继承主模型）。
    @Test func subModelIDDefaultsToNil() {
        #expect(AppSettings.defaults.general.subModelReference == nil)
        #expect(AppSettings.defaults.general.subModelID == nil)
    }

    /// Structured reference round-trip keeps provider and model identity.
    @Test func subModelIDJSONRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // 有值编码 → provider namespace + model ID 均还原。
        var s1 = AppSettings.defaults
        s1.general.subModelReference = ProviderModelReference(
            providerID: "openAI",
            modelID: "gpt-4o-mini"
        )
        let data1 = try encoder.encode(s1)
        let object1 = try #require(JSONSerialization.jsonObject(with: data1) as? [String: Any])
        let generalObject1 = try #require(object1["general"] as? [String: Any])
        #expect(generalObject1["subModelReference"] != nil)
        #expect(generalObject1["subModelID"] == nil)
        let r1 = try decoder.decode(AppSettings.self, from: data1)
        #expect(r1.general.subModelReference?.providerID == "builtin.openAI")
        #expect(r1.general.subModelReference?.modelID == "gpt-4o-mini")
        #expect(r1.general.subModelID == "gpt-4o-mini")

        // nil 编码 → 解码仍为 nil。
        var s2 = AppSettings.defaults
        s2.general.subModelID = nil
        let data2 = try encoder.encode(s2)
        let r2 = try decoder.decode(AppSettings.self, from: data2)
        #expect(r2.general.subModelID == nil)
    }

    /// Legacy bare-string JSON migrates when the old default provider is known.
    @Test func legacyBareSubModelMigratesToProviderScopedReference() throws {
        let decoder = JSONDecoder()
        let oldJSON = #"{"general":{"appearance":"system","defaultProviderID":"openAI","subModelID":"gpt-4o-mini","language":"zh-Hans"}}"#.data(using: .utf8)!
        let settings = try decoder.decode(AppSettings.self, from: oldJSON)
        #expect(settings.general.subModelReference?.providerID == "builtin.openAI")
        #expect(settings.general.subModelReference?.modelID == "gpt-4o-mini")
        #expect(settings.general.subModelID == "gpt-4o-mini")
    }

    /// Legacy bare-string JSON without a provider remains unresolved, not a
    /// model-only canonical route.
    @Test func legacyBareSubModelWithoutProviderRemainsUnresolved() throws {
        let decoder = JSONDecoder()
        let oldJSON = #"{"general":{"appearance":"system","subModelID":"gpt-4o-mini","language":"zh-Hans"}}"#.data(using: .utf8)!
        let settings = try decoder.decode(AppSettings.self, from: oldJSON)
        #expect(settings.general.subModelReference == nil)
        #expect(settings.general.subModelID == "gpt-4o-mini")
        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let generalObject = try #require(object["general"] as? [String: Any])
        #expect(generalObject["subModelReference"] == nil)
        #expect(generalObject["subModelID"] as? String == "gpt-4o-mini")
    }

    /// A legacy UI write uses the current primary provider namespace when one
    /// is available, while clearing still means inherit-primary.
    @Test func legacyProjectionWritePreservesProviderNamespace() {
        var general = GeneralSettings(defaultProviderID: "anthropic")
        general.subModelID = "claude-3-haiku"
        #expect(general.subModelReference?.providerID == "builtin.anthropic")
        #expect(general.subModelReference?.modelID == "claude-3-haiku")
        general.subModelID = nil
        #expect(general.subModelReference == nil)
    }

    /// The same model ID under two providers must remain two distinct
    /// selections; provider-free matching is forbidden.
    @Test func providerScopedReferencesDoNotCollideOnModelID() {
        let builtIn = ProviderModelReference(providerID: "openAI", modelID: "gpt-4o-mini")
        let custom = ProviderModelReference(providerID: "custom.provider-record-uuid", modelID: "gpt-4o-mini")
        #expect(builtIn.providerID == "builtin.openAI")
        #expect(custom.providerID == "custom.provider-record-uuid")
        #expect(builtIn.modelID == custom.modelID)
        #expect(builtIn != custom)
    }

    /// 旧 JSON（无 subModelID/subModelReference 键）宽容解码 → 默认为 nil。
    @Test func subModelIDMissingKeyFallsBackToNil() throws {
        let decoder = JSONDecoder()
        let oldJSON = #"{"appearance":"system","language":"zh-Hans"}"#.data(using: .utf8)!
        let s = try decoder.decode(AppSettings.self, from: oldJSON)
        #expect(s.general.subModelReference == nil)
        #expect(s.general.subModelID == nil)
        #expect(s.general.appearance == .system)
        #expect(s.general.language == "zh-Hans")
    }

    /// 白名单默认空（全部可用）。
    @Test func availableModelWhitelistDefaultsEmpty() {
        #expect(AppSettings.defaults.agent.availableModelWhitelist.isEmpty)
    }

    /// 白名单持久化往返（store 存储 + 新实例读取）。
    @Test func availableModelWhitelistSurvivesRoundTrip() throws {
        let dir = try makeTempDir("whitelist")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.update(\.agent.availableModelWhitelist, to: ["gpt-4o-mini", "claude-sonnet"])
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.agent.availableModelWhitelist == ["gpt-4o-mini", "claude-sonnet"])
    }

    // MARK: - reset

    @Test func resetToDefaultsRestoresAndPersists() throws {
        let dir = try makeTempDir("reset")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.update(\.agent.maxLoopIterations, to: 99)
        store.update(\.general.language, to: "en")
        store.update(\.privacy.collectAnalytics, to: true)
        #expect(store.settings.agent.maxLoopIterations == 99)

        store.resetToDefaults()
        #expect(store.settings == .defaults)
        #expect(store.settingsVersion == AppSettings.currentVersion)

        // reset 也持久化。
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings == .defaults)
    }

    // MARK: - 迁移

    /// v1 JSON：无 settingsVersion 之外的 v2/v3 字段（缺失 concurrentToolLimit /
    /// autoCompactThreshold / fallbackEnabled / memoryLimitMB / autoDeleteOldSessions）。
    private static let v1JSON = """
    {
      "settingsVersion": 1,
      "general": { "appearance": "dark", "language": "en" },
      "agent": { "maxLoopIterations": 5, "toolTimeoutSeconds": 120 },
      "privacy": { "redactEnvValues": false, "collectAnalytics": true },
      "storage": { "sessionRetentionDays": 14 }
    }
    """

    @Test func migrationFillsV2DefaultsFromV1JSON() throws {
        let dir = try makeTempDir("migrate")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
        try Data(Self.v1JSON.utf8).write(to: fileURL)

        let store = SettingsStore(directory: dir)
        let s = store.settings

        // 版本提升到当前 schema。
        #expect(s.settingsVersion == AppSettings.currentVersion)
        #expect(store.settingsVersion == AppSettings.currentVersion)

        // v2 新增字段补默认值。
        #expect(s.agent.concurrentToolLimit == 4)
        #expect(s.agent.autoCompactThreshold == 0.8)
        #expect(s.agent.fallbackEnabled == false)
        #expect(s.storage.memoryLimitMB == nil)
        #expect(s.storage.autoDeleteOldSessions == false)
        #expect(s.typography.uiBaseFontSize == 14)

        // 旧主题值按1115决定迁移，原值仍可从 provenance 恢复；其余配置不变。
        #expect(s.general.themePreset == .light)   // 旧深色 → 跟随系统 → 一次性迁到产品主题
        #expect(s.general.appearance == .system)
        #expect(s.general.legacyThemePresetRawValue == "dark|pseudo")
        #expect(s.general.language == "en")
        #expect(s.general.defaultProviderID == nil)
        #expect(s.agent.maxLoopIterations == 5)
        #expect(s.agent.toolTimeoutSeconds == 120)
        #expect(s.privacy.redactEnvValues == false)
        #expect(s.privacy.collectAnalytics == true)
        #expect(s.privacy.logLevel == .info)
        #expect(s.storage.sessionRetentionDays == 14)
        #expect(s.providerSettings.isEmpty)

        // 迁移结果已落盘：再次加载不再重复迁移。
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settingsVersion == AppSettings.currentVersion)
        #expect(reloaded.settings.agent.concurrentToolLimit == 4)
        #expect(reloaded.settings.general == s.general)
    }

    @Test func migrationHandlesMissingSettingsVersionKey() throws {
        let dir = try makeTempDir("migrate-noversion")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
        // 无 settingsVersion 字段 → 视为 v1 → 迁移到当前 schema。
        let json = """
        { "agent": { "maxLoopIterations": 3 } }
        """
        try Data(json.utf8).write(to: fileURL)

        let store = SettingsStore(directory: dir)
        #expect(store.settingsVersion == AppSettings.currentVersion)
        #expect(store.settings.agent.maxLoopIterations == 3)
        #expect(store.settings.agent.concurrentToolLimit == 4)
        #expect(store.settings.general.appearance == .system)
        #expect(store.settings.typography.uiBaseFontSize == 14)
    }

    @Test func migrationDirectAPIReportsMigratedFlag() throws {
        let old = try SettingsMigration.migrate(data: Data(Self.v1JSON.utf8))
        #expect(old.migrated == true)
        #expect(old.settings.settingsVersion == AppSettings.currentVersion)

        // 已是当前版本 → 不迁移。
        let encoder = JSONEncoder()
        let currentData = try encoder.encode(AppSettings.defaults)
        let current = try SettingsMigration.migrate(data: currentData)
        #expect(current.migrated == false)
        #expect(current.settings == .defaults)
    }

    @Test func migrationKeepsDeepSeekCredentialAliasesTypedAndSecretFree() throws {
        var legacy = AppSettings.defaults
        legacy.general.defaultProviderID = "HERMES_CUSTOM_DEEPSEEK_API_KEY"
        legacy.general.subModelReference = ProviderModelReference(
            providerID: "custom.HERMES_CUSTOM_DEEPSEEK_API_KEY",
            modelID: "deepseek-v4-flash"
        )
        legacy.providerSettings = [
            "HERMES_CUSTOM_DEEPSEEK_API_KEY": [
                "apiKeyEnvVar": "HERMES_CUSTOM_DEEPSEEK_API_KEY",
                "apiKey": "SYNTHETIC_SECRET_MUST_NOT_BE_COPIED",
                "baseURL": "https://api.deepseek.com/v1",
                "modelNames": "deepseek-v4-flash"
            ],
            "DEEPSEEK_API_KEY": [
                "credentialAlias": "DEEPSEEK_API_KEY",
                "protocolType": "openai_compatible"
            ]
        ]

        let encoded = try JSONEncoder().encode(legacy)
        let result = try SettingsMigration.migrate(data: encoded)

        #expect(result.migrated)
        #expect(result.settings.general.defaultProviderID == "deepseek")
        #expect(result.settings.general.subModelReference?.providerID == "builtin.deepSeek")
        #expect(result.settings.general.subModelReference?.modelID == "deepseek-v4-flash")
        let metadata = try #require(result.settings.providerSettings["deepseek"])
        #expect(metadata["recordID"] == "deepseek")
        #expect(metadata["credentialAlias"] == "DEEPSEEK_API_KEY")
        #expect(metadata["credentialAliases"] == "DEEPSEEK_API_KEY,HERMES_CUSTOM_DEEPSEEK_API_KEY")
        #expect(metadata["credentialReference"] == "DEEPSEEK_API_KEY")
        #expect(metadata["secretReference"] == "DEEPSEEK_API_KEY")
        #expect(metadata["baseURL"] == "https://api.deepseek.com/v1")
        #expect(metadata["apiKey"] == nil)
        #expect(metadata.values.allSatisfy { !$0.contains("SYNTHETIC_SECRET") })
        #expect(Array(result.settings.providerSettings.keys) == ["deepseek"])
    }

    @Test func deepSeekReferenceMigrationIsIdempotentAndDoesNotRewriteUnknownIDs() throws {
        var legacy = AppSettings.defaults
        legacy.general.defaultProviderID = "custom.random-record-id"
        legacy.providerSettings = ["custom.random-record-id": ["label": "unrelated"]]
        let first = try SettingsMigration.migrate(data: JSONEncoder().encode(legacy))
        #expect(first.migrated == false)
        #expect(first.settings.general.defaultProviderID == "custom.random-record-id")
        #expect(first.settings.providerSettings == legacy.providerSettings)

        var deepSeek = AppSettings.defaults
        deepSeek.general.defaultProviderID = "DEEPSEEK_API_KEY"
        let migrated = try SettingsMigration.migrate(data: JSONEncoder().encode(deepSeek))
        #expect(migrated.migrated)
        let second = try SettingsMigration.migrate(data: JSONEncoder().encode(migrated.settings))
        #expect(second.migrated == false)
        #expect(second.settings == migrated.settings)
    }

    @Test func emptyJSONFallsBackToDefaults() throws {
        let dir = try makeTempDir("empty")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
        try Data("{}".utf8).write(to: fileURL)

        let store = SettingsStore(directory: dir)
        #expect(store.settings.settingsVersion == AppSettings.currentVersion)
        #expect(store.settings.general == .default)
        #expect(store.settings.agent == .default)
        #expect(store.settings.privacy == .default)
        #expect(store.settings.storage == .default)
        #expect(store.settings.providerSettings.isEmpty)
    }

    // MARK: - 容错

    @Test func approvalPolicyReceiptAcceptsOnlyItsBoundSingleApply() throws {
        let dir = try makeTempDir("policy-replay")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        let before = store.settings
        var allowed = before
        allowed.agent.approvalPolicy = .riskOnlyAsk
        var mixed = allowed
        mixed.general.language = "en"
        let key = BL6SettingsApprovedInput.approvalPolicyKey
        let validInput = BL6SettingsApprovedInput(
            operation: .apply, changes: [key: .text("riskOnlyAsk")], expectedRevision: "before"
        )

        func record(_ input: BL6SettingsApprovedInput, changedKeys: [String]) -> BL6SettingsReplayRecord {
            let requestID = UUID().uuidString
            let receipt = BL6SettingsReceipt(
                requestID: requestID, operation: input.operation, previousRevision: input.expectedRevision,
                effectiveRevision: "after", changedKeys: changedKeys, rollbackValues: [:]
            )
            return BL6SettingsReplayRecord(
                requestID: requestID, payloadDigest: "payload", frozenInput: input,
                approvalBindingDigest: "approval", profileID: dir.standardizedFileURL.path,
                scope: "request", sessionID: "session", policyRevision: "policy", grantEpoch: "epoch",
                approvalExpiresAt: Date().addingTimeInterval(60), operation: input.operation, receipt: receipt,
                rollbackValues: BL6SettingsCatalog.production.completeValues(
                    overriding: [key: .text(before.agent.approvalPolicy.rawValue)]
                )
            )
        }

        let invalid: [(BL6SettingsApprovedInput, [String], AppSettings)] = [
            (.init(operation: .reset, expectedRevision: "before"), [key], allowed),
            (.init(operation: .rollback, expectedRevision: "before", undoReceiptID: "old"), [key], allowed),
            (.init(operation: .apply, changes: [key: .text("riskOnlyAsk"), "general.language": .text("en")],
                   expectedRevision: "before"), [key, "general.language"], mixed),
            (validInput, [key], mixed),
            (validInput, [], allowed),
            (.init(operation: .apply, changes: ["general.language": .text("en")],
                   expectedRevision: "before"), ["general.language"], mixed)
        ]
        let bytes = try Data(contentsOf: store.fileURL)
        for (input, keys, candidate) in invalid {
            let rejected = record(input, changedKeys: keys)
            #expect(store.commitBL6Replay(expectedSettings: before, candidate: candidate, record: rejected)
                == .failure(.conflict))
            #expect(try store.bl6ReplayRecord(for: rejected.requestID).get() == nil)
        }
        #expect(try Data(contentsOf: store.fileURL) == bytes)
        let approved = record(validInput, changedKeys: [key])
        #expect(try store.commitBL6Replay(expectedSettings: before, candidate: allowed, record: approved).get()
            == approved.receipt)
        let reopened = SettingsStore(directory: dir)
        #expect(reopened.settings.agent.approvalPolicy == .riskOnlyAsk)
        #expect(try reopened.bl6ReplayRecord(for: approved.requestID).get() == approved)
    }

    private func languageReplay(
        requestID: String,
        directory: URL,
        before: String,
        after: String,
        previousRevision: String,
        effectiveRevision: String
    ) -> BL6SettingsReplayRecord {
        let key = "general.language"
        let input = BL6SettingsApprovedInput(
            operation: .apply, changes: [key: .text(after)], expectedRevision: previousRevision
        )
        let receipt = BL6SettingsReceipt(
            requestID: requestID, operation: .apply, previousRevision: previousRevision,
            effectiveRevision: effectiveRevision, changedKeys: [key], rollbackValues: [:]
        )
        return BL6SettingsReplayRecord(
            requestID: requestID, payloadDigest: "payload-\(requestID)", frozenInput: input,
            approvalBindingDigest: "approval-\(requestID)", profileID: directory.standardizedFileURL.path,
            scope: "synthetic-scope", sessionID: "synthetic-session", policyRevision: "policy",
            grantEpoch: "epoch", approvalExpiresAt: Date().addingTimeInterval(3600),
            operation: .apply, receipt: receipt,
            rollbackValues: BL6SettingsCatalog.production.completeValues(overriding: [key: .text(before)])
        )
    }

    @Test func relocatedSettingsCanPersistAndResetWithoutRebindingReplay() throws {
        let root = try makeTempDir("profile-relocation")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let origin = root.appendingPathComponent("before", isDirectory: true)
        let destination = root.appendingPathComponent("after", isDirectory: true)
        let source = SettingsStore(directory: origin)
        let initial = source.settings
        var applied = initial
        applied.general.language = "en"
        let original = languageReplay(
            requestID: "original", directory: origin, before: initial.general.language, after: "en",
            previousRevision: "initial", effectiveRevision: "applied"
        )
        try #require(try source.commitBL6Replay(expectedSettings: initial, candidate: applied, record: original).get()
            == original.receipt)
        try fm.moveItem(at: origin, to: destination)

        let moved = SettingsStore(directory: destination)
        #expect(moved.settings == applied)
        #expect(moved.lastPersistenceError == nil)
        #expect(moved.update(\.agent.maxLoopIterations, to: 42) == .success(.persisted))
        let reopened = SettingsStore(directory: destination)
        #expect(reopened.settings.agent.maxLoopIterations == 42)
        #expect(reopened.settings.general.language == "en")
        #expect(reopened.resetToDefaults() == .success(.persisted))

        let reset = SettingsStore(directory: destination)
        #expect(reset.settings == .defaults)
        #expect(try reset.bl6ReplayRecord(for: original.requestID).get() == original)
        #expect(try reset.bl6ReplayRecord(receiptID: original.receipt.receiptID).get() == original)
        let resetBytes = try Data(contentsOf: reset.fileURL)
        #expect(reset.commitBL6Replay(expectedSettings: reset.settings, candidate: applied, record: original)
            == .failure(.conflict))
        #expect(try Data(contentsOf: reset.fileURL) == resetBytes)

        var localCandidate = reset.settings
        localCandidate.general.language = "ja"
        let local = languageReplay(
            requestID: "local", directory: destination, before: reset.settings.general.language, after: "ja",
            previousRevision: "reset", effectiveRevision: "local"
        )
        #expect(reset.commitBL6Replay(expectedSettings: applied, candidate: localCandidate, record: local)
            == .failure(.staleRevision))
        try #require(try reset.commitBL6Replay(expectedSettings: reset.settings, candidate: localCandidate, record: local).get()
            == local.receipt)
        let mixedHistory = SettingsStore(directory: destination)
        #expect(mixedHistory.settings == localCandidate)
        #expect(try mixedHistory.bl6ReplayRecord(for: original.requestID).get() == original)
        let localBytes = try Data(contentsOf: mixedHistory.fileURL)
        #expect(try mixedHistory.commitBL6Replay(expectedSettings: initial, candidate: initial, record: local).get()
            == local.receipt)
        #expect(try Data(contentsOf: mixedHistory.fileURL) == localBytes)
    }

    @Test(arguments: ["../foreign-profile", "future-envelope"])
    func invalidRelocatedReplayMetadataRemainsReadOnly(_ defect: String) throws {
        let root = try makeTempDir("profile-relocation-invalid")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let origin = root.appendingPathComponent("before", isDirectory: true)
        let destination = root.appendingPathComponent("after", isDirectory: true)
        let source = SettingsStore(directory: origin)
        let initial = source.settings
        var applied = initial
        applied.general.language = "en"
        let original = languageReplay(
            requestID: "original", directory: origin, before: initial.general.language, after: "en",
            previousRevision: "initial", effectiveRevision: "applied"
        )
        try #require(try source.commitBL6Replay(expectedSettings: initial, candidate: applied, record: original).get()
            == original.receipt)

        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source.fileURL)) as? [String: Any])
        var replay = try #require(object["_bl6Replay"] as? [String: Any])
        if defect == "future-envelope" {
            replay["version"] = 2
        } else {
            var records = try #require(replay["records"] as? [String: [String: Any]])
            records[original.requestID]?["profileID"] = defect
            replay["records"] = records
        }
        object["_bl6Replay"] = replay
        let invalidBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try invalidBytes.write(to: source.fileURL, options: .atomic)
        try fm.moveItem(at: origin, to: destination)

        let moved = SettingsStore(directory: destination)
        #expect(moved.settings == applied)
        #expect(moved.lastPersistenceError == .transactionRecoveryRequired)
        #expect(moved.update(\.general.language, to: "ja") == .failure(.transactionRecoveryRequired))
        #expect(moved.resetToDefaults() == .failure(.transactionRecoveryRequired))
        #expect(moved.bl6ReplayRecord(for: original.requestID) == .failure(.transactionRecoveryRequired))
        #expect(try Data(contentsOf: moved.fileURL) == invalidBytes)
    }

    // D3：损坏文件 → 备份 + 覆写为初始值，不再静默残留。
    @Test func corruptFileBacksUpAndRecoversToInitial() throws {
        let dir = try makeTempDir("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
        try Data("not-json{{{".utf8).write(to: fileURL)

        // 损坏文件 → 使用 initial（自定义初始值也可注入）。
        var custom = AppSettings.defaults
        custom.agent.maxLoopIterations = 42
        let store = SettingsStore(directory: dir, initial: custom)
        #expect(store.settings.agent.maxLoopIterations == 42)
        #expect(store.settings.general == .default)

        // D3：损坏文件被重命名为 `.corrupt-*` 备份，不再静默残留。
        let fm = FileManager.default
        let backups = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(SettingsStore.fileName + ".corrupt-") }
        #expect(!backups.isEmpty, "应生成损坏文件备份")
        let backupURL = URL(fileURLWithPath: dir.path).appendingPathComponent(backups[0])
        let backupText = String(data: try Data(contentsOf: backupURL), encoding: .utf8)
        #expect(backupText == "not-json{{{")
        // F-15：备份位置对外可读，界面据此告诉用户原文件在哪。
        #expect(store.corruptBackupURL?.lastPathComponent == backups[0])
        #expect(SettingsStore(directory: try makeTempDir("no-corrupt-backup")).corruptBackupURL == nil)

        // 主文件已被覆写为合法默认设置。
        #expect(fm.fileExists(atPath: fileURL.path))
        let nowSettings = SettingsStore(directory: dir, initial: custom)
        #expect(nowSettings.settings.settingsVersion == AppSettings.currentVersion)
        // 二次加载不再回退（已是合法文件），保留 injected 值。
        #expect(nowSettings.settings.agent.maxLoopIterations == 42)

        // 备份只生成一次（加载已修复的文件不会重复备份）。
        let backupsAfterReload = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(SettingsStore.fileName + ".corrupt-") }
        #expect(backupsAfterReload.count == backups.count)
    }

    @Test func preparedSettingsRecoveryFailsClosedUntilProvenCleanup() throws {
        let dir = try makeTempDir("pending-prepared")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
        let originalBytes = Data("not-json{{{".utf8)
        try originalBytes.write(to: fileURL)
        let operationID = UUID()
        let marker = try writePendingSettingsRecoveryMarker(
            in: dir,
            operationID: operationID,
            destinationName: "\(SettingsStore.fileName).corrupt-manual",
            payloadDigest: settingsDigest(originalBytes),
            phase: "prepared"
        )

        let store = SettingsStore(directory: dir)
        #expect(store.lastPersistenceError == .transactionRecoveryRequired)
        #expect(try Data(contentsOf: fileURL) == originalBytes)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(store.update(\.general.appearance, to: .dark) == .failure(.writeFailed))

        #expect(try store.recoverPendingTransactions() == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let recovered = SettingsStore(directory: dir)
        #expect(recovered.settings == .defaults)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(SettingsStore.fileName + ".corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(backups[0])) == originalBytes)
    }

    @Test func movedSettingsRecoveryPreservesBackupBytesBeforeReopen() throws {
        let dir = try makeTempDir("pending-moved")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
        let originalBytes = Data("future-settings-payload".utf8)
        try originalBytes.write(to: fileURL)
        let destinationName = "\(SettingsStore.fileName).corrupt-moved"
        let destinationURL = dir.appendingPathComponent(destinationName)
        try FileManager.default.moveItem(at: fileURL, to: destinationURL)
        let operationID = UUID()
        let marker = try writePendingSettingsRecoveryMarker(
            in: dir,
            operationID: operationID,
            destinationName: destinationName,
            payloadDigest: settingsDigest(originalBytes),
            phase: "moved"
        )

        let store = SettingsStore(directory: dir)
        #expect(store.lastPersistenceError == .transactionRecoveryRequired)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: destinationURL) == originalBytes)
        #expect(try store.recoverPendingTransactions() == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: destinationURL) == originalBytes)

        let reopened = SettingsStore(directory: dir)
        #expect(reopened.settings == .defaults)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: destinationURL) == originalBytes)
    }

    @Test func failedCorruptOrFutureBackupPreservesOriginalBytesAndReportsTypedError() throws {
        let cases: [(String, Data)] = [
            ("corrupt", Data("not-json{{{".utf8)),
            ("future", try JSONEncoder().encode({
                var settings = AppSettings.defaults
                settings.settingsVersion = AppSettings.currentVersion + 1
                return settings
            }()))
        ]

        for (label, originalBytes) in cases {
            let dir = try makeTempDir("backup-failure-\(label)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
            try originalBytes.write(to: fileURL, options: .atomic)

            var callbackError: SettingsPersistenceError?
            let store = SettingsStore(
                directory: dir,
                initial: .defaults,
                onPersistError: { error in
                    callbackError = error as? SettingsPersistenceError
                },
                backupFileManager: FailingMoveFileManager()
            )

            #expect(store.settings == .defaults)
            #expect(store.lastPersistenceError == .writeFailed)
            #expect(callbackError == .writeFailed)
            #expect(try Data(contentsOf: fileURL) == originalBytes)
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test func futureVersionBacksUpBeforeRecoveringToInitial() throws {
        let dir = try makeTempDir("future-version")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
        var future = AppSettings.defaults
        future.settingsVersion = AppSettings.currentVersion + 1
        let originalBytes = try JSONEncoder().encode(future)
        try originalBytes.write(to: fileURL, options: .atomic)

        let store = SettingsStore(directory: dir)
        #expect(store.settings == .defaults)
        #expect(store.lastPersistenceError == nil)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(SettingsStore.fileName + ".corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(backups[0])) == originalBytes)
        #expect(try Data(contentsOf: fileURL) != originalBytes)
        #expect(SettingsStore(directory: dir).settings == .defaults)
    }

    @Test func backupFailureProtectsUpdateReplaceUntilExplicitReset() throws {
        let cases: [(String, Data)] = [
            ("corrupt", Data("not-json{{{".utf8)),
            ("future", try JSONEncoder().encode({
                var settings = AppSettings.defaults
                settings.settingsVersion = AppSettings.currentVersion + 1
                return settings
            }()))
        ]

        for (label, originalBytes) in cases {
            let dir = try makeTempDir("backup-lifecycle-\(label)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
            try originalBytes.write(to: fileURL, options: .atomic)

            let store = SettingsStore(
                directory: dir,
                initial: .defaults,
                backupFileManager: FailingMoveFileManager()
            )
            var candidate = AppSettings.defaults
            candidate.general.appearance = .dark
            #expect(store.update(
                \.general.appearance,
                to: .dark
            ) == .failure(.writeFailed))
            #expect(try Data(contentsOf: fileURL) == originalBytes)
            #expect(store.replace(with: candidate) == .failure(.writeFailed))
            #expect(try Data(contentsOf: fileURL) == originalBytes)

            #expect(store.resetToDefaults() == .success(.persisted))
            #expect(store.settings == .defaults)
            #expect(store.lastPersistenceError == nil)
            #expect(try Data(contentsOf: fileURL) != originalBytes)
            let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix(SettingsStore.fileName + ".corrupt-") }
            #expect(backups.count == 1)
            #expect(try Data(contentsOf: dir.appendingPathComponent(backups[0])) == originalBytes)
            #expect(SettingsStore(directory: dir).settings == .defaults)
        }
    }

    // D6：defaultDirectory 不再 `.first!` 强解包，Application Support 不可用回退临时目录。
    @Test func defaultDirectoryDoesNotForceUnwrapApplicationSupport() throws {
        let dir = SettingsStore.defaultDirectory()
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func persistErrorCallbackFiresOnUnwritableDirectory() throws {
        // 用普通文件冒充目录路径，保证写入失败。
        let dir = try makeTempDir("errdir")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent(SettingsStore.fileName)
        try Data("x".utf8).write(to: blocker)
        // 让 fileURL 指向一个「目录」→ write(.atomic) 失败。
        let storeDir = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: storeDir)
        try Data("x".utf8).write(to: storeDir) // 普通文件占用目录路径

        var errorCount = 0
        let store = SettingsStore(directory: storeDir) { _ in errorCount += 1 }
        store.update(\.agent.maxLoopIterations, to: 1)
        #expect(errorCount > 0)
    }

    @Test func failedUpdateDoesNotMutateInMemoryState() throws {
        let dir = try makeTempDir("transactional-failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blockedDirectory = dir.appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blockedDirectory)

        let store = SettingsStore(directory: blockedDirectory)
        let before = store.settings
        let result = store.update(\.general.appearance, to: .dark)

        #expect(result == .failure(.directoryCreationFailed))
        #expect(store.settings == before)
        #expect(store.lastPersistenceError == .directoryCreationFailed)
        let restarted = SettingsStore(directory: blockedDirectory)
        #expect(restarted.settings == before)
    }

    @Test func failedResetDoesNotMutateInMemoryState() throws {
        let dir = try makeTempDir("transactional-reset-failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.update(\.general.appearance, to: .dark) == .success(.persisted))

        let settingsFile = dir.appendingPathComponent(SettingsStore.fileName)
        try FileManager.default.removeItem(at: settingsFile)
        try FileManager.default.createDirectory(at: settingsFile, withIntermediateDirectories: true)
        let result = store.resetToDefaults()

        #expect(result == .failure(.writeFailed))
        #expect(store.settings.general.appearance == .dark)
        #expect(store.lastPersistenceError == .writeFailed)
    }

    @Test func wholeSettingsReplacePersistsAsOneCandidate() throws {
        let dir = try makeTempDir("transactional-replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        var candidate = store.settings
        candidate.general.setThemePreset(.dark)
        candidate.agent.maxLoopIterations = 42
        candidate.providerSettings = ["sync": ["source": "snapshot"]]

        #expect(store.replace(with: candidate) == .success(.persisted))
        #expect(store.settings == candidate)
        #expect(SettingsStore(directory: dir).settings == candidate)
    }

    @Test func failedWholeSettingsReplaceDoesNotMutateInMemoryState() throws {
        let dir = try makeTempDir("transactional-replace-failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        var candidate = store.settings
        candidate.general.appearance = .dark
        let before = store.settings

        let settingsFile = dir.appendingPathComponent(SettingsStore.fileName)
        try FileManager.default.removeItem(at: settingsFile)
        try FileManager.default.createDirectory(at: settingsFile, withIntermediateDirectories: true)

        #expect(store.replace(with: candidate) == .failure(.writeFailed))
        #expect(store.settings == before)
        #expect(store.lastPersistenceError == .writeFailed)
    }
}

struct CCRound2LimitsSettingsTests {
    @Test func legacyTenRequiresOneAcknowledgementAndKeepsValue() throws {
        let old = Data(#"{"maxLoopIterations":10,"maxTokensPerSession":240000,"childMutationsEnabled":false}"#.utf8)
        var migrated = try JSONDecoder().decode(AgentSettings.self, from: old)
        #expect(migrated.maxLoopIterations == 10)
        #expect(!migrated.maxLoopIterationsNoticeAcknowledged)
        #expect(migrated.maxTokensPerSession == 240000)
        #expect(migrated.childMutationsEnabled)
        migrated.maxLoopIterationsNoticeAcknowledged = true
        migrated.childMutationsEnabled = false
        migrated.childMutationsExplicitlySelected = true
        let restored = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(migrated))
        #expect(restored == migrated)
        #expect(!restored.childMutationsEnabled)
    }

    @Test func missingFieldsAndIterationBoundaries() throws {
        let empty = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(empty.maxLoopIterations == 50)
        #expect(empty.maxTokensPerSession == 1_000_000)
        #expect(empty.browserWriteEnabled)
        var explicitBrowserOff = empty
        explicitBrowserOff.browserWriteEnabled = false
        #expect(try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(explicitBrowserOff)).browserWriteEnabled == false)
        #expect(empty.maxLoopIterationsNoticeAcknowledged)
        #expect(AgentSettings(maxLoopIterations: 999).maxLoopIterations == 100)
        #expect(AgentSettings(maxLoopIterations: -1).maxLoopIterations == 1)
    }
}
