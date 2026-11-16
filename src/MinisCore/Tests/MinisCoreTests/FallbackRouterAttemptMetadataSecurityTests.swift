import Foundation
import Testing
@testable import MinisCore

private struct Provider27FailingProvider: LLMProvider, Sendable {
    let name = "fixture-provider"
    var model = LLMModel(
        id: "fixture-model",
        displayName: "Fixture Model",
        provider: "fixture-provider"
    )
    let capabilities: Set<ProviderCapability> = []

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        throw LLMError.providerError(message: "fixture failure")
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        throw LLMError.providerError(message: "fixture failure")
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.providerError(message: "fixture failure")
    }
}

@Suite("Fallback router attempt metadata security", .serialized)
struct FallbackRouterAttemptMetadataSecurityTests {
    @Test("attempt metadata is positive and bounded")
    func directAttemptMetadataIsBounded() {
        let lower = FallbackRouter.FallbackEvent(
            providerID: "fixture-provider",
            errorDescription: "Provider error",
            attempt: Int.min
        )
        let zero = FallbackRouter.FallbackEvent(
            providerID: "fixture-provider",
            errorDescription: "Provider error",
            attempt: 0
        )
        let upper = FallbackRouter.FallbackEvent(
            providerID: "fixture-provider",
            errorDescription: "Provider error",
            attempt: Int.max
        )

        #expect(lower.attempt == 1)
        #expect(zero.attempt == 1)
        #expect(upper.attempt == 1_024)
    }

    @Test("real fallback route keeps ordinary attempt order")
    func routeAttemptsRemainStable() async {
        var router = FallbackRouter(providerIDs: ["primary", "backup"])
        do {
            _ = try await router.sendMessage(
                messages: [LLMMessage(role: .user, content: "fixture")],
                systemPrompt: nil,
                maxTokens: 8,
                temperature: nil,
                factory: { _ in Provider27FailingProvider() }
            )
            Issue.record("expected fallback failure")
        } catch let error as FallbackRouterError {
            guard case .allProvidersFailed(let events) = error else {
                Issue.record("expected allProvidersFailed")
                return
            }
            #expect(events.map(\.providerID) == ["primary", "backup"])
            #expect(events.map(\.attempt) == [1, 2])
        } catch {
            Issue.record("expected FallbackRouterError, got \(error)")
        }
    }
}
