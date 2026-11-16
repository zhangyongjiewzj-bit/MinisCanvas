import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("D-ARCH1 App session store owner assembly", .serialized)
@MainActor
struct ProductionSessionStoreOwner1833Tests {
    private struct SimulatedLedgerFailure: Error {}

    private enum Route: CaseIterable {
        case primary, degraded, field
    }

    private func root() throws -> URL {
        try B1ARCHOriginalFixtureSupport.makeRoot("session1833")
    }

    private func settings(root: URL, sessions: SessionStore,
                          badges: SessionBadgeStore) throws -> SettingsCenter {
        let owned = try B1ARCHOriginalFixtureSupport.inputs(root)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"),
                                  keychain: keychain, privacyStore: EnvVarPrivacyStore(defaults: owned.defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions,
            sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"),
                                         keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(owned.defaultsSuite)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: ProviderReadinessStore(
                directory: root.appendingPathComponent("providers"))
        )
    }

    private func bridge(route: Route, root: URL, sessions: SessionStore,
                        badges: SessionBadgeStore) throws -> BridgeStore {
        let owned = try B1ARCHOriginalFixtureSupport.inputs(root)
        let defaults = owned.defaults
        let shortcuts = ShortcutStore(defaults: defaults)
        let logger = LogManager(directory: root.appendingPathComponent("bridge-logs"))
        let documents = SessionDocumentStore(directory: sessions.directory)
        let workflows = WorkflowStore(storeDirectory: root.appendingPathComponent("workflows"))
        let result: BridgeStore
        switch route {
        case .primary:
            result = try BridgeStore(
                taskStorePersistenceURL: root.appendingPathComponent("agent-tasks.json"),
                shortcutStore: shortcuts, preferencesDefaults: defaults,
                settingsCatalogSkillsStore: owned.catalog, settingsCatalogSchedulerStore: owned.scheduler,
                logManager: logger, workflowStore: workflows,
                sessionBadgeStore: badges, sessionDocumentStore: documents,
                sessionStore: sessions, memoryStore: owned.memory,
                commandEnvStore: owned.env, canonicalMCPManager: owned.mcp,
                providerReadinessStore: owned.readiness, canvasFeatureLane: .phase3NonCanvas)
        case .degraded:
            result = AppLaunchCoordinator.resolve(
                primary: { throw SimulatedLedgerFailure() },
                degraded: {
                    BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
                        settingsCatalogSkillsStore: owned.catalog, settingsCatalogSchedulerStore: owned.scheduler,
                        logManager: logger, workflowStore: workflows,
                        sessionBadgeStore: badges, sessionDocumentStore: documents,
                        sessionStore: sessions, agentTaskStore: owned.tasks, contextManifestStore: owned.context,
                memoryStore: owned.memory,
                commandEnvStore: owned.env, canonicalMCPManager: owned.mcp,
                providerReadinessStore: owned.readiness, canvasFeatureLane: .phase3NonCanvas)
                })
        case .field:
            result = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
                settingsCatalogSkillsStore: owned.catalog, settingsCatalogSchedulerStore: owned.scheduler,
                logManager: logger, workflowStore: workflows,
                sessionBadgeStore: badges, sessionDocumentStore: documents,
                sessionStore: sessions, agentTaskStore: owned.tasks, contextManifestStore: owned.context,
                memoryStore: owned.memory,
                commandEnvStore: owned.env, canonicalMCPManager: owned.mcp,
                providerReadinessStore: owned.readiness, canvasFeatureLane: .phase3NonCanvas)
            try #require(result.chat.attachPersistence(sessions, badgeStore: badges))
        }
        return result
    }

    @Test("ordinary, degraded and field routes keep Settings, Chat and Task Center on root A")
    func allLaunchRoutesKeepOneSessionStore() async throws {
        for route in Route.allCases {
            let base = try root()
            defer { B1ARCHOriginalFixtureSupport.cleanupRoot(base) }
            let sessions = SessionStore(directory: base.appendingPathComponent("sessions"))
            let badges = SessionBadgeStore(directory: base.appendingPathComponent("badges"))
            let center = try settings(root: base, sessions: sessions, badges: badges)
            let bridge = try bridge(route: route, root: base, sessions: sessions, badges: badges)
            #expect(bridge.bindConfirmedSessionDeletionProjection(to: center))
            await bridge.attachProductionServices(fileAccessAllowedRoot: base,
                sessionDirectory: sessions.directory,
                mcpManager: try B1ARCHOriginalFixtureSupport.inputs(base).mcp,
                skillStore: try B1ARCHOriginalFixtureSupport.inputs(base).skills,
                externalNetworkAllowed: false,
                sessionReadSecretStore: try B1ARCHOriginalFixtureSupport.inputs(base).env).value

            #expect(center.sessionStore === sessions)
            #expect(bridge.chat.sessionStore === sessions)
            #expect(bridge.chat.sessionManager?.store === sessions)
            #expect(bridge.taskCenterControlConsumer.sharesChildTranscriptSessionStore(sessions))
            #expect(bridge.chat.sessionStore?.directory == center.sessionStore.directory)
        }
    }

    @Test("an injected owner refuses another production session directory")
    func mismatchedDirectoryCannotCreateAnotherWriter() async throws {
        let base = try root()
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(base) }
        let sessions = SessionStore(directory: base.appendingPathComponent("sessions"))
        let bridge = try bridge(route: .degraded, root: base, sessions: sessions,
            badges: SessionBadgeStore(directory: base.appendingPathComponent("badges")))
        await bridge.attachProductionServices(fileAccessAllowedRoot: base,
            sessionDirectory: base.appendingPathComponent("other-sessions"),
            mcpManager: try B1ARCHOriginalFixtureSupport.inputs(base).mcp,
            skillStore: try B1ARCHOriginalFixtureSupport.inputs(base).skills,
            externalNetworkAllowed: false,
            sessionReadSecretStore: try B1ARCHOriginalFixtureSupport.inputs(base).env).value
        #expect(bridge.chat.sessionStore == nil)
        #expect(!bridge.taskCenterControlConsumer.sharesChildTranscriptSessionStore(sessions))
    }

    @Test("confirmed Settings retention and subsequent Chat update retain canonical outcomes")
    func settingsCleanupThenChatWriteDoesNotLoseEitherOutcome() async throws {
        let base = try root()
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(base) }
        let sessions = SessionStore(directory: base.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: base.appendingPathComponent("badges"))
        var expired = try sessions.createSession(id: UUID().uuidString, title: "expired")
        expired.updatedAt = Date().addingTimeInterval(-90 * 86_400)
        try sessions.updateSession(expired)
        let fresh = try sessions.createSession(id: UUID().uuidString, title: "fresh")
        let center = try settings(root: base, sessions: sessions, badges: badges)
        let bridge = try bridge(route: .primary, root: base, sessions: sessions, badges: badges)
        #expect(bridge.bindConfirmedSessionDeletionProjection(to: center))
        await bridge.attachProductionServices(fileAccessAllowedRoot: base,
            sessionDirectory: sessions.directory,
                mcpManager: try B1ARCHOriginalFixtureSupport.inputs(base).mcp,
                skillStore: try B1ARCHOriginalFixtureSupport.inputs(base).skills,
                externalNetworkAllowed: false,
                sessionReadSecretStore: try B1ARCHOriginalFixtureSupport.inputs(base).env).value
        #expect(bridge.chat.sessionStore === center.sessionStore)
        center.sessionRetentionDays = 30
        center.reloadStorage()
        let preview = try center.previewSessionsOlderThanRetention()
        #expect(preview.affectedCount == 1)
        let confirmed = preview.withFirstConfirmation("已核对预览")
            .withSecondConfirmation("永久删除")
        let receipt = try center.deleteSessionsOlderThanRetention(intent: confirmed)
        #expect(receipt.affectedCount == 1)
        #expect(sessions.loadSession(id: expired.id) == nil)
        let expiredID = try #require(UUID(uuidString: expired.id))
        #expect(!bridge.chat.sessions.contains(where: { $0.id == expiredID }))
        #expect(!bridge.chat.applySwitchSession(id: expiredID))

        let freshID = try #require(UUID(uuidString: fresh.id))
        #expect(bridge.chat.applySwitchSession(id: freshID))
        bridge.chat.appendUser("合成会话更新")
        #expect(sessions.loadSession(id: fresh.id)?.messages.last?.content == "合成会话更新")
        #expect(sessions.loadSession(id: expired.id) == nil,
                "confirmed Settings cleanup must not be resurrected by Chat full sync")
    }

    @Test("single confirmed Settings deletion retires Chat projection; rejected intent does not notify")
    func confirmedSingleDeletionOnlyNotifiesOnSuccess() async throws {
        let base = try root()
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(base) }
        let sessions = SessionStore(directory: base.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: base.appendingPathComponent("badges"))
        let doomed = try sessions.createSession(id: UUID().uuidString, title: "doomed")
        let fresh = try sessions.createSession(id: UUID().uuidString, title: "fresh")
        let center = try settings(root: base, sessions: sessions, badges: badges)
        let bridge = try bridge(route: .primary, root: base, sessions: sessions, badges: badges)
        #expect(bridge.bindConfirmedSessionDeletionProjection(to: center))
        await bridge.attachProductionServices(fileAccessAllowedRoot: base,
            sessionDirectory: sessions.directory,
                mcpManager: try B1ARCHOriginalFixtureSupport.inputs(base).mcp,
                skillStore: try B1ARCHOriginalFixtureSupport.inputs(base).skills,
                externalNetworkAllowed: false,
                sessionReadSecretStore: try B1ARCHOriginalFixtureSupport.inputs(base).env).value

        let binding = try #require(center.onConfirmedSessionDeletion)
        var notifications: [[String]] = []
        center.onConfirmedSessionDeletion = { ids in
            notifications.append(ids)
            binding(ids)
        }
        let preview = try center.previewSessionDeletion(id: doomed.id)
        #expect(throws: Error.self) {
            _ = try center.deleteSession(id: doomed.id,
                intent: preview.withFirstConfirmation("已核对预览"))
        }
        #expect(notifications.isEmpty)
        #expect(sessions.loadSession(id: doomed.id) != nil)
        let doomedID = try #require(UUID(uuidString: doomed.id))
        #expect(bridge.chat.sessions.contains(where: { $0.id == doomedID }))
        let staleRollback = bridge.chat.captureSessionActionState()

        let confirmed = preview.withFirstConfirmation("已核对预览")
            .withSecondConfirmation("确认将会话移入回收站")
        _ = try center.deleteSession(id: doomed.id, intent: confirmed)
        #expect(notifications == [[doomed.id]])
        #expect(!bridge.chat.sessions.contains(where: { $0.id == doomedID }))
        #expect(!bridge.chat.applySwitchSession(id: doomedID))
        bridge.chat.restoreSessionActionState(staleRollback)
        #expect(!bridge.chat.sessions.contains(where: { $0.id == doomedID }))
        let freshID = try #require(UUID(uuidString: fresh.id))
        #expect(bridge.chat.applySwitchSession(id: freshID))
        bridge.chat.appendUser("合法会话更新")
        #expect(sessions.loadSession(id: fresh.id)?.messages.last?.content == "合法会话更新")
        #expect(sessions.loadSession(id: doomed.id) == nil)
    }
}
