import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("SKILL399 actual request consumers", .serialized)
@MainActor
struct SKILL399RequestConsumerTests {
    private func waitForPrompts(_ provider: SKILL399RecordingProvider, count: Int) async throws {
        for _ in 0..<500 {
            if provider.prompts.count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(provider.prompts.count >= count)
    }

    private func waitForTerminal(
        _ chat: ChatStore, provider: SKILL399RecordingProvider, count: Int
    ) async throws {
        for _ in 0..<500 {
            if provider.prompts.count >= count && !chat.isStreaming { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(provider.prompts.count >= count && !chat.isStreaming)
    }

    private func contextSettingsOwner(
        root: URL, sessions: URL, env: EnvVarStore,
        skills: SkillStore, keychain: KeychainStore,
        readiness: ProviderReadinessStore
    ) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: env,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: sessions),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: skills,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: readiness)
    }

    private func readyLocalProvider(
        _ provider: SKILL399RecordingProvider, root: URL
    ) throws -> ProviderReadinessStore {
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let checkedAt = Date()
        let lineage = ProviderReadinessLineage.derived(
            providerID: provider.name, modelID: provider.model.id, checkedAt: checkedAt
        )
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: provider.name, modelID: provider.model.id,
            status: .passed, readinessState: .mock, checkedAt: checkedAt,
            evidenceID: "skill399-owned-synthetic", isApplied: false,
            discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt
        )]))
        try #require(readiness.applyDiscoveredModels(
            providerID: provider.name, modelIDs: [provider.model.id],
            appliedAt: checkedAt.addingTimeInterval(1)
        ).count == 1)
        return readiness
    }

    // This uses the real production attachment: it constructs offscreen
    // WKWebView and AVSpeechSynthesizer dependencies. It is not a pure Core
    // test and requires ROOT's native-body classification before execution.
    @Test func settingsCommitChangesActualNewRequestsWithoutRewritingTheCapturedFirstTurn() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        // A previous isolated fixture may still own the weak process-wide
        // pointer. This fixture installs and verifies its own canonical owner.
        let root = formal.temporaryDirectory.appendingPathComponent("skill399-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let body = "settings consumer complete body\nsecond immutable line"
        let imported = try appStore.importSkillThroughLifecycle(
            content: "---\nname: skill399-settings\ndescription: skill399 settings consumer\nversion: 1.0.0\n---\n\(body)",
            source: .file, reason: "actual settings request consumer",
            approval: SkillApproval(approverID: "skill399-settings-reviewer")
        )
        let settings = SkillsStore(
             appStore: appStore,
            stateFileURL: root.appendingPathComponent("skills-enabled.json")
        )
        let defaultsName = formal.userDefaultsSuiteName + ".skill399-settings." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let keychain = KeychainStore(backing: CredentialIsolatedBacking())
        let env = EnvVarStore(
            directory: root.appendingPathComponent("environment"), keychain: keychain,
            privacyStore: EnvVarPrivacyStore(defaults: defaults)
        )
        let sessions = root.appendingPathComponent("sessions")
        let gate = SKILL399FirstRequestGate()
        let provider = SKILL399RecordingProvider(firstRequestGate: gate)
        let readiness = try readyLocalProvider(provider, root: root)
        let settingsOwner = contextSettingsOwner(
            root: root, sessions: sessions, env: env, skills: appStore,
            keychain: keychain, readiness: readiness)
        defer { withExtendedLifetime(settingsOwner) {} }
        #expect(SettingsCenter.active === settingsOwner)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions),
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness,
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        let attachment = bridge.attachProductionServices(
            browserSettings: .default, fileAccessAllowedRoot: root,
            fileAccessDeniedRoots: [], sessionDirectory: sessions,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            // Admit the local recording Provider through the real route gate;
            // it has no transport and performs no network request.
            skillStore: appStore, externalRunners: [:], externalNetworkAllowed: true,
            sessionReadSecretStore: env
        )
        await attachment.value
        let chat = bridge.chat
        chat.newSession()
        _ = try #require(chat.activeSessionID)
        try #require(chat.agentEngine is AgentLoopChatEngine)
        _ = try #require(chat.chatModelPickerReceipt(
            providerID: provider.name, modelID: provider.model.id
        ))
        chat.streamingProviderOverride = provider
        let productionFactory = try #require(chat.turnRuntimeSnapshotFactory)
        let settingsID = "app:" + imported.skill.id
        let observation = SKILL399TurnObservation()
        chat.turnRuntimeSnapshotFactory = { turn, provider in
            let pending = productionFactory(turn, provider)
            observation.captured.append(pending)
            return pending
        }
        chat.draftText = "skill399-settings"
        chat.sendDraft()
        try await waitForPrompts(provider, count: 1)
        #expect(chat.isStreaming)
        let firstPrompt = try #require(provider.prompts.first)
        #expect(firstPrompt.contains(body))
        guard case .success = settings.setEnabled(settingsID, enabled: false) else {
            await gate.release()
            Issue.record("the first settings disable did not commit")
            return
        }
        // The first request is already inside the real Provider and remains
        // frozen while the settings commit changes only later submissions.
        #expect(provider.prompts.first == firstPrompt)
        await gate.release()
        try await waitForTerminal(chat, provider: provider, count: 1)
        #expect(SkillsStateStore.load(from: root.appendingPathComponent("skills-enabled.json"))[settingsID] == false)
        #expect(provider.prompts.count == 1)
        #expect(provider.prompts.first?.contains(body) == true)
        let first = try #require(observation.captured.first)
        #expect(first.turn.isValid)
        #expect(chat.lastSkillInjectionReceipts.contains { $0.skillID == imported.skill.id && $0.injected && $0.state == .active })

        chat.draftText = "skill399-settings"
        chat.sendDraft()
        try await waitForTerminal(chat, provider: provider, count: 2)
        #expect(provider.prompts.count == 2)
        #expect(provider.prompts.last?.contains(body) == false)
        #expect(!chat.lastSkillInjectionReceipts.contains { $0.injected })
        #expect(observation.captured.count == 2)
        let second = try #require(observation.captured.last)
        #expect(second.turn.isValid && second.turn != first.turn)
        #expect(provider.prompts.first == firstPrompt)

        guard case .success = settings.setEnabled(settingsID, enabled: true) else {
            Issue.record("the next settings enable did not commit")
            return
        }
        #expect(SkillsStateStore.load(from: root.appendingPathComponent("skills-enabled.json"))[settingsID] == true)
        chat.draftText = "skill399-settings"
        chat.sendDraft()
        try await waitForTerminal(chat, provider: provider, count: 3)
        #expect(provider.prompts.count == 3)
        #expect(provider.prompts.last?.contains(body) == true)
        #expect(chat.lastSkillInjectionReceipts.contains { $0.skillID == imported.skill.id && $0.injected && $0.state == .active })
        #expect(observation.captured.count == 3)
        #expect(Set(observation.captured.map { $0.turn }).count == 3)
        #expect(provider.prompts.first == firstPrompt)
    }

    @Test func deletingExistingSkillDocumentRejectsPickerAndActualInjectionWhileManifestRemains() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("skill399-missing-document-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let body = "existing missing document complete body\nsecond literal line"
        let imported = try store.importSkillThroughLifecycle(
            content: "---\nname: skill399-missing\ndescription: skill399 missing document\nversion: 1.0.0\n---\n\(body)",
            source: .file, reason: "existing document deletion consumer",
            approval: SkillApproval(approverID: "skill399-missing-reviewer")
        )
        let manifestURL = store.skillManifestURL(for: imported.skill.id)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let document = store.skillDirectoryURL(for: imported.skill.id).appendingPathComponent("SKILL.md")
        #expect(try String(contentsOf: document, encoding: .utf8).contains(body))
        let defaultsName = formal.userDefaultsSuiteName + ".skill399-missing." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let engine = U4SystemPromptRecordingEngine()
        chat.agentEngine = engine
        chat.streamingProviderOverride = MockProvider.shared
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: store).snapshotForTurn(), mcpBridge: nil)
        }
        chat.pickerCatalogLoader = {
            SkillCatalogLoader.loadCatalog(appStore: store, servers: [])
        }
        chat.loadPickerCatalog()
        let item = try #require(chat.pickerCatalog.first { $0.id == "skill:" + imported.skill.id })
        chat.togglePickerItem(item)
        chat.sendDraft()
        for _ in 0..<200 where chat.isStreaming { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!chat.isStreaming)
        #expect(engine.systemPrompts.count == 1)
        #expect(engine.systemPrompts.first?.contains(body) == true)

        // Keep the loaded metadata and sidecar. Delete ONLY the literal body
        // document, unlike the old missing-manifest.json regression.
        chat.togglePickerItem(item)
        #expect(chat.selectedPickerItems.contains { $0.id == item.id })
        try FileManager.default.removeItem(at: document)
        #expect(try Data(contentsOf: manifestURL) == manifestBefore)
        #expect(store.allSkills().contains { $0.id == imported.skill.id })
        chat.loadPickerCatalog()
        #expect(!chat.pickerCatalog.contains { $0.id == item.id })
        #expect(!chat.selectedPickerItems.contains { $0.id == item.id })
        let rejected = SkillInjector(store: store).buildInjection(
            for: "skill399-missing", selectedSkillIDs: [imported.skill.id]
        )
        #expect(rejected.fragment == nil)
        #expect(!rejected.receipts.contains { $0.injected })
        let missingSource = try #require(rejected.receipts.first { $0.skillID == imported.skill.id })
        #expect(missingSource.state == .rejected)
        #expect(missingSource.omittedReason == SkillRegistryRejection.missingSource.rawValue)
        #expect(missingSource.injectedCharacters == 0)
        chat.draftText = "@skill399-missing"
        chat.sendDraft()
        for _ in 0..<200 where chat.isStreaming { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!chat.isStreaming)
        #expect(engine.systemPrompts.count == 2)
        #expect(engine.systemPrompts.last?.contains(body) == false)
        #expect(engine.systemPrompts.last?.contains("<injected_skills>") == false)
        #expect(!chat.lastSkillInjectionReceipts.contains { $0.injected })
        #expect(try Data(contentsOf: manifestURL) == manifestBefore)
        let restarted = SkillStore(skillsRoot: store.skillsRoot)
        #expect(!SkillCatalogLoader.loadCatalog(appStore: restarted, servers: [])
            .contains { $0.id == item.id })
        #expect(SkillInjector(store: restarted).buildInjection(for: "skill399-missing").fragment == nil)
    }

    @Test func sixSkillCatalogSendsExactlyThreeCompleteBodiesAndNoUnmentionedBodies() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("skill399-request-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        var ids: [String] = []
        var bodies: [String] = []
        for index in 1...6 {
            let body = "complete body \(index)\nsecond distinct line \(index)\nfinal distinct line \(index)"
            bodies.append(body)
            let imported = try store.importSkillThroughLifecycle(
                content: "---\nname: skill399-\(index)\ndescription: alpha beta\nversion: 1.0.0\n---\n\(body)",
                source: .file, reason: "six skill outgoing request fixture",
                approval: SkillApproval(approverID: "skill399-reviewer")
            )
            ids.append(imported.skill.id)
        }
        let injector = SkillInjector(store: store, maxInjectedSkills: 3, minimumScore: 1)
        let defaultsName = formal.userDefaultsSuiteName + ".skill399." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let engine = U4SystemPromptRecordingEngine()
        chat.agentEngine = engine
        chat.streamingProviderOverride = MockProvider.shared
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(), mcpBridge: nil)
        }
        chat.pickerCatalogLoader = { SkillCatalogLoader.storeSkillItems(from: store) }
        chat.loadPickerCatalog()
        #expect(chat.pickerCatalog.count == 6)
        chat.draftText = "alpha beta @skill399-1 @skill399-2 @skill399-3"
        chat.sendDraft()
        for _ in 0..<200 where chat.isStreaming { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!chat.isStreaming)
        #expect(engine.systemPrompts.count == 1)
        let prompt = try #require(engine.systemPrompts.first)
        #expect(prompt.contains("<injected_skills>"))
        #expect(prompt.components(separatedBy: "<skill name=").count - 1 == 3)
        for index in 0..<3 {
            #expect(prompt.contains(bodies[index]), "the whole matched body must reach the actual outgoing request")
        }
        for index in 3..<6 {
            #expect(!prompt.contains(bodies[index]), "an unmentioned skill must not enter this request")
        }
        let injected = chat.lastSkillInjectionReceipts.filter { $0.injected }
        #expect(Set(injected.map(\.skillID)) == Set(ids.prefix(3)))
        #expect(injected.count == 3)
        #expect(injected.allSatisfy { $0.state == .active })
        for receipt in injected {
            let content = try #require(store.rawContent(receipt.skillID))
            #expect(receipt.contentHash == SkillManifest.hash(content))
        }

        // Same large catalog, new actual request, no relevant reference or words.
        chat.draftText = "ordinary unrelated request"
        chat.sendDraft()
        for _ in 0..<200 where chat.isStreaming { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!chat.isStreaming)
        #expect(engine.systemPrompts.count == 2)
        let ordinary = try #require(engine.systemPrompts.last)
        // 第七版：本会话命中过的技能后续回合最多再带 2 篇，其余正文不进入。
        #expect(ordinary.contains("<injected_skills>"))
        #expect(bodies.prefix(2).allSatisfy { ordinary.contains($0) })
        #expect(bodies.dropFirst(2).allSatisfy { !ordinary.contains($0) })
        #expect(Set(chat.lastSkillInjectionReceipts.filter { $0.injected }.map(\.skillID)) == Set(ids.prefix(2)))
    }
    @Test func settingsRollbackRestoresScopedDurableSourceBeforeActualNextRequest() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("skill598-rollback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = formal.userDefaultsSuiteName + ".skill598." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")))
        chat.newSession(projectID: "skill598-owned-project")
        let scopedSessionID = try #require(chat.activeSessionID)
        let scope = MemoryScope(sessionID: scopedSessionID.uuidString, projectID: "skill598-owned-project")
        #expect(chat.activeMemoryScope == scope)
        let expiry = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 3600)
        let oldContent = "---\nname: skill598-rollback\ndescription: scoped previous revision\nversion: 1.0.0\n---\nold entire scoped body\nsecond old line"
        let currentContent = "---\nname: skill598-rollback\ndescription: global current revision\nversion: 2.0.0\n---\ncurrent entire global body\nsecond current line"
        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let previous = try store.importSkillThroughLifecycle(
            content: oldContent, source: .bundled, reason: "previous scoped revision", scope: scope,
            approval: SkillApproval(approverID: "previous-reviewer", scope: scope, expiresAt: expiry)
        )
        let previousManifest = try Data(contentsOf: store.skillManifestURL(for: previous.skill.id))
        let previousReceipt = try #require(store.lifecycleReceipt(for: previous.skill.id))
        let oldScoped = SkillInjector(store: store).buildInjection(for: "skill598-rollback", within: scope)
        #expect(oldScoped.fragment?.contains("old entire scoped body\nsecond old line") == true)
        #expect(SkillInjector(store: store).buildInjection(for: "skill598-rollback").fragment == nil)
        chat.newSession()
        #expect(chat.activeMemoryScope == nil)
        let current = try store.importSkillThroughLifecycle(
            content: currentContent, source: .file, reason: "current global revision",
            approval: SkillApproval(approverID: "current-reviewer", expiresAt: expiry.addingTimeInterval(600))
        )
        #expect(current.receipt.scope == nil)
        let stateURL = root.appendingPathComponent("skills-enabled.json")
        let settings = SkillsStore(appStore: store, stateFileURL: stateURL)
        let engine = U4SystemPromptRecordingEngine()
        chat.agentEngine = engine
        chat.streamingProviderOverride = MockProvider.shared
        var runtimeStore = store
        var frozenFirst: ChatTurnRuntimeSnapshot?
        var rollbackReceipt: SkillLifecycleReceipt?
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            let snapshot = ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: runtimeStore).snapshotForTurn(), mcpBridge: nil)
            if frozenFirst == nil {
                frozenFirst = snapshot
                switch settings.rollback("app:" + previous.skill.id) {
                case .success(let receipt): rollbackReceipt = receipt
                case .failure(let error): Issue.record("Settings rollback rejected: \(error)")
                }
            }
            return snapshot
        }
        chat.draftText = "@skill598-rollback"
        chat.sendDraft()
        for _ in 0..<200 where chat.isStreaming { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!chat.isStreaming)
        #expect(engine.systemPrompts.count == 1)
        #expect(engine.systemPrompts.first?.contains("current entire global body\nsecond current line") == true)
        #expect(engine.systemPrompts.first?.contains("old entire scoped body") == false)
        #expect(chat.lastSkillInjectionReceipts.contains { $0.skillID == previous.skill.id && $0.injected && $0.contentHash == current.receipt.contentHash })
        let rolledBack = try #require(rollbackReceipt)
        #expect(rolledBack.state == .rolledBack)
        #expect(rolledBack.scope == scope)
        #expect(rolledBack.approvedBy == previousReceipt.approvedBy)
        #expect(rolledBack.expiresAt == previousReceipt.expiresAt)
        #expect(rolledBack.sourceIdentity == previousReceipt.sourceIdentity)
        #expect(rolledBack.contentHash == previousReceipt.contentHash)
        #expect(try Data(contentsOf: store.skillManifestURL(for: previous.skill.id)) == previousManifest)
        #expect(SkillsStateStore.load(from: stateURL)["app:" + previous.skill.id] == false)
        runtimeStore = SkillStore(skillsRoot: store.skillsRoot)
        let restartedSettings = SkillsStore(appStore: runtimeStore, stateFileURL: stateURL)
        #expect(runtimeStore.lifecycleReceipt(for: previous.skill.id) == rolledBack)
        #expect(runtimeStore.rawContent(previous.skill.id) == oldContent)
        #expect(runtimeStore.allSkills().first { $0.id == previous.skill.id }?.importSource == .bundled)
        #expect(runtimeStore.allSkills().first { $0.id == previous.skill.id }?.isEnabled == false)
        let restartedPickerStore = runtimeStore
        chat.pickerCatalogLoader = {
            SkillCatalogLoader.loadCatalog(appStore: restartedPickerStore, servers: [])
        }
        chat.loadPickerCatalog()
        #expect(!chat.pickerCatalog.contains { $0.id == "skill:" + previous.skill.id })
        // Re-enabling without the original fresh-approval requirement cannot
        // turn restored historic authorization into a new global grant.
        if case .success = restartedSettings.setEnabled("app:" + previous.skill.id, enabled: true) {
            Issue.record("rolled-back skill bypassed fresh approval")
        }
        #expect(runtimeStore.lifecycleReceipt(for: previous.skill.id) == rolledBack)
        for requestScope in [scope, MemoryScope(sessionID: "foreign-session", projectID: "skill598-owned-project"), MemoryScope(sessionID: scopedSessionID.uuidString, projectID: "foreign-project")] {
            let denied = SkillInjector(store: runtimeStore).buildInjection(for: "skill598-rollback", selectedSkillIDs: [previous.skill.id], within: requestScope)
            #expect(denied.fragment == nil)
            #expect(!denied.receipts.contains { $0.injected })
            let deniedReceipt = try #require(denied.receipts.first { $0.skillID == previous.skill.id })
            #expect(deniedReceipt.state == .rejected)
            #expect(deniedReceipt.omittedReason == SkillRegistryRejection.inactiveReceipt.rawValue)
            #expect(deniedReceipt.contentHash == previousReceipt.contentHash)
        }
        chat.switchSession(id: scopedSessionID)
        #expect(chat.activeMemoryScope == scope)
        chat.draftText = "@skill598-rollback"
        chat.sendDraft()
        for _ in 0..<200 where chat.isStreaming { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!chat.isStreaming)
        #expect(engine.systemPrompts.count == 2)
        #expect(engine.systemPrompts.last?.contains("old entire scoped body") == false)
        #expect(engine.systemPrompts.last?.contains("current entire global body") == false)
        #expect(!chat.lastSkillInjectionReceipts.contains { $0.injected })
        let frozen = try #require(frozenFirst)
        let frozenInjector = try #require(frozen.skillInjector)
        #expect(frozenInjector.buildInjection(for: "skill598-rollback").fragment?.contains("current entire global body\nsecond current line") == true)
        #expect(runtimeStore.lifecycleReceipt(for: previous.skill.id)?.scope == scope)
        #expect(try Data(contentsOf: runtimeStore.skillManifestURL(for: previous.skill.id)) == previousManifest)
    }

    @Test func productionBridgeRollbackNextTurnKeepsOldAuthorizationBoundaries() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("skillb-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = formal.userDefaultsSuiteName + ".skillb-bridge." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let keychain = KeychainStore(backing: CredentialIsolatedBacking())
        let env = EnvVarStore(
            directory: root.appendingPathComponent("environment"), keychain: keychain,
            privacyStore: EnvVarPrivacyStore(defaults: defaults)
        )
        let sessions = root.appendingPathComponent("sessions")
        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let provider = SKILL399RecordingProvider()
        let readiness = try readyLocalProvider(provider, root: root)
        let settingsOwner = contextSettingsOwner(
            root: root, sessions: sessions, env: env, skills: store,
            keychain: keychain, readiness: readiness)
        defer { withExtendedLifetime(settingsOwner) {} }
        #expect(SettingsCenter.active === settingsOwner)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions),
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness,
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        let attachment = bridge.attachProductionServices(
            browserSettings: .default, fileAccessAllowedRoot: root,
            fileAccessDeniedRoots: [], sessionDirectory: sessions,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            // The synthetic Provider records requests locally; the production
            // route gate still validates its identity before dispatch.
            skillStore: store, externalRunners: [:], externalNetworkAllowed: true,
            sessionReadSecretStore: env
        )
        await attachment.value
        let chat = bridge.chat
        _ = try #require(chat.turnRuntimeSnapshotFactory)
        try #require(chat.agentEngine is AgentLoopChatEngine)
        _ = try #require(chat.chatModelPickerReceipt(
            providerID: provider.name, modelID: provider.model.id
        ))
        chat.streamingProviderOverride = provider

        chat.newSession(projectID: "skillb-owned-project")
        let ownedSession = try #require(chat.activeSessionID)
        let scope = try #require(chat.activeMemoryScope)
        #expect(scope == MemoryScope(sessionID: ownedSession.uuidString, projectID: "skillb-owned-project"))
        let expiry = Date().addingTimeInterval(3600)
        let oldBody = "old scoped complete body\nsecond old line"
        let newBody = "new global complete body\nsecond new line"
        let oldContent = "---\nname: skillb-bridge\ndescription: scoped prior revision\nversion: 1.0.0\n---\n\(oldBody)"
        let newContent = "---\nname: skillb-bridge\ndescription: global current revision\nversion: 2.0.0\n---\n\(newBody)"
        let previous = try store.importSkillThroughLifecycle(
            content: oldContent, source: .bundled, reason: "old scoped fixture", scope: scope,
            approval: SkillApproval(approverID: "old-reviewer", scope: scope, expiresAt: expiry)
        )
        let originalManifest = try Data(contentsOf: store.skillManifestURL(for: previous.skill.id))
        let current = try store.importSkillThroughLifecycle(
            content: newContent, source: .file, reason: "current global fixture",
            approval: SkillApproval(approverID: "current-reviewer", expiresAt: expiry)
        )
        let stateURL = root.appendingPathComponent("skills-enabled.json")
        let settings = SkillsStore(
             appStore: store,
            stateFileURL: stateURL
        )
        let settingsID = "app:" + previous.skill.id

        chat.newSession()
        #expect(chat.activeMemoryScope == nil)
        chat.draftText = "@skillb-bridge"
        chat.sendDraft()
        try await waitForTerminal(chat, provider: provider, count: 1)
        #expect(provider.prompts.count == 1)
        #expect(provider.prompts.last?.contains(newBody) == true)
        #expect(chat.lastSkillInjectionReceipts.contains {
            $0.skillID == previous.skill.id && $0.injected && $0.contentHash == current.receipt.contentHash
        })

        let rollback: SkillLifecycleReceipt
        switch settings.rollback(settingsID, reason: "settings bridge rollback") {
        case .success(let receipt): rollback = receipt
        case .failure(let error):
            Issue.record("production bridge fixture rollback failed: \(error)")
            return
        }
        #expect(rollback.state == .rolledBack)
        #expect(rollback.scope == previous.receipt.scope)
        #expect(rollback.approvedBy == previous.receipt.approvedBy)
        #expect(rollback.expiresAt == previous.receipt.expiresAt)
        #expect(rollback.sourceIdentity == previous.receipt.sourceIdentity)
        #expect(rollback.contentHash == previous.receipt.contentHash)
        #expect(store.rawContent(previous.skill.id) == oldContent)
        #expect(try Data(contentsOf: store.skillManifestURL(for: previous.skill.id)) == originalManifest)
        #expect(SkillsStateStore.load(from: stateURL)[settingsID] == false)
        #expect(store.allSkills().first { $0.id == previous.skill.id }?.importSource == .bundled)
        #expect(store.allSkills().first { $0.id == previous.skill.id }?.isEnabled == false)
        if case .success = settings.setEnabled(settingsID, enabled: true) {
            Issue.record("rollback re-enabled the old authorization without fresh approval")
        }

        chat.switchSession(id: ownedSession)
        #expect(chat.activeMemoryScope == scope)
        chat.draftText = "@skillb-bridge"
        chat.sendDraft()
        try await waitForTerminal(chat, provider: provider, count: 2)
        #expect(provider.prompts.count == 2)
        #expect(provider.prompts.last?.contains(oldBody) == false)
        #expect(provider.prompts.last?.contains(newBody) == false)
        #expect(!chat.lastSkillInjectionReceipts.contains { $0.injected })

        // A new explicit review can reactivate only the original scope. This
        // exercises the same BridgeStore factory on subsequent actual turns.
        let fresh = try store.importSkillThroughLifecycle(
            content: oldContent, source: .bundled, reason: "fresh scoped review",
            scope: scope,
            approval: SkillApproval(approverID: "fresh-reviewer", scope: scope, expiresAt: expiry)
        )
        #expect(fresh.receipt.state == .active)
        #expect(fresh.receipt.scope == scope)
        #expect(fresh.receipt.sourceIdentity == previous.receipt.sourceIdentity)
        try settings.setEnabled(settingsID, enabled: true).get()
        chat.draftText = "@skillb-bridge"
        chat.sendDraft()
        try await waitForTerminal(chat, provider: provider, count: 3)
        #expect(provider.prompts.count == 3)
        #expect(provider.prompts.last?.contains(oldBody) == true)
        #expect(provider.prompts.last?.contains(newBody) == false)
        #expect(chat.lastSkillInjectionReceipts.contains {
            $0.skillID == previous.skill.id && $0.injected && $0.contentHash == previous.receipt.contentHash
        })

        chat.newSession(projectID: "skillb-owned-project")
        #expect(chat.activeSessionID != ownedSession)
        #expect(chat.activeMemoryScope != scope)
        chat.draftText = "@skillb-bridge"
        chat.sendDraft()
        try await waitForTerminal(chat, provider: provider, count: 4)
        #expect(provider.prompts.count == 4)
        #expect(provider.prompts.last?.contains(oldBody) == false)
        #expect(!chat.lastSkillInjectionReceipts.contains { $0.injected })

        chat.newSession(projectID: "foreign-project")
        #expect(chat.activeMemoryScope != scope)
        chat.draftText = "@skillb-bridge"
        chat.sendDraft()
        try await waitForTerminal(chat, provider: provider, count: 5)
        #expect(provider.prompts.count == 5)
        #expect(provider.prompts.last?.contains(oldBody) == false)
        #expect(!chat.lastSkillInjectionReceipts.contains { $0.injected })

        // Expiry is a separate boundary from rollback and scope. Re-approve
        // the restored bytes for the original session, then let that approval
        // expire before a real next turn reaches the recording Provider.
        chat.switchSession(id: ownedSession)
        #expect(chat.activeMemoryScope == scope)
        let unapprovedReplacement = try store.importSkillThroughLifecycle(
            content: oldContent.replacingOccurrences(
                of: oldBody, with: "temporary unapproved replacement body"
            ),
            source: .bundled, reason: "stage unapproved replacement", scope: scope
        )
        #expect(unapprovedReplacement.receipt.state == .proposed)
        let secondRollback = try settings.rollback(
            settingsID, reason: "restore scoped bytes before expiring review"
        ).get()
        #expect(secondRollback.state == .rolledBack)
        #expect(secondRollback.scope == scope)
        #expect(secondRollback.sourceIdentity == previous.receipt.sourceIdentity)
        #expect(store.rawContent(previous.skill.id) == oldContent)
        #expect(store.allSkills().first { $0.id == previous.skill.id }?.isEnabled == false)
        let shortExpiry = Date().addingTimeInterval(5)
        let expiring = try store.importSkillThroughLifecycle(
            content: oldContent, source: .bundled, reason: "expiring scoped review",
            scope: scope,
            approval: SkillApproval(approverID: "expiring-reviewer", scope: scope, expiresAt: shortExpiry)
        )
        #expect(expiring.receipt.state == .active)
        #expect(expiring.receipt.expiresAt == shortExpiry)
        try settings.setEnabled(settingsID, enabled: true).get()
        let enabledBeforeExpiry = try #require(store.allSkills().first { $0.id == previous.skill.id })
        #expect(store.isInjectable(enabledBeforeExpiry, within: scope))
        while Date() < shortExpiry {
            try await Task.sleep(for: .milliseconds(20))
        }
        chat.draftText = "@skillb-bridge"
        chat.sendDraft()
        try await waitForTerminal(chat, provider: provider, count: 6)
        #expect(provider.prompts.count == 6)
        #expect(provider.prompts.last?.contains(oldBody) == false)
        #expect(provider.prompts.last?.contains(newBody) == false)
        #expect(!chat.lastSkillInjectionReceipts.contains { $0.injected })
    }

    @Test(arguments: ["damaged-document", "malformed-manifest", "unknown-schema", "quarantine"])
    func invalidSkillCannotReachPickerOrActualRequest(kind: String) async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("skill598-reject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let goodBody = "legal complete control body\nsecond legal line"
        let rejectedBody = "rejected entire body \(kind)\nsecond rejected line"
        let good = try store.importSkillThroughLifecycle(content: "---\nname: skill598-control\ndescription: legal control\n---\n\(goodBody)", source: .file, reason: "legal control", approval: SkillApproval(approverID: "control-reviewer"))
        let bad = try store.importSkillThroughLifecycle(content: "---\nname: skill598-reject\ndescription: invalid consumer\n---\n\(rejectedBody)", source: kind == "quarantine" ? .url("https://example.invalid/synthetic-skill") : .file, reason: "synthetic local fixture, no transport", approval: SkillApproval(approverID: "reject-reviewer"))
        let manifest = store.skillManifestURL(for: bad.skill.id)
        switch kind {
        case "damaged-document":
            try "not the approved complete body".write(to: store.skillsRoot.appendingPathComponent(bad.skill.id).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        case "malformed-manifest": try Data("{broken".utf8).write(to: manifest)
        case "unknown-schema":
            var fields = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            fields["schema"] = "future-unapproved-schema"
            try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: manifest)
        default: #expect(bad.receipt.state == .quarantined)
        }
        let damagedBytes = try Data(contentsOf: manifest)
        store.reload()
        let defaultsName = formal.userDefaultsSuiteName + ".skill598-reject." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let engine = U4SystemPromptRecordingEngine()
        chat.agentEngine = engine
        chat.streamingProviderOverride = MockProvider.shared
        chat.turnRuntimeSnapshotFactory = { turn, _ in ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: store).snapshotForTurn(), mcpBridge: nil) }
        chat.pickerCatalogLoader = { SkillCatalogLoader.loadCatalog(appStore: store, servers: []) }
        chat.loadPickerCatalog()
        #expect(chat.pickerCatalog.contains { $0.id == "skill:" + good.skill.id })
        #expect(!chat.pickerCatalog.contains { $0.id == "skill:" + bad.skill.id })
        let denied = SkillInjector(store: store).buildInjection(for: "skill598-reject", selectedSkillIDs: [bad.skill.id])
        #expect(denied.fragment == nil)
        #expect(!denied.receipts.contains { $0.injected })
        let receipt = try #require(denied.receipts.first { $0.skillID == bad.skill.id })
        #expect(receipt.state == .rejected)
        #expect(receipt.injectedCharacters == 0)
        #expect(receipt.omittedReason == (kind == "quarantine" ? SkillRegistryRejection.untrustedSource.rawValue : SkillRegistryRejection.invalidManifest.rawValue))
        chat.draftText = "@skill598-control @skill598-reject"
        chat.sendDraft()
        for _ in 0..<200 where chat.isStreaming { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!chat.isStreaming)
        #expect(engine.systemPrompts.count == 1)
        let outgoing = try #require(engine.systemPrompts.first)
        #expect(outgoing.contains(goodBody))
        #expect(!outgoing.contains(rejectedBody))
        #expect(!outgoing.contains("not the approved complete body"))
        #expect(chat.lastSkillInjectionReceipts.filter { $0.injected }.map(\.skillID) == [good.skill.id])
        #expect(try Data(contentsOf: manifest) == damagedBytes)
        let restarted = SkillStore(skillsRoot: store.skillsRoot)
        #expect(!SkillCatalogLoader.loadCatalog(appStore: restarted, servers: [])
            .contains { $0.id == "skill:" + bad.skill.id })
        #expect(SkillInjector(store: restarted).buildInjection(for: "skill598-reject", selectedSkillIDs: [bad.skill.id]).fragment == nil)
    }
    @Test func largeCatalogProductionBridgeInjectsOnlySelectedBodies() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "skill3215-large")
        defer { try? profile.cleanupDisposableRoots() }
        let root = formal.temporaryDirectory.appendingPathComponent("skill3215-large-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = formal.userDefaultsSuiteName + ".skill3215." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let keychain = KeychainStore(backing: CredentialIsolatedBacking())
        let env = EnvVarStore(directory: root.appendingPathComponent("environment"), keychain: keychain,
            privacyStore: EnvVarPrivacyStore(defaults: defaults))
        let sessions = root.appendingPathComponent("sessions")
        let store = SkillStore(skillsRoot: profile.minisCoreDirectory.appendingPathComponent("skills"))
        let manager = MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain)
        var ids: [String] = []
        var bodies: [String] = []
        for index in 1...30 {
            let body = "skill3215 unique complete body \(index)\nsecond unique line \(index)"
            let imported = try store.importSkillThroughLifecycle(
                content: "---\nname: skill3215-\(index)\ndescription: distinct3215-\(index)\nversion: 1.0.0\n---\n\(body)",
                source: .file, reason: "large catalog production request fixture",
                approval: SkillApproval(approverID: "skill3215-reviewer")
            )
            ids.append(imported.skill.id)
            bodies.append(body)
        }
        let provider = SKILL399RecordingProvider()
        let readiness = try readyLocalProvider(provider, root: root)
        let settingsOwner = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: env, memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: sessions),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: manager, skillStore: store,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness
        )
        defer { withExtendedLifetime(settingsOwner) {} }
        #expect(SettingsCenter.active === settingsOwner)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions),
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness, canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        let attachment = bridge.attachProductionServices(
            browserSettings: .default, fileAccessAllowedRoot: root,
            fileAccessDeniedRoots: [], sessionDirectory: sessions,
            mcpManager: manager,
            skillStore: store, externalRunners: [:], externalNetworkAllowed: true,
            sessionReadSecretStore: env
        )
        await attachment.value
        let chat = bridge.chat
        _ = try #require(chat.turnRuntimeSnapshotFactory)
        try #require(chat.agentEngine is AgentLoopChatEngine)
        #expect(ProductionPickerCatalogWiring.bind(chat: chat, center: settingsOwner, profile: profile))
        _ = try #require(chat.chatModelPickerReceipt(providerID: provider.name, modelID: provider.model.id))
        chat.streamingProviderOverride = provider
        chat.loadPickerCatalog()
        #expect(chat.pickerCatalog.count >= 30)
        #expect(chat.activeMemoryScope == nil)
        chat.draftText = "@skill3215-1 @skill3215-2 @skill3215-3"
        chat.sendDraft()
        try await waitForTerminal(chat, provider: provider, count: 1)
        let prompt = try #require(provider.prompts.first)
        #expect(prompt.components(separatedBy: "<skill name=").count - 1 == 3)
        for body in bodies.prefix(3) { #expect(prompt.contains(body)) }
        for body in bodies.dropFirst(3) { #expect(!prompt.contains(body)) }
        let injected = chat.lastSkillInjectionReceipts.filter { $0.injected }
        #expect(injected.count == 3)
        #expect(Set(injected.map(\.skillID)) == Set(ids.prefix(3)))
        for receipt in injected {
            let content = try #require(store.rawContent(receipt.skillID))
            #expect(receipt.contentHash == SkillManifest.hash(content))
        }

        chat.draftText = "ordinary unrelated request"
        chat.sendDraft()
        try await waitForTerminal(chat, provider: provider, count: 2)
        let ordinary = try #require(provider.prompts.last)
        // 第七版：本会话命中过的技能后续回合最多再带 2 篇，其余正文不进入。
        #expect(ordinary.contains("<injected_skills>"))
        #expect(bodies.prefix(2).allSatisfy { ordinary.contains($0) })
        #expect(bodies.dropFirst(2).allSatisfy { !ordinary.contains($0) })
        #expect(Set(chat.lastSkillInjectionReceipts.filter { $0.injected }.map(\.skillID)) == Set(ids.prefix(2)))
    }

}

