import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - F9-ui 模型选择面板：三级状态机（provider → model → tier）+ 每 Provider 记忆
//
// 用户实测反馈重做：SwiftUI Menu 点任一项即选中默认值并关闭 → Popover + 三级状态机。
// ① Provider 点击只更新选中（不关闭）② 模型点击只更新选中（不关闭）
// ③ 速度档位点击 = 最终确认（应用 + 关闭）④ 未确认关闭不生效 ⑤ 每 Provider 记忆预选。

@Suite("模型选择面板三级状态机（F9-ui）")
@MainActor
struct TESTREG613LegacyModelPickerPanelTests {

    @Test("production picker exposes local input before any model readiness exists")
    func localOptionDoesNotRequireBuiltInCatalog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPicker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let chat = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: directory))
        #expect(ProviderType.local.builtInModels.isEmpty)
        #expect(chat.chatProviderOptions.contains(.builtIn(.local)))
        #expect(ModelPickerPanel.readinessFilteredModels(for: .builtIn(.local), chat: chat).isEmpty)
    }

    /// 独立 UserDefaults suite（测试间隔离，跑前清空）
    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("confirmed Mock speed applies with production readiness; preview alone remains inert")
    func confirmedMockSpeedWithReadiness() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Provider02MockTier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = freshDefaults("Provider02MockTier-\(UUID().uuidString)")
        let chat = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: root))
        var observed: [ModelSpeedTier] = []
        chat.onSpeedTierChanged = { observed.append($0) }

        var picker = ModelPickerState(provider: nil, modelID: nil, tier: chat.modelSpeedTier)
        picker.selectProvider(nil)
        #expect(!picker.apply(to: chat, defaults: defaults))
        #expect(chat.modelSpeedTier == .balanced)
        #expect(observed.isEmpty)

        picker.selectTier(.fast)
        #expect(picker.apply(to: chat, defaults: defaults))
        #expect(chat.selectedProviderType == nil)
        #expect(chat.selectedModelID == nil)
        #expect(chat.modelSpeedTier == .fast)
        #expect(ModelSpeedTierPresentation(chat.modelSpeedTier).accessibilityLabel == "快")
        #expect(observed == [.fast])
        #expect(ModelMenuMemory.load(provider: nil, defaults: defaults)?.tier == .fast)
    }

    /// 三级流转：① Provider → ② 模型 → ③ 速度档位；只有 ③ 确认。
    @Test func threeLevelFlowProviderModelTier() {
        var state = ModelPickerState(provider: nil, modelID: nil, tier: nil)

        // ① 点 Provider：只更新选中 + 刷新列表，不确认
        state.selectProvider(.dashScope)
        #expect(state.provider == .dashScope)
        #expect(state.modelID == nil)
        #expect(state.tier == nil)
        #expect(!state.confirmed)
        #expect(state.phase == .pickingModel) // 有模型目录 → 进入 ②

        // ② 点模型即确认，沿用当前档位。
        state.selectModel("qwen-max-latest", fallbackTier: .balanced)
        #expect(state.modelID == "qwen-max-latest")
        #expect(state.tier == .balanced)
        #expect(state.confirmed)
        #expect(state.phase == .confirmed)

        // ③ 仍可单独换档。
        state.selectTier(.quality)
        #expect(state.tier == .quality)
        #expect(state.confirmed)
        #expect(state.phase == .confirmed)
    }

    /// 切换服务商只预选，远程模型点击即确认。
    @Test func providerAndModelClicksNeverConfirm() {
        var state = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        state.selectProvider(.anthropic)
        #expect(!state.confirmed)
        state.selectProvider(.deepSeek)
        #expect(!state.confirmed)
        #expect(state.modelID == nil) // 切 Provider → 旧未确认模型清空
        state.selectModel("deepseek-chat", fallbackTier: .fast)
        #expect(state.tier == .fast)
        #expect(state.confirmed)
    }

    /// ② 选模型优先沿用已预选的服务商档位。
    @Test func selectModelResetsPendingTier() {
        var state = ModelPickerState(provider: .dashScope, modelID: "qwen3.8-max-preview", tier: .balanced)
        state.selectModel("qwen-max-latest", fallbackTier: .fast)
        #expect(state.modelID == "qwen-max-latest")
        #expect(state.tier == .balanced)
        #expect(state.confirmed)
        #expect(state.phase == .confirmed)
    }

    /// Mock / 本地无模型目录 → 跳过 ②，直接 ③ 档位确认。
    @Test func mockAndLocalSkipModelStep() {
        var mock = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        #expect(mock.phase == .pickingTier)
        mock.selectTier(.balanced)
        #expect(mock.confirmed)

        var local = ModelPickerState(provider: .local, modelID: nil, tier: nil)
        #expect(local.phase == .pickingTier)
        local.selectModel("qwen2.5") // 本地自定义模型名
        #expect(local.modelID == "qwen2.5")
        local.selectTier(.balanced)
        #expect(local.confirmed)
    }

    @Test("模型面板不展示 readiness blocked 的内置模型")
    func modelPanelFiltersBlockedBuiltInModels() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ModelPickerReadiness-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderReadinessStore(directory: directory)
        let blockedModel = try #require(ProviderType.openAI.builtInModels.first)
        let fallbackModel = try #require(ProviderType.openAI.builtInModels.dropFirst().first)
        store.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: ProviderType.openAI.rawValue,
                modelID: blockedModel.id,
                status: .unavailable,
                readinessState: .blocked,
                checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
                isApplied: true
            )
        )

        let chat = ChatStore(providerReadinessStore: store)
        let provider = EnvVarEntry(
            name: ProviderType.openAI.rawValue, value: "fixture-key", isSecret: true,
            baseURL: "https://api.openai.com/v1",
            modelNames: [blockedModel.id, fallbackModel.id],
            protocolType: .openaiCompatible
        )
        let credentialRevision = "picker-fixture-revision"
        chat.providerRecordsSource = { [provider] }
        chat.schedulerCredentialVersionSource = { providerID in
            providerID.caseInsensitiveCompare(provider.name) == .orderedSame
                ? credentialRevision : nil
        }
        // A configured catalog alone must not make an unverified model selectable.
        #expect(ModelPickerPanel.readinessFilteredModels(
            for: .builtIn(.openAI), chat: chat
        ).isEmpty)
        store.upsert(ProviderReadinessPersistenceRecord(
            providerID: ProviderType.openAI.rawValue,
            modelID: fallbackModel.id,
            status: .passed,
            readinessState: .mock,
            checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
            evidenceID: "picker-selectable-fixture",
            isApplied: true,
            configurationFingerprint: ChatStore.BuiltinReadinessBinding.fingerprint(
                record: provider, credentialRevision: credentialRevision
            )
        ))
        let models = ModelPickerPanel.readinessFilteredModels(
            for: .builtIn(.openAI),
            chat: chat
        )

        #expect(!models.contains(where: { $0.id == blockedModel.id }))
        #expect(models.contains(where: { $0.id == fallbackModel.id }))
        #expect(models.map(\.id) == [fallbackModel.id])
        chat.schedulerCredentialVersionSource = { _ in "rotated-fixture-revision" }
        #expect(ModelPickerPanel.readinessFilteredModels(
            for: .builtIn(.openAI), chat: chat
        ).isEmpty)
    }

    /// ⑤ 记忆预选：再次打开该 Provider 自动预选上次模型 + 档位（高亮），但预选 ≠ 确认。
    @Test func memoryPreselectsLastUsedModelAndTier() {
        var state = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        let entry = ModelMenuMemory.Entry(modelID: "qwen-plus-latest", tier: .fast)
        state.selectProvider(.dashScope, memory: entry)
        #expect(state.modelID == "qwen-plus-latest")
        #expect(state.tier == .fast)
        #expect(state.modelChosen)
        #expect(state.phase == .pickingTier) // 记忆预选视为已选模型 → 直达 ③
        #expect(!state.confirmed) // 仍需用户点 ③ 档位确认
    }

    /// apply：未确认 → ChatStore 原样（面板外部关闭语义）；确认 → 写 ChatStore + 回调 + 写记忆。
    @Test func applyOnlyWhenConfirmed() {
        let defaults = freshDefaults("F9ApplyTests")
        let chat = ChatStore()

        // 只选服务商时，应用仍为空操作。
        var pending = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        pending.selectProvider(.deepSeek)
        pending.apply(to: chat, defaults: defaults)
        #expect(chat.selectedProviderType == nil)
        #expect(chat.selectedModelID == nil)
        #expect(chat.modelSpeedTier == .balanced)
        #expect(defaults.string(forKey: "modelMenu.lastUsed.deepSeek") == nil)

        // 选模型后，应用沿用当前档位。
        chat.restoreSpeedTier(.fast)
        pending.selectModel("deepseek-chat", fallbackTier: chat.modelSpeedTier)
        var fired: [ModelSpeedTier] = []
        chat.onSpeedTierChanged = { fired.append($0) }
        pending.apply(to: chat, defaults: defaults)
        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedModelID == "deepseek-chat")
        #expect(chat.modelSpeedTier == .fast)
        #expect(fired == [.fast])
        #expect(ModelMenuMemory.load(provider: .deepSeek, defaults: defaults)
            == ModelMenuMemory.Entry(modelID: "deepseek-chat", tier: .fast))
    }

    /// R9：面板确认（apply）路径写会话级记录 = 用户所选模型（非首模型），
    /// 切会话再切回不丢失（修复：apply 曾只把首模型写进会话，用户选择切回后回退）。
    @Test func applyPathPersistsPickedModelAcrossSessionSwitch() {
        let defaults = freshDefaults("R9ApplySessionTests")
        let chat = ChatStore()

        var state = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        state.selectProvider(.deepSeek)
        state.selectModel("deepseek-reasoner") // 非首模型（首模型 deepseek-chat）
        state.selectTier(.quality)
        state.apply(to: chat, defaults: defaults)

        // 生效字段 + 会话记录都 = 用户所选
        #expect(chat.selectedModelID == "deepseek-reasoner")
        #expect(chat.sessions[0].modelID == "deepseek-reasoner")
        #expect(chat.sessions[0].providerTypeRaw == "deepSeek")

        // 切走再切回：保持用户所选（不回退首模型）
        chat.newSession()
        chat.switchSession(id: chat.sessions[0].id)
        #expect(chat.selectedModelID == "deepseek-reasoner")
        #expect(chat.sessions[1].modelID == nil) // 新会话不受污染
    }

    /// 记忆读写：key 格式 + round-trip（含「默认」nil 模型名）+ 缺失/垃圾值返回 nil。
    @Test func memoryRoundTripAndKeyFormat() {
        #expect(ModelMenuMemory.key(for: .dashScope) == "modelMenu.lastUsed.dashScope")
        #expect(ModelMenuMemory.key(for: nil) == "modelMenu.lastUsed.mock")

        let defaults = freshDefaults("F9MemoryTests")
        #expect(ModelMenuMemory.load(provider: .gemini, defaults: defaults) == nil)

        ModelMenuMemory.save(provider: .gemini,
                             entry: .init(modelID: "gemini-2.5-pro", tier: .balanced),
                             defaults: defaults)
        #expect(ModelMenuMemory.load(provider: .gemini, defaults: defaults)
            == ModelMenuMemory.Entry(modelID: "gemini-2.5-pro", tier: .balanced))

        // 「默认」行：modelID = nil 也能 round-trip
        ModelMenuMemory.save(provider: .anthropic,
                             entry: .init(modelID: nil, tier: .quality),
                             defaults: defaults)
        #expect(ModelMenuMemory.load(provider: .anthropic, defaults: defaults)
            == ModelMenuMemory.Entry(modelID: nil, tier: .quality))

        // 垃圾值 → nil（不崩溃）
        defaults.set("{not json", forKey: ModelMenuMemory.key(for: .openAI))
        #expect(ModelMenuMemory.load(provider: .openAI, defaults: defaults) == nil)
    }

    /// 端到端：三级确认 → apply 生效 → 重开同 Provider 从记忆自动预选。
    @Test func endToEndConfirmApplyAndReopenPreselect() {
        let defaults = freshDefaults("F9E2ETests")
        let chat = ChatStore()

        // 第一次打开：① Provider → ② 模型 → ③ 档位确认
        var first = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        first.selectProvider(.deepSeek)
        first.selectModel("deepseek-reasoner")
        first.selectTier(.quality)
        first.apply(to: chat, defaults: defaults)
        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedModelID == "deepseek-reasoner")
        #expect(chat.modelSpeedTier == .quality)

        // 再次打开同一 Provider：记忆自动预选（上次模型 + 档位）
        var second = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        second.selectProvider(.deepSeek, memory: ModelMenuMemory.load(provider: .deepSeek, defaults: defaults))
        #expect(second.modelID == "deepseek-reasoner")
        #expect(second.tier == .quality)
        #expect(!second.confirmed) // 预选高亮 ≠ 确认，仍需 ③ 档位点击
    }
}

