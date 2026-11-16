import Testing
import Foundation
@testable import MinisCanvasApp
import MinisCore

// MARK: - F18b LLM 重试接线 + stopReason 映射
//
// 对齐生产 API（2026-08-04 总控修复）：
//   · RetryingLLMProvider(base:policy:) + LLMRetryPolicy(maxRetries:backoff:sleeper:)
//   · 自由函数 mapLLMStopReason(_ raw: String?) -> AgentStopReason
//   · mock 的 NSLock 操作包进同步 helper（Swift 并发隔离要求）

/// 记录退避序列的零等待 sleeper + 记录器
private final class BackoffRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [Double] = []
    var delays: [Double] {
        lock.lock(); defer { lock.unlock() }
        return _delays
    }
    func record(_ seconds: Double) {
        lock.lock(); _delays.append(seconds); lock.unlock()
    }
}

private func makeRecordingSleeper() -> (@Sendable (Duration) async throws -> Void, BackoffRecorder) {
    let recorder = BackoffRecorder()
    let sleeper: @Sendable (Duration) async throws -> Void = { duration in
        let secs = Double(duration.components.seconds)
                 + Double(duration.components.attoseconds) / 1e18
        recorder.record(secs)
    }
    return (sleeper, recorder)
}

/// 可编程失败 mock provider：前 failCount 次调用抛指定错误，之后成功。
/// 记录调用次数与收到的退避序列（断言重试行为用）。
final class F18bMockProvider: LLMProvider, StableRequestIdempotencyKeyProvider, @unchecked Sendable {
    let name = "F18bMock"
    private let acceptsToolRequests: Bool
    var capabilities: Set<ProviderCapability> { acceptsToolRequests ? [.tools] : [] }
    init(acceptsToolRequests: Bool = false) { self.acceptsToolRequests = acceptsToolRequests }
    var model: LLMModel = LLMModel(id: "mock-model", displayName: "Mock", provider: "mock")

    private let lock = NSLock()
    private var _sendCalls = 0
    private var _streamCalls = 0
    private var _seenToolNames: [[String]] = []
    var seenToolNames: [[String]] { lock.withLock { _seenToolNames } }

    /// sendMessage 前 N 次抛该错误（nil = 不失败）
    var sendError: Error?
    var sendFailCount = 0
    /// streamMessage 前 N 次抛该错误
    var streamError: Error?
    var streamFailCount = 0
    /// 成功时返回的文本
    var replyText = "ok"

    var sendCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _sendCalls
    }
    var streamCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _streamCalls
    }

    // 同步 helper：在 async 方法外完成 NSLock 操作，规避并发隔离限制
    private func nextSendCall() -> (call: Int, shouldFail: Bool, err: Error?, text: String) {
        lock.lock()
        _sendCalls += 1
        let call = _sendCalls
        let shouldFail = sendError != nil && call <= sendFailCount
        let err = sendError
        let text = replyText
        lock.unlock()
        return (call, shouldFail, err, text)
    }

    private func nextStreamCall() -> (call: Int, shouldFail: Bool, err: Error?, text: String) {
        lock.lock()
        _streamCalls += 1
        let call = _streamCalls
        let shouldFail = streamError != nil && call <= streamFailCount
        let err = streamError
        let text = replyText
        lock.unlock()
        return (call, shouldFail, err, text)
    }

    // The fixture explicitly models a stable request key so the retry tests
    // continue to exercise the opt-in idempotent path. Real providers without
    // this contract are fail-closed for ambiguous buffered POST failures.
    func stableRequestIdempotencyKey(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) -> String? {
        "f18b-fixture-request"
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        let (_, shouldFail, err, text) = nextSendCall()
        if shouldFail, let err { throw err }
        return LLMResponse(text: text, stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        guard tools.isEmpty || acceptsToolRequests else {
            throw LLMError.unsupportedCapability(.tools)
        }
        lock.withLock { _seenToolNames.append(tools.map(\.name)) }
        return try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let (_, shouldFail, err, text) = nextStreamCall()
        if shouldFail, let err { throw err }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.yield(.finished(stopReason: "stop"))
            continuation.finish()
        }
    }
}

/// 流建立成功、首个 chunk 后抛错的 mock（mid-stream 错误语义）
final class F18bStreamThenFailProvider: LLMProvider, @unchecked Sendable {
    let name = "F18bStreamThenFail"
    var model: LLMModel = LLMModel(id: "mock", displayName: "Mock", provider: "mock")

