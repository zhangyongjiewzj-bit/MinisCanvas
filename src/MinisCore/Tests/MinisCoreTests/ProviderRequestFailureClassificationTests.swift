import Foundation
import Testing
@testable import MinisCore

/// W4-PROVIDER-ERROR-CLASS-037 — D-PROVIDER-11/12 focused tests.
///
/// D-PROVIDER-11: "请求失败时能区分未配置、401/403、404、429、5xx、超时和取消"
/// D-PROVIDER-12: "fallback 发生时能看到原 Provider、失败原因和最终 route"
/// (issues/三期初期合拢-App逐项功能验收清单-20260826.md:246-247)
///
/// These tests pin the typed, payload-free failure classification on the
/// fallback trail AND the frozen-route observation, plus the D-CHAT-03
/// assistant-stream forwarding seam of `ProviderRuntimeRoute` (the runtime
/// route must forward a real streaming provider's incremental events instead
/// of always synthesizing a single `.completed` placeholder).
@Suite("D-PROVIDER-11/12 provider request failure classification")
struct ProviderRequestFailureClassificationTests {

    // MARK: - D-PROVIDER-11: stable typed classification (payload-free)

    @Test("classify maps typed LLM errors to stable failure kinds")
    func classifyTypedLLMErrors() {
        #expect(ProviderRequestFailureKind.classify(
            LLMError.httpStatus(code: 401, detail: "Bearer sk-secret https://x/y?k=v")
        ) == .unauthorized)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.httpStatus(code: 403, detail: "forbidden")
        ) == .permissionDenied)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.httpStatus(code: 404, detail: "no model")
        ) == .notFound)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.httpStatus(code: 408, detail: "req timeout")
        ) == .timeout)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.httpStatus(code: 429, detail: "slow down")
        ) == .rateLimited)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.httpStatus(code: 500, detail: "boom")
        ) == .server)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.httpStatus(code: 503, detail: "unavailable")
        ) == .server)
        // "未配置" is distinguishable from transport/server failures.
        #expect(ProviderRequestFailureKind.classify(
            LLMError.httpStatus(code: 400, detail: "bad config")
        ) == .unconfigured)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.invalidAPIKey(detail: "")
        ) == .unauthorized)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.rateLimited
        ) == .rateLimited)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.transientError(message: "later")
        ) == .server)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.cancelled
        ) == .cancelled)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.networkError(underlying: URLError(.timedOut))
        ) == .timeout)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.networkError(underlying: URLError(.cannotConnectToHost))
        ) == .transport)
    }

    @Test("classify maps transport, cancellation and unconfigured signals without inspecting text")
    func classifyTransportAndUnconfiguredSignals() {
        #expect(ProviderRequestFailureKind.classify(CancellationError()) == .cancelled)
        #expect(ProviderRequestFailureKind.classify(URLError(.cancelled)) == .cancelled)
        #expect(ProviderRequestFailureKind.classify(
            ProviderTransportCodeError(code: NSURLErrorCancelled)
        ) == .cancelled)
        #expect(ProviderRequestFailureKind.classify(
            ProviderTransportCodeError(code: NSURLErrorTimedOut)
        ) == .timeout)
        #expect(ProviderRequestFailureKind.classify(
            ProviderTransportCodeError(code: NSURLErrorCannotConnectToHost)
        ) == .transport)
        #expect(ProviderRequestFailureKind.classify(
            ProviderRequestReplayBlockedError(code: .timedOut)
        ) == .timeout)
        #expect(ProviderRequestFailureKind.classify(
            ProviderRequestReplayBlockedError(code: .connectionLost)
        ) == .transport)
        #expect(ProviderRequestFailureKind.classify(
            ProviderRuntimeSnapshotError.missingProvider("primary")
        ) == .unconfigured)
        #expect(ProviderRequestFailureKind.classify(
            ProviderRuntimeSnapshotError.missingPrimaryProvenance
        ) == .unconfigured)
        // Fail-closed: unknown errors and free-form provider text are NOT
        // guessed into a stable kind.
        struct StrangerError: Error {}
        #expect(ProviderRequestFailureKind.classify(StrangerError()) == nil)
        #expect(ProviderRequestFailureKind.classify(
            NSError(domain: "com.example.other", code: 42)
        ) == nil)
        #expect(ProviderRequestFailureKind.classify(
            LLMError.providerError(message: "401 say what")
        ) == nil)
    }

    // MARK: - D-PROVIDER-12: typed reason on the fallback trail

    @Test("FallbackRouter records typed failure kind and status code per attempt")
    func fallbackRouterRecordsTypedEvents() async throws {
        let primary = BufferedFakeProvider(name: "primary", responseText: "p", error: LLMError.httpStatus(code: 401, detail: "nope"))
        let backup = BufferedFakeProvider(name: "backup", responseText: "b", error: nil)
        var router = FallbackRouter(providerIDs: ["primary", "backup"])
        let factory: FallbackRouter.ProviderFactory = { id in
            id == "primary" ? primary : backup
        }
        let result = try await router.sendMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil,
            factory: factory
        )
        #expect(result.providerID == "backup")
        #expect(router.events.count == 1)
        #expect(router.events[0].providerID == "primary")
        #expect(router.events[0].failureKind == .unauthorized)
        #expect(router.events[0].statusCode == 401)
        #expect(router.events[0].attempt == 1)
    }

    @Test("allProvidersFailed trail carries typed kinds")
    func allProvidersFailedCarriesTypedKinds() async throws {
        let a = BufferedFakeProvider(name: "a", responseText: "x", error: LLMError.httpStatus(code: 429, detail: "rate"))
        let b = BufferedFakeProvider(name: "b", responseText: "y", error: LLMError.invalidAPIKey(detail: ""))
        var router = FallbackRouter(providerIDs: ["a", "b"])
        await #expect(throws: FallbackRouterError.self) {
            _ = try await router.sendMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                maxTokens: 32,
                temperature: nil,
                factory: { id in id == "a" ? a : b }
            )
        }
        #expect(router.events.map(\.failureKind) == [.rateLimited, .unauthorized])
        #expect(router.events.map(\.statusCode) == [429, nil])
    }

    // MARK: - Codable backward compatibility for persisted route metadata

    @Test("legacy persisted FallbackEvent and attempt decode with nil typed fields")
    func legacyCodableBackCompat() throws {
        let legacyEvent = Data(
            #"{"providerID":"primary","errorDescription":"boom","attempt":1}"#.utf8
        )
        let event = try JSONDecoder().decode(FallbackRouter.FallbackEvent.self, from: legacyEvent)
        #expect(event.failureKind == nil)
        #expect(event.statusCode == nil)

        let typed = FallbackRouter.FallbackEvent(
            providerID: "primary",
            errorDescription: "boom",
            attempt: 1,
            failureKind: .notFound,
            statusCode: 404
        )
        let roundTrip = try JSONDecoder().decode(
            FallbackRouter.FallbackEvent.self,
            from: JSONEncoder().encode(typed)
        )
        #expect(roundTrip == typed)

        let legacyAttempt = Data(
            #"{"providerID":"primary","attempt":1,"failureDescription":"boom"}"#.utf8
        )
        let attempt = try JSONDecoder().decode(ProviderRuntimeRouteAttempt.self, from: legacyAttempt)
        #expect(attempt.failureKind == nil)
        #expect(attempt.statusCode == nil)
        #expect(attempt.failureDescription == "boom")

        // Malformed status codes never survive the boundary.
        let absurd = FallbackRouter.FallbackEvent(
            providerID: "primary",
            errorDescription: "boom",
            attempt: 1,
            failureKind: .server,
            statusCode: 999_999
        )
        #expect(absurd.statusCode == nil)
    }

    // MARK: - D-PROVIDER-12: frozen route observation exposes typed reason + final route

    @Test("runtime route observation carries typed per-attempt failure and final route")
    @MainActor
    func routeObservationCarriesTypedAttempts() async throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "mock-primary",
            applyReceiptID: "provider-readiness-apply:primary",
            fallbackProvenance: [
                ProviderRuntimeFallback(
                    providerID: "backup-a",
                    modelID: "backup-a-model",
                    readinessEvidenceID: "mock-backup-a",
                    applyReceiptID: "provider-readiness-apply:backup-a"
                ),
                ProviderRuntimeFallback(
                    providerID: "backup-b",
                    modelID: "backup-b-model",
                    readinessEvidenceID: "mock-backup-b",
                    applyReceiptID: "provider-readiness-apply:backup-b"
                ),
            ]
        )
        let probe = RouteObservationProbe()
        let route = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: BufferedFakeProvider(
                name: "primary",
                modelID: "primary-model",
                responseText: "p",
                error: LLMError.httpStatus(code: 401, detail: "key rejected")
            ),
            fallbacks: [
                BufferedFakeProvider(
                    name: "backup-a",
                    modelID: "backup-a-model",
                    responseText: "a",
                    error: LLMError.httpStatus(code: 404, detail: "model gone")
                ),
                BufferedFakeProvider(
                    name: "backup-b",
                    modelID: "backup-b-model",
                    responseText: "b",
                    error: nil
                ),
            ],
            observationSink: { observation in probe.record(observation) }
        )
        let response = try await route.sendMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )
        #expect(response.text == "b")

        let observation = try #require(probe.value)
        // 原 Provider、失败原因（typed）和最终 route 都可见。
        #expect(observation.servedProviderID == "backup-b")
        #expect(observation.status == .served)
        #expect(observation.attempts.count == 3)
        #expect(observation.attempts[0].providerID == "primary")
        #expect(observation.attempts[0].failureKind == .unauthorized)
        #expect(observation.attempts[0].statusCode == 401)
        #expect(observation.attempts[1].failureKind == .notFound)
        #expect(observation.attempts[1].statusCode == 404)
        #expect(observation.attempts[2].succeeded)
        #expect(observation.attempts[2].failureKind == nil)
        #expect(observation.fallbackEvents.map(\.failureKind) == [.unauthorized, .notFound])

        // Persisted observations keep the typed fields through Codable.
        let decoded = try JSONDecoder().decode(
            ProviderRuntimeRouteObservation.self,
            from: JSONEncoder().encode(observation)
        )
        #expect(decoded == observation)
    }

}

// MARK: - Test doubles

private final class BufferedFakeProvider: LLMProvider, @unchecked Sendable {
    let name: String
    var model: LLMModel
    let responseText: String
    let error: Error?
    private(set) var sendCalls = 0

    init(name: String, modelID: String? = nil, responseText: String, error: Error?) {
        self.name = name
        let id = modelID ?? "\(name)-model"
        self.model = LLMModel(id: id, displayName: id, provider: name)
        self.responseText = responseText
        self.error = error
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        sendCalls += 1
        if let error { throw error }
        return LLMResponse(text: responseText, stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class RouteObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ProviderRuntimeRouteObservation?

    var value: ProviderRuntimeRouteObservation? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ observation: ProviderRuntimeRouteObservation) {
        lock.lock()
        storedValue = observation
        lock.unlock()
    }
}
