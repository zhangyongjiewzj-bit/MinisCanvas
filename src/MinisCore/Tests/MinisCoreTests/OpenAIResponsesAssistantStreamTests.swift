import Foundation
import Testing
@testable import MinisCore

// W5-PROVIDER-RESPONSES-048: Responses wire-SSE migration onto the
// D-CHAT-03 `AssistantStreamingLLMProvider` seam (successor to W5-044's
// chat-completions migration; the residual named in W4-037's receipt).
//
// Pins the migration contract for `OpenAIResponsesProvider`:
// - `response.output_text.delta` fragments forward live as `.textDelta`
//   (NOT a synthesized single terminal),
// - the terminal `.completed` equals what the buffered `sendMessage(tools:)`
//   would return for the same Response JSON (same admission fence),
// - function-call argument fragments never ride text deltas,
// - incomplete/truncated tool input fails closed through that same fence,
// - acquisition/terminal failures keep the payload-free typed projection
//   consumed by 037's `ProviderRequestFailureKind.classify`.
//
// Fully offline. Own suite-isolated URLProtocol stub (repo pattern: shared
// static mocks cross-contaminate under swift-testing parallel scheduling —
// see the header note in OpenAIResponsesProviderTests.swift). The durable
// attempt checkpoint is redirected at the class-level override to a fresh
// per-test directory so this suite never reads or writes the real
// Application Support checkpoint and cannot poison other suites.

// MARK: - Suite-owned mock

