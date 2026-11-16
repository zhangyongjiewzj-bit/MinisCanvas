import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - P0-C1 自定义供应商进入聊天模型菜单
//
// 根因：ChatStore.chatProviderTypes 是硬编码白名单，只含内置 ProviderType，
// 漏 `.deepSeek`，且 U-5 自定义供应商（EnvVarEntry.providerRecords）从不映射成
// ProviderType → 聊天模型菜单 100% 不可见。
// 修复：白名单补 `.deepSeek`；新增 ChatProvider 统一候选（内置 + 自定义），
// 菜单候选 = chatProviderOptions 合并内置聊天类型与用户自定义供应商记录。

@Suite("P0-C1 自定义供应商进入聊天模型菜单")
@MainActor
struct P0C1CustomProviderMenuTests {

    /// 构造一个 U-5 自定义供应商记录（仿设置页 saveProvider 产物）。
    private func makeRecord(
        name: String = "MY_CUSTOM_PROVIDER",
        baseURL: String? = "https://api.example.com/v1",
        models: [String] = ["my-model-1", "my-model-2"]
    ) -> EnvVarEntry {
        EnvVarEntry(
            name: name,
            value: "sk-test-key",
            isSecret: true,
            baseURL: baseURL,
            modelNames: models,
            protocolType: .openaiCompatible
        )
    }

    // MARK: 白名单修复（P0-2）

    @Test func whitelistIncludesDeepSeekAndExcludesImageVideo() {
        let types = ChatStore.chatProviderTypes
        // 修复：DeepSeek 已注册为聊天 Provider，此前漏在白名单 → 现必须在列。
        #expect(types.contains(.deepSeek))
        // 既有聊天 Providers 保持。
        #expect(types.contains(.openAI))
        #expect(types.contains(.anthropic))
        #expect(types.contains(.dashScope))
        #expect(types.contains(.local))
        // 生图/生视频专用不在聊天菜单。
        #expect(!types.contains(.gimage2))
        #expect(!types.contains(.kling))
        #expect(!types.contains(.jimeng))
    }

    // MARK: 候选列表 = 内置 + 自定义（P0-1 核心）

    @Test func chatProviderOptionsMergeBuiltInAndCustom() {
        let custom = makeRecord(name: "MY_CUSTOM_PROVIDER")
        let options = ChatStore.chatProviderOptions(
            builtInTypes: [.openAI, .deepSeek],
            customRecords: [custom]
        )
        // 内置在前。
        #expect(options.count == 3)
        #expect(options[0] == .builtIn(.openAI))
        #expect(options[1] == .builtIn(.deepSeek))
        // 自定义供应商记录在候选列表里。
        #expect(options[2] == .custom(custom))
        #expect(options[2].isCustom)
        #expect(options[2].displayName == "My Custom Provider")
        #expect(options[2].id == "custom.MY_CUSTOM_PROVIDER")
        // 自定义模型目录 = record.modelNames。
        #expect(options[2].modelOptions.map(\.id) == ["my-model-1", "my-model-2"])
    }

    @Test func chatProviderOptionsEmptyCustomKeepsBuiltIn() {
        let options = ChatStore.chatProviderOptions(builtInTypes: [.openAI], customRecords: [])
        #expect(options == [.builtIn(.openAI)])
    }

    // MARK: 实例级候选（经 providerRecordsSource 读取设置中心快照）

    @Test func instanceOptionsReadProviderRecordsSource() {
        let chat = ChatStore()
        let custom = makeRecord(name: "SRC_PROVIDER")
        chat.providerRecordsSource = { [custom] }
        let options = chat.chatProviderOptions
        #expect(options.contains(.custom(custom)))
        #expect(options.contains { $0.id == "custom.SRC_PROVIDER" })
    }

    // MARK: 状态机：选中自定义供应商 → 应用 → ChatStore 状态

