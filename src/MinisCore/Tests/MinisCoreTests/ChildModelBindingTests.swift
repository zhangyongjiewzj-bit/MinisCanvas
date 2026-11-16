import Foundation
import Testing
@testable import MinisCore

@Suite("Frozen child model selection")
struct ChildModelBindingTests {
    private var parent: ParentContextSnapshotV1 {
        .init(providerID: "DeepSeek", modelID: "deepseek-flash",
              configurationFingerprint: "parent-frozen", reasoningConfiguration: "medium")
    }
    private var opus: ReadyChildModel {
        .init(stableID: "anthropic-config/claude-opus-5-5", displayName: "Opus 5.5", binding: .init(providerID: "Anthropic", modelID: "claude-opus-5-5",
              configurationFingerprint: "child-frozen"), maximumThinkingLevel: .max)
    }
    private var enabledPolicy: ChildModelBindingPolicy {
        .init(settings: AgentSettings(childModelOverridesEnabled: true), readyModels: [opus])
    }

    @Test func defaultInheritsAndRejectsUnauthorizedOverride() throws {
        let legacySettings = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(!legacySettings.childModelOverridesEnabled)
        let policy = ChildModelBindingPolicy(settings: legacySettings)
        let inherited = try policy.resolve(modelID: nil, thinkingLevel: nil, parent: parent)
        #expect(inherited.binding == parent)
        #expect(inherited.inheritsParent)
        #expect(throws: ChildModelBindingError.unauthorized) {
            try policy.resolve(modelID: opus.stableID, thinkingLevel: "high", parent: parent)
        }
    }

    @Test func authorizationOffPreservesLegacyTaskTitleAndDurableOutput() async throws {
        let runner = OETestRunner(name: "legacy-child", output: "旧任务结果")
        let store = AgentTaskStore()
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator(
            externalRunners: ["legacy-child": runner], taskStore: store,
            parentID: "legacy-parent", parentBinding: parent
        ))
        _ = try await executor.execute(name: "orchestrate", input: [
            "input_version": 1,
            "tasks": [["id": "legacy", "title": "原始任务标题", "instructions": "读资料",
                       "agent": "external:legacy-child"]]
        ])
        let task = try #require(runner.receivedTasks.first)
        #expect(task.title == "原始任务标题")
        let receipt = try #require(store.allReceipts().first)
        #expect(receipt.childResultEnvelope?.output == "旧任务结果")
        #expect(ChildModelBindingPolicy().toolDescription == "")
    }

    @Test func toolDescriptionListsReadyIDsAndCeilingsOnlyAfterAuthorization() {
        let definition = OrchestrationToolExecutor.makeDefinition(childModelPolicy: enabledPolicy)
        #expect(definition.description.contains(opus.stableID))
        #expect(definition.description.contains("最高 max"))
        #expect(!OrchestrationToolExecutor.makeDefinition().description.contains(opus.stableID))
    }

    @Test func perTaskCrossProviderSelectionUsesTrustedFrozenIdentity() throws {
        var settings = AgentSettings(childModelOverridesEnabled: true)
        let policy = ChildModelBindingPolicy(settings: settings, readyModels: [opus])
        let selections = try OrchestrationToolExecutor.resolveModelSelections([
            "tasks": [["id": "research", "model": opus.stableID, "thinking_level": "high"]]
        ], parent: parent, policy: policy)
        let selection = try #require(selections["research"])
        let task = selection.applying(to: SubAgentTask(id: "research", title: "调研", instructions: "读资料"), parent: parent)
        settings.childModelOverridesEnabled = false
        #expect(task.providerID == "Anthropic")
        #expect(task.modelID == "claude-opus-5-5")
        #expect(task.configurationFingerprint == "child-frozen")
        #expect(task.reasoningConfiguration == "high")
        #expect(task.bindingSource == .explicit)
    }

    @Test func unknownModelRefusesAndOverLimitIsClippedWithReason() throws {
        #expect(throws: ChildModelBindingError.notReady("missing/model")) {
            try enabledPolicy.resolve(modelID: "missing/model", thinkingLevel: nil, parent: parent)
        }
        let selected = try enabledPolicy.resolve(modelID: opus.stableID, thinkingLevel: "ultra", parent: parent)
        #expect(selected.binding.reasoningConfiguration == "max")
        #expect(selected.truncationNote == "已截断到 max")
    }

    @Test func approvalAndTaskTitleUseExistingTitleAndFrozenLevel() throws {
        let selected = try enabledPolicy.resolve(modelID: opus.stableID, thinkingLevel: "high", parent: parent)
        let task = selected.applying(to: SubAgentTask(id: "a", title: String(repeating: "很长的任务", count: 40), instructions: "读资料"), parent: parent)
        let approvalTitle = ProductRedactionPolicy.redact(task.title, maxLength: 90)
        #expect(approvalTitle.contains("Opus 5.5 · 请求档位 high"))
        #expect(!approvalTitle.contains("档位待接通"))
        let inherited = try ChildModelBindingPolicy().resolve(modelID: nil, thinkingLevel: nil, parent: parent)
        #expect(inherited.presentation.contains("继承父级"))
    }
}

