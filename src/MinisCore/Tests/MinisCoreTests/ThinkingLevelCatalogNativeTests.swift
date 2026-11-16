import Foundation
import Testing
@testable import MinisCore

struct ThinkingLevelCatalogNativeTests {
    @Test func fixedCatalogModelsKeepTheirDeclaredResults() {
        for model in LLMModel.allModels {
            let expected: ThinkingLevel? = ["claude-opus-4-8", "claude-opus-4-6"].contains(model.id)
                ? .max : nil
            #expect(ThinkingLevelCatalog.declaredMaxLevel(for: model.id) == expected)
        }
    }

    @Test func catalogPrefixIsCaseInsensitiveWithoutNamespaceOrLeadingTrim() {
        for id in ["claude-opus-4", "claude-opus-4.6", "claude-opus-4-5",
                   "claude-opus-4foo", "CLAUDE-OPUS-4-6", "claude-opus-4-6 "] {
            #expect(ThinkingLevelCatalog.declaredMaxLevel(for: id) == .max)
        }
        for id in [" claude-opus-4-6", "anthropic/claude-opus-4-6",
                   "claude-opus-3-9", "claude-opus-5-1", "claude-sonnet-4-6"] {
            #expect(ThinkingLevelCatalog.declaredMaxLevel(for: id) == nil)
        }
    }

    @Test func declaredLevelAndUnknownModelRemainDistinct() {
        #expect(ThinkingLevelCatalog.declaredMaxLevel(for: "claude-opus-4-6") == .max)
        #expect(ThinkingLevelCatalog.declaredMaxLevel(for: "unlisted-model-task2575") == nil)
        let unknown = LLMModel(id: "unlisted-model-task2575", displayName: "Unknown", provider: "Custom")
        #expect(unknown.catalogMaxThinkingLevel == .xhigh)
    }

    @Test func reasoningSupportAndUserOverrideKeepTheirPriority() {
        let model = LLMModel(id: "claude-opus-4-6", displayName: "Claude Opus 4.6", provider: "Anthropic")
        let entry = ModelEntry(providerInstanceId: "provider-1", model: model,
                               overrides: ModelOverrides(maxThinkingLevel: .high))
        #expect(entry.effectiveMaxThinkingLevel == .high)

        let disabled = LLMModel(id: model.id, displayName: model.displayName,
                                provider: model.provider, supportsReasoning: false)
        #expect(disabled.catalogMaxThinkingLevel == .off)
    }

    @Test func agentProviderClampsRequestToCatalogBound() async throws {
        let model = LLMModel(id: "claude-opus-4-6", displayName: "Claude Opus 4.6", provider: "Anthropic")
        let provider = CapturingAgentProvider(model: model)
        _ = try await provider.streamAgentMessage(messages: [], systemPrompt: nil, tools: [],
                                                  maxTokens: 128, thinkingLevel: .ultra)
        #expect(provider.receivedLevel == .max)
        _ = try await provider.streamAgentMessage(messages: [], systemPrompt: nil, tools: [],
                                                  maxTokens: 128, thinkingLevel: .low)
        #expect(provider.receivedLevel == .low)
    }
}

private final class CapturingAgentProvider: AgentProvider, @unchecked Sendable {
    let name = "Catalog test provider"
    let model: LLMModel
    let defaultMaxTokens = 128
    private let lock = NSLock()
    private var storedLevel: ThinkingLevel?

    var receivedLevel: ThinkingLevel? {
        lock.lock()
        defer { lock.unlock() }
        return storedLevel
    }

    init(model: LLMModel) { self.model = model }

    func streamAgentMessageClamped(
        messages: [AgentMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        record(thinkingLevel)
        return AsyncThrowingStream { continuation in continuation.finish() }
    }

    private func record(_ level: ThinkingLevel?) {
        lock.lock()
        storedLevel = level
        lock.unlock()
    }
}
