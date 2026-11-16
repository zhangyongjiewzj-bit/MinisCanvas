import Foundation
import Testing
@testable import MinisCore

private struct Provider25LeakyError: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "Authorization: Bearer fixture-provider-secret body=/private/tmp/provider-response.json?token=fixture-query-secret"
    }
}

private struct Provider25ThrowingProvider: LLMProvider, Sendable {
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
        throw Provider25LeakyError()
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        throw Provider25LeakyError()
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw Provider25LeakyError()
    }
}

@Suite("Fallback router failure projection security", .serialized)
struct FallbackRouterFailureProjectionSecurityTests {
    private static let messages = [LLMMessage(role: .user, content: "fixture")]

    private static func providerFactory(
        _: String
    ) async throws -> any LLMProvider {
        Provider25ThrowingProvider()
    }

    private static func assertSafe(_ error: Error) {
        assertSafeText(error.localizedDescription)
        assertSafeText(String(describing: error))
    }

    private static func assertSafeText(_ value: String) {
        let surfaces = [value]
        #expect(surfaces.allSatisfy {
            !$0.contains("fixture-provider-secret")
                && !$0.contains("fixture-query-secret")
                && !$0.contains("Authorization")
                && !$0.contains("/private/tmp/provider-response.json")
        })
    }

    @Test("plain fallback trail rejects raw provider diagnostics")
    func plainFailureIsPayloadFree() async {
        var router = FallbackRouter(providerIDs: ["fixture-provider"])
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
            #expect(event.errorDescription == "Provider error")
            Self.assertSafe(error)
            Self.assertSafeText(event.errorDescription)
        } catch {
            Issue.record("expected FallbackRouterError, got (error)")
        }
    }

    @Test("tools fallback trail rejects raw provider diagnostics")
    func toolsFailureIsPayloadFree() async {
        var router = FallbackRouter(providerIDs: ["fixture-provider"])
        let tools = [
            AgentToolDefinition(
                name: "fixture_tool",
                description: "fixture",
                parameters: [:],
                required: []
            )
        ]
        do {
            _ = try await router.sendMessage(
                messages: Self.messages,
                systemPrompt: nil,
                tools: tools,
                maxTokens: 8,
                temperature: nil,
                factory: Self.providerFactory
            )
            Issue.record("expected tools provider failure")
        } catch let error as FallbackRouterError {
            guard case .allProvidersFailed(let events) = error,
                  let event = events.first else {
                Issue.record("expected one tools fallback event")
                return
            }
            #expect(event.errorDescription == "Provider error")
            Self.assertSafe(error)
        } catch {
            Issue.record("expected tools FallbackRouterError, got (error)")
        }
    }

    @Test("stream fallback trail rejects raw provider diagnostics")
    func streamFailureIsPayloadFree() async {
        var router = FallbackRouter(providerIDs: ["fixture-provider"])
        do {
            _ = try await router.streamMessage(
                messages: Self.messages,
                systemPrompt: nil,
                maxTokens: 8,
                temperature: nil,
                factory: Self.providerFactory
            )
            Issue.record("expected stream provider failure")
        } catch let error as FallbackRouterError {
            guard case .allProvidersFailed(let events) = error,
                  let event = events.first else {
                Issue.record("expected one stream fallback event")
                return
            }
            #expect(event.errorDescription == "Provider error")
            Self.assertSafe(error)
        } catch {
            Issue.record("expected stream FallbackRouterError, got (error)")
        }
    }
}
