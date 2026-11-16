import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

private final class U5InMemoryKeychainBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
        return true
    }
}

// MARK: - U5 模型供应商配置增强
//
// 用户诉求：新增模型供应商时除了名字和 key，还要能填 Base URL、多个模型名，
// 并选择 URL 支持的协议类型（OpenAI 兼容 / Anthropic / 其他），参照 Codex /
// Hermes 的新增模型配置（base_url + api_key + 模型列表 + wire API 类型）。
//
// 覆盖范围：
//   1. EnvVarEntry 编解码向后兼容（旧版 envvars.json 缺省字段默认值解码）；
//   2. ProviderWireProtocol 未知 raw value 回退默认（不让整文件解码失败）；
//   3. EnvVarStore.saveProvider 多模型名增删 + 落盘 + 重载存活；
//   4. 既有 key 读取路径（getEnvVar / EnvCredentials 补充源）不被破坏；
//   5. SettingsCenter 接线（providerRecords 快照、saveProvider、deleteProvider）。

@Suite("U5 供应商配置数据模型与持久化")
struct U5ProviderModelTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("U5Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: 向后兼容（旧数据解码）

    @Test func legacyJSONWithoutNewFieldsDecodesWithDefaults() throws {
        // 旧版本写出的 envvars.json：只有 id/name/value/isSecret/createdAt。
        let legacyJSON = """
        [
          {
            "id": "legacy-1",
            "name": "OPENAI_API_KEY",
            "value": "sk-legacy-value",
            "isSecret": true,
            "createdAt": 700000000
          }
        ]
        """
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent(EnvVarStore.fileName)
        try legacyJSON.data(using: .utf8)!.write(to: fileURL)

        let store = EnvVarStore(directory: dir)
        let entry = try #require(store.entry(name: "OPENAI_API_KEY"))

        // 旧字段原样保留
        #expect(entry.id == "legacy-1")
        #expect(entry.value == "sk-legacy-value")
        #expect(entry.isSecret == true)

        // U5 新字段全部落到缺省值
        #expect(entry.baseURL == nil)
        #expect(entry.modelNames.isEmpty)
        #expect(entry.protocolType == .openaiCompatible)
        #expect(!entry.isProviderRecord)

        // 既有 key 读取路径不变
        #expect(store.getEnvVar(name: "openai_api_key") == "sk-legacy-value")
        #expect(store.providerRecords.isEmpty)
    }

    @Test func unknownProtocolRawValueFailsClosedWithoutLosingMetadata() throws {
        // 更高版本写入的新协议类型仍能解码，但不能降格为 Chat Completions。
        let futureJSON = """
        [
          {
            "id": "future-1",
            "name": "FUTURE_API_KEY",
            "value": "v",
            "isSecret": false,
            "createdAt": 700000000,
            "baseURL": "https://future.example.com/v1",
            "modelNames": ["m1"],
            "protocolType": "some_future_protocol"
          }
        ]
        """
        let dir = try makeTempDir()
        try futureJSON.data(using: .utf8)!.write(to: dir.appendingPathComponent(EnvVarStore.fileName))

        let store = EnvVarStore(directory: dir)
        let entry = try #require(store.entry(name: "FUTURE_API_KEY"))
        #expect(entry.protocolType == .other)
        #expect(entry.baseURL == "https://future.example.com/v1")
        #expect(entry.modelNames == ["m1"])
    }

    @Test func responsesProviderConfigurationMapsToResponsesRuntime() {
        let entry = EnvVarEntry(
            name: "RESPONSES_API_KEY",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://api.openai.com/v1",
            modelNames: ["gpt-4o"],
            protocolType: .openaiResponses
        )
        let snapshot = SettingsProviderConfigurationSnapshot(entry: entry)
        #expect(snapshot.isValid)
        #expect(snapshot.providerType == .openAIResponses)
        #expect(snapshot.providerConfig?.providerType == .openAIResponses)
        #expect(snapshot.providerConfig?.appendV1Suffix == true)
    }

    @Test func providerEntryRoundTripKeepsAllFields() throws {
        let dir = try makeTempDir()
        let store = EnvVarStore(directory: dir)
        #expect(store.saveProvider(
            name: "MY_LLM_KEY",
            apiKey: "sk-roundtrip",
            baseURL: " https://api.example.com/v1 ",
            modelNames: ["  model-a ", "", "model-b"],
            protocolType: .anthropic
        ))

        // 从磁盘重新加载 → 全部字段存活；baseURL/模型名已按清洗规则 trim/去空。
        let reloaded = EnvVarStore(directory: dir)
        let entry = try #require(reloaded.entry(name: "MY_LLM_KEY"))
        // 惰性加载：key 值经 getEnvVar 从 Keychain 读回（entry.value 为占位空串）
        #expect(reloaded.getEnvVar(name: "MY_LLM_KEY") == "sk-roundtrip")
        #expect(entry.isSecret == true)
        #expect(entry.baseURL == "https://api.example.com/v1")
        #expect(entry.modelNames == ["model-a", "model-b"])
        #expect(entry.protocolType == .anthropic)
        #expect(entry.isProviderRecord)
    }

    @Test func providerWireProtocolRawValuesMatchSpec() {
        // 任务规定枚举 raw value：openai_compatible / anthropic / other，默认前者。
        #expect(ProviderWireProtocol.openaiCompatible.rawValue == "openai_compatible")
        #expect(ProviderWireProtocol.anthropic.rawValue == "anthropic")
        #expect(ProviderWireProtocol.other.rawValue == "other")
        #expect(ProviderWireProtocol(rawValue: "openai_compatible") == .openaiCompatible)
        #expect(ProviderWireProtocol(rawValue: "nope") == nil)
    }

    // MARK: 多模型名增删 + 既有读取路径不破坏

    @Test func multipleModelNamesAddRemoveAndPersist() throws {
        let dir = try makeTempDir()
        let store = EnvVarStore(directory: dir)

        // 初始三个模型
        #expect(store.saveProvider(
            name: "PROVIDER_X",
            apiKey: "sk-1",
            baseURL: "https://x.example.com/v1",
            modelNames: ["m1", "m2", "m3"],
            protocolType: .openaiCompatible
        ))
        #expect(store.entry(name: "PROVIDER_X")?.modelNames == ["m1", "m2", "m3"])

        // 更新：删 m2、加 m4（编辑表单全量提交语义）
        #expect(store.saveProvider(
            name: "provider_x",  // 名称大小写规范化，仍命中同一条目
            apiKey: "sk-2",
            baseURL: nil,         // Base URL 可选，允许清空
            modelNames: ["m1", "m3", "m4"],
            protocolType: .other
        ))
        let updated = try #require(store.entry(name: "PROVIDER_X"))
        #expect(updated.modelNames == ["m1", "m3", "m4"])
        #expect(updated.baseURL == nil)
        #expect(updated.protocolType == .other)
        #expect(updated.value == "sk-2")
        #expect(store.count == 1)  // 覆盖更新而非新增

        // 落盘后重载仍一致
        let reloaded = EnvVarStore(directory: dir)
        #expect(reloaded.entry(name: "PROVIDER_X")?.modelNames == ["m1", "m3", "m4"])
    }

    @Test func existingKeyReadPathUnchanged() throws {
        let dir = try makeTempDir()
        let store = EnvVarStore(directory: dir)

        // 普通环境变量与供应商记录共存：既有 setEnvVar/getEnvVar 路径不受影响。
        #expect(store.setEnvVar(name: "PLAIN_VAR", value: "plain-value", isSecret: false))
        #expect(store.saveProvider(
            name: "PROV_KEY",
            apiKey: "sk-prov",
            baseURL: "https://p.example.com",
            modelNames: ["a"],
            protocolType: .openaiCompatible
        ))

        #expect(store.getEnvVar(name: "PLAIN_VAR") == "plain-value")
        // 供应商的 API key 同样走 getEnvVar（EnvCredentials 补充源读取路径）。
        #expect(store.getEnvVar(name: "PROV_KEY") == "sk-prov")
        // providerRecords 只含供应商记录。
        #expect(store.providerRecords.map(\.name) == ["PROV_KEY"])
        #expect(store.allEnvVars.count == 2)

        // 删除供应商记录走既有 deleteEnvVar 路径。
        #expect(store.deleteEnvVar(name: "PROV_KEY"))
        #expect(store.getEnvVar(name: "PROV_KEY") == nil)
        #expect(store.providerRecords.isEmpty)
        #expect(store.getEnvVar(name: "PLAIN_VAR") == "plain-value")
    }

    @Test func invalidProviderNameRejected() throws {
        let dir = try makeTempDir()
        let store = EnvVarStore(directory: dir)
        #expect(!store.saveProvider(
            name: "1BAD NAME!", apiKey: "sk", baseURL: nil,
            modelNames: [], protocolType: .openaiCompatible
        ))
        #expect(store.providerRecords.isEmpty)
    }
}

