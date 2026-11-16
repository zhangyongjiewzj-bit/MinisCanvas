import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private enum Child439Error: Error {
    case unexpectedChildReceiptSet, unexpectedReplayReceipt, unexpectedProviderCall
}

/// Reuses donor969c's one completed synthetic runner. The production
/// orchestrator, task store and parent message consumer remain unchanged.
private actor Child439Runner: ExternalAgentRunner {
    let name = "child439-script"
    let isAvailable = true
    private var completed: [String] = []
    func run(task: SubAgentTask) async throws -> String {
        completed.append(task.id)
        return "completed-child439-one"
    }
    func invocations() -> [String] { completed }
}

private actor Child439Approval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
                         requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// Observes real provider requests; it never inserts or persists messages.
/// Exact terminal replay uses the envelope the production child already made.
private final class Child439Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "child439-parent"
    var model = LLMModel(id: "child439-model", displayName: "439 synthetic", provider: "child439-parent")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "child439-owned-synthetic-config"
    private let store: AgentTaskStore
    private let firstReply: String?
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    private var replayed = 0

    init(store: AgentTaskStore, delegateOneChild: Bool) throws {
        self.store = store
        if delegateOneChild {
            let input: [String: Any] = [
                "input_version": 1, "strategy": "sequential",
                "tasks": [["id": "child439-one", "title": "one child",
                           "instructions": "complete one synthetic child",
                           "agent": "external:child439-script"]]
            ]
            firstReply = String(decoding: try JSONSerialization.data(withJSONObject: [
                "tool_calls": [["id": "child439-orchestrate-call",
                                "name": OrchestrationToolExecutor.toolName, "input": input]]
            ]), as: UTF8.self)
        } else { firstReply = nil }
    }

    func requests() -> [[LLMMessage]] { lock.withLock { captured } }
    func replayCount() -> Int { lock.withLock { replayed } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let index = lock.withLock { captured.append(messages); return captured.count }
        guard index <= 2 else { throw Child439Error.unexpectedProviderCall }
        if index == 1, let firstReply {
            return LLMResponse(text: firstReply, stopReason: "stop", usage: nil)
        }
        if firstReply != nil {
            // The same production store also records session actions. Require
            // one typed child receipt instead of treating the first receipt as it.
            let childReceipts = store.allReceipts().filter { $0.childResultEnvelope != nil }
            guard childReceipts.count == 1,
                  let receipt = childReceipts.first,
                  let envelope = receipt.childResultEnvelope,
                  receipt.taskID == "child439-one", envelope.taskID == receipt.taskID else {
                throw Child439Error.unexpectedChildReceiptSet
            }
            let firstReplay = try store.settleChildResult(envelope)
            let secondReplay = try store.settleChildResult(envelope)
            guard firstReplay == receipt, secondReplay == receipt else {
                throw Child439Error.unexpectedReplayReceipt
            }
            lock.withLock { replayed += 2 }
        }
        return LLMResponse(text: "parent observed its history", stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw Child439Error.unexpectedProviderCall
    }
}

