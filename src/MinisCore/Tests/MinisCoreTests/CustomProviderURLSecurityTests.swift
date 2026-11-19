import Foundation
import Testing
@testable import MinisCore

// S4 HIGH security slice — 自定义 Provider URL 必须校验 scheme/host，且不得把
// Bearer 认证发送到不安全（非 HTTPS / 非 loopback）目的地。
//
// 红阶段：以下断言只使用既有 Provider API（OpenAICompatibleProvider /
// OpenAIResponsesProvider）。当前实现仅对自定义 URL 做空白处理，会把
// "Authorization: Bearer <key>" 原样发往任意 http(s) 目的地，因此这些断言
// 在实现前全部为运行时红（发送成功 ≠ 抛错；请求计数 ≠ 0）。

// MARK: - Mock URLProtocol（独立静态状态，本 suite 串行执行，避免跨 suite 并行污染）

final class S4ProviderURLMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        S4ProviderURLMockURLProtocol.requests.append(request)
        guard let handler = S4ProviderURLMockURLProtocol.handler else {
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
        requests = []
        handler = nil
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [S4ProviderURLMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - 合法响应体（成功路径 guard rail）

private let s4ChatCompletionOK = Data(#"""
{"id":"chatcmpl-s4","object":"chat.completion","created":0,"model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
"""#.utf8)

private let s4ResponsesOK = Data(#"""
{"id":"resp_1","status":"completed","output":[{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":1,"output_tokens":1}}
"""#.utf8)

// MARK: - Suite

@Suite(.serialized)
struct CustomProviderURLSecurityTests {

    private static let testAPIKey = "s4-test-unit-token"

    private static func chatProvider(customBaseURL: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            apiKey: testAPIKey,
            model: .gpt4oMini,
            customBaseURL: customBaseURL,
            session: S4ProviderURLMockURLProtocol.makeSession()
        )
    }

    private static func responsesProvider(
        customBaseURL: String,
        checkpointDirectory: URL
    ) -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(
            apiKey: testAPIKey,
            model: .gpt4oMini,
            customBaseURL: customBaseURL,
            appendV1Suffix: true,
            session: S4ProviderURLMockURLProtocol.makeSession(),
            providerName: "OpenAI Responses",
            attemptCheckpointDirectory: checkpointDirectory
        )
    }

    private static func makeResponsesCheckpointDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s4-responses-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: OpenAICompatible — 不安全目的地必须 fail-closed

    @Test("chat: 局域网 http 中转站可用且携带 Bearer")
    func chatAllowsLANHTTP() async throws {
        defer { S4ProviderURLMockURLProtocol.reset() }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ChatCompletionOK, ["Content-Type": "application/json"]) }
        let provider = Self.chatProvider(customBaseURL: "http://192.168.1.20:3000/v1")
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            maxTokens: 10,
            temperature: nil
        )
        #expect(response.text == "ok")
        let sent = try #require(S4ProviderURLMockURLProtocol.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.testAPIKey)")
    }

    @Test("chat: ftp scheme 必须抛错且零请求")
    func chatRejectsUnsupportedScheme() async {
        defer { S4ProviderURLMockURLProtocol.reset() }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ChatCompletionOK, ["Content-Type": "application/json"]) }
        let provider = Self.chatProvider(customBaseURL: "ftp://example.com/v1")
        await #expect(throws: LLMError.self) {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                maxTokens: 10,
                temperature: nil
            )
        }
        #expect(S4ProviderURLMockURLProtocol.requests.isEmpty)
    }

    @Test("chat: file scheme 必须抛错且零请求")
    func chatRejectsFileScheme() async {
        defer { S4ProviderURLMockURLProtocol.reset() }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ChatCompletionOK, ["Content-Type": "application/json"]) }
        let provider = Self.chatProvider(customBaseURL: "file:///etc/passwd")
        await #expect(throws: LLMError.self) {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                maxTokens: 10,
                temperature: nil
            )
        }
        #expect(S4ProviderURLMockURLProtocol.requests.isEmpty)
    }

    @Test("chat: URL 内嵌凭据必须抛错且零请求")
    func chatRejectsEmbeddedCredentials() async {
        defer { S4ProviderURLMockURLProtocol.reset() }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ChatCompletionOK, ["Content-Type": "application/json"]) }
        let provider = Self.chatProvider(customBaseURL: "https://user:pass@example.com/v1")
        await #expect(throws: LLMError.self) {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                maxTokens: 10,
                temperature: nil
            )
        }
        #expect(S4ProviderURLMockURLProtocol.requests.isEmpty)
    }

    @Test("chat: streamMessage 不安全 base 同样 fail-closed 且零请求")
    func chatStreamMessageRejectsUnsafeBase() async {
        defer { S4ProviderURLMockURLProtocol.reset() }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ChatCompletionOK, ["Content-Type": "application/json"]) }
        let provider = Self.chatProvider(customBaseURL: "ftp://example.com/v1")
        await #expect(throws: LLMError.self) {
            _ = try await provider.streamMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                maxTokens: 10,
                temperature: nil
            )
        }
        #expect(S4ProviderURLMockURLProtocol.requests.isEmpty)
    }

    @Test("chat: streamRaw 不安全 base 在触网前抛错")
    func chatStreamRawRejectsUnsafeBase() async {
        let provider = Self.chatProvider(customBaseURL: "ftp://example.com/v1")
        await #expect(throws: LLMError.self) {
            _ = try await provider.streamRaw(body: ["model": "gpt-4o-mini", "messages": []])
        }
    }

    // MARK: OpenAICompatible — 安全目的地必须照常工作（guard rail）

    @Test("chat: https 自定义 base 正常工作且携带 Bearer")
    func chatAllowsHTTPS() async throws {
        defer { S4ProviderURLMockURLProtocol.reset() }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ChatCompletionOK, ["Content-Type": "application/json"]) }
        let provider = Self.chatProvider(customBaseURL: "https://api.example.com/v1")
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            maxTokens: 10,
            temperature: nil
        )
        #expect(response.text == "ok")
        let sent = try #require(S4ProviderURLMockURLProtocol.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.testAPIKey)")
    }

    @Test("chat: 地址已带版本段（/v1beta/openai、/api/paas/v4）不再追加 /v1，裸域名才补 /v1")
    func chatDoesNotAppendV1AfterVersionedPath() async throws {
        defer { S4ProviderURLMockURLProtocol.reset() }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ChatCompletionOK, ["Content-Type": "application/json"]) }
        let cases = [
            ("https://generativelanguage.googleapis.com/v1beta/openai",
             "/v1beta/openai/chat/completions"),
            ("https://open.bigmodel.cn/api/paas/v4", "/api/paas/v4/chat/completions"),
            ("https://api.example.com", "/v1/chat/completions"),
            // OpenRouter 工厂默认地址不带版本段，仍补 /v1。
            ("https://openrouter.ai/api", "/api/v1/chat/completions")
        ]
        for (base, expectedPath) in cases {
            S4ProviderURLMockURLProtocol.requests = []
            let provider = Self.chatProvider(customBaseURL: base)
            _ = try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil, maxTokens: 10, temperature: nil)
            let sent = try #require(S4ProviderURLMockURLProtocol.requests.first)
            #expect(sent.url?.path == expectedPath)
        }
    }

    @Test("chat: loopback http 自定义 base 正常工作且携带 Bearer")
    func chatAllowsLoopbackHTTP() async throws {
        defer { S4ProviderURLMockURLProtocol.reset() }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ChatCompletionOK, ["Content-Type": "application/json"]) }
        let provider = Self.chatProvider(customBaseURL: "http://127.0.0.1:11434/v1")
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            maxTokens: 10,
            temperature: nil
        )
        #expect(response.text == "ok")
        let sent = try #require(S4ProviderURLMockURLProtocol.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.testAPIKey)")
    }

    // MARK: OpenAIResponses — 同样 fail-closed

    @Test("responses: 不安全自定义 base 必须抛错且零请求")
    func responsesRejectsUnsafeBase() async throws {
        defer { S4ProviderURLMockURLProtocol.reset() }
        let checkpointDirectory = try Self.makeResponsesCheckpointDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointDirectory) }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ResponsesOK, ["Content-Type": "application/json"]) }
        let provider = Self.responsesProvider(
            customBaseURL: "ftp://example.com/v1", checkpointDirectory: checkpointDirectory
        )
        await #expect(throws: LLMError.self) {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                maxTokens: 10,
                temperature: nil
            )
        }
        #expect(S4ProviderURLMockURLProtocol.requests.isEmpty)
    }

    @Test("responses: ftp scheme 必须抛错且零请求")
    func responsesRejectsUnsupportedScheme() async throws {
        defer { S4ProviderURLMockURLProtocol.reset() }
        let checkpointDirectory = try Self.makeResponsesCheckpointDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointDirectory) }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ResponsesOK, ["Content-Type": "application/json"]) }
        let provider = Self.responsesProvider(
            customBaseURL: "ftp://example.com/v1", checkpointDirectory: checkpointDirectory
        )
        await #expect(throws: LLMError.self) {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                maxTokens: 10,
                temperature: nil
            )
        }
        #expect(S4ProviderURLMockURLProtocol.requests.isEmpty)
    }

    @Test("responses: https 自定义 base 正常工作且携带 Bearer")
    func responsesAllowsHTTPS() async throws {
        defer { S4ProviderURLMockURLProtocol.reset() }
        let checkpointDirectory = try Self.makeResponsesCheckpointDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointDirectory) }
        S4ProviderURLMockURLProtocol.handler = { _ in (200, s4ResponsesOK, ["Content-Type": "application/json"]) }
        let provider = Self.responsesProvider(
            customBaseURL: "https://api.example.com/v1", checkpointDirectory: checkpointDirectory
        )
        let response: LLMResponse
        do {
            response = try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                maxTokens: 10,
                temperature: nil
            )
        } catch {
            Issue.record("Responses stage: \(provider.persistAttemptReceiptDiagnosticStage()); write stage: \(provider.durableAttemptWriteDiagnosticStage()); mock requests: \(S4ProviderURLMockURLProtocol.requests.count)")
            throw error
        }
        #expect(response.text == "ok")
        let sent = try #require(S4ProviderURLMockURLProtocol.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.testAPIKey)")
    }
}


// MARK: - 校验器纯逻辑测试（无网络，确定性）

@Suite
struct CustomProviderURLValidatorTests {

    // MARK: 允许

    @Test("https 任意 host 均允许")
    func allowsHTTPS() throws {
        let url = try CustomProviderURL.validate("https://api.example.com/v1")
        #expect(url.scheme == "https")
        #expect(url.host == "api.example.com")
    }

    @Test("https 裸 host 允许")
    func allowsHTTPSBareHost() throws {
        let url = try CustomProviderURL.validate("https://api.example.com")
        #expect(url.host == "api.example.com")
    }

    @Test("loopback http：localhost 允许")
    func allowsLoopbackLocalhost() throws {
        let url = try CustomProviderURL.validate("http://localhost:11434")
        #expect(url.host == "localhost")
    }

    @Test("loopback http：127.0.0.1 允许")
    func allowsLoopbackIPv4() throws {
        let url = try CustomProviderURL.validate("http://127.0.0.1:11434/v1")
        #expect(url.host == "127.0.0.1")
    }

    @Test("loopback http：127.0.0.0/8 其它地址允许")
    func allowsLoopbackIPv4Range() throws {
        _ = try CustomProviderURL.validate("http://127.0.0.2:8080")
        _ = try CustomProviderURL.validate("http://127.8.8.8:8080")
    }

    @Test("loopback http：IPv6 ::1 允许")
    func allowsLoopbackIPv6() throws {
        _ = try CustomProviderURL.validate("http://[::1]:11434")
        _ = try CustomProviderURL.validate("http://[0:0:0:0:0:0:0:1]:11434")
    }

    @Test("https 到 loopback 允许")
    func allowsHTTPSLoopback() throws {
        _ = try CustomProviderURL.validate("https://127.0.0.1:8443")
    }

    @Test("首尾空白会被 trim")
    func allowsTrimmedWhitespace() throws {
        let url = try CustomProviderURL.validate("  https://api.example.com/v1  ")
        #expect(url.host == "api.example.com")
    }

    // MARK: 拒绝

    @Test("http 公网 host 允许（表单另行提示明文风险）")
    func allowsPublicHTTP() throws {
        _ = try CustomProviderURL.validate("http://example.com/v1")
        #expect(ProviderEndpointPolicy.isPlainHTTPToPublicHost("http://example.com/v1"))
        #expect(!ProviderEndpointPolicy.isPlainHTTPToPublicHost("https://example.com/v1"))
    }

    @Test("http 局域网 IP 与本机直接允许且不提示风险")
    func allowsPrivateHTTP() throws {
        for raw in ["http://192.168.1.1", "http://10.0.0.5", "http://172.20.0.2:3000/v1", "http://localhost:1234/v1", "http://nas.local:8080"] {
            _ = try CustomProviderURL.validate(raw)
            #expect(!ProviderEndpointPolicy.isPlainHTTPToPublicHost(raw), "\(raw)")
        }
        #expect(ProviderEndpointPolicy.isPlainHTTPToPublicHost("http://8.8.8.8"))
        #expect(ProviderEndpointPolicy.isPlainHTTPToPublicHost("http://172.32.0.1"))
    }

    @Test("host 混淆：localhost.evil.com 视为公网")
    func hostTrickeryIsPublic() {
        #expect(ProviderEndpointPolicy.isPlainHTTPToPublicHost("http://localhost.evil.com"))
        #expect(ProviderEndpointPolicy.isPlainHTTPToPublicHost("http://127.0.0.1.evil.com"))
    }

    @Test("ftp scheme 拒绝")
    func rejectsFTPScheme() {
        #expect(throws: CustomProviderURL.Failure.unsupportedScheme("ftp")) {
            try CustomProviderURL.validate("ftp://example.com/v1")
        }
    }

    @Test("file scheme 拒绝")
    func rejectsFileScheme() {
        #expect(throws: CustomProviderURL.Failure.unsupportedScheme("file")) {
            try CustomProviderURL.validate("file:///etc/passwd")
        }
    }

    @Test("缺失 scheme 拒绝")
    func rejectsMissingScheme() {
        #expect(throws: CustomProviderURL.Failure.unsupportedScheme(nil)) {
            try CustomProviderURL.validate("example.com/v1")
        }
    }

    @Test("空 host 拒绝")
    func rejectsEmptyHost() {
        #expect(throws: CustomProviderURL.Failure.emptyHost) {
            try CustomProviderURL.validate("https://")
        }
    }

    @Test("内嵌凭据拒绝")
    func rejectsEmbeddedCredentials() {
        #expect(throws: CustomProviderURL.Failure.embeddedCredentials) {
            try CustomProviderURL.validate("https://user:pass@example.com")
        }
        #expect(throws: CustomProviderURL.Failure.embeddedCredentials) {
            try CustomProviderURL.validate("http://token@example.com")
        }
    }

    @Test("空白字符串拒绝")
    func rejectsBlank() {
        #expect(throws: CustomProviderURL.Failure.invalidURL("")) {
            try CustomProviderURL.validate("")
        }
        #expect(throws: CustomProviderURL.Failure.invalidURL("   ")) {
            try CustomProviderURL.validate("   ")
        }
    }

    // MARK: isLoopbackHost

    @Test("loopback host 判定")
    func loopbackHostMatrix() {
        #expect(CustomProviderURL.isLoopbackHost("localhost"))
        #expect(CustomProviderURL.isLoopbackHost("LOCALHOST"))
        #expect(CustomProviderURL.isLoopbackHost("127.0.0.1"))
        #expect(CustomProviderURL.isLoopbackHost("127.255.255.254"))
        #expect(CustomProviderURL.isLoopbackHost("::1"))
        #expect(CustomProviderURL.isLoopbackHost("[::1]"))
        #expect(!CustomProviderURL.isLoopbackHost("example.com"))
        #expect(!CustomProviderURL.isLoopbackHost("localhost.evil.com"))
        #expect(!CustomProviderURL.isLoopbackHost("127.0.0.1.evil.com"))
        #expect(!CustomProviderURL.isLoopbackHost("192.168.1.1"))
        #expect(!CustomProviderURL.isLoopbackHost("127.1"))
    }

    // MARK: isSafeDestination

    @Test("isSafeDestination 策略矩阵")
    func safeDestinationMatrix() throws {
        #expect(CustomProviderURL.isSafeDestination(try #require(URL(string: "https://api.example.com/v1"))))
        #expect(CustomProviderURL.isSafeDestination(try #require(URL(string: "http://127.0.0.1:11434"))))
        #expect(CustomProviderURL.isSafeDestination(try #require(URL(string: "http://localhost:11434"))))
        #expect(CustomProviderURL.isSafeDestination(try #require(URL(string: "http://example.com"))))
        #expect(!CustomProviderURL.isSafeDestination(try #require(URL(string: "ftp://example.com"))))
        #expect(!CustomProviderURL.isSafeDestination(try #require(URL(string: "file:///etc/passwd"))))
        #expect(!CustomProviderURL.isSafeDestination(try #require(URL(string: "https://user:pass@example.com"))))
    }
}

// MARK: - 重定向守卫决策（纯函数；真实 3xx 跟随行为由会话级证据另行验证）

@Suite
struct ProviderRedirectGuardTests {

    @Test("安全重定向放行")
    func allowsSafeRedirect() throws {
        let safe = try #require(URL(string: "https://api.example.com/v1/responses"))
        var request = URLRequest(url: safe)
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        #expect(ProviderRedirectGuard.guardedRedirect(for: request)?.url == safe)
        let loopback = try #require(URL(string: "http://127.0.0.1:11434/v1/chat/completions"))
        var loopbackRequest = URLRequest(url: loopback)
        loopbackRequest.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        #expect(ProviderRedirectGuard.guardedRedirect(for: loopbackRequest)?.url == loopback)
    }

    @Test("不安全重定向取消（返回 nil，fail-closed）")
    func cancelsUnsafeRedirect() throws {
        let http = try #require(URL(string: "ftp://example.com/steal"))
        var request = URLRequest(url: http)
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        #expect(ProviderRedirectGuard.guardedRedirect(for: request) == nil)
        let userinfo = try #require(URL(string: "https://user:pass@example.com/steal"))
        var userinfoRequest = URLRequest(url: userinfo)
        userinfoRequest.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        #expect(ProviderRedirectGuard.guardedRedirect(for: userinfoRequest) == nil)
    }
}

// MARK: - Gimage2 生图同样 fail-closed（不把 Bearer 发往不安全 base）

@Suite
struct Gimage2ProviderURLSecurityTests {

    @Test("gimage2: 不安全 base 必须抛错（网络前）")
    func gimage2RejectsUnsafeBase() async {
        let provider = Gimage2Provider(apiKey: "s4-test-unit-token", baseURL: "ftp://example.com")
        await #expect(throws: CloudBackendError.self) {
            _ = try await provider.generateImage(CloudImageRequest(prompt: "cat"))
        }
    }

    @Test("gimage2: 默认 https base 校验通过")
    func gimage2AcceptsDefaultBase() throws {
        _ = try CustomProviderURL.validate(Gimage2Provider.defaultBaseURL)
    }
}
