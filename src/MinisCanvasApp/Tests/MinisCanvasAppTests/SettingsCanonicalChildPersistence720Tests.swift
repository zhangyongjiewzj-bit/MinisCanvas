import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// D-SETA / D-SETB: ordinary settings writes reach the existing production
/// composition, while rejected writes cannot become a second runtime truth.
@Suite("Canonical child settings persistence boundary", .serialized)
@MainActor
struct SettingsCanonicalChildPersistence720Tests {
    private struct Fixture {
        let profile: RuntimeIsolationProfile
        let center: SettingsCenter
        let bridge: BridgeStore
    }

    private func makeFixture() throws -> Fixture {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "set720", canvasRuntimeState: .disabled
        )
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("set720-\(UUID().uuidString)")),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
        let bridge = BridgeStore(
            preferencesDefaults: profile.makeUserDefaults(),
            logManager: center.logManager,
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            memoryStore: center.memoryStore,
            canvasFeatureLane: .phase3NonCanvas
        )
        ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: center, profile: profile,
            childConcurrencySelection: center.childConcurrencySelection
        )
        ProductionOrchestrationDefaults.bindChildConcurrencySelection(
            to: bridge, settings: center, profile: profile
        )
        return Fixture(profile: profile, center: center, bridge: bridge)
    }

    @Test("save/reopen/reset use the production governor; invalid selections have no effect")
    func durableSelectionsReachRealGovernorAndReopen() async throws {
        let f = try makeFixture()
        f.center.childConcurrencyUserSelected = 8
        f.center.childConcurrencyEnabledSessionCount = 3
        f.center.childConcurrencyRiskAcknowledged = true
        // The retained governor reconfiguration commits asynchronously. Read
        // the actual production attachment only after its accepted task ends.
        await f.bridge.lastChildGovernorSafetyTask?.value
        let governor = try #require(f.bridge.orchestrationChildGovernor)
        #expect(await governor.globalBudget == 24)
        #expect(f.bridge.childConcurrencySelection.userSelected == 8)
        #expect(f.bridge.childConcurrencySelection.effective == 8)
        let url = f.center.settingsStore.directory.appendingPathComponent(SettingsStore.fileName)
        let before = try Data(contentsOf: url)
        f.center.childConcurrencyUserSelected = 41
        f.center.childConcurrencyEnabledSessionCount = 0
        #expect(f.bridge.orchestrationChildGovernor === governor)
        #expect(f.center.childConcurrencyRiskAcknowledged)
        #expect(try Data(contentsOf: url) == before)
        let reopened = SettingsStore(directory: f.center.settingsStore.directory)
        #expect(reopened.settings.agent.childConcurrencyUserSelected == 8)
        #expect(reopened.settings.agent.childConcurrencyEnabledSessionCount == 3)
        f.center.resetChildConcurrencyToDefaults()
        await f.bridge.lastChildGovernorSafetyTask?.value
        let resetGovernor = try #require(f.bridge.orchestrationChildGovernor)
        #expect(await resetGovernor.globalBudget == 4)
        #expect((try? f.bridge.childConcurrencySelection.withRuntime(nil)) == .default)
        #expect(!f.center.childConcurrencyRiskAcknowledged)
        #expect(SettingsStore(directory: f.center.settingsStore.directory).settings.agent.childConcurrencyUserSelected == 4)
        #expect(SettingsStore(directory: f.center.settingsStore.directory).settings.agent.childConcurrencyEnabledSessionCount == 1)
    }

    @Test("failed durable write cannot change live selection, acknowledgement or governor", arguments: ["selection", "sessions", "reset"])
    func rejectedWriteCannotPublishShadowSelection(operation: String) async throws {
        let f = try makeFixture()
        f.center.childConcurrencyUserSelected = 8
        f.center.childConcurrencyEnabledSessionCount = 3
        f.center.childConcurrencyRiskAcknowledged = true
        await f.bridge.lastChildGovernorSafetyTask?.value
        let governor = try #require(f.bridge.orchestrationChildGovernor)
        let selection = f.center.childConcurrencySelection
        let mirror = f.center.settingsMirror
        let directory = f.center.settingsStore.directory
        let url = directory.appendingPathComponent(SettingsStore.fileName)
        let before = try Data(contentsOf: url)
        // Owned fixture only: retain the real durable file and prevent its
        // atomic replacement. Restore permission even on an assertion error.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        switch operation {
        case "selection": f.center.childConcurrencyUserSelected = 12
        case "sessions": f.center.childConcurrencyEnabledSessionCount = 5
        default: f.center.resetChildConcurrencyToDefaults()
        }
        #expect(f.center.settingsStore.lastPersistenceError != nil)
        #expect(f.center.lastPersistenceError == f.center.settingsStore.lastPersistenceError)
        #expect(f.center.settingsMirror == mirror)
        #expect(f.center.settingsStore.settings == mirror)
        #expect(f.center.childConcurrencySelection == selection)
        #expect(f.center.childConcurrencyRiskAcknowledged)
        #expect(f.bridge.orchestrationChildGovernor === governor)
        #expect((try? f.bridge.childConcurrencySelection.withRuntime(nil)) == selection)
        #expect(await governor.globalBudget == 24)
        #expect(try Data(contentsOf: url) == before)
        #expect(SettingsStore(directory: directory).settings == mirror)
    }
}
