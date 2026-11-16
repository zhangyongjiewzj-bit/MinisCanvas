import Foundation
import Testing
@testable import MinisCore

/// Suspends the real bound approval call; the test can inspect the canonical
/// task ledger while the prompt is actually pending.
private actor M01PendingChildApproval: ApprovalDelegate {
    private var presented: ApprovalRequest?
    private var decisionWaiter: CheckedContinuation<ApprovalDecision, Never>?
    private var orchestrationFinished = false
    private var denialRequested = false

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        presented = request
        if denialRequested {
            return ApprovalDecision(
                approved: false,
                requestID: request.requestID,
                bindingDigest: request.identityDigest
            )
        }
        return await withCheckedContinuation { decisionWaiter = $0 }
    }

    func markOrchestrationFinished() {
        orchestrationFinished = true
    }

    func waitForPresentationOrFinish() async -> ApprovalRequest? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if let presented { return presented }
            if orchestrationFinished { return nil }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return presented
    }

    func approve() {
        guard let presented else { return }
        decisionWaiter?.resume(returning: ApprovalDecision(
            approved: true, requestID: presented.requestID,
            bindingDigest: presented.identityDigest))
        decisionWaiter = nil
    }

    func deny() {
        denialRequested = true
        guard let presented else { return }
        decisionWaiter?.resume(returning: ApprovalDecision(
            approved: false,
            requestID: presented.requestID,
            bindingDigest: presented.identityDigest
        ))
        decisionWaiter = nil
    }
}

@Suite("M01 actual child approval to canonical task identity")
struct P3AcceptanceM01_TaskApprovalNavigationTests {
    @Test("D-TASK-12 live bound request maps to canonical run and stale navigation fails closed")
    func realPendingRequestMapsToCanonicalAttemptOnlyWhilePending() async throws {
        try await exerciseActualChildApproval(approved: false)
    }

    @Test("approved child tool dispatch advances the canonical event before terminal settlement")
    func approvedToolDispatchResumesCanonicalProgress() async throws {
        try await exerciseActualChildApproval(approved: true)
    }

