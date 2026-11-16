import Foundation
import Testing
@testable import MinisCore

private final class Lineage2322Provider: LLMProvider, @unchecked Sendable {
    let name = "lineage2322-local"
    var model = LLMModel(id: "lineage2322", displayName: "Lineage2322", provider: "lineage2322-local")
    let capabilities: Set<ProviderCapability> = [.tools, .streaming]
    private let lock = NSLock()
    private var childCalls = 0
    private var rootCalls = 0
    private var released: Bool
    init(released: Bool = false) { self.released = released }
    var childRequestCount: Int { lock.withLock { childCalls } }
    var parentRequestCount: Int { lock.withLock { rootCalls } }
    func release() { lock.withLock { released = true } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        if messages.last(where: { $0.role == .user })?.content == "controlled child" {
            lock.withLock { childCalls += 1 }
            for _ in 0..<1000 {
                if lock.withLock({ released }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try Task.checkCancellation()
            return LLMResponse(text: "owned child complete", stopReason: "stop", usage: nil)
        }
        let call = lock.withLock { rootCalls += 1; return rootCalls }
        if call == 1 {
            let input: [String: Any] = ["input_version": 2, "strategy": "sequential", "tasks": [[
                "id": "shared-child", "title": "owned child", "instructions": "controlled child",
                "required_capabilities": [ProviderCapability.streaming.rawValue],
                "allowed_tool_names": [], "allowed_read_roots": []
            ]]]
            let bytes = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
                LLMToolCall(id: "owned-orchestration", name: OrchestrationToolExecutor.toolName,
                    rawArguments: String(decoding: bytes, as: UTF8.self), arguments: input)
            ])
        }
        return LLMResponse(text: "owned parent complete", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct Lineage2322NoTool: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.unknownTool(name)
    }
}
private actor Lineage2322Approval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// This test adapter only uses the actual parent's TaskLocal facts to create
/// the existing production orchestrator. It neither mints lineage nor settles
/// child/parent facts; both producers remain the original Core implementations.
private final class Lineage2322Composition: ToolExecutor, @unchecked Sendable {
    let store: AgentTaskStore
    let provider: Lineage2322Provider
    let goal: GoalEnvelope
    private let lock = NSLock()
    private var origin: ParentRuntimeIdentity?
    var parent: ParentRuntimeIdentity? { lock.withLock { origin } }
    init(store: AgentTaskStore, provider: Lineage2322Provider, goal: GoalEnvelope) {
        self.store = store; self.provider = provider; self.goal = goal
    }
    func execute(name: String, input: [String: Any]) async throws -> String {
        guard let context = AgentExecutionContext.current,
              let parent = context.parentRuntimeIdentity,
              let handle = context.parentTurnHandle, let binding = context.parentBinding else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }
        guard await handle.isActive(), await handle.isCancelled() == false,
              parent.turnID == "turn-handle:\(handle.turnID)",
              parent.sessionID == context.currentConversationID,
              binding.conversationID == parent.conversationID,
              let gate = context.approvalGate,
              let ledger = context.toolExecutionFactLedger,
              context.provider.capabilities.contains(.streaming) else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }
        lock.withLock { origin = parent }
        let orchestrator = AgentOrchestrator(provider: provider, toolExecutor: Lineage2322NoTool(),
            approvalGate: gate, turnController: context.turnController,
            currentConversationID: parent.conversationID, taskStore: store,
            toolExecutionFactLedger: ledger, parentID: parent.taskID,
            parentBinding: binding, parentRuntimeIdentity: parent, parentGoal: goal,
            parentTurnHandle: handle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming],
                allowedToolNames: [], allowedMCPToolNames: []), parentCapabilities: [.streaming],
            parentComposerSnapshot: context.composerSnapshot, parentComposerFacts: context.composerPolicyFacts,
            parentAuthorityCheck: context.parentAuthorityCheck)
        return try await OrchestrationToolExecutor(orchestrator: orchestrator).execute(name: name, input: input)
    }
}

