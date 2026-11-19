import Foundation
import Testing
@testable import MinisCore

// 第三轮 V-7 / V-8：主对话重试策略（`LLMRetryPolicy.mainConversation`）。
// 全部离线：假服务商按脚本失败，sleeper 只记录不等待。

private final class MainRetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [Double] = []
    private var _waits: [(LLMRateLimitWaitRequest.Reason, Double)] = []
    var delays: [Double] { lock.withLock { _delays } }
    var waits: [(LLMRateLimitWaitRequest.Reason, Double)] { lock.withLock { _waits } }
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    func sleeper() -> @Sendable (Duration) async throws -> Void {
        { [self] duration in lock.withLock { _delays.append(Self.seconds(duration)) } }
    }
    func recordWait(_ request: LLMRateLimitWaitRequest) {
        lock.withLock { _waits.append((request.reason, Self.seconds(request.delay))) }
    }
}

private final class MainRetryScriptedProvider: LLMProvider, AssistantStreamingLLMProvider, @unchecked Sendable {
    enum Step {
        /// 发送 / 建流时直接抛错。
        case fail(Error)
        /// 流建好了，但一个事件都没有就失败（Anthropic 流内 overloaded 的形状）。
        case streamFailsBeforeAnyEvent(Error)
        /// 先吐出一段文字，再失败。
        case streamTextThenFail(Error)
        case succeed(String)
    }

    let name = "main-retry-scripted"
    var model = LLMModel(id: "main-retry-model", displayName: "Main Retry", provider: "main-retry")
    let capabilities: Set<ProviderCapability> = [.tools, .streaming]

    private let lock = NSLock()
    private var steps: [Step]
    private var _calls = 0

    init(_ steps: [Step]) { self.steps = steps }

    var calls: Int { lock.withLock { _calls } }

    private func nextStep() -> Step {
        lock.withLock {
            _calls += 1
            return steps.isEmpty ? .succeed("ok") : steps.removeFirst()
        }
    }

    private func buffered() throws -> LLMResponse {
        switch nextStep() {
        case .fail(let error), .streamFailsBeforeAnyEvent(let error), .streamTextThenFail(let error): throw error
        case .succeed(let text): return LLMResponse(text: text, stopReason: "stop", usage: nil)
        }
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try buffered()
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try buffered()
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                                maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        switch nextStep() {
        case .fail(let error): throw error
        case .streamFailsBeforeAnyEvent(let error):
            return AsyncThrowingStream { $0.finish(throwing: error) }
        case .streamTextThenFail(let error):
            return AsyncThrowingStream { continuation in
                continuation.yield(.textDelta("已经输出的半截"))
                continuation.finish(throwing: error)
            }
        case .succeed(let text):
            return AsyncThrowingStream { continuation in
                continuation.yield(.textDelta(text))
                continuation.yield(.completed(LLMResponse(text: text, stopReason: "stop", usage: nil)))
                continuation.finish()
            }
        }
    }
}

private func status(_ code: Int, detail: String = "") -> LLMError { .httpStatus(code: code, detail: detail) }

private let hi = [LLMMessage(role: .user, content: "hi")]

private func send(_ provider: RetryingLLMProvider) async throws -> LLMResponse {
    try await provider.sendMessage(messages: hi, systemPrompt: nil, maxTokens: 16, temperature: nil)
}

private func collect(_ provider: RetryingLLMProvider) async throws -> [LLMAssistantStreamEvent] {
    var events: [LLMAssistantStreamEvent] = []
    let stream = try await provider.streamAssistantMessage(messages: hi, systemPrompt: nil, tools: [],
        maxTokens: 16, temperature: nil)
    for try await event in stream { events.append(event) }
    return events
}

@Suite("V-7/V-8 main conversation retry policy", .serialized)
struct MainConversationRetryPolicyTests {
    @Test("5xx statuses (500/502/503/504) and 529 are retried until the call succeeds", arguments: [500, 502, 503, 504, 529])
    func serverErrorsAreRetried(code: Int) async throws {
        let recorder = MainRetryRecorder()
        let base = MainRetryScriptedProvider([.fail(status(code)), .fail(status(code))])
        let provider = RetryingLLMProvider(base: base, policy: .mainConversation(sleeper: recorder.sleeper()))
        let response = try await send(provider)
        #expect(response.text == "ok")
        #expect(base.calls == 3)
        #expect(recorder.delays == [0.5, 1])
    }