// MARK: - U5 SettingsCenter 接线

@Suite("U5 供应商配置 SettingsCenter 接线")
@MainActor
struct U5ProviderSettingsCenterTests {

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
    }

    /// 全临时目录中心（不碰 Application Support）。
    private func makeCenter(
        directory: URL? = nil,
        keychain: KeychainStore? = nil
    ) throws -> SettingsCenter {
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("U5CenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keychain = keychain ?? KeychainStore(backing: U5InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir, keychain: keychain),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: dir.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills"))
        )
    }

    @Test func saveProviderUpdatesSnapshotAndPersists() throws {
        let center = try makeCenter()
        #expect(center.providerRecords.isEmpty)

        #expect(center.saveProvider(
            name: "my_provider_api_key",
            apiKey: "sk-ui",
            baseURL: "https://ui.example.com/v1",
            modelNames: ["m1", "m2"],
            protocolType: .openaiCompatible
        ))

        // 快照立即刷新（reloadEnv 联动）
        #expect(center.providerRecords.count == 1)
        let record = try #require(center.providerRecords.first)
        #expect(record.name == "MY_PROVIDER_API_KEY")
        #expect(record.baseURL == "https://ui.example.com/v1")
        #expect(record.modelNames == ["m1", "m2"])
        #expect(record.protocolType == .openaiCompatible)
        #expect(record.isSecret)

        // 普通环境变量快照同时包含该记录（环境变量页仍能看到 key）
        #expect(center.envEntries.contains { $0.name == "MY_PROVIDER_API_KEY" })

        // 编辑：增删模型名 + 换协议 → 覆盖更新
        #expect(center.saveProvider(
            name: "MY_PROVIDER_API_KEY",
            apiKey: "sk-ui-2",
            baseURL: nil,
            modelNames: ["m2", "m3"],
            protocolType: .anthropic
        ))
        #expect(center.providerRecords.count == 1)
        #expect(center.providerRecords.first?.modelNames == ["m2", "m3"])
        #expect(center.providerRecords.first?.baseURL == nil)
        #expect(center.providerRecords.first?.protocolType == .anthropic)

        // key 读取路径（F6 EnvCredentials 补充源依赖此接口）不变
        #expect(center.envStore.getEnvVar(name: "MY_PROVIDER_API_KEY") == "sk-ui-2")
    }

    @Test func settingsCenterMetadataEditKeepsExistingCredential() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("U5CenterKeep-\(UUID().uuidString)", isDirectory: true)
        let keychain = KeychainStore(backing: U5InMemoryKeychainBacking())
        let center = try makeCenter(directory: dir, keychain: keychain)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(center.saveProvider(
            name: "CENTER_KEEP_PROVIDER",
            apiKey: "sk-center",
            baseURL: "https://old.example/v1",
            modelNames: ["old"],
            protocolType: .openaiCompatible
        ))
        #expect(center.saveProvider(
            name: "CENTER_KEEP_PROVIDER",
            credential: .keepExisting,
            baseURL: "https://new.example/v1",
            modelNames: ["new"],
            protocolType: .anthropic
        ))

        let reloaded = EnvVarStore(directory: dir, keychain: keychain)
        #expect(await reloaded.getEnvVarAsync(name: "CENTER_KEEP_PROVIDER") == "sk-center")
        #expect(reloaded.entry(name: "CENTER_KEEP_PROVIDER")?.baseURL == "https://new.example/v1")
    }

    @Test func deleteProviderRemovesRecord() throws {
        let center = try makeCenter()
        #expect(center.saveProvider(
            name: "DEL_ME_KEY", apiKey: "sk-del-1", baseURL: nil,
            modelNames: ["only"], protocolType: .other
        ))
        #expect(center.providerRecords.count == 1)

        let deletion = try center.previewProviderDeletion(name: "DEL_ME_KEY")
        _ = try center.deleteProvider(name: "DEL_ME_KEY", intent: confirmed(deletion))
        #expect(center.providerRecords.isEmpty)
        #expect(center.envEntries.isEmpty)
        #expect(center.envStore.getEnvVar(name: "DEL_ME_KEY") == nil)
    }

    @Test func renameProviderSyncsDefaultProviderID() throws {
        let center = try makeCenter()
        #expect(center.saveProvider(
            name: "old_provider_key", apiKey: "sk-ren-1", baseURL: nil,
            modelNames: ["m1"], protocolType: .openaiCompatible
        ))
        // 该自定义供应商被设为默认 Provider
        center.defaultProviderID = "custom.OLD_PROVIDER_KEY"
        center.defaultModelID = "m1"

        let deletion = try center.previewProviderRename(from: "OLD_PROVIDER_KEY", to: "NEW_NAME_KEY")
        _ = try center.renameProvider(
            from: "OLD_PROVIDER_KEY",
            to: "NEW_NAME_KEY",
            intent: confirmed(deletion)
        )

        // L1 P1 修复：改名 = 完整迁移（旧删新建），记录保留而非清空；
        // defaultProviderID 同步到新名
        #expect(center.providerRecords.map(\.name) == ["NEW_NAME_KEY"],
                "改名后记录应迁移保留；实际 \(center.providerRecords.map(\.name))")
        #expect(center.defaultProviderID == "custom.NEW_NAME_KEY")
        #expect(center.defaultModelID == "m1")
    }

    @Test func providerRenameReadsCurrentKeychainCredential() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("U5CenterRenameKeychain-\(UUID().uuidString)", isDirectory: true)
        let keychain = KeychainStore(backing: U5InMemoryKeychainBacking())
        let center = try makeCenter(directory: dir, keychain: keychain)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(center.saveProvider(
            name: "RENAME_KEYCHAIN_PROVIDER",
            apiKey: "sk-rename",
            baseURL: "https://rename.example/v1",
            modelNames: ["model"],
            protocolType: .openaiCompatible
        ))
        let restarted = try makeCenter(directory: dir, keychain: keychain)
        let preview = try restarted.previewProviderRename(
            from: "RENAME_KEYCHAIN_PROVIDER",
            to: "RENAMED_KEYCHAIN_PROVIDER"
        )
        _ = try await restarted.renameProviderAsync(
            from: "RENAME_KEYCHAIN_PROVIDER",
            to: "RENAMED_KEYCHAIN_PROVIDER",
            intent: confirmed(preview)
        )

        #expect(await restarted.envStore.getEnvVarAsync(name: "RENAMED_KEYCHAIN_PROVIDER") == "sk-rename")
        #expect(await restarted.envStore.getEnvVarAsync(name: "RENAME_KEYCHAIN_PROVIDER") == nil)
    }

    @Test func renameProviderNonDefaultUntouched() throws {
        let center = try makeCenter()
        #expect(center.saveProvider(
            name: "other_key", apiKey: "sk-ren-2", baseURL: nil,
            modelNames: ["m1"], protocolType: .openaiCompatible
        ))
        center.defaultProviderID = "builtin.openai"
        let deletion = try center.previewProviderRename(from: "OTHER_KEY", to: "RENAMED_KEY")
        _ = try center.renameProvider(
            from: "OTHER_KEY",
            to: "RENAMED_KEY",
            intent: confirmed(deletion)
        )
        #expect(center.defaultProviderID == "builtin.openai")
        // L1 P1 修复：非默认供应商改名同样迁移保留（不丢数据）
        #expect(center.providerRecords.map(\.name) == ["RENAMED_KEY"],
                "改名后记录应迁移保留；实际 \(center.providerRecords.map(\.name))")
    }

    @Test func renameProviderPersistsEditedConfigurationAfterConfirmation() throws {
        let center = try makeCenter()
        #expect(center.saveProvider(
            name: "EDITABLE_PROVIDER",
            apiKey: "sk-old",
            baseURL: "https://old.example.com/v1",
            modelNames: ["old-model"],
            protocolType: .openaiCompatible
        ))

        let preview = try center.previewProviderRename(from: "EDITABLE_PROVIDER", to: "EDITED_PROVIDER")
        _ = try center.renameProvider(
            from: "EDITABLE_PROVIDER",
            to: "EDITED_PROVIDER",
            apiKey: "sk-new",
            baseURL: "https://new.example.com/v1",
            modelNames: ["new-model", "fallback-model"],
            protocolType: .anthropic,
            intent: confirmed(preview)
        )

        let record = try #require(center.providerRecords.first)
        #expect(record.name == "EDITED_PROVIDER")
        #expect(record.value == "sk-new")
        #expect(record.baseURL == "https://new.example.com/v1")
        #expect(record.modelNames == ["new-model", "fallback-model"])
        #expect(record.protocolType == .anthropic)
        #expect(center.envStore.getEnvVar(name: "EDITED_PROVIDER") == "sk-new")
        #expect(center.envStore.getEnvVar(name: "EDITABLE_PROVIDER") == nil)
    }

    @Test func convertingPlainEnvironmentEntryToProviderSupportsConfirmedRename() throws {
        let center = try makeCenter()
        #expect(center.setEnvVar(name: "LEGACY_API_KEY", value: "sk-legacy", isSecret: true))

        let preview = try center.previewProviderRename(from: "LEGACY_API_KEY", to: "RENAMED_PROVIDER")
        _ = try center.renameProvider(
            from: "LEGACY_API_KEY",
            to: "RENAMED_PROVIDER",
            apiKey: "sk-legacy",
            baseURL: "https://provider.example/v1",
            modelNames: ["model-a"],
            protocolType: .openaiCompatible,
            intent: confirmed(preview)
        )

        let record = try #require(center.providerRecords.first)
        #expect(record.name == "RENAMED_PROVIDER")
        #expect(record.baseURL == "https://provider.example/v1")
        #expect(record.modelNames == ["model-a"])
        #expect(center.envStore.getEnvVar(name: "RENAMED_PROVIDER") == "sk-legacy")
        #expect(center.envStore.getEnvVar(name: "LEGACY_API_KEY") == nil)
    }

    @Test func providerRenameRejectsCollisionWithPlainEnvironmentEntry() throws {
        let center = try makeCenter()
        #expect(center.saveProvider(
            name: "SOURCE_PROVIDER", apiKey: "sk-source", baseURL: nil,
            modelNames: ["model-a"], protocolType: .openaiCompatible
        ))
        #expect(center.setEnvVar(name: "DESTINATION_KEY", value: "plain", isSecret: false))

        #expect(throws: SettingsDeletionError.operationFailed("供应商名称已存在")) {
            _ = try center.previewProviderRename(from: "SOURCE_PROVIDER", to: "DESTINATION_KEY")
        }
    }