@Suite("Thinking request body mapping")
struct ChildThinkingRequestBodyTests {
    @Test func openAIChatAndResponsesUseTheirOwnEffortField() {
        var chat: [String: Any] = ["model": "gpt-5.2", "temperature": 0.7]
        let application = AssistantThinkingParameters.apply(.high, modelID: "gpt-5.2", wire: .openAIChat, body: &chat)
        #expect(application == .written)
        #expect(chat["reasoning_effort"] as? String == "high")
        #expect(chat["temperature"] == nil)
        var responses: [String: Any] = [:]
        AssistantThinkingParameters.apply(.max, modelID: "gpt-6.1-sol", wire: .openAIResponses, body: &responses)
        #expect((responses["reasoning"] as? [String: String])?["effort"] == "max")
    }

    @Test func anthropicAdaptiveAndLegacyManualBudgetUseDifferentShapes() {
        var adaptive: [String: Any] = ["max_tokens": 4096]
        AssistantThinkingParameters.apply(.high, modelID: "claude-opus-5-5", wire: .anthropic, body: &adaptive)
        #expect((adaptive["thinking"] as? [String: String])?["type"] == "adaptive")
        #expect((adaptive["output_config"] as? [String: String])?["effort"] == "high")
        var manual: [String: Any] = ["max_tokens": 4096]
        AssistantThinkingParameters.apply(.low, modelID: "claude-sonnet-4-5", wire: .anthropic, body: &manual)
        #expect((manual["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 1024)
    }

    @Test func deepSeekToggleAndEffortAreSeparateParameters() {
        var body: [String: Any] = [:]
        AssistantThinkingParameters.apply(.medium, modelID: "deepseek-v4-flash", wire: .openAIChat, body: &body)
        #expect((body["thinking"] as? [String: String])?["type"] == "enabled")
        #expect(body["reasoning_effort"] as? String == "high")
        var off: [String: Any] = [:]
        AssistantThinkingParameters.apply(.off, modelID: "deepseek-flash", wire: .openAIChat, body: &off)
        #expect((off["thinking"] as? [String: String])?["type"] == "disabled")
        #expect(off["reasoning_effort"] == nil)
    }

    @Test func unsupportedOffReportsUnchangedRequest() {
        var body: [String: Any] = ["temperature": 0.5]
        let result = AssistantThinkingParameters.apply(.off, modelID: "claude-opus-5-5", wire: .anthropic, body: &body)
        #expect(result == .ignored("该模型不支持关闭思考"))
        #expect(body["thinking"] == nil)
        #expect(body["temperature"] as? Double == 0.5)
    }

    @Test func chatToolsCombinationReportsNoThinkingParameter() {
        var body: [String: Any] = ["tools": [["type": "function"]]]
        let result = AssistantThinkingParameters.apply(.high, modelID: "gpt-6.1-sol", wire: .openAIChat, body: &body)
        #expect(result == .ignored("gpt-6.1-sol Chat带工具不支持该思考参数组合"))
        #expect(body["reasoning_effort"] == nil)
        #expect((body["tools"] as? [[String: String]])?.count == 1)
    }

    @Test func tooSmallManualBudgetReportsNotAppliedToReceipt() {
        var body: [String: Any] = ["max_tokens": 1024]
        let recorder = ThinkingParameterApplicationRecorder()
        let result = AssistantThinkingParameters.$reportApplication.withValue({ recorder.record($0) }) {
            AssistantThinkingParameters.apply(.high, modelID: "claude-sonnet-4-5", wire: .anthropic, body: &body)
        }
        #expect(result == .ignored("输出上限放不下最小手动思考预算"))
        #expect(body["thinking"] == nil)
        #expect(recorder.presentation == "档位未生效（输出上限放不下最小手动思考预算）")
    }

