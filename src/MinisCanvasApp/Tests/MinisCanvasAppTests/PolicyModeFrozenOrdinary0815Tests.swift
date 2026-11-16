import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor Policy0815Approval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    private let allowedTools: Set<String>?

    init(allowedTools: Set<String>? = nil) {
        self.allowedTools = allowedTools
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        let allowed = allowedTools?.contains(request.toolName) ?? true
        return ApprovalDecision(
            approved: allowed, confirmed: allowed,
            requestID: request.requestID, bindingDigest: request.identityDigest
        )
    }
}

private actor Policy0815ProviderGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func park() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func open() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Synthetic response input only; the admitted concrete AgentLoop constructs
/// and consumes the production turn and Composer snapshots.
private final class Policy0815Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "policy0815-offline"
    var model = LLMModel(id: "policy0815-model", displayName: "Policy 0815", provider: "policy0815-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "policy0815-isolated"
    private let lock = NSLock()
    private var requests = 0
    private var prompts: [String] = []
    private var deleteDescriptions: [String] = []
    private let firstGate: Policy0815ProviderGate?
    let marker: String
    init(marker: String, firstGate: Policy0815ProviderGate? = nil) {
        self.marker = marker; self.firstGate = firstGate
    }
    var requestCount: Int { lock.withLock { requests } }
    var receivedPrompts: [String] { lock.withLock { prompts } }
    var receivedDeleteDescriptions: [String] { lock.withLock { deleteDescriptions } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let count = lock.withLock {
            requests += 1
            prompts.append(systemPrompt ?? "")
            deleteDescriptions.append(contentsOf: tools.filter { $0.name == "file_delete" }.map(\.description))
            return requests
        }
        if count == 1, let firstGate { await firstGate.park() }
        try Task.checkCancellation()
        return LLMResponse(text: marker, stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor private final class Policy0815RuntimeObservations {
    struct Delivery {
        let composer: ComposerSubmissionSnapshot
        let execution: AgentExecutionIdentity
        let runtime: ChatTurnRuntimeSnapshot
        let loopLimit: Int
    }
    var deliveries: [Delivery] = []
}

/// Passive forwarding witness, installed only after the unchanged production
/// top-level task policy produced this exact concrete engine. It constructs no
/// snapshot, approval, Store, or policy and forwards the original arguments.
private final class Policy0815RecordingEngine: ChatAgentEngine, @unchecked Sendable {
    let delegate: AgentLoopChatEngine
    private let observations: Policy0815RuntimeObservations
    init(delegate: AgentLoopChatEngine, observations: Policy0815RuntimeObservations) {
        self.delegate = delegate
        self.observations = observations
    }
    var isAvailable: Bool { delegate.isAvailable }
    nonisolated(nonsending) func streamReply(provider: any LLMProvider,
        history: [ChatMessageUI], systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await delegate.streamReply(provider: provider, history: history,
                                       systemPrompt: systemPrompt, maxTokens: maxTokens)
    }
    @MainActor func streamReply(provider: any LLMProvider,
        history: [ChatMessageUI], systemPrompt: String, maxTokens: Int,
        conversationID: String?, authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?, turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot, executionIdentity: AgentExecutionIdentity,
        turnRuntimeSnapshot: ChatTurnRuntimeSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        observations.deliveries.append(.init(composer: composerSnapshot, execution: executionIdentity,
            runtime: turnRuntimeSnapshot, loopLimit: delegate.loop.maxIterations))
        return try await delegate.streamReply(provider: provider, history: history,
            systemPrompt: systemPrompt, maxTokens: maxTokens, conversationID: conversationID,
            authorizedSessionReadSessionID: authorizedSessionReadSessionID,
            authorizedSessionReadScope: authorizedSessionReadScope, turnID: turnID,
            composerSnapshot: composerSnapshot, executionIdentity: executionIdentity,
            turnRuntimeSnapshot: turnRuntimeSnapshot)
    }
    func interrupt() { delegate.interrupt() }
    func interrupt(turnID: Int) { delegate.interrupt(turnID: turnID) }
    func compactContext(provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, keepRecent: Int) async throws -> CompactionResult {
        try await delegate.compactContext(provider: provider, history: history,
                                      systemPrompt: systemPrompt, keepRecent: keepRecent)
    }
}

@Suite("D-POLICY-01 actual ordinary mode freeze 0815", .serialized)
@MainActor
struct PolicyModeFrozenOrdinary0815Tests {
    @Test func unconfirmedBypassDoesNotTellTheProviderThatFileRootsAreOpen() async throws {
        let root = FileManager.default.temporaryDirectory
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [root.path], workspaceID: "unconfirmed-provider-turn",
            revision: "unconfirmed-provider-turn", grantEpoch: "unconfirmed-provider-turn",
            leaseID: "unconfirmed-provider-turn", expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l3)
        let engine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            composerPolicyFacts: facts)
        let provider = Policy0815Provider(marker: "Unconfirmed turn stayed within its original instructions.")
        let snapshot = ComposerSubmissionSnapshot(mode: .bypassPermission,
            approvalScope: .request, effort: .standard, sessionID: "unconfirmed-session", turnID: 1,
            taskID: "unconfirmed-task", messageID: "unconfirmed-message", workspaceID: facts.workspaceID,
            createdAt: Date(), policyRevision: facts.revision, grantEpoch: facts.grantEpoch,
            bypassModeConfirmed: false, autonomyCeiling: .l3)
        let original = "Keep the originally authorized file scope."
        let stream = try await engine.streamReply(provider: provider,
            history: [ChatMessageUI(role: .user, content: "Describe the current task without tools.")],
            systemPrompt: original, maxTokens: 64, conversationID: snapshot.sessionID,
            authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil, turnID: 1,
            composerSnapshot: snapshot)
        for try await _ in stream { }
        #expect(provider.requestCount == 1)
        #expect(provider.receivedPrompts == [original])
    }

    private func makeFixture(
        includeSyntheticSkill: Bool = false,
        canonicalSkillsState: Bool = false
    ) throws -> (SettingsCenter, BridgeStore, URL, SkillsStore, SchedulerTaskStore) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("policy0815-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        try #require(readiness.upsert([
            ProviderReadinessPersistenceRecord(
                providerID: "policy0815-offline", modelID: "policy0815-model",
                status: .passed, readinessState: .mock, checkedAt: now,
                evidenceID: "policy0815-synthetic-readiness", isApplied: true,
                discoveryReceiptID: "policy0815-synthetic-discovery", discoveredAt: now,
                applyReceiptID: "provider-readiness-apply:policy0815-synthetic",
                appliedAt: now
            )
        ]))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain
            ),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("policy0815-\(UUID().uuidString)")),
            providerReadinessStore: readiness
        )
        let defaults = try #require(UserDefaults(suiteName: "policy0815-\(UUID().uuidString)"))
        let hermes = root.appendingPathComponent("hermes", isDirectory: true)
        if includeSyntheticSkill {
            let skill = hermes.appendingPathComponent("creative/catalog-owned", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try "---\nname: catalog-owned\ndescription: synthetic\n---\nowned body".write(
                to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        }
        let skills = SkillsStore(
             appStore: center.skillStore,
            stateFileURL: root.appendingPathComponent(canonicalSkillsState ? "skills-enabled.json" : "skill-state.json")
        )
        let scheduler = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: root.appendingPathComponent("scheduler-occurrences.json")
        )
        let bridge = try BridgeStore(
            taskStorePersistenceURL: root.appendingPathComponent("agent-tasks.json"),
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            settingsCatalogSkillsStore: skills,
            settingsCatalogSchedulerStore: scheduler,
            logManager: LogManager(directory: root.appendingPathComponent("bridge-logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: badges,
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, memoryStore: center.memoryStore,
            providerReadinessStore: readiness,
            canvasFeatureLane: .phase3NonCanvas
        )
        // Only the explicit owned local catalog participates in this fixture;
        // app-managed Hermes deployment is a separate original consumer.
        bridge.bindProductionEffectiveSettingsSource { [weak center] in
            center?.bl6EffectiveSettingsSnapshot
        }
        // The native Settings setter commits the Store before publishing its
        // effective/UI mirror. reloadAll() reloads other domains, not scalars.
        center.maxLoopIterations = 3
        try #require(center.lastPersistenceError == nil)
        #expect(center.settingsStore.settings.agent.maxLoopIterations == 3)
        #expect(center.maxLoopIterations == 3)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings.agent.maxLoopIterations == 3)
        return (center, bridge, root, skills, scheduler)
    }

    private func start(_ provider: any LLMProvider, in chat: ChatStore) throws -> (UUID, Task<Void, Never>) {
        let session = try #require(chat.activeSessionID)
        chat.streamingProviderOverride = provider
        chat.draftText = "TASK0815 owned settings temporal request"
        chat.submitComposer()
        // Keep native type-based policy/refresh/budget producers in place for
        // all future tasks. The private prepared task already owns its witness.
        if let observed = chat.agentEngine as? Policy0815RecordingEngine {
            chat.agentEngine = observed.delegate
        }
        let task = try #require(chat.turnTaskForTests(sessionID: session))
        return (session, task)
    }

    private func terminal(_ task: Task<Void, Never>, session: UUID, chat: ChatStore) async throws {
        let deadline = Date().addingTimeInterval(30)
        while chat.turnTaskForTests(sessionID: session) != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(chat.turnTaskForTests(sessionID: session) == nil)
        await task.value
    }

    @Test("five ordinary AgentLoop submissions consume persisted modes while a held old turn keeps its admitted snapshot")
    func persistedModesReachConcreteLoopWithoutChangingHeldTurn() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        let chat = bridge.chat
        let gate = Policy0815ProviderGate()
        defer { Task { await gate.open() }; chat.stopAllStreamingForSafety() }
        let defaults = center.policyRuntimeDefaults
        try #require(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(
            budget: defaults.budget, deadlineHorizon: defaults.deadlineHorizon,
            autonomyLevel: .l3, networkDomains: defaults.networkDomains)))
        #expect(center.policyRuntimeDefaults.budget == defaults.budget)
        #expect(center.policyRuntimeDefaults.deadlineHorizon == defaults.deadlineHorizon)
        #expect(center.policyRuntimeDefaults.networkDomains == defaults.networkDomains)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings.agent.policyRuntimeDefaults == center.policyRuntimeDefaults)
        await bridge.attachProductionServices(agentSettings: center.settings.agent,
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: Policy0815Approval(),
            policyDefaults: center.policyRuntimeDefaults, externalNetworkAllowed: true).value
        center.onApprovalPolicyChanged = { [weak bridge] policy in bridge?.updateApprovalPolicy(policy) }
        center.approvalPolicy = .autoApprove
        try #require(center.lastPersistenceError == nil)
        // Exact existing App composition callback, not a substitute snapshot.
        center.onComposerPolicyChanged = { [weak bridge] policy in
            bridge?.chat.restoreComposerPolicy(policy)
        }
        center.composerPolicy = ComposerPolicySettings(mode: .manual,
            approvalScope: .request, effort: .low, bypassModeConfirmed: false)
        try #require(center.lastPersistenceError == nil)
        let nativePolicy = try #require(chat.prepareTopLevelTaskPolicy)
        let observations = Policy0815RuntimeObservations()
        chat.prepareTopLevelTaskPolicy = { [weak chat] taskID, createdAt, projectTargetID, projectTask in
            guard let chat else { return false }
            if let previous = chat.agentEngine as? Policy0815RecordingEngine {
                chat.agentEngine = previous.delegate
            }
            guard nativePolicy(taskID, createdAt, projectTargetID, projectTask),
                  let concrete = chat.agentEngine as? AgentLoopChatEngine else { return false }
            chat.agentEngine = Policy0815RecordingEngine(
                delegate: concrete.withFrozenSoulExpressionForTurn(), observations: observations)
            return true
        }
        let oldSession = chat.applyNewSession(title: "policy0815-old-in-flight")
        let oldProvider = Policy0815Provider(marker: "policy0815-original-manual", firstGate: gate)
        let (_, oldTask) = try start(oldProvider, in: chat)
        let enteredDeadline = Date().addingTimeInterval(30)
        while !(await gate.entered) && Date() < enteredDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(await gate.entered)
        try #require(oldProvider.requestCount == 1)
        let old = try #require(observations.deliveries.first)
        #expect(old.composer.mode == .manual)
        #expect(old.composer.effort == .low)
        #expect(old.composer.autonomyCeiling == .l3)
        #expect(old.execution.turn.sessionID == oldSession.uuidString)
        #expect(old.runtime.turn == old.execution.turn)
        var admitted: [ComposerTaskMode] = []
        var operations: Set<String> = [old.execution.operationID]
        for mode in ComposerTaskMode.allCases {
            let settings = ComposerPolicySettings(mode: mode, approvalScope: .turn,
                effort: .standard, bypassModeConfirmed: mode == .bypassPermission)
            center.composerPolicy = settings
            try #require(center.lastPersistenceError == nil)
            #expect(center.composerPolicy == settings)
            #expect(SettingsStore(directory: center.settingsStore.directory).settings.agent.composerPolicy == settings)
            #expect(chat.composerPolicySelection.mode == mode)
            #expect(chat.composerPolicySelection.bypassModeConfirmed == settings.bypassModeConfirmed)
            #expect(oldProvider.requestCount == 1)
            #expect(chat.turnTaskForTests(sessionID: oldSession) != nil)
            #expect(observations.deliveries.first?.composer == old.composer)
            #expect(observations.deliveries.first?.runtime.turn == old.runtime.turn)
            let newSession = chat.applyNewSession(title: "policy0815-new-\(mode.rawValue)")
            let provider = Policy0815Provider(marker: "policy0815-current-\(mode.rawValue)")
            let (_, task) = try start(provider, in: chat)
            try await terminal(task, session: newSession, chat: chat)
            let current = try #require(observations.deliveries.last)
            #expect(current.composer.mode == mode)
            #expect(current.composer.approvalScope == .request)
            #expect(current.composer.effort == .standard)
            #expect(current.composer.bypassModeConfirmed == settings.bypassModeConfirmed)
            #expect(current.composer.autonomyCeiling == .l3)
            #expect(current.execution.turn.sessionID == newSession.uuidString)
            #expect(current.runtime.turn == current.execution.turn)
            #expect(current.composer.taskID != old.composer.taskID)
            #expect(operations.insert(current.execution.operationID).inserted)
            #expect(provider.requestCount == 1)
            let prompt = try #require(provider.receivedPrompts.first)
            #expect(prompt.contains("Current turn permissions: user-confirmed bypass.") == (mode == .bypassPermission))
            if mode == .bypassPermission {
                #expect(prompt.contains("outside the current project roots"))
                #expect(prompt.contains("macOS Trash"))
                #expect(prompt.contains("Child tasks retain their separately enforced permissions"))
                #expect(prompt.contains("子任务写文件开关"))
                let deletion = try #require(provider.receivedDeleteDescriptions.first)
                // 第七版重写了 file_delete 说明，逐项核对同样的四条约束。
                #expect(deletion.contains("Every call asks for approval except in confirmed bypass mode."))
                #expect(deletion.contains("Confirmed bypass moves the item to the macOS Trash (recoverable), may reach outside the root"))
                #expect(deletion.contains("Normal mode permanently removes a UTF-8 text file of at most 64 KiB inside an authorized root"))
                #expect(deletion.contains("drops the size and text limits"))
                #expect(deletion.contains("System files, credential directories and the app's own data stay protected."))
            }
            #expect(chat.terminalReceipt(for: current.execution) != nil)
            #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains(provider.marker) })
            let restored = try #require(SessionStore(directory: center.sessionStore.directory).loadSession(id: newSession.uuidString))
            #expect(restored.messages == chat.messages.map { $0.asLLMMessage() })
            #expect(restored.messages.contains { $0.role == .assistant && $0.content.contains(provider.marker) })
            #expect(oldProvider.requestCount == 1)
            #expect(observations.deliveries.first?.composer == old.composer)
            admitted.append(mode)
            print("TASK0815 new mode=\(mode.rawValue) operation=\(current.execution.operationID) providerRequests=\(provider.requestCount) oldHeld=1")
        }
        await gate.open()
        try await terminal(oldTask, session: oldSession, chat: chat)
        #expect(oldProvider.requestCount == 1)
        #expect(chat.terminalReceipt(for: old.execution) != nil)
        #expect(observations.deliveries.first?.composer == old.composer)
        #expect(observations.deliveries.first?.execution == old.execution)
        #expect(admitted == ComposerTaskMode.allCases)
        #expect(operations.count == 6)
        #expect(observations.deliveries.count == 6)
        let oldRestored = try #require(SessionStore(directory: center.sessionStore.directory).loadSession(id: oldSession.uuidString))
        #expect(oldRestored.messages.contains { $0.role == .assistant && $0.content.contains(oldProvider.marker) })
        print("TASK0815 old mode=\(old.composer.mode.rawValue) operation=\(old.execution.operationID) joined=1 deliveries=\(observations.deliveries.count)")
    }
}
