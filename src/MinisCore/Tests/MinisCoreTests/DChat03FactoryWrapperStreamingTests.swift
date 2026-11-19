import Foundation
import Network
import Testing
@testable import MinisCore

// Exercise the unmodified built-in factory, concrete wrappers and frozen
// runtime route over real URLSession.AsyncBytes. No builder replacement or
// process-global URLProtocol registration can mask the missing wrapper seam.
private final class WrapperLoopbackSSE: @unchecked Sendable {
    enum Mode: Equatable { case normal, httpFailure, waitForHeaders }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DChat03.wrapper.loopback")
    private let lock = NSLock()
    private var bodies: [Data] = []
    private var connection: NWConnection?
    private var received = Data()
    private var sendSequence = 0
    private let mode: Mode
    var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)" }

    init(mode: Mode = .normal) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.receiveRequest(connection)
            // Harness watchdog only: an unreachable producer/consumer must
            // terminate with an error instead of hanging the test runner.
            self.queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, listener.port != nil else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }

    }

    var requestBodies: [Data] { lock.withLock { bodies } }

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.received.append(data) }
            if let boundary = self.received.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: self.received[..<boundary.lowerBound], encoding: .utf8) {
                let length = headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = self.received[boundary.upperBound...]
                if body.count >= length {
                    let data = Data(body.prefix(length))
                    self.lock.withLock { self.bodies.append(data) }
                    self.respond(connection, body: data)
                    return
                }
            }
            if !complete && error == nil { self.receiveRequest(connection) }
        }
    }

    private func respond(_ connection: NWConnection, body: Data) {
        if mode == .waitForHeaders { return }
        if mode == .httpFailure {
            sendJSON(connection, status: "429 Too Many Requests", body: #"{"error":{"message":"fixture-private-body"}}"#)
            return
        }
        let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard request?["stream"] as? Bool == true else {
            // Baseline buffered route finishes promptly, yielding the actual
            // wrong completed-only event rather than a watchdog failure.
            sendJSON(connection, status: "200 OK", body: #"{"choices":[{"message":{"content":"AB"},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":2}}"#)
            return
        }
        let first = #"{"choices":[{"delta":{"content":"A","reasoning_content":"private-reasoning","tool_calls":[{"index":0,"id":"call_fixture","type":"function","function":{"name":"run_command","arguments":"{\"command\":"}}]}}]}"#
        send(connection, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + chunk("data: \(first)\n\n"))
    }

    func finish() {
        queue.async { [self] in
            guard let connection else { return }
            let last = #"{"choices":[{"delta":{"content":"B","tool_calls":[{"index":0,"function":{"arguments":"\"ls\"}"}}]},"finish_reason":"tool_calls"}]}"#
            let usage = #"{"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2,"total_tokens":9}}"#
            send(connection, chunk("data: \(last)\n\ndata: \(usage)\n\ndata: [DONE]\n\n") + "0\r\n\r\n", close: true)
        }
    }

    func breakTransport() {
        queue.async { [self] in
            guard let connection else { return }
            // Incomplete declared HTTP chunk: URLSession must throw rather
            // than interpreting clean EOF as a valid completed response.
            send(connection, "80\r\nshort", close: true)
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in connection?.cancel() }
    }

    private func chunk(_ value: String) -> String {
        "\(String(value.utf8.count, radix: 16))\r\n\(value)\r\n"
    }

    private func sendJSON(_ connection: NWConnection, status: String, body: String) {
        send(connection, "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)", close: true)
    }

    private func send(_ connection: NWConnection, _ value: String, close: Bool = false) {
        sendSequence += 1
        let sequence = sendSequence
        print("DCHAT03_LOOPBACK send sequence=\(sequence) complete=true final=\(close) bytes=\(value.utf8.count)")
        connection.send(content: Data(value.utf8),
                        contentContext: close ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { error in
            if let error {
                let failure = error as NSError
                print("DCHAT03_LOOPBACK processed sequence=\(sequence) errorDomain=\(failure.domain) errorCode=\(failure.code)")
            } else {
                print("DCHAT03_LOOPBACK processed sequence=\(sequence) errorDomain=none errorCode=0")
            }
        })
    }
}

private actor WrapperEvents {
    private(set) var deltas: [String] = []
    private(set) var completed = 0
    func append(_ event: LLMAssistantStreamEvent) {
        switch event {
        case .textDelta(let delta): deltas.append(delta)
        case .thinkingDelta: break
        case .completed: completed += 1
        }
    }
}

@Suite("D-CHAT-03 built-in wrapper factory runtime SSE", .serialized)
@MainActor
struct DChat03FactoryWrapperStreamingTests {
    nonisolated private static let types: [ProviderType] = [.deepSeek, .dashScope]
    private static let tools = [AgentToolDefinition(
        name: "run_command", description: "fixture",
        parameters: ["command": AgentToolParam(type: .string, description: "command")],
        required: ["command"]
    )]

    private func provider(_ type: ProviderType, base: String) throws -> any LLMProvider {
        let config = ProviderConfig(label: "wrapper-fixture", providerType: type,
                                    isEnabled: true, customBaseURL: base, apiKey: "fixture-key")
        let result = try ProviderFactory().makeProvider(for: config)
        #expect(type == .deepSeek ? result is DeepSeekProvider : result is DashScopeProvider)
        return result
    }

    private func route(_ type: ProviderType, server: WrapperLoopbackSSE) throws -> ProviderRuntimeRoute {
        let actual = try provider(type, base: server.baseURL)
        let material = try #require((actual as? any ProviderRuntimeConfigurationIdentity)?.runtimeConfigurationMaterial)
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: actual.name, modelID: actual.model.id,
            readinessEvidenceID: "mock-wrapper", applyReceiptID: "provider-readiness-apply:wrapper",
            capabilities: actual.capabilities,
            configurationFingerprint: ProviderRuntimeSnapshot.configurationFingerprint(
                providerID: actual.name, modelID: actual.model.id,
                capabilities: actual.capabilities, configurationMaterial: material)
        )
        return try ProviderRuntimeRoute(snapshot: snapshot, primary: actual)
    }

    private func stream(_ route: ProviderRuntimeRoute) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await route.streamAssistantMessage(messages: [LLMMessage(role: .user, content: "fixture")],
            systemPrompt: "fixture-system", tools: Self.tools, maxTokens: 64, temperature: 0.2)
    }

    @Test("loopback HTTP transport control reaches the scripted server")
    func loopbackTransportControl() async throws {
        let server = try WrapperLoopbackSSE()
        defer { server.stop() }
        var request = URLRequest(url: try #require(URL(string: server.baseURL + "/chat/completions")))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"stream":false}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (body, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(!body.isEmpty)
            #expect(server.requestBodies.count == 1)
        } catch {
            let failure = error as NSError
            Issue.record("local transport domain=\(failure.domain) code=\(failure.code) requests=\(server.requestBodies.count)")
        }
    }

    @Test("default factory returns the concrete assistant-streaming wrapper", arguments: types)
    func concreteFactoryConformance(_ type: ProviderType) throws {
        let actual = try provider(type, base: "http://127.0.0.1:1")
        #expect(actual is any AssistantStreamingLLMProvider)
    }

    @Test("runtime receives first delta while wire terminal is withheld, then tools and usage once", arguments: types)
    func firstDeltaBeforeCompletion(_ type: ProviderType) async throws {
        let server = try WrapperLoopbackSSE()
        defer { server.stop() }
        var iterator = try await stream(route(type, server: server)).makeAsyncIterator()
        let first = try await iterator.next()
        guard case .textDelta(let delta) = first else {
            Issue.record("real factory/runtime used a buffered completed-only route")
            return
        }
        #expect(delta == "A")
        #expect(server.requestBodies.count == 1)
        let body = try #require(server.requestBodies.first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
        // MC4-012：非 OpenAI 官方、非推理模型的兼容端点（此处为本机回环桩）发 max_tokens。
        #expect(json["max_tokens"] as? Int == 64)
        #expect(json["max_completion_tokens"] == nil)
        #expect(json["temperature"] as? Double == 0.2)
        #expect((json["tools"] as? [[String: Any]])?.count == 1)
        #expect((json["messages"] as? [[String: Any]])?.first?["content"] as? String == "fixture-system")
        server.finish()
        var deltas = [delta]
        var terminals: [LLMResponse] = []
        while let event = try await iterator.next() {
            switch event {
            case .textDelta(let text): deltas.append(text)
            case .thinkingDelta: break
            case .completed(let response): terminals.append(response)
            }
        }
        #expect(deltas == ["A", "B"])
        #expect(terminals.count == 1)
        let terminal = try #require(terminals.first)
        #expect(terminal.text == "AB")
        #expect(terminal.stopReason == "tool_calls")
        #expect(terminal.usage?.inputTokens == 7)
        #expect(terminal.usage?.outputTokens == 2)
        #expect(terminal.toolCalls.count == 1)
        #expect(terminal.toolCalls.first?.id == "call_fixture")
        #expect(terminal.toolCalls.first?.name == "run_command")
        #expect(terminal.toolCalls.first?.rawArguments == #"{"command":"ls"}"#)
        #expect(terminal.toolCalls.first?.arguments["command"] as? String == "ls")
        #expect(server.requestBodies.count == 1)
    }

    @Test("HTTP acquisition failure stays typed and payload-free", arguments: types)
    func acquisitionError(_ type: ProviderType) async throws {
        let server = try WrapperLoopbackSSE(mode: .httpFailure)
        defer { server.stop() }
        do {
            _ = try await stream(route(type, server: server))
            Issue.record("expected HTTP acquisition error")
        } catch let error as FallbackRouterError {
            guard case .allProvidersFailed(let trail) = error else {
                Issue.record("expected typed runtime attempt trail"); return
            }
            #expect(trail.count == 1)
            #expect(trail.first?.failureKind == .rateLimited)
            #expect(trail.first?.statusCode == 429)
            #expect(trail.first?.errorDescription == "HTTP 429")
        }
        #expect(server.requestBodies.count == 1)
        // The concrete wrapper itself preserves the underlying typed HTTP
        // boundary; the runtime consumer additionally wraps the attempt trail.
        let directServer = try WrapperLoopbackSSE(mode: .httpFailure)
        defer { directServer.stop() }
        let actual = try #require(provider(type, base: directServer.baseURL) as? any AssistantStreamingLLMProvider)
        do {
            _ = try await actual.streamAssistantMessage(messages: [LLMMessage(role: .user, content: "fixture")],
                systemPrompt: nil, tools: Self.tools, maxTokens: 64, temperature: nil)
            Issue.record("expected concrete wrapper HTTP error")
        } catch let error as LLMError {
            guard case .httpStatus(let code, let detail) = error else {
                Issue.record("expected typed wrapper HTTP error"); return
            }
            #expect(code == 429)
            #expect(!detail.contains("fixture-private-body"))
            #expect(!detail.contains("fixture-key"))
            #expect(ProviderRequestFailureKind.classify(error) == .rateLimited)
        }
        #expect(directServer.requestBodies.count == 1)
    }

    @Test("mid-stream broken transport throws and does not invent a terminal", arguments: types)
    func midStreamError(_ type: ProviderType) async throws {
        let server = try WrapperLoopbackSSE()
        defer { server.stop() }
        var iterator = try await stream(route(type, server: server)).makeAsyncIterator()
        guard case .textDelta("A") = try await iterator.next() else {
            Issue.record("expected first delta before breaking transport"); return
        }
        server.breakTransport()
        do {
            while let event = try await iterator.next() {
                if case .completed = event { Issue.record("broken stream synthesized completed") }
            }
            Issue.record("expected transport failure")
        } catch let error as LLMError {
            #expect(!error.localizedDescription.contains("fixture-key"))
            #expect(!error.localizedDescription.contains("private-reasoning"))
            #expect(ProviderRequestFailureKind.classify(error) == .transport)
        }
    }

    @Test("cancelling acquisition propagates cancellation", arguments: types)
    func cancelAcquisition(_ type: ProviderType) async throws {
        let server = try WrapperLoopbackSSE(mode: .waitForHeaders)
        defer { server.stop() }
        let route = try route(type, server: server)
        let task = Task { try await stream(route) }
        for _ in 0..<400 where server.requestBodies.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(server.requestBodies.count == 1)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled acquisition returned a stream")
        } catch {
            #expect(ProviderRequestFailureKind.classify(error) == .cancelled)
        }
    }

    @Test("cancelling after first delta rejects later wire text and terminal", arguments: types)
    func cancelAfterFirstDelta(_ type: ProviderType) async throws {
        let server = try WrapperLoopbackSSE()
        defer { server.stop() }
        let events = WrapperEvents()
        let stream = try await stream(route(type, server: server))
        let task = Task {
            for try await event in stream { await events.append(event) }
        }
        for _ in 0..<400 {
            if !(await events.deltas).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await events.deltas == ["A"])
        task.cancel()
        server.finish()
        do { try await task.value }
        catch { #expect(ProviderRequestFailureKind.classify(error) == .cancelled) }
        #expect(await events.deltas == ["A"])
        #expect(await events.completed == 0)
    }
}
