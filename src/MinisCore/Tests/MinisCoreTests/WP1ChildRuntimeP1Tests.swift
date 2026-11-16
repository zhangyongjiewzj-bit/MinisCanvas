import Foundation
import Testing
@testable import MinisCore

@Suite("WP-1 child runtime P1")
struct WP1ChildRuntimeP1Tests {
    @Test
    func legacyAndProductionRuntimeModesAreExplicitlySeparated() {
        let legacy = AgentOrchestrator(
            provider: WP1ContextCapturingProvider(name: "legacy-provider", modelID: "legacy-model")
        )
        let production = AgentOrchestrator(
            taskStore: AgentTaskStore(),
            parentID: "parent-task",
            capabilityPolicy: .denyAll
        )

        #expect(legacy.runtimeMode == .legacyLibrary)
        #expect(production.runtimeMode == .production)
    }

    @Test
    func explicitProductionWithoutParentTurnFailsClosed() async {
        let probe = WP1ContextCapturingProvider(
            name: "production-provider",
            modelID: "production-model"
        )
        let orchestrator = AgentOrchestrator(
            provider: probe,
            runtimeMode: .production
        )

        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: "child", title: "child", instructions: "run")]
        )

        #expect(reports.first?.result == .failed(error: "PARENT_TURN_UNVERIFIED"))
        #expect(await probe.callCount() == 0)
    }

    @Test
    func cancellationClosesResultGuardBeforeLateSuccess() async throws {
        let child = try makeChild(generation: 7)
        let guardrail = ChildResultGuard(identity: child)

        #expect(await guardrail.accept(.cancelled, generation: 7) == false)
        #expect(await guardrail.accept(.success, generation: 7) == false)
    }

    @Test
    func strictResultGuardRejectsLegacyAndMismatchedCompositeIdentity() async throws {
        let legacy = try makeChild(generation: 1)
        let strict = ChildResultGuard(identity: legacy, requireVerifiedIdentity: true)
        #expect(await strict.isReady() == false)
        #expect(await strict.accept(.success, generation: 1) == false)
        #expect(await strict.cancel(generation: 1) == false)
        #expect(await strict.recover() == false)

        let composed = try makeChild(
            generation: 1,
            childSessionID: "child-\u{00E9}",
            childTaskID: "task-\u{00E9}"
        )
        let decomposed = try makeChild(
            generation: 1,
            childSessionID: "child-e\u{0301}",
            childTaskID: "task-e\u{0301}"
        )
        let identityGuard = ChildResultGuard(identity: composed)
        #expect(await identityGuard.accept(
            .success,
            identity: decomposed,
            generation: 1
        ) == false)
        #expect(await identityGuard.accept(
            .success,
            identity: composed,
            generation: 1
        ) == true)

        let recoveryGuard = ChildResultGuard(identity: composed)
        #expect(await recoveryGuard.accept(
            .timedOut,
            identity: composed,
            generation: 1
        ) == true)
        #expect(await recoveryGuard.recover(identity: composed) == true)
    }

    @Test
    func resultGuardClosesAtGenerationCeilingWithoutOverflow() async throws {
        let guardrail = ChildResultGuard(identity: try makeChild(generation: Int.max - 1))

        #expect(await guardrail.accept(.timedOut, generation: Int.max - 1) == true)
        #expect(await guardrail.recover() == true)
        #expect(await guardrail.cancel(generation: Int.max) == false)
        #expect(await guardrail.accept(.success, generation: Int.max) == false)
    }

    @Test
    func productionLifecycleWithoutParentTurnFailsClosed() async throws {
        let store = AgentTaskStore()
        let probe = WP1ContextCapturingProvider(
            name: "parent-provider",
            modelID: "parent-model"
        )
        let parent = ParentContextSnapshotV1(
            providerID: "parent-provider",
            modelID: "parent-model",
            configurationFingerprint: "parent-fingerprint",
            conversationID: "parent-conversation"
        )
        let orchestrator = AgentOrchestrator(
            provider: probe,
            toolExecutor: WP1NoopExecutor(),
            taskStore: store,
            parentID: "parent-task",
            parentBinding: parent,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming],
                allowedToolNames: [],
                allowedMCPToolNames: []
            )
        )

        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: "child", title: "child", instructions: "run")]
        )

        #expect(reports.first?.result == .failed(error: "PARENT_TURN_UNVERIFIED"))
        #expect(await probe.callCount() == 0)
        #expect(store.allReceipts().first?.outcome == .failed(reason: "execution-failed"))
    }

    @Test
    func childRuntimeUsesResolvedProviderModelAndConversationBinding() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        let parent = ParentContextSnapshotV1(
            providerID: "parent-provider",
            modelID: "parent-model",
            configurationFingerprint: "parent-fingerprint",
            conversationID: "parent-conversation"
        )
        let selected = WP1ContextCapturingProvider(
            name: "child-provider",
            modelID: "child-model"
        )
        let fallback = WP1ContextCapturingProvider(
            name: "fallback-provider",
            modelID: "fallback-model"
        )
        let task = SubAgentTask(
            id: "bound-child",
            title: "bound child",
            instructions: "run",
            providerID: "child-provider",
            modelID: "child-model",
            configurationFingerprint: "child-fingerprint",
            bindingSource: .explicit
        )
        let orchestrator = AgentOrchestrator(
            provider: fallback,
            toolExecutor: WP1NoopExecutor(),
            currentConversationID: "stale-conversation",
            resolveChildProvider: { _, _ in selected },
            taskStore: AgentTaskStore(),
            parentBinding: parent,
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: "session-parent",
                conversationID: "parent-conversation",
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "parent-task",
                actorID: "parent-agent"
            ),
            parentTurnHandle: parentTurn,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentCapabilities: []
        )

        let reports = await orchestrator.orchestrate(
            tasks: [task],
            strategy: OrchestrationStrategy.sequential
        )

        #expect(reports.first?.result.isSuccess == true)
        #expect(await selected.snapshot() == ParentContextSnapshotV1(
            providerID: "child-provider",
            modelID: "child-model",
            configurationFingerprint: "child-fingerprint",
            conversationID: "parent-conversation"
        ))
        #expect(await fallback.callCount() == 0)
        await parentTurn.finish()
    }

    @Test
    func childGenerationUsesRealParentTurnHandleAndChildIdentity() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        let parent = ParentRuntimeIdentity(
            sessionID: "session-parent",
            conversationID: "conversation-parent",
            turnID: "turn-handle:\(parentTurn.turnID)",
            taskID: "parent-task",
            actorID: "parent-agent"
        )
        let snapshot = ParentContextSnapshotV1(
            providerID: "parent-provider",
            modelID: "parent-model",
            configurationFingerprint: "parent-fingerprint",
            conversationID: parent.conversationID
        )
        let task = SubAgentTask(
            id: "child",
            title: "child",
            instructions: "run",
            executionID: "execution-1"
        )
        let orchestrator = AgentOrchestrator(
            parentID: parent.taskID,
            parentBinding: snapshot,
            parentRuntimeIdentity: parent,
            parentTurnHandle: parentTurn
        )

        let identity = try orchestrator.makeChildRuntimeIdentity(for: task)

        #expect(identity.parentTurnID == parent.turnID)
        #expect(identity.parentTurnID != snapshot.snapshotID)
        #expect(identity.cancelGeneration == parentTurn.turnID)
        #expect(identity.compositeIdentityKey.contains("session-parent"))
        #expect(identity.generationID?.contains("parent-turn:\(parentTurn.turnID)") == true)
        #expect(identity.generationID?.contains("parent-session:\(parent.sessionID)") == true)
        #expect(identity.generationID?.contains("child-session:\(identity.childSessionID)") == true)
        #expect(identity.generationID?.contains("child-task:\(task.id)") == true)
        let rebound = try orchestrator.makeChildRuntimeIdentity(for: SubAgentTask(
            id: task.id,
            title: task.title,
            instructions: task.instructions,
            executionID: "execution-2"
        ))
        #expect(rebound.childTaskID == identity.childTaskID)
        #expect(rebound.childSessionID != identity.childSessionID)
        #expect(rebound.generationID != identity.generationID)
        #expect(rebound.compositeIdentityKey != identity.compositeIdentityKey)
        await parentTurn.finish()
    }

    @Test
    func childIdentityRejectsInvalidParentAndNegativeDecodedGeneration() throws {
        let invalidParent = ParentRuntimeIdentity(
            sessionID: "",
            conversationID: "conversation",
            turnID: "turn",
            taskID: "parent",
            actorID: "actor"
        )
        #expect(throws: ChildRuntimeIdentityError.invalidField("parentRuntimeIdentity")) {
            try ChildRuntimeIdentity.derive(
                parent: invalidParent,
                childSessionID: "child-session",
                childTaskID: "child-task",
                scopeID: "scope",
                requestedCapabilities: [],
                parentCapabilities: [],
                policyCapabilities: [],
                providerSnapshot: ParentContextSnapshotV1(
                    providerID: "provider",
                    modelID: "model",
                    configurationFingerprint: "fingerprint",
                    conversationID: "conversation"
                ),
                memoryScopeID: "memory",
                workingDirectory: "/tmp",
                cancelGeneration: 1,
                evidenceRoot: "evidence"
            )
        }

        let child = try makeChild(generation: 1)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(child))
                as? [String: Any]
        )
        object["cancelGeneration"] = -1
        let encoded = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChildRuntimeIdentity.self, from: encoded)
        }

        object["cancelGeneration"] = child.cancelGeneration
        object["schemaVersion"] = ChildRuntimeIdentity.currentSchemaVersion + 1
        let unknownVersion = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChildRuntimeIdentity.self, from: unknownVersion)
        }

        object["schemaVersion"] = ChildRuntimeIdentity.currentSchemaVersion
        object["childSessionID"] = String(repeating: "x", count: 4_097)
        let oversized = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChildRuntimeIdentity.self, from: oversized)
        }

        let composed = try makeChild(
            generation: 1,
            childSessionID: "child-\u{00E9}",
            childTaskID: "task-\u{00E9}"
        )
        let decomposed = try makeChild(
            generation: 1,
            childSessionID: "child-e\u{0301}",
            childTaskID: "task-e\u{0301}"
        )
        #expect(composed.compositeIdentityKey != decomposed.compositeIdentityKey)
    }

    @Test
    func productionLedgerUsesParentTaskIdentityInsteadOfConversationFallback() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        let parentIdentity = ParentRuntimeIdentity(
            sessionID: "session-parent",
            conversationID: "conversation-parent",
            turnID: "turn-handle:\(parentTurn.turnID)",
            taskID: "parent-task",
            actorID: "parent-agent"
        )
        let store = AgentTaskStore()
        let provider = WP1ContextCapturingProvider(
            name: "parent-provider",
            modelID: "parent-model"
        )
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: WP1NoopExecutor(),
            taskStore: store,
            parentID: parentIdentity.conversationID,
            parentBinding: ParentContextSnapshotV1(
                providerID: "parent-provider",
                modelID: "parent-model",
                configurationFingerprint: "parent-fingerprint",
                conversationID: parentIdentity.conversationID
            ),
            parentRuntimeIdentity: parentIdentity,
            parentTurnHandle: parentTurn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentCapabilities: []
        )

        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: "child", title: "child", instructions: "run")],
            strategy: .sequential
        )

        #expect(reports.first?.result.isSuccess == true)
        let snapshot = try #require(store.snapshot(taskID: "child", parentID: parentIdentity.taskID))
        #expect(snapshot.parentID == parentIdentity.taskID)
        #expect(store.snapshot(taskID: "child", parentID: parentIdentity.conversationID) == nil)
        await parentTurn.finish()
    }

    @Test
    func taskCenterStopCancelsTheRunningProductionChild() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        let parentIdentity = ParentRuntimeIdentity(
            sessionID: "session-parent",
            conversationID: "conversation-parent",
            turnID: "turn-handle:\(parentTurn.turnID)",
            taskID: "parent-task",
            actorID: "parent-agent"
        )
        let store = AgentTaskStore()
        let probe = WP1CancellableRunnerProbe()
        let runner = WP1CancellableExternalRunner(probe: probe)
        let orchestrator = AgentOrchestrator(
            externalRunners: [runner.name: runner],
            taskStore: store,
            parentID: parentIdentity.taskID,
            parentBinding: ParentContextSnapshotV1(
                providerID: "runner-provider",
                modelID: "runner-model",
                configurationFingerprint: "runner-fingerprint",
                conversationID: parentIdentity.conversationID
            ),
            parentRuntimeIdentity: parentIdentity,
            parentTurnHandle: parentTurn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentCapabilities: [.streaming]
        )
        let invocation = Task {
            await orchestrator.orchestrate(
                tasks: [
                    SubAgentTask(
                        id: "child",
                        title: "child",
                        instructions: "hold",
                        agentType: .external(name: runner.name)
                    )
                ],
                strategy: .sequential
            )
        }

        #expect(await probe.waitUntilStarted())
        let control = try #require(store.controlSnapshot(taskID: "child", parentID: parentIdentity.taskID))
        let runID = try #require(control.runID)
        let receipt = AgentTaskControlReceipt(
            taskID: "child",
            parentID: parentIdentity.taskID,
            idempotencyKey: "stop-child",
            command: .stop,
            revision: "test-revision",
            scopeID: "test-scope",
            actorID: "test-actor",
            runID: runID,
            resultingRunID: nil,
            controlState: .stopped,
            controlRevision: control.controlRevision + 1,
            cancelledTaskIDs: ["child"]
        )
        _ = try store.applyControl(
            taskID: "child",
            parentID: parentIdentity.taskID,
            command: .stop,
            expectedControlRevision: control.controlRevision,
            runID: runID,
            resultingRunID: nil,
            receipt: receipt
        )

        #expect(await probe.waitUntilCancelled())
        _ = await invocation.value
        #expect(store.snapshot(taskID: "child", parentID: parentIdentity.taskID)?.status == .cancelled)
        await parentTurn.finish()
    }

    private func makeChild(
        generation: Int,
        childSessionID: String = "child-session",
        childTaskID: String = "child-task"
    ) throws -> ChildRuntimeIdentity {
        try ChildRuntimeIdentity.derive(
            parent: ParentRuntimeIdentity(
                sessionID: "session",
                conversationID: "conversation",
                turnID: "turn",
                taskID: "parent",
                actorID: "actor"
            ),
            childSessionID: childSessionID,
            childTaskID: childTaskID,
            scopeID: "scope",
            requestedCapabilities: [],
            parentCapabilities: [],
            policyCapabilities: [],
            providerSnapshot: ParentContextSnapshotV1(
                providerID: "provider",
                modelID: "model",
                configurationFingerprint: "fingerprint",
                conversationID: "conversation"
            ),
            memoryScopeID: "memory",
            workingDirectory: "/tmp",
            cancelGeneration: generation,
            evidenceRoot: "/tmp/evidence"
        )
    }
}

