import Foundation

/// Error thrown when every provider in the fallback chain failed.
public enum FallbackRouterError: Error, Equatable, Sendable {
    /// The route chain was empty — nothing to try.
    case emptyChain
    /// Every provider failed; carries the recorded failure trail.
    case allProvidersFailed([FallbackRouter.FallbackEvent])
}

extension FallbackRouterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyChain:
            return "Fallback chain is empty — no provider configured."
        case .allProvidersFailed(let events):
            let lines = events.map { "  ✗ \($0.providerID): \($0.errorDescription)" }
            return "All providers failed:\n" + lines.joined(separator: "\n")
        }
    }
}

/// One existing backoff wait, optionally presented by the owning conversation.
/// No raw error body or response header crosses this boundary.
public struct LLMRateLimitWaitRequest: Sendable {
    /// 等待的原因，界面据此说人话：被限流，还是服务暂时不可用（过载、5xx、连接失败）。
    public enum Reason: Sendable, Equatable {
        case rateLimited
        case serviceUnavailable
    }
    public let delay: Duration
    public let reason: Reason
    public let sleep: @Sendable (Duration) async throws -> Void
    public init(delay: Duration, reason: Reason = .rateLimited,
                sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.delay = delay
        self.reason = reason
        self.sleep = sleep
    }
}

public enum LLMRetryWaitContext {
    @TaskLocal public static var rateLimitWait: (@Sendable (LLMRateLimitWaitRequest) async throws -> Void)?
}

/// Transient metadata carried only with the exact terminal request error.
public struct ProviderRetryExhaustion: LocalizedError {
    public let underlyingError: any Error
    public let statusCode: Int

    init(underlyingError: any Error, statusCode: Int) {
        self.underlyingError = underlyingError
        self.statusCode = statusCode
    }

    public func preservingFact(with error: any Error) -> Self {
        Self(underlyingError: error, statusCode: statusCode)
    }

    public var errorDescription: String? { underlyingError.localizedDescription }
}

/// F18b: exponential-backoff retry policy for LLM calls.
///
/// Consumes `LLMError.isRetryable` (previously zero-consumption): only
/// transient errors — 429, 5xx (`httpStatus`/`transientError`) and clear
/// pre-dispatch network refusals — are retried on the SAME provider;
/// ambiguous timeout/connection-loss failures require an explicit stable
/// request key from the provider; everything else propagates immediately.
///
/// Defaults: up to 3 retries (4 total calls) with 0.5s / 1s / 2s backoff.
/// `sleeper` is injectable so tests can run without real waiting.
public struct LLMRetryPolicy: Sendable {
    /// Maximum number of retries AFTER the initial attempt (3 → up to 4 calls).
    public let maxRetries: Int
    /// Backoff before retry `attempt` (1-based). Default: 0.5s / 1s / 2s.
    public let backoff: @Sendable (Int) -> Duration
    /// Injectable sleep (tests inject a no-op recorder).
    public let sleeper: @Sendable (Duration) async throws -> Void

    private var isMainConversation = false
    private var carriesExhaustion = false

    fileprivate func trackingExhaustion() -> Self {
        var policy = self
        policy.carriesExhaustion = isMainConversation
        return policy
    }

