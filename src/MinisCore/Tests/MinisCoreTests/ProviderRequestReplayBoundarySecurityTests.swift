import Foundation
import Testing
@testable import MinisCore

private final class Provider38Fixture: LLMProvider, StableRequestIdempotencyKeyProvider, AssistantStreamingLLMProvider, @unchecked Sendable {
    let name = "provider-38-fixture"
    var model = LLMModel(id: "provider-38-model", displayName: "Provider 38", provider: "provider-38")
    let capabilities: Set<ProviderCapability> = [.tools, .streaming]

    private let lock = NSLock()
    private var _sendCalls = 0
    private let firstError: Error?
    private let stableKey: String?

    init(firstError: Error? = nil, stableKey: String? = nil) {
        self.firstError = firstError
        self.stableKey = stableKey
    }

    var sendCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _sendCalls
    }

    private func nextCall() -> Int {
        lock.lock()
        _sendCalls += 1
        let call = _sendCalls
        lock.unlock()
        return call
    }

    func stableRequestIdempotencyKey(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) -> String? {
        stableKey
    }

    private func response() async throws -> LLMResponse {
        if nextCall() == 1, let firstError {
            throw firstError
        }
        return LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await response()
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await response()
    }

    func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let completed = try await response()
        return llmAssistantCompletedStream(completed)
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

/// Provider-39-only mock for the capability contract.  The deterministic key
/// is derived from the complete logical request so a provider can bind the
/// same value to its documented server idempotency header.  This fixture does
/// not claim that any production adapter currently has that server contract.
private final class Provider39ServerKeyFixture: LLMProvider, StableRequestIdempotencyKeyProvider, @unchecked Sendable {
    let name = "provider-39-server-key-fixture"
    var model = LLMModel(id: "provider-39-model", displayName: "Provider 39", provider: "provider-39")
    let capabilities: Set<ProviderCapability> = [.tools]

    func stableRequestIdempotencyKey(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) -> String? {
        let identity = [
            model.id,
            systemPrompt ?? "<nil>",
            messages.map { "\($0.role.rawValue):\($0.content)" }.joined(separator: "|"),
            tools.map(\.name).joined(separator: "|"),
            String(maxTokens, radix: 10),
            temperature.map { String(describing: $0) } ?? "<nil>",
        ].joined(separator: "\u{001F}")

        var digest: UInt64 = 14695981039346656037
        for byte in identity.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1099511628211
        }
        return "mock-server-\(String(digest, radix: 16))"
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "ok", stopReason: "stop", usage: nil)
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

@Suite("Provider request replay boundary security", .serialized)
struct ProviderRequestReplayBoundarySecurityTests {
    private let timeout: Error = LLMError.networkError(
        underlying: ProviderTransportCodeError(code: NSURLErrorTimedOut)
    )

    private let tools = [
        AgentToolDefinition(
            name: "fixture_tool",
            description: "fixture",
            parameters: [:],
            required: []
        )
    ]

    private func retryPolicy(maxRetries: Int = 2) -> LLMRetryPolicy {
        LLMRetryPolicy(
            maxRetries: maxRetries,
            backoff: { _ in .zero },
            sleeper: { _ in }
        )
    }

    @Test("retry operation preserves caller actor before and after backoff")
    @MainActor
    func retryOperationRetainsCallerIsolation() async throws {
        var attempts = 0
        let value = try await retryPolicy(maxRetries: 1).run {
            MainActor.preconditionIsolated()
            attempts += 1
            if attempts == 1 { throw LLMError.transientError(message: "synthetic retry") }
            return attempts
        }
        #expect(value == 2)
        #expect(attempts == 2)
    }