private final class WP1ContextCapturingProvider: LLMProvider, @unchecked Sendable {
    let name: String
    var model: LLMModel
    private let probe = WP1ProviderProbe()

    init(name: String, modelID: String) {
        self.name = name
        model = LLMModel(id: modelID, displayName: modelID, provider: name)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await probe.record(binding: AgentExecutionContext.current?.parentBinding)
        return LLMResponse(text: "ok", stopReason: nil, usage: nil)
    }

    func snapshot() async -> ParentContextSnapshotV1? {
        await probe.snapshot()
    }

    func callCount() async -> Int {
        await probe.callCount
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

private actor WP1ProviderProbe {
    private(set) var callCount = 0
    private(set) var binding: ParentContextSnapshotV1?

    func record(binding: ParentContextSnapshotV1?) {
        callCount += 1
        self.binding = binding
    }

    func snapshot() -> ParentContextSnapshotV1? {
        binding
    }
}

private struct WP1NoopExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        "ok"
    }
}

private actor WP1CancellableRunnerProbe {
    private var started = false
    private var cancelled = false

    func markStarted() {
        started = true
    }

    func markCancelled() {
        cancelled = true
    }

    func waitUntilStarted() async -> Bool {
        await waitUntil { started }
    }

    func waitUntilCancelled() async -> Bool {
        await waitUntil { cancelled }
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

private struct WP1CancellableExternalRunner: ExternalAgentRunner {
    let name = "wp1-cancellable"
    let isAvailable = true
    let capabilities: Set<ProviderCapability> = [.streaming]
    let probe: WP1CancellableRunnerProbe

    func run(task: SubAgentTask) async throws -> String {
        await probe.markStarted()
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func cancel(task: SubAgentTask) async {
        await probe.markCancelled()
    }
}
