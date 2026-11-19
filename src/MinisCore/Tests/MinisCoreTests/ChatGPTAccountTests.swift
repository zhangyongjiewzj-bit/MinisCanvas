import Foundation
import Testing
@testable import MinisCore

private final class ChatGPTAccountMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, String) -> (Int, String))?
    nonisolated(unsafe) static var requests: [(URL, String)] = []
    static let recordLock = NSLock()
    static func snapshot() -> [(URL, String)] { recordLock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = Data()
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let text = String(decoding: body, as: UTF8.self)
        Self.recordLock.withLock { Self.requests.append((request.url!, text)) }
        let (status, payload) = Self.handler?(request, text) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Keychain whose writes can be switched off to simulate a locked or refusing Keychain.
private final class FlakyKeychainBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]
    private var failWrites = false
    func setFailWrites(_ value: Bool) { lock.withLock { failWrites = value } }
    func set(_ value: String, forKey key: String) -> Bool {
        lock.withLock { () -> Bool in
            if failWrites { return false }
            store[key] = value
            return true
        }
    }
    func get(_ key: String) -> String? { lock.withLock { store[key] } }
    func delete(_ key: String) -> Bool {
        lock.withLock { () -> Bool in
            store[key] = nil
            return true
        }
    }
}

@Suite(.serialized)
struct ChatGPTAccountTests {
    private func makeSession(tokens: ChatGPTAccountTokens?, now: Date) throws -> (ChatGPTAccountSession, KeychainStore) {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let registration = ChatGPTAccountRegistration(clientID: "oaiapp_test", hostID: "urn:uuid:test", subject: "sub-1",
                                                      email: "a@example.com", needsRelogin: false)
        #expect(keychain.set(String(decoding: try JSONEncoder().encode(registration), as: UTF8.self),
                             forKey: "chatgpt.account.registration.v1"))
        if let tokens {
            #expect(keychain.set(String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self),
                                 forKey: "chatgpt.account.tokens.v1"))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTAccountMockProtocol.self]
        return (ChatGPTAccountSession(keychain: keychain, session: URLSession(configuration: configuration), now: { now }), keychain)
    }

    private func storedTokens(_ keychain: KeychainStore) throws -> ChatGPTAccountTokens {
        let raw = try #require(keychain.get("chatgpt.account.tokens.v1"))
        return try JSONDecoder().decode(ChatGPTAccountTokens.self, from: Data(raw.utf8))
    }

    // PKCE S256 (RFC 7636 appendix B vector) and state validation of the callback.
    @Test func pkceChallengeAndCallbackStateAreChecked() throws {
        #expect(MCPOAuthCoordinator.pkceChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = try #require(ChatGPTAccountAuthorization.makeURL(
            clientID: "dynamic_agent_client", redirectURI: "http://127.0.0.1:5000/auth/callback", state: "s1", nonce: "n1",
            codeChallenge: "chal", hostID: "urn:uuid:h", agentName: "MinisCanvas", idTokenHint: nil, loginHint: "a+b@example.com"))
        let query = url.absoluteString
        #expect(query.contains("code_challenge_method=S256") && query.contains("ext_agent_host_id=urn%3Auuid%3Ah"))
        #expect(query.contains("login_hint=a%2Bb%40example.com") && query.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"))

        let good = URL(string: "http://127.0.0.1:5000/auth/callback?code=c1&state=s1&client_id=oaiapp_x&scope=openid%20chatgpt.tokens.use.direct")!
        let parsed = try ChatGPTAccountAuthorization.parseCallback(good, expectedState: "s1")
        #expect(parsed.code == "c1" && parsed.clientID == "oaiapp_x" && parsed.scopes.contains("chatgpt.tokens.use.direct"))
        #expect(throws: ChatGPTAccountError.stateMismatch) {
            try ChatGPTAccountAuthorization.parseCallback(good, expectedState: "other")
        }
        let denied = URL(string: "http://127.0.0.1:5000/auth/callback?error=access_denied&state=s1")!
        #expect(throws: ChatGPTAccountError.accessDenied) { try ChatGPTAccountAuthorization.parseCallback(denied, expectedState: "s1") }
    }

    // An expiring access token is refreshed once; the rotated refresh token replaces the old one.
    @Test func refreshRotatesRefreshTokenAndIsReusedUntilExpiry() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = ChatGPTAccountTokens(accessToken: "old-access", refreshToken: "old-refresh", idToken: nil,
                                       expiresAt: now.addingTimeInterval(60), scopes: ["chatgpt.tokens.use.direct"], savedAt: now)
        let (session, keychain) = try makeSession(tokens: old, now: now)
        ChatGPTAccountMockProtocol.requests = []
        ChatGPTAccountMockProtocol.handler = { _, _ in
            (200, #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#)
        }
        let first = try await session.accessToken()
        let second = try await session.accessToken()
        #expect(first == "new-access" && second == "new-access")
        #expect(ChatGPTAccountMockProtocol.requests.count == 1)
        let form = try #require(ChatGPTAccountMockProtocol.requests.first?.1)
        #expect(form.contains("grant_type=refresh_token") && form.contains("refresh_token=old-refresh") && form.contains("client_id=oaiapp_test"))
        let saved = try storedTokens(keychain)
        #expect(saved.refreshToken == "new-refresh" && saved.accessToken == "new-access")
        #expect(saved.scopes == ["chatgpt.tokens.use.direct"])
    }

    // A revoked refresh token clears the tokens, asks for a new sign-in, and no error text carries a token.
    @Test func revokedRefreshTokenClearsSessionWithoutLeakingTokens() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = ChatGPTAccountTokens(accessToken: "secret-access-123", refreshToken: "secret-refresh-456", idToken: nil,
                                       expiresAt: now.addingTimeInterval(-10), scopes: [], savedAt: now)
        let (session, keychain) = try makeSession(tokens: old, now: now)
        ChatGPTAccountMockProtocol.handler = { _, body in (400, #"{"error":"refresh_token_reused","echo":"\#(body)"}"#) }
        do {
            _ = try await session.accessToken()
            Issue.record("refresh should fail")
        } catch {
            #expect(error as? ChatGPTAccountError == .sessionExpired)
            let text = "\(error) \(error.localizedDescription)"
            #expect(!text.contains("secret-refresh-456") && !text.contains("secret-access-123"))
        }
        #expect(keychain.get("chatgpt.account.tokens.v1") == nil)
        #expect(await session.status() == .needsRelogin(ChatGPTAccountInfo(email: "a@example.com")))
    }

    // Requests are rewritten to the ChatGPT plan limits.
    @Test func requestBodyIsRewrittenToPlanLimits() throws {
        var body: [String: Any] = [
            "model": "gpt-x", "stream": false, "max_output_tokens": 100, "temperature": 0.2, "previous_response_id": "r1",
            "input": [
                ["role": "system", "content": [["type": "input_text", "text": "s"]]],
                ["type": "function_call", "call_id": "c1", "name": "read_file", "arguments": "{}"],
                ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": "AA", "format": "wav"]]]]
            ],
            "tools": [["type": "function", "name": "read_file"], ["type": "image_generation"]]
        ]
        ChatGPTAccountRequestPolicy.rewrite(&body)
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == true)
        #expect(body["max_output_tokens"] == nil && body["temperature"] == nil && body["previous_response_id"] == nil)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input[0]["role"] as? String == "developer")
        #expect(input[1]["namespace"] as? String == "minis_tools")
        #expect(((input[2]["content"] as? [[String: Any]])?.first?["type"] as? String) == "input_text")
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1 && tools[0]["type"] as? String == "namespace")
        #expect((tools[0]["tools"] as? [[String: Any]])?.count == 1)
    }

    // Plan-usage codes map to fixed Chinese guidance.
    @Test func usageLimitCodeMapsToGuidance() {
        let body = Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"server text"}}"#.utf8)
        guard case .providerError(let message)? = ChatGPTAccountErrors.llmError(statusCode: 429, body: body) else {
            Issue.record("expected providerError"); return
        }
        #expect(message.contains("用量") && !message.contains("server text"))
    }

    // 诊断日志只含状态码与标识符形态的 type/code/param，不含 message 和非 JSON 正文。
    @Test func diagnosticSummaryOmitsServerFreeText() {
        let json = Data(#"{"error":{"type":"invalid_request_error","code":"unsupported_parameter","param":"max_output_tokens","message":"合成私密句子 alpha"}}"#.utf8)
        let summary = ChatGPTAccountErrors.diagnosticSummary(statusCode: 400, body: json)
        #expect(summary == "status=400 type=invalid_request_error code=unsupported_parameter param=max_output_tokens")
        let plain = ChatGPTAccountErrors.diagnosticSummary(statusCode: 502, body: Data("合成私密正文 beta".utf8))
        #expect(plain == "status=502")
        let sentence = Data(#"{"error":{"code":"含空格的 自由文本 gamma"}}"#.utf8)
        #expect(ChatGPTAccountErrors.diagnosticSummary(statusCode: 400, body: sentence) == "status=400")
    }

    // MARK: Second-round security fixes

    private func seed(_ keychain: KeychainStore, tokens: ChatGPTAccountTokens?, subject: String? = "sub-1") throws {
        let registration = ChatGPTAccountRegistration(clientID: "oaiapp_test", hostID: "urn:uuid:test", subject: subject,
                                                      email: "a@example.com", needsRelogin: false)
        #expect(keychain.set(String(decoding: try JSONEncoder().encode(registration), as: UTF8.self),
                             forKey: "chatgpt.account.registration.v1"))
        if let tokens {
            #expect(keychain.set(String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self),
                                 forKey: "chatgpt.account.tokens.v1"))
        }
    }

    private func mockedURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTAccountMockProtocol.self]
        return URLSession(configuration: configuration)
    }

    // 1. A rotated refresh token survives a failed Keychain write and is saved on a later access.
    @Test func rotatedTokenSurvivesKeychainWriteFailureAndIsRetried() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let backing = FlakyKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let old = ChatGPTAccountTokens(accessToken: "old-access", refreshToken: "old-refresh", idToken: nil,
                                       expiresAt: now.addingTimeInterval(60), scopes: ["chatgpt.tokens.use.direct"], savedAt: now)
        try seed(keychain, tokens: old)
        backing.setFailWrites(true)
        let session = ChatGPTAccountSession(keychain: keychain, session: mockedURLSession(), now: { now })
        ChatGPTAccountMockProtocol.requests = []
        ChatGPTAccountMockProtocol.handler = { _, _ in
            (200, #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#)
        }
        #expect(try await session.accessToken() == "new-access")
        #expect(try await session.accessToken() == "new-access")      // served from memory, no second refresh
        #expect(ChatGPTAccountMockProtocol.snapshot().count == 1)
        #expect(try storedTokens(keychain).refreshToken == "old-refresh")
        backing.setFailWrites(false)
        #expect(try await session.accessToken() == "new-access")      // retry writes the rotated token
        #expect(try storedTokens(keychain).refreshToken == "new-refresh")
    }

    // 2. A terminal refresh failure must not delete a token another instance has already rotated.
    @Test func terminalRefreshFailureKeepsTokensRotatedElsewhere() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keychain = KeychainStore(backing: FlakyKeychainBacking())
        let old = ChatGPTAccountTokens(accessToken: "old-access", refreshToken: "old-refresh", idToken: nil,
                                       expiresAt: now.addingTimeInterval(-10), scopes: ["chatgpt.tokens.use.direct"], savedAt: now)
        try seed(keychain, tokens: old)
        let session = ChatGPTAccountSession(keychain: keychain, session: mockedURLSession(), now: { now })
        let other = ChatGPTAccountTokens(accessToken: "other-access", refreshToken: "other-refresh", idToken: nil,
                                         expiresAt: now.addingTimeInterval(3600), scopes: ["chatgpt.tokens.use.direct"], savedAt: now)
        ChatGPTAccountMockProtocol.requests = []
        ChatGPTAccountMockProtocol.handler = { _, _ -> (Int, String) in
            _ = keychain.set(String(decoding: (try? JSONEncoder().encode(other)) ?? Data(), as: UTF8.self),
                             forKey: "chatgpt.account.tokens.v1")
            return (400, #"{"error":"refresh_token_reused"}"#)
        }
        #expect(try await session.accessToken() == "other-access")
        #expect(try storedTokens(keychain).refreshToken == "other-refresh")
        #expect(await session.status() == .signedIn(ChatGPTAccountInfo(email: "a@example.com")))
    }

    // 3. A failed "other account" sign-in leaves the old registration and tokens usable.
    @Test func failedAccountSwitchKeepsPreviousSignIn() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keychain = KeychainStore(backing: FlakyKeychainBacking())
        let old = ChatGPTAccountTokens(accessToken: "old-access", refreshToken: "old-refresh", idToken: nil,
                                       expiresAt: now.addingTimeInterval(3600), scopes: ["chatgpt.tokens.use.direct"], savedAt: now)
        try seed(keychain, tokens: old)
        let session = ChatGPTAccountSession(keychain: keychain, session: mockedURLSession(), now: { now })
        do {
            _ = try await session.login(replaceRegistration: true) { _ in false }   // browser cannot be opened
            Issue.record("login should fail")
        } catch {
            #expect(error as? ChatGPTAccountError == .browserUnavailable)
        }
        #expect(await session.status() == .signedIn(ChatGPTAccountInfo(email: "a@example.com")))
        let raw = try #require(keychain.get("chatgpt.account.registration.v1"))
        let registration = try JSONDecoder().decode(ChatGPTAccountRegistration.self, from: Data(raw.utf8))
        #expect(registration.clientID == "oaiapp_test" && registration.subject == "sub-1")
        #expect(try await session.accessToken() == "old-access")
    }

    // 4a. Only a request with the right state and a code/error completes the callback.
    @Test func loopbackCallbackNeedsMatchingState() {
        func match(_ target: String) -> URL? {
            LoopbackOAuthListener.matchCallback(target: target, port: 5000, callbackPath: "/auth/callback", expectedState: "s1")
        }
        #expect(match("/auth/callback") == nil)
        #expect(match("/auth/callback?code=c1") == nil)
        #expect(match("/auth/callback?code=c1&state=wrong") == nil)
        #expect(match("/auth/callback?code=c1&state=s1&state=s1") == nil)
        #expect(match("/auth/callback?state=s1") == nil)
        #expect(match("/other?code=c1&state=s1") == nil)
        #expect(match("/auth/callback?code=c1&state=s1") != nil)
        #expect(match("/auth/callback?error=access_denied&state=s1") != nil)
    }

    // 4b. The token is only sent to the official host on the default https port.
    @Test func accountTokenOnlyGoesToOfficialHostOnDefaultPort() {
        #expect(ChatGPTAccountEndpoints.isOfficialAPIURL(URL(string: "https://api.openai.com/v1/responses")!))
        #expect(ChatGPTAccountEndpoints.isOfficialAPIURL(URL(string: "https://api.openai.com:443/v1/responses")!))
        #expect(!ChatGPTAccountEndpoints.isOfficialAPIURL(URL(string: "https://api.openai.com:8443/v1/responses")!))
        #expect(!ChatGPTAccountEndpoints.isOfficialAPIURL(URL(string: "http://api.openai.com/v1/responses")!))
        #expect(!ChatGPTAccountEndpoints.isOfficialAPIURL(URL(string: "https://api.openai.com.evil.com/v1/responses")!))
    }

    // 4c. An unverifiable id_token in a refresh response is not stored; the new access/refresh tokens are.
    @Test func refreshDropsUnverifiableIDToken() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keychain = KeychainStore(backing: FlakyKeychainBacking())
        let old = ChatGPTAccountTokens(accessToken: "old-access", refreshToken: "old-refresh", idToken: "old-id",
                                       expiresAt: now.addingTimeInterval(60), scopes: ["chatgpt.tokens.use.direct"], savedAt: now)
        try seed(keychain, tokens: old)
        let session = ChatGPTAccountSession(keychain: keychain, session: mockedURLSession(), now: { now })
        ChatGPTAccountMockProtocol.handler = { request, _ in
            switch request.url?.path {
            case "/.well-known/openid-configuration":
                return (200, #"{"jwks_uri":"https://auth.openai.com/jwks","revocation_endpoint":"https://auth.openai.com/revoke"}"#)
            case "/jwks":
                return (200, #"{"keys":[{"kty":"EC","kid":"k1","x":"AAAA","y":"AAAA"}]}"#)
            default:
                return (200, #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"id_token":"e30.e30.AAAA"}"#)
            }
        }
        #expect(try await session.accessToken() == "new-access")
        let saved = try storedTokens(keychain)
        #expect(saved.refreshToken == "new-refresh" && saved.idToken == "old-id")
    }

    // 4d. A token that was issued but then rejected locally is revoked (here: no direct-use scope).
    @Test func locallyRejectedLoginTokenIsRevoked() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keychain = KeychainStore(backing: FlakyKeychainBacking())
        try seed(keychain, tokens: nil)
        let session = ChatGPTAccountSession(keychain: keychain, session: mockedURLSession(), now: { now })
        ChatGPTAccountMockProtocol.requests = []
        ChatGPTAccountMockProtocol.handler = { request, _ in
            switch request.url?.path {
            case "/.well-known/openid-configuration":
                return (200, #"{"jwks_uri":"https://auth.openai.com/jwks","revocation_endpoint":"https://auth.openai.com/revoke"}"#)
            case "/revoke":
                return (200, "")
            default:
                return (200, #"{"access_token":"a","refresh_token":"rejected-refresh","expires_in":3600,"id_token":"e30.e30.AAAA","scope":"openid"}"#)
            }
        }
        do {
            _ = try await session.login { authorizationURL in
                let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let redirect = query.first(where: { $0.name == "redirect_uri" })?.value,
                      let state = query.first(where: { $0.name == "state" })?.value,
                      let wrong = URL(string: redirect + "?code=bad&state=wrong"),
                      let right = URL(string: redirect + "?code=c1&state=\(state)") else { return false }
                Task {
                    _ = try? await URLSession.shared.data(from: wrong)    // must not consume the callback
                    _ = try? await URLSession.shared.data(from: right)
                }
                return true
            }
            Issue.record("login should be rejected")
        } catch {
            #expect(error as? ChatGPTAccountError == .planUsageNotEnabled)
        }
        var revoked = false
        for _ in 0..<40 where !revoked {
            revoked = ChatGPTAccountMockProtocol.snapshot().contains {
                $0.0.path == "/revoke" && $0.1.contains("rejected-refresh")
            }
            if !revoked { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        #expect(revoked)
    }
}

/// B-1/B-2（2026-11-17 真机 400）：Responses 线路的请求体形状。
@Suite("Responses 请求体形状：多轮助手文本与图片字段")
struct ResponsesWireShapeTests {
    @Test("第二轮起助手历史用 output_text，图片 image_url 是字符串，空助手消息不回放")
    func multiTurnAssistantAndImageShape() throws {
        let provider = OpenAIResponsesProvider(apiKey: "unit-test-key", model: .gpt4oMini,
                                               customBaseURL: "https://mock.test", appendV1Suffix: true)
        // 真实的 1×1 PNG（只有文件头的假数据会被媒体校验换成文字说明）。
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let body = try provider.requestBody(messages: [
            LLMMessage(role: .user, content: "你好"),
            LLMMessage(role: .assistant, content: "你好！"),
            LLMMessage(role: .assistant, content: ""),
            LLMMessage(role: .user, content: "看图", images: [.init(mimeType: "image/png", data: png)])
        ], systemPrompt: nil, maxTokens: 64, temperature: nil, stream: true)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.count == 3)
        let assistantParts = try #require(input[1]["content"] as? [[String: Any]])
        #expect(input[1]["role"] as? String == "assistant")
        #expect(assistantParts.map { $0["type"] as? String } == ["output_text"])
        let userParts = try #require(input[2]["content"] as? [[String: Any]])
        let image = try #require(userParts.first { $0["type"] as? String == "input_image" })
        #expect((image["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }
}

/// SSE responder with the event-stream content type the Responses stream policy requires.
private final class ChatGPTAccountSSEMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct ChatGPTAccountStreamTerminalTests {
    private static func sse(_ events: [(String, String)]) -> String {
        events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
    }

    /// 旅程实测：ChatGPT 账号线路（store:false）的 response.completed 可以不带 output。
    /// 修之前终态从空 output 取文字，与已流出的文字对不上，回复显示完后报"模型服务请求失败"；
    /// 带工具时第一个事件前就失败、被当成建流失败反复重试。对齐 Codex：用流里完成的输出项拼回终态。
    @Test func emptyCompletedOutputIsRebuiltFromStreamedItems() async throws {
        let now = Date()
        let keychain = KeychainStore(backing: FlakyKeychainBacking())
        let registration = ChatGPTAccountRegistration(clientID: "oaiapp_test", hostID: "urn:uuid:test",
                                                      subject: "sub-1", email: nil, needsRelogin: false)
        #expect(keychain.set(String(decoding: try JSONEncoder().encode(registration), as: UTF8.self),
                             forKey: "chatgpt.account.registration.v1"))
        let tokens = ChatGPTAccountTokens(accessToken: "fixture-access", refreshToken: "fixture-refresh", idToken: nil,
                                          expiresAt: now.addingTimeInterval(3_600),
                                          scopes: ["chatgpt.tokens.use.direct"], savedAt: now)
        #expect(keychain.set(String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self),
                             forKey: "chatgpt.account.tokens.v1"))
        let previous = ChatGPTAccountSessions.shared
        ChatGPTAccountSessions.install(ChatGPTAccountSession(keychain: keychain))
        defer { if let previous { ChatGPTAccountSessions.install(previous) } }

        ChatGPTAccountSSEMockProtocol.body = Self.sse([
            ("response.created", #"{"type":"response.created","response":{"id":"resp_acct_1","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"你好"}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"你好"}]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"run_command","arguments":""}}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"run_command","arguments":"{\"command\":\"ls\"}"}}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"resp_acct_1","status":"completed","output":[],"usage":{"input_tokens":9,"output_tokens":4}}}"#),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTAccountSSEMockProtocol.self]
        let checkpoints = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatgpt-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkpoints) }
        let provider = OpenAIResponsesProvider(
            apiKey: ChatGPTAccountSession.credentialPlaceholder, model: .gpt4oMini, customBaseURL: nil,
            appendV1Suffix: true, session: URLSession(configuration: configuration),
            providerName: "ChatGPT", attemptCheckpointDirectory: checkpoints)
        let tool = AgentToolDefinition(name: "run_command", description: "fixture",
                                       parameters: ["command": AgentToolParam(type: .string, description: "command")],
                                       required: ["command"])
        let stream = try await provider.streamAssistantMessage(
            messages: [LLMMessage(role: .user, content: "hi")], systemPrompt: nil,
            tools: [tool], maxTokens: 64, temperature: nil)
        var deltas: [String] = []
        var terminal: LLMResponse?
        for try await event in stream {
            switch event {
            case .textDelta(let text): deltas.append(text)
            case .thinkingDelta: break
            case .completed(let response): terminal = response
            }
        }
        #expect(deltas == ["你好"])
        let response = try #require(terminal)
        #expect(response.text == "你好")
        #expect(response.toolCalls.map(\.name) == ["run_command"])
        #expect(response.toolCalls.first?.arguments["command"] as? String == "ls")
    }
}