    @Test("assistant stream acquisition retries once and publishes one terminal")
    @MainActor
    func assistantStreamAcquisitionUsesRetryOperation() async throws {
        let fixture = Provider38Fixture(firstError: LLMError.transientError(message: "synthetic retry"))
        let provider = RetryingLLMProvider(base: fixture, policy: retryPolicy(maxRetries: 1))
        let stream = try await provider.streamAssistantMessage(
            messages: [LLMMessage(role: .user, content: "fixture")], systemPrompt: nil,
            tools: tools, maxTokens: 32, temperature: nil
        )
        var terminalTexts: [String] = []
        for try await event in stream {
            if case .completed(let response) = event { terminalTexts.append(response.text) }
        }
        #expect(fixture.sendCalls == 2)
        #expect(terminalTexts == ["ok"])
    }

    @Test("ambiguous buffered POST is not retried without a stable key")
    func ambiguousPlainPostDoesNotRetry() async {
        let fixture = Provider38Fixture(firstError: timeout)
        let provider = RetryingLLMProvider(base: fixture, policy: retryPolicy())

        do {
            _ = try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "fixture")],
                systemPrompt: nil,
                maxTokens: 32,
                temperature: nil
            )
            Issue.record("expected ambiguous request failure")
        } catch {
            #expect(error is LLMError)
        }
        #expect(fixture.sendCalls == 1)
    }

    @Test("ambiguous buffered POST does not fallback without a stable key")
    func ambiguousPlainPostDoesNotFallback() async {
        let primary = Provider38Fixture(firstError: timeout)
        let backup = Provider38Fixture()
        var router = FallbackRouter(providerIDs: ["primary", "backup"])

        do {
            _ = try await router.sendMessage(
                messages: [LLMMessage(role: .user, content: "fixture")],
                systemPrompt: nil,
                maxTokens: 32,
                temperature: nil
            ) { id in
                id == "primary" ? primary : backup
            }
            Issue.record("expected replay fence")
        } catch let error as ProviderRequestReplayBlockedError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("expected replay blocked error, got \(error)")
        }

        #expect(primary.sendCalls == 1)
        #expect(backup.sendCalls == 0)
        #expect(router.events.isEmpty)
    }

    @Test("connection-lost buffered POST is terminal without a stable key")
    func connectionLostPostIsTerminal() async {
        let primary = Provider38Fixture(
            firstError: LLMError.networkError(
                underlying: ProviderTransportCodeError(code: NSURLErrorNetworkConnectionLost)
            )
        )
        let backup = Provider38Fixture()
        var router = FallbackRouter(providerIDs: ["primary", "backup"])

        do {
            _ = try await router.sendMessage(
                messages: [LLMMessage(role: .user, content: "fixture")],
                systemPrompt: nil,
                maxTokens: 32,
                temperature: nil
            ) { id in
                id == "primary" ? primary : backup
            }
            Issue.record("expected replay fence")
        } catch let error as ProviderRequestReplayBlockedError {
            #expect(error.code == .connectionLost)
        } catch {
            Issue.record("expected replay blocked error, got \(error)")
        }

        #expect(primary.sendCalls == 1)
        #expect(backup.sendCalls == 0)
        #expect(router.events.isEmpty)
    }

    @Test("ambiguous tools POST does not retry or fallback without a stable key")
    func ambiguousToolsPostDoesNotRetryOrFallback() async {
        let primary = Provider38Fixture(firstError: timeout)
        let backup = Provider38Fixture()
        var router = FallbackRouter(
            providerIDs: ["primary", "backup"],
            retryPolicy: retryPolicy()
        )

        do {
            _ = try await router.sendMessage(
                messages: [LLMMessage(role: .user, content: "fixture")],
                systemPrompt: nil,
                tools: tools,
                maxTokens: 32,
                temperature: nil
            ) { id in
                id == "primary" ? primary : backup
            }
            Issue.record("expected replay fence")
        } catch let error as ProviderRequestReplayBlockedError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("expected replay blocked error, got \(error)")
        }

        #expect(primary.sendCalls == 1)
        #expect(backup.sendCalls == 0)
        #expect(router.events.isEmpty)
    }

    @Test("provider opt-in stable key permits same-request retry")
    func stableKeyPermitsRetry() async throws {
        let fixture = Provider38Fixture(firstError: timeout, stableKey: "p38-req-1")
        let provider = RetryingLLMProvider(base: fixture, policy: retryPolicy(maxRetries: 1))

        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "fixture")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )

        #expect(response.text == "ok")
        #expect(fixture.sendCalls == 2)
    }

    @Test("clear pre-dispatch connection refusal retains retry")
    func preDispatchRefusalCanRetry() async throws {
        let fixture = Provider38Fixture(
            firstError: LLMError.networkError(
                underlying: ProviderTransportCodeError(code: NSURLErrorCannotConnectToHost)
            )
        )
        let provider = RetryingLLMProvider(base: fixture, policy: retryPolicy(maxRetries: 1))

        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "fixture")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )

        #expect(response.text == "ok")
        #expect(fixture.sendCalls == 2)
    }

    @Test("explicit HTTP refusal retains ordinary fallback")
    func explicitRefusalCanFallback() async throws {
        let primary = Provider38Fixture(firstError: LLMError.httpStatus(code: 401, detail: ""))
        let backup = Provider38Fixture()
        var router = FallbackRouter(providerIDs: ["primary", "backup"])

        let result = try await router.sendMessage(
            messages: [LLMMessage(role: .user, content: "fixture")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        ) { id in
            id == "primary" ? primary : backup
        }

        #expect(result.providerID == "backup")
        #expect(primary.sendCalls == 1)
        #expect(backup.sendCalls == 1)
        #expect(router.events.count == 1)
    }

    @Test("replay-blocked diagnostics stay payload-free")
    func replayBlockedDiagnosticIsSafe() {
        let error = ProviderRequestReplayBlockedError(code: .connectionLost)
        let projected = ProviderErrorDiagnosticProjectionPolicy.project(error)

        #expect(projected == error.errorDescription)
        #expect(!projected.contains("http"))
        #expect(!projected.contains("/"))
        #expect(!projected.contains("token"))
    }

    @Test("mock server idempotency key is stable per logical request only")
    func mockServerKeyBindsLogicalRequestIdentity() {
        let fixture = Provider39ServerKeyFixture()
        let first = [LLMMessage(role: .user, content: "same logical request")]
        let same = [LLMMessage(role: .user, content: "same logical request")]
        let different = [LLMMessage(role: .user, content: "different logical request")]

        let firstKey = fixture.stableRequestIdempotencyKey(
            messages: first,
            systemPrompt: "system",
            tools: tools,
            maxTokens: 32,
            temperature: nil
        )
        let sameKey = fixture.stableRequestIdempotencyKey(
            messages: same,
            systemPrompt: "system",
            tools: tools,
            maxTokens: 32,
            temperature: nil
        )
        let differentKey = fixture.stableRequestIdempotencyKey(
            messages: different,
            systemPrompt: "system",
            tools: tools,
            maxTokens: 32,
            temperature: nil
        )

        #expect(firstKey == sameKey)
        #expect(firstKey != differentKey)
        #expect(firstKey?.hasPrefix("mock-server-") == true)
    }

    @Test("production adapters without a verified server contract remain fail-closed")
    func productionAdaptersDoNotClaimServerIdempotency() {
        let openAI = OpenAICompatibleProvider(apiKey: "fixture-provider-key")
        let anthropic = AnthropicProvider(apiKey: "fixture-provider-key")
        let deepSeek = DeepSeekProvider(apiKey: "fixture-provider-key")
        let dashScope = DashScopeProvider(apiKey: "fixture-provider-key")

        #expect(!(openAI is any StableRequestIdempotencyKeyProvider))
        #expect(!(anthropic is any StableRequestIdempotencyKeyProvider))
        #expect(!(deepSeek is any StableRequestIdempotencyKeyProvider))
        #expect(!(dashScope is any StableRequestIdempotencyKeyProvider))
    }
}
