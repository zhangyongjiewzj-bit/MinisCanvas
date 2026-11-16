import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center production child outcomes 2829")
struct TaskCenterAgentOutcome2829Tests {
    @Test("A denied child has a durable failure card while a sibling completes")
    func deniedAndSuccessfulProductionResultsReachTaskCenter() async throws {
        let profile = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = profile.temporaryDirectory
            .appendingPathComponent("task-center-agent2829-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: url)
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let provider = Task2829Provider()
        let parent = ParentRuntimeIdentity(
            sessionID: "2829-session", conversationID: "2829-conversation",
            turnID: "turn-handle:\(turn.turnID)", taskID: "2829-parent", actorID: "fixture")
        let orchestrator = AgentOrchestrator(
            provider: provider, toolExecutor: Task2829Executor(),
            currentConversationID: parent.conversationID, taskStore: store,
            parentID: parent.taskID,
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name, modelID: provider.model.id,
                configurationFingerprint: "2829-synthetic", conversationID: parent.conversationID),
            parentRuntimeIdentity: parent, parentTurnHandle: turn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming], allowedToolNames: [],
                allowedMCPToolNames: []),
            parentCapabilities: provider.capabilities)

        let reports = await orchestrator.orchestrate(tasks: [
            SubAgentTask(id: "2829-denied", title: "denied", instructions: "use vision",
                         requiredCapabilities: [.vision]),
            SubAgentTask(id: "2829-good", title: "good", instructions: "complete"),
        ], strategy: .sequential)
        #expect(reports.count == 2)
        #expect(!reports[0].result.isSuccess)
        #expect(reports[1].result.isSuccess)
        #expect(await provider.calls.count == 1)

        let reopened = try AgentTaskStore(persistenceURL: url)
        let consumer = TaskCenterControlConsumer(store: reopened)
        let rows = consumer.receiptRows()
        #expect(rows.count == 2)
        let denied = try #require(rows.first { $0.taskID == "2829-denied" })
        let good = try #require(rows.first { $0.taskID == "2829-good" })
        #expect(denied.lifecycleState == .failed)
        #expect(denied.childResultEnvelope != nil)
        #expect(denied.resultSummaryTitle.hasPrefix("失败"))
        let failedNavigation = try #require(consumer.resultNavigation(for: denied))
        #expect(consumer.resultDetail(navigation: failedNavigation)?.statusTitle == "失败")
        #expect(good.lifecycleState == .completed)
        #expect(good.childResultEnvelope?.outcome == .succeeded)
        #expect(good.resultSummaryTitle.hasPrefix("已完成"))
        #expect(consumer.resultNavigation(for: good) != nil)
    }
}

private struct Task2829Executor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String { "synthetic" }
}

private actor Task2829Calls {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct Task2829Provider: LLMProvider {
    let name = "2829-synthetic-provider"
    var model = LLMModel(id: "2829-synthetic-model", displayName: "2829 model",
                         provider: "2829-synthetic-provider")
    let capabilities: Set<ProviderCapability> = [.streaming]
    let calls = Task2829Calls()

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        await calls.record()
        return LLMResponse(text: "synthetic completion", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await calls.record()
        return AsyncThrowingStream { $0.finish() }
    }
}
