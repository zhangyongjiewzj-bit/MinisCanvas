import AppKit
import Foundation
import SwiftUI
import MinisCore
import Testing
@testable import MinisCanvasApp

// These tests use the production ChatStore admission/plan consumer and
// AgentLoopChatEngine with a real BuiltinToolExecutor rooted in disposable data.
// The provider is the sole scripted boundary: no network or credentials.
@Suite("Goal22 shallow production predicates group 2", .serialized)
@MainActor
struct Goal22ShallowProductionPredicateGroup2Tests {
    @Test(arguments: [false, true])
    func completedPlanApprovalAdmitsANewTurnInTheChosenMode(autoEdit: Bool) async throws {
        let fixture = try makePlanFixture(ceiling: .l2)
        let (profile, chat, provider) = fixture
        defer { chat.stopAllStreamingForSafety(); try? profile.cleanupDisposableRoots() }
        try await producePlan(chat)
        let proposal = try #require(chat.activePlanApproval)
        let original = chat.messages
        let planSnapshot = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(planSnapshot.mode == .plan)
        let decision: PlanApprovalDecision = autoEdit ? .approveAutoEdit : .approveManual
        #expect(chat.planApprovalDisabledReason(for: autoEdit ? .autoEdit : .manual) == nil)
        #expect(await chat.resolvePlanApproval(decision, proposalID: proposal.id))
        let session = try #require(chat.activeSessionID)
        if let running = chat.turnTaskForTests(sessionID: session) { await running.value }
        let execution = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(execution.mode == (autoEdit ? .autoEdit : .manual))
        #expect(execution.turnID > planSnapshot.turnID)
        #expect(execution.sessionID == planSnapshot.sessionID)
        #expect(execution.workspaceID == planSnapshot.workspaceID)
        #expect(execution.policyRevision == planSnapshot.policyRevision)
        #expect(execution.approvalScope == planSnapshot.approvalScope)
        #expect(provider.requests.count == 2)
        #expect(provider.requests.last?.last(where: { $0.role == .user })?.content == "我批准上述计划，请开始执行。")
        #expect(chat.messages.starts(with: original))
        #expect(chat.messages.contains { $0.id == proposal.id && $0.content == proposal.markdown })
        #expect(chat.activePlanApproval == nil)
    }

    @Test func planCeilingRejectsAutoEditAndContinuePreservesTheCompletedPlan() async throws {
        let (profile, chat, provider) = try makePlanFixture(ceiling: .l1)
        defer { chat.stopAllStreamingForSafety(); try? profile.cleanupDisposableRoots() }
        try await producePlan(chat)
        let proposal = try #require(chat.activePlanApproval)
        let history = chat.messages
        let admission = chat.lastComposerSubmissionSnapshot
        #expect(chat.planApprovalDisabledReason(for: .autoEdit) != nil)
        #expect(await chat.resolvePlanApproval(.approveAutoEdit, proposalID: proposal.id) == false)
        #expect(chat.activePlanApproval == proposal)
        #expect(chat.composerPolicySelection.mode == .plan)
        #expect(chat.messages == history && provider.requests.count == 1)
        chat.draftText = "继续细化验证步骤"
        #expect(await chat.resolvePlanApproval(.continuePlanning, proposalID: proposal.id))
        #expect(chat.composerPolicySelection.mode == .plan)
        #expect(chat.lastComposerSubmissionSnapshot == admission)
        #expect(chat.messages == history && provider.requests.count == 1)
        #expect(chat.draftText == "继续细化验证步骤")
        #expect(chat.activePlanApproval == nil)
    }

