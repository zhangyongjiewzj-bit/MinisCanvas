import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private enum Task05EndedProviderError: Error {
    case firstChildFailed
    case unexpectedRequest
}

/// The protocol producer only supplies model replies. Composer, Orchestrator,
/// Task Center, the child transcript, and both durable receipts are production.
private final class Task05EndedProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let workspace: URL
    let name = "task05-ended-owned-provider"
    var model = LLMModel(id: "task05-ended-owned-model", displayName: "Task05 synthetic",
                         provider: "task05-ended-owned-provider")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "task05-ended-owned-configuration"
    private let lock = NSLock()
    private var parentCalls = 0
    private var childPrompts: [String] = []

    init(workspace: URL) { self.workspace = workspace }

    func counts() -> (parent: Int, child: Int, prompts: [String]) {
        lock.withLock { (parentCalls, childPrompts.count, childPrompts) }
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                     tools: [AgentToolDefinition], maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        if AgentExecutionContext.current?.childToolRuntimeBinding != nil {
            let paragraphs = messages.filter { $0.role == .user }
                .flatMap { $0.content.components(separatedBy: "\n\n") }
            guard let childInput = paragraphs.first(where: { $0 == "task05 ended child input" }) else {
                throw Task05EndedProviderError.unexpectedRequest
            }
            let ordinal = lock.withLock { () -> Int in
                childPrompts.append(childInput)
                return childPrompts.count
            }
            if ordinal == 1 { throw Task05EndedProviderError.firstChildFailed }
            guard ordinal == 2 else { throw Task05EndedProviderError.unexpectedRequest }
            return LLMResponse(text: "task05 ended second child completed",
                               stopReason: "stop", usage: nil)
        }
        let ordinal = lock.withLock { () -> Int in
            parentCalls += 1
            return parentCalls
        }
        if ordinal == 1 {
            let input: [String: Any] = [
                "input_version": 2, "strategy": "sequential", "tasks": [[
                    "id": "task05-ended-child", "title": "retry the same durable request",
                    "instructions": "task05 ended child input", "agent": "builtin",
                    "required_capabilities": ["tools"],
                    "allowed_tool_names": ["file_read"], "allowed_read_roots": [workspace.path]
                ]]
            ]
            let data = try JSONSerialization.data(withJSONObject: [
                "tool_calls": [[
                    "id": "task05-ended-orchestrate", "name": OrchestrationToolExecutor.toolName,
                    "input": input
                ]]
            ])
            return LLMResponse(text: String(decoding: data, as: UTF8.self),
                               stopReason: "stop", usage: nil)
        }
        guard ordinal == 2 else { throw Task05EndedProviderError.unexpectedRequest }
        return LLMResponse(text: "task05 parent saw failed child",
                           stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw Task05EndedProviderError.unexpectedRequest
    }
}

