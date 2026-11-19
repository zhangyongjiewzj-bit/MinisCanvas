import Foundation
import Testing
@testable import MinisCore

@Suite("首次使用、供应商与模型（第三波 G8）")
struct G8FirstUseTests {

    @Test("OpenAI 兼容 429 + 额度用尽：不重试，文案是余额或额度不足，详情不含响应正文")
    func openAIQuotaIsNotRetryable() {
        let error = LLMError.httpStatus(
            code: 429,
            detail: ProviderHTTPErrorAdapter.quotaDetail(statusCode: 429)
        )
        #expect(ProviderHTTPErrorAdapter.indicatesQuotaExhausted(
            statusCode: 429, body: "{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"secret-text\"}}"))
        #expect(!ProviderHTTPErrorAdapter.indicatesQuotaExhausted(statusCode: 429, body: "rate limit reached"))
        #expect(error.isQuotaExhausted)
        #expect(!error.isRetryable)
        #expect(error.userMessageZH.contains("余额或额度不足"))
        #expect(!error.technicalDetail.contains("secret-text"))
    }

    @Test("Anthropic 400 余额过低显示余额不足而不是参数错误")
    func anthropicCreditBalanceMapsToQuota() {
        let provider = AnthropicProvider(apiKey: "test-key")
        let error = provider.mapHTTPError(
            statusCode: 400,
            body: "{\"error\":{\"message\":\"Your credit balance is too low to access the API\"}}"
        )
        #expect(error.isQuotaExhausted)
        #expect(error.userMessageZH.contains("余额或额度不足"))
        #expect(!error.userMessageZH.contains("参数错误"))
    }

    @Test("401 是授权类失败，402 归为账户侧问题并有提示")
    func authorizationAndPaymentCategories() {
        #expect(LLMError.httpStatus(code: 401, detail: "").isAuthorizationFailure)
        #expect(!LLMError.httpStatus(code: 500, detail: "").isAuthorizationFailure)
        #expect(LLMError.httpStatus(code: 402, detail: "").providerFailureCategory == .permissionDenied)
        let projection = ChatGenerationFailureProjection(error: LLMError.httpStatus(code: 401, detail: ""))
        #expect(projection.actionableRecoveryAction == .reauthenticate)
        #expect(projection.actionableRecoveryAction.title == "检查 API Key")
    }

    @Test("自动回退默认关闭；旧版已存的开启值按新默认迁移为关闭，带标记后用户再开启会保留")
    func fallbackDefaultsOffAndMigrates() throws {
        #expect(AgentSettings().fallbackEnabled == false)
        let legacy = try JSONDecoder().decode(AgentSettings.self, from: Data("{\"fallbackEnabled\":true}".utf8))
        #expect(legacy.fallbackEnabled == false)
        let marked = try JSONDecoder().decode(
            AgentSettings.self,
            from: Data("{\"fallbackEnabled\":true,\"fallbackDefaultOffMigrated\":true}".utf8)
        )
        #expect(marked.fallbackEnabled == true)
        var enabled = AgentSettings()
        enabled.fallbackEnabled = true
        let roundTrip = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(enabled))
        #expect(roundTrip.fallbackEnabled == true)
    }

    @Test("连接检查超时：本机和私网放宽，远端约 30 秒")
    func readinessTimeoutByEndpoint() throws {
        #expect(readinessTimeoutSeconds(for: try #require(URL(string: "http://127.0.0.1:11434"))) == 90)
        #expect(readinessTimeoutSeconds(for: try #require(URL(string: "http://192.168.1.5:8000/v1"))) == 90)
        #expect(readinessTimeoutSeconds(for: try #require(URL(string: "https://api.openai.com/v1"))) == 30)
    }

    @Test("思考档位选项从映射表推导：未声明映射的模型没有可选档位")
    func thinkingOptionsFollowMapping() {
        #expect(ThinkingLevelCatalog.requestableLevels(for: "synthetic-unregistered-model").isEmpty)
        let gpt = ThinkingLevelCatalog.requestableLevels(for: "gpt-5.5")
        #expect(gpt.contains(.off) && gpt.contains(.high))
        #expect(!ThinkingLevelCatalog.requestableLevels(for: "claude-opus-5-5").contains(.off))
    }

    @Test("导入 Key：只取 API Key 和 Base URL，OAuth 令牌不导入，Key 只掩码显示")
    func keyImportIgnoresOAuthTokens() throws {
        let codex = ProviderKeyImport.fromCodexAuth(data: Data(
            "{\"OPENAI_API_KEY\":\"sk-test-1234567890abcd\",\"tokens\":{\"access_token\":\"oauth-secret\"}}".utf8))
        #expect(codex.count == 1)
        #expect(codex[0].apiKey == "sk-test-1234567890abcd")
        #expect(!codex[0].maskedKey.contains("1234567890"))
        let tokenOnly = ProviderKeyImport.fromCodexAuth(data: Data("{\"tokens\":{\"access_token\":\"oauth-secret\"}}".utf8))
        #expect(tokenOnly.isEmpty)

        let claude = ProviderKeyImport.fromClaudeCodeSettings(data: Data(
            "{\"env\":{\"ANTHROPIC_API_KEY\":\"sk-ant-test-abcdefghij\",\"ANTHROPIC_BASE_URL\":\"https://gateway.example/v1\"}}".utf8))
        #expect(claude.first?.baseURL == "https://gateway.example/v1")

        let env = ProviderKeyImport.fromEnvironment(["OPENAI_API_KEY": "sk-env-abcdefghijkl", "HOME": "/Users/x"])
        #expect(env.map(\.credentialName) == ["OPENAI_API_KEY"])
    }

    @Test("导入 Key：登录 shell 快照只取已知变量名并与进程环境合并，同名以登录 shell 为准")
    func keyImportMergesLoginShellSnapshot() {
        let login = ModelShellEnvironment.filteredValues(
            snapshot: ["OPENAI_API_KEY": "sk-login-abcdefghijkl", "DEEPSEEK_API_KEY": "sk-ds-abcdefghijkl",
                       "AWS_SECRET_ACCESS_KEY": "unrelated-secret-value", "PATH": "/usr/bin"],
            names: ProviderKeyImport.environmentVariableNames)
        #expect(Set(login.keys) == ["OPENAI_API_KEY", "DEEPSEEK_API_KEY"])
        #expect(ModelShellEnvironment.filteredValues(snapshot: nil, names: ["OPENAI_API_KEY"]).isEmpty)

        let merged = ProviderKeyImport.mergedEnvironment(
            process: ["OPENAI_API_KEY": "sk-process-abcdefghijkl", "HOME": "/Users/x"], loginShell: login)
        let found = ProviderKeyImport.fromEnvironment(merged)
        #expect(Set(found.map(\.credentialName)) == ["OPENAI_API_KEY", "DEEPSEEK_API_KEY"])
        #expect(found.first { $0.credentialName == "OPENAI_API_KEY" }?.apiKey == "sk-login-abcdefghijkl")
    }

    @Test("Codex config.toml 只读当前 model_provider 的 base_url")
    func codexConfigBaseURL() {
        let toml = """
        model = "gpt-5"
        model_provider = "gw"
        [model_providers.other]
        base_url = "https://other.example/v1"
        [model_providers.gw]
        name = "gateway"
        base_url = "https://gw.example/v1"  # 注释
        """
        #expect(ProviderKeyImport.codexBaseURL(fromConfigTOML: Data(toml.utf8)) == "https://gw.example/v1")
        #expect(ProviderKeyImport.codexBaseURL(fromConfigTOML: Data("model = \"gpt-5\"".utf8)) == nil)
        // 官方 Key 只能绑官方地址；第三方网关用自己的 Key。
        #expect(ProviderKeyImport.codexOpenAIKeyMayBind(toBaseURL: "https://api.openai.com/v1"))
        #expect(!ProviderKeyImport.codexOpenAIKeyMayBind(toBaseURL: "https://gw.example/v1"))
        #expect(!ProviderKeyImport.codexOpenAIKeyMayBind(toBaseURL: "https://api.openai.com.evil.example/v1"))
    }

    @Test("新增预设只补地址，不写死模型名")
    func newPresetsAreAddressOnly() {
        for id in ["gemini", "kimi", "zhipu", "siliconflow"] {
            let preset = ProviderPreset.all.first { $0.id == id }
            #expect(preset != nil)
            #expect(preset?.modelNames.isEmpty == true)
            #expect(preset?.baseURL.hasPrefix("https://") == true)
        }
    }
}
