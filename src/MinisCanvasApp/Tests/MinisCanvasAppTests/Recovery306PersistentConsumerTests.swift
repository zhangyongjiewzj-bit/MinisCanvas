import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Reopens synthetic stores through existing consumers. These tests do not
/// launch the App, restore real tasks, or manufacture a readiness approval.
@Suite("Recovery306 persistent settings and next-turn consumers", .serialized)
@MainActor
struct Recovery306PersistentConsumerTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery306-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func center(_ root: URL) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("recovery306-\(root.lastPathComponent)")),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
    }

    @Test("restored settings feed model and theme consumers without granting cold readiness")
    func restoredSettingsFeedExistingConsumers() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "recovery306-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let metadata = EnvVarEntry(name: "RECOVERY_PROVIDER", value: "synthetic-public-placeholder",
            baseURL: "https://recovery306.invalid/v1", modelNames: ["recovery306-model"])
        try JSONEncoder().encode([metadata]).write(to: providers.appendingPathComponent(EnvVarStore.fileName))
        let first = center(root)
        first.defaultProviderID = "custom.RECOVERY_PROVIDER"
        first.defaultModelID = "recovery306-model"
        first.themePreset = .light
        let binding = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
        #expect(ShortcutStore(defaults: defaults).setBinding(binding, for: .createPipeline) == nil)

        // Rebuild both persisted dependencies instead of observing the writer.
        let reopened = center(root)
        #expect(reopened.defaultProviderID == "custom.RECOVERY_PROVIDER")
        #expect(reopened.defaultModelID == "recovery306-model")
        #expect(reopened.providerRecords.map(\.name) == [metadata.name])
        #expect(reopened.providerRecords.first?.baseURL == metadata.baseURL)
        #expect(reopened.themePreset == .light)
        #expect(ThemeTokenProvider(center: reopened).mode == .light)
        #expect(ThemeTokenProvider(center: reopened).tokens.background
            == ThemePreset.light.semanticTokens(systemIsDark: false)?.background)
        #expect(ShortcutStore(defaults: defaults).binding(for: .createPipeline) == binding)
        let chat = ChatStore(preferencesDefaults: defaults, logManager: reopened.logManager)
        chat.providerRecordsSource = { reopened.providerRecords }
        #expect(chat.applyDefaultProviderModel(general: reopened.settings.general))
        #expect(chat.selectedCustomProvider?.name == metadata.name)
        #expect(chat.selectedModelID == "recovery306-model")

        // Production's cold readiness gate is still authoritative after reopen.
        let gated = ChatStore(
            providerReadinessStore: reopened.providerReadinessStore,
            preferencesDefaults: defaults, logManager: reopened.logManager
        )
        gated.providerRecordsSource = { reopened.providerRecords }
        #expect(!gated.applyDefaultProviderModel(general: reopened.settings.general))
        #expect(gated.selectedProviderType == nil)
        #expect(gated.selectedCustomProvider == nil)
        #expect(reopened.defaultProviderID == "custom.RECOVERY_PROVIDER")
    }

    @Test("a persisted memory toggle controls the first new request after store reopen")
    func restoredMemoryToggleFeedsNewRequest() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "recovery306-memory-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = center(root)
        let session = UUID()
        let scope = MemoryScope(sessionID: session.uuidString, projectID: "recovery306-project")
        try first.memoryStore.addFact("用户喜欢晴天，讨厌下雨天", sourceSessionID: session.uuidString, memoryScope: scope)
        try first.sessionStore.updateSession(ChatThread(id: session, title: "synthetic recovery").asPersisted())

        for enabled in [false, true] {
            first.memoryEnabled = enabled
            let reopened = center(root)
            #expect(reopened.memoryEnabled == enabled)
            let chat = ChatStore(preferencesDefaults: defaults, logManager: reopened.logManager)
            #expect(chat.attachPersistence(reopened.sessionStore))
            chat.switchSession(id: session)
            chat.setProject(.init(id: scope.projectID, name: "Synthetic", workingDirectory: root.path), forSession: session)
            chat.memoryEnabledProvider = { reopened.memoryEnabled }
            chat.memoryInjector = MemoryInjector(store: reopened.memoryStore)
            let engine = U4SystemPromptRecordingEngine()
            chat.agentEngine = engine
            chat.streamingProviderOverride = MockProvider.shared
            chat.configureComposerPolicy(ComposerPolicyFactSource(
                knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
                workspaceID: chat.composerWorkspaceID, revision: "recovery306-policy",
                grantEpoch: "recovery306-epoch", leaseID: "recovery306-lease",
                expiresAt: Date().addingTimeInterval(300)
            ))
            chat.draftText = "今天天气是晴天吗？"
            chat.sendDraft()
            let deadline = ContinuousClock.now + .seconds(5)
            while (engine.systemPrompts.isEmpty || chat.isStreaming) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!chat.isStreaming, "A timed-out fake turn must fail the assertion")
            let prompt = try #require(engine.systemPrompts.last)
            #expect(prompt.contains("用户喜欢晴天，讨厌下雨天") == enabled)
        }
    }

    @Test("reopened skill enablement is consumed by the first canonical turn snapshot")
    func restoredSkillToggleFeedsCanonicalTurn() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "recovery306-skill-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = center(root)
        let imported = try first.skillStore.importSkillThroughLifecycle(
            content: """
            ---
            name: recovery306-skill
            description: recovery306-skill restart fixture
            version: 1
            ---
            recovery306 canonical skill body
            """,
            source: .file, reason: "synthetic persisted recovery fixture",
            approval: SkillApproval(approverID: "recovery306-test")
        )
        let stateURL = root.appendingPathComponent("skills-enabled.json")
        let facade = SkillsStore(appStore: first.skillStore, stateFileURL: stateURL)
        for enabled in [false, true] {
            guard case .success = facade.setEnabled("app:\(imported.skill.id)", enabled: enabled) else {
                Issue.record("Synthetic toggle did not persist")
                return
            }
            let reopened = center(root)
            let reopenedFacade = SkillsStore(appStore: reopened.skillStore, stateFileURL: stateURL)
            #expect(reopenedFacade.isEnabled("app:\(imported.skill.id)") == enabled)
            #expect(reopened.skillStore.lifecycleReceipt(for: imported.skill.id)?.contentHash == imported.receipt.contentHash)
            let bridge = BridgeStore(
                shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
                logManager: reopened.logManager,
                sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("sessions")),
                canvasFeatureLane: .phase3NonCanvas
            )
            bridge.attachProductionServices(
                sessionDirectory: root.appendingPathComponent("sessions"),
                mcpManager: reopened.mcpManager, skillStore: reopened.skillStore,
                externalNetworkAllowed: false
            )
            let factory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
            let pending = factory(AgentTurnIdentity(sessionID: "recovery306", turnID: 1, messageID: "reopened"), MockProvider.shared)
            let turn = try #require(await pending.preparedForExecution())
            let skills = try #require(turn.skillInjector)
            let injection = skills.buildInjection(for: "recovery306-skill", selectedSkillIDs: [imported.skill.id])
            // Explicit selection remains auditable when the persisted toggle
            // disables injection; absence of a fragment is not absence of a receipt.
            #expect(injection.receipts.count == 1)
            let receipt = try #require(injection.receipts.first)
            #expect(receipt.skillID == imported.skill.id)
            #expect(receipt.version == imported.skill.version)
            #expect(receipt.contentHash == imported.receipt.contentHash)
            #expect(receipt.sourceIdentity == SkillInjectionReceipt.expectedSourceIdentity(
                skillID: imported.skill.id, contentHash: imported.receipt.contentHash
            ))
            if enabled {
                #expect(injection.fragment?.contains("recovery306 canonical skill body") == true)
                #expect(receipt.state == .active)
                #expect(receipt.omittedReason == nil)
                #expect(receipt.injected)
                #expect(receipt.injectedCharacters > 0)
            } else {
                #expect(injection.fragment == nil)
                #expect(receipt.state == .rejected)
                #expect(receipt.omittedReason == SkillRegistryRejection.inactiveReceipt.rawValue)
                #expect(receipt.injectedCharacters == 0)
                #expect(receipt.skipped)
                #expect(!injection.receipts.contains { $0.injected })
            }
        }
    }
}
