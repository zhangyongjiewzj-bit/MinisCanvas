import Foundation
import Testing
@testable import MinisCore

@Suite("R28 WP2 Core parent-handle seam")
struct R28WP2CoreParentHandleSeamTests {
    @Test("a real turn exposes the exact parent handle and Core-derived identity")
    func realTurnBindsParentContextAfterHandleCreation() async throws {
        let controller = TurnController()
        let probe = R28WP2ParentContextProbe()
        let provider = R28WP2ParentContextProvider(probe: probe)
        let seed = ParentRuntimeIdentitySeed(
            sessionID: "session-root",
            conversationID: "conversation-root",
            taskID: "task-root",
            actorID: "actor-root"
        )
        let loop = AgentLoop(
            maxIterations: 1,
            turnController: controller,
            loopDetector: nil
        )

        _ = try await loop.run(
            messages: [LLMMessage(role: .user, content: "finish")],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: R28WP2NoopExecutor(),
            tools: [],
            currentConversationID: "conversation-root",
            parentIdentitySeed: seed
        )

        let context = await probe.context()
        #expect(context?.parentTurnHandle?.turnID == 1)
        #expect(context?.parentRuntimeIdentity == ParentRuntimeIdentity(
            sessionID: "session-root",
            conversationID: "conversation-root",
            turnID: "turn-handle:1",
            taskID: "task-root",
            actorID: "actor-root"
        ))
        #expect(context?.hasVerifiedParentRuntime == true)
    }

    @Test("an empty seed fails before the first provider call")
    func emptyParentSeedFailsClosed() async {
        let controller = TurnController()
        let provider = R28WP2CountingProvider()
        let loop = AgentLoop(maxIterations: 1, turnController: controller, loopDetector: nil)

        await #expect(throws: ParentRuntimeIdentitySeedError.invalidField("sessionID")) {
            _ = try await loop.run(
                messages: [LLMMessage(role: .user, content: "finish")],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: R28WP2NoopExecutor(),
                tools: [],
                parentIdentitySeed: ParentRuntimeIdentitySeed(
                    sessionID: "",
                    conversationID: "conversation-root",
                    taskID: "task-root",
                    actorID: "actor-root"
                )
            )
        }
        #expect(await provider.callCount() == 0)
    }

    @Test("a seed that disagrees with the composition-root conversation fails closed")
    func mismatchedParentSeedFailsClosed() async {
        let controller = TurnController()
        let provider = R28WP2CountingProvider()
        let loop = AgentLoop(maxIterations: 1, turnController: controller, loopDetector: nil)

        await #expect(throws: ParentRuntimeIdentitySeedError.conversationMismatch) {
            _ = try await loop.run(
                messages: [LLMMessage(role: .user, content: "finish")],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: R28WP2NoopExecutor(),
                tools: [],
                currentConversationID: "conversation-a",
                parentIdentitySeed: ParentRuntimeIdentitySeed(
                    sessionID: "session-root",
                    conversationID: "conversation-b",
                    taskID: "task-root",
                    actorID: "actor-root"
                )
            )
        }
        #expect(await provider.callCount() == 0)
    }

    @Test("production orchestration without the exact handle makes zero child calls")
    func productionMissingHandleFailsClosed() async {
        let provider = R28WP2CountingProvider()
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: R28WP2NoopExecutor(),
            parentBinding: r28wp2ParentSnapshot(),
            runtimeMode: .production
        )

        let reports = await orchestrator.orchestrate(
            tasks: [R28WP2ChildTask()],
            strategy: .sequential
        )

        #expect(reports.first?.result == .failed(error: "PARENT_TURN_UNVERIFIED"))
        #expect(await provider.callCount() == 0)
    }

    @Test("a cancelled exact parent handle blocks child dispatch")
    func cancelledParentHandleFailsClosed() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        await parentTurn.interrupt()
        let provider = R28WP2CountingProvider()
        let orchestrator = R28WP2Orchestrator(
            provider: provider,
            controller: controller,
            parentTurn: parentTurn,
            parentID: "cancel-parent"
        )

        let reports = await orchestrator.orchestrate(
            tasks: [R28WP2ChildTask()],
            strategy: .sequential
        )

        #expect(reports.first?.result == .failed(error: "任务已取消"))
        #expect(await provider.callCount() == 0)
        await parentTurn.finish()
    }

    @Test("A/B turns sharing one controller cancel only the exact parent")
    func siblingParentHandlesDoNotCrossCancel() async throws {
        let controller = TurnController()
        let parentA = await controller.beginTurn()
        let parentB = await controller.beginTurn()
        await parentA.interrupt()
        let providerA = R28WP2CountingProvider()
        let providerB = R28WP2CountingProvider()
        let orchestratorA = R28WP2Orchestrator(
            provider: providerA,
            controller: controller,
            parentTurn: parentA,
            parentID: "parent-a"
        )
        let orchestratorB = R28WP2Orchestrator(
            provider: providerB,
            controller: controller,
            parentTurn: parentB,
            parentID: "parent-b"
        )

        let reportsA = await orchestratorA.orchestrate(
            tasks: [R28WP2ChildTask(id: "child-a")],
            strategy: .sequential
        )
        let reportsB = await orchestratorB.orchestrate(
            tasks: [R28WP2ChildTask(id: "child-b")],
            strategy: .sequential
        )

        #expect(reportsA.first?.result == .failed(error: "任务已取消"))
        #expect(await providerA.callCount() == 0)
        #expect(reportsB.first?.result.isSuccess == true)
        #expect(await providerB.callCount() == 1)
        await parentA.finish()
        await parentB.finish()
    }

    @Test("ended or mismatched parent handles cannot dispatch a child")
    func endedOrMismatchedParentFailsClosed() async throws {
        let controller = TurnController()
        let endedTurn = await controller.beginTurn()
        await endedTurn.finish()
        let endedProvider = R28WP2CountingProvider()
        let endedOrchestrator = R28WP2Orchestrator(
            provider: endedProvider,
            controller: controller,
            parentTurn: endedTurn,
            parentID: "ended-parent"
        )
        let endedReports = await endedOrchestrator.orchestrate(
            tasks: [R28WP2ChildTask(id: "ended-child")],
            strategy: .sequential
        )

        let mismatchTurn = await controller.beginTurn()
        let mismatchProvider = R28WP2CountingProvider()
        let mismatchOrchestrator = R28WP2Orchestrator(
            provider: mismatchProvider,
            controller: controller,
            parentTurn: mismatchTurn,
            parentID: "mismatch-parent",
            parentTurnIDOverride: "turn-handle:999"
        )
        let mismatchReports = await mismatchOrchestrator.orchestrate(
            tasks: [R28WP2ChildTask(id: "mismatch-child")],
            strategy: .sequential
        )

        #expect(endedReports.first?.result == .failed(error: "任务已取消"))
        #expect(await endedProvider.callCount() == 0)
        #expect(mismatchReports.first?.result.isSuccess == false)
        #expect(await mismatchProvider.callCount() == 0)
        await mismatchTurn.finish()
    }

    @Test("late success and duplicate finish can produce only one terminal decision")
    func lateResultAndDuplicateFinishAreClosed() async throws {
        let child = try ChildRuntimeIdentity.derive(
            parent: ParentRuntimeIdentity(
                sessionID: "session-root",
                conversationID: "conversation-root",
                turnID: "turn-handle:1",
                taskID: "task-root",
                actorID: "actor-root"
            ),
            childSessionID: "child-session",
            childTaskID: "child-task",
            scopeID: "child-scope",
            requestedCapabilities: [],
            parentCapabilities: [],
            policyCapabilities: [],
            providerSnapshot: r28wp2ParentSnapshot(),
            memoryScopeID: "memory",
            workingDirectory: "/tmp",
            cancelGeneration: 1,
            evidenceRoot: "/tmp/evidence"
        )
        let resultGuard = ChildResultGuard(identity: child)

        #expect(await resultGuard.accept(.success, generation: 1))
        #expect(await resultGuard.accept(.success, generation: 1) == false)
        #expect(await resultGuard.accept(.cancelled, generation: 1) == false)
    }
}

