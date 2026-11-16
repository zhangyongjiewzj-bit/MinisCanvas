import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private struct Child683PolicyBinding: Decodable {
    let goal: GoalEnvelope
    let lease: AutonomyLease
}

private enum Child683Error: Error { case unexpectedProviderCall }
private actor Child683Runner: ExternalAgentRunner {
    let name = "child683-unused"
    let isAvailable = true
    func run(task: SubAgentTask) async throws -> String { throw Child683Error.unexpectedProviderCall }
}
private actor Child683Approval: ApprovalDelegate {
    private let holdChildRead: Bool
    private var didHoldChildRead = false
    private var childWaiter: CheckedContinuation<Void, Never>?
    init(holdChildRead: Bool = false) { self.holdChildRead = holdChildRead }
    var isHoldingChildApproval: Bool { childWaiter != nil }
    func releaseChildApproval() { childWaiter?.resume(); childWaiter = nil }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        if holdChildRead, !didHoldChildRead,
           request.taskID == "child683-builtin", request.toolName == "file_read" {
            didHoldChildRead = true
            await withCheckedContinuation { childWaiter = $0 }
        }
        return ApprovalDecision(approved: true, confirmed: true,
                         requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// Local protocol producer; all tools, task controls and persistence are the
/// actual production consumers. Child cancellation interrupts its second call.
private final class Child683Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "child683-parent"
    var model = LLMModel(id: "child683-model", displayName: "683 synthetic", provider: "child683-parent")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "child683-owned-config"
    private let workspace: URL
    private let emptyTasks: Bool?
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    private var capturedChildContext: AgentExecutionContextSnapshot?
    private var blocked = false
    private var cancelled = false
    init(workspace: URL, emptyTasks: Bool? = nil) { self.workspace = workspace; self.emptyTasks = emptyTasks }
    var requests: [[LLMMessage]] { lock.withLock { captured } }
    var childContext: AgentExecutionContextSnapshot? { lock.withLock { capturedChildContext } }
    var childIsBlocked: Bool { lock.withLock { blocked } }
    var childWasCancelled: Bool { lock.withLock { cancelled } }
    private func response(name: String, id: String, input: [String: Any]) throws -> LLMResponse {
        let data = try JSONSerialization.data(withJSONObject: ["tool_calls": [["id": id, "name": name, "input": input]]])
        return LLMResponse(text: String(decoding: data, as: UTF8.self), stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [], maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(messages) }
        if messages.contains(where: { $0.role == .user && $0.content.hasSuffix("683 child input") }) {
            lock.withLock { capturedChildContext = AgentExecutionContext.current }
            if messages.contains(where: { $0.role == .tool || $0.content.contains("\"tool_result\"") }) {
                lock.withLock { blocked = true }
                do { try await Task.sleep(for: .seconds(120)) }
                catch { lock.withLock { cancelled = true }; throw error }
                throw Child683Error.unexpectedProviderCall
            }
            let data = try JSONSerialization.data(withJSONObject: ["tool_calls": [
                ["id": "child683-read", "name": "file_read", "input": ["path": workspace.appendingPathComponent("note.txt").path]],
                ["id": "child683-denied-read", "name": "file_read", "input": ["path": workspace.deletingLastPathComponent().appendingPathComponent("outside-child.txt").path]]
            ]])
            return LLMResponse(text: String(decoding: data, as: UTF8.self), stopReason: "stop", usage: nil)
        }
        if messages.contains(where: { $0.role == .tool || $0.content.contains("\"tool_result\"") }) {
            return LLMResponse(text: "683 parent saw cancellation", stopReason: "stop", usage: nil)
        }
        if let emptyTasks {
            let tasks: [[String: Any]] = emptyTasks ? [] : [["id": "683-invalid", "title": "invalid", "instructions": ""]]
            return try response(name: OrchestrationToolExecutor.toolName, id: "child683-orchestrate",
                                input: ["input_version": 2, "tasks": tasks])
        }
        return try response(name: OrchestrationToolExecutor.toolName, id: "child683-orchestrate", input: [
            "input_version": 2, "strategy": "sequential", "tasks": [[
                "id": "child683-builtin", "title": "683 builtin child", "instructions": "683 child input",
                "agent": "builtin", "required_capabilities": ["tools"],
                "allowed_tool_names": ["file_read"], "allowed_read_roots": [workspace.path]
            ]]
        ])
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw Child683Error.unexpectedProviderCall
    }
}

/// The production routing consumer forwards to this same real builtin only
/// after its source/grant checks. Counting forwarding witnesses primitive I/O.
private final class Child683ReadProbe: BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    let builtin: BuiltinToolExecutor
    private let lock = NSLock()
    private var count = 0
    init(_ builtin: BuiltinToolExecutor) { self.builtin = builtin }
    var currentBuiltinOwner: BuiltinToolExecutor? { builtin }
    var readCount: Int { lock.withLock { count } }
    func execute(name: String, input: [String: Any]) async throws -> String {
        if name == "file_read" { lock.withLock { count += 1 } }
        return try await builtin.execute(name: name, input: input)
    }
    func executeBoundToBuiltinOwner(_ owner: BuiltinToolExecutor, name: String,
                                   input: [String: Any]) async throws -> String {
        guard owner === builtin else { throw ToolExecutorError.resourceScopeInvalid }
        return try await execute(name: name, input: input)
    }
    // Match production's existing sendable invocation box: the owner stays
    // in this box and each non-Sendable tool dictionary is created per call.
    func readThrough(_ route: ProjectSessionCompositeToolExecutor, path: String,
                     bound: Bool = true, foreignOwnerRoot: URL? = nil) async throws -> String {
        if !bound { return try await route.execute(name: "file_read", input: ["path": path]) }
        let owner = foreignOwnerRoot.map { BuiltinToolExecutor(allowedRoot: $0, deniedRoots: []) } ?? builtin
        return try await route.executeBoundToBuiltinOwner(owner, name: "file_read", input: ["path": path])
    }
}

