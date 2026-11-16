import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - L1 边界：renameProvider / applyDefaultProviderModel 边界测试
//
// 本轮补边界（现有 B1L1ProviderFixesTests 10 用例未覆盖）：
// 1. 改名同名不同大小写（Alpha→ALPHA / Alpha→" ALPHA "）：同 canonical 的改名
//    —— 预期旧记录不丢（本次暴露真实 bug：记录被删，见 issues 报告）
// 2. 改名成非法名（空串 / 下划线开头 / 数字开头）：旧记录完整保留（数据完整性断言）
// 3. 撞名守卫大小写变体（Alpha→"beta" 撞已存在 BETA）：双方记录 + 内容均不动
// 4. applyDefaultProviderModel：defaultProviderID 大写变体命中存储小写化记录
// 5. applyDefaultProviderModel：defaultModelID 大小写不匹配 → 回落供应商首模型（记录契约）
// 6. selectedProvider 记录删除后 applyDefault 行为（显式选择残留时不再接管 / 无残留时记录缺失返回 false）
// 7. renameProvider 对不存在的 old 名无操作（不崩溃、不产生记录）
// 8. defaultProviderID 以小写存储时改名不同步（本次暴露真实 bug：默认引用悬挂，见 issues 报告）

@Suite("L1 供应商数据完整性边界")
struct L1BoundaryEdgeTests {