    @Test func nilAndUnknownModelsPreserveExistingRequest() throws {
        let original: [String: Any] = ["model": "custom", "temperature": 0.4, "max_tokens": 1000]
        var nilBody = original
        AssistantThinkingParameters.apply(nil, modelID: "gpt-6.1-sol", wire: .openAIChat, body: &nilBody)
        var unknown = original
        let ignored = AssistantThinkingParameters.apply(.ultra, modelID: "custom", wire: .anthropic, body: &unknown)
        #expect(ignored == .ignored("模型ID未声明思考参数映射"))
        let encoded = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        #expect(try JSONSerialization.data(withJSONObject: nilBody, options: [.sortedKeys]) == encoded)
        #expect(try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys]) == encoded)
    }
}

private final class ChildThinkingForwardProbe: AssistantStreamingLLMProvider, @unchecked Sendable {
    let name = "thinking-probe"
    var model = LLMModel(id: "probe", displayName: "Probe", provider: "test")
    let capabilities: Set<ProviderCapability> = []
    private let lock = NSLock()
    private var levels: [ThinkingLevel?] = []
    private var bufferedCount = 0
    var recordedLevels: [ThinkingLevel?] { lock.withLock { levels } }
    var bufferedCalls: Int { lock.withLock { bufferedCount } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { bufferedCount += 1 }
        return LLMResponse(text: "done", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                                maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt, tools: tools,
            maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
    }
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                                maxTokens: Int, temperature: Double?, thinkingLevel: ThinkingLevel?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        lock.withLock { levels.append(thinkingLevel) }
        return llmAssistantCompletedStream(LLMResponse(text: "done", stopReason: "end_turn", usage: nil))
    }
}

@Suite("Parent and child shared thinking forwarding")
struct ChildThinkingForwardingTests {
    @Test func frozenLevelReachesRetryWrappedProviderWithoutDisplayCallback() async throws {
        let probe = ChildThinkingForwardProbe()
        let binding = ParentContextSnapshotV1(providerID: probe.name, modelID: probe.model.id,
            configurationFingerprint: "frozen", reasoningConfiguration: "high")
        let loop = AgentLoop(maxIterations: 1, parentBinding: binding)
        let result = try await loop.run(messages: [.init(role: .user, content: "hello")],
            systemPrompt: nil, provider: RetryingLLMProvider(base: probe),
            toolExecutor: OETestNoopExecutor(), tools: [])
        #expect(probe.recordedLevels == [.high])
        #expect(probe.bufferedCalls == 0)
        #expect(result.messages.last?.content == "done")
    }

    @Test func nilWithoutDisplayCallbackPreservesBufferedRoute() async throws {
        let probe = ChildThinkingForwardProbe()
        let loop = AgentLoop(maxIterations: 1)
        _ = try await loop.run(messages: [.init(role: .user, content: "hello")], systemPrompt: nil,
            provider: probe, toolExecutor: OETestNoopExecutor(), tools: [])
        #expect(probe.recordedLevels.isEmpty)
        #expect(probe.bufferedCalls == 1)
    }

    @Test func modelAndUserCeilingsClipBeforeWireMapping() throws {
        let model = ReadyChildModel(stableID: "instance/gpt-5.2", displayName: "GPT",
            binding: .init(providerID: "openai", modelID: "gpt-5.2", configurationFingerprint: "f"),
            maximumThinkingLevel: .xhigh)
        let policy = ChildModelBindingPolicy(settings: AgentSettings(childModelOverridesEnabled: true,
            childModelThinkingLevelCeiling: .medium), readyModels: [model])
        let selection = try policy.resolve(modelID: model.stableID, thinkingLevel: "ultra",
            parent: .init(providerID: "parent", modelID: "parent", configurationFingerprint: "p"))
        var body: [String: Any] = [:]
        AssistantThinkingParameters.apply(selection.binding.reasoningConfiguration.flatMap(ThinkingLevel.init(rawValue:)),
            modelID: selection.binding.modelID, wire: .openAIResponses, body: &body)
        #expect((body["reasoning"] as? [String: String])?["effort"] == "medium")
        #expect(selection.truncationNote == "已截断到 medium")
    }
}
