import Foundation
import Testing
@testable import MinisCore

// D-CHAT-03（生产路由转发）—— ProviderRuntimeRoute.assistant 增量流转发回归。
//
// 冻结需求：issues/三期初期合拢-App逐项功能验收清单-20260826.md:160 `CHAT-03`
// 「助手回复能流式显示，生成中状态清晰」。
//
// 本文件固定的是生产路由本身：`ProviderRuntimeRoute.streamAssistantMessage`
// 之前经缓冲 `sendMessageWithReceipt` 合成单 `.completed`（零实时增量）。
// 现在符合 `AssistantStreamingLLMProvider` 的 provider（生产中即
// AnthropicProvider / OpenAICompatibleProvider / OpenAIResponsesProvider）
// 的真实增量流必须经 `FallbackRouter.streamAssistantMessage(tools:factory:)`
// 逐事件转发；不符形的 provider 保持缓冲合成路径逐字节不变。

// MARK: - Test doubles

private struct RouteStreamAcquisitionError: Error, Equatable {}

/// 增量流式 provider：按脚本发出 textDelta，随后 `.completed` 携带权威终态。
/// 同时记录缓冲 `sendMessage` 两个重载的调用次数，用于证明真实流式路径
/// 不再触碰缓冲调用。
private final class RouteStreamingProvider: AssistantStreamingLLMProvider, @unchecked Sendable {
    var name: String { providerName }
    var model: LLMModel
    var capabilities: Set<ProviderCapability> { [.tools] }

    private let lock = NSLock()
    private let providerName: String
    private let deltas: [String]
    private let terminalText: String
    private let acquisitionError: Error?
    private let midStreamError: Error?
    private var noToolsBufferedCalls = 0
    private var toolsBufferedCalls = 0

    init(
        name: String,
        modelID: String,
        deltas: [String],
        terminalText: String? = nil,
        acquisitionError: Error? = nil,
        midStreamError: Error? = nil
    ) {
        self.providerName = name
        self.model = LLMModel(id: modelID, displayName: modelID, provider: name)
        self.deltas = deltas
        self.terminalText = terminalText ?? deltas.joined()
        self.acquisitionError = acquisitionError
        self.midStreamError = midStreamError
    }

