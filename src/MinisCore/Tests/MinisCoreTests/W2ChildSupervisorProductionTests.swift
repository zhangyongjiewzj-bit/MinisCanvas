import Foundation
import Testing
@testable import MinisCore

@Suite("W2 child supervisor production consumer")
struct W2ChildSupervisorProductionTests {
    @Test("production child dispatch records supervised progress before its receipt")
    func productionDispatchRecordsSupervisedLifecycle() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer {
            Task { await parentTurn.finish() }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("W2RootBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistenceURL = directory.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: persistenceURL)
        let provider = W2SupervisorProvider()
        let parent = ParentRuntimeIdentity(
            sessionID: "w2-session",
            conversationID: "w2-conversation",
            turnID: "turn-handle:\(parentTurn.turnID)",
            taskID: "w2-parent",
            actorID: "app"
        )
        let parentGoal = GoalEnvelope(
            scopeID: "production:agent",
            allowedCapabilities: ["orchestrate"],
            budget: 10,
            deadline: Date().addingTimeInterval(60)
        )
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: W2SupervisorNoopExecutor(),
            currentConversationID: "w2-conversation",
            taskStore: store,
            parentID: "w2-parent",
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name,
                modelID: provider.model.id,
                configurationFingerprint: "w2-fingerprint",
                conversationID: "w2-conversation"
            ),
            parentRuntimeIdentity: parent,
            parentGoal: parentGoal,
            parentTurnHandle: parentTurn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming],
                allowedToolNames: [],
                allowedMCPToolNames: []
            ),
            parentCapabilities: provider.capabilities
        )

        let reports = await orchestrator.orchestrate(
            tasks: [
                SubAgentTask(
                    id: "w2-child",
                    title: "child",
                    instructions: "complete"
                )
            ],
            strategy: .sequential
        )

        let receipt = try #require(store.allReceipts().first)
        let events = store.events(runID: receipt.runID)
        #expect(reports.first?.result.isSuccess == true)
        #expect(events.map(\.kind) == [.started, .progress, .completed])
        #expect(receipt.attemptID.hasSuffix(":attempt:1"))
        let child = try #require(store.snapshot(taskID: "w2-child", parentID: "w2-parent")?.childRuntimeIdentity)
        #expect(child.rootParentIdentity == parent)
        #expect(child.parentGoalID == parentGoal.goalID)
        #expect(child.parentGoalScopeID == parentGoal.scopeID)
        #expect(child.scopeID != parentGoal.scopeID)
        let recovered = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(recovered.snapshot(taskID: "w2-child", parentID: "w2-parent")?.childRuntimeIdentity == child)
    }

    @Test("durable child admission rejects forged root and foreign parent Goal without rejecting a private child scope")
    func childRootBoundaryUsesActualParentAuthority() async throws {
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let parent = ParentRuntimeIdentity(
            sessionID: "w2-root", conversationID: "w2-conversation",
            turnID: "turn-handle:\(handle.turnID)", taskID: "w2-parent", actorID: "app"
        )
        let goal = GoalEnvelope(scopeID: "parent-authority", allowedCapabilities: ["orchestrate"],
            budget: 10, deadline: Date().addingTimeInterval(60))
        let provider = ParentContextSnapshotV1(providerID: "w2-provider", modelID: "w2-model",
            configurationFingerprint: "w2-fingerprint", conversationID: parent.conversationID)
        func makeChild(parent identity: ParentRuntimeIdentity, goal boundary: GoalEnvelope?) throws -> ChildRuntimeIdentity {
            try ChildRuntimeIdentity.derive(parent: identity,
                childSessionID: "w2-child-session", childTaskID: "w2-child",
                scopeID: "w2-private-child-scope",
                requestedCapabilities: [.streaming], parentCapabilities: [.streaming],
                policyCapabilities: [.streaming], providerSnapshot: provider,
                memoryScopeID: "w2-memory", workingDirectory: "/tmp/w2-synthetic",
                cancelGeneration: handle.turnID, evidenceRoot: "w2-evidence",
                parentTurnHandle: handle, childExecutionID: "w2-execution", parentGoal: boundary)
        }
        let child = try makeChild(parent: parent, goal: goal)
        let store = AgentTaskStore()
        let otherGoalID = GoalEnvelope(scopeID: goal.scopeID,
            allowedCapabilities: goal.allowedCapabilities, budget: 10, deadline: goal.deadline)
        let otherScope = GoalEnvelope(goalID: goal.goalID, scopeID: "other-parent-authority",
            allowedCapabilities: goal.allowedCapabilities, budget: 10, deadline: goal.deadline)
        let forgedParent = ParentRuntimeIdentity(sessionID: parent.sessionID,
            conversationID: parent.conversationID, turnID: parent.turnID,
            taskID: parent.taskID, actorID: "forged-root")
        let forgedRoot = try makeChild(parent: forgedParent, goal: goal)
        for (candidate, actualGoal) in [(child, otherGoalID), (child, otherScope), (forgedRoot, goal)] {
            #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
                try store.enqueue(taskID: "w2-child", parentID: parent.taskID,
                    providerID: provider.providerID, modelID: provider.modelID,
                    parentRuntimeIdentity: parent, childRuntimeIdentity: candidate,
                    parentGoal: actualGoal)
            }
            #expect(store.snapshot(taskID: "w2-child", parentID: parent.taskID) == nil)
        }
        let admitted = try store.enqueue(taskID: "w2-child", parentID: parent.taskID,
            providerID: provider.providerID, modelID: provider.modelID,
            parentRuntimeIdentity: parent, childRuntimeIdentity: child, parentGoal: goal)
        #expect(admitted.childRuntimeIdentity == child)
        #expect(child.scopeID != goal.scopeID)

        let legacy = try makeChild(parent: parent, goal: nil)
        #expect(legacy.rootParentIdentity == nil)
        #expect(legacy.parentGoalScopeID == nil)
    }

    @Test("supervisor rejects a late writeback after a completed attempt")
    func completedAttemptRejectsLateWriteback() async throws {
        let supervisor = ChildSupervisor(childID: "w2-late")
        let attempt = try await supervisor.start()
        _ = try await supervisor.acceptWriteback(
            attemptID: attempt.attemptID,
            sequence: 1
        )
        _ = try await supervisor.complete(attemptID: attempt.attemptID)

        #expect(try await supervisor.acceptWriteback(
            attemptID: attempt.attemptID,
            sequence: 2
        ) == false)
    }

    @Test("production JSON input accepts an exact integral value after Composer freezing")
    func exactIntegralJSONVersionSurvivesComposerRehydration() throws {
        let request = try OrchestrateRequestV1.decode(
            input: [
                "input_version": Int64(1),
                "tasks": []
            ],
            maxTasks: OrchestrationToolExecutor.maxTasks
        )
        #expect(request.tasks.isEmpty)
        #expect(OrchestrateRequestV1.decodeInteger(1.0) == nil)
        #expect(OrchestrateRequestV1.decodeInteger(Float(1.0)) == nil)
        #expect(OrchestrateRequestV1.decodeInteger(1.5) == nil)
        #expect(OrchestrateRequestV1.decodeInteger(true) == nil)
        #expect(OrchestrateRequestV1.decodeInteger("1") == nil)

        let jsonInteger = try #require(
            JSONSerialization.jsonObject(
                with: Data(#"{"input_version":1,"tasks":[]}"#.utf8)
            ) as? [String: Any]
        )
        #expect(try OrchestrateRequestV1.decode(
            input: jsonInteger,
            maxTasks: OrchestrationToolExecutor.maxTasks
        ).tasks.isEmpty)
        let jsonIntegralFloat = try #require(
            JSONSerialization.jsonObject(
                with: Data(#"{"input_version":1.0,"tasks":[]}"#.utf8)
            ) as? [String: Any]
        )
        #expect(try OrchestrateRequestV1.decode(
            input: jsonIntegralFloat,
            maxTasks: OrchestrationToolExecutor.maxTasks
        ).tasks.isEmpty)
        let jsonFraction = try #require(
            JSONSerialization.jsonObject(
                with: Data(#"{"input_version":1.5,"tasks":[]}"#.utf8)
            ) as? [String: Any]
        )
        #expect(throws: ToolExecutorError.invalidParameter("input_version")) {
            try OrchestrateRequestV1.decode(
                input: jsonFraction,
                maxTasks: OrchestrationToolExecutor.maxTasks
            )
        }
        let jsonBoolean = try #require(
            JSONSerialization.jsonObject(
                with: Data(#"{"input_version":true,"tasks":[]}"#.utf8)
            ) as? [String: Any]
        )
        #expect(throws: ToolExecutorError.invalidParameter("input_version")) {
            try OrchestrateRequestV1.decode(
                input: jsonBoolean,
                maxTasks: OrchestrationToolExecutor.maxTasks
            )
        }
    }

    @Test("JSON integer stays an integer across the Composer input boundary")
    func composerFreezesJSONIntegerWithoutBooleanCoercion() throws {
        let object = try #require(
            JSONSerialization.jsonObject(
                with: Data(#"{"input_version":1,"enabled":true}"#.utf8)
            ) as? [String: Any]
        )
        let frozen = try ComposerToolInput(object)
        #expect(frozen.values["input_version"] == .integer(1))
        #expect(frozen.values["enabled"] == .bool(true))
        let smallInteger = try ComposerToolInput([
            "small": NSNumber(value: Int8(1))
        ])
        #expect(smallInteger.values["small"] == .integer(1))
    }
}

private struct W2SupervisorNoopExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        "ok"
    }
}

private struct W2SupervisorProvider: LLMProvider {
    let name = "w2-provider"
    var model = LLMModel(
        id: "w2-model",
        displayName: "W2 model",
        provider: "w2-provider"
    )
    let capabilities: Set<ProviderCapability> = [.streaming]

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "child complete", stopReason: "stop", usage: nil)
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
