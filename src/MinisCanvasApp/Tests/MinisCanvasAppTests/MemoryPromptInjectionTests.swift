import Testing
import Foundation
import Darwin
import AppKit
import SwiftUI
import ApplicationServices
import MinisCore
@testable import MinisCanvasApp


/// Uses the existing production preprocessing barrier; no prompt is assembled here.
private final class MemoryPreparationGate3092: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isPaused: Bool { lock.withLock { continuation != nil } }
    func wait() async {
        await withCheckedContinuation { next in
            let resume = lock.withLock {
                if released { return true }
                continuation = next
                return false
            }
            if resume { next.resume() }
        }
    }
    func release() {
        let parked = lock.withLock {
            released = true
            let parked = continuation
            continuation = nil
            return parked
        }
        parked?.resume()
    }
}

/// Records actual AgentLoop requests and returns only a synthetic completion.
private final class MemoryRequestProvider3092: LLMProvider, @unchecked Sendable {
    let name = "memory3092-owned"
    var model = LLMModel(id: "memory3092-model", displayName: "Owned memory probe", provider: "memory3092-owned")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var captured: [String] = []
    private var streams = 0
    var prompts: [String] { lock.withLock { captured } }
    var streamCount: Int { lock.withLock { streams } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(systemPrompt ?? "") }
        return LLMResponse(text: "Owned memory completion", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { streams += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

private final class MemoryToolExecutor3092: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var executions = 0
    var count: Int { lock.withLock { executions } }
    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { executions += 1 }
        throw NSError(domain: "Memory3092.unexpectedTool", code: 1)
    }
}

// MARK: - M1 持久记忆生产提示注入
//
// ChatStore 生产提示集成：memoryEnabled 门禁开启且事实属于当前会话时，
// 把 MemoryInjector 片段注入发送回合的 systemPrompt；门禁关闭、跨会话
// 事实一律不注入（fail-closed）。

@Suite("M1 持久记忆生产提示注入")
@MainActor
struct MemoryPromptInjectionTests {

