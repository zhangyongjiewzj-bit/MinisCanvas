import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - E24 对话条模型按钮（ModelMenuButton 标签 / 档位 / 模型 / 与侧栏状态一致）

@Suite("对话条模型按钮（E24）")
@MainActor
struct ModelMenuButtonTests {

    @Test func projectSessionUsesCurrentDisplayNameWithoutChangingProviderIdentity() {
        let chat = ChatStore()
        chat.newSession(projectID: "display-name-project", projectName: "显示名项目")
        let record = EnvVarEntry(name: "FIXTURE_PROVIDER_API_KEY", value: "", displayName: "我的 模型服务",
            isSecret: true, valueInKeychain: true, modelNames: ["qwen-plus-latest"])
        var records = [record]
        chat.providerRecordsSource = { records }
        chat.selectedCustomProvider = record
        chat.selectedModelID = "qwen-plus-latest"
        #expect(chat.providerLabel == "我的 模型服务 · qwen-plus")
        #expect(ChatStore.chatProviderOptions(customRecords: records).last?.displayName == "我的 模型服务")
        records[0].displayName = "新 中文名称"
        #expect(chat.providerLabel == "新 中文名称 · qwen-plus")
        #expect(chat.selectedCustomProvider?.id == record.id)
        #expect(chat.selectedCustomProvider?.name == "FIXTURE_PROVIDER_API_KEY")
        #expect(chat.sessions.first { $0.id == chat.activeSessionID }?.projectID == "display-name-project")
    }

