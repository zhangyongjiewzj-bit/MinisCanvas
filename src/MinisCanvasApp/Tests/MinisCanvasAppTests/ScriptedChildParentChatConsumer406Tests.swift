import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private enum Child406Error: Error { case childFailed, unexpectedProviderCall }

/// Synthetic protocol producer only. No endpoint, credential, URLSession,
/// subprocess, or native window is used. Captures the actual parent requests.
private final class Child406Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "child406-parent"
    var model = LLMModel(id: "child406-model", displayName: "406 synthetic", provider: "child406-parent")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "child406-owned-synthetic-config"
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    let firstReply: String

    init() throws {
        let input: [String: Any] = [
            "input_version": 1, "strategy": "sequential",
            "tasks": ["child406-first", "child406-second"].map {
                ["id": $0, "title": $0, "instructions": "complete \($0)",
                 "agent": "external:child406-script"]
            }
        ]
        firstReply = String(decoding: try JSONSerialization.data(withJSONObject: [
            "tool_calls": [["id": "child406-orchestrate-call",
                            "name": OrchestrationToolExecutor.toolName, "input": input]]
        ]), as: UTF8.self)
    }

    private func record(_ messages: [LLMMessage]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        captured.append(messages)
        return captured.count
    }
    func requests() -> [[LLMMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let index = record(messages)
        guard index <= 2 else { throw Child406Error.unexpectedProviderCall }
        return LLMResponse(text: index == 1 ? firstReply : "parent observed child results",
                           stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw Child406Error.unexpectedProviderCall
    }
}

/// Reuses the 396 actual-throw/success control, through the App production
/// composite. No fabricated child report or PolicyRuntimeBound conformance.
private actor Child406Runner: ExternalAgentRunner {
    let name = "child406-script"
    let isAvailable = true
    let failFirst: Bool
    private var invoked: [String] = []
    init(failFirst: Bool) { self.failFirst = failFirst }
    func run(task: SubAgentTask) async throws -> String {
        invoked.append(task.id)
        if failFirst && task.id == "child406-first" { throw Child406Error.childFailed }
        return "completed-\(task.id)"
    }
    func invocations() -> [String] { invoked }
}

private actor Child406Approval: ApprovalDelegate {
    private var observed: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        observed.append(request)
        return ApprovalDecision(approved: true, confirmed: true,
                                requestID: request.requestID, bindingDigest: request.identityDigest)
    }
    func requests() -> [ApprovalRequest] { observed }
}

/// Decodes only the synthetic fixture's real production binding, never a
/// second Goal/Lease or a policy marker fabricated by the provider.
private struct Child413GoalLease: Decodable {
    let goal: GoalEnvelope
    let lease: AutonomyLease
    let taskBindings: [String: Child413TaskGoalLease]
}

private struct Child413TaskGoalLease: Decodable {
    let goal: GoalEnvelope
    let lease: AutonomyLease
}

