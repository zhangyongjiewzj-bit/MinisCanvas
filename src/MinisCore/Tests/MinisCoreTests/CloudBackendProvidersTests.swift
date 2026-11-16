import Foundation
import Testing
@testable import MinisCore

// 本文件自带的离线 mock URLProtocol（M2k）：
// 独立命名、独立静态状态，避免与 CloudVideoKlingTests 的 KlingMockURLProtocol /
// CloudVideoJimengTests 的 JimengMockURLProtocol 在并行执行时互相覆盖。

final class CloudBackendMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CloudBackendMockURLProtocol.receivedRequests.append(request)
        guard let handler = CloudBackendMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestHandler = nil
        receivedRequests = []
    }

    static func jsonResponse(_ json: [String: Any], status: Int = 200) -> (Int, Data, [String: String]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return (status, data, ["Content-Type": "application/json"])
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudBackendMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// Cloud backend (M2b) provider tests — 纯离线验证为主；
// 唯一 live 测试 testDashScopeLiveChat 仅在百炼 API key 存在时执行
//（无 key 自动 skip），保证 swift test 在无网/无 key 环境也能通过。
//
// 注意：本套件含 setenv/unsetenv 的环境变量测试，必须串行执行
//（@Suite(.serialized)），否则并发测试会读到被污染的 env。

@Suite(.serialized)
struct CloudBackendProvidersTests {

    /// 恢复某个环境变量到测试前的原值（nil → 删除该变量）。
    private func restoreEnv(_ name: String, original: String?) {
        if let original {
            setenv(name, original, 1)
        } else {
            unsetenv(name)
        }
    }

    // MARK: - LLMModel.allDashScope

    @Test func allDashScopeModelsRegistered() {
        let models = LLMModel.allDashScope
        #expect(!models.isEmpty)
        #expect(models.contains(where: { $0.id == "qwen3.8-max-preview" }))
        #expect(models.contains(where: { $0.id == "qwen3.7-max" }))
        #expect(models.contains(where: { $0.id == "qwen3.7-plus" }))
        #expect(models.allSatisfy { $0.provider == "DashScope" })
        // ProviderType 与 allModels 均已收录。
        #expect(ProviderType.dashScope.builtInModels.map(\.id).sorted() == models.map(\.id).sorted())
        for m in models {
            #expect(LLMModel.allModels.contains(m))
        }
    }

    // MARK: - ProviderType

    @Test func cloudProviderTypeDecoding() {
        #expect(ProviderType.decoded("dashScope") == .dashScope)
        #expect(ProviderType.decoded("gimage2") == .gimage2)
        #expect(ProviderType.decoded("kling") == .kling)
        #expect(ProviderType.decoded("jimeng") == .jimeng)
        #expect(ProviderType.decoded("no-such-provider") == .unsupported)
        #expect(!ProviderType.dashScope.displayName.isEmpty)
        #expect(!ProviderType.kling.displayName.isEmpty)
        #expect(!ProviderType.jimeng.displayName.isEmpty)
        #expect(ProviderType.kling.builtInModels.isEmpty)
        #expect(ProviderType.jimeng.builtInModels.isEmpty)
    }

    // MARK: - ProviderFactory 注册

    @Test func factoryRegistersCloudTypes() {
        let factory = ProviderFactory()
        let types = Set(factory.registeredTypes)
        #expect(types.contains(.dashScope))
        #expect(types.contains(.gimage2))
        #expect(types.contains(.kling))
        #expect(types.contains(.jimeng))
    }

    @Test func factoryMakesDashScopeProvider() throws {
        let factory = ProviderFactory()
        let config = ProviderConfig(label: "百炼", providerType: .dashScope, apiKey: "test-key")
        let provider = try factory.makeProvider(for: config)
        #expect(provider is DashScopeProvider)
        #expect(provider.name == "DashScope")
        #expect(provider.model.id == "qwen3.8-max-preview")
        let ds = provider as! DashScopeProvider
        #expect(ds.resolvedAPIKey == "test-key")
    }

    @Test func factoryMakesMediaProviders() throws {
        let factory = ProviderFactory()
        let g = try factory.makeProvider(for: ProviderConfig(label: "Gimage2", providerType: .gimage2, apiKey: "k1"))
        #expect(g is Gimage2Provider)
        #expect((g as! Gimage2Provider).resolvedAPIKey == "k1")

        let k = try factory.makeProvider(for: ProviderConfig(label: "可灵", providerType: .kling, apiKey: "k2"))
        #expect(k is KlingProvider)
        #expect((k as! KlingProvider).resolvedAPIKey == "k2")

        let j = try factory.makeProvider(for: ProviderConfig(label: "即梦", providerType: .jimeng, apiKey: "k3"))
        #expect(j is JimengProvider)
        #expect((j as! JimengProvider).resolvedAPIKey == "k3")
    }

    // MARK: - API key 解析链

    @Test func dashScopeKeyResolutionChain() {
        let origB = EnvCredentials.value(for: "BAILIAN_TOKEN_PLAN_API_KEY")
        let origQ = EnvCredentials.value(for: "HERMES_CUSTOM_QWEN38_API_KEY")
        let origImg = EnvCredentials.value(for: "HERMES_CUSTOM_IMAGE2_API_KEY")
        let origImg2 = EnvCredentials.value(for: "IMAGE2_API_KEY")
        let origImg3 = EnvCredentials.value(for: "GIMAGE2_API_KEY")
        setenv("BAILIAN_TOKEN_PLAN_API_KEY", "bailian-key", 1)
        setenv("HERMES_CUSTOM_QWEN38_API_KEY", "qwen38-key", 1)
        unsetenv("HERMES_CUSTOM_IMAGE2_API_KEY")
        unsetenv("IMAGE2_API_KEY")
        unsetenv("GIMAGE2_API_KEY")
        defer {
            restoreEnv("BAILIAN_TOKEN_PLAN_API_KEY", original: origB)
            restoreEnv("HERMES_CUSTOM_QWEN38_API_KEY", original: origQ)
            restoreEnv("HERMES_CUSTOM_IMAGE2_API_KEY", original: origImg)
            restoreEnv("IMAGE2_API_KEY", original: origImg2)
            restoreEnv("GIMAGE2_API_KEY", original: origImg3)
        }
        // 无注入 → 按序取第一个存在的环境变量。
        #expect(DashScopeProvider.resolveAPIKey(injected: nil) == "qwen38-key")
        // 注入值优先。
        #expect(DashScopeProvider.resolveAPIKey(injected: "injected") == "injected")
        // 注入为空串 → 回落环境变量。
        #expect(DashScopeProvider.resolveAPIKey(injected: "  ") == "qwen38-key")
        // 环境变量未设置 → nil。
        let g = Gimage2Provider(apiKey: nil)
        #expect(Gimage2Provider.resolveAPIKey(injected: nil) == nil)
        #expect(g.isConfigured == false)
    }

    @Test func gimage2KeyResolution() {
        let origImg = EnvCredentials.value(for: "HERMES_CUSTOM_IMAGE2_API_KEY")
        setenv("HERMES_CUSTOM_IMAGE2_API_KEY", "img-key", 1)
        defer { restoreEnv("HERMES_CUSTOM_IMAGE2_API_KEY", original: origImg) }
        let provider = Gimage2Provider()
        #expect(provider.isConfigured == true)
        #expect(provider.resolvedAPIKey == "img-key")
        #expect(provider.modelID == "gpt-image-2-official")
    }

    // MARK: - Gimage2 请求体 / 响应解析

    @Test func gimage2RequestBodyShape() {
        let body = Gimage2Provider.buildRequestBody(model: "gpt-image-2-official", prompt: "一只猫", n: 2, size: "1024x1024")
        #expect(body["model"] as? String == "gpt-image-2-official")
        #expect(body["prompt"] as? String == "一只猫")
        #expect(body["n"] as? Int == 2)
        #expect(body["size"] as? String == "1024x1024")
        #expect(body["response_format"] as? String == "b64_json")
        let noSize = Gimage2Provider.buildRequestBody(model: "m", prompt: "p", n: 0, size: nil)
        #expect(noSize["n"] as? Int == 1)
        #expect(noSize["size"] == nil)
    }

    @Test func gimage2ParseResponse() throws {
        let json: [String: Any] = [
            "created": 1,
            "data": [
                ["b64_json": "AAAA"],
                ["url": "https://example.com/img.png", "revised_prompt": "better"],
            ],
        ]
        let result = try Gimage2Provider.parseImageResponse(providerID: "gimage2", model: "gpt-image-2-official", json: json)
        #expect(result.images.count == 2)
        #expect(result.images[0].base64Data == "AAAA")
        #expect(result.images[1].url == "https://example.com/img.png")
        #expect(result.revisedPrompt == "better")
    }

    @Test func gimage2ParseEmptyDataThrows() {
        #expect(throws: CloudBackendError.self) {
            try Gimage2Provider.parseImageResponse(providerID: "gimage2", model: "m", json: ["data": []])
        }
    }

    // MARK: - Kling / Jimeng 离线错误路径（M2k：不再用假 key 打真实 endpoint）
    //
    // 原 klingJimengSkeletonThrowsNotImplemented 在骨架期（M2g）验证"未实现即抛错"；
    // M2h/M2i 后 Kling/Jimeng 已真实接入，改用 mock session 验证，全程不联网：
    //   - Kling：假 key + mock 401 → submitVideo 抛 CloudBackendError
    //   - Jimeng：无 AK/SK → pollVideo 在发请求前抛 missingAPIKey

    @Test func klingSubmitVideoFakeKeyThrowsOffline() async {
        defer { CloudBackendMockURLProtocol.reset() }
        CloudBackendMockURLProtocol.requestHandler = { _ in
            CloudBackendMockURLProtocol.jsonResponse(
                ["code": 40100, "message": "无效的 API Key"],
                status: 401
            )
        }
        let kling = KlingProvider(apiKey: "fake-key", session: CloudBackendMockURLProtocol.makeSession())
        #expect(kling.isConfigured == true)
        await #expect(throws: CloudBackendError.self) {
            _ = try await kling.submitVideo(CloudVideoRequest(prompt: "test"))
        }
        // 请求确实发出，但被 mock URLProtocol 拦截，未触碰真实网络。
        #expect(CloudBackendMockURLProtocol.receivedRequests.count == 1)
    }

    @Test func jimengPollVideoWithoutCredentialsThrowsOffline() async {
        // 清空 AK/SK 环境变量，避免测试机残留凭证导致真发请求。
        for name in JimengProvider.accessKeyEnvVars + JimengProvider.secretKeyEnvVars {
            unsetenv(name)
        }
        let jimeng = JimengProvider(apiKey: "fake-key")
        #expect(jimeng.isConfigured == true) // 注入 apiKey → 旧语义下视为已配置
        await #expect(throws: CloudBackendError.self) {
            _ = try await jimeng.pollVideo(taskID: "t")
        }
    }

    @Test func mediaProviderLLMStubThrows() async {
        let g = Gimage2Provider(apiKey: "k")
        let msg = [LLMMessage(role: .user, content: "hi")]
        await #expect(throws: CloudBackendError.self) {
            _ = try await g.sendMessage(messages: msg, systemPrompt: nil, maxTokens: 100, temperature: nil)
        }
        await #expect(throws: CloudBackendError.self) {
            _ = try await g.streamMessage(messages: msg, systemPrompt: nil, maxTokens: 100, temperature: nil)
        }
    }

    @Test func notImplementedErrorDescription() {
        let err = CloudBackendError.notImplemented(providerID: "kling", detail: "TODO")
        #expect(err.errorDescription?.contains("尚未接入真实 API") == true)
        #expect(err.errorDescription?.contains("kling") == false)
        #expect(err.errorDescription?.contains("TODO") == false)
        #expect(err == .notImplemented(providerID: "kling", detail: "TODO"))
    }

    // MARK: - Live（仅在有百炼 key 时执行）
    //
    // 实测：HERMES_CUSTOM_QWEN38_API_KEY 对 qwen3.8-max-preview 可用；
    // BAILIAN_TOKEN_PLAN_API_KEY 对该模型返回 403 Unpurchased（需开通），
    // 因此优先注入前者，其次回退 BAILIAN。无 key 时自动 skip。

    @Test(.enabled(if: EnvCredentials.value(for: "HERMES_CUSTOM_QWEN38_API_KEY") != nil
        || EnvCredentials.value(for: "BAILIAN_TOKEN_PLAN_API_KEY") != nil,
        "未配置百炼 API key，跳过 live 测试"))
    func testDashScopeLiveChat() async throws {
        let key = EnvCredentials.value(for: "HERMES_CUSTOM_QWEN38_API_KEY")
            ?? EnvCredentials.value(for: "BAILIAN_TOKEN_PLAN_API_KEY")
        let requiredKey = try #require(key, "live test enabled but no DashScope API key was available")
        let provider = DashScopeProvider(apiKey: requiredKey)
        try #require(provider.resolvedAPIKey != nil)
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "只回复两个字：你好")],
            systemPrompt: nil,
            maxTokens: 64,
            temperature: 0.1
        )
        #expect(!response.text.isEmpty)
        #expect(response.text.contains("你好") || response.text.contains("Hello") || response.text.contains("hello"))
    }
}
