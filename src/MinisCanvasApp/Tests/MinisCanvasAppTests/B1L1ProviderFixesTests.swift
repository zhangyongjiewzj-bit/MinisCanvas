import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - L1 修复验证：供应商改名丢数据（P1）+ 撞名覆盖 / 大小写 / 删除残留（P2）

@Suite("L1 供应商数据完整性修复")
struct B1L1ProviderFixesTests {

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
    }

    /// 临时目录 + SettingsCenter（照 AJ28 模式，隔离存储）。
    @MainActor private func makeCenter() throws -> (SettingsCenter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("B1L1Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir, keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        return (center, dir)
    }

    /// 直接构造供应商记录（不落盘，用于 ChatStore 注入）。
    private func record(_ name: String, models: [String] = ["m1"]) -> EnvVarEntry {
        EnvVarEntry(name: name, value: "sk-test", isSecret: true,
                    baseURL: "https://\(name.lowercased()).example/v1",
                    modelNames: models)
    }

    // MARK: - P1 改名丢数据

    /// 改名 = 完整迁移：旧删新建，apiKey/baseURL/modelNames/protocolType 全保留。
    @Test @MainActor func renameProviderMigratesFullRecord() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "Alpha", apiKey: "sk-alpha-123",
            baseURL: "https://alpha.example/v1",
            modelNames: ["alpha-1", "alpha-2"],
            protocolType: .anthropic
        ))
        let deletion = try center.previewProviderRename(from: "Alpha", to: "Beta")
        _ = try center.renameProvider(from: "Alpha", to: "Beta", intent: confirmed(deletion))
        let names = center.providerRecords.map(\.name)
        #expect(names == ["BETA"], "旧记录应删除、新记录 BETA 存在；实际 \(names)")
        let record = try #require(center.providerRecords.first)
        #expect(record.value == "sk-alpha-123", "apiKey 应随改名迁移")
        #expect(record.baseURL == "https://alpha.example/v1")
        #expect(record.modelNames == ["alpha-1", "alpha-2"])
        #expect(record.protocolType == .anthropic)
    }

    /// 改名后默认 Provider 引用同步（custom. 前缀）。
    @Test @MainActor func renameProviderSyncsDefaultProviderID() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "Alpha", apiKey: "sk", baseURL: "https://a.example/v1",
            modelNames: ["m1"], protocolType: .openaiCompatible
        ))
        center.defaultProviderID = "custom.ALPHA"
        let intent = try center.previewProviderRename(from: "Alpha", to: "Beta")
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try center.renameProvider(from: "Alpha", to: "Beta", intent: intent)
        #expect(center.defaultProviderID == "custom.BETA",
                "默认 Provider 引用应随改名同步；实际 \(center.defaultProviderID ?? "nil")")
    }

    /// 新名不合法 → 不删旧记录（saveProvider 失败时保护）。
    @Test @MainActor func renameProviderInvalidNewNameKeepsOld() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "Alpha", apiKey: "sk", baseURL: "https://a.example/v1",
            modelNames: ["m1"], protocolType: .openaiCompatible
        ))
        center.renameProvider(from: "Alpha", to: "bad name!")   // 含非法字符
        #expect(center.providerRecords.map(\.name) == ["ALPHA"],
                "新名不合法时旧记录必须保留")
    }

    /// 改名撞已存在名 → 不动任何记录（不静默覆盖）。
    @Test @MainActor func renameProviderConflictDoesNotTouchExisting() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "Alpha", apiKey: "sk-a", baseURL: "https://a.example/v1",
            modelNames: ["a1"], protocolType: .openaiCompatible
        ))
        #expect(center.saveProvider(
            name: "Beta", apiKey: "sk-b", baseURL: "https://b.example/v1",
            modelNames: ["b1"], protocolType: .openaiCompatible
        ))
        center.renameProvider(from: "Alpha", to: "Beta")
        let names = center.providerRecords.map(\.name).sorted()
        #expect(names == ["ALPHA", "BETA"], "撞名时旧记录不得被覆盖/删除；实际 \(names)")
        #expect(center.providerRecords.first { $0.name == "BETA" }?.value == "sk-b",
                "已存在的 BETA 记录内容不受影响")
    }

    /// 同名改名（old == new）无操作。
    @Test @MainActor func renameProviderSameNameIsNoop() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "Alpha", apiKey: "sk", baseURL: "https://a.example/v1",
            modelNames: ["m1"], protocolType: .openaiCompatible
        ))
        center.renameProvider(from: "Alpha", to: "Alpha")
        #expect(center.providerRecords.map(\.name) == ["ALPHA"])
    }

    // MARK: - P2 撞名防护（providerExists）

    /// 大小写不敏感同名检测；excluding 豁免编辑自身。
    @Test @MainActor func providerExistsIsCaseInsensitiveAndExcludesSelf() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "MyProvider", apiKey: "sk", baseURL: "https://m.example/v1",
            modelNames: ["m1"], protocolType: .openaiCompatible
        ))
        #expect(center.providerExists(named: "myprovider"), "小写查询应命中大写存储")
        #expect(center.providerExists(named: "MYPROVIDER"))
        let record = try #require(center.providerRecords.first)
        #expect(!center.providerExists(named: "MyProvider", excluding: record.id),
                "编辑自身（同 id）不应判为撞名")
        #expect(center.providerExists(named: "MyProvider", excluding: UUID().uuidString),
                "排除他人 id 仍应命中")
        #expect(!center.providerExists(named: "Other"))
    }

    // MARK: - P2 大小写静默失效（ChatStore applyDefaultProviderModel）

    /// defaultProviderID 带 custom. 前缀且大小写与存储不一致 → 仍应生效。
    @Test @MainActor func applyDefaultCustomProviderIsCaseInsensitive() {
        let chat = ChatStore()
        let source = record("MyProvider", models: ["model-x"])
        chat.providerRecordsSource = { [source] }
        let general = GeneralSettings(
            defaultProviderID: "custom.myprovider",
            defaultModelID: "model-x"
        )
        #expect(chat.applyDefaultProviderModel(general: general) == true,
                "小写 defaultProviderID 应匹配大写存储记录")
        #expect(chat.selectedCustomProvider?.name == "MyProvider",
                "selectedCustomProvider 保留注入记录的原名（匹配成功与否看返回值）")
        #expect(chat.selectedModelID == "model-x")
    }

    /// 记录不存在 → 返回 false（保持原行为）。
    @Test @MainActor func applyDefaultCustomProviderMissingRecord() {
        let chat = ChatStore()
        chat.providerRecordsSource = { [] }
        let general = GeneralSettings(defaultProviderID: "custom.ghost")
        #expect(chat.applyDefaultProviderModel(general: general) == false)
    }

    // MARK: - P2 删除残留（selectedProvider 防幽灵）

    /// 选中供应商记录被删除后，selectedProvider 回落 nil（不显示幽灵供应商）。
    @Test @MainActor func selectedProviderClearsWhenRecordDeleted() {
        let chat = ChatStore()
        let source = record("Alpha")
        chat.providerRecordsSource = { [source] }
        chat.setCustomProvider(source)
        #expect(chat.selectedCustomProvider != nil)
        #expect(chat.selectedProvider != nil)

        // 记录从源中消失（等价于 SettingsCenter.deleteProvider 后）
        chat.providerRecordsSource = { [] }
        #expect(chat.selectedProvider == nil, "记录删除后不得残留幽灵供应商")
    }

    /// 记录仍在 → selectedProvider 正常返回。
    @Test @MainActor func selectedProviderSurvivesWhileRecordExists() {
        let chat = ChatStore()
        let source = record("Alpha")
        chat.providerRecordsSource = { [source] }
        chat.setCustomProvider(source)
        #expect(chat.selectedProvider != nil)
    }
}