@Suite("H3A/H3B actual parent lineage and orphan consumer", .serialized)
struct ParentLineageOrphanProduction2322Tests {
    private func startParent(store: AgentTaskStore, provider: Lineage2322Provider,
                             root: URL, name: String, controller: TurnController)
        throws -> (Lineage2322Composition, AgentExecutionIdentity, Task<AgentLoopResult, Error>) {
        let goal = GoalEnvelope(scopeID: "\(name)-authority", allowedCapabilities: ["orchestrate"],
            budget: 100, deadline: Date().addingTimeInterval(60), autonomyLevel: .l3)
        let composition = Lineage2322Composition(store: store, provider: provider, goal: goal)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "\(name)-session",
            turnID: 1, messageID: "\(name)-message"), operationID: "\(name)-operation", attempt: 1)
        let facts = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("\(name)-tools.json"))
        let loop = AgentLoop(maxIterations: 3, approvalGate: ApprovalGate(delegate: Lineage2322Approval()),
            turnController: controller, timeout: 20, taskStore: store,
            toolExecutionFactLedger: facts)
        let task = Task {
            try await loop.run(messages: [LLMMessage(role: .user, content: "dispatch root")],
                systemPrompt: nil, provider: provider, toolExecutor: composition,
                tools: [OrchestrationToolExecutor.makeDefinition()], currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                    conversationID: identity.turn.sessionID, taskID: "\(name)-parent", actorID: "owned-app"),
                executionIdentity: identity)
        }
        return (composition, identity, task)
    }

    @Test("actual parent joins only its own lineage; a running crash snapshot never replays",
          arguments: [false, true])
    func actualParentOrphanDoesNotCrossRootOrReplay(cancelParent: Bool) async throws {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("lineage2322-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalURL = root.appendingPathComponent("original.json")
        let store = try AgentTaskStore(persistenceURL: originalURL)
        let provider = Lineage2322Provider()
        defer { provider.release() }
        let controller = TurnController()
        let (composition, execution, runningParent) = try startParent(store: store, provider: provider,
            root: root, name: "original", controller: controller)
        for _ in 0..<300 {
            if provider.childRequestCount == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if provider.childRequestCount == 0 { _ = try await runningParent.value }
        #expect(provider.childRequestCount == 1)
        let parent = try #require(composition.parent)
        let childTask = try #require(store.snapshot(taskID: "shared-child", parentID: parent.taskID))
        let childIdentity = try #require(childTask.childRuntimeIdentity)
        let runID = try #require(store.controlSnapshot(taskID: childTask.taskID, parentID: parent.taskID)?.runID)
        #expect(childTask.status == .running)
        #expect(store.receipt(runID: runID) == nil)
        #expect(childIdentity.rootParentIdentity == parent)
        #expect(childIdentity.parentGoalID == composition.goal.goalID)
        #expect(childIdentity.parentGoalScopeID == composition.goal.scopeID)
        #expect(childIdentity.scopeID != composition.goal.scopeID)
        // This is the actual producer's durable running point, copied before
        // cancellation/completion. It models a crash without killing a runner.
        let orphanURL = root.appendingPathComponent("crash-point.json")
        let crashBytes = try Data(contentsOf: originalURL)
        try crashBytes.write(to: orphanURL)
        if cancelParent { await controller.interrupt(turnID: execution.turn.turnID) }
        provider.release()
        if cancelParent {
            _ = try? await runningParent.value
        } else {
            _ = try await runningParent.value
        }
        let liveJoin = try #require(store.parentTurnTerminalFact(parent: parent, execution: execution))
        #expect(liveJoin.outcome == (cancelParent ? .cancelled : .succeeded))
        #expect(liveJoin.children.count == 1)
        #expect(liveJoin.children.first?.runID == runID)
        #expect(liveJoin.children.first?.outcome == (cancelParent ? .cancelled : .succeeded))
        let liveReopen = try AgentTaskStore(persistenceURL: originalURL)
        #expect(liveReopen.parentTurnTerminalFact(parent: parent, execution: execution) == liveJoin)

        let reopened = try AgentTaskStore(persistenceURL: orphanURL)
        #expect(reopened.taskSnapshot(runID: runID)?.childRuntimeIdentity == childIdentity)
        #expect(reopened.recoveryState(runID: runID) == .needsUserReview)
        #expect(reopened.externalSubmissionDecision(runID: runID) == .needsUserReview)
        #expect(reopened.receipt(runID: runID) == nil)
        #expect(reopened.parentTurnTerminalFact(parent: parent, execution: execution) == nil)
        let replayProvider = Lineage2322Provider(released: true)
        let freshController = TurnController()
        let handle = await freshController.beginTurn()
        defer { Task { await handle.finish() } }
        for foreignRoot in [false, true] {
            let rootIdentity = foreignRoot ? ParentRuntimeIdentity(sessionID: "foreign-session",
                conversationID: "foreign-session", turnID: parent.turnID,
                taskID: parent.taskID, actorID: parent.actorID) : parent
            let boundary = foreignRoot ? GoalEnvelope(scopeID: "foreign-authority",
                allowedCapabilities: ["orchestrate"], budget: 100,
                deadline: Date().addingTimeInterval(60)) : composition.goal
            let binding = ParentContextSnapshotV1(providerID: replayProvider.name,
                modelID: replayProvider.model.id, configurationFingerprint: "owned-replay",
                conversationID: rootIdentity.conversationID)
            let actual = AgentOrchestrator(provider: replayProvider, toolExecutor: Lineage2322NoTool(),
                currentConversationID: rootIdentity.conversationID, taskStore: reopened,
                parentID: rootIdentity.taskID, parentBinding: binding, parentRuntimeIdentity: rootIdentity,
                parentGoal: boundary, parentTurnHandle: handle, runtimeMode: .production,
                capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming],
                    allowedToolNames: [], allowedMCPToolNames: []), parentCapabilities: [.streaming])
            let reports = await actual.orchestrate(tasks: [SubAgentTask(id: childTask.taskID,
                title: "replay", instructions: "controlled child")], strategy: .sequential)
            #expect(reports.first?.result.isSuccess == false)
            #expect(replayProvider.childRequestCount == 0)
            #expect(reopened.allReceipts().isEmpty)
            #expect(try Data(contentsOf: orphanURL) == crashBytes)
        }
        // A distinct root/parent is a new authorized execution, not recovery
        // of the old UNKNOWN attempt. Actual parent join cannot adopt the old
        // child merely because both roots use the same display/task ID.
        let newProvider = Lineage2322Provider(released: true)
        let newController = TurnController()
        let (newComposition, newExecution, newParentTask) = try startParent(store: reopened,
            provider: newProvider, root: root, name: "new-root", controller: newController)
        _ = try await newParentTask.value
        let newParent = try #require(newComposition.parent)
        #expect(newParent.sessionID != parent.sessionID)
        #expect(newComposition.goal.scopeID != composition.goal.scopeID)
        #expect(newProvider.parentRequestCount == 2 && newProvider.childRequestCount == 1)
        let newJoin = try #require(reopened.parentTurnTerminalFact(parent: newParent, execution: newExecution))
        #expect(newJoin.outcome == .succeeded && newJoin.children.count == 1)
        #expect(newJoin.children.first?.runID != runID)
        #expect(reopened.receipt(runID: runID) == nil)
        #expect(reopened.recoveryState(runID: runID) == .needsUserReview)
        let final = try AgentTaskStore(persistenceURL: orphanURL)
        #expect(final.parentTurnTerminalFact(parent: newParent, execution: newExecution) == newJoin)
        #expect(final.recoveryState(runID: runID) == .needsUserReview)
        #expect(final.taskSnapshot(runID: runID)?.childRuntimeIdentity == childIdentity)
    }
}