// MARK: - AJ-40 模型智能排序（使用频率：常用/最近使用排前面）

@Suite("模型智能排序（AJ-40）")
@MainActor
struct ModelMenuUsageTests {

    /// 独立 UserDefaults suite（测试间隔离，跑前清空）
    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// 排序：按使用频率降序，常用模型排前面；未使用（count=0）保持原目录顺序。
    @Test func sortsByFrequencyMostUsedFirst() {
        let models = [
            LLMModel(id: "a", displayName: "A", provider: "p"),
            LLMModel(id: "b", displayName: "B", provider: "p"),
            LLMModel(id: "c", displayName: "C", provider: "p"),
            LLMModel(id: "d", displayName: "D", provider: "p"),
        ]
        let usage: [String: ModelUsage] = [
            "c": ModelUsage(count: 5, lastUsed: Date(timeIntervalSince1970: 100)),
            "a": ModelUsage(count: 2, lastUsed: Date(timeIntervalSince1970: 100)),
        ]
        // c(5) > a(2) > b/d(0，保持原目录相对顺序)
        let sorted = ModelMenuUsage.sortedModels(models, usage: usage)
        #expect(sorted.map(\.id) == ["c", "a", "b", "d"])
    }

    /// 排序：使用次数相同 → 最近使用优先（recency 填平频率）。
    @Test func sortsByRecencyWhenCountsEqual() {
        let models = [
            LLMModel(id: "a", displayName: "A", provider: "p"),
            LLMModel(id: "b", displayName: "B", provider: "p"),
        ]
        let usage: [String: ModelUsage] = [
            "a": ModelUsage(count: 3, lastUsed: Date(timeIntervalSince1970: 100)),
            "b": ModelUsage(count: 3, lastUsed: Date(timeIntervalSince1970: 200)), // 更新
        ]
        let sorted = ModelMenuUsage.sortedModels(models, usage: usage)
        #expect(sorted.map(\.id) == ["b", "a"])
    }

