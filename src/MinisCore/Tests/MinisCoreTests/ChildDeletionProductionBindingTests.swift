import Foundation
import Testing
@testable import MinisCore

@Suite("Goal18 child deletion production storage bindings")
struct ChildDeletionProductionBindingTests {
    @Test func forgedChildLabelWithoutCanonicalRuntimeCannotPrepareBackup() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-delete-binding-" + UUID().uuidString)
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("notes.txt")
        try Data("owned synthetic data".utf8).write(to: target)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"), allowedRoots: [root])
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        owner.fileCheckpointsEnabled = true; owner.fileCheckpointStore = store
        owner.fileChangeLedger = FileChangeLedger(workspaceRoot: root.path)
        owner.fileChangeSessionID = "child-session"
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "claimed-child", turnID: 1,
            messageID: "claimed-task"), operationID: "claimed-run", attempt: 1)
        let key = ToolExecutionCompositeKey(sessionID: "claimed-child", turnID: 1, messageID: "claimed-task",
            operationID: "claimed-run", attemptID: "claimed-attempt", attemptNumber: 1, toolCallID: "delete")
        let presentation = ApprovalPresentationContext(compositeKey: key, executionIdentity: identity,
            toolName: "file_delete", eventSink: { _ in })
        let context = AgentExecutionContextSnapshot(provider: NoNetworkDeleteBindingProvider(), approvalGate: nil,
            turnController: nil, currentConversationID: "claimed-child", makeChildBudget: nil, deadline: nil)
        await #expect(throws: ToolExecutorError.self) {
            _ = try await owner.prepareChildDeletionReview(path: target.path, context: context,
                approvalContext: presentation)
        }
        #expect(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("checkpoints"),
            includingPropertiesForKeys: nil).isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func realBuiltinDeletionCommitsThePreparedIDAndCanonicalMetadataThenParentRestores() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = try fixture.store.begin(path: fixture.target, sessionID: "child-session", operation: .delete,
            expectedAfter: nil, parentSessionID: "parent-session")
        let preparation = ChildDeletionReviewPreparation(store: fixture.store, checkpointID: id,
            approvalContext: fixture.presentation)
        let lease = try await ToolFileMutationScope.acquireForApproval(path: fixture.target, context: fixture.presentation)
        do {
            try await ToolFileMutationLease.$current.withValue(lease) {
                try #require(lease.attachReceipt(fixture.receipt))
                try await ChildDeletionReviewPreparationContext.$current.withValue(preparation) {
                    let record = ChildDeletionReviewRecord(id: UUID(), requestIDHash: String(repeating: "a", count: 64),
                        checkpointID: id, recordedAt: Date(), reason: .independentRecommendation)
                    try await ChildDeletionReviewer.durableCheckpointRecordSink(record)
                    try await ToolExecutionReceiptContext.$current.withValue(fixture.receipt) {
                        try await ToolExecutionReceiptContext.$ledger.withValue(fixture.ledger) {
                            _ = try await fixture.owner.execute(name: "file_delete", input: ["path": fixture.target.path])
                        }
                    }
                }
            }
            await ToolFileMutationScope.release(lease)
        } catch { await ToolFileMutationScope.release(lease); throw error }
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
        let summaries = try fixture.store.summaries(sessionID: "parent-session")
        #expect(summaries.count == 1)
        #expect(summaries.first?.id == id)
        #expect(summaries.first?.producerSessionID == "child-session")
        let recordURL = fixture.root.appendingPathComponent("checkpoints").appendingPathComponent(id.uuidString + ".json")
        let record = try JSONDecoder().decode(FileCheckpointStore.Record.self, from: Data(contentsOf: recordURL))
        #expect(record.deletionReview?.checkpointID == id)
        #expect(record.deletionReview?.reason == .independentRecommendation)
        _ = try fixture.store.restore(id, sessionID: "parent-session")
        #expect(try Data(contentsOf: fixture.target) == Data("owned synthetic data".utf8))
    }

    @Test func wrongPreparedCallCannotDeleteOrCommitAnyCheckpoint() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = try fixture.store.begin(path: fixture.target, sessionID: "child-session", operation: .delete, expectedAfter: nil)
        let wrongKey = ToolExecutionCompositeKey(sessionID: "child-session", turnID: 1, messageID: "child-task",
            operationID: "child-run", attemptID: "child-attempt", attemptNumber: 1, toolCallID: "different-call")
        let wrongPresentation = ApprovalPresentationContext(compositeKey: wrongKey,
            executionIdentity: fixture.presentation.executionIdentity, toolName: "file_delete", eventSink: { _ in })
        let lease = try await ToolFileMutationScope.acquireForApproval(path: fixture.target, context: fixture.presentation)
        do {
            try await ToolFileMutationLease.$current.withValue(lease) {
                try #require(lease.attachReceipt(fixture.receipt))
                await ChildDeletionReviewPreparationContext.$current.withValue(
                    ChildDeletionReviewPreparation(store: fixture.store, checkpointID: id, approvalContext: wrongPresentation)
                ) {
                    await ToolExecutionReceiptContext.$current.withValue(fixture.receipt) {
                        await ToolExecutionReceiptContext.$ledger.withValue(fixture.ledger) {
                            await #expect(throws: ToolExecutionFactLedgerError.self) {
                                _ = try await fixture.owner.execute(name: "file_delete", input: ["path": fixture.target.path])
                            }
                        }
                    }
                }
            }
            await ToolFileMutationScope.release(lease)
        } catch { await ToolFileMutationScope.release(lease); throw error }
        #expect(FileManager.default.fileExists(atPath: fixture.target.path))
        #expect(try fixture.store.summaries(sessionID: "child-session").isEmpty)
    }

    @Test(arguments: ["recoverable", "restricted-roots", "missing-store", "stale-prepared"])
    func canonicalChildRunsRealPreGatePreparationThroughOriginalComposerChain(_ scenario: String) async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("goal18-canonical-delete-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        try #require(root.path.hasPrefix(profile.rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"))
        let project = root.appendingPathComponent("project")
        let restricted = project.appendingPathComponent("narrow")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = project.appendingPathComponent("notes.txt")
        try Data("owned canonical child bytes".utf8).write(to: target)
        let envelope: [String: Any] = ["tool_calls": [["id": "canonical-delete", "name": "file_delete", "input": ["path": target.path]]]]
        let call = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        let provider = ScriptedChildProvider(responses: [call, "done"])
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "canonical-delete-parent")
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id, conversationID: source.id,
            taskID: "canonical-parent-task", actorID: "synthetic-owner").makeIdentity(using: turn)
        let goal = GoalEnvelope(scopeID: "canonical-delete-scope", allowedCapabilities: ["file_delete"],
            fileRoots: [project.path], budget: 20, deadline: Date().addingTimeInterval(60),
            concurrencyLimit: 1, autonomyLevel: .l3)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: Date(), expiresAt: goal.deadline)
        let owner = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [])
        owner.fileChangeLedger = FileChangeLedger(workspaceRoot: project.path)
        owner.fileChangeSessionID = source.id
        owner.fileCheckpointsEnabled = true
        let storeDirectory = root.appendingPathComponent("checkpoints")
        let store = try FileCheckpointStore(directory: storeDirectory, allowedRoots: [project])
        owner.fileCheckpointStore = scenario == "missing-store" ? nil : store
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let policy = PolicyEnforcedToolExecutor(base: owner, goal: goal, lease: lease,
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder)
        let manual = DeleteBindingHumanFallback(approve: scenario == "stale-prepared")
        let model = DeleteBindingMetadataVerdict(mutate: scenario == "stale-prepared" ? target : nil)
        let delegate = ChildDeletionApprovalDelegate(manualDelegate: manual,
            reviewer: ChildDeletionReviewer(configuration: .init(enabled: true, whitelistDirectories: [project]),
                classifier: model, recordSink: ChildDeletionReviewer.durableCheckpointRecordSink))
        let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: source.id, turnID: 99, taskID: parent.taskID, attemptID: "parent-attempt",
            messageID: "parent-message", workspaceID: "canonical-workspace", createdAt: Date(),
            policyRevision: "canonical-revision", grantEpoch: "canonical-epoch", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_delete"], grantedCapabilities: ["file_delete"],
            allowedWriteRoots: [project.path], workspaceID: "canonical-workspace", revision: "canonical-revision",
            grantEpoch: "canonical-epoch", leaseID: "canonical-lease", expiresAt: goal.deadline, autonomyCeiling: .l3)
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 3, provider: provider, toolExecutor: policy,
            approvalGate: ApprovalGate(delegate: delegate), turnController: controller, makeLoopDetector: { nil },
            currentConversationID: source.id, taskStore: tasks, sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentGoal: goal, parentTurnHandle: turn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: ["file_delete"]),
            parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            parentWorkingDirectory: project.path, childMutationsEnabled: true,
            parentComposerSnapshot: snapshot, parentComposerFacts: facts, parentAuthorityCheck: { true },
            concreteBuiltinToolExecutorOwner: owner, requiresPolicyRuntime: true)
        let narrow = scenario == "restricted-roots" ? SubAgentResourceRequest(allowedToolNames: ["file_delete"],
            allowedReadRoots: [restricted.path], allowedWriteRoots: [restricted.path], workingDirectory: restricted.path) : nil
        _ = await orchestrator.orchestrate(tasks: [SubAgentTask(id: "canonical-child", title: "Synthetic deletion",
            instructions: "Delete the owned fixture only", requiredCapabilities: [.tools], resourceRequest: narrow)], strategy: .sequential)
        if scenario == "recoverable" {
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(await model.count == 1)
            #expect(await manual.count == 0)
            let summaries = try store.summaries(sessionID: source.id)
            #expect(summaries.count == 1)
            let summary = try #require(summaries.first)
            #expect(summary.producerSessionID != source.id)
            let recordURL = storeDirectory.appendingPathComponent(summary.id.uuidString + ".json")
            let record = try JSONDecoder().decode(FileCheckpointStore.Record.self, from: Data(contentsOf: recordURL))
            #expect(record.parentSessionID == source.id)
            #expect(record.deletionReview?.checkpointID == summary.id)
            #expect(ledger.facts.contains { $0.toolName == "file_delete" && $0.status == .succeeded })
            _ = try store.restore(summary.id, sessionID: source.id)
            #expect(try Data(contentsOf: target) == Data("owned canonical child bytes".utf8))
        } else if scenario == "stale-prepared" {
            // The human freshly approved V2, but the durable backup is V1:
            // never delete using the old prepared ID or quietly make another.
            #expect(try Data(contentsOf: target) == Data("external V2".utf8))
            #expect(await model.count == 1)
            #expect(await manual.count == 2)
            #expect(try store.summaries(sessionID: source.id).isEmpty)
            #expect(!ledger.facts.contains { $0.toolName == "file_delete" && $0.status == .succeeded })
        } else {
            #expect(FileManager.default.fileExists(atPath: target.path))
            #expect(await model.count == 0)
            #expect(try FileManager.default.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil).isEmpty)
            if scenario == "missing-store" {
                #expect(await manual.count == 1)
                #expect(await manual.observedOwnedPreGateLease)
                #expect(await manual.rejectedMissingRuntime)
                #expect(await manual.rejectedWrongPresentation)
            }
        }
    }

    private func fixture() throws -> (root: URL, target: URL, store: FileCheckpointStore,
        owner: BuiltinToolExecutor, ledger: ToolExecutionFactLedger,
        presentation: ApprovalPresentationContext, receipt: ToolExecutionReceipt) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("goal18-delete-binding-" + UUID().uuidString)
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("notes.txt")
        try Data("owned synthetic data".utf8).write(to: target)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"), allowedRoots: [root])
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        owner.fileCheckpointsEnabled = true; owner.fileCheckpointStore = store
        owner.fileChangeLedger = FileChangeLedger(workspaceRoot: root.path)
        owner.fileChangeSessionID = "child-session"
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "child-session", turnID: 1,
            messageID: "child-task"), operationID: "child-run", attempt: 1)
        let key = ToolExecutionCompositeKey(sessionID: "child-session", turnID: 1, messageID: "child-task",
            operationID: "child-run", attemptID: "child-attempt", attemptNumber: 1, toolCallID: "delete")
        let presentation = ApprovalPresentationContext(compositeKey: key, executionIdentity: identity,
            toolName: "file_delete", eventSink: { _ in })
        let receipt = try ledger.mint(toolCallID: "delete", toolName: "file_delete", attemptID: "child-attempt",
            attemptNumber: 1, executionIdentity: identity)
        return (root, target, store, owner, ledger, presentation, receipt)
    }
}