@Suite("406 production child terminal reaches its parent ChatStore")
@MainActor
struct ScriptedChildParentChatConsumer406Tests {
    @Test("mixed child failure cannot become parent success; all-success control",
          arguments: [true, false])
    func childTerminalFeedsActualParentChatAndTaskCards(failFirst: Bool) async throws {
        // Fail before constructing any default consumer unless the existing
        // validated formal profile owns the entire namespace.
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("child406-\(failFirst)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "child406-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let taskStore = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let provider = try Child406Provider()
        let runner = Child406Runner(failFirst: failFirst)
        let approval = Child406Approval()
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let checkedAt = Date()
        let lineage = ProviderReadinessLineage.derived(providerID: provider.name,
                                                       modelID: provider.model.id, checkedAt: checkedAt)
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: provider.name, modelID: provider.model.id,
            status: .passed, readinessState: .mock,
            checkedAt: checkedAt, evidenceID: "child406-synthetic-readiness",
            isApplied: false, discoveryReceiptID: lineage.discoveryReceiptID,
            discoveredAt: lineage.discoveredAt
        )]))
        let applied = readiness.applyDiscoveredModels(providerID: provider.name,
            modelIDs: [provider.model.id], appliedAt: checkedAt.addingTimeInterval(1))
        #expect(applied.count == 1)
        #expect(applied.first?.applyReceiptID?.isEmpty == false)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("406 headless must not construct CanvasStore") },
            agentTaskStore: taskStore,
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-binding.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        defer { bridge.chat.stopAllStreamingForSafety() }
        let ownedSessionStore = SessionStore(directory: root.appendingPathComponent("sessions"))
        let ownedBadgeDirectory = root.appendingPathComponent("badges461")
        let ownedBadgeStore = SessionBadgeStore(directory: ownedBadgeDirectory)
        try #require(bridge.chat.attachPersistence(ownedSessionStore, badgeStore: ownedBadgeStore))
        let ownedMCPManager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        let ownedSkills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let ownedEnvironment = EnvVarStore(directory: root.appendingPathComponent("env"),
            keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        // The production snapshot captures the actual SettingsCenter owner.
        // Keep a same-root owner alive instead of inheriting another fixture's
        // ambient settings or bypassing the context-directory fence.
        let ownedSettings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: ownedEnvironment, memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: ownedSessionStore, sessionBadgeStore: ownedBadgeStore,
            logManager: LogManager(directory: root.appendingPathComponent("settings-logs")),
            mcpManager: ownedMCPManager, skillStore: ownedSkills, providerReadinessStore: readiness)
        defer { withExtendedLifetime(ownedSettings) {} }
        try #require(SettingsCenter.active === ownedSettings)
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: root.appendingPathComponent("sessions"),
            mcpManager: ownedMCPManager, skillStore: ownedSkills,
            approvalDelegateOverride: approval,
            policyDefaults: ProductionPolicyDefaults(budget: 1_000, deadlineHorizon: 120,
                                                     autonomyLevel: .l3, networkDomains: []),
            enableOrchestration: true,
            externalRunners: [runner.name: runner],
            // Keep the production admission condition. The injected Provider
            // and sole runner above have no network implementation; this flag
            // is not evidence of transport use or a changed product permission.
            externalNetworkAllowed: true,
            sessionReadSecretStore: ownedEnvironment
        )
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
        bridge.updateApprovalPolicy(.autoApprove)
        // Freeze the full identity published by the actual settings-policy
        // producer before submission; its independent settings UUIDs are authoritative.
        let expectedPolicyAuthority: ComposerPolicyFactSource = bridge.chat.composerPolicyFacts
        let chat = bridge.chat
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.orchestrationTaskStore === taskStore)
        #expect(bridge.orchestrationTaskStore === taskStore)
        #expect(engine.toolExecutionFactLedger.hasDurableAuthority)
        #expect((engine.composedExecutor as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound == true)
        chat.streamingProviderOverride = provider
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        let sessionID = try #require(chat.activeSessionID)
        let untouchedSessionIDs = Set(chat.sessions.map(\.id)).subtracting([sessionID])
        chat.draftText = "run the two synthetic children"
        chat.submitComposer()
        for _ in 0..<500 {
            if provider.requests().count == 2 && !chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        #expect(await runner.invocations() == ["child406-first", "child406-second"])
        #expect(provider.requests().count == 2)
        // The final Composer wrapper validates the actual frozen auto/L3 authority.
        // The synthetic external route follows high-risk approval; the test delegate confirms its one request.
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let policyFacts = chat.composerPolicyFacts
        let persistedBinding = try JSONDecoder().decode(Child413GoalLease.self,
            from: Data(contentsOf: root.appendingPathComponent("task-binding.json")))
        let binding = try #require(persistedBinding.taskBindings[snapshot.taskID])
        #expect(snapshot.mode == .auto && snapshot.autonomyCeiling == .l3)
        #expect(snapshot.hasRequiredPolicyIdentity)
        #expect(snapshot.sessionID == sessionID.uuidString)
        #expect(snapshot.workspaceID == policyFacts.workspaceID)
        #expect(snapshot.policyRevision == policyFacts.revision && snapshot.grantEpoch == policyFacts.grantEpoch)
        #expect(policyFacts.autonomyCeiling == .l3 && !policyFacts.revoked && policyFacts.expiresAt > Date())
        #expect(policyFacts.knownCapabilities.contains(OrchestrationToolExecutor.toolName))
        #expect(policyFacts.grantedCapabilities.contains(OrchestrationToolExecutor.toolName))
        #expect(binding.goal.autonomyLevel == .l3)
        #expect(binding.goal.allowedCapabilities.contains(OrchestrationToolExecutor.toolName))
        #expect(binding.goal.networkDomains.isEmpty)
        #expect(binding.goal.fileRoots == policyFacts.allowedWriteRoots)
        #expect(binding.lease.isValid(at: Date(), for: binding.goal.goalID, scopeID: binding.goal.scopeID))
        #expect(binding.lease.expiresAt == binding.goal.deadline && policyFacts.expiresAt == binding.goal.deadline)
        #expect(policyFacts.revision == expectedPolicyAuthority.revision)
        // The pre-submit global lease remains intact. Submission mints a new
        // task goal/epoch/lease, which is the authority actually used here.
        #expect(expectedPolicyAuthority.grantEpoch.hasPrefix(
            "composer-epoch:\(persistedBinding.goal.goalID.uuidString):settings-"))
        #expect(expectedPolicyAuthority.leaseID ==
            "composer-lease:\(persistedBinding.goal.goalID.uuidString)")
        #expect(expectedPolicyAuthority.expiresAt == persistedBinding.goal.deadline)
        #expect(policyFacts.grantEpoch == "composer-epoch:\(binding.goal.goalID.uuidString)")
        #expect(policyFacts.leaseID == "composer-lease:\(binding.goal.goalID.uuidString)")
        // 0845: external child orchestration requires per-call high-risk approval.
        let requests = await approval.requests()
        try #require(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.callID == "child406-orchestrate-call")
        #expect(request.toolName == OrchestrationToolExecutor.toolName)
        #expect(request.riskLevel == .high)
        // 2026-11-16 起只有不可逆操作才需要第二次确认；外部子任务编排仍是高风险、不提供持久放行。
        #expect(!request.requiresSecondConfirmation)
        #expect(request.persistentAllowOffer == nil)

        let receipts = taskStore.allReceipts()
        #expect(receipts.count == 2)
        let first = try #require(receipts.first { $0.childResultEnvelope?.taskID == "child406-first" })
        let second = try #require(receipts.first { $0.childResultEnvelope?.taskID == "child406-second" })
        let envelope = try #require(first.childResultEnvelope)
        #expect(envelope.taskID == "child406-first")
        #expect(first.parentContextSnapshotID == second.parentContextSnapshotID)
        #expect(second.outcome == .succeeded)
        #expect(first.outcome == (failFirst ? .failed(reason: "execution-failed") : .succeeded))
        if failFirst {
            let error = Child406Error.childFailed.localizedDescription
            #expect(envelope.outcome == .failed(reason: error))
            #expect(envelope.error == error)
            #expect(envelope.output == nil)
        } else { #expect(envelope.outcome == .succeeded) }

        let facts = engine.toolExecutionFactLedger.facts.filter { $0.toolCallID == "child406-orchestrate-call" }
        #expect(facts.count == 1)
        let fact = try #require(facts.first)
        let executionIdentity = try #require(fact.executionIdentity)
        #expect(executionIdentity.turn.sessionID == sessionID.uuidString)
        #expect(executionIdentity.turn.turnID == snapshot.turnID)
        #expect(executionIdentity.turn.messageID == snapshot.messageID)
        let key = try #require(fact.compositeKey)
        #expect(key.attemptID == snapshot.attemptID && key.messageID == snapshot.messageID)
        #expect(fact.status == (failFirst ? .failed : .succeeded))
        let parentRuntime = try #require(taskStore.taskSnapshot(runID: first.runID)?.parentRuntimeIdentity)
        let durableJoin = try #require(taskStore.parentTurnTerminalFact(
            parent: parentRuntime, execution: executionIdentity))
        #expect(durableJoin.outcome == (failFirst ? .failed : .succeeded))
        #expect(durableJoin.children.count == 2)
        let event = try #require(chat.conversationEvents.last {
            $0.toolCallID == fact.toolCallID && $0.status == (failFirst ? .failed : .succeeded)
        })
        #expect(event.receiptID == fact.receiptID)
        #expect(ToolEventCard.displayModel(for: event).status == (failFirst ? "失败" : "完成"))
        let rows = bridge.taskCenterControlConsumer.receiptRows().filter {
            ["child406-first", "child406-second"].contains($0.taskID)
        }
        #expect(rows.count == 2)
        #expect(rows.first { $0.taskID == "child406-first" }?.childResultEnvelope == envelope)
        #expect(rows.first { $0.taskID == "child406-first" }?.taskState == (failFirst ? .failed : .completed))
        #expect(rows.first { $0.taskID == "child406-second" }?.childResultEnvelope?.outcome == .succeeded)
        #expect(rows.first { $0.taskID == "child406-second" }?.taskState == .completed)
        for messages in provider.requests().suffix(1) {
            let results = messages.flatMap { $0.toAgentContentParts() }
                .compactMap { part -> (id: String, content: String, isError: Bool)? in
                    guard case .toolResult(let id, _, let content, let isError, _, _, _, _) = part else { return nil }
                    return (id, content, isError)
                }
            #expect(results.count == 1)
            let result = try #require(results.first)
            #expect(result.id == fact.toolCallID)
            #expect(result.isError == failFirst)
            // The production feedback contract is versioned JSON. Retain the
            // original per-child success/failure and ordering assertions, and
            // bind the actual parent-visible references to durable receipts.
            let body = try #require(try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
            #expect(body["version"] as? Int == 1)
            let children = try #require(body["results"] as? [[String: Any]])
            #expect(children.count == 2)
            #expect(children.map { $0["task_id"] as? String } == ["child406-first", "child406-second"])
            #expect(children.map { $0["status"] as? String } == [failFirst ? "failed" : "succeeded", "succeeded"])
            for (child, receipt) in zip(children, [first, second]) {
                let reference = try #require(child["output_ref"] as? [String: Any])
                #expect(reference["task_id"] as? String == receipt.taskID)
                #expect(reference["run_id"] as? String == receipt.runID)
                #expect(reference["attempt_id"] as? String == receipt.attemptID)
                #expect(reference["parent_id"] as? String == taskStore.taskSnapshot(runID: receipt.runID)?.parentID)
            }
        }

        // This is the missing consumer boundary. A neutral model end_turn
        // cannot erase the canonical failed-child fact in the parent badge or
        // its terminal receipt. Paired success must still retire normally.
        let parent = try #require(chat.executionSnapshot(forSessionID: sessionID))
        #expect(parent.state == (failFirst ? .failed : .idle))
        let terminal = try #require(chat.terminalReceipt(for: executionIdentity))
        #expect(terminal.outcome == (failFirst ? .failed : .succeeded))
        #expect(parent.turnID == snapshot.turnID && parent.taskID == snapshot.taskID)
        #expect(terminal.revision == 1)
        #expect(chat.activeExecutionIdentity(for: sessionID) == nil)
        // A settled turn's late callbacks cannot reopen or overwrite its
        // authoritative failure/success, including the old success cleanup.
        #expect(!chat.markExecutionSucceeded(sessionID: sessionID, executionIdentity: executionIdentity))
        #expect(!chat.markExecutionFailed(sessionID: sessionID, executionIdentity: executionIdentity,
                                        reason: "late old-turn failure"))
        #expect(chat.terminalReceipt(for: executionIdentity) == terminal)
        #expect(chat.sessions.filter { untouchedSessionIDs.contains($0.id) }.allSatisfy {
            chat.executionSnapshot(forSessionID: $0.id) == nil
        })
        #expect(chat.messages.last(where: { $0.role == .assistant })?.content.contains("parent observed child results") == true)
        // Retain this owned fixture directory and original failure evidence.
        // No source/test result here counts as native UI or requirement closure.
    }
}