@Suite("683 actual builtin child cancellation survives session switch and reopen")
@MainActor
struct ChildCancellation683ConsumerTests {
    private func makeBridge(root: URL, store: AgentTaskStore, provider: any LLMProvider,
                            runner: Child683Runner, approval: Child683Approval? = nil,
                            expectedAppliedReadiness: [ProviderReadinessPersistenceRecord]? = nil) async throws -> (bridge: BridgeStore, settings: SettingsCenter) {
        let defaults = try #require(UserDefaults(suiteName: "child683-\(UUID().uuidString)"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        if let expectedAppliedReadiness {
            // Reopening must consume the actual durable Apply receipt. Apply
            // returns only newly applied rows, not a second receipt for it.
            try #require(expectedAppliedReadiness.count == 1)
            try #require(readiness.records == expectedAppliedReadiness)
            let applied = try #require(readiness.records.first)
            #expect(applied.providerID == provider.name && applied.modelID == provider.model.id)
            #expect(applied.isApplied && applied.applyReceiptID?.isEmpty == false)
            #expect(applied.status == .passed && applied.readinessState == .mock)
        } else {
            try #require(readiness.records.isEmpty)
            let checkedAt = Date()
            let lineage = ProviderReadinessLineage.derived(providerID: provider.name,
                                                           modelID: provider.model.id, checkedAt: checkedAt)
            #expect(readiness.upsert([ProviderReadinessPersistenceRecord(
                providerID: provider.name, modelID: provider.model.id,
                status: .passed, readinessState: .mock, checkedAt: checkedAt,
                evidenceID: "child683-synthetic-readiness", isApplied: false,
                discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt
            )]))
            let applied = readiness.applyDiscoveredModels(providerID: provider.name,
                modelIDs: [provider.model.id], appliedAt: checkedAt.addingTimeInterval(1))
            #expect(applied.count == 1 && applied.first?.applyReceiptID?.isEmpty == false)
        }
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("683 must not construct CanvasStore") },
            agentTaskStore: store,
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-binding.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        let ownedSessionStore = SessionStore(directory: root.appendingPathComponent("sessions"))
        let ownedBadgeDirectory = root.appendingPathComponent("badges461")
        let ownedBadgeStore = SessionBadgeStore(directory: ownedBadgeDirectory)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: ownedSessionStore, sessionBadgeStore: ownedBadgeStore,
            logManager: bridge.chat.logManager,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("child683-usage-\(UUID().uuidString)")),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: readiness)
        try #require(SettingsCenter.active === settings)
        try #require(settings.sessionStore === ownedSessionStore)
        try #require(bridge.chat.attachPersistence(ownedSessionStore, badgeStore: ownedBadgeStore))
        let productionAttachment = bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: root.appendingPathComponent("sessions"),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            approvalDelegateOverride: approval ?? Child683Approval(),
            policyDefaults: ProductionPolicyDefaults(budget: 1_000, deadlineHorizon: 120,
                                                     autonomyLevel: .l3, networkDomains: []),
            enableOrchestration: true, externalRunners: [runner.name: runner],
            // This is the unchanged admission flag from 413. Both injected
            // protocol producers above are local and implement no transport.
            externalNetworkAllowed: true,
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        )
        await productionAttachment.value
        // AJ-2's existing-store branch must retain the exact owned authorities.
        // This fixture does not cover Bridge's default created-store branch.
        try #require(bridge.chat.sessionStore === ownedSessionStore)
        let ownedManager = try #require(bridge.chat.sessionManager)
        try #require(ownedManager.store === ownedSessionStore)
        try #require(ownedManager.badgeStore === ownedBadgeStore)
        let expectedSessionDirectory = root.appendingPathComponent("sessions")
        #expect(ownedManager.store.directory.isFileURL && expectedSessionDirectory.isFileURL)
        #expect(ownedManager.store.directory.pathComponents == expectedSessionDirectory.pathComponents)
        #expect(FileManager.default.fileExists(atPath: ownedBadgeDirectory.path))
        bridge.updateApprovalPolicy(.alwaysAsk)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        try #require(SettingsCenter.active === settings)
        try #require(settings.sessionStore === bridge.chat.sessionStore)
        return (bridge, settings)
    }


    @Test func globalParentDerivedChildAndRealTaskCenterRetryCannotStartBackground() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("j4-child-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let provider = J4DerivedChildProvider(workspace: workspace)
        let fixture = try await makeBridge(root: root, store: tasks, provider: provider, runner: Child683Runner())
        let bridge = fixture.bridge
        let chat = bridge.chat
        defer { chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture.settings) {} }
        let builtin = try #require(bridge.productionBuiltinToolExecutor)
        provider.install(owner: builtin)
        chat.draftText = "owned global parent background child contract"
        chat.submitComposer()
        for _ in 0..<500 {
            if !chat.hasStreamingTasksForSafety && provider.generations.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.hasStreamingTasksForSafety && provider.generations.count == 1)
        #expect(provider.parentWasGlobal)
        let consumer = bridge.taskCenterControlConsumer
        let row = try #require(consumer.receiptRows().first { $0.taskID == "j4-derived-child" && $0.lifecycleState == .failed })
        let oldRunID = try #require(row.runID)
        let oldReceipt = try #require(tasks.receipt(runID: oldRunID))
        let fact = try #require(bridge.taskCenterGoalProjection().fact(taskID: row.taskID, parentID: row.parentID))
        let request = TaskCenterControlRequest(taskID: row.taskID, parentID: row.parentID,
            revision: fact.revision, scopeID: try #require(fact.scopeID), actorID: "task-center-ui",
            idempotencyKey: "j4-real-retry-" + UUID().uuidString, action: .retry, runID: oldRunID)
        let retried = try await bridge.executeTaskCenterRetryFromUserEvent(request)
        let newRunID = try #require(retried.resultingRunID)
        try #require(await bridge.joinTaskCenterRetryExecution(runID: newRunID) != nil)
        #expect(provider.generations.count == 2 && Set(provider.generations).count == 2)
        #expect(provider.origins == [.restricted, .restricted])
        #expect(provider.refusalCount == 2)
        #expect(provider.independentChecks == ["binding-only", "snapshot-only"])
        let binding = try #require(tasks.retryRunRuntimeBinding(runID: newRunID))
        #expect(binding.parent.taskID != row.parentID)
        #expect(binding.child.parentTaskID == binding.parent.taskID)
        #expect(tasks.receipt(runID: oldRunID) == oldReceipt)
        #expect({
            if case .some(.failed(reason: _)) = tasks.receipt(runID: newRunID)?.outcome { return true }
            return false
        }())
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let facts = engine.toolExecutionFactLedger.facts.filter { $0.toolCallID.hasPrefix("j4-child-background-") }
        #expect(facts.count == 2 && facts.allSatisfy { $0.status == .failed },
                "J4 facts count=\(facts.count) entries=\(facts.map { $0.toolCallID + ":" + $0.status.rawValue }.joined(separator: ","))")
        #expect(provider.childSessions.allSatisfy { builtin.backgroundShells.snapshots(sessionID: $0).isEmpty })
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("unexpected-background.txt").path))
    }

    @Test("cancelled canonical child keeps its existing read-only transcript without admitting a late writer")
    func actualCancelledChildRemainsReadableAcrossSwitchAndReopen() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("child683-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "683 owned note".write(to: workspace.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try "683 outside child scope".write(to: root.appendingPathComponent("outside-child.txt"), atomically: true, encoding: .utf8)
        let sessionsURL = root.appendingPathComponent("sessions")
        let seed = SessionStore(directory: sessionsURL)
        let parentID = UUID(), otherID = UUID()
        try seed.createSession(id: parentID.uuidString, title: "683 parent")
        try seed.createSession(id: otherID.uuidString, title: "683 other")
        try seed.saveMessage(LLMMessage(role: .user, content: "683 other only"), sessionID: otherID.uuidString)
        let userForkID = UUID()
        let userForkBefore = try seed.forkSession(from: parentID.uuidString,
            id: userForkID.uuidString, title: "683 ordinary user fork")
        let legacyBefore = try seed.forkSession(from: parentID.uuidString,
            id: "683-legacy-unverified", title: "683 legacy unverified",
            createdByTaskID: "683-legacy-task", createdByRunID: "683-legacy-run")
        let tasksURL = root.appendingPathComponent("tasks.json")
        let tasks = try AgentTaskStore(persistenceURL: tasksURL)
        let provider = Child683Provider(workspace: workspace)
        let approval = Child683Approval(holdChildRead: true)
        let fixture = try await makeBridge(root: root, store: tasks, provider: provider,
            runner: Child683Runner(), approval: approval)
        defer { Task { await approval.releaseChildApproval() } }
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture.settings) {} }
        try #require(SettingsCenter.active === fixture.settings)
        try #require(fixture.settings.sessionStore === bridge.chat.sessionStore)
        let chat = bridge.chat
        #expect(chat.sessions.contains { $0.id == userForkID })
        #expect(chat.sessions.contains { $0.title == legacyBefore.title && $0.createdByTaskID == legacyBefore.createdByTaskID })
        chat.switchSession(id: parentID)
        try #require(chat.activeSessionID == parentID)
        let sessions = try #require(chat.sessionStore)
        let otherBefore = try #require(sessions.loadSession(id: otherID.uuidString))
        let productionEngine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(bridge.orchestrationEnabled)
        #expect(productionEngine.hasOrchestrationCapability)
        try #require(productionEngine.toolExecutionFactLedger.hasDurableAuthority)
        chat.draftText = "683 parent request"
        chat.submitComposer()
        var waitingRevision: UInt64?
        var waitingProjection: TaskSummaryChildProjection?
        var parentTaskID: String?
        for _ in 0..<500 {
            if waitingRevision == nil, await approval.isHoldingChildApproval {
                parentTaskID = chat.executionSnapshot(forSessionID: parentID)?.taskID
                let capture = ChatInspectorTaskScope.capture(bridge: bridge,
                    viewerSessionID: parentID.uuidString, currentTaskID: parentTaskID)
                waitingProjection = TaskSummaryChildProjection(currentTaskID: parentTaskID,
                    receiptRows: capture.receiptRows, viewerSessionID: parentID.uuidString)
                waitingRevision = chat.toolLifecyclePresentationRevision
                await approval.releaseChildApproval()
            }
            if provider.childIsBlocked, let waitingRevision,
               chat.toolLifecyclePresentationRevision > waitingRevision { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if !provider.childIsBlocked {
            print("TASK2467_CHILD683_PREPROVIDER_DIAG requests=\(provider.requests.count) child_context=\(provider.childContext != nil) task_snapshots=\(String(describing: tasks.taskCenterSnapshots())) receipts=\(String(describing: tasks.allReceipts()))")
        }
        try #require(provider.childIsBlocked)
        let beforeRevision = try #require(waitingRevision)
        let pendingProjection = try #require(waitingProjection)
        let currentParentTaskID = try #require(parentTaskID)
        #expect(pendingProjection.approvalCount == 1 && pendingProjection.runningCount == 0)
        #expect(chat.toolLifecyclePresentationRevision > beforeRevision)
        // Same capture factory as ContentView; the test does not replace an
        // inspector snapshot or pretend the child's phase belongs to its parent.
        let refreshed = ChatInspectorTaskScope.capture(bridge: bridge,
            viewerSessionID: parentID.uuidString, currentTaskID: currentParentTaskID)
        let inspectorProjection = TaskSummaryChildProjection(currentTaskID: currentParentTaskID,
            receiptRows: refreshed.receiptRows, viewerSessionID: parentID.uuidString)
        #expect(inspectorProjection.runningCount == 1 && inspectorProjection.approvalCount == 0)
        let waitingRow = try #require(pendingProjection.rows.first { $0.taskID == "child683-builtin" })
        let updatedRow = try #require(inspectorProjection.rows.first { $0.taskID == waitingRow.taskID })
        #expect(updatedRow.parentID == waitingRow.parentID)
        #expect(updatedRow.runID == waitingRow.runID && updatedRow.attemptID == waitingRow.attemptID)
        let consumer = bridge.taskCenterControlConsumer
        let running = try #require(consumer.receiptRows().first { $0.taskID == "child683-builtin" })
        let navigation = try #require(running.childNavigation)
        let locator = try #require(navigation.locator)
        #expect(running.sourceSessionID == parentID.uuidString)
        #expect(running.taskID == locator.taskID && running.parentID == locator.parentID)
        #expect(running.runID == locator.runID && running.attemptID == locator.attemptID)
        let before = try #require(consumer.childTranscript(navigation: navigation))
        #expect(before.messages.count >= 3)
        #expect(before.messages.first?.content.hasSuffix("683 child input") == true)
        let childBefore = try #require(sessions.loadSession(id: locator.childSessionID))
        let readFact = try #require(productionEngine.toolExecutionFactLedger.facts.first { $0.toolCallID == "child683-read" })
        let deniedFact = try #require(productionEngine.toolExecutionFactLedger.facts.first { $0.toolCallID == "child683-denied-read" })
        let childFeedback = provider.requests.last { messages in
            messages.contains { $0.role == .user && $0.content.hasSuffix("683 child input") }
        }?.last?.content ?? "missing child feedback"
        print("AGENT683_CHILD_TOOL_FEEDBACK \(childFeedback)")
        print("AGENT683_CHILD_READ_TYPED_FACT \(String(decoding: try JSONEncoder().encode(readFact), as: UTF8.self))")
        print("AGENT683_CHILD_SCOPE_REFUSAL_TYPED_FACT \(String(decoding: try JSONEncoder().encode(deniedFact), as: UTF8.self))")
        #expect(readFact.status == .succeeded, "Actual owned child tool feedback: \(childFeedback)")
        #expect(deniedFact.status == .failed)
        #expect(childFeedback.contains("683 owned note"))
        #expect(childFeedback.contains("路径超出授权目录或已被拒绝："))
        let capturedContext = try #require(provider.childContext)
        let capturedBinding = try #require(capturedContext.childToolRuntimeBinding)
        let durableChild = try #require(tasks.snapshot(taskID: locator.taskID,
            parentID: locator.parentID)?.childRuntimeIdentity)
        #expect(durableChild == capturedBinding.boundary.identity)
        #expect(durableChild.rootParentIdentity == capturedBinding.parent)
        #expect(durableChild.parentGoalID != nil)
        #expect(durableChild.parentGoalScopeID == "production:agent")
        #expect(durableChild.scopeID != durableChild.parentGoalScopeID)
        let builtin = try #require(bridge.productionBuiltinToolExecutor)
        let handler = try #require(bridge.productionProjectSessionHandler)
        let probe = Child683ReadProbe(builtin)
        let route = ProjectSessionCompositeToolExecutor(base: probe, builtin: builtin,
            handler: handler, workspaceBindings: ProjectSessionWorkspaceBindings())
        let readPath = workspace.appendingPathComponent("note.txt").path
        let actualPayload = try await AgentExecutionContext.$current.withValue(capturedContext) {
            try await probe.readThrough(route, path: readPath)
        }
        #expect(actualPayload == "683 owned note" && probe.readCount == 1)
        func copiedContext(ledger: ToolExecutionFactLedger?, binding: AgentChildToolRuntimeBinding?) -> AgentExecutionContextSnapshot {
            AgentExecutionContextSnapshot(provider: capturedContext.provider,
                approvalGate: capturedContext.approvalGate, turnController: capturedContext.turnController,
                currentConversationID: capturedContext.currentConversationID,
                makeChildBudget: capturedContext.makeChildBudget, deadline: capturedContext.deadline,
                taskStore: capturedContext.taskStore, toolExecutionFactLedger: ledger,
                parentBinding: capturedContext.parentBinding, parentTurnHandle: capturedContext.parentTurnHandle,
                parentRuntimeIdentity: capturedContext.parentRuntimeIdentity,
                childRuntimeSnapshot: capturedContext.childRuntimeSnapshot, childToolRuntimeBinding: binding)
        }
        let foreignLocator = ChildTranscriptLocator(childSessionID: locator.childSessionID,
            parentSessionID: locator.parentSessionID, taskID: locator.taskID, parentID: locator.parentID,
            runID: "683-foreign-run", attemptID: locator.attemptID,
            childExecutionID: locator.childExecutionID, parentContextSnapshotID: locator.parentContextSnapshotID,
            lineageVersion: locator.lineageVersion)
        let foreignBinding = AgentChildToolRuntimeBinding(parent: capturedBinding.parent,
            boundary: capturedBinding.boundary, locator: foreignLocator)
        let unverifiedOrdinaryContext = AgentExecutionContextSnapshot(provider: provider,
            approvalGate: capturedContext.approvalGate, turnController: nil,
            currentConversationID: parentID.uuidString, makeChildBudget: nil,
            deadline: capturedContext.deadline, taskStore: tasks,
            toolExecutionFactLedger: capturedContext.toolExecutionFactLedger)
        for rejectedContext in [
            unverifiedOrdinaryContext,
            copiedContext(ledger: capturedContext.toolExecutionFactLedger, binding: nil),
            copiedContext(ledger: nil, binding: capturedBinding),
            copiedContext(ledger: capturedContext.toolExecutionFactLedger, binding: foreignBinding)
        ] {
            await AgentExecutionContext.$current.withValue(rejectedContext) {
                await #expect(throws: ProjectSessionAppError.sourceUnavailable) {
                    _ = try await probe.readThrough(route, path: readPath)
                }
            }
            #expect(probe.readCount == 1)
        }
        await AgentExecutionContext.$current.withValue(capturedContext) {
            await #expect(throws: ProjectSessionAppError.sourceUnavailable) {
                _ = try await probe.readThrough(route, path: readPath, bound: false)
            }
            await #expect(throws: ToolExecutorError.resourceScopeInvalid) {
                _ = try await probe.readThrough(route, path: readPath, foreignOwnerRoot: root)
            }
        }
        #expect(probe.readCount == 1)
        let foreignProjects = ProjectSessionWorkspaceBindings()
        try foreignProjects.register(TargetWorkspaceBinding(source: capturedBinding.parent,
            targetSessionID: capturedBinding.parent.sessionID, taskID: "683-foreign-project-task",
            runID: "683-foreign-project-run", projectID: "683-foreign-project",
            workingDirectory: workspace.path))
        let foreignRoute = ProjectSessionCompositeToolExecutor(base: probe, builtin: builtin,
            handler: handler, workspaceBindings: foreignProjects)
        await AgentExecutionContext.$current.withValue(capturedContext) {
            await #expect(throws: ProjectSessionAppError.grantUnavailable) {
                _ = try await probe.readThrough(foreignRoute, path: readPath)
            }
        }
        #expect(probe.readCount == 1)
        print("AGENT683_ACTIVE_CHILD_ROUTING actual-reader=1 unverified/missingledger/wrongrun/missingowner/foreignproject-zero-effect")
        let childFactIdentity = try #require(readFact.executionIdentity)
        #expect(childFactIdentity.turn.sessionID == locator.childSessionID)
        #expect(childFactIdentity.turn.messageID == locator.taskID)
        #expect(deniedFact.executionIdentity == childFactIdentity)
        #expect(try String(contentsOf: workspace.appendingPathComponent("note.txt"), encoding: .utf8) == "683 owned note")
        let childTask = try #require(tasks.snapshot(taskID: locator.taskID, parentID: locator.parentID))
        #expect(childTask.providerID == provider.name && childTask.modelID == provider.model.id)
        // Cross the actual App turn, child transcript and durable task/effect
        // consumers. The IDs below all came from this one ChatStore dispatch.
        let parentOrigin = capturedBinding.parent
        let durableTask = try #require(tasks.taskSnapshot(runID: locator.runID))
        let durableRun = try #require(tasks.historicalRunIdentity(
            runID: locator.runID, taskID: locator.taskID, parentID: locator.parentID))
        let durableAttempt = try #require(tasks.attempt(
            runID: locator.runID, attemptID: locator.attemptID))
        let childEffectKey = try #require(readFact.compositeKey)
        #expect(parentOrigin.sessionID == parentID.uuidString && parentOrigin.conversationID == parentID.uuidString)
        #expect(parentOrigin.turnID.hasPrefix("turn-handle:") && parentOrigin.taskID == locator.parentID)
        #expect(durableTask == childTask && durableTask.parentRuntimeIdentity == parentOrigin)
        #expect(durableTask.sourceSessionID == parentID.uuidString)
        #expect(durableRun.taskID == locator.taskID && durableRun.parentID == parentOrigin.taskID)
        #expect(durableRun.runID == locator.runID && durableRun.attemptID == durableAttempt.attemptID)
        #expect(durableAttempt.runID == locator.runID && durableAttempt.attemptID == locator.attemptID)
        #expect(readFact.parentRuntimeIdentity == parentOrigin && readFact.childTranscriptLocator == locator)
        #expect(childEffectKey.sessionID == locator.childSessionID && childEffectKey.turnID == childFactIdentity.turn.turnID)
        #expect(childEffectKey.messageID == locator.taskID && childEffectKey.operationID == childFactIdentity.operationID)
        #expect(childEffectKey.attemptID == readFact.attemptID && childEffectKey.toolCallID == readFact.toolCallID)
        #expect(readFact.attemptID != durableAttempt.attemptID)
        let fact = try #require(consumer.project().fact(taskID: locator.taskID, parentID: locator.parentID))
        let scopeID = try #require(fact.scopeID)
        let policyBytes = try Data(contentsOf: root.appendingPathComponent("task-binding.json"))
        let policy = try JSONDecoder().decode(Child683PolicyBinding.self, from: policyBytes)
        #expect(policy.goal.scopeID == scopeID)
        #expect(policy.goal.allowedCapabilities.contains("file_read"))
        #expect(policy.goal.fileRoots.contains(root.path))
        _ = try consumer.execute(TaskCenterControlRequest(
            taskID: locator.taskID, parentID: locator.parentID, revision: fact.revision,
            scopeID: scopeID, actorID: "683-owned-test", idempotencyKey: "683-cancel",
            action: .cancel, runID: locator.runID))
        for _ in 0..<500 {
            if provider.childWasCancelled && !chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(provider.childWasCancelled)
        try #require(!chat.isStreaming)
        let cancelled = try #require(consumer.receiptRows().first { $0.taskID == locator.taskID })
        #expect(cancelled.taskState == .cancelled)
        #expect(cancelled.runID == locator.runID && cancelled.attemptID == locator.attemptID)
        let receipt = try #require(tasks.receipt(runID: locator.runID))
        #expect(receipt.outcome == .cancelled && receipt.childResultEnvelope == nil)
        #expect(sessions.loadSession(id: locator.childSessionID) == childBefore)
        #expect(consumer.childTranscript(navigation: navigation) == before)
        #expect(cancelled.childNavigation == navigation)
        #expect(cancelled.durationTitle() != "未记录")
        await AgentExecutionContext.$current.withValue(capturedContext) {
            await #expect(throws: ProjectSessionAppError.sourceUnavailable) {
                _ = try await probe.readThrough(route, path: readPath)
            }
        }
        #expect(probe.readCount == 1)
        #expect(chat.executionSnapshot(forSessionID: parentID)?.state == .failed)
        let parentFact = try #require(productionEngine.toolExecutionFactLedger.facts.first { $0.toolCallID == "child683-orchestrate" })
        let parentFactIdentity = try #require(parentFact.executionIdentity)
        #expect(parentFact.status == .failed)
        #expect(parentFactIdentity.turn.sessionID == parentID.uuidString)
        #expect(parentFactIdentity.turn.sessionID == parentOrigin.sessionID)
        #expect(chat.terminalReceipt(for: parentFactIdentity)?.outcome == .failed)
        #expect(parentFactIdentity != childFactIdentity)
        #expect(parentFactIdentity.operationID != childFactIdentity.operationID)
        let parentBeforeSwitch = try #require(sessions.loadSession(id: parentID.uuidString))
        chat.switchSession(id: otherID)
        #expect(chat.activeSessionID == otherID)
        #expect(chat.messages.map { $0.asLLMMessage() } == otherBefore.messages)
        #expect(sessions.loadSession(id: otherID.uuidString) == otherBefore)
        chat.switchSession(id: parentID)
        #expect(chat.activeSessionID == parentID)
        #expect(chat.messages.map { $0.asLLMMessage() } == parentBeforeSwitch.messages)
        let reloadedTasks = try AgentTaskStore(persistenceURL: tasksURL)
        let reloadedSessions = SessionStore(directory: sessionsURL)
        let reopenedFixture = try await makeBridge(root: root, store: reloadedTasks,
            provider: Child683Provider(workspace: workspace), runner: Child683Runner(),
            expectedAppliedReadiness: try #require(chat.providerReadinessStore).records)
        let reopenedBridge = reopenedFixture.bridge
        defer { reopenedBridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(reopenedFixture.settings) {} }
        try #require(SettingsCenter.active === reopenedFixture.settings)
        try #require(reopenedFixture.settings.sessionStore === reopenedBridge.chat.sessionStore)
        let reopened = reopenedBridge.taskCenterControlConsumer
        let reopenedEngine = try #require(reopenedBridge.chat.agentEngine as? AgentLoopChatEngine)
        let reopenedChildEffect = try #require(reopenedEngine.toolExecutionFactLedger.facts.first {
            $0.toolCallID == readFact.toolCallID
        })
        #expect(reopenedChildEffect == readFact)
        #expect(reloadedTasks.taskSnapshot(runID: locator.runID)?.parentRuntimeIdentity == parentOrigin)
        #expect(reloadedTasks.historicalRunIdentity(
            runID: locator.runID, taskID: locator.taskID, parentID: locator.parentID) == durableRun)
        let restoredFact = try #require(reopened.project().fact(taskID: locator.taskID, parentID: locator.parentID))
        #expect(restoredFact.scopeID == scopeID)
        #expect(try Data(contentsOf: root.appendingPathComponent("task-binding.json")) == policyBytes)
        #expect(restoredFact.providerID == childTask.providerID && restoredFact.modelID == childTask.modelID)
        let restored = try #require(reopened.receiptRows().first { $0.taskID == locator.taskID })
        #expect(restored.taskState == .cancelled)
        #expect(restored.runID == locator.runID && restored.attemptID == locator.attemptID)
        #expect(reopened.childTranscript(navigation: navigation) == before)
        #expect(restored.childNavigation == navigation)
        #expect(restored.durationTitle() == cancelled.durationTitle())
        #expect(reloadedTasks.snapshot(taskID: locator.taskID, parentID: locator.parentID)?.providerID == childTask.providerID)
        #expect(reloadedTasks.snapshot(taskID: locator.taskID, parentID: locator.parentID)?.modelID == childTask.modelID)
        #expect(reloadedSessions.loadSession(id: parentID.uuidString) == parentBeforeSwitch)
        #expect(reopenedBridge.chat.sessions.contains { $0.id == userForkID })
        #expect(reopenedBridge.chat.sessions.contains { $0.title == legacyBefore.title && $0.createdByTaskID == legacyBefore.createdByTaskID })
        #expect(reloadedSessions.loadSession(id: legacyBefore.id) == legacyBefore)
        reopenedBridge.chat.switchSession(id: userForkID)
        #expect(reopenedBridge.chat.activeSessionID == userForkID)
        #expect(reopenedBridge.chat.messages.map { $0.asLLMMessage() } == userForkBefore.messages)
        #expect(reloadedSessions.loadSession(id: userForkID.uuidString) == userForkBefore)
        reopenedBridge.chat.switchSession(id: otherID)
        reopenedBridge.chat.switchSession(id: parentID)
        #expect(reloadedSessions.listSessions().filter {
            $0.createdByTaskID == locator.taskID && $0.createdByRunID == locator.runID
        }.map(\.id) == [locator.childSessionID], "Reopening and switching must not mint another child transcript identity")
        #expect(reloadedSessions.loadSession(id: locator.childSessionID) == childBefore)
        // A terminal read is never a write admission.
        #expect(throws: AgentTaskStoreError.childResultStaleAttempt) {
            try reloadedTasks.withWritableChildTranscript(locator) { }
        }
        // Read-only terminal navigation still rejects every altered identity.
        for (runID, attemptID, parentSessionID, parentTaskID) in [
            ("wrong-run", locator.attemptID, locator.parentSessionID, locator.parentID),
            (locator.runID, "wrong-attempt", locator.parentSessionID, locator.parentID),
            (locator.runID, locator.attemptID, otherID.uuidString, locator.parentID),
            (locator.runID, locator.attemptID, locator.parentSessionID, "wrong-parent-task")
        ] {
            let wrong = ChildTranscriptLocator(childSessionID: locator.childSessionID,
                parentSessionID: parentSessionID, taskID: locator.taskID, parentID: parentTaskID,
                runID: runID, attemptID: attemptID, childExecutionID: locator.childExecutionID,
                parentContextSnapshotID: locator.parentContextSnapshotID, lineageVersion: locator.lineageVersion)
            #expect(reopened.childTranscript(navigation: TaskCenterChildSessionNavigation(locator: wrong)) == nil)
        }
        // Old ledgers and unordered clock observations stay unknown, while
        // their unchanged canonical transcript identity remains read-only.
        for variant in ["legacy", "reversed"] {
            var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: tasksURL)) as? [String: Any])
            var state = try #require(payload["state"] as? [String: Any])
            var attempts = try #require(state["attempts"] as? [String: Any])
            var attempt = try #require(attempts[locator.attemptID] as? [String: Any])
            if variant == "legacy" {
                attempt.removeValue(forKey: "startedAt"); attempt.removeValue(forKey: "finishedAt")
            } else {
                let start = try #require(attempt["startedAt"] as? Double)
                attempt["finishedAt"] = start - 1
            }
            attempts[locator.attemptID] = attempt; state["attempts"] = attempts; payload["state"] = state
            let copyURL = root.appendingPathComponent("\(variant)-owned-tasks.json")
            try JSONSerialization.data(withJSONObject: payload).write(to: copyURL)
            let copyStore = try AgentTaskStore(persistenceURL: copyURL)
            let copyConsumer = TaskCenterControlConsumer(store: copyStore, childTranscriptSessionStore: reloadedSessions)
            #expect(copyConsumer.receiptRows().first { $0.taskID == locator.taskID }?.durationTitle() == "未记录")
            #expect(copyConsumer.childTranscript(navigation: navigation) == before)
        }
        let retryFact = try #require(reopened.project().fact(taskID: locator.taskID, parentID: locator.parentID))
        // A cold read-only consumer has no live retry owner. The ordinary
        // Composer fresh-user-event retry path is qualified separately;
        // this low-level call must leave the original cancelled run intact.
        #expect(throws: TaskCenterControlConsumerError.unavailable) {
            _ = try reopened.execute(TaskCenterControlRequest(taskID: locator.taskID,
                parentID: locator.parentID, revision: retryFact.revision,
                scopeID: scopeID, actorID: "683-owned-test",
                idempotencyKey: "683-retry", action: .retry, runID: locator.runID))
        }
        #expect(reloadedTasks.controlSnapshot(taskID: locator.taskID,
            parentID: locator.parentID)?.runID == locator.runID)
        #expect(reopened.childTranscript(navigation: navigation) == before)
        #expect(reloadedTasks.receipt(runID: locator.runID) == receipt)
        #expect(reloadedSessions.loadSession(id: locator.childSessionID) == childBefore)
    }

    @Test("empty and malformed task requests reach explicit actual parent outcomes", arguments: [true, false])
    func emptyOrInvalidTaskHasExplicitDurableParentOutcome(emptyTasks: Bool) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("child683-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let provider = Child683Provider(workspace: root, emptyTasks: emptyTasks)
        let sessionID = UUID()
        let seed = SessionStore(directory: root.appendingPathComponent("sessions"))
        try seed.createSession(id: sessionID.uuidString, title: "683 empty or invalid")
        let fixture = try await makeBridge(root: root, store: tasks, provider: provider, runner: Child683Runner())
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture.settings) {} }
        try #require(SettingsCenter.active === fixture.settings)
        try #require(fixture.settings.sessionStore === bridge.chat.sessionStore)
        let chat = bridge.chat
        let sessions = try #require(chat.sessionStore)
        chat.switchSession(id: sessionID)
        try #require(chat.activeSessionID == sessionID)
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        chat.draftText = "683 parent request"
        chat.submitComposer()
        for _ in 0..<500 {
            if !chat.isStreaming && provider.requests.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming && provider.requests.count == 2)
        let fact = try #require(engine.toolExecutionFactLedger.facts.first { $0.toolCallID == "child683-orchestrate" })
        #expect(fact.status == (emptyTasks ? .succeeded : .failed))
        let identity = try #require(fact.executionIdentity)
        #expect(identity.turn.sessionID == sessionID.uuidString)
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == (emptyTasks ? .idle : .failed))
        #expect(chat.terminalReceipt(for: identity)?.outcome == (emptyTasks ? .succeeded : .failed))
        let persisted = try #require(sessions.loadSession(id: sessionID.uuidString))
        let nextRequest = try #require(provider.requests.last)
        let consumers = [chat.messages.map { $0.asLLMMessage() }, persisted.messages, nextRequest]
        for messages in consumers {
            let results = messages.flatMap { $0.toAgentContentParts() }.compactMap { part -> (String, Bool)? in
                guard case .toolResult(let id, _, let content, let isError, _, _, _, _) = part,
                      id == "child683-orchestrate" else { return nil }
                return (content, isError)
            }
            try #require(results.count == 1)
            #expect(results[0].1 == !emptyTasks)
            if emptyTasks {
                let payload = try #require(JSONSerialization.jsonObject(with: Data(results[0].0.utf8)) as? [String: Any])
                #expect(payload["version"] as? Int == 1)
                let rows = try #require(payload["results"] as? [Any])
                #expect(rows.isEmpty)
            } else {
                #expect(results[0].0.contains("Error executing tool"))
            }
        }
        #expect(tasks.taskCenterSnapshots().allSatisfy { $0.taskID != "683-invalid" })
        let reopened = SessionStore(directory: root.appendingPathComponent("sessions"))
        #expect(reopened.loadSession(id: sessionID.uuidString) == persisted)
    }
}