private struct NoNetworkDeleteBindingProvider: LLMProvider {
    enum Failure: Error { case neverRequest }
    var name: String { "no-network-binding-test" }
    var model: LLMModel = .claudeHaiku45
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?) async throws -> LLMResponse { throw Failure.neverRequest }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> { throw Failure.neverRequest }
}

private actor DeleteBindingHumanFallback: ApprovalDelegate {
    private(set) var count = 0
    private(set) var observedOwnedPreGateLease = false
    private(set) var rejectedMissingRuntime = false
    private(set) var rejectedWrongPresentation = false
    let approve: Bool
    init(approve: Bool = false) { self.approve = approve }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        count += 1
        if let context = AgentExecutionContext.current,
           let child = context.childToolRuntimeBinding?.boundary.identity,
           let tasks = context.taskStore,
           let navigation = tasks.currentPendingApprovalBinding(taskID: child.childTaskID, parentID: child.parentTaskID),
           let presentation = ApprovalPresentationContext.current,
           let lease = ToolFileMutationLease.current {
            let ownsPhysicalFile = await ToolFileMutationSerialiser.shared.owns(key: lease.key, token: lease.token)
            observedOwnedPreGateLease = lease.matchesApprovalContext(presentation) && ownsPhysicalFile
            func retryNavigation() throws -> AgentTaskApprovalNavigationBinding {
                try tasks.beginPendingChildApproval(taskRunID: navigation.taskRunID,
                    taskAttemptID: navigation.taskAttemptID, childIdentity: child, request: request)
            }
            do {
                _ = try AgentExecutionContext.$current.withValue(nil) { try retryNavigation() }
            } catch AgentTaskStoreError.approvalNavigationIdentityMismatch { rejectedMissingRuntime = true }
            catch { }
            let key = presentation.compositeKey
            let wrongKey = ToolExecutionCompositeKey(sessionID: key.sessionID, turnID: key.turnID,
                messageID: key.messageID, operationID: key.operationID, attemptID: key.attemptID,
                attemptNumber: key.attemptNumber, toolCallID: "wrong-observation-call")
            let wrongPresentation = ApprovalPresentationContext(compositeKey: wrongKey,
                executionIdentity: presentation.executionIdentity, toolName: presentation.toolName, eventSink: { _ in })
            do {
                _ = try ApprovalPresentationContext.$current.withValue(wrongPresentation) { try retryNavigation() }
            } catch AgentTaskStoreError.approvalNavigationIdentityMismatch { rejectedWrongPresentation = true }
            catch { }
            // Rejected probes cannot replace or end the original live prompt.
            #expect(tasks.currentPendingApprovalBinding(taskID: child.childTaskID, parentID: child.parentTaskID) == navigation)
        }
        return ApprovalDecision(approved: approve, reason: "synthetic human decision", confirmed: approve,
            requestID: request.requestID, bindingDigest: request.identityDigest, filePreview: request.filePreview)
    }
}
private actor DeleteBindingMetadataVerdict: IndependentDeletionClassifying {
    private(set) var count = 0
    let mutate: URL?
    init(mutate: URL? = nil) { self.mutate = mutate }
    func classify(_ input: ChildDeletionClassifierInput) async throws -> ChildDeletionModelVerdict {
        count += 1
        if let mutate { try Data("external V2".utf8).write(to: mutate, options: .atomic) }
        return .allowRecoverableDeletion
    }
}