    /// 排序：无可记录数据（空 usage）→ 保持原目录顺序（稳定，不重排）。
    @Test func sortsStableWhenNoUsage() {
        let models = [
            LLMModel(id: "x", displayName: "X", provider: "p"),
            LLMModel(id: "y", displayName: "Y", provider: "p"),
            LLMModel(id: "z", displayName: "Z", provider: "p"),
        ]
        let sorted = ModelMenuUsage.sortedModels(models, usage: [:])
        #expect(sorted.map(\.id) == ["x", "y", "z"])
    }

    /// 使用频率存储：key 格式 + record 累加 + round-trip 读取。
    @Test func usageKeyFormatAndRecordRoundTrip() {
        #expect(ModelMenuUsage.key(for: .dashScope) == "modelMenu.usage.dashScope")
        #expect(ModelMenuUsage.key(for: nil) == "modelMenu.usage.mock")
        #expect(ModelMenuUsage.key(forCustom: "MyProxy") == "modelMenu.usage.custom.MyProxy")

        let defaults = freshDefaults("AJ40UsageTests")
        #expect(ModelMenuUsage.load(provider: .dashScope, defaults: defaults).isEmpty)

        ModelMenuUsage.record(modelID: "qwen-max", provider: .dashScope, defaults: defaults)
        ModelMenuUsage.record(modelID: "qwen-max", provider: .dashScope, defaults: defaults)
        ModelMenuUsage.record(modelID: "qwen-plus", provider: .dashScope, defaults: defaults)

        let usage = ModelMenuUsage.load(provider: .dashScope, defaults: defaults)
        #expect(usage["qwen-max"]?.count == 2)
        #expect(usage["qwen-plus"]?.count == 1)
        // 归零（未使用）模型不出现
        #expect(usage["qwen-turbo"] == nil)
    }