    private let lock = NSLock()
    private var _streamCalls = 0
    var streamCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _streamCalls
    }

    private func nextStreamCall() -> Int {
        lock.lock()
        _streamCalls += 1
        let call = _streamCalls
        lock.unlock()
        return call
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "", stopReason: nil, usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        _ = nextStreamCall()
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("partial"))
            continuation.finish(throwing: LLMError.transientError(message: "mid-stream"))
        }
    }
}

// MARK: - RetryingLLMProvider 重试纪律

@Suite("F18b RetryingLLMProvider 重试纪律")
struct F18bRetryTests {

    @Test func retryableErrorsRetriedUntilSuccess() async throws {
        let mock = F18bMockProvider()
        mock.sendError = LLMError.transientError(message: "server busy")
        mock.sendFailCount = 2   // 前 2 次失败，第 3 次成功
        let (sleeper, recorder) = makeRecordingSleeper()
        let policy = LLMRetryPolicy(maxRetries: 2, sleeper: sleeper)
        let retried = RetryingLLMProvider(base: mock, policy: policy)

        let response = try await retried.sendMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil, maxTokens: 100, temperature: nil)

        #expect(response.text == "ok")
        #expect(mock.sendCalls == 3, "重试 2 次后第 3 次成功")
        let delays = recorder.delays
        #expect(delays.count == 2)
        // 指数退避：0.5 → 1.0（基数 0.5 × 2^(k-1)）
        #expect(abs(delays[0] - 0.5) < 0.001)
        #expect(abs(delays[1] - 1.0) < 0.001)
    }

    @Test func compatibleRateLimitWaitUsesOnlyBoundedCanonicalRetryHint() async throws {
        let prefix = "status=429; category=rateLimited; retry_after="
        let samples: [(String, Double)] = [
            (prefix + "5", 5),
            (prefix + "5; request_id=present", 5),
            (prefix + "0", 0.5),
            (prefix + "86401", 0.5),
            (prefix + "+5", 0.5),
            (prefix + "5; extra=value", 0.5),
        ]
        for (detail, expectedDelay) in samples {
            let mock = F18bMockProvider()
            mock.sendError = LLMError.httpStatus(code: 429, detail: detail)
            mock.sendFailCount = 1
            let (sleeper, recorder) = makeRecordingSleeper()
            let provider = RetryingLLMProvider(base: mock,
                policy: LLMRetryPolicy(maxRetries: 1, sleeper: sleeper))

            let result = try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil, maxTokens: 100, temperature: nil)

            #expect(result.text == "ok" && mock.sendCalls == 2)
            #expect(recorder.delays == [expectedDelay])
        }
    }

    @Test func retryExhaustedThrowsLastError() async {
        let mock = F18bMockProvider()
        mock.sendError = LLMError.transientError(message: "always fails")
        mock.sendFailCount = 99
        let (sleeper, recorder) = makeRecordingSleeper()
        let policy = LLMRetryPolicy(maxRetries: 2, sleeper: sleeper)
        let retried = RetryingLLMProvider(base: mock, policy: policy)

        await #expect(throws: LLMError.self) {
            try await retried.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil, maxTokens: 100, temperature: nil)
        }
        #expect(mock.sendCalls == 3, "maxRetries=2 → 恰好 3 次尝试")
        let delays = recorder.delays
        #expect(delays.count == 2, "最后一次失败后不再退避")
        #expect(abs(delays[0] - 0.5) < 0.001 && abs(delays[1] - 1.0) < 0.001)
    }

    @Test func nonRetryableErrorPropagatesWithoutRetry() async {
        let mock = F18bMockProvider()
        mock.sendError = LLMError.rateLimited   // 429 → fallback 语义，不重试
        mock.sendFailCount = 99
        let (sleeper, _) = makeRecordingSleeper()
        let policy = LLMRetryPolicy(maxRetries: 2, sleeper: sleeper)
        let retried = RetryingLLMProvider(base: mock, policy: policy)

        await #expect(throws: LLMError.self) {
            try await retried.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil, maxTokens: 100, temperature: nil)
        }
        #expect(mock.sendCalls == 1, "非 retryable 立即上抛，不烧重试")
    }

    @Test func cancellationErrorNeverRetried() async {
        let mock = F18bMockProvider()
        mock.sendError = CancellationError()
        mock.sendFailCount = 99
        let (sleeper, recorder) = makeRecordingSleeper()
        let policy = LLMRetryPolicy(maxRetries: 2, sleeper: sleeper)
        let retried = RetryingLLMProvider(base: mock, policy: policy)

        await #expect(throws: CancellationError.self) {
            try await retried.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil, maxTokens: 100, temperature: nil)
        }
        #expect(mock.sendCalls == 1, "用户中断必须立即生效")
        #expect(recorder.delays.isEmpty)
    }

    @Test func streamEstablishmentRetried() async throws {
        let mock = F18bMockProvider()
        mock.streamError = LLMError.transientError(message: "connect reset")
        mock.streamFailCount = 1
        let (sleeper, _) = makeRecordingSleeper()
        let policy = LLMRetryPolicy(maxRetries: 2, sleeper: sleeper)
        let retried = RetryingLLMProvider(base: mock, policy: policy)

        let stream = try await retried.streamMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil, maxTokens: 100, temperature: nil)
        #expect(mock.streamCalls == 2, "流建立失败重试 1 次后成功")

        var text = ""
        for try await chunk in stream {
            if case .text(let t) = chunk { text += t }
        }
        #expect(text == "ok")
    }

    @Test func midStreamErrorNotRetried() async throws {
        // 流建立成功但消费中途出错 → 装饰器不重试（mid-stream 归调用方，
        // 与 FallbackRouter 流式纪律一致）
        let mock = F18bStreamThenFailProvider()
        let (sleeper, _) = makeRecordingSleeper()
        let policy = LLMRetryPolicy(maxRetries: 2, sleeper: sleeper)
        let retried = RetryingLLMProvider(base: mock, policy: policy)

        let stream = try await retried.streamMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil, maxTokens: 100, temperature: nil)
        #expect(mock.streamCalls == 1, "流建立成功 → 只调一次")

        var caught = false
        do {
            for try await _ in stream {}
        } catch {
            caught = true
        }
        #expect(caught, "mid-stream 错误照常上抛给调用方")
        #expect(mock.streamCalls == 1, "消费中出错不触发重新建流")
    }

    @Test func isRetryableStaticDecisionTable() {
        // LLMError.isRetryable(Error) 全仓统一重试判定点
        #expect(LLMError.isRetryable(LLMError.transientError(message: "x")))
        #expect(LLMError.isRetryable(LLMError.networkError(
            underlying: URLError(.networkConnectionLost))))
        #expect(LLMError.isRetryable(URLError(.timedOut)), "逃逸的 URLError 网络抖动可重试")
        #expect(!LLMError.isRetryable(LLMError.rateLimited), "429 走 fallback 不走重试")
        #expect(!LLMError.isRetryable(LLMError.invalidAPIKey(detail: "bad")))
        #expect(!LLMError.isRetryable(LLMError.cancelled))
        #expect(!LLMError.isRetryable(CancellationError()))
        #expect(!LLMError.isRetryable(URLError(.cancelled)), "URL 取消不重试")
        #expect(!LLMError.isRetryable(NSError(domain: "x", code: 1)))
    }
}