    /// 主对话的重试策略（对齐 Claude Code：429、过载、5xx 和"请求还没发出去"的连接失败都重试，指数退避）。
    /// - 可重试：429、500、502、503、504、529，瞬时错误（含流在 message_stop 前断开），
    ///   以及连不上主机 / 解析不了域名 / 没有网络这类请求还没发出去的失败。
    ///   超时、连接中断这类"服务端可能已经收到"的失败不在内。
    /// - 次数与退避：最多重试 8 次，0.5 / 1 / 2 / 4 / 8 / 16 / 32 / 32 秒，累计约 95 秒。
    ///   Claude Code 是最多 10 次、同样从 0.5 秒起翻倍、单次上限 32 秒；这里次数少 2 次，
    ///   因为每次等待在界面上可见、可取消、可"立即重试"，且用完后还会按路线换备用服务商。
    /// - 流已经吐出任何内容之后不再重试（见 `retriesBeforeFirstStreamEvent`），避免重复输出。
    /// `sleeper` 默认真实等待；测试注入零等待记录器。
    public static func mainConversation(
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> Self {
        var policy = Self(maxRetries: 8, backoff: mainConversationBackoff, sleeper: sleeper)
        policy.isMainConversation = true
        return policy
    }

    /// 主对话退避：0.5s 起每次翻倍，单次上限 32s（与 Claude Code 一致）。
    public static let mainConversationBackoff: @Sendable (Int) -> Duration = { attempt in
        .milliseconds(min(500 * (1 << min(max(0, attempt - 1), 10)), 32_000))
    }

    /// 服务端给的"多少秒后再试"按它等，但单次最多等 60 秒；更长的只等到上限，再失败就由重试次数兜住。
    public static let maximumServerRetryAfter: Duration = .seconds(60)

    /// 流式请求是否在拿到第一个事件之前就算作"还没开始输出"，失败时可以整体重发。
    /// 只有主对话策略这样做；第一个事件一旦交出去（含思考增量），后续失败原样抛给调用方，不重试。
    var retriesBeforeFirstStreamEvent: Bool { isMainConversation }

    private func admitsRetry(_ error: Error) -> Bool {
        guard isMainConversation else { return true }
        switch error as? LLMError {
        case .httpStatus(code: let code, detail: _)?:
            return [429, 500, 502, 503, 504, 529].contains(code)
        case .transientError?:
            return true
        case .networkError?:
            return FallbackRouter.isPreDispatchConnectionFailure(error)
        default:
            return false
        }
    }

    /// Default backoff schedule: retry 1 → 0.5s, retry 2 → 1s, retry 3 → 2s.
    public static let defaultBackoff: @Sendable (Int) -> Duration = { attempt in
        .milliseconds(500 * (1 << max(0, attempt - 1)))
    }

    public init(
        maxRetries: Int = 3,
        backoff: @escaping @Sendable (Int) -> Duration = LLMRetryPolicy.defaultBackoff,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maxRetries = max(0, maxRetries)
        self.backoff = backoff
        self.sleeper = sleeper
    }

    /// Run `operation` with exponential-backoff retry.
    ///
    /// Only errors passing `LLMError.isRetryable(_:)` and `shouldRetry` are
    /// retried (429/5xx/clear pre-dispatch network errors); all other errors
    /// propagate immediately. A cancelled Task never retries. Backoff
    /// `backoff(k)` is awaited before retry `k`.
    /// `shouldRetry` is an additional request-replay fence.  Callers that
    /// cannot prove a failed operation was never accepted by its remote
    /// endpoint must return false for ambiguous post-dispatch transport
    /// failures.  The default preserves the policy's historical decision for
    /// callers that do not have a request-dispatch boundary.
    // Retry closures remain on their caller actor across backoff suspension.
    // A non-Sendable provider operation must not be transferred to the generic executor.
    public func run<T>(
        _ operation: () async throws -> T,
        isolation: isolated (any Actor)? = #isolation,
        shouldRetry: @escaping @Sendable (Error) -> Bool = { _ in true }
    ) async throws -> T {
        var retriesUsed = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard !Task.isCancelled,
                      !ProviderCancellationPolicy.isCancellation(error),
                      LLMError.isRetryable(error),
                      admitsRetry(error),
                      shouldRetry(error) else {
                    throw error
                }
                guard retriesUsed < maxRetries else {
                    if carriesExhaustion, maxRetries > 0,
                       let statusCode = ProviderRequestFailureKind.httpStatusCode(from: error) {
                        throw ProviderRetryExhaustion(underlyingError: error, statusCode: statusCode)
                    }
                    throw error
                }
                retriesUsed += 1
                let localDelay = backoff(retriesUsed)
                let delay: Duration
                // 非 nil 时这次等待交给界面展示（可取消、可立即重试）。
                let waitReason: LLMRateLimitWaitRequest.Reason?
                switch error as? LLMError {
                case .httpStatus(code: 429, detail: let detail)?:
                    waitReason = .rateLimited
                    delay = max(localDelay, Self.serverRetryAfter(detail) ?? localDelay)
                case .rateLimited?:
                    waitReason = .rateLimited
                    delay = localDelay
                default:
                    waitReason = isMainConversation ? .serviceUnavailable : nil
                    delay = localDelay
                }
                if let waitReason, let wait = LLMRetryWaitContext.rateLimitWait {
                    try await wait(LLMRateLimitWaitRequest(delay: delay, reason: waitReason, sleep: sleeper))
                } else {
                    try await sleeper(delay)
                }
                try Task.checkCancellation()
            }
        }
    }

    /// Consume only the two providers' complete safe projections:
    /// - OpenAI 兼容端：`status=429; category=rateLimited; retry_after=N[; request_id=present]`
    /// - Anthropic：`status=429; category=rate_limited; retry_after=N[; request_id=present][; reason=标签]`
    ///   （N 来自 Retry-After 或 anthropic-ratelimit-*-reset，由 Anthropic 错误投影换算好）
    /// The hint is advisory: bounded to a 60 s single wait (`maximumServerRetryAfter`),
    /// and any other shape is ignored in favour of the local backoff.
    private static func serverRetryAfter(_ detail: String) -> Duration? {
        let styles: [(prefix: String, allowsReason: Bool)] = [
            ("status=429; category=rateLimited; retry_after=", false),
            ("status=429; category=rate_limited; retry_after=", true),
        ]
        guard let style = styles.first(where: { detail.hasPrefix($0.prefix) }) else { return nil }
        var fields = detail.dropFirst(style.prefix.count).components(separatedBy: "; ")
        let digits = fields.removeFirst()
        if fields.first == "request_id=present" { fields.removeFirst() }
        if style.allowsReason, let reason = fields.first, reason.hasPrefix("reason="), reason.count > 7 {
            fields.removeFirst()
        }
        guard fields.isEmpty,
              (1...5).contains(digits.utf8.count),
              digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let seconds = Int(digits), seconds <= 86_400,
              digits == String(seconds) else { return nil }
        return min(Duration.seconds(seconds), maximumServerRetryAfter)
    }
}

/// A provider may opt into retrying an ambiguous buffered POST only when it
/// binds one stable key to the same logical request on every attempt.  The
/// key is deliberately obtained from the provider rather than synthesized by
/// the router: the provider owns the wire header/parameter and its server-side
/// idempotency contract.  Providers that do not implement this protocol are
/// fail-closed for timeout/connection-lost failures.
public protocol StableRequestIdempotencyKeyProvider: LLMProvider {
    func stableRequestIdempotencyKey(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) -> String?
}

private func providerHasStableRequestIdempotencyKey(
    _ provider: any LLMProvider,
    messages: [LLMMessage],
    systemPrompt: String?,
    tools: [AgentToolDefinition],
    maxTokens: Int,
    temperature: Double?
) -> Bool {
    guard let keyed = provider as? any StableRequestIdempotencyKeyProvider,
          let key = keyed.stableRequestIdempotencyKey(
              messages: messages,
              systemPrompt: systemPrompt,
              tools: tools,
              maxTokens: maxTokens,
              temperature: temperature
          ) else {
        return false
    }
    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 256 else { return false }
    return value.utf8.allSatisfy { byte in
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
             0x2D, 0x2E, 0x3A, 0x5F:
            return true
        default:
            return false
        }
    }
}

/// Safe terminal error emitted when a buffered provider request may already
/// have reached the remote endpoint.  It carries only a stable category; raw
/// URLSession errors, URLs, headers and response bodies never cross the
/// boundary.
public struct ProviderRequestReplayBlockedError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public enum Code: String, Equatable, Sendable {
        case timedOut
        case connectionLost
    }

    public let code: Code

    public init(code: Code) {
        self.code = code
    }

    public var errorDescription: String? {
        switch code {
        case .timedOut:
            return "Request timed out; it was not retried because delivery status is unknown"
        case .connectionLost:
            return "Connection lost; the request was not retried because delivery status is unknown"
        }
    }

    public var description: String {
        errorDescription ?? "Provider request was not replayed"
    }
}