    var bufferedCallCounts: (noTools: Int, withTools: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (noToolsBufferedCalls, toolsBufferedCalls)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        lock.withLock { noToolsBufferedCalls += 1 }
        return LLMResponse(text: "unexpected-buffered", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        lock.withLock { toolsBufferedCalls += 1 }
        return LLMResponse(text: "unexpected-buffered-tools", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        if let acquisitionError {
            throw acquisitionError
        }
        let scriptDeltas = deltas
        let scriptTerminal = terminalText
        let scriptMidStreamError = midStreamError
        return AsyncThrowingStream { continuation in
            for delta in scriptDeltas {
                continuation.yield(.textDelta(delta))
            }
            if let scriptMidStreamError {
                continuation.finish(throwing: scriptMidStreamError)
                return
            }
            continuation.yield(
                .completed(LLMResponse(text: scriptTerminal, stopReason: "end_turn", usage: nil))
            )
            continuation.finish()
        }
    }
}

/// 未实现 assistant 增量流接缝的缓冲 provider（如内置 Mock）；分别记录两个
/// 缓冲重载，用于固定「空 tools 走无 tools 重载」的既有委托。
private final class RouteBufferedOnlyProvider: LLMProvider, @unchecked Sendable {
    var name: String { providerName }
    var model: LLMModel
    var capabilities: Set<ProviderCapability> { [.tools] }

    private let lock = NSLock()
    private let providerName: String
    private let text: String
    private let toolsError: Error?
    private var noToolsCalls = 0
    private var toolsCalls = 0

    init(name: String, modelID: String, text: String, toolsError: Error? = nil) {
        self.providerName = name
        self.model = LLMModel(id: modelID, displayName: modelID, provider: name)
        self.text = text
        self.toolsError = toolsError
    }

    var callCounts: (noTools: Int, withTools: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (noToolsCalls, toolsCalls)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        lock.withLock { noToolsCalls += 1 }
        return LLMResponse(text: text, stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        lock.withLock { toolsCalls += 1 }
        if let toolsError {
            throw toolsError
        }
        return LLMResponse(text: text, stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class RouteObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProviderRuntimeRouteObservation] = []

    var all: [ProviderRuntimeRouteObservation] {
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

@MainActor
private func makeAssistantRoute(
    primary: any LLMProvider,
    fallbacks: [any LLMProvider] = [],
    primaryID: String,
    primaryModelID: String,
    fallbackPairs: [(id: String, modelID: String)] = [],
    observations: RouteObservations
) throws -> ProviderRuntimeRoute {
    let snapshot = try ProviderRuntimeSnapshot(
        providerID: primaryID,
        modelID: primaryModelID,
        readinessEvidenceID: "primary-evidence",
        applyReceiptID: "provider-readiness-apply:discovery-primary",
        fallbackProvenance: fallbackPairs.map {
            ProviderRuntimeFallback(
                providerID: $0.id,
                modelID: $0.modelID,
                readinessEvidenceID: "\($0.id)-evidence",
                applyReceiptID: "provider-readiness-apply:discovery-\($0.id)"
            )
        }
    )
    return try ProviderRuntimeRoute(
        snapshot: snapshot,
        primary: primary,
        fallbacks: fallbacks,
        observationSink: { observation in
            observations.record(observation)
        }
    )
}

private func sampleTool() -> [AgentToolDefinition] {
    [
        AgentToolDefinition(
            name: "sample_tool",
            description: "d-chat-03 fixture",
            parameters: ["query": AgentToolParam(type: .string, description: "fixture query")],
            required: ["query"]
        )
    ]
}

private func collect(
    _ stream: AsyncThrowingStream<LLMAssistantStreamEvent, Error>
) async throws -> [String] {
    var projected: [String] = []
    for try await event in stream {
        switch event {
        case .textDelta(let delta):
            projected.append("delta:\(delta)")
        case .thinkingDelta: break
        case .completed(let response):
            projected.append("completed:\(response.text)")
        }
    }
    return projected
}

// MARK: - Regression

@Suite("D-CHAT-03 ProviderRuntimeRoute assistant 增量流转发")
struct ProviderRuntimeAssistantStreamTests {

    /// CHAT-03 核心：符合接缝的 provider 的真实增量必须逐事件穿过路由，
    /// 且不得回落到缓冲 `sendMessage`（否则生产永远只有一个终态合成事件）。
    @Test func conformingProviderDeltasForwardedThroughRoute() async throws {
        let observations = RouteObservations()
        let primary = RouteStreamingProvider(
            name: "primary",
            modelID: "primary-model",
            deltas: ["你", "好", "，世界"]
        )
        let route = try await MainActor.run {
            try makeAssistantRoute(
                primary: primary,
                primaryID: "primary",
                primaryModelID: "primary-model",
                observations: observations
            )
        }

        let events = try await collect(
            try await route.streamAssistantMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                tools: sampleTool(),
                maxTokens: 32,
                temperature: nil
            )
        )

        #expect(
            events == ["delta:你", "delta:好", "delta:，世界", "completed:你好，世界"],
            "路由必须按序转发 provider 的每个 textDelta，completed 保持权威终态"
        )
        #expect(
            primary.bufferedCallCounts == (noTools: 0, withTools: 0),
            "真实流式 provider 不得触碰缓冲 sendMessage 路径"
        )
        let observation = try #require(observations.all.last)
        #expect(observation.servedProviderID == "primary")
        #expect(observation.status == .served)
    }

    /// 不符形 provider：单 `.completed`、零增量，缓冲重载选择与旧路径一致
    /// （非空 tools → tools 重载）。
    @Test func nonConformingProviderKeepsBufferedSynthesis() async throws {
        let observations = RouteObservations()
        let primary = RouteBufferedOnlyProvider(
            name: "primary",
            modelID: "primary-model",
            text: "缓冲答案。"
        )
        let route = try await MainActor.run {
            try makeAssistantRoute(
                primary: primary,
                primaryID: "primary",
                primaryModelID: "primary-model",
                observations: observations
            )
        }

        let events = try await collect(
            try await route.streamAssistantMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                tools: sampleTool(),
                maxTokens: 32,
                temperature: nil
            )
        )

        #expect(
            events == ["completed:缓冲答案。"],
            "未迁移 provider 必须保持零增量、单 .completed 的合成路径"
        )
        #expect(primary.callCounts == (noTools: 0, withTools: 1))
        let observation = try #require(observations.all.last)
        #expect(observation.servedProviderID == "primary")
        #expect(observation.status == .served)
    }

    /// 零行为变化委托：空 tools 的缓冲路径仍走无 tools 重载（与旧的
    /// `route.sendMessage(tools:)` 委托一致）。
    @Test func emptyToolsBufferedPathKeepsNoToolsOverload() async throws {
        let observations = RouteObservations()
        let primary = RouteBufferedOnlyProvider(
            name: "primary",
            modelID: "primary-model",
            text: "无工具缓冲答案"
        )
        let route = try await MainActor.run {
            try makeAssistantRoute(
                primary: primary,
                primaryID: "primary",
                primaryModelID: "primary-model",
                observations: observations
            )
        }

        let events = try await collect(
            try await route.streamAssistantMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                tools: [],
                maxTokens: 32,
                temperature: nil
            )
        )

        #expect(events == ["completed:无工具缓冲答案"])
        #expect(primary.callCounts == (noTools: 1, withTools: 0))
    }

