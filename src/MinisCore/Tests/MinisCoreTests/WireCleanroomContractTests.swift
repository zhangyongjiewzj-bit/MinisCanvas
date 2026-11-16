import Foundation
import Testing
@testable import MinisCore

private final class WireFixtureRegistry: @unchecked Sendable {
    struct Plan: Sendable {
        var status = 200
        var contentType = "text/event-stream"
        var chunks: [Data] = []
        var failure: URLError.Code?
    }
    static let shared = WireFixtureRegistry()
    private let lock = NSLock()
    private var plans: [String: Plan] = [:]
    private var counts: [String: Int] = [:]
    func insert(_ plan: Plan) -> String {
        lock.withLock {
            let id = UUID().uuidString
            plans[id] = plan
            counts[id] = 0
            return id
        }
    }
    func take(_ id: String) -> Plan? {
        lock.withLock { counts[id, default: 0] += 1; return plans[id] }
    }
    func count(_ id: String) -> Int { lock.withLock { counts[id] ?? 0 } }
    func remove(_ id: String) { lock.withLock { plans.removeValue(forKey: id); counts.removeValue(forKey: id) } }
}

private final class WireFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "wire.fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Wire-Fixture"),
              let plan = WireFixtureRegistry.shared.take(id), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        if let code = plan.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code)); return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": plan.contentType]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


// All records and task identifiers below are synthetic state inputs, never Foundation metrics.
private final class WireSyntheticLedgerObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [OwnedMMOutboundRecord] = []
    private var lines: [String] = []
    func record(_ entry: OwnedMMOutboundRecord) { lock.withLock { entries.append(entry) } }
    func publish(_ line: String) { lock.withLock { lines.append(line) } }
    var records: [OwnedMMOutboundRecord] { lock.withLock { entries } }
    var publishedLines: [String] { lock.withLock { lines } }
}

// Pauses only a controlled in-memory sequence; its EOF is not real transport evidence.
private actor WireSyntheticPausedLines {
    private let lines = ["data: [DONE]", ": transport-still-open",
        "data: {\"choices\":[{\"delta\":{\"content\":\"SHOULD_NOT_APPEAR\"}}]}"]
    private var offset = 0
    private var closed = false
    private var pending: CheckedContinuation<String?, Never>?
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []
    func next() async -> String? {
        if offset < lines.count {
            let line = lines[offset]
            offset += 1
            return line
        }
        if closed { return nil }
        return await withCheckedContinuation { continuation in
            pending = continuation
            let observers = pauseObservers
            pauseObservers.removeAll()
            for observer in observers { observer.resume() }
        }
    }
    func waitUntilInputRemainsOpen() async {
        if pending != nil { return }
        await withCheckedContinuation { pauseObservers.append($0) }
    }
    func closeSyntheticInput() {
        closed = true
        let continuation = pending
        pending = nil
        continuation?.resume(returning: nil)
    }
}