    /// 临时目录 + SettingsCenter（照 B1L1ProviderFixesTests 模式，隔离存储）。
    @MainActor private func makeCenter() throws -> (SettingsCenter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("L1BoundaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        return (center, dir)
    }

    /// 直接构造供应商记录（不落盘，用于 ChatStore 注入）。
    private func record(_ name: String, models: [String] = ["m1"]) -> EnvVarEntry {
        EnvVarEntry(name: name, value: "sk-l1-test", isSecret: true,
                    baseURL: "https://\(name.lowercased()).example/v1",
                    modelNames: models)
    }

    // MARK: 1) 同名不同大小写改名（暴露 bug）

    /// 边界：old == "Alpha" 与 new == "ALPHA" 字符串不同但 canonical 相同。
    /// 预期：改名应是无操作或保留记录（数据不丢）。实际：记录被删除 —— 真实 bug。
    @Test @MainActor func renameCaseOnlyVariantMustNotDeleteRecord() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "Alpha", apiKey: "sk-l1-case", baseURL: "https://a.example/v1",
            modelNames: ["m1"], protocolType: .openaiCompatible
        ))

        center.renameProvider(from: "Alpha", to: "ALPHA")   // 仅大小写不同

        // 预期：记录仍在（改名目标是同一 canonical 记录）
        #expect(center.providerRecords.count == 1,
                "仅大小写不同的改名不得删除记录；实际 records=\\(center.providerRecords.map(\\.name))")
        let kept = try #require(center.providerRecords.first)
        #expect(kept.name == "ALPHA")
        #expect(kept.value == "sk-l1-case", "apiKey 必须保留")
        #expect(kept.modelNames == ["m1"])
    }

    /// 边界变体：new 带首尾空白（canonical 后仍为 ALPHA）。
    @Test @MainActor func renameWhitespaceVariantMustNotDeleteRecord() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "Alpha", apiKey: "sk-l1-ws", baseURL: "https://a.example/v1",
            modelNames: ["m1"], protocolType: .openaiCompatible
        ))

        center.renameProvider(from: "Alpha", to: " ALPHA ")   // canonical 相同

        #expect(center.providerRecords.count == 1,
                "仅空白/大小写差异的改名不得删除记录；实际 records=\\(center.providerRecords.map(\\.name))")
        #expect(center.providerRecords.first?.value == "sk-l1-ws")
    }

    // MARK: 2) 改名成非法名

    /// 边界：new 为空串 / 下划线开头 / 数字开头（canonical 后仍非法）→ 旧记录 + 数据完整保留。
    @Test @MainActor func renameToInvalidNamesKeepsOldRecordIntact() throws {
        let invalidNames = ["", "_x", "1abc", "A B"]
        for newName in invalidNames {
            let (center, _) = try makeCenter()
            #expect(center.saveProvider(
                name: "Alpha", apiKey: "sk-l1-inv", baseURL: "https://a.example/v1",
                modelNames: ["m1", "m2"], protocolType: .openaiCompatible
            ))

            center.renameProvider(from: "Alpha", to: newName)

            let records = center.providerRecords
            #expect(records.count == 1, "改名 \\(newName.debugDescription) 失败后旧记录必须保留；实际 \\(records.map(\\.name))")
            #expect(records.first?.name == "ALPHA")
            #expect(records.first?.value == "sk-l1-inv", "非法改名后 apiKey 不得丢失")
            #expect(records.first?.modelNames == ["m1", "m2"], "非法改名后模型列表不得丢失")
            #expect(records.first?.protocolType == .openaiCompatible)
        }
    }

    // MARK: 3) 撞名守卫大小写变体

    /// 边界：rename Alpha → "beta"（小写）撞已存在 BETA → 双方记录 + 内容均不动。
    @Test @MainActor func renameConflictCaseInsensitivePreservesBothWithData() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "Alpha", apiKey: "sk-l1-a", baseURL: "https://a.example/v1",
            modelNames: ["a1"], protocolType: .openaiCompatible
        ))
        #expect(center.saveProvider(
            name: "Beta", apiKey: "sk-l1-b", baseURL: "https://b.example/v1",
            modelNames: ["b1"], protocolType: .anthropic
        ))

        center.renameProvider(from: "Alpha", to: "beta")   // 大小写变体撞名

        let records = center.providerRecords
        #expect(records.count == 2, "撞名时任何记录都不得被删除；实际 \\(records.map(\\.name))")
        #expect(records.contains { $0.name == "ALPHA" && $0.value == "sk-l1-a" && $0.modelNames == ["a1"] },
                "ALPHA 记录内容必须原样保留")
        #expect(records.contains { $0.name == "BETA" && $0.value == "sk-l1-b" && $0.modelNames == ["b1"] },
                "BETA 记录内容必须原样保留（大小写变体撞名也须命中守卫）")
    }

    /// 边界：old 名不存在 → 无操作、不崩溃、不产生新记录。
    @Test @MainActor func renameProviderNonexistentOldIsNoop() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "Alpha", apiKey: "sk-l1-x", baseURL: "https://a.example/v1",
            modelNames: ["m1"], protocolType: .openaiCompatible
        ))

        center.renameProvider(from: "Ghost", to: "NewName")

        #expect(center.providerRecords.map(\.name) == ["ALPHA"], "不存在的 old 名不得产生任何变化")
    }

    // MARK: 4) applyDefaultProviderModel 大小写变体

    /// 边界：defaultProviderID 大写变体 "custom.MYPROVIDER" 命中存储 "MyProvider"。
    @Test @MainActor func applyDefaultUppercaseCustomIDMatchesStoredRecord() {
        let chat = ChatStore()
        let source = record("MyProvider", models: ["model-x"])
        chat.providerRecordsSource = { [source] }
        let general = GeneralSettings(
            defaultProviderID: "custom.MYPROVIDER",
            defaultModelID: "model-x"
        )
        #expect(chat.applyDefaultProviderModel(general: general) == true,
                "大写 defaultProviderID 应命中存储记录（大小写不敏感匹配）")
        #expect(chat.selectedCustomProvider?.name == "MyProvider")
        #expect(chat.selectedModelID == "model-x")
    }

    /// 边界（记录契约）：defaultModelID 大小写不匹配 → 回落供应商首模型（模型 ID 匹配大小写敏感）。
    @Test @MainActor func applyDefaultModelIDCaseMismatchFallsBackToFirstModel() {
        let chat = ChatStore()
        let source = record("MyProvider", models: ["model-x", "model-y"])
        chat.providerRecordsSource = { [source] }
        let general = GeneralSettings(
            defaultProviderID: "custom.myprovider",
            defaultModelID: "MODEL-X"   // 与存储 "model-x" 仅大小写不同
        )
        #expect(chat.applyDefaultProviderModel(general: general) == true,
                "供应商应被应用（模型 ID 大小写不匹配时回落首模型）")
        #expect(chat.selectedCustomProvider?.name == "MyProvider")
        #expect(chat.selectedModelID == "model-x",
                "记录契约：模型 ID 大小写敏感，MODEL-X 不命中时回落首模型 model-x；见 issues 报告 P3")
    }

    // MARK: 5) selectedProvider 删除后 applyDefault 行为

    /// 边界：选中记录被删除且用户仍保有显式模型选择 → applyDefault 不再接管（guard 生效），
    /// selectedProvider 回落 nil（防幽灵），但 selectedCustomProvider/selectedModelID 残留（记录契约）。
    @Test @MainActor func applyDefaultAfterSelectedRecordDeletedWithExplicitModel() {
        let chat = ChatStore()
        let source = record("Alpha", models: ["m1"])
        chat.providerRecordsSource = { [source] }
        chat.setCustomProvider(source)
        #expect(chat.selectedModelID == "m1")

        // 记录被删除（等价 SettingsCenter.deleteProvider 后）；默认仍指向 custom.alpha
        chat.providerRecordsSource = { [] }
        let general = GeneralSettings(defaultProviderID: "custom.alpha", defaultModelID: "m1")

        #expect(chat.applyDefaultProviderModel(general: general) == false,
                "显式模型选择残留时 applyDefault 不得接管（guard）")
        #expect(chat.selectedProvider == nil, "记录删除后不得出现幽灵供应商")
        #expect(chat.selectedCustomProvider != nil,
                "记录契约：selectedCustomProvider 残留未清理；见 issues 报告 P3")
        #expect(chat.selectedModelID == "m1",
                "记录契约：selectedModelID 残留未清理；见 issues 报告 P3")
    }

    /// 边界：选中记录被删除且无显式模型选择 → applyDefault 因记录缺失返回 false（不崩溃、不选中）。
    @Test @MainActor func applyDefaultAfterSelectedRecordDeletedWithoutExplicitModel() {
        let chat = ChatStore()
        let source = record("Alpha", models: [])
        chat.providerRecordsSource = { [source] }
        chat.setCustomProvider(source)
        #expect(chat.selectedModelID == nil)

        chat.providerRecordsSource = { [] }
        let general = GeneralSettings(defaultProviderID: "custom.alpha")

        #expect(chat.applyDefaultProviderModel(general: general) == false,
                "记录缺失时 applyDefault 返回 false（照常回落默认）")
        #expect(chat.selectedProvider == nil)
    }

    // MARK: 6) defaultProviderID 小写存储时改名同步（暴露 bug）

    /// 边界：defaultProviderID = "custom.alpha"（小写，applyDefault 大小写不敏感匹配可正常生效）。
    /// renameProvider(from: "Alpha", to: "Beta") 后预期 defaultProviderID 同步为 "custom.beta"。
    /// 实际：SettingsCenter 用精确匹配 "custom.ALPHA" 比较 → 小写引用不同步 → 悬挂（真实 bug）。
    @Test @MainActor func renameSyncsDefaultProviderIDStoredLowercase() throws {
        let (center, _) = try makeCenter()
        #expect(center.saveProvider(
            name: "Alpha", apiKey: "sk-l1-d", baseURL: "https://a.example/v1",
            modelNames: ["m1"], protocolType: .openaiCompatible
        ))
        center.defaultProviderID = "custom.alpha"   // 小写存储（applyDefault 可大小写不敏感命中）

        let intent = try center.previewProviderRename(from: "Alpha", to: "Beta")
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try center.renameProvider(from: "Alpha", to: "Beta", intent: intent)

        let actualDefaultID = center.defaultProviderID ?? "nil"
        #expect(center.defaultProviderID == "custom.beta",
                "默认 Provider 引用（小写变体）应随改名同步；实际 \(actualDefaultID)")
    }
}