/// Observe the real Bridge factory without replacing its AgentLoop engine.
@MainActor
private final class SKILL399TurnObservation {
    var captured: [ChatTurnRuntimeSnapshot] = []
}

/// Hold the first real Provider call open while Settings commits the toggle.
/// The Provider receives the fully prepared system prompt before this wait.
private actor SKILL399FirstRequestGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func hold() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

/// A local, no-network Provider that records the actual AgentLoop outbound
/// prompt. It never executes tools or grants any new capability.
private final class SKILL399RecordingProvider: LLMProvider,
    ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "skill399-local"
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var currentModel = LLMModel(
        id: "skill399-local", displayName: "Synthetic Skill 399", provider: "skill399-local"
    )
    private var configurationMaterial: String? = "skill399-fixed-local"
    private var recordedPrompts: [String] = []
    private let firstRequestGate: SKILL399FirstRequestGate?

    init(firstRequestGate: SKILL399FirstRequestGate? = nil) {
        self.firstRequestGate = firstRequestGate
    }

    var model: LLMModel {
        get { lock.withLock { currentModel } }
        set { lock.withLock { currentModel = newValue } }
    }
    var runtimeConfigurationMaterial: String? {
        get { lock.withLock { configurationMaterial } }
        set { lock.withLock { configurationMaterial = newValue } }
    }
    var prompts: [String] { lock.withLock { recordedPrompts } }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let count = lock.withLock { () -> Int in
            recordedPrompts.append(systemPrompt ?? "")
            return recordedPrompts.count
        }
        if count == 1 { await firstRequestGate?.hold() }
        return LLMResponse(text: "synthetic skill consumer answer", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw CancellationError()
    }

}