    @Test("4xx and unlisted 5xx are not retried", arguments: [400, 401, 403, 404, 413, 501, 505])
    func otherStatusesAreNotRetried(code: Int) async {
        let recorder = MainRetryRecorder()
        let base = MainRetryScriptedProvider([.fail(status(code)), .fail(status(code))])
        let provider = RetryingLLMProvider(base: base, policy: .mainConversation(sleeper: recorder.sleeper()))
        await #expect(throws: LLMError.self) { _ = try await send(provider) }
        #expect(base.calls == 1)
        #expect(recorder.delays.isEmpty)
    }

    @Test("backoff doubles from 0.5 s, is capped at 32 s, and gives up after 8 retries")
    func backoffScheduleAndExhaustion() async {
        let recorder = MainRetryRecorder()
        let base = MainRetryScriptedProvider(Array(repeating: .fail(status(503)), count: 20))
        let provider = RetryingLLMProvider(base: base, policy: .mainConversation(sleeper: recorder.sleeper()))
        await #expect(throws: Error.self) { _ = try await send(provider) }
        #expect(base.calls == 9)
        #expect(recorder.delays == [0.5, 1, 2, 4, 8, 16, 32, 32])
    }

    @Test("connections that never reached the server are retried; ambiguous or permanent ones are not")
    func connectionFailures() async throws {
        let retried: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet]
        for code in retried {
            let base = MainRetryScriptedProvider([.fail(LLMError.networkError(underlying: URLError(code)))])
            let provider = RetryingLLMProvider(base: base,
                policy: .mainConversation(sleeper: MainRetryRecorder().sleeper()))
            #expect(try await send(provider).text == "ok", "\(code) should be retried")
            #expect(base.calls == 2)
        }
        let notRetried: [URLError.Code] = [.timedOut, .networkConnectionLost, .secureConnectionFailed, .badServerResponse]
        for code in notRetried {
            let base = MainRetryScriptedProvider([.fail(LLMError.networkError(underlying: URLError(code)))])
            let provider = RetryingLLMProvider(base: base,
                policy: .mainConversation(sleeper: MainRetryRecorder().sleeper()))
            await #expect(throws: Error.self) { _ = try await send(provider) }
            #expect(base.calls == 1, "\(code) must not be retried")
        }
    }

    @Test("a stream that fails before any event is replayed as a whole")
    func streamFailureBeforeAnyEventIsRetried() async throws {
        let recorder = MainRetryRecorder()
        let base = MainRetryScriptedProvider([.streamFailsBeforeAnyEvent(status(529))])
        let provider = RetryingLLMProvider(base: base, policy: .mainConversation(sleeper: recorder.sleeper()))
        let events = try await collect(provider)
        var texts: [String] = []
        var completions = 0
        for event in events {
            switch event {
            case .textDelta(let text): texts.append(text)
            case .completed: completions += 1
            case .thinkingDelta: break
            }
        }
        #expect(base.calls == 2)
        #expect(texts == ["ok"], "only the successful attempt's text reaches the caller")
        #expect(completions == 1)
        #expect(recorder.delays == [0.5])
    }

    @Test("once text has been delivered a later failure is surfaced, never replayed")
    func streamFailureAfterOutputIsNotRetried() async throws {
        let recorder = MainRetryRecorder()
        let base = MainRetryScriptedProvider([.streamTextThenFail(status(529)), .succeed("不应出现")])
        let provider = RetryingLLMProvider(base: base, policy: .mainConversation(sleeper: recorder.sleeper()))
        let stream = try await provider.streamAssistantMessage(messages: hi, systemPrompt: nil, tools: [],
            maxTokens: 16, temperature: nil)
        var texts: [String] = []
        var thrown: Error?
        do {
            for try await event in stream {
                if case .textDelta(let text) = event { texts.append(text) }
            }
        } catch { thrown = error }
        #expect(texts == ["已经输出的半截"])
        var surfacedCode: Int?
        if case .httpStatus(let code, _)? = thrown as? LLMError { surfacedCode = code }
        #expect(surfacedCode == 529)
        #expect(base.calls == 1)
        #expect(recorder.delays.isEmpty)
    }

    @Test("Retry-After is honoured in both projections, capped at 60 s, and malformed hints fall back to backoff")
    func retryAfterHints() async throws {
        let openAI = "status=429; category=rateLimited; retry_after="
        let anthropic = "status=429; category=rate_limited; retry_after="
        let samples: [(String, Double)] = [
            (openAI + "7", 7),
            (openAI + "7; request_id=present", 7),
            (anthropic + "7", 7),
            (anthropic + "7; request_id=present", 7),
            (anthropic + "7; request_id=present; reason=rate limited", 7),
            (anthropic + "7; reason=rate limited", 7),
            (anthropic + "3600", 60),
            (anthropic + "0", 0.5),
            (anthropic + "86401", 0.5),
            (anthropic + "7; extra=value", 0.5),
            (openAI + "7; reason=rate limited", 0.5),
            ("status=429; category=rate_limited", 0.5),
        ]
        for (detail, expected) in samples {
            let recorder = MainRetryRecorder()
            let base = MainRetryScriptedProvider([.fail(status(429, detail: detail))])
            let provider = RetryingLLMProvider(base: base, policy: .mainConversation(sleeper: recorder.sleeper()))
            #expect(try await send(provider).text == "ok")
            #expect(recorder.delays == [expected], "detail: \(detail)")
        }
    }

    @Test("an Anthropic 429 with a real Retry-After header waits that long")
    func anthropicHeaderEndToEnd() async throws {
        let anthropic = AnthropicProvider(apiKey: "fixture-key")
        let error = anthropic.mapHTTPError(statusCode: 429, body: "", headers: ["Retry-After": "7"])
        let recorder = MainRetryRecorder()
        let base = MainRetryScriptedProvider([.fail(error)])
        let provider = RetryingLLMProvider(base: base, policy: .mainConversation(sleeper: recorder.sleeper()))
        #expect(try await send(provider).text == "ok")
        #expect(recorder.delays == [7])

        // 只带 anthropic-ratelimit-*-reset（RFC 3339）时，按重置时间点换算。
        let formatter = ISO8601DateFormatter()
        let reset = formatter.string(from: Date().addingTimeInterval(20))
        let resetError = anthropic.mapHTTPError(statusCode: 429, body: "", headers: [
            "anthropic-ratelimit-requests-remaining": "0",
            "anthropic-ratelimit-requests-reset": reset,
        ])
        let recorder2 = MainRetryRecorder()
        let base2 = MainRetryScriptedProvider([.fail(resetError)])
        let provider2 = RetryingLLMProvider(base: base2, policy: .mainConversation(sleeper: recorder2.sleeper()))
        #expect(try await send(provider2).text == "ok")
        let waited = try #require(recorder2.delays.first)
        #expect(waited >= 17 && waited <= 21, "waited \(waited)")
    }

    @Test("waits are presented with the right reason")
    func waitReasons() async throws {
        let recorder = MainRetryRecorder()
        let base = MainRetryScriptedProvider([.fail(status(429)), .fail(status(503)), .fail(status(529)),
            .fail(LLMError.transientError(message: "x"))])
        let provider = RetryingLLMProvider(base: base, policy: .mainConversation(sleeper: recorder.sleeper()))
        let response = try await LLMRetryWaitContext.$rateLimitWait.withValue({ request in
            recorder.recordWait(request)
        }) { try await send(provider) }
        #expect(response.text == "ok")
        let expectedReasons: [LLMRateLimitWaitRequest.Reason] = [.rateLimited, .serviceUnavailable, .serviceUnavailable, .serviceUnavailable]
        #expect(recorder.waits.map { $0.0 } == expectedReasons)
        #expect(recorder.delays.isEmpty, "presented waits replace the plain sleeper")
    }

    @Test("the default policy keeps its historical admission (it is not the main-conversation policy)")
    func defaultPolicyUnchanged() async throws {
        let recorder = MainRetryRecorder()
        let base = MainRetryScriptedProvider([.fail(status(503))])
        let provider = RetryingLLMProvider(base: base, policy: LLMRetryPolicy(sleeper: recorder.sleeper()))
        #expect(try await send(provider).text == "ok")
        #expect(LLMRetryPolicy().retriesBeforeFirstStreamEvent == false)
        #expect(LLMRetryPolicy.mainConversation().retriesBeforeFirstStreamEvent)
    }
}