    private func exerciseActualChildApproval(approved: Bool) async throws {
        let root = try minisCoreToolContractRoot("m01-task-approval-navigation")
        let sessions = SessionStore(directory: root)
        let parentSession = try sessions.createSession(id: "m01-approval-parent")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let parent = ParentRuntimeIdentity(
            sessionID: parentSession.id,
            conversationID: parentSession.id,
            turnID: "turn-handle:\(handle.turnID)",
            taskID: "m01-approval-parent-task",
            actorID: "m01-synthetic"
        )
        // The original denial case deliberately has no bound parent Goal.
        // Actual dispatch must use the same verified-root producer as production.
        let dispatchGoal: GoalEnvelope? = approved ? GoalEnvelope(
            goalID: UUID(), scopeID: "m01-approved-parent-scope",
            allowedCapabilities: ["tools"], budget: 10,
            deadline: Date().addingTimeInterval(60), createdAt: Date()) : nil
        let taskFile = root.appendingPathComponent("canonical-tasks/tasks.json")
        let store: AgentTaskStore
        if approved {
            // The canonical store opens its lock before writing the ledger.
            // This fixture owns and must create the lock's parent directory.
            try FileManager.default.createDirectory(at: taskFile.deletingLastPathComponent(),
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            store = try AgentTaskStore(persistenceURL: taskFile)
        } else {
            store = AgentTaskStore()
        }
        let delegate = M01PendingChildApproval()
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let payload = try JSONSerialization.data(withJSONObject: [
            "tool_calls": [[
                "id": "m01-file-read-call",
                "name": "file_read",
                "input": [
                    "tool_title": "Read isolated synthetic fixture file",
                    "path": root.appendingPathComponent("never-written.txt").path,
                ],
            ]],
        ])
        let provider = ScriptedChildProvider(responses: [
            String(decoding: payload, as: UTF8.self), "child completed after denial",
        ])
        let orchestrator = AgentOrchestrator(
            maxIterationsPerTask: 2,
            provider: provider,
            toolExecutor: owner,
            approvalGate: ApprovalGate(policyByTool: ["file_read": .alwaysAsk], delegate: delegate),
            turnController: controller,
            currentConversationID: parentSession.id,
            taskStore: store,
            sessionStore: sessions,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root),
            parentID: parent.taskID,
            parentRuntimeIdentity: parent,
            parentGoal: dispatchGoal,
            parentTurnHandle: handle,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
            ),
            parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            concreteBuiltinToolExecutorOwner: owner
        )
        let child = SubAgentTask(
            id: "m01-approval-child", title: "synthetic approval", instructions: "request one tool",
            requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(
                allowedToolNames: ["file_read"], allowedReadRoots: [root.path]
            )
        )
        let running = Task {
            let reports = await orchestrator.orchestrate(tasks: [child], strategy: .sequential)
            await delegate.markOrchestrationFinished()
            return reports
        }
        guard let request = await delegate.waitForPresentationOrFinish() else {
            // A preflight rejection must fail this pending-request test, not
            // leave an unresumed continuation or masquerade as a denial pass.
            await delegate.deny()
            await handle.interrupt()
            running.cancel()
            let reports = await running.value
            Issue.record("the child must present a bound approval request on the canonical attempt; reports: \(reports.map(\.result))")
            return
        }
        let canonicalRun = try #require(store.controlSnapshot(
            taskID: child.id, parentID: parent.taskID
        )?.runID)
        let canonicalAttempt = try #require(store.canonicalAttemptID(runID: canonicalRun))
        let navigation = try #require(store.currentPendingApprovalBinding(
            taskID: child.id, parentID: parent.taskID
        ))
        #expect(request.binding != nil)
        #expect(navigation.taskRunID == canonicalRun)
        #expect(navigation.taskAttemptID == canonicalAttempt)
        #expect(navigation.approvalRequestID == request.requestID)
        #expect(navigation.approvalBindingDigest == request.identityDigest)
        #expect(navigation.childSessionID == request.sessionID)
        #expect(navigation.approvalRunID == request.runID)
        #expect(navigation.approvalAttemptID == request.attemptID)
        #expect(navigation.approvalRunID != canonicalRun)
        #expect(navigation.approvalAttemptID != canonicalAttempt)
        #expect(store.events(runID: canonicalRun).contains { $0.kind == .approvalRequired })
        #expect(store.currentPendingApprovalBinding(
            taskID: child.id, parentID: parent.taskID, now: navigation.expiresAt
        ) == nil)
        if approved {
            let goal = try #require(dispatchGoal)
            let stored = try #require(store.snapshot(taskID: child.id, parentID: parent.taskID))
            let boundChild = try #require(stored.childRuntimeIdentity)
            #expect(stored.parentRuntimeIdentity == parent)
            #expect(boundChild.hasVerifiedRootBoundary(parent: parent, goal: goal))
            #expect(boundChild.childSessionID == navigation.childSessionID)
            await delegate.approve()
            _ = await running.value
            let events = store.events(runID: canonicalRun)
            let waiting = try #require(events.firstIndex { $0.kind == .approvalRequired })
            let dispatched = try #require(events[events.index(after: waiting)...].firstIndex { $0.kind == .progress },
                Comment(rawValue: "canonical events=\(events.map(\.kind))"))
            let terminal = try #require(events.firstIndex { [.completed, .failed, .cancelled].contains($0.kind) })
            #expect(waiting < dispatched && dispatched < terminal)
            #expect(store.currentPendingApprovalBinding(taskID: child.id, parentID: parent.taskID) == nil)
            let reopened = try AgentTaskStore(persistenceURL: taskFile)
            let recovered = try #require(reopened.snapshot(taskID: child.id, parentID: parent.taskID))
            #expect(recovered.childRuntimeIdentity == boundChild)
            #expect(boundChild.grantedCapabilities == [.tools])
            #expect(boundChild.capabilityIntersection.parentCapabilities == [.tools])
            #expect(boundChild.capabilityIntersection.requestedCapabilities == [.tools])
            #expect(boundChild.capabilityIntersection.policyCapabilities == [.tools])
            #expect(boundChild.capabilityIntersection.grantedCapabilities == boundChild.grantedCapabilities)
            #expect(boundChild.workingDirectory == owner.allowedRoot.path)
            let projection = GoalTaskCenterFacade(store: reopened).project()
            let recoveredFact = try #require(projection.tasks.first {
                $0.taskID == child.id && $0.parentID == parent.taskID
            })
            #expect(recoveredFact.childGrantedCapabilities == boundChild.grantedCapabilities)
            #expect(recoveredFact.childCapabilityIntersection == boundChild.capabilityIntersection)
            #expect(recoveredFact.childWorkingDirectory == boundChild.workingDirectory)
            // No binding is manufactured from child metadata after recovery.
            #expect(!recoveredFact.isGoalBound)
            await handle.finish()
            return
        }
        _ = try store.finish(runID: canonicalRun, outcome: .cancelled)
        #expect(store.currentPendingApprovalBinding(taskID: child.id, parentID: parent.taskID) == nil)
        await delegate.deny()
        _ = await running.value
        #expect(store.currentPendingApprovalBinding(taskID: child.id, parentID: parent.taskID) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("never-written.txt").path))
    }
    @Test("真实canonical retry直接审批导航及五类身份反例")
    func directRetryApprovalKeepsCanonicalParentAndRejectsInvalidBindings() async throws {
        let root = try minisCoreToolContractRoot("m01-direct-retry-navigation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let ledger = try minisCoreToolContractLedger(at: root)
        let controller = TurnController()
        let oldHandle = await controller.beginTurn()
        let session = "m01-direct-parent-session"
        let taskID = "m01-direct-child"
        let deadline = Date().addingTimeInterval(60)
        let goal = GoalEnvelope(scopeID: "m01-direct-scope", allowedCapabilities: ["file_read"],
            fileRoots: [root.path], networkDomains: [], budget: 100, deadline: deadline,
            concurrencyLimit: 1, autonomyLevel: .l3, creatorID: "m01-synthetic")
        func parent(_ task: String, _ handle: TurnController.TurnHandle) -> ParentRuntimeIdentity {
            ParentRuntimeIdentity(sessionID: session, conversationID: session,
                turnID: "turn-handle:\(handle.turnID)", taskID: task, actorID: "m01-synthetic")
        }
        func child(_ parent: ParentRuntimeIdentity, _ handle: TurnController.TurnHandle,
                   _ execution: String) throws -> ChildRuntimeIdentity {
            try ChildRuntimeIdentity.derive(parent: parent, childSessionID: session + ":" + execution,
                childTaskID: taskID, scopeID: "scope:" + execution,
                requestedCapabilities: [.tools], parentCapabilities: [.tools], policyCapabilities: [.tools],
                providerSnapshot: ParentContextSnapshotV1(providerID: "ScriptedChild", modelID: "local",
                    configurationFingerprint: "m01-synthetic", conversationID: session),
                memoryScopeID: "memory:" + execution, workingDirectory: root.path,
                cancelGeneration: handle.turnID, evidenceRoot: "evidence:" + execution,
                parentTurnHandle: handle, childExecutionID: execution, parentGoal: goal)
        }
        let oldParent = parent("m01-original-parent", oldHandle)
        let oldChild = try child(oldParent, oldHandle, "m01-original-execution")
        _ = try store.enqueue(taskID: taskID, parentID: oldParent.taskID, providerID: "ScriptedChild", modelID: "local",
            configurationFingerprint: "m01-synthetic", parentContextSnapshotID: oldChild.providerSnapshot.snapshotID,
            parentRuntimeIdentity: oldParent, childRuntimeIdentity: oldChild, parentGoal: goal)
        _ = try store.startRun(taskID: taskID, parentID: oldParent.taskID, runID: "m01-original-run")
        let oldAttempt = try #require(store.canonicalAttemptID(runID: "m01-original-run"))
        try store.bindChildTranscript(ChildTranscriptLocator(childSessionID: oldChild.childSessionID,
            parentSessionID: session, taskID: taskID, parentID: oldParent.taskID,
            runID: "m01-original-run", attemptID: oldAttempt, childExecutionID: "m01-original-execution",
            parentContextSnapshotID: oldChild.providerSnapshot.snapshotID))
        let gate = ApprovalGate(policyByTool: ["file_read": .alwaysAsk])
        func request(_ identity: ChildRuntimeIdentity, wrongPresentation: Bool = false) throws -> ApprovalRequest {
            let generation = try #require(identity.generationID)
            let call = "m01-bound-read"
            let input = ["path": root.appendingPathComponent("never-written.txt").path]
            let binding = ApprovalAuthorizationContext(actorID: "child:" + identity.childSessionID,
                sessionID: identity.childSessionID, turnID: identity.cancelGeneration, taskID: taskID,
                runID: generation, attemptID: generation, effectID: call, scope: identity.scopeID,
                payloadDigest: try #require(ApprovalAuthorizationContext.payloadDigest(for: input)),
                expiresAt: deadline, policyRevision: "m01", grantEpoch: generation, toolName: "file_read")
            return gate.makeBoundRequest(id: wrongPresentation ? "wrong-presented-call" : call,
                tool: "file_read", input: input, context: binding)
        }
        // Ordinary legal child remains valid; only its wrong presentation is denied.
        let ordinary = try store.beginPendingChildApproval(taskRunID: "m01-original-run", taskAttemptID: oldAttempt,
            childIdentity: oldChild, request: request(oldChild))
        #expect(ordinary.parentID == oldParent.taskID)
        store.endPendingChildApproval(ordinary)
        #expect(throws: AgentTaskStoreError.approvalNavigationIdentityMismatch) {
            try store.beginPendingChildApproval(taskRunID: "m01-original-run", taskAttemptID: oldAttempt,
                childIdentity: oldChild, request: request(oldChild, wrongPresentation: true))
        }
        _ = try store.finish(runID: "m01-original-run", outcome: .failed(reason: "synthetic original failure"))
        await oldHandle.finish()
        let freshHandle = await controller.beginTurn()
        let freshParent = parent("m01-fresh-parent", freshHandle)
        let freshChild = try child(freshParent, freshHandle, "m01-retry-execution")
        let control = try #require(store.controlSnapshot(taskID: taskID, parentID: oldParent.taskID))
        let retryRun = "m01-real-retry-run"
        let receipt = AgentTaskControlReceipt(taskID: taskID, parentID: oldParent.taskID,
            idempotencyKey: "m01-real-retry-control", command: .retry, revision: "m01", scopeID: "m01",
            actorID: "m01-synthetic", runID: "m01-original-run", resultingRunID: retryRun,
            controlState: .active, controlRevision: control.controlRevision + 1, cancelledTaskIDs: [])
        _ = try store.applyControl(taskID: taskID, parentID: oldParent.taskID, command: .retry,
            expectedControlRevision: control.controlRevision, runID: "m01-original-run",
            resultingRunID: retryRun, receipt: receipt)
        let retryAttempt = try #require(store.canonicalAttemptID(runID: retryRun))
        let retry = try await store.bindRetryRunRuntime(taskID: taskID, originalParentID: oldParent.taskID,
            runID: retryRun, attemptID: retryAttempt, parent: freshParent, parentGoal: goal,
            child: freshChild, childExecutionID: "m01-retry-execution", parentTurnHandle: freshHandle)
        let locator = ChildTranscriptLocator(childSessionID: freshChild.childSessionID, parentSessionID: session,
            taskID: taskID, parentID: oldParent.taskID, runtimeParentID: freshParent.taskID,
            runID: retryRun, attemptID: retryAttempt, childExecutionID: "m01-retry-execution",
            parentContextSnapshotID: oldChild.providerSnapshot.snapshotID)
        try store.bindChildTranscript(locator)
        let childController = TurnController()
        let boundary = try AgentChildBoundary(identity: freshChild, parentCapabilities: [.tools],
            requestedCapabilities: [.tools], policy: AgentCapabilityPolicy(allowedCapabilities: [.tools],
                allowedToolNames: ["file_read"]), parentTools: [try #require(AgentToolCatalog.makeTools().first { $0.name == "file_read" })],
            budget: BudgetTracker(RequestBudget()), deadline: deadline, parentTurnHandle: freshHandle,
            childTurnController: childController, approvalGate: gate)
        let runtimeBinding = AgentChildToolRuntimeBinding(parent: freshParent, boundary: boundary, locator: locator)
        let provider = ScriptedChildProvider(responses: [])
        func context(parent: ParentRuntimeIdentity?, binding: AgentChildToolRuntimeBinding?) -> AgentExecutionContextSnapshot {
            AgentExecutionContextSnapshot(provider: provider, approvalGate: gate, turnController: childController,
                currentConversationID: freshChild.childSessionID, makeChildBudget: nil, deadline: deadline,
                taskStore: store, toolExecutionFactLedger: ledger, parentBinding: freshChild.providerSnapshot,
                parentTurnHandle: freshHandle, parentRuntimeIdentity: parent,
                childRuntimeSnapshot: AgentChildRuntimeSnapshot(identity: freshChild), childToolRuntimeBinding: binding,
                offeredToolNames: ["file_read"])
        }
        let validContext = context(parent: nil, binding: runtimeBinding)
        let validRequest = try request(freshChild)
        #expect(retry.originalParentID == oldParent.taskID && retry.parent == freshParent && retry.child == freshChild)
        #expect(await runtimeBinding.verifiedParentSessionID(for: "file_read", context: validContext) == session)
        // Direct call: old code must fail here, not at ObservingDelegate's try? -> deny.
        try AgentExecutionContext.$current.withValue(validContext) {
            let navigation = try store.beginPendingChildApproval(taskRunID: retryRun, taskAttemptID: retryAttempt,
                childIdentity: freshChild, request: validRequest)
            #expect(navigation.parentID == oldParent.taskID)
            #expect(store.currentPendingApprovalBinding(taskID: taskID, parentID: oldParent.taskID) == navigation)
            store.endPendingChildApproval(navigation)
        }
        #expect(throws: AgentTaskStoreError.approvalNavigationIdentityMismatch) {
            try AgentExecutionContext.$current.withValue(validContext) {
                try store.beginPendingChildApproval(taskRunID: "unknown-run", taskAttemptID: retryAttempt,
                    childIdentity: freshChild, request: validRequest)
            }
        }
        for (label, invalidContext, identity) in [
            ("missing-runtime-binding", context(parent: nil, binding: nil), freshChild),
            ("forged-child", validContext, oldChild),
            ("cross-fresh-parent", context(parent: nil, binding: AgentChildToolRuntimeBinding(
                parent: oldParent, boundary: boundary, locator: locator)), freshChild)
        ] {
            #expect(throws: AgentTaskStoreError.approvalNavigationIdentityMismatch, Comment(rawValue: label)) {
                try AgentExecutionContext.$current.withValue(invalidContext) {
                    try store.beginPendingChildApproval(taskRunID: retryRun, taskAttemptID: retryAttempt,
                        childIdentity: identity, request: validRequest)
                }
            }
        }
        #expect(throws: AgentTaskStoreError.approvalNavigationIdentityMismatch) {
            try AgentExecutionContext.$current.withValue(validContext) {
                try store.beginPendingChildApproval(taskRunID: retryRun, taskAttemptID: retryAttempt,
                    childIdentity: freshChild, request: validRequest, now: deadline.addingTimeInterval(1))
            }
        }
        #expect(store.currentPendingApprovalBinding(taskID: taskID, parentID: oldParent.taskID) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("never-written.txt").path))
        let freshGeneration = try #require(freshChild.generationID)
        func phase(_ state: ToolExecutionPhase = .running, session: String? = nil) -> ToolExecutionPhaseFact {
            let execution = AgentExecutionIdentity(turn: AgentTurnIdentity(
                sessionID: session ?? freshChild.childSessionID,
                turnID: freshChild.cancelGeneration, messageID: freshChild.childTaskID),
                operationID: freshGeneration, attempt: 1)
            return ToolExecutionPhaseFact(compositeKey: ToolExecutionCompositeKey(
                sessionID: execution.turn.sessionID, turnID: execution.turn.turnID,
                messageID: execution.turn.messageID, operationID: execution.operationID,
                attemptID: "m01-tool-attempt", attemptNumber: 1, toolCallID: "m01-bound-read"),
                executionIdentity: execution, toolName: "file_read", phase: state, occurredAt: Date())
        }
        let beforeDispatch = store.events(runID: retryRun)
        #expect(try !store.recordChildToolRunningPhase(phase(.queued), taskRunID: retryRun,
            taskAttemptID: retryAttempt, runtime: runtimeBinding))
        #expect(try !store.recordChildToolRunningPhase(phase(session: "foreign-child"), taskRunID: retryRun,
            taskAttemptID: retryAttempt, runtime: runtimeBinding))
        #expect(try !store.recordChildToolRunningPhase(phase(), taskRunID: retryRun,
            taskAttemptID: oldAttempt, runtime: runtimeBinding))
        #expect(try !store.recordChildToolRunningPhase(phase(), taskRunID: "m01-original-run",
            taskAttemptID: oldAttempt, runtime: runtimeBinding))
        try AgentExecutionContext.$current.withValue(validContext) {
            let pending = try store.beginPendingChildApproval(taskRunID: retryRun, taskAttemptID: retryAttempt,
                childIdentity: freshChild, request: validRequest)
            #expect(try !store.recordChildToolRunningPhase(phase(), taskRunID: retryRun,
                taskAttemptID: retryAttempt, runtime: runtimeBinding))
            store.endPendingChildApproval(pending)
        }
        #expect(store.events(runID: retryRun).count == beforeDispatch.count + 1)
        #expect(store.events(runID: retryRun).last?.kind == .approvalRequired)
        #expect(try store.recordChildToolRunningPhase(phase(), taskRunID: retryRun,
            taskAttemptID: retryAttempt, runtime: runtimeBinding))
        #expect(store.events(runID: retryRun).last?.kind == .progress)
        let afterDispatch = store.events(runID: retryRun)
        #expect(try !store.recordChildToolRunningPhase(phase(), taskRunID: retryRun,
            taskAttemptID: retryAttempt, runtime: runtimeBinding))
        #expect(store.events(runID: retryRun) == afterDispatch)
        _ = try store.finish(runID: retryRun, outcome: .cancelled)
        #expect(try !store.recordChildToolRunningPhase(phase(), taskRunID: retryRun,
            taskAttemptID: retryAttempt, runtime: runtimeBinding))
        await freshHandle.finish()
    }

}
