import Foundation
import Testing
@testable import MinisCore

/// R14 / F-J08-a: the DeepSeek official Chat Completions API only honours
/// `max_tokens`; the shared provider must not send `max_completion_tokens`
/// to the api.deepseek.com host. Mock transport only; no live endpoint.
@Suite("R14 DeepSeek output cap uses max_tokens", .serialized)
struct DeepSeekMaxTokensField_R14_Tests {
    private let cap = 321

    private func provider(base: String, router: Bool = false,
                          model: LLMModel = .deepSeekV4Flash) -> OpenAICompatibleProvider {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key", model: model,
            customBaseURL: base, appendV1Suffix: false,
            session: R14CaptureURLProtocol.session(), providerName: "DeepSeek")
        provider.useOpenRouterCompat = router
        return provider
    }

    private func sentBody(base: String, router: Bool = false, streaming: Bool = false,
                          model: LLMModel = .deepSeekV4Flash) async throws -> [String: Any] {
        R14CaptureURLProtocol.reset(streaming: streaming)
        let p = provider(base: base, router: router, model: model)
        let messages = [LLMMessage(role: .user, content: "fixture")]
        if streaming {
            if let stream = try? await p.streamMessage(messages: messages, systemPrompt: nil,
                maxTokens: cap, temperature: nil) {
                do { for try await _ in stream {} } catch {}
            }
        } else {
            _ = try? await p.sendMessage(messages: messages, systemPrompt: nil, maxTokens: cap, temperature: nil)
        }
        let request = try #require(R14CaptureURLProtocol.requests.first)
        return try R14CaptureURLProtocol.body(of: request)
    }

    private func expectMaxTokens(_ body: [String: Any]) {
        #expect(body["max_tokens"] as? Int == cap)
        #expect(body["max_completion_tokens"] == nil)
    }

    private func expectMaxCompletionTokens(_ body: [String: Any]) {
        #expect(body["max_completion_tokens"] as? Int == cap)
        #expect(body["max_tokens"] == nil)
    }

    // MARK: RED on unfixed baseline

    @Test("api.deepseek.com non-streaming sends max_tokens only")
    func bareHostNonStreaming() async throws {
        expectMaxTokens(try await sentBody(base: "https://api.deepseek.com"))
    }

    @Test("api.deepseek.com/v1 streaming sends max_tokens only and keeps include_usage")
    func v1HostStreaming() async throws {
        let body = try await sentBody(base: "https://api.deepseek.com/v1", streaming: true)
        expectMaxTokens(body)
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    }

    @Test("DeepSeekProvider default wiring sends max_tokens only")
    func wrapperDefaultWiring() async throws {
        // DeepSeekProvider has no session seam, so build the inner provider the
        // same way its init does (normalized default base, no /v1 suffix).
        let base = DeepSeekProvider.normalizedOpenAICompatibleBaseURL(DeepSeekProvider.defaultBaseURL)
        expectMaxTokens(try await sentBody(base: base))
    }

    // MARK: guards, green on unfixed baseline

    @Test("api.openai.com keeps max_completion_tokens")
    func openAIHost() async throws {
        expectMaxCompletionTokens(try await sentBody(base: "https://api.openai.com"))
    }

    // MC4-012：自定义 OpenAI 兼容端点默认用 max_tokens；官方端点与推理模型用 max_completion_tokens。
    @Test("MC4-012 custom compatible host with a non-reasoning model sends max_tokens")
    func customHostNonReasoning() async throws {
        expectMaxTokens(try await sentBody(base: "https://proxy.example/api", model: .gpt4oMini))
    }

    @Test("MC4-012 custom compatible host with a reasoning model keeps max_completion_tokens")
    func customHostReasoningModel() async throws {
        expectMaxCompletionTokens(try await sentBody(base: "https://proxy.example/api", model: .gpt5))
        expectMaxCompletionTokens(try await sentBody(base: "https://proxy.example/api",
            model: LLMModel(id: "openai/o3-mini", displayName: "o3-mini", provider: "Custom")))
    }

    @Test("MC4-012 api.openai.com with a non-reasoning model still sends max_completion_tokens")
    func officialHostNonReasoning() async throws {
        expectMaxCompletionTokens(try await sentBody(base: "https://api.openai.com", model: .gpt4oMini))
    }

    @Test("OpenRouter compat keeps max_tokens")
    func routerCompat() async throws {
        expectMaxTokens(try await sentBody(base: "https://openrouter.ai/api", router: true))
    }

    @Test("lookalike host api.openai.com.evil.example is not the OpenAI official endpoint")
    func lookalikeSuffixHost() async throws {
        expectMaxTokens(try await sentBody(base: "https://api.openai.com.evil.example", model: .gpt4oMini))
    }

    @Test("openai host name only in the path is not the OpenAI official endpoint")
    func hostInPathOnly() async throws {
        expectMaxTokens(try await sentBody(base: "https://evil.example/api.openai.com", model: .gpt4oMini))
    }
}

private final class R14CaptureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var streaming = false

    static func reset(streaming: Bool) {
        requests = []
        self.streaming = streaming
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    static func body(of request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        }
        let bodyData = try #require(data)
        let object = try JSONSerialization.jsonObject(with: bodyData)
        return try #require(object as? [String: Any])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let sse = Self.streaming
        let body = sse
            ? Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
            : Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}".utf8)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": sse ? "text/event-stream" : "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
