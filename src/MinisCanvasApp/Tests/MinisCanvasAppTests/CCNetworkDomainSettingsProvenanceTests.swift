import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("H05 network configuration provenance producer")
@MainActor struct CCNetworkDomainSettingsProvenanceTests {
    @Test func savedSettingsAttestOnlyTheExactCapturedDefaultsAndFailedSaveDoesNotReplaceThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CCNetworkProvenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(directory: root)
        let center = SettingsCenter(settingsStore: store,
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let configured = ProductionPolicyDefaults(networkDomains: ["example.com"])
        #expect(center.updatePolicyRuntimeDefaults(configured))
        let current = center.networkDomainConfigurationSnapshot(expectedDefaults: configured)
        #expect(current.origin == .actualLocalSettingsConfiguredCeiling)
        #expect(current.configuredDomains == ["example.com"])
        let injected = ProductionPolicyDefaults(networkDomains: ["unconfigured.example"])
        #expect(center.networkDomainConfigurationSnapshot(expectedDefaults: injected) == .unknown)

        // Turn the owned settings file into a directory to force a real
        // persistence failure, rather than manufacturing a success receipt.
        let settingsFile = root.appendingPathComponent(SettingsStore.fileName)
        try FileManager.default.removeItem(at: settingsFile)
        try FileManager.default.createDirectory(at: settingsFile, withIntermediateDirectories: false)
        #expect(!center.updatePolicyRuntimeDefaults(injected))
        #expect(store.settings.agent.policyRuntimeDefaults == configured)
        #expect(center.networkDomainConfigurationSnapshot(expectedDefaults: injected) == .unknown)
    }
}
