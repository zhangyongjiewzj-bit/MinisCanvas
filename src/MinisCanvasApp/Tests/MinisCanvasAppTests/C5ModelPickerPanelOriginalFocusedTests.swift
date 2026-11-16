import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp
@Suite(.serialized)
@MainActor
struct ModelPickerPanelTests {
    @Test
    func confirmedMockSpeedWithReadiness() throws {
        let c5 = try C5OriginalOwnedFixture()
        defer { c5.cleanup() }
        let root = c5.root
            .appendingPathComponent("Provider02MockTier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = c5.freshDefaults("Provider02MockTier-\(UUID().uuidString)")
        let chat = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: root), preferencesDefaults: c5.defaults, logManager: c5.logManager)
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

    @Test
    func threeLevelFlowProviderModelTier() throws {
        let c5 = try C5OriginalOwnedFixture()
        defer { c5.cleanup() }
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

    @Test
    func applyOnlyWhenConfirmed() throws {
        let c5 = try C5OriginalOwnedFixture()
        defer { c5.cleanup() }
        let defaults = c5.freshDefaults("F9ApplyTests")
        let chat = ChatStore(preferencesDefaults: c5.defaults, logManager: c5.logManager)

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

    @Test
    func applyPathPersistsPickedModelAcrossSessionSwitch() throws {
        let c5 = try C5OriginalOwnedFixture()
        defer { c5.cleanup() }
        let defaults = c5.freshDefaults("R9ApplySessionTests")
        let chat = ChatStore(preferencesDefaults: c5.defaults, logManager: c5.logManager)

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

    @Test
    func endToEndConfirmApplyAndReopenPreselect() throws {
        let c5 = try C5OriginalOwnedFixture()
        defer { c5.cleanup() }
        let defaults = c5.freshDefaults("F9E2ETests")
        let chat = ChatStore(preferencesDefaults: c5.defaults, logManager: c5.logManager)

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
