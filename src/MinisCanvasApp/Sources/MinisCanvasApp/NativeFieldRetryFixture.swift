import Foundation
import MinisCore

// Field-only protocol producer, following the 1611 accepted Task08 fixture.
// Durable dispatch, failure, retry and cancellation use production services.
private enum NativeFieldRetryError: Error { case firstChildFailure, unexpectedCall }
actor NativeFieldRetryRunner: ExternalAgentRunner {
    let name = "task05-retry-cancel-unused"
    let isAvailable = true
    func run(task: SubAgentTask) async throws -> String { throw NativeFieldRetryError.unexpectedCall }
}
actor NativeFieldRetryApproval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
                         requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// Only the remote protocol boundary is controlled. Dispatch, cancellation,
/// transcript writer, TaskCenter mutation and settlement are actual production.
final class NativeFieldRetryProvider: LLMProvider,
    ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "task05-retry-cancel-provider"
    var model = LLMModel(id: "task05-retry-cancel-model", displayName: "owned retry cancel", provider: "task05-retry-cancel-provider")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "owned-task05-retry-cancel-config"
    private let workspace: URL
    private let taskID: String
    private let title: String
    private let lock = NSLock()
    private var childCallsValue = 0
    private var heldValue = false
    private var cancelledValue = false
    private var releasedValue = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(workspace: URL, taskID: String = "task05-cancel-child", title: String = "retry cancellation") {
        self.workspace = workspace
        self.taskID = taskID
        self.title = title
    }
    var childCalls: Int { lock.withLock { childCallsValue } }
    var isHeld: Bool { lock.withLock { heldValue } }
    var sawCancellation: Bool { lock.withLock { cancelledValue } }
    func releaseActualResponse() {
        let pending = lock.withLock {
            releasedValue = true
            let value = continuation
            continuation = nil
            return value
        }
        pending?.resume()
    }
    private func markCancelled() { lock.withLock { cancelledValue = true } }
    private func awaitOwnedRelease() async {
        await withCheckedContinuation { pending in
            let released = lock.withLock {
                heldValue = true
                if releasedValue { return true }
                continuation = pending
                return false
            }
            if released { pending.resume() }
        }
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              tools: [], maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        if messages.contains(where: { $0.role == .user && $0.content == "task05 cancel original durable instructions" }) {
            let count = lock.withLock { childCallsValue += 1; return childCallsValue }
            if count == 1 { throw NativeFieldRetryError.firstChildFailure }
            guard count == 2 else { throw NativeFieldRetryError.unexpectedCall }
            await withTaskCancellationHandler {
                await awaitOwnedRelease()
            } onCancel: { [self] in markCancelled() }
            // Deliberately late remote success: the production identity and
            // cancellation guards must reject this actual response.
            return LLMResponse(text: "TASK05_LATE_REMOTE_SUCCESS_MUST_NOT_COMMIT", stopReason: "stop", usage: nil)
        }
        if messages.contains(where: { $0.role == .tool || $0.content.contains("\"tool_result\"") }) {
            return LLMResponse(text: "owned parent recorded first failure", stopReason: "stop", usage: nil)
        }
        let payload: [String: Any] = ["tool_calls": [["id": "task05-cancel-orchestrate", "name": OrchestrationToolExecutor.toolName,
            "input": ["input_version": 2, "strategy": "sequential", "tasks": [[
                "id": taskID, "title": title, "instructions": "task05 cancel original durable instructions",
                "agent": "builtin", "required_capabilities": ["tools"],
                "allowed_tool_names": ["file_read"], "allowed_read_roots": [workspace.path]
            ]]]]]]
        return LLMResponse(text: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self), stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw NativeFieldRetryError.unexpectedCall
    }
}


@MainActor
final class NativeFieldRetryFixture {
    enum Failure: Error { case preparation, initialTurnDidNotSettle, missingFailedIntent }
    let bridge: BridgeStore
    let provider: NativeFieldRetryProvider
    let originalReceipt: AgentTaskReceipt
    let parentID: String
    private init(bridge: BridgeStore, provider: NativeFieldRetryProvider,
                 receipt: AgentTaskReceipt, parentID: String) {
        self.bridge = bridge
        self.provider = provider
        self.originalReceipt = receipt
        self.parentID = parentID
    }

