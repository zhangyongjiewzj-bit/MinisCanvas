import Foundation
import Testing
@testable import MinisCore

// W5-PROVIDER-WIRE-SSE-044: real wire-SSE forwarding for the tools-aware
// assistant streaming seam opened by W4-PROVIDER-ERROR-CLASS-037.
//
// Pins the migration contract for the two wire-provider fleets:
// - incremental `.textDelta` events are forwarded live (NOT a single
//   synthesized terminal — the 037 route-level placeholder gap),
// - the terminal `.completed` response equals what the buffered path would
//   return for the same reply (same admission functions, same boundaries),
// - native tool-call payloads/reasoning never leak into text deltas,
// - acquisition failures keep the provider's payload-free typed projection
//   consumed by 037's `ProviderRequestFailureKind.classify`.
//
// Fully offline: each suite owns an isolated URLProtocol stub (repo pattern:
// per-suite static state to survive swift-testing parallel scheduling).

private final class W5044FailureHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [LLMMessage] = []
    func record(_ value: [LLMMessage]) { lock.withLock { messages = value } }
    var snapshot: [LLMMessage] { lock.withLock { messages } }
}

private func reportsOneDiscardedToolCall(_ notice: String) -> Bool {
    let count = #"(?i)\b(?:1|one)\s+(?:(?:discarded|omitted|incomplete)\s+tool calls?|tool calls?\s+(?:discarded|omitted|not executed))\b|\b(?:discarded|omitted)\s+(?:1|one)\s+tool calls?\b|(?:丢弃|省略|未完成)(?:的)?\s*[：:]?\s*(?:1|一)\s*(?:个|次)?\s*工具调用|(?<![0-9])(?:1|一)\s*(?:个|次)?\s*(?:(?:未完成的|被丢弃的|被省略的)工具调用|工具调用\s*(?:被丢弃|被省略|未执行))"#
    return notice.range(of: count, options: .regularExpression) != nil
}

// MARK: - Shared SSE body scripting

private func sseBody(_ payloads: [String]) -> Data {
    payloads.map { "data: \($0)\n\n" }.joined().data(using: .utf8)!
}

