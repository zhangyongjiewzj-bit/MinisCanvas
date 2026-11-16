import Foundation
import Testing
@testable import MinisCore

private struct Provider26LeakyError: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "Authorization: Bearer fixture-provider-secret body=/private/tmp/provider.json?token=fixture-query-secret"
    }
}

private struct Provider26ThrowingProvider: LLMProvider, Sendable {
    let name = "fixture-provider"
    var model = LLMModel(
        id: "fixture-model",
        displayName: "Fixture Model",
        provider: "fixture-provider"
    )
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        throw Provider26LeakyError()
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        throw Provider26LeakyError()
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw Provider26LeakyError()
    }
}

@Suite("Fallback router provider identity security", .serialized)
struct FallbackRouterProviderIdentitySecurityTests {
    private static let messages = [LLMMessage(role: .user, content: "fixture")]
    private static let unsafeProviderID =
        "provider://Bearer fixture-provider-secret/path?token=fixture-query-secret"

    private static func providerFactory(
        _: String
    ) async throws -> any LLMProvider {
        Provider26ThrowingProvider()
    }

    private static func assertNoSensitiveText(_ value: String) {
        #expect(!value.contains("fixture-provider-secret"))
        #expect(!value.contains("fixture-query-secret"))
        #expect(!value.contains("Authorization"))
        #expect(!value.contains("/private/tmp/provider.json"))
        #expect(!value.contains("provider://"))
    }

    @Test("plain fallback event bounds unsafe provider identity")
    func plainFallbackBoundsProviderID() async {
        var router = FallbackRouter(providerIDs: [Self.unsafeProviderID])
        do {
            _ = try await router.sendMessage(
                messages: Self.messages,
                systemPrompt: nil,
                maxTokens: 8,
                temperature: nil,
                factory: Self.providerFactory
            )
            Issue.record("expected provider failure")
        } catch let error as FallbackRouterError {
            guard case .allProvidersFailed(let events) = error,
                  let event = events.first else {
                Issue.record("expected one fallback event")
                return
            }
            #expect(event.providerID == "provider")
            #expect(event.errorDescription == "Provider error")
            Self.assertNoSensitiveText(error.localizedDescription)
        } catch {
            Issue.record("expected FallbackRouterError, got \(error)")
        }
    }

    @Test("valid registry identity remains readable")
    func validProviderIDRemainsStable() {
        let event = FallbackRouter.FallbackEvent(
            providerID: "Google Gemini",
            errorDescription: "Provider error",
            attempt: 1
        )
        #expect(event.providerID == "Google Gemini")
    }

    @Test("long identity is bounded without exposing its suffix")
    func longProviderIDIsBounded() {
        let event = FallbackRouter.FallbackEvent(
            providerID: String(repeating: "x", count: 129),
            errorDescription: "Provider error",
            attempt: 1
        )
        #expect(event.providerID == "provider")
        Self.assertNoSensitiveText(event.providerID)
    }
}
