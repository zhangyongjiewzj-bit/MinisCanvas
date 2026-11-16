import Testing
import Foundation
@testable import MinisCore

// MARK: - DeepSeek 独立 Provider（E12）

@Suite("DeepSeekProvider", .serialized)
struct DeepSeekProviderTests {

    // MARK: 端点 / 模型目录

    @Test func defaultEndpointIsDeepSeekOfficial() {
        #expect(DeepSeekProvider.defaultBaseURL == DeepSeekProviderContract.baseURL)
    }

    @Test func modelCatalogHasDeepSeekModels() {
        let ids = LLMModel.allDeepSeek.map(\.id)
        #expect(ids.contains("deepseek-chat"))
        #expect(ids.contains("deepseek-reasoner"))
        #expect(LLMModel.allDeepSeek.allSatisfy { $0.provider == "DeepSeek" })
        #expect(LLMModel.allModels.contains(.deepSeekChat))
        #expect(LLMModel.allModels.contains(.deepSeekReasoner))
        // 全局模型目录必须包含新模型
        #expect(LLMModel.allModels.map(\.id).contains("deepseek-chat"))
    }

    @Test func reasonerModelDeclaresReasoning() {
        #expect(LLMModel.deepSeekReasoner.supportsReasoning == true)
        #expect(LLMModel.deepSeekReasoner.interleavedReasoningField == "reasoning_content")
        #expect(LLMModel.deepSeekChat.supportsReasoning != true)
    }

    @Test func builtInModelsForDeepSeekType() {
        #expect(ProviderType.deepSeek.builtInModels == LLMModel.allDeepSeek)
        #expect(!ProviderType.deepSeek.builtInModels.isEmpty)
    }

    // MARK: API key 解析链

    @Test func injectedKeyWins() {
        #expect(DeepSeekProvider.resolveAPIKey(injected: "sk-injected") == "sk-injected")
        // 注入空白 → 回退环境变量
        #expect(DeepSeekProvider.resolveAPIKey(injected: "   ") != "   ")
    }

    @Test func envChainHERMESThenDEEPSEEK() {
        let oldH = getenv("HERMES_CUSTOM_DEEPSEEK_API_KEY").map { String(cString: $0) }
        let oldD = getenv("DEEPSEEK_API_KEY").map { String(cString: $0) }
        defer {
            restore("HERMES_CUSTOM_DEEPSEEK_API_KEY", oldH)
            restore("DEEPSEEK_API_KEY", oldD)
        }
        setenv("HERMES_CUSTOM_DEEPSEEK_API_KEY", "sk-hermes-custom", 1)
        setenv("DEEPSEEK_API_KEY", "sk-plain", 1)
        // HERMES_CUSTOM 优先
        #expect(DeepSeekProvider.resolveAPIKey(injected: nil) == "sk-hermes-custom")
        // 移除 HERMES_CUSTOM → 回退 DEEPSEEK_API_KEY
        unsetenv("HERMES_CUSTOM_DEEPSEEK_API_KEY")
        #expect(DeepSeekProvider.resolveAPIKey(injected: nil) == "sk-plain")
        // 全无 → nil
        unsetenv("DEEPSEEK_API_KEY")
        #expect(DeepSeekProvider.resolveAPIKey(injected: nil) == nil)
    }

    @Test func providerResolvesKeyFromEnv() {
        let oldH = getenv("HERMES_CUSTOM_DEEPSEEK_API_KEY").map { String(cString: $0) }
        defer { restore("HERMES_CUSTOM_DEEPSEEK_API_KEY", oldH) }
        setenv("HERMES_CUSTOM_DEEPSEEK_API_KEY", "sk-from-env", 1)
        let provider = DeepSeekProvider()
        #expect(provider.resolvedAPIKey == "sk-from-env")
    }

    private func restore(_ name: String, _ value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }

    // MARK: 注册 / 工厂

    @Test func factoryRegistersDeepSeek() {
        #expect(ProviderFactory.shared.hasBuilder(for: .deepSeek))
        #expect(ProviderFactory.shared.registeredTypes.contains(.deepSeek))
    }

    @Test func makeProviderReturnsDeepSeekProvider() throws {
        let config = ProviderConfig(
            label: "deepseek-test",
            providerType: .deepSeek,
            isEnabled: true,
            apiKey: "sk-test-injected"
        )
        let provider = try ProviderFactory.shared.makeProvider(for: config)
        #expect(provider is DeepSeekProvider)
        let deepSeek = try #require(provider as? DeepSeekProvider)
        #expect(deepSeek.name == "DeepSeek")
        #expect(deepSeek.resolvedAPIKey == "sk-test-injected")
        // 默认模型 deepseek-v4-flash
        #expect(deepSeek.model.id == DeepSeekProviderContract.preferredModelID)
    }

    @Test func makeProviderWithoutCredentialsThrows() {
        let config = ProviderConfig(
            label: "deepseek-no-key",
            providerType: .deepSeek,
            isEnabled: true,
            apiKeyEnvVar: "NO_SUCH_ENV_VAR_FOR_TEST",
            apiKey: nil
        )
        #expect(throws: ProviderFactory.FactoryError.self) {
            _ = try ProviderFactory.shared.makeProvider(for: config)
        }
    }

    // MARK: providerID ↔ ProviderType 映射

    @Test func providerIDMapDeepSeek() {
        #expect(ProviderIDMap.providerType(fromID: "deepseek") == .deepSeek)
        #expect(ProviderIDMap.providerID(from: .deepSeek) == "deepseek")
        #expect(ProviderIDMap.providerType(fromID: ProviderIDMap.providerID(from: .deepSeek) ?? "") == .deepSeek)
    }

    // MARK: 百炼模型目录完整性（E12 回归确认）

    @Test func dashScopeCatalogIntact() {
        let ids = LLMModel.allDashScope.map(\.id)
        #expect(ids.contains("qwen3.8-max-preview"))
        #expect(ids.contains("qwen3.7-max"))
        #expect(ids.contains("qwen3.7-plus"))
        #expect(ids.contains("qwen-max-latest"))
        #expect(ids.contains("qwen-plus-latest"))
        #expect(ids.contains("qwen-turbo-latest"))
        #expect(ids.contains("qwen3-vl-plus"))
    }
}