private func collectAssistantEvents(
    _ stream: AsyncThrowingStream<LLMAssistantStreamEvent, Error>
) async throws -> [LLMAssistantStreamEvent] {
    var events: [LLMAssistantStreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

// MARK: - Anthropic

/// Anthropic-suite-owned mock (independent static state, serialized suite).
private final class W5044AnthropicMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var handler: (() throws -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
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

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [W5044AnthropicMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() { handler = nil; lastRequest = nil }
}

@Suite("W5044 Anthropic assistant wire-SSE stream", .serialized)
struct W5044AnthropicAssistantStreamTests {
    @Test("buffered truncated tool diagnostics only name offered tools", arguments: ["file_write", "unadvertised_remote_tool"])
    func bufferedTruncationReportsOnlyTheOfferedToolName(toolName: String) async throws {
        defer { W5044AnthropicMockURLProtocol.reset() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("b32-anthropic-buffered-tool-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("target.txt")
        try "original file".write(to: file, atomically: true, encoding: .utf8)
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: [
            "path": file.path, "content": "B32_BUFFERED_ARGUMENT_MARKER"
        ]), as: UTF8.self)
        W5044AnthropicMockURLProtocol.handler = {
            // The transport JSON is complete; tool input is deliberately a
            // truncated JSON string rather than an admitted input object.
            let body: [String: Any] = ["content": [
                ["type": "text", "text": "Partial buffered reply"],
                ["type": "tool_use", "id": "call_buffered_truncated", "name": toolName,
                 "input": String(arguments.dropLast())]
            ], "stop_reason": "max_tokens"]
            return (200, try JSONSerialization.data(withJSONObject: body), ["Content-Type": "application/json"])
        }
        let executor = RecordingToolExecutor()
        // No display callback or frozen thinking level: AgentLoop.sendProvider
        // must call the real buffered sendMessage(tools:) path.
        let loop = AgentLoop(maxIterations: 1, approvalGate: ApprovalGate(policyByTool: ["file_write": .autoApprove]))
        let history = W5044FailureHistory()
        var observedError: Error?
        do {
            _ = try await loop.run(messages: [.init(role: .user, content: "Write a long file")],
                systemPrompt: nil, provider: Self.provider(session: W5044AnthropicMockURLProtocol.makeSession()),
                toolExecutor: executor, tools: AgentToolCatalog.makeTools().filter { $0.name == "file_write" },
                onFailure: { history.record($0) })
        } catch { observedError = error }
        let request = try #require(W5044AnthropicMockURLProtocol.lastRequest)
        let bodyData: Data
        if let data = request.httpBody { bodyData = data }
        else {
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
            bodyData = data
        }
        let requestJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        try #require(requestJSON["stream"] as? Bool != true, "This fixture must exercise buffered production dispatch")
        let advertised = try #require(requestJSON["tools"] as? [[String: Any]])
        try #require(advertised.compactMap { $0["name"] as? String } == ["file_write"])
        #expect(observedError != nil)
        let notice = observedError?.localizedDescription ?? ""
        let messages = history.snapshot
        #expect(messages.last(where: { $0.role == .assistant })?.content == "Partial buffered reply")
        #expect(messages.allSatisfy { $0.role != .tool && $0.toolCalls.isEmpty })
        #expect(notice.contains("截断") || notice.lowercased().contains("truncat"))
        #expect(reportsOneDiscardedToolCall(notice))
        #expect(notice.contains("file_write") == (toolName == "file_write"))
        #expect(!notice.contains("unadvertised_remote_tool"))
        for marker in ["B32_SYNTHETIC_ARGUMENT_MARKER", "B32_BUFFERED_ARGUMENT_MARKER", file.path] {
            #expect(!notice.contains(marker))
            #expect(messages.allSatisfy { !$0.content.contains(marker) })
        }
        #expect(executor.executedNames.isEmpty)
        #expect(try Data(contentsOf: file) == Data("original file".utf8))
    }

    @Test("truncated tool diagnostics only name offered tools and never disclose arguments", arguments: ["file_write", "unadvertised_remote_tool"])
    func maxTokensTruncationReportsOnlyTheOfferedToolName(toolName: String) async throws {
        defer { W5044AnthropicMockURLProtocol.reset() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b32-anthropic-tool-diagnostic-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("target.txt")
        try "original file".write(to: file, atomically: true, encoding: .utf8)
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: [
            "path": file.path, "content": "B32_SYNTHETIC_ARGUMENT_MARKER"
        ]), as: UTF8.self)
        let partialArguments = String(arguments.dropLast())
        W5044AnthropicMockURLProtocol.handler = {
            let frames: [[String: Any]] = [
                ["type": "message_start", "message": ["usage": ["input_tokens": 10, "output_tokens": 0]]],
                ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": "Partial file reply"]],
                ["type": "content_block_stop", "index": 0],
                ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "call_truncated_file", "name": toolName]],
                ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": partialArguments]],
                ["type": "message_delta", "delta": ["stop_reason": "max_tokens"], "usage": ["output_tokens": 20]],
                ["type": "message_stop"]
            ]
            return (200, sseBody(try frames.map {
                String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
            }), ["Content-Type": "text/event-stream"])
        }
        let executor = RecordingToolExecutor()
        var loop = AgentLoop(maxIterations: 1, approvalGate: ApprovalGate(policyByTool: ["file_write": .autoApprove]))
        loop.onAssistantTextDelta = { _, delta in
            #expect(!delta.contains("B32_SYNTHETIC_ARGUMENT_MARKER"))
            #expect(!delta.contains(file.path))
        }
        let history = W5044FailureHistory()
        var observedError: Error?
        do {
            _ = try await loop.run(messages: [.init(role: .user, content: "Write a long file")],
                systemPrompt: nil, provider: Self.provider(session: W5044AnthropicMockURLProtocol.makeSession()),
                toolExecutor: executor, tools: AgentToolCatalog.makeTools().filter { $0.name == "file_write" },
                onFailure: { history.record($0) })
        } catch { observedError = error }
        let request = try #require(W5044AnthropicMockURLProtocol.lastRequest)
        let bodyData: Data
        if let data = request.httpBody { bodyData = data }
        else {
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
            bodyData = data
        }
        let requestJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        try #require(requestJSON["stream"] as? Bool == true, "This fixture must exercise streamed production dispatch")
        let advertised = try #require(requestJSON["tools"] as? [[String: Any]])
        try #require(advertised.compactMap { $0["name"] as? String } == ["file_write"])
        #expect(observedError != nil)
        let notice = observedError?.localizedDescription ?? ""
        let messages = history.snapshot
        #expect(messages.last(where: { $0.role == .assistant })?.content == "Partial file reply")
        #expect(messages.allSatisfy { $0.role != .tool && $0.toolCalls.isEmpty })
        #expect(notice.contains("截断") || notice.lowercased().contains("truncat"))
        #expect(reportsOneDiscardedToolCall(notice))
        #expect(notice.contains("file_write") == (toolName == "file_write"))
        #expect(!notice.contains("unadvertised_remote_tool"))
        for marker in ["B32_SYNTHETIC_ARGUMENT_MARKER", "B32_BUFFERED_ARGUMENT_MARKER", file.path] {
            #expect(!notice.contains(marker))
            #expect(messages.allSatisfy { !$0.content.contains(marker) })
        }
        #expect(executor.executedNames.isEmpty)
        #expect(try Data(contentsOf: file) == Data("original file".utf8))
    }

    private static func provider(session: URLSession) -> AnthropicProvider {
        AnthropicProvider(apiKey: "fixture-anthropic-secret", session: session)
    }

    private static func stream(_ provider: AnthropicProvider) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await provider.streamAssistantMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            tools: [AgentToolDefinition(
                name: "run_command",
                description: "fixture",
                parameters: ["command": AgentToolParam(type: .string, description: "command")],
                required: ["command"]
            )],
            maxTokens: 64,
            temperature: nil
        )
    }

    @Test("text and tool_use events forward incrementally with a buffered-identical terminal")
    func incrementalForwardingAndTerminalParity() async throws {
        defer { W5044AnthropicMockURLProtocol.reset() }
        W5044AnthropicMockURLProtocol.handler = {
            (200, sseBody([
                #"{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":4,"output_tokens":0}}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_fixture_1","name":"run_command"}}"#,
                #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"comm"}}"#,
                #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"and\":\"ls\"}"}}"#,
                #"{"type":"content_block_stop","index":1}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}"#,
                #"{"type":"message_stop"}"#,
            ]), ["Content-Type": "text/event-stream"])
        }
        let events = try await Self.collect(try await Self.stream(Self.provider(session: W5044AnthropicMockURLProtocol.makeSession())))

        var deltas: [String] = []
        var terminal: LLMResponse?
        for event in events {
            switch event {
            case .textDelta(let text): deltas.append(text)
            case .completed(let response): terminal = response
            }
        }
        // Real incremental forwarding, not a synthesized single terminal.
        #expect(deltas == ["Hel", "lo"])
        guard let terminal else {
            Issue.record("assistant stream must end with a .completed event")
            return
        }
        // Terminal parity: text equals the delta concatenation; the tool call
        // is admitted through the shared buffered boundary; usage merges
        // message_start input/cache fields with message_delta output.
        #expect(terminal.text == "Hello")
        #expect(terminal.stopReason == "tool_use")
        #expect(terminal.usage?.inputTokens == 10)
        #expect(terminal.usage?.outputTokens == 5)
        #expect(terminal.usage?.cacheReadInputTokens == 4)
        #expect(terminal.toolCalls.count == 1)
        #expect(terminal.toolCalls.first?.id == "toolu_fixture_1")
        #expect(terminal.toolCalls.first?.name == "run_command")
        #expect(terminal.toolCalls.first?.rawArguments == "{\"command\":\"ls\"}")
        #expect(terminal.toolCalls.first?.arguments["command"] as? String == "ls")
        // Contract 2: tool argument fragments never ride text deltas.
        #expect(deltas.allSatisfy { !$0.contains("comm") && !$0.contains("partial_json") })
    }

    @Test("incomplete tool input at message_stop fails closed without synthesis")
    func incompleteToolInputFailsClosed() async throws {
        defer { W5044AnthropicMockURLProtocol.reset() }
        W5044AnthropicMockURLProtocol.handler = {
            (200, sseBody([
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_truncated","name":"run_command"}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"comm"}}"#,
                #"{"type":"message_stop"}"#,
            ]), ["Content-Type": "text/event-stream"])
        }
        let events = try await Self.collect(try await Self.stream(Self.provider(session: W5044AnthropicMockURLProtocol.makeSession())))
        guard case .completed(let terminal)? = events.last else {
            Issue.record("expected terminal .completed event")
            return
        }
        // Fail closed: a call whose streamed arguments never completed is
        // dropped by the shared boundary, never admitted with empty input.
        #expect(terminal.toolCalls.isEmpty)
        #expect(terminal.text.isEmpty)
    }

    @Test("mid-stream error event throws payload-free projection and no terminal")
    func midStreamErrorIsPayloadFree() async throws {
        defer { W5044AnthropicMockURLProtocol.reset() }
        W5044AnthropicMockURLProtocol.handler = {
            (200, sseBody([
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#,
                #"{"type":"error","error":{"type":"overloaded_error","message":"fixture-upstream-secret text"}}"#,
            ]), ["Content-Type": "text/event-stream"])
        }
        do {
            _ = try await Self.collect(try await Self.stream(Self.provider(session: W5044AnthropicMockURLProtocol.makeSession())))
            Issue.record("expected mid-stream provider error")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected LLMError.providerError, got \(error)")
                return
            }
            #expect(message.contains("category=server_overloaded"))
            #expect(!message.contains("fixture-upstream-secret"))
            #expect(message.contains("fixture-anthropic-secret") == false)
        }
    }

    @Test("acquisition HTTP status keeps the typed payload-free projection")
    func acquisitionFailureKeepsTypedProjection() async throws {
        defer { W5044AnthropicMockURLProtocol.reset() }
        W5044AnthropicMockURLProtocol.handler = {
            (429, Data(#"{"type":"error","error":{"message":"fixture-rate-secret"}}"#.utf8), ["Content-Type": "application/json"])
        }
        do {
            _ = try await Self.stream(Self.provider(session: W5044AnthropicMockURLProtocol.makeSession()))
            Issue.record("expected acquisition httpStatus failure")
        } catch let error as LLMError {
            guard case .httpStatus(let code, let detail) = error else {
                Issue.record("expected LLMError.httpStatus, got \(error)")
                return
            }
            #expect(code == 429)
            #expect(!detail.contains("fixture-rate-secret"))
            // 037 typed-kind consumption unchanged on the migrated path.
            #expect(ProviderRequestFailureKind.classify(error) == .rateLimited)
        }
    }

    private static func collect(
        _ stream: AsyncThrowingStream<LLMAssistantStreamEvent, Error>
    ) async throws -> [LLMAssistantStreamEvent] {
        try await collectAssistantEvents(stream)
    }
}

// MARK: - OpenAI-compatible

/// OpenAI-compatible-suite-owned mock (independent static state).
private final class W5044ChatMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (() throws -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
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

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [W5044ChatMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        handler = nil
        lastRequest = nil
    }
}

@Suite("W5044 OpenAI-compatible assistant wire-SSE stream", .serialized)
struct W5044OpenAICompatibleAssistantStreamTests {
    @Test("buffered truncated tool diagnostics only name offered tools", arguments: ["file_write", "unadvertised_remote_tool"])
    func bufferedTruncationReportsOnlyTheOfferedToolName(toolName: String) async throws {
        defer { W5044ChatMockURLProtocol.reset() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("b32-buffered-tool-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("target.txt")
        try "original file".write(to: file, atomically: true, encoding: .utf8)
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: [
            "path": file.path, "content": "B32_BUFFERED_ARGUMENT_MARKER"
        ]), as: UTF8.self)
        W5044ChatMockURLProtocol.handler = {
            let body: [String: Any] = ["choices": [["index": 0, "message": [
                "role": "assistant", "content": "Partial buffered reply", "tool_calls": [[
                    "id": "call_buffered_truncated", "type": "function",
                    "function": ["name": toolName, "arguments": String(arguments.dropLast())]
                ]]
            ], "finish_reason": "length"]]]
            return (200, try JSONSerialization.data(withJSONObject: body), ["Content-Type": "application/json"])
        }
        let executor = RecordingToolExecutor()
        // No display callback or frozen thinking level: AgentLoop.sendProvider
        // must call the real buffered sendMessage(tools:) path.
        let loop = AgentLoop(maxIterations: 1, approvalGate: ApprovalGate(policyByTool: ["file_write": .autoApprove]))
        let history = W5044FailureHistory()
        var observedError: Error?
        do {
            _ = try await loop.run(messages: [.init(role: .user, content: "Write a long file")],
                systemPrompt: nil, provider: Self.provider(session: W5044ChatMockURLProtocol.makeSession()),
                toolExecutor: executor, tools: AgentToolCatalog.makeTools().filter { $0.name == "file_write" },
                onFailure: { history.record($0) })
        } catch { observedError = error }
        let request = try #require(W5044ChatMockURLProtocol.lastRequest)
        let bodyData: Data
        if let data = request.httpBody { bodyData = data }
        else {
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
            bodyData = data
        }
        let requestJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        try #require(requestJSON["stream"] as? Bool != true, "This fixture must exercise buffered production dispatch")
        let advertised = try #require(requestJSON["tools"] as? [[String: Any]])
        try #require(advertised.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } == ["file_write"])
        #expect(observedError != nil)
        let notice = observedError?.localizedDescription ?? ""
        let messages = history.snapshot
        #expect(messages.last(where: { $0.role == .assistant })?.content == "Partial buffered reply")
        #expect(messages.allSatisfy { $0.role != .tool && $0.toolCalls.isEmpty })
        #expect(notice.contains("截断") || notice.lowercased().contains("truncat"))
        #expect(reportsOneDiscardedToolCall(notice))
        #expect(notice.contains("file_write") == (toolName == "file_write"))
        #expect(!notice.contains("unadvertised_remote_tool"))
        for marker in ["B32_SYNTHETIC_ARGUMENT_MARKER", "B32_BUFFERED_ARGUMENT_MARKER", file.path] {
            #expect(!notice.contains(marker))
            #expect(messages.allSatisfy { !$0.content.contains(marker) })
        }
        #expect(executor.executedNames.isEmpty)
        #expect(try Data(contentsOf: file) == Data("original file".utf8))
    }

    @Test func mixedTruncationExecutesOnlyAdmittedCallAndSendsOneSafeContinuationNotice() async throws {
        defer { W5044ChatMockURLProtocol.reset() }
        let partialText = "Partial mixed reply"
        let systemPrompt = "Original system prompt"
        let discardedMarker = "B32_MIXED_DISCARDED_ARGUMENT_MARKER"
        let unknownName = "unadvertised_mixed_remote_tool"
        let unknownMarker = "B32_MIXED_UNKNOWN_ARGUMENT_MARKER"
        var requestCount = 0
        W5044ChatMockURLProtocol.handler = {
            requestCount += 1
            let message: [String: Any]
            let finishReason: String
            switch requestCount {
            case 1:
                message = ["role": "assistant", "content": partialText, "tool_calls": [
                    ["id": "call_admitted", "type": "function",
                     "function": ["name": "file_read", "arguments": #"{"path":"synthetic.txt"}"#]],
                    ["id": "call_discarded", "type": "function",
                     "function": ["name": "file_write", "arguments": "{\"content\":\"" + discardedMarker]],
                    ["id": "call_unknown_discarded", "type": "function",
                     "function": ["name": unknownName, "arguments": "{\"content\":\"" + unknownMarker]]
                ]]
                finishReason = "length"
            case 2:
                message = ["role": "assistant", "content": "Continuation complete"]
                finishReason = "stop"
            default:
                throw URLError(.badServerResponse)
            }
            let body: [String: Any] = ["choices": [["index": 0, "message": message, "finish_reason": finishReason]]]
            return (200, try JSONSerialization.data(withJSONObject: body), ["Content-Type": "application/json"])
        }

        let root = try minisCoreToolContractRoot("b32-mixed-continuation")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("b32-mixed-continuation")
        let executor = RecordingToolExecutor()
        let loop = AgentLoop(
            maxIterations: 2,
            approvalGate: ApprovalGate(
                policyByTool: ["file_read": .autoApprove, "file_write": .autoApprove],
                delegate: MockApprovalDelegate(decisions: [.approve])),
            turnController: TurnController(),
            timeout: 30,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        _ = try await loop.run(messages: [.init(role: .user, content: "Read and write")],
            systemPrompt: systemPrompt, provider: Self.provider(session: W5044ChatMockURLProtocol.makeSession()),
            toolExecutor: executor, tools: AgentToolCatalog.makeTools().filter {
                $0.name == "file_read" || $0.name == "file_write"
            },
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID,
                taskID: "task:b32-mixed-continuation",
                actorID: "test"
            ),
            executionIdentity: identity
        )
        try #require(requestCount == 2)
        #expect(executor.executedNames == ["file_read"])

        let request = try #require(W5044ChatMockURLProtocol.lastRequest)
        let bodyData: Data
        if let data = request.httpBody { bodyData = data }
        else {
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            bodyData = data
        }
        let requestJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        try #require(requestJSON["stream"] as? Bool != true)
        let advertised = try #require(requestJSON["tools"] as? [[String: Any]])
        #expect(Set(advertised.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            == Set(["file_read", "file_write"]))
        let messages = try #require(requestJSON["messages"] as? [[String: Any]])
        let assistants = messages.filter { $0["role"] as? String == "assistant" }
        try #require(assistants.count == 1)
        #expect(assistants[0]["content"] as? String == partialText)
        let calls = try #require(assistants[0]["tool_calls"] as? [[String: Any]])
        #expect(calls.compactMap { $0["id"] as? String } == ["call_admitted"])
        let receipts = messages.filter { $0["role"] as? String == "tool" }
        try #require(receipts.count == 1)
        #expect(receipts[0]["tool_call_id"] as? String == "call_admitted")
        #expect(receipts[0]["content"] as? String == "executed file_read")
        let systemMessages = messages.filter { $0["role"] as? String == "system" }
        try #require(systemMessages.count == 1)
        let systemText = try #require(systemMessages[0]["content"] as? String)
        let paragraphs = systemText.components(separatedBy: "\n\n")
        try #require(paragraphs.count == 2)
        #expect(paragraphs[0] == systemPrompt)
        let truncationMarkers = ["模型输出截断，", "The model output was truncated."]
        let noticeCount = truncationMarkers.reduce(0) { count, marker in
            count + paragraphs[1].components(separatedBy: marker).count - 1
        }
        #expect(noticeCount == 1)
        let notice = paragraphs[1]
        #expect((notice.contains("丢弃 2 个工具调用。") && notice.contains("未知工具 1 个。"))
            || (notice.contains("Discarded 2 tool calls.") && notice.contains("Unknown tool calls: 1.")))
        #expect(paragraphs[1].components(separatedBy: "file_write").count == 2)
        #expect(!paragraphs[1].contains("file_read"))
        let wire = String(decoding: bodyData, as: UTF8.self)
        #expect(!wire.contains(discardedMarker))
        #expect(!wire.contains("call_discarded"))
        #expect(!wire.contains("call_unknown_discarded"))
        #expect(!wire.contains(unknownMarker))
        #expect(!wire.contains(unknownName))
    }

    @Test("truncated tool diagnostics only name offered tools and never disclose arguments", arguments: ["file_write", "unadvertised_remote_tool"])
    func truncatedToolInputReportsOnlyTheOfferedToolName(toolName: String) async throws {
        defer { W5044ChatMockURLProtocol.reset() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b32-tool-diagnostic-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("target.txt")
        try "original file".write(to: file, atomically: true, encoding: .utf8)
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: [
            "path": file.path, "content": "B32_SYNTHETIC_ARGUMENT_MARKER"
        ]), as: UTF8.self)
        let partialArguments = String(arguments.dropLast())
        W5044ChatMockURLProtocol.handler = {
            let frame: [String: Any] = ["choices": [["index": 0, "delta": [
                "content": "Partial file reply", "tool_calls": [["index": 0, "id": "call_truncated_file",
                    "type": "function", "function": ["name": toolName, "arguments": partialArguments]]]
            ], "finish_reason": "length"]]]
            return (200, sseBody([String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self), "[DONE]"]),
                    ["Content-Type": "text/event-stream"])
        }
        let executor = RecordingToolExecutor()
        var loop = AgentLoop(maxIterations: 1, approvalGate: ApprovalGate(policyByTool: ["file_write": .autoApprove]))
        loop.onAssistantTextDelta = { _, delta in
            #expect(!delta.contains("B32_SYNTHETIC_ARGUMENT_MARKER"))
            #expect(!delta.contains(file.path))
        }
        let history = W5044FailureHistory()
        var observedError: Error?
        do {
            _ = try await loop.run(messages: [.init(role: .user, content: "Write a long file")],
                systemPrompt: nil, provider: Self.provider(session: W5044ChatMockURLProtocol.makeSession()),
                toolExecutor: executor, tools: AgentToolCatalog.makeTools().filter { $0.name == "file_write" },
                onFailure: { history.record($0) })
        } catch { observedError = error }
        let request = try #require(W5044ChatMockURLProtocol.lastRequest)
        let bodyData: Data
        if let data = request.httpBody { bodyData = data }
        else {
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
            bodyData = data
        }
        let requestJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        try #require(requestJSON["stream"] as? Bool == true, "This fixture must exercise streamed production dispatch")
        let advertised = try #require(requestJSON["tools"] as? [[String: Any]])
        try #require(advertised.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } == ["file_write"])
        #expect(observedError != nil)
        let notice = observedError?.localizedDescription ?? ""
        let messages = history.snapshot
        #expect(messages.last(where: { $0.role == .assistant })?.content == "Partial file reply")
        #expect(messages.allSatisfy { $0.role != .tool && $0.toolCalls.isEmpty })
        #expect(notice.contains("截断") || notice.lowercased().contains("truncat"))
        #expect(reportsOneDiscardedToolCall(notice))
        #expect(notice.contains("file_write") == (toolName == "file_write"))
        #expect(!notice.contains("unadvertised_remote_tool"))
        for marker in ["B32_SYNTHETIC_ARGUMENT_MARKER", "B32_BUFFERED_ARGUMENT_MARKER", file.path] {
            #expect(!notice.contains(marker))
            #expect(messages.allSatisfy { !$0.content.contains(marker) })
        }
        #expect(executor.executedNames.isEmpty)
        #expect(try Data(contentsOf: file) == Data("original file".utf8))
    }

    private static func provider(session: URLSession) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(apiKey: "fixture-chat-secret", session: session)
    }

    private static func stream(_ provider: OpenAICompatibleProvider) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await provider.streamAssistantMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            tools: [AgentToolDefinition(
                name: "run_command",
                description: "fixture",
                parameters: ["command": AgentToolParam(type: .string, description: "command")],
                required: ["command"]
            )],
            maxTokens: 64,
            temperature: nil
        )
    }

    @Test("content and tool_call fragments forward incrementally with a buffered-identical terminal")
    func incrementalForwardingAndTerminalParity() async throws {
        defer { W5044ChatMockURLProtocol.reset() }
        W5044ChatMockURLProtocol.handler = {
            (200, sseBody([
                #"{"choices":[{"index":0,"delta":{"role":"assistant","content":"Wea"}}]}"#,
                #"{"choices":[{"index":0,"delta":{"content":"ther"}}]}"#,
                #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_fixture_1","type":"function","function":{"name":"run_command","arguments":""}}]}}]}"#,
                #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"com"}}]}}]}"#,
                #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"mand\":\"pwd\"}"}}]},"finish_reason":"tool_calls"}]}"#,
                // include_usage servers deliver the usage-only frame AFTER the
                // finish frame; the migrated path must still capture it.
                #"{"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3}}"#,
                #"[DONE]"#,
            ]), ["Content-Type": "text/event-stream"])
        }
        let events = try await Self.collect(try await Self.stream(Self.provider(session: W5044ChatMockURLProtocol.makeSession())))

        var deltas: [String] = []
        var terminal: LLMResponse?
        for e in events {
            switch e {
            case .textDelta(let text): deltas.append(text)
            case .completed(let response): terminal = response
            }
        }
        #expect(deltas == ["Wea", "ther"])
        guard let terminal else {
            Issue.record("assistant stream must end with a .completed event")
            return
        }
        // Terminal parity with the buffered parser: same text, native call
        // admitted via the shared boundary, streamed usage and finish reason.
        #expect(terminal.text == "Weather")
        #expect(terminal.stopReason == "tool_calls")
        #expect(terminal.usage?.inputTokens == 7)
        #expect(terminal.usage?.outputTokens == 3)
        #expect(terminal.toolCalls.count == 1)
        #expect(terminal.toolCalls.first?.id == "call_fixture_1")
        #expect(terminal.toolCalls.first?.name == "run_command")
        #expect(terminal.toolCalls.first?.rawArguments == "{\"command\":\"pwd\"}")
        #expect(terminal.toolCalls.first?.arguments["command"] as? String == "pwd")
        #expect(deltas.allSatisfy { !$0.contains("com") && !$0.contains("arguments") })
    }

    @Test("tools-aware streaming request carries tools and stream flags")
    func requestCarriesToolsAndStreamFlag() async throws {
        defer { W5044ChatMockURLProtocol.reset() }
        W5044ChatMockURLProtocol.handler = {
            (200, sseBody([#"{"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#, #"[DONE]"#]), ["Content-Type": "text/event-stream"])
        }
        _ = try await Self.collect(try await Self.stream(Self.provider(session: W5044ChatMockURLProtocol.makeSession())))
        guard let request = W5044ChatMockURLProtocol.lastRequest else {
            Issue.record("missing scripted request")
            return
        }
        let bodyData: Data
        if let body = request.httpBody {
            bodyData = body
        } else if let streamBody = request.httpBodyStream {
            streamBody.open()
            defer { streamBody.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while streamBody.hasBytesAvailable {
                let read = streamBody.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            bodyData = data
        } else {
            Issue.record("assistant stream request must carry a body")
            return
        }
        let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
        #expect((json["tools"] as? [[String: Any]])?.count == 1)
    }

    @Test("acquisition HTTP status keeps the typed payload-free projection")
    func acquisitionFailureKeepsTypedProjection() async throws {
        defer { W5044ChatMockURLProtocol.reset() }
        W5044ChatMockURLProtocol.handler = {
            (401, Data(#"{"error":{"message":"fixture-auth-secret"}}"#.utf8), ["Content-Type": "application/json"])
        }
        do {
            _ = try await Self.stream(Self.provider(session: W5044ChatMockURLProtocol.makeSession()))
            Issue.record("expected acquisition httpStatus failure")
        } catch let error as LLMError {
            guard case .httpStatus(let code, let detail) = error else {
                Issue.record("expected LLMError.httpStatus, got \(error)")
                return
            }
            #expect(code == 401)
            #expect(!detail.contains("fixture-auth-secret"))
            #expect(!detail.contains("fixture-chat-secret"))
            #expect(ProviderRequestFailureKind.classify(error) == .unauthorized)
        }
    }

    private static func collect(
        _ stream: AsyncThrowingStream<LLMAssistantStreamEvent, Error>
    ) async throws -> [LLMAssistantStreamEvent] {
        try await collectAssistantEvents(stream)
    }
}