private actor R28WP2ParentContextProbe {
    private var captured: AgentExecutionContextSnapshot?

    func record(_ context: AgentExecutionContextSnapshot?) {
        captured = context
    }

    func context() -> AgentExecutionContextSnapshot? {
        captured
    }
}

private struct R28WP2ParentContextProvider: LLMProvider {
    let name = "r28-wp2-provider"
    var model = LLMModel(id: "gpt-5.6-sol", displayName: "gpt-5.6-sol", provider: "r28-wp2-provider")
    let probe: R28WP2ParentContextProbe

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await probe.record(AgentExecutionContext.current)
        return LLMResponse(text: "done", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private struct R28WP2NoopExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        "ok"
    }
}

private actor R28WP2CallCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private enum R28WP2Fixtures {
    static let value = ParentContextSnapshotV1(
        providerID: "r28-wp2-provider",
        modelID: "gpt-5.6-sol",
        configurationFingerprint: "r28-wp2-fingerprint",
        conversationID: "conversation-root"
    )
}

private final class R28WP2CountingProvider: LLMProvider, @unchecked Sendable {
    let name = "r28-wp2-provider"
    var model = LLMModel(id: "gpt-5.6-sol", displayName: "gpt-5.6-sol", provider: "r28-wp2-provider")
    private let counter = R28WP2CallCounter()

    func callCount() async -> Int {
        await counter.count
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await counter.record()
        return LLMResponse(text: "child-done", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private func r28wp2ParentSnapshot() -> ParentContextSnapshotV1 {
    R28WP2Fixtures.value
}

private func R28WP2ChildTask(id: String = "child") -> SubAgentTask {
    SubAgentTask(id: id, title: id, instructions: "finish")
}

private func R28WP2Orchestrator(
    provider: any LLMProvider,
    controller: TurnController,
    parentTurn: TurnController.TurnHandle,
    parentID: String,
    parentTurnIDOverride: String? = nil
) -> AgentOrchestrator {
    AgentOrchestrator(
        provider: provider,
        toolExecutor: R28WP2NoopExecutor(),
        turnController: controller,
        taskStore: AgentTaskStore(),
        parentID: parentID,
        parentBinding: r28wp2ParentSnapshot(),
        parentRuntimeIdentity: ParentRuntimeIdentity(
            sessionID: "session-root",
            conversationID: "conversation-root",
            turnID: parentTurnIDOverride ?? "turn-handle:\(parentTurn.turnID)",
            taskID: parentID,
            actorID: "actor-root"
        ),
        parentTurnHandle: parentTurn,
        runtimeMode: .production,
        capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
        parentCapabilities: [.streaming]
    )
}
