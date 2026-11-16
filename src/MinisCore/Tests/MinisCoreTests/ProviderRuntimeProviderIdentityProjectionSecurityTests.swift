import Foundation
import Testing
@testable import MinisCore

private let providerIdentityFixture =
    "provider://fixture-provider-secret/path"

@Suite("Provider runtime provider identity projection", .serialized)
struct ProviderRuntimeProviderIdentityProjectionSecurityTests {
    @Test("live route observation bounds served identity and attempts")
    @MainActor
    func liveObservationBoundsExternalIdentity() async throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: providerIdentityFixture,
            modelID: "fixture-model",
            readinessEvidenceID: "fixture-evidence",
            applyReceiptID: "provider-readiness-apply:fixture"
        )
        let provider = ProviderIdentityFixtureProvider(name: providerIdentityFixture)
        let probe = ProviderIdentityObservationProbe()
        let route = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: provider,
            observationSink: { probe.record($0) }
        )

        let result = try await route.sendMessageWithReceipt(
            messages: [LLMMessage(role: .user, content: "fixture")],
            systemPrompt: nil,
            maxTokens: 8,
            temperature: nil
        )
        let observation = try #require(probe.value)

        #expect(route.name == providerIdentityFixture)
        #expect(result.receipt.servedProviderID == providerIdentityFixture)
        #expect(observation.servedProviderID == "provider")
        #expect(observation.attempts.map(\.providerID) == ["provider"])
        #expect(observation.fallbackEvents.isEmpty)
    }

    @Test("direct observation construction bounds served and attempt identities")
    func directObservationBoundsIdentity() {
        let malformedIDs = [
            providerIdentityFixture,
            "provider\u{0000}fixture",
            String(repeating: "x", count: 129),
        ]
        for malformedID in malformedIDs {
            let observation = ProviderRuntimeRouteObservation(
                routeReceiptID: "fixture-receipt",
                servedProviderID: malformedID,
                attempts: [
                    ProviderRuntimeRouteAttempt(
                        providerID: malformedID,
                        attempt: 1
                    )
                ]
            )

            #expect(observation.servedProviderID == "provider")
            #expect(observation.attempts.map(\.providerID) == ["provider"])
        }
    }

    @Test("valid observation identity remains readable")
    func validObservationIdentityRemainsStable() {
        let observation = ProviderRuntimeRouteObservation(
            routeReceiptID: "fixture-receipt",
            servedProviderID: "Google Gemini",
            attempts: [
                ProviderRuntimeRouteAttempt(
                    providerID: "Google Gemini",
                    attempt: 1
                )
            ]
        )

        #expect(observation.servedProviderID == "Google Gemini")
        #expect(observation.attempts.map(\.providerID) == ["Google Gemini"])
    }

    @Test("Codable observation decode applies the same identity projection")
    func decodedObservationBoundsIdentity() throws {
        let payload = """
        {
          "routeReceiptID": "fixture-receipt",
          "servedProviderID": "provider://fixture-provider-secret/path",
          "servedModelID": "fixture-model",
          "attempts": [{
            "providerID": "provider://fixture-provider-secret/path?token=secret",
            "attempt": 1,
            "failureDescription": "Provider error"
          }],
          "fallbackEvents": [],
          "status": {"served": {}},
          "terminalErrorDescription": null
        }
        """.data(using: .utf8)!

        let observation = try JSONDecoder().decode(
            ProviderRuntimeRouteObservation.self,
            from: payload
        )

        #expect(observation.servedProviderID == "provider")
        #expect(observation.attempts.map(\.providerID) == ["provider"])
    }
}

private struct ProviderIdentityFixtureProvider: LLMProvider, Sendable {
    let name: String
    var model: LLMModel
    let capabilities: Set<ProviderCapability> = []

    init(name: String) {
        self.name = name
        self.model = LLMModel(
            id: "fixture-model",
            displayName: "Fixture Model",
            provider: name
        )
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
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private final class ProviderIdentityObservationProbe: @unchecked Sendable {
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
