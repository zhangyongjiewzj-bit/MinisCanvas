import Foundation
import Testing
@testable import MinisCore

private final class MetadataRequestProvider3237: LLMProvider, @unchecked Sendable {
    let name = "metadata3237"
    var model: LLMModel
    var capabilities: Set<ProviderCapability> { [.tools, .streaming] }
    private let lock = NSLock()
    private var requests: [Int] = []
    var maxTokensReceived: [Int] { lock.withLock { requests } }

    init(model: LLMModel) { self.model = model }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { requests.append(maxTokens) }
        return LLMResponse(text: "synthetic3237", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                     tools: [AgentToolDefinition], maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?,
                       maxTokens: Int, temperature: Double?) async throws
        -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Provider runtime frozen model metadata 3237", .serialized)
@MainActor
struct ProviderRuntimeModelMetadata3237Tests {
    private func fullModel() -> LLMModel {
        LLMModel(id: "model3237", displayName: "Frozen synthetic model",
                 provider: "metadata3237", modalityOverride: .vision,
                 contextWindow: 32768, maxOutputTokens: 3000,
                 supportsReasoning: true, interleavedReasoningField: "reasoning_content")
    }

    private func route(_ provider: MetadataRequestProvider3237) throws -> ProviderRuntimeRoute {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: provider.name, modelID: provider.model.id,
            readinessEvidenceID: "readiness3237",
            applyReceiptID: "provider-readiness-apply:metadata3237",
            capabilities: provider.capabilities)
        return try ProviderRuntimeRoute(snapshot: snapshot, primary: provider)
    }

    @Test("route existential preserves every captured model field and dispatches through real route proxy")
    func fullFrozenMetadataReachesRouteConsumer() async throws {
        let original = fullModel()
        let provider = MetadataRequestProvider3237(model: original)
        let frozen = try route(provider)
        let consumer: any LLMProvider = frozen
        #expect(consumer.model == original)
        #expect(consumer.model.displayName == "Frozen synthetic model")
        #expect(consumer.model.modalityOverride == .vision)
        #expect(consumer.model.contextWindowTokens == 32768)
        #expect(consumer.model.maxOutputTokens == 3000)
        #expect(consumer.model.supportsReasoning == true)
        #expect(consumer.model.interleavedReasoningField == "reasoning_content")
        #expect(consumer.capabilities == [.tools, .streaming])
        let tokens = try #require(consumer.model.maxOutputTokens)
        _ = try await consumer.sendMessage(messages: [], systemPrompt: nil,
                                           maxTokens: tokens, temperature: nil)
        #expect(provider.maxTokensReceived == [3000])
    }

    @Test("mutated upstream metadata cannot rewrite frozen route and is rejected before wire")
    func upstreamMetadataDriftKeepsOldValueAndRejectsWire() async throws {
        let original = fullModel()
        let provider = MetadataRequestProvider3237(model: original)
        let frozen = try route(provider)
        provider.model.maxOutputTokens = 9000
        provider.model.contextWindow = 65536
        provider.model.modalityOverride = .fullMultimodalInput
        provider.model.supportsReasoning = false
        provider.model.interleavedReasoningField = nil
        #expect(frozen.model == original)
        await #expect(throws: ProviderRuntimeSnapshotError.modelBindingMismatch("metadata3237")) {
            _ = try await frozen.sendMessage(messages: [], systemPrompt: nil,
                                             maxTokens: 3000, temperature: nil)
        }
        #expect(provider.maxTokensReceived.isEmpty)
    }

    @Test("unknown metadata retains nil values and existing context heuristic")
    func unknownMetadataStaysUnknown() throws {
        let original = LLMModel(id: "unknown3237", displayName: "Unknown synthetic",
                                provider: "metadata3237")
        let frozen = try route(MetadataRequestProvider3237(model: original))
        #expect(frozen.model == original)
        #expect(frozen.model.maxOutputTokens == nil)
        #expect(frozen.model.contextWindow == nil)
        #expect(frozen.model.modalityOverride == nil)
        #expect(frozen.model.supportsReasoning == nil)
        #expect(frozen.model.interleavedReasoningField == nil)
        #expect(frozen.model.contextWindowTokens == original.contextWindowTokens)
    }

    // This Core consumer verifies the frozen ceiling and the original effort
    // scaler. The original App3155 held/SDK consumer separately exercises the
    // ChatAgentEngine context calculation, permission gates and receipts.
    @Test("three effort budgets respect frozen model ceiling when clipped and retain unclipped scaling",
          arguments: [ComposerEffort.low, .standard, .high], [false, true])
    func threeEffortsPreserveFrozenCeiling(effort: ComposerEffort, clipped: Bool) async throws {
        var captured = fullModel()
        captured.maxOutputTokens = clipped ? 3000 : 16384
        let provider = MetadataRequestProvider3237(model: captured)
        let frozen = try route(provider)
        #expect(frozen.model.maxOutputTokens == (clipped ? 3000 : 16384))
        let ceiling = clipped ? frozen.model.maxOutputTokens : nil
        let base = min(4096, ceiling ?? Int.max)
        let profile = ComposerEffortExecutionProfile(
            effort: effort, baseMaxIterations: 10, baseMaxTokens: base,
            maxOutputTokensCeiling: ceiling)
        let expected: Int
        switch effort {
        case .low: expected = clipped ? 1500 : 2048
        case .standard: expected = clipped ? 3000 : 4096
        case .high: expected = clipped ? 3000 : 6144
        }
        #expect(profile.maxTokens == expected)
        if clipped { #expect(profile.maxTokens <= 3000) }
        _ = try await frozen.sendMessage(messages: [], systemPrompt: nil,
                                        maxTokens: profile.maxTokens, temperature: nil)
        #expect(provider.maxTokensReceived == [expected])
    }
}