private final class W5048ResponsesMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (() throws -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastRequestBody = Self.bodyData(from: request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler()
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

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [W5048ResponsesMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        handler = nil
        lastRequest = nil
        lastRequestBody = nil
    }
}

// MARK: - Scripting helpers

/// Responses SSE framing: a named `event:` line, a `data:` line whose JSON
/// `type` equals the event name, blank-line delimiter (the provider flushes
/// events on the delimiter, and has no `[DONE]` sentinel).
private func responsesSSEBody(_ events: [(event: String, data: String)]) -> Data {
    var text = ""
    for pair in events {
        text += "event: " + pair.event + "\n"
        text += "data: " + pair.data + "\n"
        text += "\n"
    }
    return Data(text.utf8)
}

private func responsesSSE(_ events: [(event: String, data: String)]) -> (Int, Data, [String: String]) {
    (200, responsesSSEBody(events), ["Content-Type": "text/event-stream"])
}

@Suite("W5048 Responses assistant wire-SSE stream", .serialized)
struct W5048ResponsesAssistantStreamTests {

    // MARK: Harness

    private func makeProvider(session: URLSession, checkpointDirectory: URL) -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(
            apiKey: "fixture-responses-secret",
            model: .gpt4oMini,
            customBaseURL: "https://mock.test",
            appendV1Suffix: true,
            session: session,
            providerName: "OpenAI Responses",
            attemptCheckpointDirectory: checkpointDirectory
        )
    }

    // Each test owns its synthetic checkpoint root; no process-global
    // override can redirect another suite's provider.
    private struct CheckpointIsolation {
        let directory: URL
    }

    private func isolateCheckpointDirectory() throws -> CheckpointIsolation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("w5048-attempt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return CheckpointIsolation(directory: directory)
    }

    private func restore(_ isolation: CheckpointIsolation) {
        try? FileManager.default.removeItem(at: isolation.directory)
    }

    private static let tool: AgentToolDefinition = AgentToolDefinition(
        name: "run_command",
        description: "fixture",
        parameters: ["command": AgentToolParam(type: .string, description: "command")],
        required: ["command"]
    )

    private func stream(
        _ provider: OpenAIResponsesProvider
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await provider.streamAssistantMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            tools: [Self.tool],
            maxTokens: 64,
            temperature: nil
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<LLMAssistantStreamEvent, Error>
    ) async throws -> [LLMAssistantStreamEvent] {
        var events: [LLMAssistantStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: Tests

    @Test("text and function-call events forward incrementally with a buffered-identical terminal")
    func incrementalForwardingAndTerminalParity() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        W5048ResponsesMockURLProtocol.handler = {
            responsesSSE([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_stream_1","status":"in_progress"}}"#),
                (event: "response.output_item.added",
                 data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hel"}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"lo"}"#),
                (event: "response.output_text.done",
                 data: #"{"type":"response.output_text.done","item_id":"msg_1","output_index":0,"content_index":0,"text":"Hello"}"#),
                (event: "response.output_item.done",
                 data: #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}"#),
                (event: "response.output_item.added",
                 data: #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"run_command","arguments":""}}"#),
                (event: "response.function_call_arguments.delta",
                 data: #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":1,"delta":"{\"comm"}"#),
                (event: "response.function_call_arguments.delta",
                 data: #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":1,"delta":"and\":\"ls\"}"}"#),
                (event: "response.function_call_arguments.done",
                 data: #"{"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":1,"arguments":"{\"command\":\"ls\"}"}"#),
                (event: "response.output_item.done",
                 data: #"{"type":"response.output_item.done","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"run_command","arguments":"{\"command\":\"ls\"}"}}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_stream_1","status":"completed","output":[{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"Hello"}]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"run_command","arguments":"{\"command\":\"ls\"}"}],"usage":{"input_tokens":9,"output_tokens":4}}}"#),
            ])
        }
        let events = try await collect(stream(makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory)))

        var deltas: [String] = []
        var terminal: LLMResponse?
        for event in events {
            switch event {
            case .textDelta(let text): deltas.append(text)
            case .thinkingDelta: break
            case .completed(let response): terminal = response
            }
        }
        // Real incremental forwarding, not a synthesized single terminal.
        #expect(deltas == ["Hel", "lo"])
        guard let terminal else {
            Issue.record("assistant stream must end with a .completed event")
            return
        }
        // Terminal parity: the buffered `sendMessage(tools:)` fence on the
        // same Response JSON yields exactly this text/usage/native call.
        #expect(terminal.text == "Hello")
        #expect(terminal.stopReason == "completed")
        #expect(terminal.usage?.inputTokens == 9)
        #expect(terminal.usage?.outputTokens == 4)
        #expect(terminal.toolCalls.count == 1)
        #expect(terminal.toolCalls.first?.id == "call_1")
        #expect(terminal.toolCalls.first?.name == "run_command")
        #expect(terminal.toolCalls.first?.rawArguments == "{\"command\":\"ls\"}")
        #expect(terminal.toolCalls.first?.arguments["command"] as? String == "ls")
        // Contract 2: argument fragments never ride text deltas.
        #expect(deltas.allSatisfy { !$0.contains("comm") && !$0.contains("arguments") })
    }

    @Test("completed response with null error closes the stream with buffered parity")
    func completedNullErrorHasBufferedParity() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        let responseJSON = #"{"id":"resp_null_error","status":"completed","error":null,"output":[{"type":"message","id":"msg_null_error","content":[{"type":"output_text","text":"OK"}]}]}"#
        W5048ResponsesMockURLProtocol.handler = {
            responsesSSE([
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","item_id":"msg_null_error","output_index":0,"content_index":0,"delta":"OK"}"#),
                (event: "response.completed",
                 data: "{\"type\":\"response.completed\",\"response\":" + responseJSON + "}"),
            ])
        }
        let provider = makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory)
        let events = try await collect(stream(provider))
        #expect(events.count == 2)
        var terminal: LLMResponse?
        var deltas: [String] = []
        for event in events {
            switch event {
            case .textDelta(let text): deltas.append(text)
            case .thinkingDelta: break
            case .completed(let response): terminal = response
            }
        }
        #expect(deltas == ["OK"])
        guard let terminal else {
            Issue.record("completed response with null error must yield a terminal event")
            return
        }
        W5048ResponsesMockURLProtocol.handler = {
            (200, Data(responseJSON.utf8), ["Content-Type": "application/json"])
        }
        let buffered = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            tools: [Self.tool],
            maxTokens: 64,
            temperature: nil
        )
        #expect(terminal.text == "OK")
        #expect(terminal.stopReason == "completed")
        #expect(terminal.toolCalls.isEmpty)
        #expect(buffered.text == terminal.text)
        #expect(buffered.stopReason == terminal.stopReason)
        #expect(buffered.toolCalls.isEmpty)
    }

    @Test("incomplete tool input at the terminal fails closed without synthesis")
    func incompleteToolInputFailsClosed() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        W5048ResponsesMockURLProtocol.handler = {
            responsesSSE([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_stream_2","status":"in_progress"}}"#),
                (event: "response.output_item.added",
                 data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_trunc","type":"function_call","call_id":"call_9","name":"run_command","arguments":""}}"#),
                (event: "response.function_call_arguments.delta",
                 data: #"{"type":"response.function_call_arguments.delta","item_id":"fc_trunc","output_index":0,"delta":"{\"comm"}"#),
                // Truncated arguments surface in the terminal Response
                // object exactly as a buffered body would carry them.
                (event: "response.incomplete",
                 data: #"{"type":"response.incomplete","response":{"id":"resp_stream_2","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"function_call","id":"fc_trunc","call_id":"call_9","name":"run_command","arguments":"{\"comm"}]}}"#),
            ])
        }
        var sawTerminal = false
        do {
            let events = try await collect(stream(makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory)))
            sawTerminal = events.contains { if case .completed = $0 { return true } else { return false } }
            Issue.record("expected truncated tool input to fail closed")
        } catch let error as LLMError {
            #expect(sawTerminal == false)
            guard case .providerError(let message) = error else {
                Issue.record("expected typed providerError, got \(error)")
                return
            }
            // Payload-free projection identical to stream failures.
            #expect(message == "Responses API stream error")
            #expect(!message.contains("comm"))
            #expect(error.errorDescription?.contains("run_command") == false)
        }
    }

    @Test("terminal text that diverges from streamed deltas fails closed")
    func streamedTerminalParityIsEnforced() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        W5048ResponsesMockURLProtocol.handler = {
            responsesSSE([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_stream_3","status":"in_progress"}}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","item_id":"msg_3","output_index":0,"content_index":0,"delta":"Hel"}"#),
                // Terminal claims different text than what was streamed —
                // seam contract 1 violation must not be papered over.
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_stream_3","status":"completed","output":[{"type":"message","id":"msg_3","content":[{"type":"output_text","text":"Hello there"}]}]}}"#),
            ])
        }
        do {
            _ = try await collect(stream(makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory)))
            Issue.record("expected text-parity divergence to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected typed providerError, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
            #expect(!message.contains("Hello there"))
        }
    }

    @Test("stream EOF without a terminal event throws, never synthesizes .completed")
    func prematureEndHasNoSilentTerminal() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        W5048ResponsesMockURLProtocol.handler = {
            responsesSSE([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_stream_4","status":"in_progress"}}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","item_id":"msg_4","output_index":0,"content_index":0,"delta":"partial"}"#),
            ])
        }
        do {
            _ = try await collect(stream(makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory)))
            Issue.record("expected premature stream end to throw")
        } catch let error as ResponsesAPIError {
            guard case .prematureStreamEnd = error else {
                Issue.record("expected prematureStreamEnd, got \(error)")
                return
            }
        }
    }

    @Test("acquisition HTTP status keeps the typed payload-free projection")
    func acquisitionFailureKeepsTypedProjection() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        W5048ResponsesMockURLProtocol.handler = {
            (429, Data(#"{"error":{"message":"fixture-rate-secret"}}"#.utf8), ["Content-Type": "application/json"])
        }
        do {
            _ = try await stream(makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory))
            Issue.record("expected acquisition httpStatus failure")
        } catch let error as LLMError {
            guard case .httpStatus(let code, let detail) = error else {
                Issue.record("expected LLMError.httpStatus, got \(error)")
                return
            }
            #expect(code == 429)
            #expect(!detail.contains("fixture-rate-secret"))
            #expect(!detail.contains("fixture-responses-secret"))
            // 037 typed-kind consumption unchanged on the migrated path.
            #expect(ProviderRequestFailureKind.classify(error) == .rateLimited)
        }
    }

    // R3-02：流式请求的非 2xx 要读一段有上限的正文交给识别器（超窗、余额不足），
    // 任何账号类型都一样；正文原文不进错误对象。
    @Test("acquisition 400 with an overflow body maps to contextLengthExceeded without leaking text")
    func acquisitionOverflowBodyMapsToContextLength() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        W5048ResponsesMockURLProtocol.handler = {
            (400, Data(#"{"error":{"message":"fixture-overflow-secret","type":"invalid_request_error","code":"context_length_exceeded"}}"#.utf8),
             ["Content-Type": "application/json"])
        }
        do {
            _ = try await stream(makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory))
            Issue.record("expected acquisition overflow failure")
        } catch let error as LLMError {
            guard case .contextLengthExceeded = error else {
                Issue.record("expected contextLengthExceeded, got \(error)")
                return
            }
            #expect(!String(describing: error).contains("fixture-overflow-secret"))
        }
    }

    @Test("acquisition 429 with an insufficient_quota body maps to the balance-insufficient error")
    func acquisitionInsufficientQuotaBodyMapsToQuotaExhausted() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        W5048ResponsesMockURLProtocol.handler = {
            (429, Data(#"{"error":{"message":"fixture-quota-secret","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8),
             ["Content-Type": "application/json"])
        }
        do {
            _ = try await stream(makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory))
            Issue.record("expected acquisition quota failure")
        } catch let error as LLMError {
            #expect(error.isQuotaExhausted)
            #expect(!String(describing: error).contains("fixture-quota-secret"))
            #expect(!error.userMessageZH.contains("fixture-quota-secret"))
        }
    }

    @Test("in-stream failure events map known error codes and keep other codes payload-free")
    func inStreamFailureEventsMapErrorCodes() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        let created = (event: "response.created",
                       data: #"{"type":"response.created","response":{"id":"resp_fail_1","status":"in_progress"}}"#)
        func failed(_ code: String) -> (event: String, data: String) {
            (event: "response.failed",
             data: #"{"type":"response.failed","response":{"id":"resp_fail_1","status":"failed","error":{"code":""# + code + #"","message":"fixture-stream-secret"}}}"#)
        }
        func errorEvent(_ code: String) -> (event: String, data: String) {
            (event: "error", data: #"{"type":"error","code":""# + code + #"","message":"fixture-stream-secret"}"#)
        }
        let cases: [(event: String, data: String)] = [
            failed("context_length_exceeded"), failed("insufficient_quota"), failed("server_error"),
            errorEvent("context_length_exceeded"), errorEvent("insufficient_quota"), errorEvent("server_error"),
        ]
        var results: [LLMError] = []
        for terminal in cases {
            W5048ResponsesMockURLProtocol.handler = { responsesSSE([created, terminal]) }
            do {
                _ = try await collect(stream(makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory)))
                Issue.record("expected \(terminal.event) to throw")
            } catch let error as LLMError {
                results.append(error)
            }
        }
        #expect(results.count == cases.count)
        guard results.count == cases.count else { return }
        for index in [0, 3] {
            if case .contextLengthExceeded = results[index] {} else {
                Issue.record("case \(index): expected contextLengthExceeded, got \(results[index])")
            }
        }
        #expect(results[1].isQuotaExhausted)
        #expect(results[4].isQuotaExhausted)
        for index in [2, 5] {
            guard case .providerError(let message) = results[index] else {
                Issue.record("case \(index): expected providerError, got \(results[index])")
                continue
            }
            #expect(!message.contains("fixture-stream-secret"))
        }
        for error in results {
            #expect(!String(describing: error).contains("fixture-stream-secret"))
        }
    }

    @Test("text-only stream maps response.failed and error event codes the same way")
    func textOnlyStreamMapsFailureCodes() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        let created = (event: "response.created",
                       data: #"{"type":"response.created","response":{"id":"resp_fail_2","status":"in_progress"}}"#)
        let failedOverflow = (event: "response.failed",
                              data: #"{"type":"response.failed","response":{"id":"resp_fail_2","status":"failed","error":{"code":"context_length_exceeded","message":"fixture-text-secret"}}}"#)
        let errorQuota = (event: "error",
                          data: #"{"type":"error","code":"insufficient_quota","message":"fixture-text-secret"}"#)
        var results: [LLMError] = []
        for terminal in [failedOverflow, errorQuota] {
            W5048ResponsesMockURLProtocol.handler = { responsesSSE([created, terminal]) }
            let provider = makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory)
            do {
                let chunks = try await provider.streamMessage(
                    messages: [LLMMessage(role: .user, content: "hi")],
                    systemPrompt: nil,
                    maxTokens: 64,
                    temperature: nil
                )
                for try await _ in chunks {}
                Issue.record("expected \(terminal.event) to throw")
            } catch let error as LLMError {
                results.append(error)
            }
        }
        #expect(results.count == 2)
        guard results.count == 2 else { return }
        if case .contextLengthExceeded = results[0] {} else {
            Issue.record("expected contextLengthExceeded, got \(results[0])")
        }
        #expect(results[1].isQuotaExhausted)
        for error in results {
            #expect(!String(describing: error).contains("fixture-text-secret"))
        }
    }

    @Test("tools-aware streaming request carries tools, stream flag and input items")
    func requestCarriesToolsAndStreamFlag() async throws {
        defer { W5048ResponsesMockURLProtocol.reset() }
        let isolation = try isolateCheckpointDirectory()
        defer { restore(isolation) }
        W5048ResponsesMockURLProtocol.handler = {
            responsesSSE([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_stream_6","status":"in_progress"}}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","item_id":"msg_6","output_index":0,"content_index":0,"delta":"ok"}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_stream_6","status":"completed","output":[{"type":"message","id":"msg_6","content":[{"type":"output_text","text":"ok"}]}]}}"#),
            ])
        }
        _ = try await collect(stream(makeProvider(session: W5048ResponsesMockURLProtocol.makeSession(), checkpointDirectory: isolation.directory)))
        let bodyData = try #require(W5048ResponsesMockURLProtocol.lastRequestBody)
        let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
        #expect((json["tools"] as? [[String: Any]])?.count == 1)
        #expect(json["input"] is [Any])
        #expect(json["max_output_tokens"] as? Int == 64)
    }
}
