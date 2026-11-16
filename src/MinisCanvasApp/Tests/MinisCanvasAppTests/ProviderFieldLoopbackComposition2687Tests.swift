import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

@Suite("D-PROVIDER-01/02 field composition keeps exact loopback capability")
@MainActor
struct ProviderFieldLoopbackComposition2687Tests {
    @Test("production attach and settings reattach retain only the explicit field capability")
    func fieldAttachAndReattach() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-composition-2687-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "provider-composition-2687",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: [
                "MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
                SessionPackageFieldFixture.activationArgument
            ]
        )
        defer { try? profile.cleanupDisposableRoots() }
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory,
                                  keychain: profile.makeKeychainStore()),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: LogManager(directory: profile.minisCanvasDirectory, ringCapacity: 20),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock
        )
        let bridge = BridgeStore()
        await ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: settings, profile: profile,
            childConcurrencySelection: settings.childConcurrencySelection,
            controlledFieldLoopbackAllowed: true
        ).value
        #expect(bridge.productionControlledFieldLoopbackAllowed)
        #expect(bridge.chat.controlledFieldLoopbackAllowed)
        #expect(!bridge.productionExternalNetworkAllowed)

        ProductionOrchestrationDefaults.bindChildConcurrencySelection(
            to: bridge, settings: settings, profile: profile,
            controlledFieldLoopbackAllowed: true
        )
        ProductionOrchestrationDefaults.bindPolicyRuntimeDefaults(
            to: bridge, settings: settings, profile: profile,
            controlledFieldLoopbackAllowed: true
        )
        defer {
            settings.onChildConcurrencySelectionChanged = nil
            settings.onPolicyRuntimeDefaultsChanged = nil
        }
        settings.onChildConcurrencySelectionChanged?(settings.childConcurrencySelection)
        settings.onPolicyRuntimeDefaultsChanged?(settings.policyRuntimeDefaults)
        #expect(bridge.productionControlledFieldLoopbackAllowed)
        #expect(bridge.chat.controlledFieldLoopbackAllowed)
        #expect(!bridge.productionExternalNetworkAllowed)

        await ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: settings, profile: profile,
            childConcurrencySelection: settings.childConcurrencySelection
        ).value
        #expect(!bridge.productionControlledFieldLoopbackAllowed)
        #expect(!bridge.chat.controlledFieldLoopbackAllowed)
        #expect(!bridge.productionExternalNetworkAllowed)
    }
}