    /// 自定义供应商使用频率与内置隔离：不同 key，互不串台。
    @Test func usageIsolatedPerCustomProvider() {
        let defaults = freshDefaults("AJ40CustomUsageTests")
        ModelMenuUsage.record(modelID: "m1", custom: "GatewayA", defaults: defaults)
        ModelMenuUsage.record(modelID: "m1", custom: "GatewayB", defaults: defaults)

        #expect(ModelMenuUsage.load(custom: "GatewayA", defaults: defaults)["m1"]?.count == 1)
        #expect(ModelMenuUsage.load(custom: "GatewayB", defaults: defaults)["m1"]?.count == 1)
    }

    /// apply 确认后应写入使用频率（与 ModelMenuMemory 并存，互不破坏）。
    @Test func applyRecordsUsageAlongsideMemory() {
        let defaults = freshDefaults("AJ40ApplyUsageTests")
        let chat = ChatStore()

        var state = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        state.selectProvider(.deepSeek)
        state.selectModel("deepseek-chat")
        state.selectTier(.fast)
        state.apply(to: chat, defaults: defaults)

        // 记忆（上次模型+档位）不破坏
        #expect(ModelMenuMemory.load(provider: .deepSeek, defaults: defaults)
            == ModelMenuMemory.Entry(modelID: "deepseek-chat", tier: .fast))
        // 使用频率已记录
        #expect(ModelMenuUsage.load(provider: .deepSeek, defaults: defaults)["deepseek-chat"]?.count == 1)
    }
}
