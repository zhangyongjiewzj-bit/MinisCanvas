import Foundation
import MinisCore

/// The App's original domain construction seam, callable without installing
/// the App's window, event monitors or permission surfaces. The only readiness
/// source supplied to a Bridge is the exact SettingsCenter-owned object.
@MainActor
enum ProductionDomainAssembly {
    static func makeSettings(
        profile: RuntimeIsolationProfile,
        keychain: KeychainStore,
        sessionStore: SessionStore,
        sessionBadgeStore: SessionBadgeStore,
        logManager: LogManager,
        store: ShortcutStore,
        readinessTransport: (any SettingsProviderReadinessTransport)?,
        providerReadinessStore: ProviderReadinessStore,
        fieldEnvironmentStore: EnvVarStore? = nil
    ) -> SettingsCenter {
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: fieldEnvironmentStore ?? profile.makeEnvironmentStore(keychain: keychain),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.memoryDirectory),
            sessionStore: sessionStore,
            sessionBadgeStore: sessionBadgeStore,
            logManager: logManager,
            mcpManager: MCPServerManager(
                fileURL: profile.mcpConfigurationURL,
                keychain: keychain
            ),
            skillStore: SkillStore.startForAppBootstrap(
                skillsRoot: profile.minisCoreDirectory.appendingPathComponent(
                    "skills",
                    isDirectory: true
                )
            ),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            shortcutStore: store,
            providerReadinessTransport: readinessTransport,
            providerReadinessStore: providerReadinessStore
        )
        return settings
    }

    static func makeBridge(
        profile: RuntimeIsolationProfile,
        bootstrapFailure: RuntimeIsolationProfile.BootstrapFailure?,
        settings: SettingsCenter,
        store: ShortcutStore,
        defaults: UserDefaults,
        skillsStore: SkillsStore,
        schedulerStore: SchedulerTaskStore,
        logManager: LogManager,
        workflowStore: WorkflowStore,
        sessionBadgeStore: SessionBadgeStore,
        sessionStore: SessionStore,
        onPrimaryComposed: (() -> Void)? = nil
    ) -> BridgeStore {
        let providerReadinessStore = settings.providerReadinessStore
        let bridge: BridgeStore = if bootstrapFailure == nil {
            AppLaunchCoordinator.resolve(
                primary: {
                    let primary = try BridgeStore(
                        taskStorePersistenceURL: profile.agentTaskStorePersistenceURL,
                        shortcutStore: store,
                        preferencesDefaults: defaults,
                        settingsCatalogSkillsStore: skillsStore,
                        settingsCatalogSchedulerStore: schedulerStore,
                        logManager: logManager,
                        workflowStore: workflowStore,
                        sessionBadgeStore: sessionBadgeStore,
                        canvasRuntimeState: profile.canvasRuntimeState,
                        sessionDocumentStore: SessionDocumentStore(
                            directory: profile.sessionDirectory
                        ),
                        sessionStore: sessionStore,
                        memoryStore: settings.memoryStore,
                        memoryProposalConsumer: settings.memoryProposalConsumer,
                        commandEnvStore: settings.envStore,
                        canonicalMCPManager: settings.mcpManager,
                        providerReadinessStore: providerReadinessStore,
                        canvasFeatureLane: .phase3NonCanvas
                    )
                    onPrimaryComposed?()
                    return primary
                },
                degraded: {
                    BridgeStore(
                        shortcutStore: store,
                        preferencesDefaults: defaults,
                        settingsCatalogSkillsStore: skillsStore,
                        settingsCatalogSchedulerStore: schedulerStore,
                        logManager: logManager,
                        workflowStore: workflowStore,
                        sessionBadgeStore: sessionBadgeStore,
                        sessionDocumentStore: SessionDocumentStore(
                            directory: profile.sessionDirectory
                        ),
                        sessionStore: sessionStore,
                        canvasRuntimeState: profile.canvasRuntimeState,
                        memoryStore: settings.memoryStore,
                        memoryProposalConsumer: settings.memoryProposalConsumer,
                        commandEnvStore: settings.envStore,
                        canonicalMCPManager: settings.mcpManager,
                        providerReadinessStore: providerReadinessStore,
                        canvasFeatureLane: .phase3NonCanvas
                    )
                }
            )
        } else {
            // A bootstrap failure must not attempt the throwing persistent
            // ledger initializer. This constructor is fully disposable and
            // keeps all failure-mode state behind the blocker UI.
            BridgeStore(
                shortcutStore: store,
                preferencesDefaults: defaults,
                settingsCatalogSkillsStore: skillsStore,
                settingsCatalogSchedulerStore: schedulerStore,
                logManager: logManager,
                workflowStore: workflowStore,
                sessionBadgeStore: sessionBadgeStore,
                sessionDocumentStore: SessionDocumentStore(
                    directory: profile.sessionDirectory
                ),
                sessionStore: sessionStore,
                canvasRuntimeState: profile.canvasRuntimeState,
                memoryStore: settings.memoryStore,
                memoryProposalConsumer: settings.memoryProposalConsumer,
                commandEnvStore: settings.envStore,
                canonicalMCPManager: settings.mcpManager,
                providerReadinessStore: providerReadinessStore,
                canvasFeatureLane: .phase3NonCanvas
            )
        }
        return bridge
    }
}
