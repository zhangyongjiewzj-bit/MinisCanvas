import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class H3B2603Provider: LLMProvider, @unchecked Sendable {
    let name = "h3b2603-local"
    var model = LLMModel(id: "h3b2603", displayName: "H3B2603", provider: "h3b2603-local")
    let capabilities: Set<ProviderCapability> = [.tools, .streaming]
    private let lock = NSLock()
    private var childCalls = 0
    private var released = false

    var childRequestCount: Int { lock.withLock { childCalls } }
    func releaseChild() { lock.withLock { released = true } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        if messages.last(where: { $0.role == .user })?.content == "held child" {
            lock.withLock { childCalls += 1 }
            for _ in 0..<500 {
                if lock.withLock({ released }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try Task.checkCancellation()
            return LLMResponse(text: "late success", stopReason: "stop", usage: nil)
        }
        if messages.contains(where: { $0.role == .user && $0.content == "dispatch parent" }),
           !messages.contains(where: { $0.role == .assistant && !$0.toolCalls.isEmpty }) {
            let input: [String: Any] = ["input_version": 2, "strategy": "sequential", "tasks": [[
                "id": "owned-child", "title": "owned child", "instructions": "held child",
                // This held child only streams text; v2 otherwise defaults to tools.
                "required_capabilities": [ProviderCapability.streaming.rawValue],
                "allowed_tool_names": [], "allowed_read_roots": []
            ]]]
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
                LLMToolCall(id: "owned-dispatch", name: OrchestrationToolExecutor.toolName,
                    rawArguments: String(decoding: data, as: UTF8.self), arguments: input)
            ])
        }
        return LLMResponse(text: "parent complete", stopReason: "stop", usage: nil)
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

private actor H3B2603Approval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
                         requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private final class H3B2603ParentTool: ToolExecutor, @unchecked Sendable {
    let store: AgentTaskStore
    let provider: H3B2603Provider
    let goal: GoalEnvelope
    let governor: ChildConcurrencyGovernor
    let childToolOwner: BuiltinToolExecutor
    private let lock = NSLock()
    private var observedParent: ParentRuntimeIdentity?
    var parent: ParentRuntimeIdentity? { lock.withLock { observedParent } }

    init(store: AgentTaskStore, provider: H3B2603Provider, goal: GoalEnvelope,
         governor: ChildConcurrencyGovernor, childToolOwner: BuiltinToolExecutor) {
        self.store = store
        self.provider = provider
        self.goal = goal
        self.governor = governor
        self.childToolOwner = childToolOwner
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        guard let context = AgentExecutionContext.current,
              let parent = context.parentRuntimeIdentity,
              let handle = context.parentTurnHandle,
              let binding = context.parentBinding else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }
        lock.withLock { observedParent = parent }
        let orchestrator = AgentOrchestrator(
            provider: provider, toolExecutor: childToolOwner,
            currentConversationID: parent.conversationID, taskStore: store,
            parentID: parent.taskID, parentBinding: binding,
            parentRuntimeIdentity: parent, parentGoal: goal,
            parentTurnHandle: handle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming],
                allowedToolNames: [], allowedMCPToolNames: []),
            parentCapabilities: [.streaming],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(
                allowedRoot: childToolOwner.allowedRoot,
                additionalAllowedRoots: [], deniedRoots: childToolOwner.deniedRoots,
                explicitDeniedRoots: childToolOwner.explicitDeniedRoots),
            parentWorkingDirectory: childToolOwner.allowedRoot.path,
            concreteBuiltinToolExecutorOwner: childToolOwner,
            childGovernor: governor
        )
        return try await OrchestrationToolExecutor(orchestrator: orchestrator)
            .execute(name: name, input: input)
    }
}

