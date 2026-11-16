import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// Goal18 CHILD-DELETE-AUTO production entry: Settings -> Agent switch + whitelist.
// Every path below lives in a per-test temporary directory. Nothing here reads
// the user's real settings, Keychain or test-user directories.

@Suite("Goal18 child deletion auto review settings entry")
@MainActor
struct Goal18ChildDeletionAutoReviewSettingsTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("goal18-delete-auto-settings-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCenter(at root: URL, profile: RuntimeIsolationProfile? = nil) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: profile?.settingsDirectory ?? root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: profile?.sessionDirectory ?? root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain)
        )
    }

    private func makeDirectory(_ name: String, under root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Exercise the actual private browser wrapper through its production gate;
    /// no visibility change or standalone replacement delegate is needed.
    private func expectProductionBrowserDemand(_ bridge: BridgeStore, enabled: Bool) throws {
        try #require(bridge.productionBrowserTool != nil)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let delegate = try #require(engine.loop.approvalGate?.delegate)
        #expect(!(delegate is ChildDeletionApprovalDelegate))
        let demand = try #require(delegate as? any ChildDeletionReviewPreparationDemand)
        #expect(demand.requiresDeletionPreparation == enabled)
    }

    // MARK: SettingsCenter owner

    @Test func freshCenterIsOffAndEmptyAndDerivesADisabledConfiguration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(at: root)
        #expect(!center.childDeletionAutoReviewEnabled)
        #expect(center.childDeletionAutoReviewWhitelist.isEmpty)
        let configuration = ChildDeletionReviewSettings.configuration(from: center.settings.agent)
        #expect(!configuration.enabled)
        #expect(configuration.whitelistDirectories.isEmpty)
    }

    @Test func userSwitchAndWhitelistPersistAsCanonicalRealPathsAndRebindNewAttachments() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(at: root)
        var rebindCount = 0
        center.onFileAccessSettingsChanged = { rebindCount += 1 }

        let real = try makeDirectory("real", under: root)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let file = root.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)

        let canonicalReal = try #require(ChildDeletionReviewSettings.canonicalDirectory(real))
        #expect(center.addChildDeletionAutoReviewDirectory(link) == .added(canonicalReal))
        #expect(center.childDeletionAutoReviewWhitelist == [canonicalReal])
        #expect(rebindCount == 1)
        #expect(center.addChildDeletionAutoReviewDirectory(real) == .alreadyPresent(canonicalReal))
        #expect(center.addChildDeletionAutoReviewDirectory(file) == .notADirectory)
        #expect(center.addChildDeletionAutoReviewDirectory(root.appendingPathComponent("absent")) == .notADirectory)
        #expect(center.addChildDeletionAutoReviewDirectory(URL(fileURLWithPath: "/")) == .notADirectory)
        #expect(rebindCount == 1)

        // Broad / protected directories are refused with a reason and change nothing.
        for broad in [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                      URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).deletingLastPathComponent(),
                      URL(fileURLWithPath: "/usr", isDirectory: true),
                      URL(fileURLWithPath: "/Applications", isDirectory: true)] {
            guard case .tooBroad(let reason) = center.addChildDeletionAutoReviewDirectory(broad) else {
                Issue.record("\(broad.path) should be refused as too broad")
                continue
            }
            #expect(!reason.isEmpty)
        }
        #expect(center.childDeletionAutoReviewWhitelist == [canonicalReal])
        #expect(rebindCount == 1)

        center.childDeletionAutoReviewEnabled = true
        try #require(center.lastPersistenceError == nil)
        #expect(rebindCount == 2)

        let persisted = SettingsStore(directory: center.settingsStore.directory).settings.agent
        #expect(persisted.childDeletionAutoReviewEnabled)
        #expect(persisted.childDeletionAutoReviewWhitelist == [canonicalReal])
        let configuration = ChildDeletionReviewSettings.configuration(from: persisted)
        #expect(configuration.enabled)
        #expect(configuration.whitelistDirectories.map(\.path) == [canonicalReal])

        #expect(center.removeChildDeletionAutoReviewDirectory(canonicalReal))
        #expect(!center.removeChildDeletionAutoReviewDirectory(canonicalReal))
        #expect(center.childDeletionAutoReviewWhitelist.isEmpty)
        #expect(rebindCount == 3)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings.agent
            .childDeletionAutoReviewWhitelist.isEmpty)
    }

    @Test func whitelistLimitIsEnforcedByTheOwner() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(at: root)
        for index in 0..<ChildDeletionReviewSettings.maxWhitelistDirectories {
            let directory = try makeDirectory("dir-\(index)", under: root)
            guard case .added = center.addChildDeletionAutoReviewDirectory(directory) else {
                Issue.record("expected directory \(index) to be added")
                return
            }
        }
        let extra = try makeDirectory("one-too-many", under: root)
        #expect(center.addChildDeletionAutoReviewDirectory(extra) == .limitReached)
        #expect(center.childDeletionAutoReviewWhitelist.count == ChildDeletionReviewSettings.maxWhitelistDirectories)
    }

    @Test func resetToDefaultsTurnsItOffAndClearsTheWhitelist() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(at: root)
        let directory = try makeDirectory("covered", under: root)
        center.addChildDeletionAutoReviewDirectory(directory)
        center.childDeletionAutoReviewEnabled = true
        try #require(center.childDeletionAutoReviewEnabled && !center.childDeletionAutoReviewWhitelist.isEmpty)
        center.resetToDefaults()
        #expect(!center.childDeletionAutoReviewEnabled)
        #expect(center.childDeletionAutoReviewWhitelist.isEmpty)
        let persisted = SettingsStore(directory: center.settingsStore.directory).settings.agent
        #expect(!persisted.childDeletionAutoReviewEnabled)
        #expect(persisted.childDeletionAutoReviewWhitelist.isEmpty)
    }

    // MARK: model settings tool cannot touch the two fields

    @Test func modelSettingsCatalogHasNoKeyForEitherField() {
        let ids = BL6SettingsCatalog.production.entries.map(\.id)
        #expect(!ids.contains { $0.contains("deletion") })
        for key in ["agent.child-deletion-auto-review-enabled", "agent.child-deletion-auto-review-whitelist",
                    "agent.childDeletionAutoReviewEnabled", "agent.childDeletionAutoReviewWhitelist"] {
            #expect(throws: (any Error).self) {
                try BL6SettingsCatalog.production.validateApprovedMutation(changedKeys: [key])
            }
        }
    }

    @Test func modelDispatchCannotChangeEitherFieldAndLeavesBothUntouchedByApplyAndReset() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(at: root)
        let covered = try makeDirectory("covered", under: root)
        let attacker = try makeDirectory("attacker", under: root)
        let canonicalCovered = try #require(ChildDeletionReviewSettings.canonicalDirectory(covered))

        func approved(_ id: String, _ operation: BL6SettingsOperation = .apply,
                      changes: [String: BL6SettingValue] = [:], revision: String) -> BL6SettingsIntent {
            BL6SettingsIntent(requestID: id, operation: operation, changes: changes,
                expectedRevision: revision, approval: .approved(receiptID: "approval-" + id))
        }

        // Default state: a model-proposed enable/whitelist is rejected and nothing changes.
        var snapshot = try #require(center.bl6EffectiveSettingsSnapshot)
        for (index, change) in [
            ["agent.child-deletion-auto-review-enabled": BL6SettingValue.toggle(true)],
            ["agent.child-deletion-auto-review-whitelist": BL6SettingValue.list([attacker.path])],
            ["agent.childDeletionAutoReviewEnabled": BL6SettingValue.toggle(true)]
        ].enumerated() {
            let result = center.dispatchBL6Settings(approved("deny-\(index)", changes: change, revision: snapshot.catalogRevision))
            guard case .failure = result else {
                Issue.record("model change \(change.keys) must be rejected, got \(result)")
                continue
            }
        }
        #expect(!center.childDeletionAutoReviewEnabled)
        #expect(center.childDeletionAutoReviewWhitelist.isEmpty)
        #expect(!center.settings.agent.childDeletionAutoReviewEnabled)

        // User opts in; an unrelated model apply and a model reset must keep the user's choice.
        center.addChildDeletionAutoReviewDirectory(covered)
        center.childDeletionAutoReviewEnabled = true
        try #require(center.lastPersistenceError == nil)
        snapshot = try #require(center.bl6EffectiveSettingsSnapshot)
        guard case .success = center.dispatchBL6Settings(approved("unrelated", changes: ["general.language": .text("en")],
            revision: snapshot.catalogRevision)) else {
            Issue.record("unrelated approved apply should succeed")
            return
        }
        #expect(center.childDeletionAutoReviewEnabled)
        #expect(center.childDeletionAutoReviewWhitelist == [canonicalCovered])
        snapshot = try #require(center.bl6EffectiveSettingsSnapshot)
        guard case .success = center.dispatchBL6Settings(approved("reset", .reset, revision: snapshot.catalogRevision)) else {
            Issue.record("model reset of catalogued settings should succeed")
            return
        }
        #expect(center.childDeletionAutoReviewEnabled)
        #expect(center.childDeletionAutoReviewWhitelist == [canonicalCovered])
        let persisted = SettingsStore(directory: center.settingsStore.directory).settings.agent
        #expect(persisted.childDeletionAutoReviewEnabled)
        #expect(persisted.childDeletionAutoReviewWhitelist == [canonicalCovered])
    }

    // MARK: production composition

    @Test func disposableProfilesIgnoreUserChosenPathsButNormalProfilesUseThem() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let covered = try makeDirectory("covered", under: root)
        let canonical = try #require(ChildDeletionReviewSettings.canonicalDirectory(covered))
        let agent = AgentSettings(childDeletionAutoReviewEnabled: true, childDeletionAutoReviewWhitelist: [canonical])

        let normal = ProductionOrchestrationDefaults.childDeletionReviewConfiguration(
            agent: agent, profileIsDisposable: false)
        #expect(normal.enabled)
        #expect(normal.whitelistDirectories.map(\.path) == [canonical])

        let disposable = ProductionOrchestrationDefaults.childDeletionReviewConfiguration(
            agent: agent, profileIsDisposable: true)
        #expect(!disposable.enabled)
        #expect(disposable.whitelistDirectories.isEmpty)

        let off = ProductionOrchestrationDefaults.childDeletionReviewConfiguration(
            agent: .default, profileIsDisposable: false)
        #expect(!off.enabled)
        #expect(off.whitelistDirectories.isEmpty)
    }

    @Test(arguments: [false, true])
    func isolatedOwnedSettingsRebindDefaultOnOffImportAndRejectForeignRoots(journey: Bool) async throws {
        let requestedRoot = try makeRoot()
        let arguments = ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument]
            + (journey ? [DeepSeekEnvironmentPackageFieldBootstrap.journeyArgument] : [])
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "G1Explicit", processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: requestedRoot.path],
            processArguments: arguments, canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let workspace = try makeDirectory("workspace", under: root)
        let defaults = profile.makeUserDefaults()
        let center = makeCenter(at: root, profile: profile)
        let bridge = try BridgeStore(taskStorePersistenceURL: root.appendingPathComponent("tasks.json"),
            preferencesDefaults: defaults, logManager: profile.makeLogManager(),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            sessionStore: center.sessionStore, memoryStore: center.memoryStore,
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory),
            canvasFeatureLane: .phase3NonCanvas)
        defer {
            bridge.chat.stopAllStreamingForSafety()
            if let suite = profile.userDefaultsSuiteName { defaults.removePersistentDomain(forName: suite) }
            try? profile.cleanupDisposableRoots()
        }
        ProductionOrchestrationDefaults.bindFileAccessSettings(
            to: bridge, settings: center, profile: profile, arguments: arguments)
        try #require(center.onFileAccessSettingsChanged != nil)
        await ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: center, profile: profile,
            childConcurrencySelection: center.childConcurrencySelection, arguments: arguments).value
        let executor = try #require(bridge.productionBuiltinToolExecutor)
        #expect(executor.allowedRoot.path == (journey ? workspace : root).standardizedFileURL.path)
        #expect(executor.additionalAllowedRoots.isEmpty)
        #expect(bridge.productionChildDeletionReviewConfiguration?.enabled == false)
        #expect(!bridge.productionExternalNetworkAllowed)
        try expectProductionBrowserDemand(bridge, enabled: false)

        let covered = try makeDirectory("covered", under: workspace)
        let canonical = try #require(ChildDeletionReviewSettings.canonicalDirectory(covered))
        #expect(center.addChildDeletionAutoReviewDirectory(covered) == .added(canonical))
        center.childDeletionAutoReviewEnabled = true
        await bridge.lastChildGovernorSafetyTask?.value
        let active = try #require(bridge.productionChildDeletionReviewConfiguration)
        #expect(active.enabled == journey)
        #expect(active.whitelistDirectories.map(\.path) == (journey ? [canonical] : []))
        #expect(!bridge.productionExternalNetworkAllowed)
        try expectProductionBrowserDemand(bridge, enabled: journey)

        let foreignRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreign = try makeDirectory("foreign", under: foreignRoot)
        let foreignPath = try #require(ChildDeletionReviewSettings.canonicalDirectory(foreign))
        #expect(center.addChildDeletionAutoReviewDirectory(foreign) == .added(foreignPath))
        await bridge.lastChildGovernorSafetyTask?.value
        // The profile root contains settings and credentials. Even an explicit
        // whitelist of that broader owned root must not reach the reviewer.
        let profileRootPath = try #require(ChildDeletionReviewSettings.canonicalDirectory(root))
        #expect(center.addChildDeletionAutoReviewDirectory(root) == .added(profileRootPath))
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.productionChildDeletionReviewConfiguration?.whitelistDirectories.map(\.path)
            == (journey ? [canonical] : []))
        let foreignCenter = makeCenter(at: foreignRoot)
        #expect(!ProductionOrchestrationDefaults.isolatedDeletionSettingsAreOwned(foreignCenter, profile: profile))

        // Export the ON setting, then import through the real SettingsCenter
        // consumer: N1 keeps the local value, so import neither enables nor revokes it.
        let snapshot = try center.syncManager.exportSnapshot(scopes: [.settings])
        let backup = root.appendingPathComponent("g1-backup.json")
        try snapshot.write(to: backup)
        center.childDeletionAutoReviewEnabled = false
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.productionChildDeletionReviewConfiguration?.enabled == false)
        try expectProductionBrowserDemand(bridge, enabled: false)
        // Local OFF + imported ON snapshot: import must not turn it on.
        #expect(!center.importBackup(from: backup).isError)
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(!center.childDeletionAutoReviewEnabled)
        #expect(bridge.productionChildDeletionReviewConfiguration?.enabled == false)
        center.childDeletionAutoReviewEnabled = true
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.productionChildDeletionReviewConfiguration?.enabled == journey)
        // Local ON + imported ON snapshot: still ON, local whitelist kept.
        #expect(!center.importBackup(from: backup).isError)
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(center.childDeletionAutoReviewEnabled)
        #expect(bridge.productionChildDeletionReviewConfiguration?.enabled == journey)
        #expect(bridge.productionChildDeletionReviewConfiguration?.whitelistDirectories.map(\.path)
            == (journey ? [canonical] : []))
    }

    @Test func importNeverChangesLocalChildDeletionReviewOrRebinds() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(at: root)
        let source = makeCenter(at: try makeDirectory("source", under: root))
        source.language = "en"
        let covered = try makeDirectory("imported-whitelist", under: root)
        let canonical = try #require(ChildDeletionReviewSettings.canonicalDirectory(covered))
        #expect(source.addChildDeletionAutoReviewDirectory(covered) == .added(canonical))
        let backup = root.appendingPathComponent("g1-off-backup.json")
        try source.syncManager.exportSnapshot(scopes: [.settings]).write(to: backup)
        var rebinds = 0
        center.onFileAccessSettingsChanged = { rebinds += 1 }
        #expect(!center.importBackup(from: backup).isError)
        #expect(center.language == "en")
        #expect(!center.childDeletionAutoReviewEnabled)
        #expect(center.childDeletionAutoReviewWhitelist.isEmpty)
        #expect(rebinds == 0)
        center.childDeletionAutoReviewEnabled = true
        #expect(rebinds == 1)
        #expect(!center.importBackup(from: backup).isError)
        #expect(center.childDeletionAutoReviewEnabled)
        #expect(rebinds == 1)
        #expect(!center.importBackup(from: backup).isError)
        #expect(rebinds == 1)
    }

    @Test func bridgeStoreBuildsTheReviewerFromTheSettingsDerivedConfiguration() async throws {
        let root = try makeRoot()
        let suite = "goal18-delete-auto-settings." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let bridge = try BridgeStore(taskStorePersistenceURL: root.appendingPathComponent("tasks.json"),
            preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory), sessionStore: sessions,
            memoryStore: memory, providerReadinessStore: readiness, canvasFeatureLane: .phase3NonCanvas)
        defer {
            bridge.chat.stopAllStreamingForSafety()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let covered = try makeDirectory("covered", under: root)
        let canonical = try #require(ChildDeletionReviewSettings.canonicalDirectory(covered))
        let on = AgentSettings(childDeletionAutoReviewEnabled: true, childDeletionAutoReviewWhitelist: [canonical])

        await bridge.attachProductionServices(agentSettings: on,
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: sessions.directory,
            childDeletionReviewConfiguration: ChildDeletionReviewSettings.configuration(from: on),
            enableOrchestration: true, externalNetworkAllowed: true).value
        let enabled = try #require(bridge.productionChildDeletionReviewConfiguration)
        #expect(enabled.enabled)
        #expect(enabled.whitelistDirectories.map(\.path) == [canonical])

        // A later attachment built from the switched-off setting replaces it.
        let off = AgentSettings(childDeletionAutoReviewEnabled: false, childDeletionAutoReviewWhitelist: [canonical])
        await bridge.attachProductionServices(agentSettings: off,
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: sessions.directory,
            childDeletionReviewConfiguration: ChildDeletionReviewSettings.configuration(from: off),
            enableOrchestration: true, externalNetworkAllowed: true).value
        let disabled = try #require(bridge.productionChildDeletionReviewConfiguration)
        #expect(!disabled.enabled)
        #expect(disabled.whitelistDirectories.isEmpty)
    }

    @Test func attachWithoutAnExplicitConfigurationStaysOff() async throws {
        let root = try makeRoot()
        let suite = "goal18-delete-auto-settings." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let bridge = try BridgeStore(taskStorePersistenceURL: root.appendingPathComponent("tasks.json"),
            preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory), sessionStore: sessions,
            memoryStore: memory, providerReadinessStore: readiness, canvasFeatureLane: .phase3NonCanvas)
        defer {
            bridge.chat.stopAllStreamingForSafety()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await bridge.attachProductionServices(agentSettings: .default,
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: sessions.directory,
            enableOrchestration: true, externalNetworkAllowed: true).value
        let configuration = try #require(bridge.productionChildDeletionReviewConfiguration)
        #expect(!configuration.enabled)
        #expect(configuration.whitelistDirectories.isEmpty)
    }

    @Test func staleWhitelistEntriesAreReportedPerEntryAndDroppedFromTheConfiguration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(at: root)
        let keep = try makeDirectory("keep", under: root)
        let gone = try makeDirectory("gone", under: root)
        let keepPath = try #require(ChildDeletionReviewSettings.canonicalDirectory(keep))
        let gonePath = try #require(ChildDeletionReviewSettings.canonicalDirectory(gone))
        #expect(center.addChildDeletionAutoReviewDirectory(keep) == .added(keepPath))
        #expect(center.addChildDeletionAutoReviewDirectory(gone) == .added(gonePath))
        center.childDeletionAutoReviewEnabled = true
        try FileManager.default.removeItem(at: gone)

        #expect(center.childDeletionAutoReviewEntryStatus(keepPath) == .usable(keepPath))
        guard case .stale = center.childDeletionAutoReviewEntryStatus(gonePath) else {
            Issue.record("missing directory should be reported as stale")
            return
        }
        // The stale entry stays in the list so the user can remove it.
        #expect(center.childDeletionAutoReviewWhitelist == [keepPath, gonePath])
        let configuration = ChildDeletionReviewSettings.configuration(from: center.settings.agent)
        #expect(configuration.whitelistDirectories.map(\.path) == [keepPath])
        #expect(center.removeChildDeletionAutoReviewDirectory(gonePath))
        #expect(center.childDeletionAutoReviewWhitelist == [keepPath])
    }

}
