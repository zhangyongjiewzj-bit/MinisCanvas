import Foundation
import XCTest
import MinisCore
@testable import MinisCanvasApp

@MainActor
final class SafetyRuntimeConsumerTests: XCTestCase {
    private func makeCenter() -> SettingsCenter {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SafetyRuntime-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
    }

    func testFrozenSettingsSnapshotUpdatesBridgeThroughOneCallback() {
        let center = makeCenter()
        let bridge = BridgeStore()
        center.onSafetyRuntimeSnapshotChanged = { snapshot in
            _ = bridge.updateSafetyRuntimeSnapshot(snapshot)
        }

        let initial = bridge.safetyRuntimeSnapshot
        XCTAssertEqual(initial, center.safetyRuntimeSnapshot)

        center.enableSafeMode()

        XCTAssertTrue(bridge.safetyRuntimeSnapshot.safeModeEnabled)
        XCTAssertFalse(bridge.isSafetyFeatureEnabled(.canvas))
        XCTAssertTrue(bridge.isSafetyFeatureEnabled(.chat))
        XCTAssertTrue(bridge.isSafetyFeatureEnabled(.backup))
        XCTAssertTrue(bridge.isSafetyFeatureEnabled(.recovery))
    }

    func testOptionalCanvasStartIsRejectedWhileLocked() async {
        let bridge = BridgeStore()
        _ = bridge.updateSafetyRuntimeSnapshot(
            SafetyRuntimeSnapshot(safeModeEnabled: true)
        )

        do {
            _ = try await bridge.executeCanvasMutation(.autoLayout)
            XCTFail("Safe Mode must reject optional Canvas work before execution")
        } catch let error as SafetyRuntimeAdmissionError {
            XCTAssertEqual(error, .featureDisabled(.canvas))
        } catch {
            XCTFail("Unexpected admission error: \(error)")
        }
    }

    func testTransitionReceiptExposesGenerationAndCheckpointContract() {
        let bridge = BridgeStore()

        let receipt = bridge.updateSafetyRuntimeSnapshot(
            SafetyRuntimeSnapshot(killSwitchEnabled: true)
        )

        XCTAssertEqual(receipt.generation, bridge.safetyRuntimeGeneration)
        XCTAssertEqual(receipt.cancelledOptionalWorkIDs, [])
        XCTAssertEqual(receipt.retainedCheckpointIDs, [])
        XCTAssertFalse(receipt.lateCallbackRejected)
        XCTAssertTrue(bridge.safetyRuntimeSnapshot.allOptionalModulesDisabled)
        XCTAssertTrue(bridge.safetyRuntimeSnapshot.coreFeaturesRemainEnabled)
    }

    func testProductionOrchestrationIsNotComposedWhenLocked() {
        let bridge = BridgeStore()
        _ = bridge.updateSafetyRuntimeSnapshot(
            SafetyRuntimeSnapshot(safeModeEnabled: true)
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SafetyRuntimeAttach-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        bridge.attachProductionServices(
            sessionDirectory: directory,
            mcpManager: MCPServerManager(
                fileURL: directory.appendingPathComponent("mcps.json")
            ),
            skillStore: SkillStore(
                skillsRoot: directory.appendingPathComponent("skills", isDirectory: true)
            ),
            enableOrchestration: true
        )

        XCTAssertFalse(bridge.orchestrationEnabled)
        XCTAssertTrue(bridge.productionExternalRunnerNames.isEmpty)
        XCTAssertTrue(bridge.isSafetyFeatureEnabled(.chat))
    }

    func testLateCanvasCallbackIsRejectedAfterRuntimeGenerationChanges() async {
        let bridge = BridgeStore()
        let originalGeneration = bridge.safetyRuntimeGeneration
        _ = bridge.updateSafetyRuntimeSnapshot(
            SafetyRuntimeSnapshot(killSwitchEnabled: true)
        )

        XCTAssertGreaterThan(bridge.safetyRuntimeGeneration, originalGeneration)
        do {
            _ = try await bridge.executeCanvasMutation(.resetStatuses)
            XCTFail("A callback captured before the lock must not execute")
        } catch let error as SafetyRuntimeAdmissionError {
            XCTAssertEqual(error, .featureDisabled(.canvas))
        } catch {
            XCTFail("Unexpected admission error: \(error)")
        }
    }
}
