import Foundation
import Testing
@testable import MinisCore

// B-32 (decision 16): a reply cut by the output limit, or a stream that ends
// before the provider's protocol terminator, must never complete as a normal
// turn. Only the Provider network boundary is scripted (stub provider / URL
// protocol); the AgentLoop and OpenAICompatibleProvider paths are production.

// MARK: - Fixtures

private final class B32LengthProvider: LLMProvider, @unchecked Sendable {
    let stopReason: String
    let text: String
    init(stopReason: String, text: String) { self.stopReason = stopReason; self.text = text }
    var name: String { "B32LengthFixture" }
    var model = LLMModel(id: "b32-length", displayName: "B32 length", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: text, stopReason: stopReason, usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class B32History: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [LLMMessage] = []
    private var deltas: [String] = []
    func record(_ value: [LLMMessage]) { lock.withLock { messages = value } }
    func delta(_ value: String) { lock.withLock { deltas.append(value) } }
    var assistantText: String? { lock.withLock { messages.last(where: { $0.role == .assistant })?.content } }
    var streamedText: String { lock.withLock { deltas.joined() } }
}

private final class B32ChatMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (() throws -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler()
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [B32ChatMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func b32SSE(_ payloads: [String]) -> Data {
    payloads.map { "data: \($0)\n\n" }.joined().data(using: .utf8)!
}

private func b32Notice(_ error: Error) -> String { error.localizedDescription }

private func b32IsTruncationNotice(_ text: String) -> Bool {
    text.contains("截断") || text.lowercased().contains("truncat")
}

// MARK: - 1. Buffered reply cut by the output limit

@Suite("B-32 output limit is visible and keeps the partial reply")
struct B32OutputLimitTests {
    @Test("length and max_tokens fail with a truncation notice, partial text kept, no success",
          arguments: ["length", "max_tokens"])
    func outputLimitIsNotASuccessfulTurn(reason: String) async throws {
        let history = B32History()
        let loop = AgentLoop(maxIterations: 2)
        let executor = BuiltinToolExecutor(allowedRoot: FileManager.default.temporaryDirectory)
        var observed: Error?
        do {
            _ = try await loop.run(
                messages: [.init(role: .user, content: "给我一份长回答")],
                systemPrompt: nil,
                provider: B32LengthProvider(stopReason: reason, text: "这是尚未完成的回答"),
                toolExecutor: executor, tools: [], onFailure: { history.record($0) })
        } catch { observed = error }
        let error = try #require(observed, "达到输出上限不能作为完整回答成功结束")
        #expect(b32IsTruncationNotice(b32Notice(error)))
        #expect(history.assistantText == "这是尚未完成的回答")
    }

    @Test("an empty reply cut by the limit is a truncation, not an empty-response error")
    func emptyTruncatedReplyReportsTruncation() async throws {
        let loop = AgentLoop(maxIterations: 2)
        let executor = BuiltinToolExecutor(allowedRoot: FileManager.default.temporaryDirectory)
        var observed: Error?
        do {
            _ = try await loop.run(
                messages: [.init(role: .user, content: "hi")], systemPrompt: nil,
                provider: B32LengthProvider(stopReason: "length", text: ""),
                toolExecutor: executor, tools: [])
        } catch { observed = error }
        let error = try #require(observed)
        #expect(b32IsTruncationNotice(b32Notice(error)))
    }

    @Test("a normal stop still completes without a notice")
    func normalStopCompletes() async throws {
        let loop = AgentLoop(maxIterations: 2)
        let executor = BuiltinToolExecutor(allowedRoot: FileManager.default.temporaryDirectory)
        let result = try await loop.run(
            messages: [.init(role: .user, content: "hi")], systemPrompt: nil,
            provider: B32LengthProvider(stopReason: "stop", text: "完整回答"),
            toolExecutor: executor, tools: [])
        #expect(result.messages.last?.content == "完整回答")
    }
}

// MARK: - 2/3. Chat Completions streams

@Suite("B-32 Chat Completions stream termination", .serialized)
struct B32ChatStreamTerminationTests {
    private static func provider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(apiKey: "fixture-chat-secret", session: B32ChatMockURLProtocol.makeSession())
    }

    private static func run(
        history: B32History, executor: RecordingToolExecutor
    ) async throws -> AgentLoopResult {
        var loop = AgentLoop(maxIterations: 1,
                             approvalGate: ApprovalGate(policyByTool: ["file_write": .autoApprove]))
        loop.onAssistantTextDelta = { _, delta in history.delta(delta) }
        return try await loop.run(
            messages: [.init(role: .user, content: "Write a long answer")], systemPrompt: nil,
            provider: provider(), toolExecutor: executor,
            tools: AgentToolCatalog.makeTools().filter { $0.name == "file_write" },
            onFailure: { history.record($0) })
    }

    @Test("streamed finish_reason=length keeps streamed text and reports truncation")
    func streamedLengthReportsTruncation() async throws {
        defer { B32ChatMockURLProtocol.handler = nil }
        B32ChatMockURLProtocol.handler = {
            (200, b32SSE([
                #"{"choices":[{"index":0,"delta":{"role":"assistant","content":"前半"}}]}"#,
                #"{"choices":[{"index":0,"delta":{"content":"段回答"},"finish_reason":"length"}]}"#,
                #"[DONE]"#,
            ]), ["Content-Type": "text/event-stream"])
        }
        let history = B32History()
        var observed: Error?
        do { _ = try await Self.run(history: history, executor: RecordingToolExecutor()) }
        catch { observed = error }
        let error = try #require(observed, "length 截断不能当作正常完成")
        #expect(b32IsTruncationNotice(b32Notice(error)))
        #expect(history.streamedText == "前半段回答")
        #expect(history.assistantText == "前半段回答")
    }

    @Test("stream cut after partial text (no finish_reason, no [DONE]) is a retryable error")
    func partialTextThenDisconnectIsRetryable() async throws {
        defer { B32ChatMockURLProtocol.handler = nil }
        B32ChatMockURLProtocol.handler = {
            (200, b32SSE([
                #"{"choices":[{"index":0,"delta":{"role":"assistant","content":"半截"}}]}"#,
                #"{"choices":[{"index":0,"delta":{"content":"文本"}}]}"#,
            ]), ["Content-Type": "text/event-stream"])
        }
        let history = B32History()
        var observed: Error?
        do { _ = try await Self.run(history: history, executor: RecordingToolExecutor()) }
        catch { observed = error }
        let error = try #require(observed, "提前断流不能当作正常完成")
        let llm = try #require(error as? LLMError, "应为 Provider 层的可重试错误，实际 \(error)")
        #expect(llm.isRetryable)
        #expect(history.streamedText == "半截文本", "已流出的半截文本必须保留在界面里")
    }

    @Test("stream cut with no text at all is a retryable error")
    func emptyStreamThenDisconnectIsRetryable() async throws {
        defer { B32ChatMockURLProtocol.handler = nil }
        B32ChatMockURLProtocol.handler = {
            (200, b32SSE([
                #"{"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#,
            ]), ["Content-Type": "text/event-stream"])
        }
        var observed: Error?
        do { _ = try await Self.run(history: B32History(), executor: RecordingToolExecutor()) }
        catch { observed = error }
        let error = try #require(observed)
        #expect((error as? LLMError)?.isRetryable == true, "实际 \(error)")
    }

    @Test("stream cut inside a tool call never executes the tool and is retryable")
    func toolCallThenDisconnectIsRetryableAndNotExecuted() async throws {
        defer { B32ChatMockURLProtocol.handler = nil }
        B32ChatMockURLProtocol.handler = {
            (200, b32SSE([
                #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_cut","type":"function","function":{"name":"file_write","arguments":"{\"path\":\"/tmp/b32-never\",\"content\":\"abc"}}]}}]}"#,
            ]), ["Content-Type": "text/event-stream"])
        }
        let executor = RecordingToolExecutor()
        var observed: Error?
        do { _ = try await Self.run(history: B32History(), executor: executor) }
        catch { observed = error }
        let error = try #require(observed)
        #expect((error as? LLMError)?.isRetryable == true, "实际 \(error)")
        #expect(executor.executedNames.isEmpty)
    }

    @Test("a stream closed by finish_reason=stop alone, or by [DONE] alone, still completes")
    func singleTerminatorStillCompletes() async throws {
        defer { B32ChatMockURLProtocol.handler = nil }
        let variants: [[String]] = [
            [#"{"choices":[{"index":0,"delta":{"role":"assistant","content":"好"},"finish_reason":"stop"}]}"#],
            [#"{"choices":[{"index":0,"delta":{"role":"assistant","content":"好"}}]}"#, #"[DONE]"#],
        ]
        for payloads in variants {
            B32ChatMockURLProtocol.handler = {
                (200, b32SSE(payloads), ["Content-Type": "text/event-stream"])
            }
            let history = B32History()
            let result = try await Self.run(history: history, executor: RecordingToolExecutor())
            #expect(result.messages.last?.content == "好")
        }
    }
}
