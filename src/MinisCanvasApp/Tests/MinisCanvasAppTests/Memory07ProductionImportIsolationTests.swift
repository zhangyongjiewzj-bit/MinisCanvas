import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Memory07ImportProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "memory07-local"
    var model = LLMModel(id: "synthetic", displayName: "Synthetic", provider: "memory07-local")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "memory07-owned-config"
    private let lock = NSLock()
    private var captured: [String] = []
    var prompts: [String] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(systemPrompt ?? "") }
        return LLMResponse(text: "synthetic reply", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        Issue.record("Synthetic import probe unexpectedly used streaming transport")
        return AsyncThrowingStream { $0.finish() }
    }
}

/// D-MEMORY-07 diagnostic delta: imported facts come only from the real
/// SettingsCenter preview/select/confirm path. Never repair their metadata in
/// the fixture. The existing classified injection tests cover actual requests;
/// this probe targets their missing production writer and reload boundary.
@Suite("D-MEMORY-07 production import visibility and reload")
@MainActor
struct Memory07ProductionImportIsolationTests {
    private func makeCenter(root: URL, memory: MemoryStore, defaults: UserDefaults) throws -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: memory,
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("memory07-import-" + root.lastPathComponent)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
        _ = try center.provisionMemoryCandidateSubmission()
        return center
    }

    @Test("D-MEMORY-07 production Personal Project and Temporary imports survive reload and enforce owner/project matrix")
    func productionPersonalProjectImportsRespectReloadedMatrix() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("memory07-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "memory07-import-" + root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: "memory07-import-" + root.lastPathComponent) }
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let center = try makeCenter(root: root, memory: memory, defaults: defaults)
        let principal = try #require(ProcessUIDMemoryPrincipalSource.production.trustedPrincipal())
        let otherUID: uid_t = getuid() == 501 ? 502 : 501
        let other = try #require(ProcessUIDMemoryPrincipalSource(readUID: { otherUID }).trustedPrincipal())
        let a = MemoryScope(sessionID: "synthetic-session-a", projectID: "synthetic-project-a")
        let sibling = MemoryScope(sessionID: "synthetic-session-a2", projectID: a.projectID)
        let b = MemoryScope(sessionID: "synthetic-session-b", projectID: "synthetic-project-b")
        var activeScope = a
        center.memoryScopeProvider = { activeScope }
        center.memoryOwnerUserIDProvider = { principal.userID }
        let inputs: [(MemoryImportScope, String)] = [
            (.personal, "scopeprobe personal-owned"), (.project, "scopeprobe project-a"),
            (.temporary, "scopeprobe temporary-a")
        ]
        for (selection, text) in inputs {
            let preview = try center.previewMemoryMarkdown(Data("## Preferences\n- \(text)\n".utf8))
            let result = try center.confirmMemoryMarkdownImport(preview, selecting: selection)
            #expect(result.added == 1)
        }
        activeScope = b
        let previewB = try center.previewMemoryMarkdown(Data("## Preferences\n- scopeprobe project-b\n".utf8))
        #expect(try center.confirmMemoryMarkdownImport(previewB, selecting: .project).added == 1)
        let bytesBefore = try Data(contentsOf: memory.fileURL)
        let reopened = MemoryStore(directory: memory.directory)
        let facts = try reopened.activeFacts()
        #expect(facts.count == 4)
        #expect(facts.first { $0.text == "scopeprobe temporary-a" }?.visibility == .temporary)
        #expect(facts.first { $0.text == "scopeprobe temporary-a" }?.temporaryLifetimeID == "session:" + a.sessionID)
        #expect(facts.first { $0.text == "scopeprobe personal-owned" }?.visibility == .personal)
        #expect(facts.first { $0.text == "scopeprobe project-a" }?.visibility == .project)
        #expect(facts.first { $0.text == "scopeprobe project-b" }?.visibility == .project)
        let injector = MemoryInjector(store: reopened, maxFacts: 10)
        let cells: [(String, MemoryScope, MemoryTrustedPrincipal?, MemoryTemporaryLifetime?, Set<String>)] = [
            ("A/owner", a, principal, MemoryTemporaryLifetime(id: "session:" + a.sessionID), ["scopeprobe personal-owned", "scopeprobe project-a", "scopeprobe temporary-a"]),
            ("A/wrong-lifetime", a, principal, MemoryTemporaryLifetime(id: "session:other"), ["scopeprobe personal-owned", "scopeprobe project-a"]),
            ("A/no-lifetime", a, principal, nil, ["scopeprobe personal-owned", "scopeprobe project-a"]),
            ("A/other-owner", a, other, MemoryTemporaryLifetime(id: "session:" + a.sessionID), ["scopeprobe project-a", "scopeprobe temporary-a"]),
            ("A2/owner", sibling, principal, MemoryTemporaryLifetime(id: "session:" + a.sessionID), ["scopeprobe personal-owned", "scopeprobe project-a"]),
            ("B/owner", b, principal, MemoryTemporaryLifetime(id: "session:" + a.sessionID), ["scopeprobe personal-owned", "scopeprobe project-b"]),
            ("B/other-owner", b, other, MemoryTemporaryLifetime(id: "session:" + a.sessionID), ["scopeprobe project-b"]),
            ("B/no-principal", b, nil, MemoryTemporaryLifetime(id: "session:" + a.sessionID), ["scopeprobe project-b"])
        ]
        for (label, scope, owner, lifetime, expected) in cells {
            let injected = try injector.injection(base: "synthetic", userMessage: "scopeprobe",
                context: MemoryInjectionContext(scope: scope, trustedPrincipal: owner, temporaryLifetime: lifetime))
            let seen = Set(facts.filter { injected.injectedFactIDs.contains($0.id) }.map(\.text))
            print("MEMORY07_IMPORT_MATRIX cell=\(label) injectedCount=\(seen.count) expectedCount=\(expected.count)")
            #expect(seen == expected, "cell=\(label)")
            for fact in facts {
                #expect(injected.prompt.contains(fact.text) == expected.contains(fact.text), "cell=\(label)")
            }
        }
        #expect(try Data(contentsOf: memory.fileURL) == bytesBefore)
    }

    @Test("D-MEMORY-07 production imports reach actual ordinary requests after reload and Project B switch")
    func productionImportsReachOrdinaryRequestsWithSessionLifetime() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("memory07-request-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "memory07-import-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemoryStore(directory: root.appendingPathComponent("memory"))
        let center = try makeCenter(root: root, memory: store, defaults: defaults)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let a = UUID(), a2 = UUID(), b = UUID()
        for (id, project) in [(a, "synthetic-A"), (a2, "synthetic-A"), (b, "synthetic-B")] {
            try sessions.createSession(id: id.uuidString, title: "Synthetic", projectID: project,
                projectName: project, workingDirectory: root.path)
        }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        defer { chat.stopAllStreamingForSafety() }
        try #require(chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        try #require(chat.applySwitchSession(id: a))
        center.memoryScopeProvider = { chat.activeMemoryScope }
        let principal = try #require(ProcessUIDMemoryPrincipalSource.production.trustedPrincipal())
        center.memoryOwnerUserIDProvider = { principal.userID }
        for (selection, marker) in [(MemoryImportScope.personal, "scopeprobe personal"), (.project, "scopeprobe project-A"), (.temporary, "scopeprobe temporary-A")] {
            let preview = try center.previewMemoryMarkdown(Data("## Preferences\n- \(marker)\n".utf8))
            #expect(try center.confirmMemoryMarkdownImport(preview, selecting: selection).added == 1)
        }
        try #require(chat.applySwitchSession(id: b))
        let previewB = try center.previewMemoryMarkdown(Data("## Preferences\n- scopeprobe project-B\n".utf8))
        #expect(try center.confirmMemoryMarkdownImport(previewB, selecting: .project).added == 1)
        let bytes = try Data(contentsOf: store.fileURL)
        chat.memoryInjector = MemoryInjector(store: MemoryStore(directory: store.directory), maxFacts: 10)
        chat.memoryEnabledProvider = { true }
        chat.memoryTrustedPrincipalProvider = { principal }
        // The production default chooses the concrete target session lifetime.
        // No test override or repair of imported facts is installed.
        try #require(chat.memoryTemporaryLifetimeProvider == nil)
        let provider = Memory07ImportProvider()
        chat.streamingProviderOverride = provider
        let policy = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "synthetic-policy", grantEpoch: "synthetic-epoch",
            leaseID: "synthetic-lease", expiresAt: .distantFuture, autonomyCeiling: .l1)
        chat.configureComposerPolicy(policy)
        chat.agentEngine = AgentLoopChatEngine(requestBudget: chat.budgetTracker, composerPolicyFacts: policy)
        let skill = SkillInjector(store: SkillStore(skillsRoot: root.appendingPathComponent("skills")))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: skill.snapshotForTurn(), mcpBridge: nil)
        }
        let cells: [(UUID, Set<String>)] = [
            (a, ["scopeprobe personal", "scopeprobe project-A", "scopeprobe temporary-A"]),
            (a2, ["scopeprobe personal", "scopeprobe project-A"]),
            (b, ["scopeprobe personal", "scopeprobe project-B"])
        ]
        for (index, cell) in cells.enumerated() {
            try #require(chat.applySwitchSession(id: cell.0))
            chat.draftText = "scopeprobe ordinary \(index)"
            chat.submitComposer()
            for _ in 0..<300 {
                if !chat.isActiveSessionStreaming && provider.prompts.count == index + 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(!chat.isActiveSessionStreaming)
            try #require(provider.prompts.count == index + 1)
            let prompt = try #require(provider.prompts.last)
            for marker in ["scopeprobe personal", "scopeprobe project-A", "scopeprobe temporary-A", "scopeprobe project-B"] {
                #expect(prompt.contains(marker) == cell.1.contains(marker), "request=\(index)")
            }
            print("MEMORY07_IMPORT_REQUEST cell=\(index) expectedCount=\(cell.1.count) providerCount=\(provider.prompts.count)")
        }
        #expect(try Data(contentsOf: store.fileURL) == bytes)
        #expect(try MemoryStore(directory: store.directory).activeFacts().count == 4)
    }

    @Test("D-MEMORY-07 Personal production import rejects unavailable process identity before persistence")
    func personalImportWithoutOwnerFailsClosed() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("memory07-no-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "memory07-import-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let center = try makeCenter(root: root, memory: memory, defaults: defaults)
        center.memoryScopeProvider = { MemoryScope(sessionID: "synthetic-session", projectID: "synthetic-project") }
        center.memoryOwnerUserIDProvider = nil
        let preview = try center.previewMemoryMarkdown(Data("## Preferences\n- scopeprobe personal\n".utf8))
        #expect(throws: MemoryMarkdownImportError.invalidScope) {
            try center.confirmMemoryMarkdownImport(preview, selecting: .personal)
        }
        #expect(try MemoryStore(directory: memory.directory).activeFacts().isEmpty)
    }
}
