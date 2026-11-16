import Foundation
import Testing
@testable import MinisCore

private final class AnthropicStreamMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseChunks: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.responseChunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        responseChunks = []
    }
}

@Suite("Anthropic provider stream security", .serialized)
struct AnthropicProviderStreamSecurityTests {
    private static func response(contentType: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: contentType.map { ["Content-Type": $0] }
        )!
    }

    @Test("Anthropic successful streams require SSE content type")
    func sseContentTypeBoundary() {
        #expect(throws: Never.self) {
            try ProviderResponseStreamPolicy.validateSSEResponse(
                Self.response(contentType: "text/event-stream; charset=utf-8")
            )
        }
        #expect(throws: ProviderResponseStreamPolicyError.unexpectedContentType) {
            try ProviderResponseStreamPolicy.validateSSEResponse(
                Self.response(contentType: "application/json")
            )
        }
        #expect(throws: ProviderResponseStreamPolicyError.missingContentType) {
            try ProviderResponseStreamPolicy.validateSSEResponse(Self.response(contentType: nil))
        }
    }

    @Test("Anthropic stream budget charges decoded UTF-8 before event parsing")
    func decodedResponseBudget() throws {
        var budget = ProviderResponseStreamPolicy.DecodedByteBudget()
        let line = "data: " + String(repeating: "中", count: 64)
        try budget.consume(line: line)
        #expect(budget.decodedBytes == line.utf8.count + 1)

        #expect(throws: ProviderResponseStreamPolicyError.lineTooLarge) {
            try budget.consume(
                line: String(repeating: "x", count: ProviderResponseStreamPolicy.maximumDecodedLineBytes + 1)
            )
        }
    }

    @Test("Anthropic stream producer stops at consumer termination")
    func terminatedConsumerStopsProducer() {
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        var stream: AsyncThrowingStream<String, Error>? = AsyncThrowingStream { value in
            continuation = value
        }
        guard let producer = continuation else {
            Issue.record("missing stream continuation")
            return
        }
        #expect(stream != nil)
        stream = nil

        #expect(throws: CancellationError.self) {
            try ProviderStreamCancellationPolicy.yield("after-stop", to: producer)
        }
    }

    @Test("Anthropic production stream routes raw bytes through SSE parser and flushes EOF")
    func productionCallerUsesIncrementalParser() async throws {
        defer { AnthropicStreamMockURLProtocol.reset() }

        let body = Data((
            "event: content_block_delta\n" +
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n" +
            "event: message_stop\n" +
            "data: {\"type\":\"message_stop\"}"
        ).utf8)
        let split = body.count / 2
        AnthropicStreamMockURLProtocol.responseChunks = [
            Data(body.prefix(split)),
            Data(body.suffix(body.count - split)),
        ]

        let provider = AnthropicProvider(
            apiKey: "fixture-api-key",
            session: AnthropicStreamMockURLProtocol.makeSession()
        )
        let stream = try await provider.streamMessage(
            messages: [LLMMessage(role: .user, content: "hello")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )

        var text = ""
        var finishedCount = 0
        for try await chunk in stream {
            switch chunk {
            case .text(let delta):
                text += delta
            case .finished:
                finishedCount += 1
            default:
                break
            }
        }

        #expect(text == "Hello")
        #expect(finishedCount == 1)
    }
}