@Suite("439 one child returns to durable parent exactly once")
@MainActor
struct SingleChildDurableParent439Tests {
    /// The existing 413 production composition, with owned synthetic stores.
    /// No persistence handler, fabricated policy binding or alternate engine.
    private func makeBridge(profile: RuntimeIsolationProfile, store: AgentTaskStore, provider: Child439Provider,
                            runner: Child439Runner,
                            expectedAppliedReadiness: [ProviderReadinessPersistenceRecord]? = nil) throws -> (BridgeStore, SettingsCenter) {
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
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
                evidenceID: "child439-synthetic-readiness", isApplied: false,
                discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt
            )]))
            let applied = readiness.applyDiscoveredModels(providerID: provider.name,
                modelIDs: [provider.model.id], appliedAt: checkedAt.addingTimeInterval(1))
            #expect(applied.count == 1 && applied.first?.applyReceiptID?.isEmpty == false)
        }
        let ownedSessionStore = SessionStore(directory: profile.sessionDirectory)
        let ownedBadgeDirectory = root.appendingPathComponent("badges461")
        let ownedBadgeStore = SessionBadgeStore(directory: ownedBadgeDirectory)
        let shortcuts = ShortcutStore(defaults: defaults)
        let keychain = profile.makeKeychainStore()
        let secrets = profile.makeEnvironmentStore(keychain: keychain)
        let memory = MemoryStore(directory: profile.memoryDirectory)
        let skills = SkillStore(skillsRoot: profile.minisCoreDirectory.appendingPathComponent("skills"))
        let mcp = MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain)
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory), envStore: secrets,
            memoryStore: memory, sessionStore: ownedSessionStore, sessionBadgeStore: ownedBadgeStore,
            logManager: profile.makeLogManager(), mcpManager: mcp, skillStore: skills,
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain), shortcutStore: shortcuts,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: readiness)
        let bridge = BridgeStore(
            shortcutStore: shortcuts, preferencesDefaults: defaults,
            logManager: settings.logManager,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: ownedBadgeStore,
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            sessionStore: ownedSessionStore,
            canvasFactory: { _ in preconditionFailure("439 must not construct CanvasStore") },
            canvasRuntimeState: .disabled,
            agentTaskStore: store,
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json")),
            memoryStore: memory, commandEnvStore: secrets, canonicalMCPManager: mcp,
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-binding.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        try #require(bridge.chat.attachPersistence(ownedSessionStore, badgeStore: ownedBadgeStore))
        try #require(ProductionPickerCatalogWiring.bind(chat: bridge.chat, center: settings, profile: profile))
        bridge.attachProductionServices(
            agentSettings: settings.settings.agent,
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: profile.sessionDirectory,
            mcpManager: mcp, skillStore: skills,
            approvalDelegateOverride: Child439Approval(),
            policyDefaults: ProductionPolicyDefaults(budget: 1_000, deadlineHorizon: 120,
                                                     autonomyLevel: .l3, networkDomains: []),
            enableOrchestration: true, externalRunners: [runner.name: runner],
            // This is the unchanged admission flag from 413. Both injected
            // protocol producers above are local and implement no transport.
            externalNetworkAllowed: true,
            sessionReadSecretStore: secrets
        )
        // AJ-2's existing-store branch must retain the exact owned authorities.
        // This fixture does not cover Bridge's default created-store branch.
        try #require(bridge.chat.sessionStore === ownedSessionStore)
        let ownedManager = try #require(bridge.chat.sessionManager)
        try #require(ownedManager.store === ownedSessionStore)
        try #require(ownedManager.badgeStore === ownedBadgeStore)
        let expectedSessionDirectory = profile.sessionDirectory
        #expect(ownedManager.store.directory.isFileURL && expectedSessionDirectory.isFileURL)
        #expect(ownedManager.store.directory.pathComponents == expectedSessionDirectory.pathComponents)
        #expect(FileManager.default.fileExists(atPath: ownedBadgeDirectory.path))
        bridge.updateApprovalPolicy(.alwaysAsk)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        return (bridge, settings)
    }

    private func childResults(_ messages: [LLMMessage]) -> [(id: String, content: String, isError: Bool)] {
        messages.flatMap { $0.toAgentContentParts() }.compactMap { part in
            guard case .toolResult(let id, _, let content, let isError, _, _, _, _) = part,
                  id == "child439-orchestrate-call" else { return nil }
            return (id, content, isError)
        }
    }

    private func awaitTurn(_ chat: ChatStore, provider: Child439Provider, requestCount: Int,
        failureContext: @autoclosure () -> String = "stage=UNOBSERVED type=UNOBSERVED case=UNOBSERVED") async throws {
        // Existing 413 bounded settlement wait; a timeout remains a failure.
        for _ in 0..<500 {
            if provider.requests().count == requestCount && !chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming)
        try #require(provider.requests().count == requestCount, Comment(rawValue: failureContext()))
    }

    private func switchSession(_ chat: ChatStore, to id: UUID, store: AgentTaskStore) throws {
        let before = store.allReceipts()
        let needsAction = chat.activeSessionID != id
        chat.switchSession(id: id)
        try #require(chat.activeSessionID == id)
        let after = store.allReceipts()
        #expect(Array(after.prefix(before.count)) == before)
        try #require(after.count == before.count + (needsAction ? 1 : 0))
        for receipt in after.dropFirst(before.count) {
            #expect(receipt.configurationFingerprint == "session-action-v1")
            #expect(receipt.taskID.hasPrefix("session-action:"))
            #expect(receipt.runID.hasPrefix("session-action-run:"))
            #expect(receipt.outcome == .succeeded && receipt.childResultEnvelope == nil)
        }
    }

    @Test("D-AGENT-01/02 single completion and terminal replay survive parent reopen without duplication")
    func oneChildTerminalReplayPersistsOneParentResultAndNextRequest() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "child439", canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionDirectory = profile.sessionDirectory
        let seed = SessionStore(directory: sessionDirectory)
        let parentID = UUID(), otherID = UUID()
        try seed.createSession(id: parentID.uuidString, title: "439 parent")
        try seed.createSession(id: otherID.uuidString, title: "439 other parent")
        try seed.saveMessage(LLMMessage(role: .user, content: "other-parent-only"), sessionID: otherID.uuidString)
        let tasksURL = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: tasksURL)
        let runner = Child439Runner()
        let provider = try Child439Provider(store: store, delegateOneChild: true)
        let (bridge, settings) = try makeBridge(profile: profile, store: store, provider: provider, runner: runner)
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(settings) {} }
        let chat = bridge.chat
        let originalReadiness = try #require(chat.providerReadinessStore)
        let appliedReadiness = originalReadiness.records
        try #require(appliedReadiness.count == 1)
        try #require(store.allReceipts().isEmpty)
        try switchSession(chat, to: parentID, store: store)
        let originalSessions = try #require(chat.sessionStore)
        let otherBefore = try #require(originalSessions.loadSession(id: otherID.uuidString))
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.orchestrationTaskStore === store)
        #expect(engine.toolExecutionFactLedger.hasDurableAuthority)
        #expect((engine.composedExecutor as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound == true)
        // switchSession above legitimately creates a session-action receipt.
        // Keep the complete ordered baseline so no other new receipt is hidden.
        let receiptsBeforeTurn = store.allReceipts()
        try #require(receiptsBeforeTurn.allSatisfy { $0.childResultEnvelope == nil })
        let unobservedFailure = "stage=UNOBSERVED type=UNOBSERVED case=UNOBSERVED"
        var firstFailureContext = unobservedFailure
        let previousFailureObserver = chat.turnFailureObserverForTests
        defer { chat.turnFailureObserverForTests = previousFailureObserver }
        chat.turnFailureObserverForTests = { observation in
            previousFailureObserver?(observation)
            guard observation.sessionID == parentID, firstFailureContext == unobservedFailure else { return }
            firstFailureContext = "stage=\(observation.stage.rawValue) type=\(observation.errorType) case=\(observation.errorCaseName ?? "UNMAPPED")"
        }
        chat.draftText = "delegate exactly one synthetic child"
        chat.submitComposer()
        try await awaitTurn(chat, provider: provider, requestCount: 2,
            failureContext: firstFailureContext)

        #expect(await runner.invocations() == ["child439-one"])
        #expect(provider.replayCount() == 2)
        let receiptsAfterTurn = store.allReceipts()
        let childReceipts = receiptsAfterTurn.filter { $0.childResultEnvelope != nil }
        try #require(childReceipts.count == 1)
        let receipt = try #require(childReceipts.first)
        #expect(receiptsAfterTurn == receiptsBeforeTurn + [receipt])
        let envelope = try #require(receipt.childResultEnvelope)
        #expect(envelope.taskID == "child439-one" && envelope.outcome == .succeeded)
        #expect(receipt.outcome == .succeeded)
        #expect(!envelope.attemptID.isEmpty && !envelope.childExecutionID.isEmpty)
        #expect(envelope.output == "completed-child439-one")
        let completedChild = try #require(store.taskSnapshot(runID: receipt.runID))
        #expect(completedChild.taskID == "child439-one" && completedChild.status == .succeeded)
        #expect(completedChild.parentContextSnapshotID == envelope.parentContextSnapshotID)
        let parentFact = try #require(engine.toolExecutionFactLedger.facts.first {
            $0.toolCallID == "child439-orchestrate-call"
        })
        #expect(parentFact.status == .succeeded)
        #expect(parentFact.compositeKey?.sessionID == parentID.uuidString)
        let persisted = try #require(originalSessions.loadSession(id: parentID.uuidString))
        let nextRequest = try #require(provider.requests().dropFirst().first)
        let consumers: [(String, [LLMMessage])] = [
            ("live-parent", chat.messages.map { $0.asLLMMessage() }),
            ("persisted-parent", persisted.messages),
            ("next-provider-request", nextRequest)
        ]
        for (group, messages) in consumers {
            let results = childResults(messages)
            // Owned synthetic metadata only: no message body, tool arguments,
            // credential material or provider configuration is logged.
            let metadata = messages.prefix(32).enumerated().map { index, message in
                "\(index):role=\(message.role.rawValue)"
                    + ",callID=\(message.toolCallID?.prefix(160) ?? "nil")"
                    + ",nativeCalls=\(message.toolCalls.count)"
                    + ",exactChildResults=\(childResults([message]).count)"
                    + ",containsMarker=\(message.content.contains("completed-child439-one"))"
            }.joined(separator: ";")
            print("CHILD454 consumer=\(group) parent=\(parentID.uuidString)"
                + " run=\(receipt.runID) attempt=\(envelope.attemptID)"
                + " count=\(messages.count) metadata=[\(metadata)]")
            #expect(results.count == 1, "consumer=\(group)")
            let result = try #require(results.first, "consumer=\(group)")
            #expect(!result.isError && result.content.contains("child439-one"))
            #expect(result.content.contains("completed-child439-one"))
        }
        #expect(originalSessions.loadSession(id: otherID.uuidString)?.messages == otherBefore.messages)

        // Reopen both durable authorities. Exact replay is performed on the
        // new task store; neither the probe nor test writes a parent result.
        let reopenedStore = try AgentTaskStore(persistenceURL: tasksURL)
        #expect(reopenedStore.allReceipts() == receiptsAfterTurn)
        #expect(try reopenedStore.settleChildResult(envelope) == receipt)
        #expect(try reopenedStore.settleChildResult(envelope) == receipt)
        #expect(reopenedStore.allReceipts() == receiptsAfterTurn)
        #expect(reopenedStore.taskSnapshot(runID: receipt.runID) == completedChild)
        let reopenedSessions = SessionStore(directory: sessionDirectory)
        let reopenedParent = try #require(reopenedSessions.loadSession(id: parentID.uuidString))
        #expect(reopenedParent.id == persisted.id)
        #expect(reopenedParent.messages == persisted.messages)
        #expect(childResults(reopenedParent.messages).count == 1)
        #expect(reopenedSessions.loadSession(id: otherID.uuidString)?.messages == otherBefore.messages)

        let resumedProvider = try Child439Provider(store: reopenedStore, delegateOneChild: false)
        let (reopened, reopenedSettings) = try makeBridge(profile: profile, store: reopenedStore, provider: resumedProvider,
                                      runner: runner, expectedAppliedReadiness: appliedReadiness)
        defer { reopened.chat.stopAllStreamingForSafety(); withExtendedLifetime(reopenedSettings) {} }
        let resumedChat = reopened.chat
        // A fresh composition root admits a new turn only after its actual
        // production attachment restores the effective-settings gate.
        // The first fixture happened to finish that async assembly before
        // submit; reopening must await the same production boundary.
        if let attachment = reopened.lastChildGovernorSafetyTask {
            await attachment.value
        }
        if let source = resumedChat.effectiveSettingsSnapshotSource {
            try #require(source() != nil)
        }
        let resumedSessions = try #require(resumedChat.sessionStore)
        #expect(resumedSessions !== originalSessions)
        #expect(reopenedStore.allReceipts() == receiptsAfterTurn)
        try switchSession(resumedChat, to: parentID, store: reopenedStore)
        let receiptsBeforeResumedTurn = reopenedStore.allReceipts()
        resumedChat.draftText = "continue using the one child result"
        resumedChat.submitComposer()
        try await awaitTurn(resumedChat, provider: resumedProvider, requestCount: 1)
        #expect(reopenedStore.allReceipts() == receiptsBeforeResumedTurn)
        let resumedRequest = try #require(resumedProvider.requests().first)
        let resumedResults = childResults(resumedRequest)
        #expect(resumedResults.count == 1)
        #expect(resumedResults.first?.content == childResults(persisted.messages).first?.content)
        let continuedParent = try #require(resumedSessions.loadSession(id: parentID.uuidString))
        #expect(childResults(continuedParent.messages).count == 1)

        try switchSession(resumedChat, to: otherID, store: reopenedStore)
        let receiptsBeforeOtherTurn = reopenedStore.allReceipts()
        resumedChat.draftText = "continue this other parent"
        resumedChat.submitComposer()
        try await awaitTurn(resumedChat, provider: resumedProvider, requestCount: 2)
        #expect(reopenedStore.allReceipts() == receiptsBeforeOtherTurn)
        let otherRequest = try #require(resumedProvider.requests().last)
        #expect(childResults(otherRequest).isEmpty)
        #expect(!otherRequest.contains { $0.content.contains("completed-child439-one") })
        let continuedOther = try #require(resumedSessions.loadSession(id: otherID.uuidString))
        #expect(childResults(continuedOther.messages).isEmpty)
        #expect(await runner.invocations() == ["child439-one"])
        #expect(reopenedStore.allReceipts().filter { $0.childResultEnvelope != nil } == [receipt])
        #expect(reopenedStore.taskSnapshot(runID: receipt.runID) == completedChild)
        #expect(await settings.usageStore.waitForPersistence())
        #expect(await reopenedSettings.usageStore.waitForPersistence())
        // No source-only claim is UI PASS.
    }
}
