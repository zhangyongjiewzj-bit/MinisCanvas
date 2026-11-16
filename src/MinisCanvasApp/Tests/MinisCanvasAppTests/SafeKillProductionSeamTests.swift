import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("safe-kill production seam")
@MainActor
struct SafeKillProductionSeamTests {
    private func makeSettingsCenter(root: URL) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10)
        )
    }

    @Test
    func productionSafetyControlsReachCanonicalBridge() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-kill-production-seam-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let center = makeSettingsCenter(root: root)
        let bridge = BridgeStore(canvasFeatureLane: .phase3NonCanvas)
        center.onSafetyRuntimeSnapshotChanged = { snapshot in
            _ = bridge.updateSafetyRuntimeSnapshot(snapshot)
        }

        #expect(center.safetyRuntimeSnapshot == bridge.safetyRuntimeSnapshot)
        center.enableSafeMode()
        #expect(center.safeModeEnabled)
        #expect(bridge.safetyRuntimeSnapshot.safeModeEnabled)

        center.engageKillSwitch()
        #expect(center.killSwitchEnabled)
        #expect(bridge.safetyRuntimeSnapshot.killSwitchEnabled)
        #expect(bridge.safetyRuntimeSnapshot.allOptionalModulesDisabled)
    }

    @Test
    func productionCrashRecoveryGateIsDirtyAfterRestart() {
        let suite = "safe-kill-production-crash-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        defaults.set(false, forKey: AppLifecycleGuard.cleanExitDefaultsKey)
        let restarted = AppLifecycleGuard(defaults: defaults)

        #expect(restarted.beginSession() == false)
        #expect(restarted.lastExitWasClean == false)
        #expect(defaults.bool(forKey: AppLifecycleGuard.cleanExitDefaultsKey) == false)
    }

    @Test
    func productionSeamKeepsPhase3IsolationContract() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-kill-production-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore(
            canvasRuntimeState: .enabled,
            canvasFeatureLane: .phase3NonCanvas
        )
        bridge.attachProductionServices(
            sessionDirectory: root,
            enableOrchestration: true,
            externalNetworkAllowed: false
        )

        #expect(RuntimeIsolationProfile.phase3CanvasFeatureLane == .phase3NonCanvas)
        #expect(RuntimeIsolationProfile.phase3CanvasChatConsumerCount == 0)
        #expect(RuntimeIsolationProfile.phase3CanvasEventToChatWriteCount == 0)
        #expect(bridge.canvasFeatureLane == .phase3NonCanvas)
        #expect(bridge.productionExternalNetworkAllowed == false)
        #expect(bridge.productionChatComposition.canvasCapabilities.isEmpty)
    }
}