    /// 有序 fallback：符合接缝的主因获取失败而让位，备份的真实增量继续
    /// 逐事件转发，observation 记录回退链。
    @Test func fallbackChainForwardsBackupDeltasAfterPrimaryAcquisitionFailure() async throws {
        let observations = RouteObservations()
        let primary = RouteStreamingProvider(
            name: "primary",
            modelID: "primary-model",
            deltas: ["never"],
            acquisitionError: LLMError.providerError(message: "primary unavailable")
        )
        let backup = RouteStreamingProvider(
            name: "backup",
            modelID: "backup-model",
            deltas: ["备", "用", "流"]
        )
        let route = try await MainActor.run {
            try makeAssistantRoute(
                primary: primary,
                fallbacks: [backup],
                primaryID: "primary",
                primaryModelID: "primary-model",
                fallbackPairs: [("backup", "backup-model")],
                observations: observations
            )
        }

        let events = try await collect(
            try await route.streamAssistantMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                tools: sampleTool(),
                maxTokens: 32,
                temperature: nil
            )
        )

        #expect(events == ["delta:备", "delta:用", "delta:流", "completed:备用流"])
        let observation = try #require(observations.all.last)
        #expect(observation.servedProviderID == "backup")
        #expect(observation.status == .served)
        #expect(observation.fallbackEvents.map(\.providerID) == ["primary"])
    }

    /// 混合链：缓冲主失败后回退到流式备，两条路径在同一入口共存。
    @Test func bufferedPrimaryFallsBackToStreamingBackup() async throws {
        let observations = RouteObservations()
        let primary = RouteBufferedOnlyProvider(
            name: "primary",
            modelID: "primary-model",
            text: "ignored",
            toolsError: LLMError.providerError(message: "buffered primary unavailable")
        )
        let backup = RouteStreamingProvider(
            name: "backup",
            modelID: "backup-model",
            deltas: ["转发", "增量"]
        )
        let route = try await MainActor.run {
            try makeAssistantRoute(
                primary: primary,
                fallbacks: [backup],
                primaryID: "primary",
                primaryModelID: "primary-model",
                fallbackPairs: [("backup", "backup-model")],
                observations: observations
            )
        }

        let events = try await collect(
            try await route.streamAssistantMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                tools: sampleTool(),
                maxTokens: 32,
                temperature: nil
            )
        )

        #expect(events == ["delta:转发", "delta:增量", "completed:转发增量"])
        let observation = try #require(observations.all.last)
        #expect(observation.servedProviderID == "backup")
        #expect(observation.fallbackEvents.map(\.providerID) == ["primary"])
    }

    /// 全链失败：终态错误语义保持（allProvidersFailed + terminalFailure
    /// observation），与缓冲路径一致。
    @Test func exhaustedChainKeepsTerminalFallbackErrorSemantics() async throws {
        let observations = RouteObservations()
        let primary = RouteStreamingProvider(
            name: "primary",
            modelID: "primary-model",
            deltas: ["never"],
            acquisitionError: LLMError.providerError(message: "primary unavailable")
        )
        let backup = RouteBufferedOnlyProvider(
            name: "backup",
            modelID: "backup-model",
            text: "ignored",
            toolsError: LLMError.providerError(message: "backup unavailable")
        )
        let route = try await MainActor.run {
            try makeAssistantRoute(
                primary: primary,
                fallbacks: [backup],
                primaryID: "primary",
                primaryModelID: "primary-model",
                fallbackPairs: [("backup", "backup-model")],
                observations: observations
            )
        }

        do {
            _ = try await route.streamAssistantMessage(
                messages: [LLMMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                tools: sampleTool(),
                maxTokens: 32,
                temperature: nil
            )
            Issue.record("exhausted chain unexpectedly succeeded")
        } catch let error as FallbackRouterError {
            guard case .allProvidersFailed(let events) = error else {
                Issue.record("unexpected fallback error: \(error)")
                return
            }
            #expect(events.map(\.providerID) == ["primary", "backup"])
        }

        let observation = try #require(observations.all.last)
        #expect(observation.servedProviderID == nil)
        #expect(observation.status == .terminalFailure)
        #expect(observation.attempts.map(\.providerID) == ["primary", "backup"])
    }

    /// 流已建立后的中途失败归调用方：获取已成功、observation 已 served，
    /// 错误从流中抛出，不再触发路由级 fallback（与 streamMessage 纪律一致）。
    @Test func midStreamFailurePropagatesFromStreamWithoutRouterFallback() async throws {
        let observations = RouteObservations()
        let primary = RouteStreamingProvider(
            name: "primary",
            modelID: "primary-model",
            deltas: ["前半"],
            midStreamError: RouteStreamAcquisitionError()
        )
        let backup = RouteStreamingProvider(
            name: "backup",
            modelID: "backup-model",
            deltas: ["不应被调用"]
        )
        let route = try await MainActor.run {
            try makeAssistantRoute(
                primary: primary,
                fallbacks: [backup],
                primaryID: "primary",
                primaryModelID: "primary-model",
                fallbackPairs: [("backup", "backup-model")],
                observations: observations
            )
        }

        let stream = try await route.streamAssistantMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            tools: sampleTool(),
            maxTokens: 32,
            temperature: nil
        )
        var received: [String] = []
        do {
            for try await event in stream {
                switch event {
                case .textDelta(let delta):
                    received.append("delta:\(delta)")
                case .thinkingDelta: break
                case .completed(let response):
                    received.append("completed:\(response.text)")
                }
            }
            Issue.record("mid-stream error did not propagate")
        } catch is RouteStreamAcquisitionError {
            #expect(received == ["delta:前半"])
        }

        let observation = try #require(observations.all.last)
        #expect(observation.servedProviderID == "primary")
        #expect(observation.status == .served)
        #expect(backup.bufferedCallCounts == (noTools: 0, withTools: 0))
    }
}