/// D-PROVIDER-11/12: stable, payload-free classification of provider request
/// failures carried by fallback events and frozen-route observations.
///
/// The classifier only reads typed error signals: `LLMError` cases, HTTP
/// status codes, URLSession transport codes, cancellation markers, replay
/// fences and snapshot provenance errors. Free-form provider text, URLs,
/// headers and response bodies never influence the classification and never
/// cross the observation boundary. Unknown errors fail closed to `nil`
/// (unclassified) instead of being guessed into a category.
public enum ProviderRequestFailureKind: String, Codable, Equatable, Sendable {
    case unconfigured
    case unauthorized
    case permissionDenied
    case notFound
    case rateLimited
    case server
    case timeout
    case cancelled
    case transport

    /// Classify any thrown error into a stable failure kind.
    public static func classify(_ error: Error) -> ProviderRequestFailureKind? {
        if error is CancellationError
            || ProviderCancellationPolicy.isCancellation(error) {
            return .cancelled
        }
        if let llmError = error as? LLMError {
            return classify(llmError)
        }
        if let blocked = error as? ProviderRequestReplayBlockedError {
            return blocked.code == .timedOut ? .timeout : .transport
        }
        if let snapshotError = error as? ProviderRuntimeSnapshotError {
            switch snapshotError {
            case .missingProvider, .missingPrimaryProvenance, .missingFallbackProvenance:
                return .unconfigured
            default:
                return nil
            }
        }
        if let factoryError = error as? ProviderFactory.FactoryError {
            if case .noCredentials = factoryError { return .unconfigured }
        }
        if let transportCodeError = error as? ProviderTransportCodeError {
            switch transportCodeError.code {
            case NSURLErrorCancelled:
                return .cancelled
            case NSURLErrorTimedOut:
                return .timeout
            default:
                return .transport
            }
        }
        if isTransportDomainError(error) {
            let transport = ProviderHTTPErrorAdapter.classify(transport: error)
            if transport.isCancelled {
                return .cancelled
            }
            return kind(forCategory: transport.category)
        }
        return nil
    }

    static func classify(_ llmError: LLMError) -> ProviderRequestFailureKind? {
        if case .cancelled = llmError {
            return .cancelled
        }
        guard let category = llmError.providerFailureCategory else {
            return nil
        }
        return kind(forCategory: category)
    }

    /// HTTP status carried by a typed error, bounded to wire-valid codes.
    public static func httpStatusCode(from error: Error) -> Int? {
        guard let llmError = error as? LLMError,
              case .httpStatus(let code, _) = llmError else {
            return nil
        }
        return (100...599).contains(code) ? code : nil
    }

    static func kind(
        forCategory category: ProviderReadinessFailureCategory
    ) -> ProviderRequestFailureKind {
        switch category {
        case .invalidConfiguration, .missingCredential:
            return .unconfigured
        case .unauthorized:
            return .unauthorized
        case .permissionDenied:
            return .permissionDenied
        case .notFound, .modelNotFound:
            return .notFound
        case .rateLimited:
            return .rateLimited
        case .server, .unavailable:
            return .server
        case .timeout:
            return .timeout
        case .transport, .malformedResponse:
            return .transport
        }
    }

    private static func isTransportDomainError(_ error: Error) -> Bool {
        if error is URLError || error is ProviderTransportCodeError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }
}

/// Boxes a non-Sendable `any LLMProvider` for the retry decorator
/// (same pattern as the App layer's `LLMProviderBox`).
struct RetryingProviderBox: @unchecked Sendable {
    var value: any LLMProvider
}

/// F18b: `LLMProvider` decorator — wraps every call in exponential-backoff
/// retry (`LLMRetryPolicy`), mirroring the `BudgetRecordingProvider`
/// decorator pattern (no engine/provider intrusion).
///
/// - `sendMessage`: the whole call is retried.
/// - `streamMessage`: only stream ACQUISITION is retried; once a stream is
///   created, mid-stream errors are the caller's concern (same discipline as
///   `FallbackRouter.streamMessage`).
/// - A buffered `sendMessage` retry is additionally fenced: timeout and
///   connection-lost errors are not replayed unless the base provider opts
///   into `StableRequestIdempotencyKeyProvider`.
///
/// Retry exhaustion rethrows the LAST error unchanged, so upstream fallback
/// logic (`LLMError.isFallbackable` / `FallbackRouter`) sees the original.
public struct RetryingLLMProvider: UsageRouteIdentityProviding, LLMProvider, StableRequestIdempotencyKeyProvider, Sendable {
    private var baseBox: RetryingProviderBox
    public let policy: LLMRetryPolicy
    /// Optional session-owned budget.  Every retry attempt borrows from this
    /// same tracker so retries cannot reset budget before fallback begins.
    public let requestBudget: BudgetTracker?

    public var usageRouteIdentity: UsageServedRoute? { UsageTelemetryContext.directRoute(of: baseBox.value) }
    public var name: String { baseBox.value.name }
    public var model: LLMModel {
        get { baseBox.value.model }
        set { baseBox.value.model = newValue }
    }
    public var capabilities: Set<ProviderCapability> { baseBox.value.capabilities }

    public func stableRequestIdempotencyKey(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) -> String? {
        guard let keyed = baseBox.value as? any StableRequestIdempotencyKeyProvider else {
            return nil
        }
        return keyed.stableRequestIdempotencyKey(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    public init(
        base: any LLMProvider,
        policy: LLMRetryPolicy = LLMRetryPolicy(),
        requestBudget: BudgetTracker? = nil
    ) {
        self.baseBox = RetryingProviderBox(value: base)
        self.policy = policy
        self.requestBudget = requestBudget
    }

    private func runBudgeted<T>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T,
        usage: @escaping (T) -> LLMUsage? = { _ in nil }
    ) async throws -> T {
        let lease: BudgetRequestLease? = if let requestBudget {
            try await requestBudget.beginRequest(enforceExhaustion: true)
        } else {
            nil
        }
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            if let requestBudget, let lease {
                if let terminalPolicy = await requestBudget.completeRequest(
                    lease,
                    usage: usage(value)
                ), terminalPolicy == .pause {
                    throw BudgetTrackerError.exhausted
                }
            }
            try Task.checkCancellation()
            return value
        } catch {
            if let requestBudget, let lease {
                await requestBudget.failRequest(lease)
            }
            throw error
        }
    }