@Suite("D-H3B actual parent cancel and Task Center recovery", .serialized)
struct H3BParentCancelTaskCenter2603Tests {
    @Test("late child success cannot replace the cancelled parent join after fresh projection")
    func cancelledParentRejectsLateChildTerminal() async throws {
        let formalRoot = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formalRoot, isDirectory: true)
            .appendingPathComponent("h3b2603-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledgerURL = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledgerURL)
        let provider = H3B2603Provider()
        defer { provider.releaseChild() }
        let controller = TurnController()
        let goal = GoalEnvelope(scopeID: "h3b2603-parent-authority",
            allowedCapabilities: ["orchestrate"], budget: 100,
            deadline: Date().addingTimeInterval(60), autonomyLevel: .l3)
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        // Production builtin tasks require the exact executor owner and file
        // ceiling even when their explicit resource request grants no tools/roots.
        let childToolOwner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let tool = H3B2603ParentTool(store: store, provider: provider, goal: goal,
            governor: governor, childToolOwner: childToolOwner)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: "h3b2603-session", turnID: 1, messageID: "h3b2603-message"),
            operationID: "h3b2603-operation", attempt: 1)
        let facts = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("tools.json"))
        let loop = AgentLoop(maxIterations: 3, approvalGate: ApprovalGate(delegate: H3B2603Approval()),
            turnController: controller, timeout: 20, taskStore: store,
            toolExecutionFactLedger: facts)
        let parentTask = Task {
            try await loop.run(messages: [LLMMessage(role: .user, content: "dispatch parent")],
                systemPrompt: nil, provider: provider, toolExecutor: tool,
                tools: [OrchestrationToolExecutor.makeDefinition()],
                currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                    conversationID: identity.turn.sessionID, taskID: "h3b2603-parent", actorID: "app"),
                executionIdentity: identity)
        }
        for _ in 0..<300 {
            if provider.childRequestCount == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(provider.childRequestCount == 1)
        let parent = try #require(tool.parent)
        let running = try #require(store.snapshot(taskID: "owned-child", parentID: parent.taskID))
        let runID = try #require(store.controlSnapshot(taskID: running.taskID,
            parentID: running.parentID)?.runID)
        #expect(running.status == .running)
        #expect(store.receipt(runID: runID) == nil)
        #expect(await governor.checkpoint().globalActive == 1)

        // The durable pre-terminal bytes represent a process lost while the
        // real child was running. Reopening those bytes must require review.
        let orphanURL = root.appendingPathComponent("orphan.json")
        try Data(contentsOf: ledgerURL).write(to: orphanURL)
        await controller.interrupt(turnID: identity.turn.turnID)
        provider.releaseChild()
        _ = try? await parentTask.value

        let join = try #require(store.parentTurnTerminalFact(parent: parent, execution: identity))
        #expect(join.outcome == .cancelled)
        #expect(await governor.checkpoint().globalActive == 0)
        #expect(join.children.count == 1 && join.children.first?.runID == runID)
        let receipt = try #require(store.receipt(runID: runID))
        #expect(receipt.outcome == .cancelled)
        let terminalEvents = store.events(runID: runID)
        let cancelledEnvelope = try #require(receipt.childResultEnvelope)
        let lateSuccess = ChildResultEnvelope(
            taskID: cancelledEnvelope.taskID, runID: cancelledEnvelope.runID,
            attemptID: cancelledEnvelope.attemptID,
            attemptNumber: cancelledEnvelope.attemptNumber,
            parentContextSnapshotID: cancelledEnvelope.parentContextSnapshotID,
            childExecutionID: cancelledEnvelope.childExecutionID,
            outcome: .succeeded, outputDigest: "late-success-digest",
            evidenceRefs: cancelledEnvelope.evidenceRefs,
            agentType: cancelledEnvelope.agentType, output: "late success",
            startedAt: cancelledEnvelope.startedAt, finishedAt: Date(),
            childTranscriptLocator: cancelledEnvelope.childTranscriptLocator)
        #expect(throws: AgentTaskStoreError.childResultCancelled) {
            _ = try store.settleChildResult(lateSuccess)
        }
        #expect(store.receipt(runID: runID) == receipt)
        #expect(store.events(runID: runID) == terminalEvents)

        let restarted = try AgentTaskStore(persistenceURL: ledgerURL)
        #expect(restarted.parentTurnTerminalFact(parent: parent, execution: identity) == join)
        let cancelledConsumer = TaskCenterControlConsumer(store: restarted)
        let cancelledRow = try #require(cancelledConsumer.receiptRows().first {
            $0.taskID == running.taskID && $0.parentID == running.parentID
        })
        #expect(cancelledRow.taskState == .cancelled)
        #expect(cancelledRow.childResultEnvelope?.outcome == .cancelled)
        #expect(!cancelledRow.needsChildTerminalReview)
        #expect(cancelledConsumer.orphanReceiptRunIDs().isEmpty)

        let orphanStore = try AgentTaskStore(persistenceURL: orphanURL)
        let orphanConsumer = TaskCenterControlConsumer(store: orphanStore)
        let orphanRow = try #require(orphanConsumer.receiptRows().first {
            $0.taskID == running.taskID && $0.parentID == running.parentID
        })
        #expect(orphanRow.needsChildTerminalReview)
        #expect(orphanRow.recoveryState == .needsUserReview)
        #expect(orphanRow.childResultEnvelope == nil)
        #expect(!orphanRow.cancelAvailable && !orphanRow.retryAvailable)
        #expect(orphanConsumer.orphanReceiptRunIDs().isEmpty)
        #expect(orphanStore.allReceipts().isEmpty)

        // The crash-point ledger preserves the production child's identity.
        // Reopening it leaves the unknown terminal outcome for review.
        #expect(orphanStore.taskSnapshot(runID: runID)?.childRuntimeIdentity ==
            running.childRuntimeIdentity)
        let orphanBytes = try Data(contentsOf: orphanURL)
        let originalAttemptCount = orphanStore.attempts(runID: runID).count
        #expect(provider.childRequestCount == 1)

        // A foreign Goal scope cannot use the App's actual control entry to
        // turn that orphan into a cancellation or a retry. A valid binding is
        // installed so rejection proves the scope fence, not an absent goal.
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: goal.createdAt, expiresAt: goal.deadline)
        orphanConsumer.installProductionGoal(goal: goal, lease: lease)
        #expect(orphanConsumer.installTopLevelTaskGoal(taskID: parent.taskID,
            goal: goal, lease: lease))
        let fact = try #require(orphanConsumer.project().fact(taskID: running.taskID,
            parentID: running.parentID))
        #expect(fact.isGoalBound)
        let foreignCancel = TaskCenterControlRequest(taskID: running.taskID,
            parentID: running.parentID, revision: fact.revision,
            scopeID: "foreign-authority", actorID: "app",
            idempotencyKey: "h3b2603-orphan-foreign", action: .cancel,
            runID: runID)
        #expect(throws: TaskCenterControlConsumerError.facade(.scopeMismatch)) {
            _ = try orphanConsumer.execute(foreignCancel)
        }
        for action in [TaskCenterControlAction.cancel, .retry] {
            let request = TaskCenterControlRequest(taskID: running.taskID,
                parentID: running.parentID, revision: fact.revision,
                scopeID: goal.scopeID, actorID: "app",
                idempotencyKey: "h3b2603-orphan-denied:\(action.rawValue)",
                action: action, runID: runID)
            let expected: TaskCenterControlConsumerError = action == .cancel
                ? .executor(.needsUserReview(.recoveredRunningTask))
                : .facade(.commandNotApplicable(.retry, .running))
            #expect(throws: expected) { _ = try orphanConsumer.execute(request) }
        }
        #expect(orphanConsumer.childResult(taskID: running.taskID,
            parentID: "foreign-parent", runID: runID) == nil)
        #expect(try Data(contentsOf: orphanURL) == orphanBytes)
        #expect(orphanStore.attempts(runID: runID).count == originalAttemptCount)
        #expect(orphanStore.allReceipts().isEmpty)
        #expect(provider.childRequestCount == 1)

        let reopenedOrphan = try AgentTaskStore(persistenceURL: orphanURL)
        let reopenedRow = try #require(TaskCenterControlConsumer(store: reopenedOrphan)
            .receiptRows().first { $0.runID == runID })
        #expect(reopenedRow.needsChildTerminalReview)
        #expect(reopenedRow.recoveryState == .needsUserReview)
        #expect(reopenedRow.childResultEnvelope == nil)
        #expect(reopenedOrphan.allReceipts().isEmpty)
    }
}
