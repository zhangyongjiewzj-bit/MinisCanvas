import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor Settings3177Approval: ApprovalDelegate {
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

private final class Settings3177MutationProvider:
    LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable
{
    let name = "settings3177-offline"
    var model = LLMModel(id: "settings3177-model", displayName: "Settings 2094", provider: "settings3177-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "settings3177-isolated"
    private let lock = NSLock()
    private var requests: [(names: [String], messages: [LLMMessage])] = []
    private let callName: String
    private let callInput: [String: Any]
    private let repeatedTurns: Bool
    private let callIDPrefix: String

    init(name: String, input: [String: Any], repeatedTurns: Bool = false,
         callIDPrefix: String = "settings3177-call") {
        callName = name
        callInput = input
        self.repeatedTurns = repeatedTurns
        self.callIDPrefix = callIDPrefix
    }

    var offeredNames: [String] { lock.withLock { requests.first?.names ?? [] } }
    var returnedToolMessage: String? {
        lock.withLock {
            requests.dropFirst().flatMap(\.messages)
                .first(where: { $0.role == .tool && $0.toolCallID == "\(callIDPrefix)-1" })?.content
        }
    }
    var requestCount: Int { lock.withLock { requests.count } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let count = lock.withLock {
            requests.append((tools.map(\.name), messages))
            return requests.count
        }
        if count == 1 || (repeatedTurns && count == 3) {
            let data = try JSONSerialization.data(withJSONObject: callInput, options: [.sortedKeys])
            let call = LLMToolCall(
                id: "\(callIDPrefix)-\((count + 1) / 2)", name: callName,
                rawArguments: String(decoding: data, as: UTF8.self), arguments: callInput
            )
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [call])
        }
        return LLMResponse(text: "已处理隔离设置请求。", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor Settings3177ProviderGate {
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

/// No transport: repeated known catalog calls make the actual AgentLoop's
/// frozen iteration limit visible as the number of real Provider requests.
private final class Settings3177LoopProvider:
    LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "settings3177-offline"
    var model = LLMModel(id: "settings3177-model", displayName: "Settings 3177", provider: "settings3177-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "settings3177-isolated"
    private let lock = NSLock()
    private var requests: [[String]] = []
    private let firstGate: Settings3177ProviderGate?
    private let callPrefix = "settings3177-loop-" + UUID().uuidString
    init(firstGate: Settings3177ProviderGate? = nil) { self.firstGate = firstGate }
    var requestCount: Int { lock.withLock { requests.count } }
    var offeredCatalogInEveryRequest: Bool {
        lock.withLock { !requests.isEmpty && requests.allSatisfy { $0.contains(BL6SettingsToolApproval.catalogToolName) } }
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let count = lock.withLock { requests.append(tools.map(\.name)); return requests.count }
        if count == 1, let firstGate { await firstGate.park() }
        try Task.checkCancellation()
        return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
            LLMToolCall(id: "\(callPrefix)-\(count)", name: BL6SettingsToolApproval.catalogToolName,
                        rawArguments: "{}", arguments: [:])
        ])
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor private final class Settings3177RuntimeObservations {
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
private final class Settings3177RecordingEngine: ChatAgentEngine, @unchecked Sendable {
    let delegate: AgentLoopChatEngine
    private let observations: Settings3177RuntimeObservations
    init(delegate: AgentLoopChatEngine, observations: Settings3177RuntimeObservations) {
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

@Suite("D-SETE actual mixed settings turn consumer 3177", .serialized)
@MainActor
struct SettingsTurnSnapshot3177Tests {
    private func makeFixture(
        includeSyntheticSkill: Bool = false,
        canonicalSkillsState: Bool = false
    ) throws -> (SettingsCenter, BridgeStore, URL, SkillsStore, SchedulerTaskStore) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("sete3177-\(UUID().uuidString)")
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
                providerID: "settings3177-offline", modelID: "settings3177-model",
                status: .passed, readinessState: .mock, checkedAt: now,
                evidenceID: "settings3177-synthetic-readiness", isApplied: true,
                discoveryReceiptID: "settings3177-synthetic-discovery", discoveredAt: now,
                applyReceiptID: "provider-readiness-apply:settings3177-synthetic",
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
            usageStore: UsageStore(domain: .suite("sete3177-\(UUID().uuidString)")),
            providerReadinessStore: readiness
        )
        let defaults = try #require(UserDefaults(suiteName: "sete3177-\(UUID().uuidString)"))
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
        chat.draftText = "TASK3177 owned settings temporal request"
        chat.submitComposer()
        // Keep native type-based policy/refresh/budget producers in place for
        // all future tasks. The private prepared task already owns its witness.
        if let observed = chat.agentEngine as? Settings3177RecordingEngine {
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

    private func captured(_ observations: Settings3177RuntimeObservations, session: UUID,
        expected: BL6EffectiveSettingsSnapshot, limit: Int
    ) throws -> Settings3177RuntimeObservations.Delivery {
        let delivery = try #require(observations.deliveries.last {
            $0.execution.turn.sessionID == session.uuidString
        })
        let frozen = try #require(delivery.runtime.inFlightSettingsSnapshot)
        #expect(delivery.runtime.requiresInFlightSettingsSnapshot)
        #expect(frozen.snapshot == expected)
        #expect(frozen.snapshot.value(for: "agent.max-loop-iterations") == .integer(limit))
        #expect(frozen.capturedForTurnID == delivery.execution.operationID)
        #expect(delivery.runtime.turn == delivery.execution.turn)
        #expect(delivery.composer.taskID.count > 0)
        #expect(delivery.loopLimit == limit)
        #expect(observations.deliveries.filter { $0.execution == delivery.execution }.count == 1)
        // Only public scalar/hash/owned turn identity reaches the future raw.
        print("TASK3177 runtime task=\(delivery.composer.taskID) operation=\(delivery.execution.operationID) revision=\(frozen.snapshot.catalogRevision) loopLimit=\(delivery.loopLimit)")
        return delivery
    }

    @Test("approved scalar mutation preserves actual in-flight turn while existing/new-session tasks and receipt Undo capture their own revision")
    func inFlightExistingAndNewTaskUseTheirAdmittedSettings() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        let chat = bridge.chat
        let gate = Settings3177ProviderGate()
        let preparationGate = Settings3177ProviderGate()
        defer {
            Task { await gate.open(); await preparationGate.open() }
            chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings3177Approval()
        await bridge.attachProductionServices(agentSettings: center.settings.agent,
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true).value
        chat.composerPolicySelection = ComposerPolicySelection(mode: .manual,
            approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        let nativeTaskPolicy = try #require(chat.prepareTopLevelTaskPolicy)
        let observations = Settings3177RuntimeObservations()
        chat.prepareTopLevelTaskPolicy = { [weak chat] taskID, createdAt, projectTargetID, projectTask in
            guard let chat else { return false }
            if let previous = chat.agentEngine as? Settings3177RecordingEngine {
                chat.agentEngine = previous.delegate
            }
            guard nativeTaskPolicy(taskID, createdAt, projectTargetID, projectTask),
                  let concrete = chat.agentEngine as? AgentLoopChatEngine else { return false }
            chat.agentEngine = Settings3177RecordingEngine(
                delegate: concrete.withFrozenSoulExpressionForTurn(), observations: observations)
            return true
        }
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(before.value(for: "agent.max-loop-iterations") == .integer(3))
        let originalSession = chat.applyNewSession(title: "3177-existing-in-flight")
        let oldProvider = Settings3177LoopProvider(firstGate: gate)
        let (_, oldTask) = try start(oldProvider, in: chat)
        let deadline = Date().addingTimeInterval(30)
        while !(await gate.entered) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(await gate.entered)
        #expect(oldProvider.requestCount == 1)
        #expect(chat.turnTaskForTests(sessionID: originalSession) != nil)
        let old = try captured(observations, session: originalSession, expected: before, limit: 3)

        // A second existing task has crossed admission but is held on the
        // existing value-only worker seam, before its first Provider request.
        let preparedSession = chat.applyNewSession(title: "3177-existing-preparing")
        let preparingProvider = Settings3177LoopProvider()
        chat.turnPromptPreprocessPauseForTests = { await preparationGate.park() }
        let (_, preparingTask) = try start(preparingProvider, in: chat)
        chat.turnPromptPreprocessPauseForTests = nil
        let preparationDeadline = Date().addingTimeInterval(30)
        while !(await preparationGate.entered) && Date() < preparationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await preparationGate.entered)
        #expect(preparingProvider.requestCount == 0)
        #expect(chat.turnTaskForTests(sessionID: preparedSession) != nil)

        let mutationSession = chat.applyNewSession(title: "3177-approved-mutation")
        let mutation = Settings3177MutationProvider(name: BL6SettingsToolApproval.toolName,
            input: ["operation": "apply", "expectedRevision": before.catalogRevision,
                    "changes": ["agent.max-loop-iterations": ["kind": "integer", "integer": 5]]],
            callIDPrefix: "3177-apply")
        let (_, mutationTask) = try start(mutation, in: chat)
        try await terminal(mutationTask, session: mutationSession, chat: chat)
        #expect(mutation.requestCount == 2)
        let applyText = try #require(mutation.returnedToolMessage)
        let receipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(applyText.utf8))
        #expect(receipt.changedKeys == ["agent.max-loop-iterations"])
        #expect(receipt.previousRevision == before.catalogRevision)
        #expect(receipt.rollbackValues.isEmpty)
        let after = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(after.catalogRevision == receipt.effectiveRevision)
        #expect(after.value(for: "agent.max-loop-iterations") == .integer(5))
        #expect(SettingsStore(directory: center.settingsStore.directory).settings.agent.maxLoopIterations == 5)
        #expect(try center.settingsStore.bl6ReplayRecord(for: receipt.requestID).get()?.receipt == receipt)
        // This is the original public Bridge effect consumer invoked by the
        // App's maxLoopIterations onChange. A mounted SwiftUI onChange is not
        // claimed by this non-UI fixture.
        bridge.refreshProductionAgentSettings(center.settings.agent)
        #expect(bridge.lastAgentSettingsReapplyReceipt?.source == .runtimeRefresh)
        #expect(bridge.lastAgentSettingsReapplyReceipt?.maxLoopIterations == 5)
        #expect(oldProvider.requestCount == 1)
        #expect(preparingProvider.requestCount == 0)
        #expect(old.runtime.inFlightSettingsSnapshot?.snapshot == before)
        #expect(chat.turnTaskForTests(sessionID: originalSession) != nil)
        #expect(chat.turnTaskForTests(sessionID: preparedSession) != nil)

        let newSession = chat.applyNewSession(title: "3177-created-after-commit")
        let newProvider = Settings3177LoopProvider()
        let (_, newTask) = try start(newProvider, in: chat)
        try await terminal(newTask, session: newSession, chat: chat)
        let newlyCreated = try captured(observations, session: newSession, expected: after, limit: 5)
        #expect(newProvider.requestCount == 5)
        #expect(newProvider.offeredCatalogInEveryRequest)
        #expect(newSession != originalSession)
        #expect(newlyCreated.composer.taskID != old.composer.taskID)
        #expect(oldProvider.requestCount == 1)

        #expect(preparingProvider.requestCount == 0)
        await preparationGate.open()
        try await terminal(preparingTask, session: preparedSession, chat: chat)
        let preparedOld = try captured(observations, session: preparedSession, expected: before, limit: 3)
        #expect(preparingProvider.requestCount == 3)
        #expect(preparingProvider.offeredCatalogInEveryRequest)
        #expect(preparedOld.composer.taskID != old.composer.taskID)
        #expect(preparedOld.runtime.inFlightSettingsSnapshot?.snapshot.catalogRevision != after.catalogRevision)

        await gate.open()
        try await terminal(oldTask, session: originalSession, chat: chat)
        #expect(oldProvider.requestCount == 3)
        #expect(oldProvider.offeredCatalogInEveryRequest)
        #expect(old.runtime.inFlightSettingsSnapshot?.snapshot == before)
        chat.switchSession(id: originalSession)
        try #require(chat.activeSessionID == originalSession)
        let existingProvider = Settings3177LoopProvider()
        let (_, existingTask) = try start(existingProvider, in: chat)
        try await terminal(existingTask, session: originalSession, chat: chat)
        let existingNext = try captured(observations, session: originalSession, expected: after, limit: 5)
        #expect(existingProvider.requestCount == 5)
        #expect(existingProvider.offeredCatalogInEveryRequest)
        #expect(existingNext.execution.turn.sessionID == old.execution.turn.sessionID)
        #expect(existingNext.execution != old.execution)
        #expect(existingNext.composer.taskID != old.composer.taskID)

        chat.switchSession(id: mutationSession)
        try #require(chat.activeSessionID == mutationSession)
        let undo = Settings3177MutationProvider(name: BL6SettingsToolApproval.toolName,
            input: ["operation": "rollback", "expectedRevision": after.catalogRevision,
                    "changes": [String: Any](), "undoReceiptID": receipt.receiptID],
            callIDPrefix: "3177-undo")
        let (_, undoTask) = try start(undo, in: chat)
        try await terminal(undoTask, session: mutationSession, chat: chat)
        #expect(undo.requestCount == 2)
        let undoText = try #require(undo.returnedToolMessage)
        let undoReceipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(undoText.utf8))
        #expect(undoReceipt.operation == .rollback)
        #expect(undoReceipt.changedKeys == receipt.changedKeys)
        let restored = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(restored.values == before.values)
        #expect(restored.catalogRevision == undoReceipt.effectiveRevision)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings.agent.maxLoopIterations == 3)
        bridge.refreshProductionAgentSettings(center.settings.agent)
        #expect(bridge.lastAgentSettingsReapplyReceipt?.maxLoopIterations == 3)
        chat.switchSession(id: originalSession)
        try #require(chat.activeSessionID == originalSession)
        let restoredProvider = Settings3177LoopProvider()
        let (_, restoredTask) = try start(restoredProvider, in: chat)
        try await terminal(restoredTask, session: originalSession, chat: chat)
        _ = try captured(observations, session: originalSession, expected: restored, limit: 3)
        #expect(restoredProvider.requestCount == 3)
        #expect(restoredProvider.offeredCatalogInEveryRequest)
        #expect(old.runtime.inFlightSettingsSnapshot?.snapshot == before)
        #expect(await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }.count == 2)
        #expect(observations.deliveries.count == 7)
        print("TASK3177 actualProviderRequests inFlight=\(oldProvider.requestCount) preparing=\(preparingProvider.requestCount) newSession=\(newProvider.requestCount) existingNext=\(existingProvider.requestCount) afterUndo=\(restoredProvider.requestCount) mutation=\(mutation.requestCount) undo=\(undo.requestCount) deliveries=\(observations.deliveries.count)")
    }
}