    @Test func selectCustomProviderAppliesToChat() {
        let defaults = UserDefaults(suiteName: "P0C1CustomDefaults")!
        defaults.removePersistentDomain(forName: "P0C1CustomDefaults")
        let chat = ChatStore()
        let custom = makeRecord(name: "CUSTOM_A")

        var state = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        state.selectCustomProvider(custom)
        #expect(state.selectedOption == .custom(custom))
        #expect(state.provider == nil)
        #expect(state.modelID == nil)

        state.selectModel("my-model-1")
        state.selectTier(.fast)
        state.apply(to: chat, defaults: defaults)

        #expect(chat.selectedCustomProvider == custom)
        #expect(chat.selectedProviderType == nil) // 内置选择被清除
        #expect(chat.selectedModelID == "my-model-1")
        #expect(chat.modelSpeedTier == .fast)
        #expect(chat.selectedProvider == .custom(custom))
        // 记忆按自定义供应商名隔离。
        #expect(ModelMenuMemory.load(custom: custom.name, defaults: defaults)
            == ModelMenuMemory.Entry(modelID: "my-model-1", tier: .fast))
    }

    @Test func builtInSelectionStillWorksBackwardCompat() {
        let defaults = UserDefaults(suiteName: "P0C1BuiltinDefaults")!
        defaults.removePersistentDomain(forName: "P0C1BuiltinDefaults")
        let chat = ChatStore()

        var state = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        state.selectProvider(.deepSeek)
        state.selectModel("deepseek-chat")
        state.selectTier(.balanced)
        state.apply(to: chat, defaults: defaults)

        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedCustomProvider == nil)
        #expect(chat.selectedModelID == "deepseek-chat")
        #expect(chat.selectedProvider == .builtIn(.deepSeek))
    }

    // MARK: 自定义供应商 → 真实 Provider（activeProvider 建链）

    @Test func activeProviderBuildsCustomProvider() throws {
        let chat = ChatStore()
        let custom = makeRecord(
            name: "CUSTOM_RUNTIME",
            baseURL: "https://api.example.com/v1",
            models: ["my-model-1"]
        )
        chat.setCustomProvider(custom)
        chat.selectedModelID = "my-model-1"
        let provider = try chat.activeProvider()
        #expect(provider.model.id == "my-model-1")
        #expect(provider.model.provider == "CUSTOM_RUNTIME")
    }

    @Test("other protocol never falls back to the OpenAI-compatible provider")
    func otherProtocolFailsClosedBeforeProviderConstruction() {
        let chat = ChatStore()
        let custom = EnvVarEntry(
            name: "OTHER_RUNTIME",
            value: "sk-test-key",
            isSecret: true,
            baseURL: "https://private.example/v1",
            modelNames: ["gpt-5.6-luna"],
            protocolType: .other
        )

        #expect(throws: ChatStoreProviderError.unavailable(
            providerID: "OTHER_RUNTIME",
            protocolType: .other
        )) {
            try chat.makeCustomProvider(
                record: custom,
                modelID: "gpt-5.6-luna"
            )
        }
    }

    /// Hermes/Luna 的历史配置可能写成 `GPT-5.6-luna`，但上游模型 ID 区分
    /// 大小写并只接受 `gpt-5.6-luna`；规范化应发生在发 wire 请求前。
    @Test func canonicalizesKnownLunaModelAlias() throws {
        #expect(ChatStore.canonicalModelID("GPT-5.6-luna") == "gpt-5.6-luna")
        #expect(ChatStore.canonicalModelID("gpt-5.6-luna") == "gpt-5.6-luna")
        #expect(ChatStore.canonicalModelID("deepseek-v4-flash") == "deepseek-v4-flash")

        let chat = ChatStore()
        let custom = makeRecord(
            name: "LUNA",
            baseURL: "https://luna.example.test/v1",
            models: ["GPT-5.6-luna"]
        )
        let provider = try chat.makeCustomProvider(record: custom, modelID: "GPT-5.6-luna")
        #expect(provider.model.id == "gpt-5.6-luna")
    }

    /// Keychain 托管的 EnvVarEntry 在启动快照中 value 为空；自定义 Provider
    /// 必须通过 EnvCredentials 补充源惰性取回真实值，不能发空 Bearer token。
    @Test func resolvesKeychainBackedCustomProviderCredential() {
        let previous = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = previous }
        EnvCredentials.supplementarySource = { name in
            name == "LUNA" ? "sk-luna-from-keychain" : nil
        }
        let custom = EnvVarEntry(
            name: "LUNA",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://luna.example.test/v1",
            modelNames: ["gpt-5.6-luna"]
        )
        #expect(ChatStore.customProviderCredential(record: custom) == "sk-luna-from-keychain")
    }
}
