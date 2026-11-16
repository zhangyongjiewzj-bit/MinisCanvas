import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - E19 模型速度档位选择（ChatStore 接线）

@Suite("模型速度档位选择（E19）")
@MainActor
struct ModelSpeedTierSelectionTests {

    /// 选档位 → 自动切换 Provider + 该档默认模型。
    @Test func setSpeedTierSelectsDefaultModel() {
        let chat = ChatStore()
        #expect(chat.modelSpeedTier == .balanced) // 默认均衡

        chat.setSpeedTier(.quality)
        #expect(chat.modelSpeedTier == .quality)
        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedModelID == "deepseek-reasoner")

        chat.setSpeedTier(.fast)
        #expect(chat.modelSpeedTier == .fast)
        #expect(chat.selectedProviderType == .dashScope)
        #expect(chat.selectedModelID == "qwen-turbo-latest")

        chat.setSpeedTier(.ultraFast)
        #expect(chat.selectedModelID == "deepseek-chat")
        #expect(chat.selectedProviderType == .deepSeek)

        chat.setSpeedTier(.balanced)
        #expect(chat.selectedModelID == "qwen3.8-max-preview")
        #expect(chat.selectedProviderType == .dashScope)
    }

    /// 选具体模型 → 档位自动匹配（跨 Provider 生效）。
    @Test func selectModelAutoMatchesTier() {
        let chat = ChatStore()
        chat.selectModel(.deepSeekChat)
        #expect(chat.modelSpeedTier == .fast)
        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedModelID == "deepseek-chat")

        chat.selectModel(.qwen38MaxPreview)
        #expect(chat.modelSpeedTier == .balanced)
        #expect(chat.selectedProviderType == .dashScope)
        #expect(chat.selectedModelID == "qwen3.8-max-preview")

        chat.selectModel(.qwenTurboLatest)
        #expect(chat.modelSpeedTier == .ultraFast)

        chat.selectModel(.deepSeekReasoner)
        #expect(chat.modelSpeedTier == .quality)
    }

    /// 手动切 Provider → 首个内置模型，档位随模型自动匹配。
    @Test func setProviderAutoMatchesTierToFirstModel() {
        let chat = ChatStore()
        chat.setProvider(.dashScope) // 第一个内置模型 qwen3.8-max-preview
        #expect(chat.selectedModelID == "qwen3.8-max-preview")
        #expect(chat.modelSpeedTier == .balanced)

        chat.setProvider(.deepSeek) // 第一个内置模型 deepseek-chat
        #expect(chat.selectedModelID == "deepseek-chat")
        #expect(chat.modelSpeedTier == .fast)

        chat.setProvider(nil) // Mock：无模型 → 档位保持
        #expect(chat.selectedProviderType == nil)
        #expect(chat.selectedModelID == nil)
    }

    /// 启动恢复：仅当未显式选择 Provider/模型时才应用档位默认模型。
    @Test func restoreSpeedTierAppliesOnlyWhenNothingSelected() {
        let chat = ChatStore()
        chat.restoreSpeedTier(.quality)
        #expect(chat.modelSpeedTier == .quality)
        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedModelID == "deepseek-reasoner")

        // 已显式选择 → 恢复不覆盖模型
        let chat2 = ChatStore()
        chat2.setProvider(.anthropic)
        chat2.restoreSpeedTier(.quality)
        #expect(chat2.selectedProviderType == .anthropic)
        #expect(chat2.selectedModelID == "claude-fable-5")
    }

    /// 档位变更回调（持久化钩子）触发顺序正确。
    @Test func speedTierChangeCallbackFires() {
        let chat = ChatStore()
        var captured: [ModelSpeedTier] = []
        chat.onSpeedTierChanged = { captured.append($0) }
        chat.setSpeedTier(.quality)
        chat.selectModel(.qwen38MaxPreview)
        #expect(captured == [.quality, .balanced])
    }

    /// activeProvider 携带档位默认模型（真实 provider 装配路径）。
    @Test func activeProviderCarriesTierDefaultModel() throws {
        let chat = ChatStore()
        chat.setSpeedTier(.fast)
        let provider = try chat.activeProvider()
        #expect(provider.model.id == "qwen-turbo-latest")
    }
}