private actor Task05EndedApproval: ApprovalDelegate {
    private var requests = 0

    func requestCount() -> Int { requests }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests += 1
        return ApprovalDecision(approved: true, confirmed: true,
                         requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

@Suite("D-TASK-05 ended parent retries from a new Task Center user event")
@MainActor
struct TaskCenterEndedParentActualRetry05Tests {
    private func ownedSettings(root: URL, sessions: SessionStore) throws -> SettingsCenter {
        let defaults = try #require(UserDefaults(suiteName: "task-center-settings-\(UUID().uuidString)"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("settings-env"),
                keychain: keychain, privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("settings-memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("settings-memory-files")),
            sessionStore: sessions,
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("settings-badges")),
            logManager: LogManager(directory: root.appendingPathComponent("settings-logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("settings-mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("task-center-settings-usage-\(UUID().uuidString)")),
            shortcutStore: ShortcutStore(defaults: defaults),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("settings-readiness")))
    }

    @Test("settings capture accepts only this fixture's canonical session root")
    func ownedSettingsCaptureRetainsForeignRootRefusal() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("task05-settings-\(UUID().uuidString)")
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let owner = try ownedSettings(root: root, sessions: sessions)
        defer { withExtendedLifetime(owner) {} }
        let provider = Task05EndedProvider(workspace: root)
        let sessionID = "task05-owned-settings-capture"
        let expected = try #require(BridgeStore.canonicalSessionDirectoryIdentity(sessions.directory))
        let accepted = ChatContextSettingsCapture.deferredForProduction(
            sessionStore: sessions, sessionID: sessionID, model: provider.model,
            expectedCanonicalDirectory: expected,
            canonicalizeDirectory: { BridgeStore.canonicalSessionDirectoryIdentity($0) })
        let foreignSessions = SessionStore(directory: root.appendingPathComponent("foreign-sessions"))
        let foreign = try ownedSettings(root: root.appendingPathComponent("foreign"), sessions: foreignSessions)
        defer { withExtendedLifetime(foreign) {} }
        let refused = ChatContextSettingsCapture.deferredForProduction(
            sessionStore: sessions, sessionID: sessionID, model: provider.model,
            expectedCanonicalDirectory: expected,
            canonicalizeDirectory: { BridgeStore.canonicalSessionDirectoryIdentity($0) })
        // The admitted snapshot survives a later ambient-owner change.
        let preparedAccepted = try #require(await accepted.preparedForExecution())
        guard case .accepted(let snapshot) = preparedAccepted.resolution else {
            Issue.record("Same-root settings must produce a valid captured context")
            return
        }
        #expect(snapshot.sessionID == sessionID)
        let preparedRefused = try #require(await refused.preparedForExecution())
        guard case .scopeMismatch = preparedRefused.resolution else {
            Issue.record("Foreign-root settings must retain the existing hard refusal")
            return
        }
    }

    @Test("ended parent retry uses current authority and retains the failed result when revoked", arguments: [false, true])
    func endedParentUsesActualBridgeRetryProducer(revokeBeforeRetry: Bool) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("task05-ended-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledger)
        let provider = Task05EndedProvider(workspace: root)
        let defaults = try #require(UserDefaults(suiteName: "task05-ended-\(UUID().uuidString)"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let checkedAt = Date()
        let lineage = ProviderReadinessLineage.derived(
            providerID: provider.name, modelID: provider.model.id, checkedAt: checkedAt)
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: provider.name, modelID: provider.model.id,
            status: .passed, readinessState: .mock, checkedAt: checkedAt,
            evidenceID: "task05-ended-owned-provider-readiness",
            isApplied: false, discoveryReceiptID: lineage.discoveryReceiptID,
            discoveredAt: lineage.discoveredAt
        )]))
        #expect(readiness.applyDiscoveredModels(
            providerID: provider.name, modelIDs: [provider.model.id],
            appliedAt: checkedAt.addingTimeInterval(1)).count == 1)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("Task05 headless test cannot construct CanvasStore") },
            agentTaskStore: store,
            contextManifestStore: try ContextManifestStore(
                persistenceURL: root.appendingPathComponent("manifests.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-binding.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false,
                                             audioOutputDevicePresent: false)
            }
        )
        defer { bridge.chat.stopAllStreamingForSafety() }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        // Compose this fixture's real owner; never borrow a preceding suite's active settings.
        let settingsOwner = try ownedSettings(root: root, sessions: sessions)
        defer { withExtendedLifetime(settingsOwner) {} }
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        try #require(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        let approval = Task05EndedApproval()
        let attached = bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: root.appendingPathComponent("sessions"),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            approvalDelegateOverride: approval,
            policyDefaults: ProductionPolicyDefaults(
                budget: 1_000, deadlineHorizon: 120, autonomyLevel: .l3,
                networkDomains: []),
            enableOrchestration: true,
            externalRunners: [:],
            externalNetworkAllowed: true,
            sessionReadSecretStore: EnvVarStore(
                directory: root.appendingPathComponent("env"),
                keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        )
        await attached.value
        let chat = bridge.chat
        try #require(chat.sessionStore === sessions)
        try #require(bridge.orchestrationTaskStore === store)
        bridge.updateApprovalPolicy(.alwaysAsk)
        chat.streamingProviderOverride = provider
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .auto, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false)
        let sourceSessionID = try #require(chat.activeSessionID)
        chat.draftText = "start one owned child and let its first call fail"
        chat.submitComposer()
        for _ in 0..<500 {
            if !chat.isStreaming && provider.counts().child == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        #expect(provider.counts().parent == 2)
        #expect(provider.counts().child == 1)
        let originalComposer = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(originalComposer.sessionID == sourceSessionID.uuidString)
        #expect(originalComposer.hasRequiredPolicyIdentity)
        #expect(chat.activeExecutionIdentity(for: sourceSessionID) == nil)
        let originalExecution = try #require(
            chat.executionSnapshot(forSessionID: sourceSessionID)?.executionIdentity)
        let originalReceipt = try #require(store.allReceipts().first {
            $0.taskID == "task05-ended-child"
        })
        guard case .failed = originalReceipt.outcome else {
            Issue.record("The original child must actually fail before Task Center retry")
            return
        }
        let originalRunID = originalReceipt.runID
        let originalTask = try #require(store.taskSnapshot(runID: originalRunID))
        let originalLocator = try #require(originalTask.childTranscriptLocator)
        let originalChild = try #require(sessions.loadSession(id: originalLocator.childSessionID))
        let originalChildURL = sessions.sessionsDirectory.appendingPathComponent(
            originalLocator.childSessionID + ".json")
        let originalChildBytes = try Data(contentsOf: originalChildURL)
        let originalIntent = try #require(store.settledFailedChildLaunchIntent(
            taskID: originalTask.taskID, originalParentID: originalTask.parentID,
            runID: originalRunID))
        let originalTerminal = try #require(store.parentTurnTerminalFact(
            parent: originalIntent.intent.parent, execution: originalExecution))
        #expect(originalTerminal.outcome == .failed)
        #expect(originalTerminal.children.count == 1)
        #expect(originalTerminal.children.first?.runID == originalRunID)
        #expect(originalIntent.task.instructions == "task05 ended child input")
        #expect(originalIntent.intent.parent.taskID == originalComposer.taskID)
        #expect(originalChild.createdByRunID == originalRunID)
        let fact = try #require(bridge.taskCenterGoalProjection().fact(
            taskID: originalTask.taskID, parentID: originalTask.parentID))
        let request = TaskCenterControlRequest(
            taskID: fact.taskID, parentID: fact.parentID, revision: fact.revision,
            scopeID: try #require(fact.scopeID), actorID: "task-center-ui",
            idempotencyKey: "task05-ended-actual-retry",
            action: .retry, runID: originalRunID)
        if revokeBeforeRetry {
            let facts = chat.composerPolicyFacts
            chat.configureComposerPolicy(ComposerPolicyFactSource(
                knownCapabilities: facts.knownCapabilities, grantedCapabilities: facts.grantedCapabilities,
                capabilityGrantBindings: facts.capabilityGrantBindings, allowedWriteRoots: facts.allowedWriteRoots,
                workspaceID: facts.workspaceID, revision: facts.revision, grantEpoch: facts.grantEpoch,
                leaseID: facts.leaseID, expiresAt: facts.expiresAt, revoked: true,
                autonomyCeiling: facts.autonomyCeiling))
            await #expect(throws: ChatStore.TaskCenterRetryAdmissionError.self) {
                _ = try await bridge.executeTaskCenterRetryFromUserEvent(request)
            }
            #expect(provider.counts().child == 1)
            #expect(store.receipt(runID: originalRunID) == originalReceipt)
            return
        }
        let userMessagesBefore = chat.messages.filter { $0.role == .user }.count
        let assistantMessagesBefore = chat.messages.filter { $0.role == .assistant }.count
        let approvalsBefore = await approval.requestCount()
        print("TASK05_RETRY_PREFLIGHT active=\(chat.activeSessionID == sourceSessionID) has=\(chat.hasSession(sourceSessionID)) streaming=\(chat.isStreaming) isolated=\(chat.isCanonicalWriteIsolated(sourceSessionID)) engine=\(type(of: chat.agentEngine)) runtimeFactory=\(chat.turnRuntimeSnapshotFactory != nil) policy=\(chat.prepareTopLevelTaskPolicy != nil)")
        let control: TaskCenterControlReceipt
        do {
            control = try await bridge.executeTaskCenterRetryFromUserEvent(request)
        } catch {
            print("TASK05_RETRY_THROW type=\(type(of: error)) error=\(error)")
            throw error
        }
        let newRunID = try #require(control.resultingRunID)
        #expect(newRunID != originalRunID)
        #expect(store.canonicalAttemptID(runID: newRunID) != originalReceipt.attemptID)
        #expect(provider.counts().child == 2)
        #expect(await approval.requestCount() > approvalsBefore)
        #expect(provider.counts().prompts == [
            originalIntent.task.instructions, originalIntent.task.instructions
        ])
        #expect(chat.messages.filter { $0.role == .user }.count == userMessagesBefore + 1)
        #expect(chat.messages.filter { $0.role == .assistant }.count == assistantMessagesBefore + 1)
        let freshComposer = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(freshComposer.taskID != originalComposer.taskID)
        #expect(freshComposer.sessionID == originalComposer.sessionID)
        #expect(freshComposer.hasRequiredPolicyIdentity)
        #expect(chat.activeExecutionIdentity(for: sourceSessionID) == nil)
        let freshExecution = try #require(
            chat.executionSnapshot(forSessionID: sourceSessionID)?.executionIdentity)
        #expect(freshExecution != originalExecution)
        let binding = try #require(store.retryRunRuntimeBinding(runID: newRunID))
        #expect(binding.taskID == originalTask.taskID)
        #expect(binding.originalParentID == originalTask.parentID)
        #expect(binding.attemptID == store.canonicalAttemptID(runID: newRunID))
        #expect(binding.parent.taskID == freshComposer.taskID)
        #expect(binding.parent.taskID != originalComposer.taskID)
        #expect(binding.parent.sessionID == sourceSessionID.uuidString)
        #expect(binding.parent.conversationID == originalIntent.intent.parent.conversationID)
        #expect(binding.parent.actorID == originalIntent.intent.parent.actorID)
        #expect(binding.parent.isValid)
        #expect(binding.parentGoal.deadline > Date())
        #expect(binding.child.parentTaskID == freshComposer.taskID)
        #expect(binding.child.childTaskID == originalTask.taskID)
        #expect(binding.child.parentGoalID == binding.parentGoal.goalID)
        let freshTerminal = try #require(store.parentTurnTerminalFact(
            parent: binding.parent, execution: freshExecution))
        #expect(freshTerminal.outcome == .succeeded)
        #expect(freshTerminal.children.count == 1)
        #expect(freshTerminal.children.first?.runID == newRunID)
        #expect(freshTerminal.children.first?.outcome == .succeeded)
        #expect(chat.terminalReceipt(for: freshExecution)?.outcome == .succeeded)
        let retryReport = try #require(await bridge.joinTaskCenterRetryExecution(runID: newRunID))
        #expect(retryReport.result.isSuccess)
        let newReceipt = try #require(store.receipt(runID: newRunID))
        let newEnvelope = try #require(newReceipt.childResultEnvelope)
        #expect(newEnvelope.outcome == .succeeded)
        let newTask = try #require(store.taskSnapshot(runID: newRunID))
        let newLocator = try #require(newTask.childTranscriptLocator)
        let newChild = try #require(sessions.loadSession(id: newLocator.childSessionID))
        #expect(newLocator.runID == newRunID)
        #expect(newLocator.attemptID == newReceipt.attemptID)
        #expect(newLocator.childSessionID == binding.child.childSessionID)
        #expect(newLocator.childSessionID != originalLocator.childSessionID)
        #expect(newChild.createdByRunID == newRunID)
        #expect(store.receipt(runID: originalRunID) == originalReceipt)
        #expect(try Data(contentsOf: originalChildURL) == originalChildBytes)
        #expect(sessions.loadSession(id: originalLocator.childSessionID) == originalChild)

        let oldEnvelope = try #require(originalReceipt.childResultEnvelope)
        let lateOld = ChildResultEnvelope(
            taskID: oldEnvelope.taskID, runID: oldEnvelope.runID,
            attemptID: oldEnvelope.attemptID,
            attemptNumber: oldEnvelope.attemptNumber, sequence: oldEnvelope.sequence,
            parentContextSnapshotID: oldEnvelope.parentContextSnapshotID,
            childExecutionID: oldEnvelope.childExecutionID,
            outcome: .succeeded, outputDigest: "task05-ended-late-old-success",
            childTranscriptLocator: oldEnvelope.childTranscriptLocator)
        #expect(throws: AgentTaskStoreError.childResultIdempotencyConflict) {
            _ = try store.settleChildResult(lateOld)
        }
        let foreign = ChildResultEnvelope(
            taskID: "task05-ended-foreign", runID: newRunID,
            attemptID: newEnvelope.attemptID,
            attemptNumber: newEnvelope.attemptNumber, sequence: newEnvelope.sequence,
            parentContextSnapshotID: newEnvelope.parentContextSnapshotID,
            childExecutionID: newEnvelope.childExecutionID,
            outcome: .succeeded, outputDigest: "task05-ended-foreign-success")
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.settleChildResult(foreign)
        }
        #expect(store.receipt(runID: originalRunID) == originalReceipt)
        #expect(store.receipt(runID: newRunID) == newReceipt)
        let userMessagesAfter = chat.messages.filter { $0.role == .user }.count
        let childCallsBeforeRepeat = provider.counts().child
        let repeated = try await bridge.executeTaskCenterRetryFromUserEvent(request)
        #expect(repeated == control)
        #expect(chat.messages.filter { $0.role == .user }.count == userMessagesAfter)
        #expect(provider.counts().child == 2)
        let reopened = try AgentTaskStore(persistenceURL: ledger)
        #expect(reopened.receipt(runID: originalRunID) == originalReceipt)
        #expect(reopened.receipt(runID: newRunID) == newReceipt)
        #expect(reopened.retryRunRuntimeBinding(runID: newRunID) == binding)
        #expect(reopened.parentTurnTerminalFact(
            parent: originalIntent.intent.parent, execution: originalExecution) == originalTerminal)
        #expect(reopened.parentTurnTerminalFact(
            parent: binding.parent, execution: freshExecution) == freshTerminal)
        let row = try #require(TaskCenterControlConsumer(store: reopened)
            .receiptRows().first { $0.runID == newRunID })
        #expect(row.childResultEnvelope?.outcome == .succeeded)
        #expect(row.statusTitle == "已完成")
        let reopenedChild = try #require(SessionStore(directory: root.appendingPathComponent("sessions"))
            .loadSession(id: newLocator.childSessionID))
        #expect(reopenedChild.createdByRunID == newRunID)
        print("TASK05_ACTUAL_RETRY oldRun=\(originalRunID) oldAttempt=\(originalReceipt.attemptID) "
            + "newRun=\(newRunID) newAttempt=\(newReceipt.attemptID) "
            + "providerChildCalls=\(provider.counts().child) "
            + "repeatProviderDelta=\(provider.counts().child - childCallsBeforeRepeat) "
            + "repeatUserDelta=\(chat.messages.filter { $0.role == .user }.count - userMessagesAfter) "
            + "coldStatus=\(row.statusTitle)")
    }
}
