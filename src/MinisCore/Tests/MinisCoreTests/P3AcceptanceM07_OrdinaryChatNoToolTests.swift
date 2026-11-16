import Foundation
import Testing
@testable import MinisCore

private actor M07PlainChatEffectProbe: ToolExecutor {
    private(set) var executionCount = 0

    nonisolated func execute(name: String, input: [String: Any]) async throws -> String {
        await recordExecution()
        return "unexpected synthetic tool effect"
    }

    private func recordExecution() {
        executionCount += 1
    }
}

private actor M07PlainChatApprovalProbe: ApprovalDelegate {
    private(set) var requestCount = 0

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requestCount += 1
        return .deny
    }
}

@Suite("D-TOOL-01 ordinary chat has no tool effect")
struct P3AcceptanceM07OrdinaryChatNoToolTests {
    @Test func initialPlainTextReplyNeverCallsAvailableToolOrApproval() async throws {
        let identity = minisCoreToolContractIdentity("plain-chat-\(UUID().uuidString)")
        let provider = MockLLMProvider(responses: ["合成纯文本答复"])
        let executor = M07PlainChatEffectProbe()
        let delegate = M07PlainChatApprovalProbe()
        let factLedger = ToolExecutionFactLedger()
        let loop = AgentLoop(
            maxIterations: 2,
            approvalGate: ApprovalGate(delegate: delegate),
            turnController: TurnController(),
            loopDetector: nil,
            toolExecutionFactLedger: factLedger
        )

        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "普通合成问答")],
            systemPrompt: "test",
            provider: provider,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_read"]),
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID,
                taskID: "task:plain-chat",
                actorID: "test"
            ),
            executionIdentity: identity
        )

        #expect(result.messages.last?.content == "合成纯文本答复")
        #expect(result.toolCallsExecuted == 0)
        #expect(result.toolExecutionFacts.isEmpty)
        #expect(factLedger.facts.isEmpty)
        #expect(await executor.executionCount == 0)
        #expect(await delegate.requestCount == 0)
        let toolResultCount = result.messages.flatMap { $0.toAgentContentParts() }.filter { part in
            if case .toolResult(_, _, _, _, _, _, _, _) = part { return true }
            return false
        }.count
        #expect(toolResultCount == 0)
    }
}