    public func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let box = baseBox
        let policy = policy
        let allowsAmbiguousReplay = providerHasStableRequestIdempotencyKey(
            baseBox.value,
            messages: messages,
            systemPrompt: systemPrompt,
            tools: [],
            maxTokens: maxTokens,
            temperature: temperature
        )
        return try await policy.run {
            try await self.runBudgeted {
                try await box.value.sendMessage(
                    messages: messages, systemPrompt: systemPrompt,
                    maxTokens: maxTokens, temperature: temperature
                )
            } usage: { $0.usage }
        } shouldRetry: { error in
            !FallbackRouter.isAmbiguousPostDispatchTransport(error)
                || allowsAmbiguousReplay
        }
    }

    public func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let box = baseBox
        let policy = policy
        let allowsAmbiguousReplay = providerHasStableRequestIdempotencyKey(
            baseBox.value,
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature
        )
        return try await policy.run {
            try await self.runBudgeted {
                try await box.value.sendMessage(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    tools: tools,
                    maxTokens: maxTokens,
                    temperature: temperature
                )
            } usage: { $0.usage }
        } shouldRetry: { error in
            !FallbackRouter.isAmbiguousPostDispatchTransport(error)
                || allowsAmbiguousReplay
        }
    }

    public func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let box = baseBox
        let policy = policy
        return try await policy.run {
            try await self.runBudgeted {
                try await box.value.streamMessage(
                    messages: messages, systemPrompt: systemPrompt,
                    maxTokens: maxTokens, temperature: temperature
                )
            }
        }
    }
}

/// 把一条 assistant 事件流拆成"先取第一个事件、再接着转发其余事件"两步，
/// 让主对话重试能在第一个事件到手之前把失败当成建流失败。只有一个消费者，按顺序访问迭代器。
final class AssistantStreamEventSource: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<LLMAssistantStreamEvent, Error>.Iterator

    init(_ stream: AsyncThrowingStream<LLMAssistantStreamEvent, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> LLMAssistantStreamEvent? {
        try await iterator.next()
    }

    /// 第一个事件之后原样转发；调用方取消时连带取消上游流。
    func continuing(after first: LLMAssistantStreamEvent?) -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let first else { continuation.finish(); return }
            let forwarding = Task {
                do {
                    continuation.yield(first)
                    while let event = try await self.next() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in forwarding.cancel() }
        }
    }
}

// D-CHAT-03：assistant 增量流装饰器。遵守与 `streamMessage` 相同的纪律：
// 只对流的「获取」重试，一旦流建立、中途错误归调用方处理。base 不符合
// 流式协议时，合成单 `.completed` 事件并复用本类型自己的缓冲
// `sendMessage(tools:)` 路径 —— 重试退避、POST 幂等回放栅栏、预算语义
// 与今天逐字节一致（零行为变化）。
// 例外：主对话策略（`LLMRetryPolicy.mainConversation`）把"取到第一个事件"也算进获取，
// 第一个事件之前的失败整体重发；第一个事件交出之后仍归调用方，不再重试。
extension RetryingLLMProvider: AssistantStreamingLLMProvider {
    public func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        return try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
    }

    public func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?, thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let box = baseBox
        if let streaming = box.value as? any AssistantStreamingLLMProvider {
            let policy = policy
            if policy.retriesBeforeFirstStreamEvent {
                // 主对话：流刚建好、还没产出任何事件就失败（Anthropic 的流内 overloaded、网关半路断流等），
                // 和建流失败一样整体重发；第一个事件一旦交给调用方就不再重试，已经输出的内容不会重复。
                let (first, source) = try await policy.run {
                    try await self.runBudgeted { () async throws -> (LLMAssistantStreamEvent?, AssistantStreamEventSource) in
                        let stream = try await streaming.streamAssistantMessage(
                            messages: messages,
                            systemPrompt: systemPrompt,
                            tools: tools,
                            maxTokens: maxTokens,
                            temperature: temperature, thinkingLevel: thinkingLevel
                        )
                        let source = AssistantStreamEventSource(stream)
                        let first = try await source.next()
                        return (first, source)
                    }
                }
                return source.continuing(after: first)
            }
            return try await policy.run {
                try await self.runBudgeted {
                    try await streaming.streamAssistantMessage(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        maxTokens: maxTokens,
                        temperature: temperature, thinkingLevel: thinkingLevel
                    )
                }
            }
        }
        let response = try await self.sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature
        )
        return llmAssistantCompletedStream(response)
    }
}

/// Model fallback router.
///
/// Holds an ordered route chain of provider IDs. A request is attempted on the
/// first provider; on failure (timeout, provider error, …) the router
/// automatically moves to the next one, recording every fallback in `events`.
///
/// Port of the group-level fallback discipline in OpenMinis
/// `AIChatViewModel+Fallback`:
/// - The chain is tried strictly in order; a provider already tried is never
///   retried within the same request.
/// - `shouldFallback` lets callers distinguish permanent provider rejection
///   (fallback immediately) from errors that should propagate as-is.
/// - The final error carries the full trail (`FallbackRouterError.allProvidersFailed`).
///
/// B1i wiring status (F18b):
/// - RETRY-BEFORE-FALLBACK is wired: when `retryPolicy` is non-nil, each
///   resolved provider is wrapped in `RetryingLLMProvider` — retryable errors
///   are retried with exponential backoff on that provider until exhaustion;
///   ambiguous buffered POST failures are fail-closed unless the provider
///   supplies a stable request key. Only then does the router fall back to the
///   next provider. `nil` (default) = legacy behavior (no retry).
/// - Provider resolution is still injected via the `factory` closure.
///   TODO(B1i) remainder: a string-ID → ProviderConfig registry so IDs resolve
///   directly through `ProviderFactory`, mirroring `streamWithGroupFallback`'s
///   session-binding update (the serving provider ID is already returned).
public struct FallbackRouter: Sendable {

