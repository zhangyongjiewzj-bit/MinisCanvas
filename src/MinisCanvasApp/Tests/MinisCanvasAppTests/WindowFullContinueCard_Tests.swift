import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// 用户 11/9：上下文占窗口 95% 被拦（contextWindowFull）与最终超窗失败
/// （contextLengthExceeded 重试后仍失败）都要点亮既有“新会话继续”卡，
/// 与旧的压缩失败路径同一入口（contextLimitReason / continueAfterContextLimit）。
/// 真实 ChatStore / AgentLoop；Provider 是外部边界。
@Suite("Window full lights the continue card", .serialized)
@MainActor
struct WindowFullContinueCard_Tests {
    typealias Fixture = OrdinaryAutoCompactionCancellation2669Tests.Fixture
    typealias Dialogue = OrdinaryAutoCompactionCancellation2669Tests.Dialogue

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func shortHistory() -> [LLMMessage] {
        (0..<8).map { index in
            LLMMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "short-\(index)")
        }
    }

    private func continueIntoNewSession(_ chat: ChatStore) async throws {
        let sourceID = try #require(chat.activeSessionID)
        let before = chat.sessions.count
        chat.continueAfterContextLimit()
        let draft = try #require(chat.sessionContinuationDraft)
        _ = await waitUntil { !draft.isGenerating }
        chat.confirmSessionContinuation()
        #expect(chat.sessionContinuationDraft == nil)
        #expect(chat.sessions.count == before + 1)
        #expect(chat.activeSessionID != sourceID)
    }

    @Test func blockedAtNinetyFivePercentLightsContinueCard() async throws {
        let short = shortHistory()
        let fixture = try Fixture(initialHistory: short)
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.recordWindowOccupancy(sessionID: fixture.sessionID, providerID: Dialogue.providerID,
            modelID: Dialogue.modelID, sentMessageCount: short.count, inputTokens: 124_000)  // 97%
        chat.compactionProviderOverride = dialogue
        chat.streamingProviderOverride = dialogue
        chat.draftText = "WINDOW_FULL_CARD_BLOCKED"
        chat.submitComposer()
        #expect(await waitUntil { !chat.hasStreamingTasksForSafety })
        #expect(chat.executionSnapshot(forSessionID: fixture.sessionID)?.state == .failed)
        #expect(chat.contextLimitReason != nil)
        #expect(chat.canContinueAfterContextLimit)
        chat.compactionProviderOverride = dialogue
        try await continueIntoNewSession(chat)
    }

    @Test func finalContextLengthExceededLightsContinueCard() async throws {
        let short = shortHistory()
        let fixture = try Fixture(initialHistory: short)
        let overflow = AlwaysOverflowProvider()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.compactionProviderOverride = Dialogue()
        chat.streamingProviderOverride = overflow
        chat.draftText = "WINDOW_FULL_CARD_OVERFLOW"
        chat.submitComposer()
        #expect(await waitUntil { !chat.hasStreamingTasksForSafety })
        #expect(chat.executionSnapshot(forSessionID: fixture.sessionID)?.state == .failed)
        #expect(overflow.sendCount >= 1)
        #expect(chat.contextLimitReason != nil)
        #expect(chat.canContinueAfterContextLimit)
        try await continueIntoNewSession(chat)
    }

    /// R3-Z1-02 / R3-Z3-01: a session that belongs to a project runs through
    /// ChatSessionRuntime, so the engine hands ChatStore a wrapped terminal
    /// error instead of the bare overflow. The card must still light.
    @Test func projectSessionFinalContextLengthExceededLightsContinueCard() async throws {
        let (center, _, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsDomain = "windowfull-project-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        try #require(chat.attachPersistence(center.sessionStore))
        chat.applyNewSession(title: "Window full project fixture",
            projectID: "windowfull-project", projectName: "Synthetic window project",
            workingDirectory: root.path)
        let sessionID = try #require(chat.activeSessionID)
        let overflow = AlwaysOverflowProvider()
        defer {
            chat.stopAllStreamingForSafety()
            withExtendedLifetime(center) {}
        }
        let settingsCapture = ChatContextSettingsCapture(
            sessionStore: center.sessionStore, sessionID: sessionID.uuidString, model: overflow.model)
        let providerSnapshot = try ProviderRuntimeSnapshot(
            providerID: overflow.model.provider, modelID: overflow.model.id,
            readinessEvidenceID: "live-settings:" + String(repeating: "b", count: 64),
            applyReceiptID: "provider-readiness-apply:windowfull-project")
        let route = try ProviderRuntimeRoute(snapshot: providerSnapshot, primary: overflow)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil,
                providerRuntimeRoute: route, requiresProviderRuntimeRoute: true,
                contextSettingsCapture: settingsCapture)
        }
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID,
            revision: "windowfull-project-policy", grantEpoch: "windowfull-project-epoch",
            leaseID: "windowfull-project-lease", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            requestBudget: chat.budgetTracker,
            chatRuntimeDependencies: .init(
                sessionStore: center.sessionStore,
                memoryStore: center.memoryStore,
                skillStore: skills,
                soulStore: SoulStore(directory: root.appendingPathComponent("soul"))),
            contextWritebackStorePersistenceURL: center.sessionStore.directory
                .appendingPathComponent("agent-turn-context-v1.json"),
            toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json")),
            composerPolicyFacts: facts)
        chat.streamingProviderOverride = overflow
        chat.compactionProviderOverride = Dialogue()
        chat.draftText = "WINDOW_FULL_CARD_PROJECT_OVERFLOW"
        chat.submitComposer()
        #expect(await waitUntil { !chat.hasStreamingTasksForSafety })
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .failed)
        #expect(overflow.sendCount >= 1)
        #expect(chat.contextLimitReason != nil)
        #expect(chat.canContinueAfterContextLimit)
        chat.continueAfterContextLimit()
        #expect(chat.sessionContinuationDraft != nil)
    }
}

/// External-boundary Provider whose every ordinary request is a context overflow.
private final class AlwaysOverflowProvider: AssistantStreamingLLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = OrdinaryAutoCompactionCancellation2669Tests.Dialogue.providerID
    var model = LLMModel(id: OrdinaryAutoCompactionCancellation2669Tests.Dialogue.modelID,
        displayName: "Always overflow", provider: OrdinaryAutoCompactionCancellation2669Tests.Dialogue.providerID)
    var runtimeConfigurationMaterial: String? = "owned-runtime2669"
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var count = 0
    var sendCount: Int { lock.withLock { count } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { count += 1 }
        throw LLMError.contextLengthExceeded
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { count += 1 }
        throw LLMError.contextLengthExceeded
    }
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        lock.withLock { count += 1 }
        throw LLMError.contextLengthExceeded
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}
