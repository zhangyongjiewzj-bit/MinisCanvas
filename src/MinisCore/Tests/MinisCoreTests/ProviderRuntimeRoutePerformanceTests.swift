import Foundation
import Testing
@testable import MinisCore

@Suite("D-PERF-08 provider route timing")
struct ProviderRuntimeRoutePerformanceTests {
    @Test("monotonic interval rounds down and never wraps")
    func monotonicIntervalConversion() {
        #expect(ProviderRuntimeRoutePerformance.elapsedMilliseconds(
            startNanoseconds: 10,
            endNanoseconds: 999_999
        ) == 0)
        #expect(ProviderRuntimeRoutePerformance.elapsedMilliseconds(
            startNanoseconds: 10,
            endNanoseconds: 12_345_688
        ) == 12)
        #expect(ProviderRuntimeRoutePerformance.elapsedMilliseconds(
            startNanoseconds: 11,
            endNanoseconds: 10
        ) == 0)
    }

    @Test("all four route acquisitions emit bounded elapsed observations")
    func allRouteAcquisitionsEmitElapsed() async throws {
        let probe = RouteTimingProbe()
        let route = try await MainActor.run {
            try makeRoute(provider: RouteTimingProvider(), probe: probe)
        }
        let messages = [LLMMessage(role: .user, content: "hello")]

        _ = try await route.sendMessageWithReceipt(
            messages: messages,
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )
        _ = try await route.sendMessageWithReceipt(
            messages: messages,
            systemPrompt: nil,
            tools: routeTimingTool,
            maxTokens: 32,
            temperature: nil
        )
        _ = try await route.streamMessageWithReceipt(
            messages: messages,
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )
        _ = try await route.streamAssistantMessage(
            messages: messages,
            systemPrompt: nil,
            tools: routeTimingTool,
            maxTokens: 32,
            temperature: nil
        )

        let observations = probe.values
        #expect(observations.count == 4)
        for observation in observations {
            #expect(observation.elapsedMilliseconds != nil)
            #expect((observation.elapsedMilliseconds ?? -1) >= 0)
            #expect(observation.status == .served)
            #expect(observation.servedProviderID == "primary")
        }
    }

    @Test("terminal route failure retains an elapsed observation")
    func terminalFailureEmitsElapsed() async throws {
        let probe = RouteTimingProbe()
        let route = try await MainActor.run {
            try makeRoute(provider: RouteTimingProvider(failBuffered: true), probe: probe)
        }

        do {
            _ = try await route.sendMessageWithReceipt(
                messages: [LLMMessage(role: .user, content: "hello")],
                systemPrompt: nil,
                maxTokens: 32,
                temperature: nil
            )
            Issue.record("expected route failure")
        } catch {
            let observation = try #require(probe.values.last)
            #expect(observation.status == .terminalFailure)
            #expect(observation.elapsedMilliseconds != nil)
            #expect((observation.elapsedMilliseconds ?? -1) >= 0)
        }
    }

    @Test("legacy journal lacks elapsed and new journal remains bounded")
    func observationCodableCompatibility() throws {
        let legacy = ProviderRuntimeRouteObservation(
            routeReceiptID: "legacy-route",
            servedProviderID: "primary"
        )
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyText = try #require(String(data: legacyData, encoding: .utf8))
        #expect(!legacyText.contains("elapsedMilliseconds"))
        let legacyDecoded = try JSONDecoder().decode(
            ProviderRuntimeRouteObservation.self,
            from: legacyData
        )
        #expect(legacyDecoded.elapsedMilliseconds == nil)

        let current = ProviderRuntimeRouteObservation(
            routeReceiptID: "new-route",
            servedProviderID: "primary",
            elapsedMilliseconds: -5
        )
        #expect(current.elapsedMilliseconds == 0)
        let currentData = try JSONEncoder().encode(current)
        let decoded = try JSONDecoder().decode(
            ProviderRuntimeRouteObservation.self,
            from: currentData
        )
        #expect(decoded.elapsedMilliseconds == 0)
        #expect(decoded.servedProviderID == "primary")
    }
}

private let routeTimingTool = [
    AgentToolDefinition(
        name: "sample_tool",
        description: "timing fixture",
        parameters: ["query": AgentToolParam(type: .string, description: "fixture query")],
        required: ["query"]
    )
]

@MainActor
private func makeRoute(
    provider: RouteTimingProvider,
    probe: RouteTimingProbe
) throws -> ProviderRuntimeRoute {
    let snapshot = try ProviderRuntimeSnapshot(
        providerID: "primary",
        modelID: "primary-model",
        readinessEvidenceID: "primary-evidence",
        applyReceiptID: "provider-readiness-apply:primary"
    )
    return try ProviderRuntimeRoute(
        snapshot: snapshot,
        primary: provider,
        observationSink: { probe.record($0) }
    )
}

private struct RouteTimingError: Error {}

private final class RouteTimingProvider: AssistantStreamingLLMProvider, @unchecked Sendable {
    let name = "primary"
    var model = LLMModel(
        id: "primary-model",
        displayName: "primary-model",
        provider: "primary"
    )
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let failBuffered: Bool

    init(failBuffered: Bool = false) {
        self.failBuffered = failBuffered
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        if failBuffered { throw RouteTimingError() }
        return LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        if failBuffered { throw RouteTimingError() }
        return LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        return AsyncThrowingStream { $0.finish() }
    }

    func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(LLMResponse(
                text: "ok", stopReason: "stop", usage: nil
            )))
            continuation.finish()
        }
    }
}

private final class RouteTimingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProviderRuntimeRouteObservation] = []

    var values: [ProviderRuntimeRouteObservation] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ observation: ProviderRuntimeRouteObservation) {
        lock.lock()
        stored.append(observation)
        lock.unlock()
    }
}