    private func makeTempDir() throws -> URL {
        let paths = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let url = paths.rootDirectory
            .appendingPathComponent("MemoryPromptInjection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private func makeInjector(dir: URL, facts: [(text: String, session: String)]) throws -> MemoryInjector {
        let store = MemoryStore(directory: dir)
        for fact in facts {
            try store.addFact(
                fact.text,
                sourceSessionID: fact.session,
                memoryScope: MemoryScope(sessionID: fact.session, projectID: "test-project")
            )
        }
        return MemoryInjector(store: store)
    }

    private func bindTestProject(_ bridge: BridgeStore, sessionID: UUID) {
        bridge.chat.setProject(
            .init(id: "test-project", name: "Test Project", workingDirectory: "/tmp"),
            forSession: sessionID
        )
    }

    private func sendAndWait(_ bridge: BridgeStore) async {
        bridge.chat.sendDraft()
        var waited: TimeInterval = 0
        while bridge.chat.isStreaming && waited < 10 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
    }

    @Test("启用 + 当前会话：注入匹配记忆片段")
    func enabledInjectsMatchingSessionFacts() async throws {
        let dir = try makeTempDir()

        let bridge = BridgeStore()
        let engine = U4SystemPromptRecordingEngine()
        bridge.chat.agentEngine = engine
        let sessionID = try #require(bridge.chat.activeSessionID)
        bindTestProject(bridge, sessionID: sessionID)
        bridge.chat.memoryEnabledProvider = { true }
        bridge.chat.memoryInjector = try makeInjector(
            dir: dir,
            facts: [("用户喜欢晴天，讨厌下雨天", sessionID.uuidString)]
        )

        bridge.chat.draftText = "今天天气是晴天吗？"
        await sendAndWait(bridge)

        let prompt = try #require(engine.systemPrompts.last)
        #expect(prompt.contains("用户喜欢晴天，讨厌下雨天"), "启用 + 当前会话事实应注入生产提示")
        #expect(prompt.contains("background context"))
    }

    @Test("关闭门禁：即使命中也不注入")
    func disabledSkipsInjection() async throws {
        let dir = try makeTempDir()

        let bridge = BridgeStore()
        let engine = U4SystemPromptRecordingEngine()
        bridge.chat.agentEngine = engine
        let sessionID = try #require(bridge.chat.activeSessionID)
        bindTestProject(bridge, sessionID: sessionID)
        bridge.chat.memoryEnabledProvider = { false }
        bridge.chat.memoryInjector = try makeInjector(
            dir: dir,
            facts: [("用户喜欢晴天，讨厌下雨天", sessionID.uuidString)]
        )

        bridge.chat.draftText = "今天天气是晴天吗？"
        await sendAndWait(bridge)

        let prompt = try #require(engine.systemPrompts.last)
        #expect(!prompt.contains("用户喜欢晴天，讨厌下雨天"), "关闭门禁时不注入任何记忆片段")
    }

    @Test("跨会话排除：他会话事实即使命中也不注入")
    func crossSessionFactsAreExcluded() async throws {
        let dir = try makeTempDir()

        let bridge = BridgeStore()
        let engine = U4SystemPromptRecordingEngine()
        bridge.chat.agentEngine = engine
        let sessionID = try #require(bridge.chat.activeSessionID)
        bindTestProject(bridge, sessionID: sessionID)
        bridge.chat.memoryEnabledProvider = { true }
        bridge.chat.memoryInjector = try makeInjector(
            dir: dir,
            facts: [("用户喜欢晴天，讨厌下雨天", "other-session-id")]
        )

        bridge.chat.draftText = "今天天气是晴天吗？"
        await sendAndWait(bridge)

        let prompt = try #require(engine.systemPrompts.last)
        #expect(!prompt.contains("用户喜欢晴天，讨厌下雨天"), "跨会话事实绝不注入")
    }

    @Test("MEMORY07 process UID source rejects missing reads and preserves the exact process UID")
    func processUIDBoundaryRejectsUnavailableAndCapturesExactUID3092() throws {
        #expect(ProcessUIDMemoryPrincipalSource(readUID: { nil }).trustedPrincipal() == nil)
        let supplied = ProcessUIDMemoryPrincipalSource(readUID: { 501 })
        #expect(supplied.trustedPrincipal()?.userID == "macos-uid:501")
        let actual = try #require(ProcessUIDMemoryPrincipalSource.production.trustedPrincipal())
        #expect(actual.userID == "macos-uid:\(getuid())")
    }

    @Test("MEMORY07 actual ordinary requests consume classified context captured before preparation")
    func classifiedContextReachesActualAgentLoopAndFreezesAdmission3092() async throws {
        let root = try makeTempDir()
        let suite = "memory3092-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let sessionID = UUID()
        let projectBSessionID = UUID()
        let unassignedSessionID = UUID()
        let scope = MemoryScope(sessionID: sessionID.uuidString, projectID: "owned-project-A")
        let otherSessionScope = MemoryScope(sessionID: UUID().uuidString, projectID: scope.projectID)
        let otherProjectScope = MemoryScope(
            sessionID: projectBSessionID.uuidString, projectID: "owned-project-B"
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: sessionID.uuidString, title: "owned classified consumer",
            projectID: scope.projectID, projectName: "Owned A", workingDirectory: root.path)
        _ = try sessions.createSession(id: projectBSessionID.uuidString,
            title: "owned Project B consumer", projectID: otherProjectScope.projectID,
            projectName: "Owned B", workingDirectory: root.path)
        _ = try sessions.createSession(id: unassignedSessionID.uuidString)
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let principalA = try #require(ProcessUIDMemoryPrincipalSource(readUID: { 501 }).trustedPrincipal())
        let principalB = try #require(ProcessUIDMemoryPrincipalSource(readUID: { 502 }).trustedPrincipal())
        let lifetimeA = MemoryTemporaryLifetime(id: "owned-explicit-lifetime-A")
        let lifetimeB = MemoryTemporaryLifetime(id: "owned-explicit-lifetime-B")
        _ = try memory.addFact("weather legacy-owned", sourceSessionID: scope.sessionID, memoryScope: scope)
        _ = try memory.addFact("weather legacy-other-session", sourceSessionID: otherSessionScope.sessionID,
            memoryScope: otherSessionScope)
        _ = try memory.addFact("weather project-shared", sourceSessionID: otherSessionScope.sessionID,
            memoryScope: otherSessionScope, visibility: .project)
        _ = try memory.addFact("weather project-other", sourceSessionID: otherProjectScope.sessionID,
            memoryScope: otherProjectScope, visibility: .project)
        let ownerFact = try memory.addFact("weather personal-A", memoryScope: scope, ownerUserID: principalA.userID,
            visibility: .personal, trustedPrincipal: principalA)
        _ = try memory.addFact("weather personal-B", memoryScope: scope, ownerUserID: principalB.userID,
            visibility: .personal, trustedPrincipal: principalB)
        _ = try memory.addFact("weather temporary-A", memoryScope: scope,
            visibility: .temporary, temporaryLifetimeID: lifetimeA.id)
        _ = try memory.addFact("weather temporary-B", memoryScope: scope,
            visibility: .temporary, temporaryLifetimeID: lifetimeB.id)
        _ = try memory.addFact("weather temporary-other-session", memoryScope: otherSessionScope,
            visibility: .temporary, temporaryLifetimeID: lifetimeA.id)
        let memoryBytes = try Data(contentsOf: memory.fileURL)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        try souls.upsert(Soul(id: "memory3092", name: "Owned soul",
            systemPrompt: "Synthetic expression only.", isActive: true))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        // Same canonical producer/dependencies as the original native 460 consumer.
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)), memoryStore: memory,
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: sessions, logManager: log,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: skills, usageStore: UsageStore(domain: .suite(suite)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness)
        let chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
        defer { chat.stopAllStreamingForSafety() }
        #expect(chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        #expect(chat.applySwitchSession(id: sessionID))
        #expect(chat.activeMemoryScope == scope)
        let policy = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "memory3092-policy", grantEpoch: "memory3092-epoch",
            leaseID: "memory3092-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(policy)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.configureBudget(from: settings.settingsStore.settings.agent)
        chat.effectiveSettingsSnapshotSource = { settings.bl6EffectiveSettingsSnapshot }
        let executor = MemoryToolExecutor3092()
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("tool-facts.json"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let engine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory,
                skillStore: skills, soulStore: souls),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger, composerPolicyFacts: policy)
        chat.agentEngine = engine.withRequestBudget(chat.budgetTracker)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let provider = MemoryRequestProvider3092()
        chat.streamingProviderOverride = provider
        chat.memoryEnabledProvider = { true }
        let memoryFiles = MemoryFileStore(directory: memory.directory)
        try memoryFiles.writeGlobal("S1_GLOBAL_OWNED")
        chat.memoryInjector = MemoryInjector(store: memory, fileStore: memoryFiles)
        var principal: MemoryTrustedPrincipal? = principalA
        var lifetime: MemoryTemporaryLifetime? = lifetimeA
        var principalReads = 0
        var lifetimeReads = 0
        chat.memoryTrustedPrincipalProvider = { principalReads += 1; return principal }
        chat.memoryTemporaryLifetimeProvider = { lifetimeReads += 1; return lifetime }
        let gate = MemoryPreparationGate3092()
        defer { gate.release() }
        chat.turnPromptPreprocessPauseForTests = { await gate.wait() }
        chat.draftText = "weather first request"
        chat.sendDraft()
        for _ in 0..<300 {
            if gate.isPaused { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(gate.isPaused)
        #expect(provider.prompts.isEmpty)
        #expect(principalReads == 1 && lifetimeReads == 1)
        principal = principalB
        lifetime = lifetimeB
        chat.turnPromptPreprocessPauseForTests = nil
        gate.release()
        for expectedCount in 1...3 {
            for _ in 0..<300 {
                if !chat.isStreaming && provider.prompts.count == expectedCount { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!chat.isStreaming)
            #expect(provider.prompts.count == expectedCount)
            let prompt = try #require(provider.prompts.last)
            #expect(prompt.contains("weather legacy-owned"))
            #expect(prompt.contains("weather project-shared"))
            #expect(!prompt.contains("weather legacy-other-session"))
            #expect(!prompt.contains("weather project-other"))
            #expect(!prompt.contains("weather temporary-other-session"))
            #expect(prompt.contains("weather personal-A") == (expectedCount == 1))
            #expect(prompt.contains("weather personal-B") == (expectedCount == 2))
            #expect(prompt.contains("weather temporary-A") == (expectedCount == 1))
            #expect(prompt.contains("weather temporary-B") == (expectedCount == 2))
            #expect(principalReads == expectedCount && lifetimeReads == expectedCount)
            #expect(try Data(contentsOf: memory.fileURL) == memoryBytes)
            #expect(executor.count == 0 && provider.streamCount == 0)
            if expectedCount < 3 {
                if expectedCount == 2 { principal = nil; lifetime = nil }
                chat.draftText = "weather next request \(expectedCount)"
                chat.sendDraft()
            }
        }
        let persisted = try #require(sessions.loadSession(id: sessionID.uuidString))
        #expect(persisted.messages.filter { $0.role == .user }.count == 3)
        #expect(persisted.messages.filter { $0.role == .assistant }.count == 3)

        // Exercise the actual session switch and next ordinary requests. A
        // verified Personal owner remains visible across projects; Project-A,
        // legacy exact-scope and Temporary-A never cross into Project-B.
        #expect(chat.applySwitchSession(id: projectBSessionID))
        #expect(chat.activeMemoryScope == otherProjectScope)
        principal = principalA
        lifetime = lifetimeA
        chat.draftText = "weather Project B same owner"
        chat.sendDraft()
        for _ in 0..<300 {
            if !chat.isStreaming && provider.prompts.count == 4 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        #expect(provider.prompts.count == 4)
        let sameOwnerProjectBPrompt = try #require(provider.prompts.last)
        #expect(sameOwnerProjectBPrompt.contains("weather project-other"))
        #expect(sameOwnerProjectBPrompt.contains("weather personal-A"))
        #expect(!sameOwnerProjectBPrompt.contains("weather personal-B"))
        #expect(!sameOwnerProjectBPrompt.contains("weather project-shared"))
        #expect(!sameOwnerProjectBPrompt.contains("weather legacy-owned"))
        #expect(!sameOwnerProjectBPrompt.contains("weather temporary-A"))
        #expect(!sameOwnerProjectBPrompt.contains("weather temporary-B"))
        #expect(!sameOwnerProjectBPrompt.contains("weather temporary-other-session"))

        principal = principalB
        chat.draftText = "weather Project B different owner"
        chat.sendDraft()
        for _ in 0..<300 {
            if !chat.isStreaming && provider.prompts.count == 5 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        #expect(provider.prompts.count == 5)
        let differentOwnerProjectBPrompt = try #require(provider.prompts.last)
        #expect(differentOwnerProjectBPrompt.contains("weather project-other"))
        #expect(differentOwnerProjectBPrompt.contains("weather personal-B"))
        #expect(!differentOwnerProjectBPrompt.contains("weather personal-A"))
        #expect(!differentOwnerProjectBPrompt.contains("weather project-shared"))
        #expect(!differentOwnerProjectBPrompt.contains("weather legacy-owned"))
        #expect(!differentOwnerProjectBPrompt.contains("weather temporary-A"))
        #expect(!differentOwnerProjectBPrompt.contains("weather temporary-B"))
        #expect(principalReads == 5 && lifetimeReads == 5)
        let persistedProjectB = try #require(sessions.loadSession(id: projectBSessionID.uuidString))
        #expect(persistedProjectB.messages.filter { $0.role == .user }.count == 2)
        #expect(persistedProjectB.messages.filter { $0.role == .assistant }.count == 2)
        try #require(chat.applySwitchSession(id: unassignedSessionID))
        try #require(chat.activeMemoryScope == nil)
        principal = principalA
        let unassignedGate = MemoryPreparationGate3092()
        defer { unassignedGate.release() }
        chat.turnPromptPreprocessPauseForTests = { await unassignedGate.wait() }
        chat.draftText = "weather unassigned request"
        chat.sendDraft()
        for _ in 0..<300 {
            if unassignedGate.isPaused { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(unassignedGate.isPaused)
        #expect(provider.prompts.count == 5)
        #expect(principalReads == 6 && lifetimeReads == 5)
        principal = principalB
        chat.turnPromptPreprocessPauseForTests = nil
        unassignedGate.release()
        for _ in 0..<300 {
            if !chat.isStreaming && provider.prompts.count == 6 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming && provider.prompts.count == 6)
        let unassignedPrompt = try #require(provider.prompts.last)
        #expect(unassignedPrompt.contains("S1_GLOBAL_OWNED"))
        #expect(unassignedPrompt.contains("weather personal-A"))
        for excluded in ["personal-B", "project-shared", "project-other", "legacy-owned", "temporary-"] {
            #expect(!unassignedPrompt.contains(excluded))
        }
        #expect(chat.lastInjectedMemoryFactIDs == [ownerFact.id])
        #expect(principalReads == 6 && lifetimeReads == 5)
        #expect(executor.count == 0 && provider.streamCount == 0)
        #expect(try MemoryStore(directory: memory.directory).facts().count == 9)
        #expect(try Data(contentsOf: memory.fileURL) == memoryBytes)
        // Capture a known synthetic secret in the existing in-memory credential fixture.
        // The cut at 100 would preserve only its prefix if display clipping happened first.
        try #require(chat.applySwitchSession(id: sessionID))
        let expectedCount = provider.prompts.count + 1
        chat.credentialBroker.attach(center: settings, externalNetworkAllowed: false)
        let syntheticSecret = "violet orchard fixture"
        let secretPrefix = "violet"
        let factPrefix = "weather " + String(repeating: "a", count: 83) + " "
        let summaryFact = try memory.addFact(factPrefix + syntheticSecret,
            sourceSessionID: otherSessionScope.sessionID, memoryScope: otherSessionScope, visibility: .project)
        let patternedFixture = "sk-test" + String(repeating: "x", count: 32)
        let patternedFact = try memory.addFact("weather pattern check " + patternedFixture,
            sourceSessionID: otherSessionScope.sessionID, memoryScope: otherSessionScope, visibility: .project)
        let stored = settings.envStore.setEnvVar(name: "MEMORY_DISPLAY_FIXTURE", value: syntheticSecret, isSecret: true)
        try #require(stored)
        try #require(chat.credentialBroker.protect(syntheticSecret) != syntheticSecret)
        chat.draftText = "weather redaction preview"
        chat.sendDraft()
        for _ in 0..<300 {
            if !chat.isStreaming && provider.prompts.count == expectedCount { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming && provider.prompts.count == expectedCount)
        let marker = "…" + String(summaryFact.id.suffix(8))
        let label = try #require(chat.lastInjectedMemoryFactLabels.first { $0.contains(marker) })
        #expect(label.hasPrefix(factPrefix))
        #expect(!label.contains(secretPrefix))
        let patternedLabel = try #require(chat.lastInjectedMemoryFactLabels.first { $0.contains("…" + String(patternedFact.id.suffix(8))) })
        #expect(!patternedLabel.contains(patternedFixture))
        chat.setProject(.init(id: otherProjectScope.projectID, name: "Owned B", workingDirectory: root.path),
                        forSession: sessionID)
        #expect(chat.activeSessionID == sessionID)
        #expect(chat.activeMemoryScope?.projectID == otherProjectScope.projectID)
        #expect(!chat.lastInjectedMemoryFactLabels.contains { $0.hasPrefix(factPrefix) })
        chat.setProject(.init(id: scope.projectID, name: "Owned A", workingDirectory: root.path),
                        forSession: sessionID)
    }

    @Test("G22 memory recall joins Chinese search IDs to the actual ordinary request and scope")
    func chineseRecallDisplayAndActualPromptShareScopedFactIdentity() async throws {
        let root = try makeTempDir()
        let suite = "g22-memory-recall-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let a = UUID(), b = UUID()
        let scopeA = MemoryScope(sessionID: a.uuidString, projectID: "g22-owned-A")
        let scopeB = MemoryScope(sessionID: b.uuidString, projectID: "g22-owned-B")
        for (id, scope) in [(a, scopeA), (b, scopeB)] {
            _ = try sessions.createSession(id: id.uuidString, title: "owned memory recall",
                projectID: scope.projectID, projectName: scope.projectID, workingDirectory: root.path)
        }
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let usage = UsageStore(domain: .suite(suite))
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: memory, memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: sessions, logManager: log,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: skills, usageStore: usage, shortcutStore: ShortcutStore(defaults: defaults),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        let chat = ChatStore(preferencesDefaults: defaults, logManager: log)
        settings.memoryScopeProvider = { [weak chat] in chat?.activeMemoryScope }
        try #require(chat.attachPersistence(sessions,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        // Create valid input facts through the existing real proposal and user-approval consumers.
        // The production API generates the provenance triple and lifecycle receipts.
        try #require(chat.applySwitchSession(id: a))
        _ = try settings.provisionBuiltInMemoryCandidateSubmissions()
        let source = SettingsCenter.BuiltInMemoryCandidateSource.composerCommand
        let origin = MemoryWriteProvenanceInput(actorID: "g22-owned-fixture-user",
            runID: "g22-owned-recall-setup", triggerID: "g22-owned-fixture-input", sourceID: source.rawValue)
        let proposedA = try settings.memoryProposalConsumer.submit(
            text: "晴天 A_SCOPED " + String(repeating: "owned context ", count: 40)
                + " MEMORY_TAIL_MUST_NOT_FIT", within: scopeA,
            sourceRef: "synthetic://g22-recall/A", sourceID: source.rawValue, writeProvenance: origin)
        try settings.approveDisplayedMemoryProposal(proposedA)
        let approvedA = try memory.facts()
        let factA = try #require(approvedA.first { $0.sourceProposalID == proposedA.proposal.proposalID })
        try #require(chat.applySwitchSession(id: b))
        let proposedB = try settings.memoryProposalConsumer.submit(text: "晴天 B_ORIGINAL",
            within: scopeB, sourceRef: "synthetic://g22-recall/B",
            sourceID: source.rawValue, writeProvenance: origin)
        try settings.approveDisplayedMemoryProposal(proposedB)
        let approvedB = try memory.facts()
        let priorB = try #require(approvedB.first { $0.sourceProposalID == proposedB.proposal.proposalID })
        let revisionB = try settings.memoryProposalConsumer.submit(text: "晴天 B_SCOPED",
            within: scopeB, sourceRef: "synthetic://g22-recall/B",
            sourceID: source.rawValue, writeProvenance: origin)
        _ = try settings.memoryProposalConsumer.approveRevision(
            proposalID: revisionB.proposal.proposalID, supersedingFactID: priorB.id, within: scopeB,
            reason: "Owned fixture user approved this revision", generation: revisionB.generation,
            sourceHash: revisionB.sourceHash)
        let revised = try memory.facts()
        let factB = try #require(revised.first { $0.sourceProposalID == revisionB.proposal.proposalID })
        #expect(factA.revision == 1 && factB.revision == 2)
        let originalBytes = try Data(contentsOf: memory.fileURL)
        let policy = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID, revision: "g22-recall-policy",
            grantEpoch: "g22-recall-epoch", leaseID: "g22-recall-lease", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(policy)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.configureBudget(from: settings.settingsStore.settings.agent)
        chat.effectiveSettingsSnapshotSource = { settings.bl6EffectiveSettingsSnapshot }
        let executor = MemoryToolExecutor3092()
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("tool-facts.json"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory,
                skillStore: skills, soulStore: souls),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger, composerPolicyFacts: policy).withRequestBudget(chat.budgetTracker)
        chat.turnRuntimeSnapshotFactory = { turn, provider in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil,
                contextSettingsCapture: ChatContextSettingsCapture(sessionStore: sessions,
                    sessionID: turn.sessionID, model: provider.model))
        }
        let provider = MemoryRequestProvider3092()
        chat.streamingProviderOverride = provider
        chat.memoryEnabledProvider = { true }
        chat.memoryInjector = MemoryInjector(store: memory, maxFacts: 1, maxFactLength: 80,
            maxTotalCharacters: 512)
        let outcome: Result<Void, Error>
        do {
            for (ordinal, id, scope, fact, included, excluded) in [
                (1, a, scopeA, factA, "A_SCOPED", "B_SCOPED"),
                (2, b, scopeB, factB, "B_SCOPED", "A_SCOPED")
            ] {
                try #require(chat.applySwitchSession(id: id))
                #expect(chat.activeMemoryScope == scope)
                let displayed = try MemorySearchDisplayConsumer(search: MemorySearch(store: memory))
                    .retrieve(keyword: "晴天", scope: .session(scope))
                #expect(displayed.items.map(\.factID) == [fact.id])
                #expect(displayed.items.first?.revision == fact.revision)
                #expect(displayed.items.first?.sourceRef == fact.sourceRef)
                #expect(displayed.items.first?.matchedTerms == ["晴天"])
                chat.draftText = "晴天"
                chat.submitComposer()
                for _ in 0..<300 {
                    if !chat.isStreaming && !chat.isActiveSessionGenerating && provider.prompts.count == ordinal { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(!chat.isStreaming && !chat.isActiveSessionGenerating)
                try #require(provider.prompts.count == ordinal)
                let actualPrompt = try #require(provider.prompts.last)
                #expect(actualPrompt.contains(included))
                #expect(!actualPrompt.contains(excluded))
                #expect(!actualPrompt.contains("MEMORY_TAIL_MUST_NOT_FIT"))
                #expect(!actualPrompt.contains("B_ORIGINAL"))
                #expect(chat.lastInjectedMemoryFactIDs == [fact.id])
                #expect(chat.lastInjectedMemoryFactIDs == displayed.items.map(\.factID))
                #expect(chat.memoryInjectionLimitCharacters == 512)
                #expect(chat.memoryInjectionStatusText == "本轮使用的记忆")
                #expect(chat.messages.last(where: { $0.role == .assistant })?.content == "Owned memory completion")
                #expect(executor.count == 0 && ledger.facts.isEmpty)
                #expect(try Data(contentsOf: memory.fileURL) == originalBytes)
            }
            outcome = .success(())
        } catch { outcome = .failure(error) }
        let workers = chat.cancelStreamingForApplicationExit()
        for worker in workers { await worker.value }
        try #require(await usage.waitForPersistence())
        try FileManager.default.removeItem(at: root)
        try outcome.get()
    }

    @Test func globalInstructionsAreIndependentAndKeepUserTextWithin1200Characters() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(directory: root)
        let files = MemoryFileStore(directory: root)
        let injector = MemoryInjector(store: store, maxTotalCharacters: 0, fileStore: files)
        func prepare(memoryEnabled: Bool) throws -> ChatTurnPromptPreprocessResult {
            let input = ChatTurnPromptPreprocessInput(basePrompt: "base", userMessage: "ordinary request",
                memoryEnabled: memoryEnabled, memoryInjector: injector, memoryScope: nil, skillInjector: nil,
                legacySkillResult: .init(fragment: nil, receipts: []), pickerCatalog: [], steers: [],
                intentText: "ordinary request")
            return try #require(ChatTurnPromptPreprocessor.prepare(input))
        }

        let defaultPrompt = try prepare(memoryEnabled: false)
        #expect(defaultPrompt.systemPrompt.contains("最小改动"))
        #expect(defaultPrompt.memoryFactIDs.isEmpty)
        #expect(files.readGlobal().isEmpty)

        let exact = String(repeating: "甲", count: MemoryInjector.maxGlobalInstructionCharacters - 1) + "乙"
        let overLimit = exact + "丙"
        try files.writeGlobal(overLimit)
        for memoryEnabled in [false, true] {
            let current = try prepare(memoryEnabled: memoryEnabled)
            #expect(current.systemPrompt.contains(exact))
            #expect(!current.systemPrompt.contains(overLimit))
            #expect(!current.systemPrompt.contains("最小改动"))
            #expect(current.memoryFactIDs.isEmpty)
        }
        #expect(files.readGlobal() == overLimit)
    }

    @Test func unassignedPromptReadsGlobalWithoutAdoptingAProject() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(directory: root)
        let files = MemoryFileStore(directory: root)
        try files.writeGlobal("weather GLOBAL_S1")
        let scope = MemoryScope(sessionID: "owned-session", projectID: "owned-project")
        let foreign = MemoryScope(sessionID: "foreign-session", projectID: "foreign-project")
        let principal = try #require(ProcessUIDMemoryPrincipalSource(readUID: { 501 }).trustedPrincipal())
        let otherPrincipal = try #require(ProcessUIDMemoryPrincipalSource(readUID: { 502 }).trustedPrincipal())
        let lifetime = MemoryTemporaryLifetime(id: "owned-synthetic-lifetime")
        let local = try store.addFact("weather PROJECT_S1", memoryScope: scope, visibility: .project)
        let personal = try store.addFact("weather PERSONAL_S1", memoryScope: scope, ownerUserID: principal.userID,
                                         visibility: .personal, trustedPrincipal: principal)
        _ = try store.addFact("weather FOREIGN_S1", memoryScope: foreign, visibility: .project)
        _ = try store.addFact("weather OTHER_OWNER_S1", memoryScope: scope, ownerUserID: otherPrincipal.userID,
                              visibility: .personal, trustedPrincipal: otherPrincipal)
        _ = try store.addFact("weather TEMPORARY_S1", memoryScope: scope,
                              visibility: .temporary, temporaryLifetimeID: lifetime.id)
        let injector = MemoryInjector(store: store, fileStore: files)

        func prepare(scope: MemoryScope?, context: MemoryInjectionContext? = nil,
                     principal: MemoryTrustedPrincipal? = nil) throws -> ChatTurnPromptPreprocessResult {
            let input = ChatTurnPromptPreprocessInput(basePrompt: "base", userMessage: "weather",
                memoryEnabled: true, memoryInjector: injector, memoryScope: scope, skillInjector: nil,
                legacySkillResult: .init(fragment: nil, receipts: []), pickerCatalog: [], steers: [],
                memoryContext: context, intentText: "weather", trustedMemoryPrincipal: principal)
            return try #require(ChatTurnPromptPreprocessor.prepare(input))
        }

        let unassigned = try prepare(scope: nil)
        #expect(unassigned.systemPrompt.contains("GLOBAL_S1"))
        #expect(unassigned.memoryFactIDs.isEmpty)
        for marker in ["PROJECT_S1", "PERSONAL_S1", "FOREIGN_S1", "OTHER_OWNER_S1", "TEMPORARY_S1"] {
            #expect(!unassigned.systemPrompt.contains(marker))
        }
        let unassignedWithOwner = try prepare(scope: nil, principal: principal)
        #expect(unassignedWithOwner.systemPrompt.contains("GLOBAL_S1"))
        #expect(unassignedWithOwner.systemPrompt.contains("PERSONAL_S1"))
        #expect(unassignedWithOwner.memoryFactIDs == [personal.id])
        for marker in ["PROJECT_S1", "FOREIGN_S1", "OTHER_OWNER_S1", "TEMPORARY_S1"] {
            #expect(!unassignedWithOwner.systemPrompt.contains(marker))
        }

        let project = try prepare(scope: scope, context: MemoryInjectionContext(scope: scope, trustedPrincipal: principal))
        #expect(project.systemPrompt.contains("GLOBAL_S1"))
        #expect(Set(project.memoryFactIDs) == Set([local.id, personal.id]))
        for marker in ["FOREIGN_S1", "OTHER_OWNER_S1", "TEMPORARY_S1"] {
            #expect(!project.systemPrompt.contains(marker))
        }
    }

    @Test("MEMORY07 optional scoped prompt read preserves the original corrupt-file behavior")
    func corruptClassifiedRecallRemainsOptionalWhileStrictInjectionThrows3092() throws {
        let root = try makeTempDir()
        let scope = MemoryScope(sessionID: "owned-session", projectID: "owned-project")
        let store = MemoryStore(directory: root)
        _ = try store.addFact("weather owned fact", memoryScope: scope)
        let corrupt = Data("{owned malformed facts".utf8)
        try corrupt.write(to: store.fileURL, options: .atomic)
        let injector = MemoryInjector(store: store)
        let context = MemoryInjectionContext(scope: scope)
        #expect(throws: (any Error).self) {
            try injector.injection(base: "base", userMessage: "weather", context: context)
        }
        #expect(try injector.systemPrompt(base: "base", userMessage: "weather", memoryScope: scope) == "base")
        #expect(try ChatTurnPromptPreprocessor.preparePinnedPrompt(
            basePrompt: "base", userMessage: "weather", memoryInjector: injector,
            memoryScope: scope, skillInjector: nil, memoryContext: context) == "base")
        let input = ChatTurnPromptPreprocessInput(basePrompt: "base", userMessage: "weather",
            memoryEnabled: true, memoryInjector: injector, memoryScope: scope,
            skillInjector: nil, legacySkillResult: .init(fragment: nil, receipts: []),
            pickerCatalog: [], steers: [], memoryContext: context, intentText: "weather")
        let prepared = try #require(ChatTurnPromptPreprocessor.prepare(input))
        #expect(prepared.systemPrompt == "base")
        #expect(try Data(contentsOf: store.fileURL) == corrupt)
    }

    @Test("O09 corrupt optional facts warn through the real memory toolbar while the ordinary turn continues")
    func corruptOrdinaryMemoryReadWarnsWithoutChangingFallbackOrControls() async throws {
        var visibleStatus: [String: String] = [:]
        for scenario in ["empty", "corrupt", "off", "foreign"] {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "o09-warning-" + root.lastPathComponent
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let a = UUID(), b = UUID()
            let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
            for id in [a, b] {
                _ = try sessions.createSession(id: id.uuidString, title: "owned O09 read",
                    projectID: "owned-O09", projectName: "Owned O09", workingDirectory: root.path)
            }
            let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
            let corrupt = Data("{owned O09 malformed facts".utf8)
            if scenario == "corrupt" || scenario == "off" {
                _ = try memory.addFact("O09_BAD_FACT_MUST_NOT_ENTER", sourceSessionID: a.uuidString,
                    memoryScope: MemoryScope(sessionID: a.uuidString, projectID: "owned-O09"))
                try corrupt.write(to: memory.fileURL, options: .atomic)
            } else if scenario == "foreign" {
                _ = try memory.addFact("O09_FOREIGN_FACT_MUST_NOT_ENTER", sourceSessionID: b.uuidString,
                    memoryScope: MemoryScope(sessionID: b.uuidString, projectID: "owned-O09"))
            } else { #expect(try memory.facts().isEmpty) }
            let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
            let souls = SoulStore(directory: root.appendingPathComponent("souls"))
            let log = LogManager(directory: root.appendingPathComponent("logs"))
            let usage = UsageStore(domain: .suite(suite))
            let keychain = KeychainStore(backing: InMemoryKeychainBacking())
            let settings = SettingsCenter(
                settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                    privacyStore: EnvVarPrivacyStore(defaults: defaults)), memoryStore: memory,
                memoryFileStore: MemoryFileStore(directory: memory.directory), sessionStore: sessions, logManager: log,
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
                skillStore: skills, usageStore: usage,
                providerReadinessTransport: FailClosedProviderReadinessTransport(), providerReadinessDeployment: .mock,
                providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
            let chat = ChatStore(preferencesDefaults: defaults, logManager: log)
            defer { chat.stopAllStreamingForSafety() }
            try #require(chat.attachPersistence(sessions))
            try #require(chat.applySwitchSession(id: a))
            let policy = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
                workspaceID: chat.composerWorkspaceID, revision: "o09-policy", grantEpoch: "o09-epoch",
                leaseID: "o09-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
            chat.configureComposerPolicy(policy)
            chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
            chat.configureBudget(from: settings.settingsStore.settings.agent)
            chat.effectiveSettingsSnapshotSource = { settings.bl6EffectiveSettingsSnapshot }
            let executor = MemoryToolExecutor3092()
            let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("tool-facts.json"))
            chat.agentEngine = AgentLoopChatEngine(toolExecutor: executor,
                taskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
                chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory, skillStore: skills, soulStore: souls),
                contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
                toolExecutionFactLedger: ledger, composerPolicyFacts: policy).withRequestBudget(chat.budgetTracker)
            chat.turnRuntimeSnapshotFactory = { turn, provider in
                .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil,
                    contextSettingsCapture: ChatContextSettingsCapture(sessionStore: sessions, sessionID: turn.sessionID, model: provider.model))
            }
            let provider = MemoryRequestProvider3092()
            chat.streamingProviderOverride = provider
            chat.memoryEnabledProvider = { scenario != "off" }
            chat.memoryInjector = MemoryInjector(store: memory)
            let base = ChatStore.systemPrompt(for: chat.outputMode)
            let outcome: Result<Void, Error>
            do {
                chat.draftText = "owned O09 facts query"
                chat.submitComposer()
                for _ in 0..<300 {
                    if !chat.isStreaming && !chat.isActiveSessionGenerating && provider.prompts.count == 1 { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(!chat.isStreaming && !chat.isActiveSessionGenerating && provider.prompts.count == 1)
                let prompt = try #require(provider.prompts.first)
                #expect(prompt.contains(base))
                #expect(!prompt.contains("O09_BAD_FACT_MUST_NOT_ENTER") && !prompt.contains("O09_FOREIGN_FACT_MUST_NOT_ENTER"))
                #expect(chat.messages.last(where: { $0.role == .assistant })?.content == "Owned memory completion")
                #expect(executor.count == 0 && ledger.facts.isEmpty && provider.streamCount == 0)
                #expect(chat.lastInjectedMemoryFactIDs.isEmpty)
                if scenario == "corrupt" || scenario == "off" { #expect(try Data(contentsOf: memory.fileURL) == corrupt) }
                let lease = NativeTestHostLifecycle.begin("O09MemoryWarning")
                let host = NSHostingView(rootView: ComposerMemoryToolbarButton(chat: chat))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.setAccessibilityIdentifier("o09-memory-warning-" + lease.uuidString)
                NativeTestHostLifecycle.bind(lease, to: window)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                defer {
                    window.orderOut(nil); window.contentView = nil; window.close()
                    NativeTestHostLifecycle.end(window)
                }
                var toolbar: AnyObject?
                for _ in 0..<300 {
                    toolbar = NativeConsumerOwnedAX.find(in: window, identifier: "composer.injected-memory.toolbar")
                    if toolbar != nil { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let actualToolbar = try #require(toolbar)
                let valueCandidate = NativeConsumerOwnedAX.attribute(actualToolbar, kAXValueAttribute as CFString) as? String
                let value = try #require(valueCandidate)
                #expect(value == chat.memoryInjectionStatusText)
                visibleStatus[scenario] = value
                if scenario != "corrupt" { #expect(value == "本轮未注入持久记忆") }
                outcome = .success(())
            } catch { outcome = .failure(error) }
            let workers = chat.cancelStreamingForApplicationExit()
            for worker in workers { await worker.value }
            try #require(await usage.waitForPersistence())
            try FileManager.default.removeItem(at: root)
            try outcome.get()
        }
        let warning = try #require(visibleStatus["corrupt"])
        for control in ["empty", "off", "foreign"] { #expect(warning != visibleStatus[control]) }
        // O09:402–413 requires a readable load-failure warning, not a new API
        // or a hard-coded future sentence. The ordinary no-memory status is insufficient.
        #expect(warning.contains("记忆"))
        #expect(["读取失败", "读取异常", "无法读取"].contains { warning.contains($0) })
    }


    @Test("O09 GLOBAL editor saves reach the next ordinary Provider snapshot without escaping its root")
    func globalDocumentEditsReachNextActualPromptAndKeepPriorSnapshot() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "o09-global-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessionID = UUID()
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: sessionID.uuidString, title: "owned GLOBAL consumer",
            projectID: "owned-O09", projectName: "Owned O09", workingDirectory: root.path)
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let files = MemoryFileStore(directory: memory.directory)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let usage = UsageStore(domain: .suite(suite))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)), memoryStore: memory, memoryFileStore: files,
            sessionStore: sessions, logManager: log,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: skills, usageStore: usage,
            providerReadinessTransport: FailClosedProviderReadinessTransport(), providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        let v1 = "O09_GLOBAL_V1_owned_standing_instruction"
        let v2 = "O09_GLOBAL_V2_owned_standing_instruction"
        #expect(settings.saveMemoryDocumentResult(named: "GLOBAL.md", content: v1) == .saved)
        let chat = ChatStore(preferencesDefaults: defaults, logManager: log)
        defer { chat.stopAllStreamingForSafety() }
        try #require(chat.attachPersistence(sessions))
        try #require(chat.applySwitchSession(id: sessionID))
        let policy = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "o09-policy", grantEpoch: "o09-epoch",
            leaseID: "o09-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(policy)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        chat.configureBudget(from: settings.settingsStore.settings.agent)
        chat.effectiveSettingsSnapshotSource = { settings.bl6EffectiveSettingsSnapshot }
        let executor = MemoryToolExecutor3092()
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("tool-facts.json"))
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: executor,
            taskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory, skillStore: skills, soulStore: souls),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger, composerPolicyFacts: policy).withRequestBudget(chat.budgetTracker)
        chat.turnRuntimeSnapshotFactory = { turn, provider in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil,
                contextSettingsCapture: ChatContextSettingsCapture(sessionStore: sessions, sessionID: turn.sessionID, model: provider.model))
        }
        let provider = MemoryRequestProvider3092()
        chat.streamingProviderOverride = provider
        var enabled = true
        chat.memoryEnabledProvider = { enabled }
        // 2026-11-15 提示词方案 v2：全局指令有自己的开关，不再跟随记忆开关。
        var globalEnabled = true
        chat.globalInstructionsEnabledProvider = { globalEnabled }
        // Same explicit configured file-store dependency as the production root.
        // Legacy facts-only injectors do not acquire file reads implicitly.
        chat.memoryInjector = MemoryInjector(store: settings.memoryStore, fileStore: settings.memoryFileStore)
        let base = ChatStore.systemPrompt(for: chat.outputMode)
        let outside = root.appendingPathComponent("outside-GLOBAL.txt")
        let outsideText = "O09_OUTSIDE_SYMLINK_MUST_NOT_ENTER"
        var firstPrompt = ""
        let outcome: Result<Void, Error>
        do {
            for ordinal in 1...4 {
                if ordinal == 2 {
                    #expect(settings.saveMemoryDocumentResult(named: "GLOBAL.md", content: v2) == .saved)
                    #expect(provider.prompts.first == firstPrompt)
                } else if ordinal == 3 { enabled = false; globalEnabled = false }
                else if ordinal == 4 {
                    enabled = true; globalEnabled = true
                    try outsideText.write(to: outside, atomically: true, encoding: .utf8)
                    try FileManager.default.removeItem(at: files.globalURL)
                    try FileManager.default.createSymbolicLink(at: files.globalURL, withDestinationURL: outside)
                    #expect(settings.readMemoryDocument(named: "GLOBAL.md") == nil)
                    #expect(settings.saveMemoryDocumentResult(named: "GLOBAL.md", content: "must-not-overwrite-external") == .saveInvalidTarget)
                    #expect(try String(contentsOf: outside, encoding: .utf8) == outsideText)
                }
                chat.draftText = "owned GLOBAL request \(ordinal)"
                chat.submitComposer()
                for _ in 0..<300 {
                    if !chat.isStreaming && !chat.isActiveSessionGenerating && provider.prompts.count == ordinal { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(!chat.isStreaming && !chat.isActiveSessionGenerating && provider.prompts.count == ordinal)
                let prompt = try #require(provider.prompts.last)
                #expect(prompt.contains(base))
                #expect(chat.messages.last(where: { $0.role == .assistant })?.content == "Owned memory completion")
                #expect(!prompt.contains(outsideText))
                if ordinal == 1 {
                    firstPrompt = prompt
                    #expect(prompt.contains(v1) && !prompt.contains(v2))
                } else if ordinal == 2 {
                    #expect(prompt.contains(v2) && !prompt.contains(v1))
                    #expect(provider.prompts.first == firstPrompt)
                } else if ordinal == 3 { #expect(!prompt.contains(v1) && !prompt.contains(v2)) }
                if ordinal < 4 { #expect(settings.readMemoryDocument(named: "GLOBAL.md") == (ordinal == 1 ? v1 : v2)) }
                #expect(executor.count == 0 && ledger.facts.isEmpty && provider.streamCount == 0)
            }
            #expect(try String(contentsOf: outside, encoding: .utf8) == outsideText)
            #expect(provider.prompts.first == firstPrompt)
            outcome = .success(())
        } catch { outcome = .failure(error) }
        let workers = chat.cancelStreamingForApplicationExit()
        for worker in workers { await worker.value }
        try #require(await usage.waitForPersistence())
        try FileManager.default.removeItem(at: root)
        try outcome.get()
    }

}

// 2026-11-15 第七版（用户同意）：内置技能默认启用，每个内置库版本只自动安装一次，
// 用户删除或关闭后不会被自动装回。
@Suite("Builtin skill auto install")
@MainActor
struct BuiltinSkillAutoInstallTests {
    private func fixture() throws -> (root: URL, owner: SkillStore, store: SkillsStore, defaults: UserDefaults) {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("builtin-skill-install-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = SkillStore(skillsRoot: root.appendingPathComponent("app"))
        let store = SkillsStore(appStore: owner,
            stateFileURL: root.appendingPathComponent("enablement.json"), loadImmediately: false)
        let suite = "builtin-skill-install-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (root, owner, store, defaults)
    }

    @Test func firstLaunchEnablesEveryBuiltinSkillOnce() throws {
        let (root, owner, store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = store.installBuiltinSkillsIfNeeded(markerStore: defaults)
        #expect(installed == DefaultPromptSkills.entries.count)
        for entry in DefaultPromptSkills.entries {
            let skill = try #require(owner.allSkills().first { $0.id == SkillStore.slugify(entry.name) })
            #expect(skill.isEnabled)
        }
        #expect(defaults.integer(forKey: SkillsStore.builtinSkillsInstalledVersionKey) == DefaultPromptSkills.version)
        #expect(store.installBuiltinSkillsIfNeeded(markerStore: defaults) == 0)
    }

    @Test func aSkillTheUserAlreadyHasIsLeftUntouched() throws {
        let (root, owner, store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(DefaultPromptSkills.entries.first)
        let userCopy = "---\nname: \(first.name)\nversion: 9.0.0\n---\nuser body"
        _ = try owner.importSkill(content: userCopy, source: .file)
        let installed = store.installBuiltinSkillsIfNeeded(markerStore: defaults)
        #expect(installed == DefaultPromptSkills.entries.count - 1)
        #expect(owner.rawContent(SkillStore.slugify(first.name)) == userCopy)
    }

    @Test func everyBuiltinSkillIsSubstantialAndProductSpecific() {
        #expect(DefaultPromptSkills.entries.count >= 15)
        for entry in DefaultPromptSkills.entries {
            let characters = entry.body.filter { !$0.isWhitespace }.count
            #expect(characters >= 1_500, "\(entry.name) is too thin: \(characters)")
            #expect(SkillCatalogDocumentPolicy.admit(entry.document) != nil, "\(entry.name) must pass the skill document policy")
        }
    }
    @Test func everydayRequestsReachTheMatchingBuiltinSkill() throws {
        let (root, owner, store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = store.installBuiltinSkillsIfNeeded(markerStore: defaults)
        let injector = SkillInjector(store: owner)
        let cases: [(String, String)] = [
            ("这个接口报错了，500", "debugging-playbook"),
            ("帮我做个计划，下周要上线新版本", "planning-playbook"),
            ("帮我写一份周报", "writing-summary"),
            ("打开这个网页看看价格", "browser-web"),
            ("每天早上九点自动汇总邮件", "scheduled-task"),
            ("把这个目录下的旧文件删掉", "file-safety")
        ]
        for (request, expected) in cases {
            let matched = injector.matchingSkills(for: request).map(\.id)
            #expect(matched.contains(SkillStore.slugify(expected)), "\(request) → \(matched)")
        }
        #expect(injector.matchingSkills(for: "今天天气怎么样").isEmpty)
    }
}

// 2026-11-15 第七版：技能审批预览里的范围扩大警示（非原生，纯函数）。
@Suite("Skill scope expansion warning")
struct SkillScopeExpansionWarningTests {
    @Test func addedLinesThatWidenScopeAreListed() throws {
        let diff = "@@ -1 +1,4 @@\n-原有说明\n+新增工具：文件读取\n+新增目录：样例目录\n+扩大写入范围：样例输出\n+换一种说法描述步骤"
        let lines = try #require(ApprovalPromptView.skillScopeExpansionLines(diff))
        #expect(lines == ["新增工具：文件读取", "新增目录：样例目录", "扩大写入范围：样例输出"])
    }

    @Test func removedOrNeutralLinesDoNotWarn() {
        #expect(ApprovalPromptView.skillScopeExpansionLines("@@ -1 +1 @@\n-新增工具：旧的\n+换一种说法描述步骤") == nil)
        #expect(ApprovalPromptView.skillScopeExpansionLines("+++ b/SKILL.md\n+只改了措辞") == nil)
    }
}