@Suite("Cleanroom WIRE synthetic contracts", .serialized)
struct WireCleanroomContractTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func anthropic(_ session: URLSession, id: String) -> AnthropicProvider {
        let provider = AnthropicProvider(apiKey: "fixture-only", basePath: "https://wire.fixture.invalid/prefix", session: session)
        provider.extraHeaders = ["X-Wire-Fixture": id]
        return provider
    }
    private func compatible(_ session: URLSession, id: String) -> OpenAICompatibleProvider {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-only", customBaseURL: "https://wire.fixture.invalid/prefix", session: session)
        provider.extraHeaders = ["X-Wire-Fixture": id]
        return provider
    }

    @Test func anthropicUnicodeMultilineAndSemanticStop() async throws {
        let body = """
        data: {"type":"message_start","message":{"id":"msg_fixture","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[],"stop_reason":null,"usage":{"input_tokens":2,"output_tokens":0}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta",
        data: "index":0,"delta":{"type":"text_delta","text":"你好🌊"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

        data: {"type":"message_stop"}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"AFTER_STOP_SENTINEL"}}

        """.replacingOccurrences(of: "\n", with: "\r\n")
        let id = WireFixtureRegistry.shared.insert(.init(chunks: body.utf8.map { Data([$0]) }))
        defer { WireFixtureRegistry.shared.remove(id) }
        let network = session()
        defer { network.invalidateAndCancel() }
        let stream = try await anthropic(network, id: id).streamMessage(messages: [.init(role: .user, content: "fixture")],
            systemPrompt: nil, maxTokens: 12, temperature: nil)
        var text = "", starts = 0, finishes = 0
        var stop: String?
        for try await event in stream {
            switch event {
            case .started: starts += 1
            case .text(let value): text += value
            case .finished(let reason): finishes += 1; stop = reason
            case .usage: break
            }
        }
        #expect(starts == 1)
        #expect(text == "你好🌊")
        #expect(finishes == 1)
        #expect(stop == "end_turn")
        #expect(WireFixtureRegistry.shared.count(id) == 1)

        let mixed = ": keepalive\revent: ping\rdata: {\"type\":\"ping\"}\r\rdata:{\"type\":\"message_stop\"}"
        var parser = SSEStreamParser()
        var events: [SSEStreamParser.Event] = []
        for byte in mixed.utf8 {
            for output in parser.feed(Data([byte])) {
                switch output {
                case .event(let event): events.append(event)
                case .done: Issue.record("No DONE sentinel was supplied")
                }
            }
        }
        #expect(events.compactMap { $0.jsonObject?["type"] as? String } == ["ping"])
        if let tail = parser.flushPending() { events.append(tail) }
        #expect(events.compactMap { $0.jsonObject?["type"] as? String } == ["ping", "message_stop"])
        #expect(events.count == 2)
        #expect(parser.flushPending() == nil)
    }

    @Test func anthropicIncompleteToolInputStaysInadmissible() async throws {
        let body = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_fixture\",\"name\":\"lookup\",\"input\":{}}}\r\r"
            + "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\"}}\r\r"
            + "data: {\"type\":\"message_stop\"}"
        let id = WireFixtureRegistry.shared.insert(.init(chunks: body.utf8.map { Data([$0]) }))
        defer { WireFixtureRegistry.shared.remove(id) }
        let network = session()
        defer { network.invalidateAndCancel() }
        let stream = try await anthropic(network, id: id).streamAssistantMessage(messages: [.init(role: .user, content: "fixture")],
            systemPrompt: nil, tools: [], maxTokens: 12, temperature: nil)
        var completions = 0
        var executable = -1
        var published = ""
        for try await event in stream {
            switch event {
            case .textDelta(let value): published += value
            case .completed(let response): completions += 1; executable = response.toolCalls.count
            }
        }
        #expect(published.isEmpty)
        #expect(completions == 1)
        #expect(executable == 0)

        let completeObjects: [[String: Any]] = [
            ["type": "message_start", "message": ["id": "msg_fixture_complete", "type": "message",
                "role": "assistant", "model": "claude-sonnet-4-6", "content": [], "stop_reason": NSNull(),
                "usage": ["input_tokens": 12, "output_tokens": 0, "cache_read_input_tokens": 4]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": "查找"]],
            ["type": "content_block_start", "index": 1,
                "content_block": ["type": "tool_use", "id": "call_fixture", "name": "lookup", "input": [:]]],
            ["type": "content_block_delta", "index": 1,
                "delta": ["type": "input_json_delta", "partial_json": "{\"query\":"]],
            ["type": "content_block_delta", "index": 1,
                "delta": ["type": "input_json_delta", "partial_json": "\"river\"}"]],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 5]],
            ["type": "message_stop"],
            ["type": "content_block_delta", "index": 0,
                "delta": ["type": "text_delta", "text": "SHOULD_NOT_APPEAR"]]
        ]
        let completeBody = try completeObjects.map { object in
            "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }.joined(separator: "\n\n")
        let completeID = WireFixtureRegistry.shared.insert(.init(chunks: completeBody.utf8.map { Data([$0]) }))
        defer { WireFixtureRegistry.shared.remove(completeID) }
        let completeStream = try await anthropic(network, id: completeID).streamAssistantMessage(
            messages: [.init(role: .user, content: "fixture")], systemPrompt: nil, tools: [], maxTokens: 12, temperature: nil)
        var completeText = ""
        var completeCount = 0
        var completeResponse: LLMResponse?
        for try await event in completeStream {
            switch event {
            case .textDelta(let value): completeText += value
            case .completed(let response): completeCount += 1; completeResponse = response
            }
        }
        #expect(completeText == "查找")
        #expect(completeCount == 1)
        #expect(completeResponse?.text == "查找")
        #expect(completeResponse?.stopReason == "tool_use")
        #expect(completeResponse?.toolCalls.count == 1)
        #expect(completeResponse?.toolCalls.first?.id == "call_fixture")
        #expect(completeResponse?.toolCalls.first?.name == "lookup")
        #expect(completeResponse?.toolCalls.first?.arguments.count == 1)
        #expect(completeResponse?.toolCalls.first?.arguments["query"] as? String == "river")
        #expect(completeResponse?.usage?.inputTokens == 12)
        #expect(completeResponse?.usage?.cacheReadInputTokens == 4)
        #expect(completeResponse?.usage?.outputTokens == 5)
        #expect(WireFixtureRegistry.shared.count(completeID) == 1)
    }

    @Test func compatibleFinalFrameAndTrailingUsage() async throws {
        let body = """
        event: ignored
        data: []
        data: broken
        data:{"choices":[{"index":0,"delta":{"content":"A","tool_calls":[{"index":0,"id":"call_fixture","type":"function","function":{"name":"lookup","arguments":"{\\\"query\\\":"}}]},"finish_reason":null}]}
        data: {"choices":[{"index":0,"delta":{"content":"B","tool_calls":[{"index":0,"function":{"arguments":"\\\"river\\\"}"}}]},"finish_reason":"tool_calls"}]}
        data: {"choices":[{"index":0,"delta":{"content":"AFTER_STOP_SENTINEL"},"finish_reason":null}]}
        data: {"choices":[],"usage":{"prompt_tokens":8,"completion_tokens":2}}
        data: [DONE]
        """
        let id = WireFixtureRegistry.shared.insert(.init(chunks: body.utf8.map { Data([$0]) }))
        defer { WireFixtureRegistry.shared.remove(id) }
        let network = session()
        defer { network.invalidateAndCancel() }
        let stream = try await compatible(network, id: id).streamAssistantMessage(messages: [.init(role: .user, content: "fixture")],
            systemPrompt: nil, tools: [], maxTokens: 12, temperature: nil)
        var text = "", completed = 0
        var result: LLMResponse?
        for try await event in stream {
            switch event {
            case .textDelta(let value): text += value
            case .completed(let value): completed += 1; result = value
            }
        }
        #expect(text == "AB")
        #expect(completed == 1)
        #expect(result?.text == "AB")
        #expect(result?.stopReason == "tool_calls")
        #expect(result?.usage?.inputTokens == 8)
        #expect(result?.usage?.outputTokens == 2)
        #expect(result?.toolCalls.count == 1)
        #expect(result?.toolCalls.first?.arguments["query"] as? String == "river")

        // Synthetic state/sequence ordering only: no Foundation metrics or real network EOF is claimed.
        let observation = WireSyntheticLedgerObservation()
        let ledger = OwnedMMOutboundLedger(runIdentity: "wire-synthetic-paused-sequence",
            sink: { observation.record($0) })
        let readiness = try ledger.beginAction(.providerReadinessButton)
        let readyPhases: [OwnedMMPhase] = [.reachability, .authentication, .modelDiscovery, .minimalText]
        for (index, phase) in readyPhases.enumerated() {
            let permit = try ledger.beforeSend(action: readiness, phase: phase)
            #expect(ledger.snapshot.admitted == index + 1)
            #expect(ledger.snapshot.finished == index)
            #expect(ledger.snapshot.inFlight)
            let syntheticTaskID = index + 1
            ledger.recordMetrics(permit, taskID: syntheticTaskID, count: 1)
            ledger.finish(permit, taskID: syntheticTaskID, status: 200, errorPresent: false)
            try await permit.waitForFinish()
            #expect(!ledger.snapshot.stopped)
            #expect(!ledger.snapshot.inFlight)
            #expect(ledger.snapshot.finished == index + 1)
            #expect(observation.records.filter { $0.event == .finish && !$0.failed }.count == index + 1)
        }
        let composer = try ledger.beginAction(.composerSendButton)
        let visualPermit = try ledger.beforeSend(action: composer, phase: .visual)
        ledger.recordMetrics(visualPermit, taskID: 5, count: 1)
        let pausedInput = WireSyntheticPausedLines()
        let syntheticLines = AsyncStream<String>(unfolding: { await pausedInput.next() })
        let raw = compatible(network, id: id).makeRawLineStream(lines: syntheticLines,
            statusCode: 200, streamPermit: visualPermit)
        let consumer = Task {
            for try await line in raw { observation.publish(line) }
        }
        await pausedInput.waitUntilInputRemainsOpen()
        // DONE plus later data have been consumed, but no legal completion input or EOF was supplied.
        #expect(ledger.snapshot.admitted == 5)
        #expect(ledger.snapshot.finished == 4)
        #expect(ledger.snapshot.inFlight)
        #expect(!ledger.snapshot.stopped)
        #expect(observation.publishedLines.isEmpty)
        #expect(!observation.records.contains { $0.phase == .visual && $0.event == .finish && !$0.failed })
        await pausedInput.closeSyntheticInput()
        try await consumer.value
        #expect(ledger.snapshot.admitted == 5)
        #expect(ledger.snapshot.finished == 5)
        #expect(ledger.snapshot.transactions == 5)
        #expect(!ledger.snapshot.inFlight)
        #expect(!ledger.snapshot.stopped)
        #expect(observation.publishedLines == ["data: [DONE]"])
        let finishes = observation.records.filter { $0.event == .finish }
        #expect(finishes.count == 5)
        #expect(finishes.allSatisfy { !$0.failed })
        #expect(finishes.filter { $0.phase == .visual }.count == 1)

        // Synthetic counterexample: a count other than one cannot settle successfully.
        let rejectedObservation = WireSyntheticLedgerObservation()
        let rejectedLedger = OwnedMMOutboundLedger(runIdentity: "wire-synthetic-invalid-metrics",
            sink: { rejectedObservation.record($0) })
        let rejectedAction = try rejectedLedger.beginAction(.providerReadinessButton)
        let rejectedPermit = try rejectedLedger.beforeSend(action: rejectedAction, phase: .reachability)
        rejectedLedger.recordMetrics(rejectedPermit, taskID: 101, count: 2)
        rejectedLedger.finish(rejectedPermit, taskID: 101, status: 200, errorPresent: false)
        await #expect(throws: (any Error).self) {
            try await rejectedPermit.waitForFinish()
        }
        #expect(rejectedLedger.snapshot.stopped)
        #expect(!rejectedObservation.records.contains { $0.event == .finish && !$0.failed })
    }

    @Test(arguments: [URLError.Code.timedOut, URLError.Code.cancelled])
    func acquisitionFailureKeepsTypedTransportOrCancellation(_ code: URLError.Code) async {
        let id = WireFixtureRegistry.shared.insert(.init(failure: code))
        defer { WireFixtureRegistry.shared.remove(id) }
        let network = session()
        defer { network.invalidateAndCancel() }
        let a = anthropic(network, id: id)
        let o = compatible(network, id: id)
        let messages = [LLMMessage(role: .user, content: "fixture")]
        let operations: [() async throws -> Void] = [
            { _ = try await a.streamMessage(messages: messages, systemPrompt: nil, maxTokens: 8, temperature: nil) },
            { _ = try await a.streamAssistantMessage(messages: messages, systemPrompt: nil, tools: [], maxTokens: 8, temperature: nil) },
            { _ = try await o.streamMessage(messages: messages, systemPrompt: nil, maxTokens: 8, temperature: nil) },
            { _ = try await o.streamAssistantMessage(messages: messages, systemPrompt: nil, tools: [], maxTokens: 8, temperature: nil) },
            { _ = try await o.streamRaw(body: ["stream": true, "messages": []]) }
        ]
        for operation in operations {
            do { try await operation(); Issue.record("Expected an acquisition failure") }
            catch let error as LLMError {
                switch (code, error) {
                case (.cancelled, .cancelled), (.timedOut, .networkError): break
                default: Issue.record("Acquisition error lost its typed cancellation/transport category")
                }
            } catch { Issue.record("Acquisition escaped the LLMError contract") }
        }
        #expect(WireFixtureRegistry.shared.count(id) == operations.count)
    }

    @Test func publicErrorStringsDoNotPublishSyntheticSecrets() {
        let sentinel = "sk-SYNTHETIC-PRIVATE_REQUEST_RESPONSE_SENTINEL"
        let underlying = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
            userInfo: [NSLocalizedDescriptionKey: sentinel])
        let errors: [LLMError] = [.invalidAPIKey(detail: sentinel), .networkError(underlying: underlying),
            .providerError(message: sentinel), .transientError(message: sentinel), .decodingError(underlying: underlying),
            .rateLimited, .cancelled, .unsupportedCapability(.audio), .unknown(underlying: underlying),
            .httpStatus(code: 401, detail: sentinel)]
        for error in errors {
            let projections = [error.errorDescription ?? "", error.description, error.userMessageZH, error.userMessageEN,
                error.technicalDetail, error.fallbackReason, error.friendlyMessage(locale: Locale(identifier: "zh_CN")),
                error.friendlyMessage(locale: Locale(identifier: "en_US"))]
            #expect(projections.allSatisfy { !$0.contains(sentinel) })
        }
        #expect(!LLMError.isRetryable(CancellationError()))
        #expect(!LLMError.isRetryable(URLError(.cancelled)))
        #expect(LLMError.isRetryable(URLError(.timedOut)))

        let enLocale = Locale(identifier: "en_US")
        #expect(LLMError.networkError(underlying: URLError(.timedOut)).friendlyMessage(locale: enLocale)
            == "❌ 网络错误 / Network Error（network）：Request timed out — please check your network or retry later")
        #expect(LLMError.networkError(underlying: URLError(.cannotConnectToHost)).friendlyMessage(locale: enLocale)
            == "❌ 网络错误 / Network Error（network）：Cannot connect to the server — please check your network or the service address")

        let britishEnglish = Locale(identifier: "en_GB")
        #expect(LLMError.networkError(underlying: URLError(.timedOut)).friendlyMessage(locale: britishEnglish)
            == "❌ 网络错误 / Network Error（network）：Request timed out — please check your network or retry later")
        #expect(LLMError.networkError(underlying: URLError(.cannotConnectToHost)).friendlyMessage(locale: britishEnglish)
            == "❌ 网络错误 / Network Error（network）：Cannot connect to the server — please check your network or the service address")

        let zhLocale = Locale(identifier: "zh_CN")
        let privateDetail = "SYNTHETIC_PRIVATE_DETAIL"
        let explicitChineseCases: [(LLMError, [String])] = [
            (.networkError(underlying: URLError(.timedOut)), ["网络错误", "请求超时", "network"]),
            (.networkError(underlying: URLError(.cannotConnectToHost)), ["网络错误", "无法连接到服务器", "network"]),
            (.httpStatus(code: 401, detail: privateDetail), ["401", "API Key"]),
            (.httpStatus(code: 429, detail: privateDetail), ["429", "限流"]),
            (.httpStatus(code: 500, detail: privateDetail), ["500", "服务端内部错误"]),
            (.httpStatus(code: 503, detail: privateDetail), ["503", "服务暂时不可用"])
        ]
        for (error, requiredStrings) in explicitChineseCases {
            let message = error.friendlyMessage(locale: zhLocale)
            #expect(requiredStrings.allSatisfy { message.contains($0) })
            #expect(!message.contains(privateDetail))
        }
    }
}