// MARK: - stopReason 统一映射（B7）

@Suite("F18b stopReason 统一映射")
struct F18bStopReasonTests {

    @Test func openAIAndAnthropicEndReasonsMapToEndTurn() {
        #expect(mapLLMStopReason("stop") == .endTurn)
        #expect(mapLLMStopReason("end_turn") == .endTurn)
        #expect(mapLLMStopReason("END_TURN") == .endTurn, "default 分支兜底为 endTurn")
        #expect(mapLLMStopReason("  stop  ") == .endTurn, "default 分支兜底为 endTurn")
    }

    @Test func tokenLimitReasonsMapToMaxTokens() {
        #expect(mapLLMStopReason("length") == .maxTokens)
        #expect(mapLLMStopReason("max_tokens") == .maxTokens)
    }

    @Test func toolReasonsMapToToolUse() {
        #expect(mapLLMStopReason("tool_calls") == .toolUse)
        #expect(mapLLMStopReason("tool_use") == .toolUse)
    }

    @Test func safetyReasonsMapToRefusal() {
        #expect(mapLLMStopReason("refusal") == .refusal)
    }

    @Test func unknownAndNilFallBackToEndTurn() {
        // 生产实现：nil / 未识别值均归 .endTurn（保守不截断）
        #expect(mapLLMStopReason(nil) == .endTurn)
        #expect(mapLLMStopReason("weird_new_reason") == .endTurn)
    }

    @Test func oldBehaviorFixedOpenAIStopNoLongerMisreported() {
        // 回归锚点：旧实现 (reason == "end_turn") ? .endTurn : .maxTokens
        // 把 OpenAI 正常结束的 "stop" 误判成 .maxTokens —— 修复后必须是 .endTurn
        #expect(mapLLMStopReason("stop") != .maxTokens)
        #expect(mapLLMStopReason("stop") == .endTurn)
    }
}
