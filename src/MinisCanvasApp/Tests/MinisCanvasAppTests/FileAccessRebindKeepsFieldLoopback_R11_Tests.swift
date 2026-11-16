import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

@Suite("R11 file-access settings rebind keeps controlled field loopback")
@MainActor
struct FileAccessRebindKeepsFieldLoopback_R11_Tests {
    @Test("onFileAccessSettingsChanged reattach keeps the field loopback capability")
    func fileAccessRebindKeepsFieldLoopback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "file-access-rebind-r11-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "file-access-rebind-r11",
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

        ProductionOrchestrationDefaults.bindFileAccessSettings(
            to: bridge, settings: settings, profile: profile,
            controlledFieldLoopbackAllowed: true
        )
        defer { settings.onFileAccessSettingsChanged = nil }
        // The packaged-field profile is disposable and owns these settings,
        // so the ownership guard passes and the callback must be installed.
        try #require(settings.onFileAccessSettingsChanged != nil)
        settings.onFileAccessSettingsChanged?()
        // The reattach runs in a detached Task the callback does not return;
        // give it time to publish before asserting.
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if !bridge.productionControlledFieldLoopbackAllowed { break }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(bridge.productionControlledFieldLoopbackAllowed)
        #expect(bridge.chat.controlledFieldLoopbackAllowed)
    }
}