    static func prepare(root: URL, taskID: String, title: String) async throws -> NativeFieldRetryFixture {
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let provider = NativeFieldRetryProvider(workspace: workspace, taskID: taskID, title: title)
        let runner = NativeFieldRetryRunner()
        guard let defaults = UserDefaults(suiteName: "native-field-retry-" + UUID().uuidString) else {
            throw Failure.preparation
        }
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let checkedAt = Date()
        let lineage = ProviderReadinessLineage.derived(providerID: provider.name,
                                                       modelID: provider.model.id, checkedAt: checkedAt)
        guard readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: provider.name, modelID: provider.model.id,
            status: .passed, readinessState: .mock, checkedAt: checkedAt,
            evidenceID: "native-field-local-protocol", isApplied: false,
            discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt
        )]) else { throw Failure.preparation }
        let applied = readiness.applyDiscoveredModels(providerID: provider.name,
            modelIDs: [provider.model.id], appliedAt: checkedAt.addingTimeInterval(1))
        guard applied.count == 1, applied.first?.applyReceiptID?.isEmpty == false else {
            throw Failure.preparation
        }
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("Task05 must not construct CanvasStore") },
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
        guard bridge.chat.attachPersistence(ownedSessionStore, badgeStore: ownedBadgeStore) else { throw Failure.preparation }
        let productionAttachment = bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: root.appendingPathComponent("sessions"),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            approvalDelegateOverride: NativeFieldRetryApproval(),
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
        guard bridge.chat.sessionStore === ownedSessionStore,
              bridge.chat.sessionManager?.store === ownedSessionStore,
              bridge.chat.sessionManager?.badgeStore === ownedBadgeStore else {
            throw Failure.preparation
        }
        bridge.updateApprovalPolicy(.alwaysAsk)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)

        let chat = bridge.chat
        chat.draftText = "owned task05 first request"
        chat.submitComposer()
        let firstTurn = chat.turnTaskForTests(sessionID: chat.activeSessionID)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && (chat.isStreaming || provider.childCalls == 0) {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard !chat.isStreaming, provider.childCalls == 1, firstTurn != nil else {
            chat.stopStreaming()
            provider.releaseActualResponse()
            await firstTurn?.value
            throw Failure.initialTurnDidNotSettle
        }
        await firstTurn?.value
        guard let receipt = store.allReceipts().first(where: { $0.taskID == taskID }),
              receipt.outcome == .failed(reason: "execution-failed"),
              let task = store.taskSnapshot(runID: receipt.runID),
              store.settledFailedChildLaunchIntent(taskID: taskID,
                  originalParentID: task.parentID, runID: receipt.runID) != nil else {
            throw Failure.missingFailedIntent
        }
        return NativeFieldRetryFixture(bridge: bridge, provider: provider,
                                       receipt: receipt, parentID: task.parentID)
    }

    func waitForHeldRetry() async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !provider.isHeld {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func matchesHeldRetry(_ row: TaskCenterReceiptRow?) -> Bool {
        guard provider.isHeld, provider.childCalls == 2, let row,
              let runID = bridge.taskCenterControlRunID(taskID: originalReceipt.taskID, parentID: parentID),
              let task = bridge.agentTaskStore.taskSnapshot(runID: runID),
              let attemptID = bridge.agentTaskStore.canonicalAttemptID(runID: runID),
              let attempt = bridge.agentTaskStore.attempt(runID: runID, attemptID: attemptID) else { return false }
        return runID != originalReceipt.runID
            && row.taskID == originalReceipt.taskID && row.parentID == parentID
            && row.runID == runID && row.receiptID == runID && row.attemptID == attemptID
            && task.taskID == originalReceipt.taskID && task.parentID == parentID
            && attempt.runID == runID
            && attempt.parentContextSnapshotID == task.parentContextSnapshotID
            && bridge.agentTaskStore.receipt(runID: originalReceipt.runID) == originalReceipt
            && row.taskState == .retrying && row.runState == .retrying
            && row.attemptState == .retrying && row.effectState == .retrying
    }

    func cleanup() async -> [String] {
        var errors: [String] = []
        let store = bridge.agentTaskStore
        let chat = bridge.chat
        let runID = bridge.taskCenterControlRunID(taskID: originalReceipt.taskID, parentID: parentID)
        let parent = runID.flatMap { store.retryRunRuntimeBinding(runID: $0)?.parent }
        let execution = chat.activeSessionID.flatMap {
            chat.executionSnapshot(forSessionID: $0)?.executionIdentity
        }
        chat.stopStreaming()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && provider.isHeld && !provider.sawCancellation {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { continuation.resume() }
            }
        }
        if provider.isHeld && !provider.sawCancellation { errors.append("retry_cancellation_missing") }
        provider.releaseActualResponse()
        if let runID, runID != originalReceipt.runID {
            if await bridge.joinTaskCenterRetryExecution(runID: runID) == nil {
                errors.append("retry_child_join_missing")
            }
        }
        // The outer UI Task has no handle. This fact is its last durable write.
        if let parent, let execution {
            while Date() < deadline && store.parentTurnTerminalFact(parent: parent, execution: execution) == nil {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { continuation.resume() }
                }
            }
            if store.parentTurnTerminalFact(parent: parent, execution: execution) == nil {
                errors.append("retry_outer_terminal_fact_missing")
            }
        } else if provider.isHeld {
            errors.append("retry_runtime_binding_missing")
        }
        return errors
    }
}