@Test func plainEnvVarsNotTreatedAsProviders() throws {
        let center = try makeCenter()
        #expect(center.setEnvVar(name: "JUST_A_VAR", value: "v", isSecret: false))
        #expect(center.saveProvider(
            name: "REAL_PROVIDER_KEY", apiKey: "sk-real",
            baseURL: "https://r.example.com", modelNames: ["m"],
            protocolType: .openaiCompatible
        ))

        #expect(center.providerRecords.map(\.name) == ["REAL_PROVIDER_KEY"])
        #expect(center.envEntries.count == 2)
    }

    // MARK: AJ-39 旧 key → 模型供应商 转换

    @Test func convertLegacyKeyToProviderPreservesKeyValue() throws {
        let center = try makeCenter()
        // 旧 key：U-5 之前配置，无 baseURL/modelNames → 不识别为供应商。
        #expect(center.setEnvVar(name: "DASHSCOPE_API_KEY", value: "sk-legacy", isSecret: true))
        #expect(center.providerRecords.isEmpty)
        #expect(center.envEntries.count == 1)

        // 自动建议命中 DashScope 配置。
        let suggestion = EnvVarStore.providerSuggestion(for: "DASHSCOPE_API_KEY")
        #expect(suggestion?.providerLabel == "DashScope（阿里云百炼）")

        // 转换：沿用 key 值，补填建议的 Base URL / 模型 / 协议。
        #expect(center.saveProvider(
            name: "DASHSCOPE_API_KEY",
            apiKey: center.envStore.getEnvVar(name: "DASHSCOPE_API_KEY") ?? "",
            baseURL: suggestion?.baseURL,
            modelNames: suggestion?.modelNames ?? [],
            protocolType: suggestion?.protocolType ?? .openaiCompatible
        ))

        // 转换后条目同时是供应商（聊天可用）也是环境变量（shell 可读）。
        let record = try #require(center.providerRecords.first)
        #expect(record.name == "DASHSCOPE_API_KEY")
        #expect(record.isProviderRecord)
        #expect(record.baseURL == "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
        #expect(record.modelNames == ["qwen3.8-max-preview"])
        // key 值保留在 value 字段，既有读取路径不变。
        #expect(center.envStore.getEnvVar(name: "DASHSCOPE_API_KEY") == "sk-legacy")
        #expect(center.envEntries.contains { $0.name == "DASHSCOPE_API_KEY" })
        // count 仍为 1（覆盖更新而非新增）。
        #expect(center.envEntries.count == 1)
    }

    @Test func convertGenericApiKeyWithNoSuggestion() throws {
        let center = try makeCenter()
        #expect(center.setEnvVar(name: "MY_CUSTOM_API_KEY", value: "sk-x", isSecret: true))
        #expect(center.providerRecords.isEmpty)

        // 泛型 *_API_KEY 也有建议（自定义 OpenAI 兼容），但 Base URL / 模型自填。
        #expect(EnvVarStore.providerSuggestion(for: "MY_CUSTOM_API_KEY")?.providerLabel == "自定义 OpenAI 兼容")

        // 用户手动填 Base URL / 模型完成转换。
        #expect(center.saveProvider(
            name: "MY_CUSTOM_API_KEY", apiKey: "sk-x",
            baseURL: "https://custom.example.com/v1", modelNames: ["my-model"],
            protocolType: .openaiCompatible
        ))
        #expect(center.providerRecords.first?.isProviderRecord == true)
        #expect(center.providerRecords.first?.modelNames == ["my-model"])
        #expect(center.envStore.getEnvVar(name: "MY_CUSTOM_API_KEY") == "sk-x")
    }

    @Test func nonApiKeyVarGetsNoSuggestion() throws {
        let center = try makeCenter()
        #expect(center.setEnvVar(name: "DATABASE_URL", value: "postgres://localhost", isSecret: false))
        #expect(EnvVarStore.providerSuggestion(for: "DATABASE_URL") == nil)
        #expect(center.providerRecords.isEmpty)
    }
    }