    @Test func outputPresetsReachTheNextActualRequestWithSoulAndUnchangedAuthority() async throws {
        let (profile, chat, provider) = try makePlanFixture(ceiling: .l2)
        defer { chat.stopAllStreamingForSafety(); try? profile.cleanupDisposableRoots() }
        let sessions = try #require(chat.sessionManager).store
        let skills = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        let souls = SoulStore(directory: profile.rootDirectory.appendingPathComponent("souls"))
        try souls.upsert(Soul(id: "group2-owned", name: "Synthetic style",
            systemPrompt: "GROUP2_SOUL_EXPRESSION_ONLY", isActive: true))
        let facts = chat.composerPolicyFacts
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: profile.rootDirectory),
            requestBudget: chat.budgetTracker,
            chatRuntimeDependencies: .init(sessionStore: sessions,
                memoryStore: MemoryStore(directory: profile.rootDirectory.appendingPathComponent("memory")),
                skillStore: skills, soulStore: souls), composerPolicyFacts: facts)
        chat.composerPolicySelection.mode = .manual
        let keychain = profile.makeKeychainStore()
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.rootDirectory.appendingPathComponent("settings")),
            envStore: profile.makeEnvironmentStore(keychain: keychain),
            memoryStore: MemoryStore(directory: profile.rootDirectory.appendingPathComponent("memory")),
            sessionStore: sessions, logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.rootDirectory.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: skills, usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain))
        center.bindChatOutputMode(to: chat)
        var prior: ComposerSubmissionSnapshot?
        for (index, mode) in ChatOutputMode.presets.enumerated() {
            chat.setOutputMode(mode)
            #expect(center.chatOutputMode == mode)
            chat.draftText = "合成风格请求 \(index)"
            let session = try #require(chat.activeSessionID)
            chat.submitComposer()
            let running = try #require(chat.turnTaskForTests(sessionID: session))
            await running.value
            #expect(provider.requests.count == index + 1)
            #expect(provider.toolSets.count == index + 1)
            let prompt = try #require(provider.prompts.last ?? nil)
            #expect(prompt.contains(try #require(mode.systemPromptInstruction)))
            #expect(prompt.contains("GROUP2_SOUL_EXPRESSION_ONLY"))
            let current = try #require(chat.lastComposerSubmissionSnapshot)
            #expect(current.mode == .manual)
            if let prior {
                #expect(current.approvalScope == prior.approvalScope)
                #expect(current.policyRevision == prior.policyRevision)
                #expect(current.workspaceID == prior.workspaceID)
                #expect(provider.toolSets.last == provider.toolSets.first)
            }
            prior = current
            #expect(SettingsStore(directory: profile.rootDirectory.appendingPathComponent("settings"))
                .settings.general.chatOutputMode == mode)
        }
    }

    @Test func productionBootstrapPreservesTheUserSessionAndDraftCreatedBeforeRecoveryAttach() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "g22-recovery10",
            processEnvironment: [:], processArguments: ["Goal22ShallowProductionPredicateGroup2Tests.xctest"],
            canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        var old = ChatThread(title: "旧恢复会话")
        old.messages = [ChatMessageUI(role: .user, content: "已落盘的旧正文")]
        try sessions.updateSession(old.asPersisted())
        let oldBytes = try #require(sessions.loadSession(id: old.id.uuidString))
        let bridge = try recoveryBridge(profile)
        defer { bridge.chat.stopAllStreamingForSafety() }
        #expect(!bridge.chat.isPersistenceReady)
        let welcome = bridge.chat.activeSessionID
        // The same public ChatStore entry called by the sidebar/menu. This
        // invokes BridgeStore's registered session action handler, not a state assignment.
        bridge.chat.newSession()
        let created = try #require(bridge.chat.activeSessionID)
        #expect(created != welcome && created != old.id)
        bridge.chat.appendUser("恢复装配前接受的新正文")
        let editor = ScrollableComposerTextView(
            text: Binding(get: { bridge.chat.draftText }, set: { bridge.chat.draftText = $0 }),
            font: .systemFont(ofSize: 13),
            onSend: { Issue.record("Recovery draft must remain unsent") }).makeCoordinator()
        let nativeInput = ComposerPasteAwareTextView(frame: .zero)
        nativeInput.string = "恢复装配前接受的新草稿"
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: nativeInput))
        #expect(bridge.chat.draftText == nativeInput.string)
        let newBefore = try #require(bridge.chat.messages(forSession: created))
        await attachRecoveryServices(bridge, profile: profile)
        #expect(bridge.chat.isPersistenceReady)
        #expect(bridge.chat.activeSessionID == created)
        #expect(bridge.chat.messages(forSession: created) == newBefore)
        #expect(bridge.chat.draftText == nativeInput.string)
        #expect(bridge.chat.messages(forSession: old.id)?.filter { $0.role == .user }.map(\.content)
            == ["已落盘的旧正文"])
        #expect(sessions.loadSession(id: old.id.uuidString)?.messages == oldBytes.messages)
        #expect(bridge.chat.flushPendingDraftForTermination())
        #expect(try #require(bridge.chat.draftStore).flushAll())
        let after = SessionStore(directory: profile.sessionDirectory)
        #expect(after.loadSession(id: created.uuidString)?.messages == newBefore.map { $0.asLLMMessage() })
        // Fresh production assembly consumes the reconciled durable source.
        // This is a cold object graph, not a claimed OS-process restart.
        let reopened = try recoveryBridge(profile)
        defer { reopened.chat.stopAllStreamingForSafety() }
        await attachRecoveryServices(reopened, profile: profile)
        reopened.chat.switchSession(id: created)
        #expect(reopened.chat.activeSessionID == created)
        #expect(reopened.chat.messages.map { $0.asLLMMessage() } == newBefore.map { $0.asLLMMessage() })
        #expect(reopened.chat.draftText == nativeInput.string)
        #expect(reopened.chat.messages(forSession: old.id)?.filter { $0.role == .user }.map(\.content)
            == ["已落盘的旧正文"])
    }

    private func recoveryBridge(_ profile: RuntimeIsolationProfile) throws -> BridgeStore {
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        return try BridgeStore(taskStorePersistenceURL: root.appendingPathComponent("recovery-tasks.json"),
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            canvasRuntimeState: .disabled,
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")),
            canvasFeatureLane: .phase3NonCanvas)
    }

    private func attachRecoveryServices(_ bridge: BridgeStore, profile: RuntimeIsolationProfile) async {
        let root = profile.rootDirectory
        let keychain = profile.makeKeychainStore()
        await bridge.attachProductionServices(fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: profile.sessionDirectory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false,
            sessionReadSecretStore: profile.makeEnvironmentStore(keychain: keychain)).value
    }

    private func producePlan(_ chat: ChatStore) async throws {
        chat.draftText = "请先制定计划，不执行修改"
        let session = try #require(chat.activeSessionID)
        chat.submitComposer()
        let task = try #require(chat.turnTaskForTests(sessionID: session))
        await task.value
        #expect(!chat.isActiveSessionGenerating)
        #expect(chat.messages.last(where: { $0.role == .assistant })?.content.hasPrefix("## 计划") == true)
    }

    private func makePlanFixture(ceiling: AutonomyLevel) throws
        -> (RuntimeIsolationProfile, ChatStore, G22Group2PlanProvider) {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "g22-shallow-group2",
            processEnvironment: [:], processArguments: ["Goal22ShallowProductionPredicateGroup2Tests.xctest"],
            canvasRuntimeState: .disabled)
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(SessionStore(directory: profile.sessionDirectory)))
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "g22-group2-plan", grantEpoch: "g22-group2",
            leaseID: "g22-group2", expiresAt: .distantFuture, autonomyCeiling: ceiling)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection.mode = .plan
        let skills = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:g22-group2")
            return .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: try! ProviderRuntimeRoute(snapshot: snapshot, primary: box),
                requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: profile.rootDirectory),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        let provider = G22Group2PlanProvider()
        chat.streamingProviderOverride = provider
        return (profile, chat, provider)
    }
}

private final class G22Group2PlanProvider: LLMProvider, @unchecked Sendable {
    let name = "g22-group2-offline"
    var model = LLMModel(id: "g22-group2", displayName: "Group 2 synthetic", provider: "g22-group2-offline")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    private var capturedPrompts: [String?] = []
    private var capturedTools: [Set<String>] = []
    var prompts: [String?] { lock.withLock { capturedPrompts } }
    var toolSets: [Set<String>] { lock.withLock { capturedTools } }
    var requests: [[LLMMessage]] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(messages); capturedPrompts.append(systemPrompt) }
        return LLMResponse(text: "## 计划\n1. 只读检查\n2. 获得批准后执行", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { capturedTools.append(Set(tools.map(\.name))) }
        return try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                                    maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}