    @Test("readiness 过滤为空时选择器阶段允许直接确认档位")
    func readinessFilteredEmptyCatalogUsesTierPhase() {
        #expect(
            ModelPickerState.phase(
                hasCatalog: false,
                modelChosen: false,
                confirmed: false
            ) == .pickingTier
        )
    }

    /// 对话条按钮显示当前模型短名（档位图标由按钮单独渲染，这里验证文案部分）。
    @Test func composerLabelShowsCurrentModel() {
        // 未选模型（Mock 演示）
        #expect(ModelMenuButton.composerLabel(modelID: nil, providerType: nil, tier: .balanced) == "演示模式")
        // 已选模型 → 模型短名
        #expect(ModelMenuButton.composerLabel(modelID: "qwen3.8-max-preview", providerType: .dashScope, tier: .balanced) == "qwen3.8")
        #expect(ModelMenuButton.composerLabel(modelID: "deepseek-chat", providerType: .deepSeek, tier: .fast) == "deepseek-chat")
        #expect(ModelMenuButton.composerLabel(modelID: "deepseek-reasoner", providerType: .deepSeek, tier: .quality) == "deepseek-reasoner")
        // 有 Provider 但无模型 → 档位名
        #expect(ModelMenuButton.composerLabel(modelID: nil, providerType: .local, tier: .ultraFast) == "极快")
    }

    /// 模型短名去掉常见速度后缀（胶囊更紧凑）。
    @Test func modelShortNameStripsSuffixes() {
        #expect(ModelMenuButton.modelShortName("qwen3.8-max-preview") == "qwen3.8")
        #expect(ModelMenuButton.modelShortName("gemini-2.5-flash-lite") == "gemini-2.5-flash")
        #expect(ModelMenuButton.modelShortName("qwen-plus-latest") == "qwen-plus")
        #expect(ModelMenuButton.modelShortName("codex-mini-latest") == "codex-mini")
        #expect(ModelMenuButton.modelShortName("deepseek-chat") == "deepseek-chat")
    }

    /// 档位切换（按钮动作 = chat.setSpeedTier）→ 模型 + 档位图标 + 按钮文案同步更新。
    @Test func speedTierSwitchUpdatesButtonLabel() {
        let chat = ChatStore()
        #expect(chat.modelSpeedTier == .balanced) // 默认均衡 ⚖️
        #expect(chat.modelSpeedTier.icon == "⚖️")

        chat.setSpeedTier(.quality)
        #expect(chat.modelSpeedTier == .quality)
        #expect(chat.modelSpeedTier.icon == "💎")
        #expect(chat.selectedModelID == "deepseek-reasoner")
        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "deepseek-reasoner")

        chat.setSpeedTier(.ultraFast)
        #expect(chat.modelSpeedTier.icon == "⚡")
        #expect(chat.selectedModelID == "deepseek-chat")
        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "deepseek-chat")
    }

    /// 模型选择（按钮动作 = chat.selectModel）→ 档位自动匹配 + 按钮文案更新。
    @Test func modelSelectionUpdatesButtonLabel() {
        let chat = ChatStore()
        chat.selectModel(.qwen38MaxPreview)
        #expect(chat.modelSpeedTier == .balanced)
        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "qwen3.8")

        chat.selectModel(.deepSeekChat)
        #expect(chat.modelSpeedTier == .fast)
        #expect(chat.modelSpeedTier.icon == "🚀")
        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "deepseek-chat")
    }

    /// 侧栏（ChatModelMenu）与对话条（ModelMenuButton）共用同一 ChatStore：
    /// 切换档位/模型后，两处标签从同一状态派生，保持一致。
    @Test func sidebarAndComposerShareSameStoreState() {
        let chat = ChatStore()
        // 先选档位建立模型（ChatStore 初始为 Mock，无模型）
        chat.setSpeedTier(.balanced)
        #expect(ChatModelMenu.menuLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "均衡 · qwen3.8-max-preview")
        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "qwen3.8")

        // 对话条侧切档位 → 侧栏标签同步变化（同一 store）
        chat.setSpeedTier(.quality)
        #expect(ChatModelMenu.menuLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "质量 · deepseek-reasoner")
        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "deepseek-reasoner")

        // 侧栏侧选模型 → 对话条同步（同一 store）
        chat.selectModel(.qwenTurboLatest)
        #expect(ChatModelMenu.menuLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "极快 · qwen-turbo-latest")
        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "qwen-turbo")
        #expect(chat.modelSpeedTier.icon == "⚡")
    }

    // MARK: - AJ-55 伴随栏模型选择
    //
    // 画布/文档伴随栏（CompanionChatView）composer 复用同款 ModelMenuButton（与主聊天 GlobalComposerView 一致）。
    // 两者共用同一 ChatStore，因此伴随栏的模型按钮文案与主聊天/侧栏从同一状态派生，天然保持一致。

    /// 伴随栏同款按钮：模型选择后，伴随栏按钮文案与主聊天一致（复用同一 store + 同一 ModelMenuButton）。
    @Test func companionComposerSharesMainComposerState() {
        let chat = ChatStore()
        // 初始（Mock，无模型）→ 伴随栏按钮显示 "Mock"
        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "演示模式")

        // 选模型 → 伴随栏按钮文案与主聊天按钮一致（同一派生函数）
        chat.selectModel(.deepSeekReasoner)
        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "deepseek-reasoner")

        // 切档位 → 伴随栏按钮文案同步（同一 store）
        chat.setSpeedTier(.ultraFast)
        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID, providerType: chat.selectedProviderType, tier: chat.modelSpeedTier
        ) == "deepseek-chat")
        #expect(chat.modelSpeedTier.icon == "⚡")
    }

    // MARK: - G10 P2-1 Mock 模式明示

    /// 未选任何 Provider → isMockMode = true（UI 常驻「Mock 演示」橙色徽标）。
    @Test func mockModeWhenNoProviderSelected() {
        let chat = ChatStore()
        #expect(chat.isMockMode)
        #expect(chat.providerLabel == "演示模式")
    }

    /// 选择内置 Provider 后 → isMockMode = false，徽标消失（真实模型名）。
    @Test func notMockModeAfterSelectingProvider() {
        let chat = ChatStore()
        chat.selectModel(.deepSeekReasoner)
        #expect(!chat.isMockMode)
        #expect(chat.providerLabel.contains("deepseek-reasoner"))
    }
}
