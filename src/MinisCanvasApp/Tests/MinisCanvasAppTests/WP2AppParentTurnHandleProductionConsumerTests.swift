import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("WP-2 App parent consumer")
struct WP2AppParentTurnHandleProductionConsumerTests {
    @Test("production App engine exposes one exact parent handle and identity")
    func productionConsumerUsesCoreParentContext() async throws {
        let provider = WP2ContextProbeProvider()
        let engine = AgentLoopChatEngine(
            toolExecutor: NoopToolExecutor(),
            maxIterations: 1
        )
        let stream = try await engine.streamReply(
            provider: provider,
            history: [.init(role: .user, content: "hello")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: "conversation",
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 1
        )
        for try await _ in stream {}

        #expect(provider.sawExactParentContext)
        #expect(provider.observedIdentity?.sessionID == "conversation")
        #expect(provider.observedIdentity?.conversationID == "conversation")
        #expect(provider.observedIdentity?.taskID == "chat:conversation:1")
        #expect(provider.observedIdentity?.actorID == "app")
        #expect(provider.observedIdentity?.turnID == "turn-handle:\(provider.observedHandleTurnID ?? -1)")
        #expect(provider.observedParentIsActive)
    }
}

private struct NoopToolExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        "ok"
    }
}

private final class WP2ContextProbeProvider: LLMProvider, @unchecked Sendable {
    let name = "wp2-probe"
    var model = LLMModel(id: "wp2-probe", displayName: "WP2 Probe", provider: "test")
    let capabilities: Set<ProviderCapability> = [.tools]
    private(set) var sawExactParentContext = false
    private(set) var observedIdentity: ParentRuntimeIdentity?
    private(set) var observedHandleTurnID: Int?
    private(set) var observedParentIsActive = false

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await recordContext()
        return LLMResponse(text: "done", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await recordContext()
        return LLMResponse(text: "done", stopReason: "stop", usage: nil)
    }

    private func recordContext() async {
        let context = AgentExecutionContext.current
        observedIdentity = context?.parentRuntimeIdentity
        observedHandleTurnID = context?.parentTurnHandle?.turnID
        observedParentIsActive = await context?.parentTurnHandle?.isActive() ?? false
        sawExactParentContext = context?.hasVerifiedParentRuntime == true
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