/// Only the local protocol producer is controlled. Both attempts are created
/// by production Orchestrator; the second is a real TaskCenter user retry.
private final class J4DerivedChildProvider: LLMProvider, ProviderRuntimeConfigurationIdentity {
    let name = "child683-parent"
    var model = LLMModel(id: "child683-model", displayName: "J4 child", provider: "child683-parent")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "child683-owned-config"
    private let workspace: URL
    private let lock = NSLock()
    private var owner: BuiltinToolExecutor?
    private var parentScope: ChildToolWorkspaceScope?
    private var generationsValue: [String] = []
    private var sessionsValue: [String] = []
    private var originsValue: [ChildToolWorkspaceScope.BackgroundOrigin] = []
    private var callIDs: [String: String] = [:]
    private var refused = 0
    private var checks: Set<String> = []
    init(workspace: URL) { self.workspace = workspace }
    func install(owner: BuiltinToolExecutor) { lock.withLock { self.owner = owner } }
    var generations: [String] { lock.withLock { generationsValue } }
    var childSessions: [String] { lock.withLock { sessionsValue } }
    var origins: [ChildToolWorkspaceScope.BackgroundOrigin] { lock.withLock { originsValue } }
    var refusalCount: Int { lock.withLock { refused } }
    var independentChecks: Set<String> { lock.withLock { checks } }
    var parentWasGlobal: Bool { lock.withLock { parentScope?.backgroundOrigin == .globalParent } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [], maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        if let context = AgentExecutionContext.current, let binding = context.childToolRuntimeBinding {
            let generation = try #require(binding.boundary.identity.generationID)
            let scope = try #require(ChildToolWorkspaceScope.current)
            let fresh = lock.withLock { () -> Bool in
                guard callIDs[generation] == nil else { return false }
                generationsValue.append(generation)
                sessionsValue.append(binding.boundary.identity.childSessionID)
                originsValue.append(scope.backgroundOrigin)
                callIDs[generation] = "j4-child-background-" + String(generationsValue.count)
                return true
            }
            #expect(scope.backgroundOrigin == .restricted)
            let callID = try #require(lock.withLock { callIDs[generation] })
            if fresh {
                if generations.count == 1 { try await verifyIndependentRuntimeGuards(context) }
                return try response(["tool_calls": [["id": callID, "name": "shell_execute", "input": [
                    "command": "printf 'UNEXPECTED' > unexpected-background.txt", "cwd": workspace.path,
                    "run_in_background": true, "timeout": 30]]]])
            }
            let refusals = messages.flatMap { $0.toAgentContentParts() }.compactMap { part -> String? in
                if case .toolResult(let id, _, let content, let isError, _, _, _, _) = part, id == callID, isError { return content }
                return nil
            }
            let refusalComments = refusals.prefix(2).map { refusal in
                let marker = " [TRUNCATED]"
                return refusal.count > 320
                    ? String(refusal.prefix(320 - marker.count)) + marker : refusal
            }
            #expect(refusals.contains { $0.contains("子任务或项目任务暂不支持后台命令") },
                    "J4 generation=\(generation) callID=\(callID) sameCallErrorRefusals=\(refusalComments) additionalItemsTruncated=\(refusals.count > 2)")
            lock.withLock { refused += 1 }
            throw J4ChildResult.refusedAfterActualToolResult
        }
        if messages.flatMap({ $0.toAgentContentParts() }).contains(where: {
            if case .toolResult = $0 { return true }; return false
        }) { return LLMResponse(text: "parent retained child refusal", stopReason: "stop", usage: nil) }
        let scope = try #require(ChildToolWorkspaceScope.current)
        #expect(scope.backgroundOrigin == .globalParent)
        lock.withLock { parentScope = scope }
        return try response(["tool_calls": [["id": "j4-orchestrate", "name": "orchestrate", "input": [
            "input_version": 2, "strategy": "sequential", "tasks": [["id": "j4-derived-child", "title": "background child refusal",
                "instructions": "try the one owned background call", "agent": "builtin", "required_capabilities": ["tools"],
                "allowed_tool_names": ["shell_execute", "shell_output", "shell_stop"],
                "working_directory": workspace.path,
                "allowed_read_roots": [workspace.path], "allowed_write_roots": [workspace.path]]]]]]])
    }
    nonisolated(nonsending) private func verifyIndependentRuntimeGuards(_ context: AgentExecutionContextSnapshot) async throws {
        let owner = try #require(lock.withLock { self.owner })
        let global = try #require(lock.withLock { parentScope })
        #expect(global.backgroundOrigin == .globalParent)
        for onlySnapshot in [false, true] {
            let isolated = AgentExecutionContextSnapshot(provider: context.provider, approvalGate: context.approvalGate,
                turnController: context.turnController, currentConversationID: context.currentConversationID,
                makeChildBudget: context.makeChildBudget, deadline: context.deadline, taskStore: context.taskStore,
                toolExecutionFactLedger: context.toolExecutionFactLedger, parentBinding: context.parentBinding,
                parentTurnHandle: context.parentTurnHandle, parentRuntimeIdentity: context.parentRuntimeIdentity,
                childRuntimeSnapshot: onlySnapshot ? context.childRuntimeSnapshot : nil,
                childToolRuntimeBinding: onlySnapshot ? nil : context.childToolRuntimeBinding,
                composerSnapshot: context.composerSnapshot, composerPolicyFacts: context.composerPolicyFacts,
                offeredToolNames: context.offeredToolNames, childMutationsEnabled: context.childMutationsEnabled,
                parentAuthorityCheck: context.parentAuthorityCheck, executionIdentity: context.executionIdentity)
            do {
                _ = try await ChildToolWorkspaceScope.$current.withValue(global) {
                    try await AgentExecutionContext.$current.withValue(isolated) {
                        try await owner.execute(name: "shell_execute", input: ["command": "pwd", "cwd": workspace.path, "run_in_background": true])
                    }
                }
                Issue.record("an isolated captured child runtime fact must not start background work")
            } catch {
                if onlySnapshot { #expect(error as? ToolExecutorError == .shellRejected("子任务或项目任务暂不支持后台命令")) }
                else { #expect(error as? ToolExecutionFactLedgerError == .invalidCanonicalIdentity) }
                _ = lock.withLock { checks.insert(onlySnapshot ? "snapshot-only" : "binding-only") }
            }
        }
    }
    private func response(_ payload: [String: Any]) throws -> LLMResponse {
        LLMResponse(text: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self), stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
private enum J4ChildResult: Error { case refusedAfterActualToolResult }