    /// One recorded fallback attempt.
    public struct FallbackEvent: Codable, Sendable, Equatable {
        public let providerID: String
        public let errorDescription: String
        /// 1-based attempt number within this request.
        public let attempt: Int
        /// D-PROVIDER-11/12: stable typed failure category (D-PROVIDER-11
        /// coverage), or `nil` when the error failed closed to unclassified.
        /// Optional so previously persisted events keep decoding.
        public let failureKind: ProviderRequestFailureKind?
        /// HTTP status that produced the failure, when the typed error
        /// carried one. Bounded to wire-valid codes; `nil` otherwise.
        public let statusCode: Int?

        public init(
            providerID: String,
            errorDescription: String,
            attempt: Int,
            failureKind: ProviderRequestFailureKind? = nil,
            statusCode: Int? = nil
        ) {
            self.providerID = Self.boundedProviderID(providerID)
            self.errorDescription = Self.boundedErrorDescription(errorDescription)
            self.attempt = Self.boundedAttempt(attempt)
            self.failureKind = failureKind
            self.statusCode = Self.boundedStatusCode(statusCode)
        }

        private enum CodingKeys: String, CodingKey {
            case providerID
            case errorDescription
            case attempt
            case failureKind
            case statusCode
        }

        /// Decode through the same projection as programmatic event creation;
        /// persisted or imported route metadata is not trusted merely because
        /// it came from Codable storage. Legacy payloads without the typed
        /// fields decode to `nil` (unclassified), never a guessed category.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                providerID: try container.decode(String.self, forKey: .providerID),
                errorDescription: try container.decode(String.self, forKey: .errorDescription),
                attempt: try container.decode(Int.self, forKey: .attempt),
                failureKind: try container.decodeIfPresent(
                    ProviderRequestFailureKind.self,
                    forKey: .failureKind
                ),
                statusCode: try container.decodeIfPresent(Int.self, forKey: .statusCode)
            )
        }

        /// Status codes are diagnostic metadata, so keep malformed direct
        /// construction or imported payloads from persisting unbounded or
        /// non-wire values while preserving ordinary HTTP codes unchanged.
        private static func boundedStatusCode(_ raw: Int?) -> Int? {
            guard let raw, (100...599).contains(raw) else { return nil }
            return raw
        }

        /// Provider IDs are provenance labels, not a free-form diagnostic
        /// channel. Keep the ordinary registry IDs readable while rejecting
        /// URL/path/query syntax, control characters, and unbounded labels.
        /// Shared with the runtime observation boundary so displayed
        /// provenance uses the same projection as fallback events while the
        /// router keeps its canonical route IDs internally.
        static func boundedProviderID(_ raw: String) -> String {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 128 else {
                return "provider"
            }
            guard value.utf8.allSatisfy({ byte in
                switch byte {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                     0x20, 0x2D, 0x2E, 0x3A, 0x5F:
                    return true
                default:
                    return false
                }
            }) else {
                return "provider"
            }
            return value
        }

        /// Attempt numbers are route metadata, so keep malformed direct
        /// constructions from creating negative or unbounded observation
        /// values while preserving ordinary route attempts unchanged.
        private static func boundedAttempt(_ raw: Int) -> Int {
            min(max(raw, 1), 1_024)
        }

        /// Fallback reasons are user/log surfaces. Keep known short reasons
        /// useful, while rejecting control characters, URL/path syntax,
        /// credential markers, and unbounded imported text.
        private static func boundedErrorDescription(_ raw: String) -> String {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 256 else {
                return "Provider error"
            }
            guard !value.unicodeScalars.contains(where: { scalar in
                scalar.value < 0x20 || scalar.value == 0x7F
            }) else {
                return "Provider error"
            }

            let lowercased = value.lowercased()
            let sensitiveMarkers = [
                "authorization", "proxy-authorization", "bearer", "api_key",
                "apikey", "token", "secret", "password", "credential", "cookie"
            ]
            guard !sensitiveMarkers.contains(where: lowercased.contains),
                  !value.contains("/"),
                  !value.contains("\\"),
                  !value.contains("?"),
                  !value.contains("#") else {
                return "Provider error"
            }
            return value
        }
    }

    /// Ordered route chain. Tried front-to-back.
    public let providerIDs: [String]

    /// Failure trail recorded during the last request(s).
    public private(set) var events: [FallbackEvent] = []
    private(set) var lastRetryExhaustion: ProviderRetryExhaustion?
    var tracksRetryExhaustion = false


    /// Decide whether a thrown error should trigger fallback. Defaults to true
    /// (the plain-text `LLMProvider` protocol has no structured error type, so
    /// every error is treated as fallbackable unless the caller says otherwise).
    public var shouldFallback: @Sendable (Error) -> Bool

    /// F18b (B1i): retry policy applied to each provider BEFORE falling back.
    /// Non-nil → every resolved provider is wrapped in `RetryingLLMProvider`
    /// (exponential backoff, retryable errors only); ambiguous buffered POST
    /// failures require a stable request key. Fallback happens only after
    /// retries are exhausted. `nil` = legacy immediate-fallback behavior.
    public var retryPolicy: LLMRetryPolicy?

    /// Session-owned budget shared by fallback and retry attempts.  The router
    /// never resets this tracker; a later provider only starts when the same
    /// remaining budget still admits it.
    public let requestBudget: BudgetTracker?

    public init(
        providerIDs: [String],
        shouldFallback: @escaping @Sendable (Error) -> Bool = { _ in true },
        retryPolicy: LLMRetryPolicy? = nil,
        requestBudget: BudgetTracker? = nil
    ) {
        self.providerIDs = providerIDs
        self.shouldFallback = shouldFallback
        self.retryPolicy = retryPolicy
        self.requestBudget = requestBudget
    }

    /// Resolve a provider ID to a provider instance.
    ///
    /// TODO(B1i): replace with `ProviderFactory.provider(for:)` once ProviderFactory
    /// lands; until then callers inject resolution via the `factory` parameter.
    public typealias ProviderFactory = @Sendable (String) async throws -> any LLMProvider

    private func runBudgeted<T>(
        operation: () async throws -> T,
        usage: @escaping (T) -> LLMUsage? = { _ in nil }
    ) async throws -> T {
        guard let requestBudget else {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            return value
        }
        let lease = try await requestBudget.beginRequest(enforceExhaustion: true)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            if let terminalPolicy = await requestBudget.completeRequest(
                lease,
                usage: usage(value)
            ), terminalPolicy == .pause {
                throw BudgetTrackerError.exhausted
            }
            try Task.checkCancellation()
            return value
        } catch {
            await requestBudget.failRequest(lease)
            throw error
        }
    }

    private func preflightBudget() async throws {
        try await requestBudget?.checkCanBeginRequest()
        try Task.checkCancellation()
    }

    private func isTerminalBoundary(_ error: Error) -> Bool {
        error is BudgetTrackerError
            || error is ProviderRequestReplayBlockedError
            || Task.isCancelled
            || ProviderCancellationPolicy.isCancellation(error)
    }

    private func terminalError(_ error: Error) -> Error {
        if Task.isCancelled || ProviderCancellationPolicy.isCancellation(error) {
            return CancellationError()
        }
        return error
    }

    /// Keep the fallback trail on the same payload-free surface as provider
    /// errors. A provider implementation supplied by a registry or plugin can
    /// still throw a raw NSError/LocalizedError; copying its localized text
    /// into a durable event would retain URLs, headers, bodies, or paths.
    /// Known provider projections retain their stable user-facing reason, while
    /// unknown errors fail closed to a generic provider failure.
    private static func safeFailureDescription(for error: Error) -> String {
        ProviderErrorDiagnosticProjectionPolicy.project(error)
    }

    /// A timeout or connection loss can happen after URLSession dispatched a
    /// buffered POST.  The transport code is the only accepted input; no
    /// localized text or URL is inspected.
    fileprivate static func isAmbiguousPostDispatchTransport(_ error: Error) -> Bool {
        guard let code = transportCode(from: error) else { return false }
        return code == NSURLErrorTimedOut || code == NSURLErrorNetworkConnectionLost
    }

    /// 请求肯定还没发到服务端的连接失败（连不上主机、解析不了域名、没有网络）。
    /// 只看传输错误码，与 `isAmbiguousPostDispatchTransport` 互斥；证书、TLS 握手失败等
    /// 重试也不会好的不在内。
    fileprivate static func isPreDispatchConnectionFailure(_ error: Error) -> Bool {
        guard let code = transportCode(from: error) else { return false }
        return code == NSURLErrorCannotConnectToHost || code == NSURLErrorCannotFindHost
            || code == NSURLErrorDNSLookupFailed || code == NSURLErrorNotConnectedToInternet
    }

    private static func transportCode(from error: Error, depth: Int = 0) -> Int? {
        guard depth < 4 else { return nil }
        if let urlError = error as? URLError {
            return urlError.code.rawValue
        }
        if let transport = error as? ProviderTransportCodeError {
            return transport.code
        }
        if let llmError = error as? LLMError,
           case .networkError(let underlying) = llmError {
            return transportCode(from: underlying, depth: depth + 1)
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        return nsError.code
    }

    private static func replayBlockedCode(for error: Error) -> ProviderRequestReplayBlockedError.Code? {
        guard let code = transportCode(from: error) else { return nil }
        switch code {
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorNetworkConnectionLost:
            return .connectionLost
        default:
            return nil
        }
    }

    /// 换到下一个供应商（或模型）重试时，清掉历史里的 thinking 块：它们带着上一个
    /// 供应商的签名，发给别的供应商会被拒（Anthropic 要求签名与原模型一致）。
    static func messagesForAttempt(_ messages: [LLMMessage], afterFailure: Bool) -> [LLMMessage] {
        guard afterFailure,
              messages.contains(where: { $0.toolCalls.contains { !$0.thinkingBlocks.isEmpty } })
        else { return messages }
        return messages.map { message in
            var copy = message
            for index in copy.toolCalls.indices { copy.toolCalls[index].thinkingBlocks = [] }
            return copy
        }
    }

    // MARK: - Non-streaming request

    /// Send a message through the chain, falling back on failure.
    ///
    /// - Returns: the successful response plus the provider ID that served it.
    /// - Throws: `FallbackRouterError.allProvidersFailed` when the chain is
    ///   exhausted, or the original error when `shouldFallback` rejects it.
    public mutating func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?,
        factory: ProviderFactory
    ) async throws -> (response: LLMResponse, providerID: String) {
        var tried: Set<String> = []
        var failures: [FallbackEvent] = []

        for providerID in providerIDs {
            guard !tried.contains(providerID) else { continue }
            tried.insert(providerID)
            lastRetryExhaustion = nil
            let messages = Self.messagesForAttempt(messages, afterFailure: !failures.isEmpty)

            var resolvedProvider: (any LLMProvider)?
            do {
                try await preflightBudget()
                // F18b (B1i): retry clear transient errors on this provider
                // with backoff first; the buffered POST fence below refuses
                // ambiguous timeout/connection-loss replay without a key.
                let resolved = try await factory(providerID)
                resolvedProvider = resolved
                let provider: any LLMProvider
                if let policy = retryPolicy {
                    provider = RetryingLLMProvider(
                        base: resolved,
                        policy: tracksRetryExhaustion ? policy.trackingExhaustion() : policy,
                        requestBudget: requestBudget
                    )
                } else {
                    provider = resolved
                }
                let response: LLMResponse
                if retryPolicy == nil {
                    response = try await runBudgeted {
                        try await provider.sendMessage(
                            messages: messages,
                            systemPrompt: systemPrompt,
                            maxTokens: maxTokens,
                            temperature: temperature
                        )
                    } usage: { $0.usage }
                } else {
                    response = try await provider.sendMessage(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )
                }
                return (response, providerID)
            } catch {
                lastRetryExhaustion = error as? ProviderRetryExhaustion
                let error = lastRetryExhaustion?.underlyingError ?? error
                if isTerminalBoundary(error) { throw terminalError(error) }
                if let resolvedProvider,
                   Self.isAmbiguousPostDispatchTransport(error),
                   !providerHasStableRequestIdempotencyKey(
                       resolvedProvider,
                       messages: messages,
                       systemPrompt: systemPrompt,
                       tools: [],
                       maxTokens: maxTokens,
                       temperature: temperature
                   ) {
                    let code = Self.replayBlockedCode(for: error)
                    if let code {
                        throw ProviderRequestReplayBlockedError(code: code)
                    }
                }
                guard shouldFallback(error) else {
                    // Non-fallbackable — propagate the original error untouched.
                    throw error
                }
                let event = FallbackEvent(
                    providerID: providerID,
                    errorDescription: Self.safeFailureDescription(for: error),
                    attempt: failures.count + 1,
                    failureKind: ProviderRequestFailureKind.classify(error),
                    statusCode: ProviderRequestFailureKind.httpStatusCode(from: error)
                )
                failures.append(event)
                events.append(event)
            }
        }

        if providerIDs.isEmpty {
            throw FallbackRouterError.emptyChain
        }
        throw FallbackRouterError.allProvidersFailed(failures)
    }

    /// Send a tools-aware message through the same ordered chain.
    ///
    /// Tool schemas are part of the request contract, so each provider is
    /// called through the protocol requirement rather than falling back to the
    /// plain-text overload (which would silently drop tools).
    public mutating func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?,
        factory: ProviderFactory
    ) async throws -> (response: LLMResponse, providerID: String) {
        var tried: Set<String> = []
        var failures: [FallbackEvent] = []

        for providerID in providerIDs {
            guard !tried.contains(providerID) else { continue }
            tried.insert(providerID)
            lastRetryExhaustion = nil
            let messages = Self.messagesForAttempt(messages, afterFailure: !failures.isEmpty)

            var resolvedProvider: (any LLMProvider)?
            do {
                try await preflightBudget()
                let resolved = try await factory(providerID)
                resolvedProvider = resolved
                let provider: any LLMProvider
                if let policy = retryPolicy {
                    provider = RetryingLLMProvider(
                        base: resolved,
                        policy: tracksRetryExhaustion ? policy.trackingExhaustion() : policy,
                        requestBudget: requestBudget
                    )
                } else {
                    provider = resolved
                }
                let response: LLMResponse
                if retryPolicy == nil {
                    response = try await runBudgeted {
                        try await provider.sendMessage(
                            messages: messages,
                            systemPrompt: systemPrompt,
                            tools: tools,
                            maxTokens: maxTokens,
                            temperature: temperature
                        )
                    } usage: { $0.usage }
                } else {
                    response = try await provider.sendMessage(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )
                }
                return (response, providerID)
            } catch {
                lastRetryExhaustion = error as? ProviderRetryExhaustion
                let error = lastRetryExhaustion?.underlyingError ?? error
                if isTerminalBoundary(error) { throw terminalError(error) }
                if let resolvedProvider,
                   Self.isAmbiguousPostDispatchTransport(error),
                   !providerHasStableRequestIdempotencyKey(
                       resolvedProvider,
                       messages: messages,
                       systemPrompt: systemPrompt,
                       tools: tools,
                       maxTokens: maxTokens,
                       temperature: temperature
                   ) {
                    let code = Self.replayBlockedCode(for: error)
                    if let code {
                        throw ProviderRequestReplayBlockedError(code: code)
                    }
                }
                guard shouldFallback(error) else { throw error }
                let event = FallbackEvent(
                    providerID: providerID,
                    errorDescription: Self.safeFailureDescription(for: error),
                    attempt: failures.count + 1,
                    failureKind: ProviderRequestFailureKind.classify(error),
                    statusCode: ProviderRequestFailureKind.httpStatusCode(from: error)
                )
                failures.append(event)
                events.append(event)
            }
        }

        if providerIDs.isEmpty {
            throw FallbackRouterError.emptyChain
        }
        throw FallbackRouterError.allProvidersFailed(failures)
    }

    // MARK: - Streaming request

    /// Start a stream through the chain. A provider "succeeds" as soon as its
    /// stream is created; mid-stream errors are the caller's concern
    /// (follows OpenMinis's approach: return the stream for upstream consumption).
    public mutating func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?,
        factory: ProviderFactory
    ) async throws -> (stream: AsyncThrowingStream<LLMStreamChunk, Error>, providerID: String) {
        var tried: Set<String> = []
        var failures: [FallbackEvent] = []

        for providerID in providerIDs {
            guard !tried.contains(providerID) else { continue }
            tried.insert(providerID)
            lastRetryExhaustion = nil
            let messages = Self.messagesForAttempt(messages, afterFailure: !failures.isEmpty)

            do {
                try await preflightBudget()
                // F18b (B1i): same retry-before-fallback as sendMessage; only
                // stream ACQUISITION is retried (mid-stream errors are the
                // caller's concern, per the streamMessage contract).
                let resolved = try await factory(providerID)
                let provider: any LLMProvider
                if let policy = retryPolicy {
                    provider = RetryingLLMProvider(
                        base: resolved,
                        policy: tracksRetryExhaustion ? policy.trackingExhaustion() : policy,
                        requestBudget: requestBudget
                    )
                } else {
                    provider = resolved
                }
                let stream: AsyncThrowingStream<LLMStreamChunk, Error>
                if retryPolicy == nil {
                    stream = try await runBudgeted {
                        try await provider.streamMessage(
                            messages: messages,
                            systemPrompt: systemPrompt,
                            maxTokens: maxTokens,
                            temperature: temperature
                        )
                    }
                } else {
                    stream = try await provider.streamMessage(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )
                }
                return (stream, providerID)
            } catch {
                lastRetryExhaustion = error as? ProviderRetryExhaustion
                let error = lastRetryExhaustion?.underlyingError ?? error
                if isTerminalBoundary(error) { throw terminalError(error) }
                guard shouldFallback(error) else { throw error }
                let event = FallbackEvent(
                    providerID: providerID,
                    errorDescription: Self.safeFailureDescription(for: error),
                    attempt: failures.count + 1,
                    failureKind: ProviderRequestFailureKind.classify(error),
                    statusCode: ProviderRequestFailureKind.httpStatusCode(from: error)
                )
                failures.append(event)
                events.append(event)
            }
        }

        if providerIDs.isEmpty {
            throw FallbackRouterError.emptyChain
        }
        throw FallbackRouterError.allProvidersFailed(failures)
    }

    /// D-CHAT-03: tools-aware assistant streaming through the same ordered
    /// chain.
    ///
    /// Providers conforming to `AssistantStreamingLLMProvider` have their real
    /// event stream (live `textDelta`s) forwarded; with a retry policy the
    /// acquisition runs through `RetryingLLMProvider`'s streaming decorator so
    /// retry-before-fallback stays identical to `streamMessage`. Non-conforming
    /// providers keep the buffered `sendMessage` path and synthesize a single
    /// `.completed` event — including the legacy "empty tools uses the no-tools
    /// overload" delegation, the buffered POST replay fence, and budget
    /// semantics — so their behavior stays byte-for-byte what the runtime
    /// route produced before live forwarding existed. As with `streamMessage`,
    /// only stream ACQUISITION participates in fallback; mid-stream errors are
    /// the caller's concern.
    public mutating func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?,
        factory: ProviderFactory
    ) async throws -> (stream: AsyncThrowingStream<LLMAssistantStreamEvent, Error>, providerID: String) {
        return try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil, factory: factory)
    }

    public mutating func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?, thinkingLevel: ThinkingLevel?,
        factory: ProviderFactory
    ) async throws -> (stream: AsyncThrowingStream<LLMAssistantStreamEvent, Error>, providerID: String) {
        var tried: Set<String> = []
        var failures: [FallbackEvent] = []

        for providerID in providerIDs {
            guard !tried.contains(providerID) else { continue }
            tried.insert(providerID)
            lastRetryExhaustion = nil
            let messages = Self.messagesForAttempt(messages, afterFailure: !failures.isEmpty)

            var resolvedProvider: (any LLMProvider)?
            var streamingAcquisition = false
            do {
                try await preflightBudget()
                let resolved = try await factory(providerID)
                resolvedProvider = resolved
                if let baseStreaming = resolved as? any AssistantStreamingLLMProvider {
                    streamingAcquisition = true
                    let provider: any AssistantStreamingLLMProvider
                    if let policy = retryPolicy {
                        // The decorator forwards the inner real stream and
                        // keeps retry/budget discipline on the acquisition.
                        provider = RetryingLLMProvider(
                            base: baseStreaming,
                            policy: tracksRetryExhaustion ? policy.trackingExhaustion() : policy,
                            requestBudget: requestBudget
                        )
                    } else {
                        provider = baseStreaming
                    }
                    let stream: AsyncThrowingStream<LLMAssistantStreamEvent, Error>
                    if retryPolicy == nil {
                        stream = try await runBudgeted {
                            try await provider.streamAssistantMessage(
                                messages: messages,
                                systemPrompt: systemPrompt,
                                tools: tools,
                                maxTokens: maxTokens,
                                temperature: temperature, thinkingLevel: thinkingLevel
                            )
                        }
                    } else {
                        stream = try await provider.streamAssistantMessage(
                            messages: messages,
                            systemPrompt: systemPrompt,
                            tools: tools,
                            maxTokens: maxTokens,
                            temperature: temperature, thinkingLevel: thinkingLevel
                        )
                    }
                    return (stream, providerID)
                }
                // Non-conforming: buffered synthesis, identical to the
                // legacy runtime-route assistant-stream behavior.
                let provider: any LLMProvider
                if let policy = retryPolicy {
                    provider = RetryingLLMProvider(
                        base: resolved,
                        policy: tracksRetryExhaustion ? policy.trackingExhaustion() : policy,
                        requestBudget: requestBudget
                    )
                } else {
                    provider = resolved
                }
                let response: LLMResponse
                if retryPolicy == nil {
                    response = try await runBudgeted {
                        if tools.isEmpty {
                            try await provider.sendMessage(
                                messages: messages,
                                systemPrompt: systemPrompt,
                                maxTokens: maxTokens,
                                temperature: temperature
                            )
                        } else {
                            try await provider.sendMessage(
                                messages: messages,
                                systemPrompt: systemPrompt,
                                tools: tools,
                                maxTokens: maxTokens,
                                temperature: temperature
                            )
                        }
                    } usage: { $0.usage }
                } else if tools.isEmpty {
                    response = try await provider.sendMessage(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )
                } else {
                    response = try await provider.sendMessage(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )
                }
                return (llmAssistantCompletedStream(response), providerID)
            } catch {
                lastRetryExhaustion = error as? ProviderRetryExhaustion
                let error = lastRetryExhaustion?.underlyingError ?? error
                if isTerminalBoundary(error) { throw terminalError(error) }
                // The buffered POST replay fence belongs to the buffered
                // path only; stream acquisition failures fall back exactly
                // like `streamMessage` (no fence there today).
                if !streamingAcquisition, let resolvedProvider,
                   Self.isAmbiguousPostDispatchTransport(error),
                   !providerHasStableRequestIdempotencyKey(
                       resolvedProvider,
                       messages: messages,
                       systemPrompt: systemPrompt,
                       tools: tools,
                       maxTokens: maxTokens,
                       temperature: temperature
                   ) {
                    let code = Self.replayBlockedCode(for: error)
                    if let code {
                        throw ProviderRequestReplayBlockedError(code: code)
                    }
                }
                guard shouldFallback(error) else { throw error }
                let event = FallbackEvent(
                    providerID: providerID,
                    errorDescription: Self.safeFailureDescription(for: error),
                    attempt: failures.count + 1,
                    failureKind: ProviderRequestFailureKind.classify(error),
                    statusCode: ProviderRequestFailureKind.httpStatusCode(from: error)
                )
                failures.append(event)
                events.append(event)
            }
        }

        if providerIDs.isEmpty {
            throw FallbackRouterError.emptyChain
        }
        throw FallbackRouterError.allProvidersFailed(failures)
    }

}
