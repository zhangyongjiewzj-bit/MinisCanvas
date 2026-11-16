import Foundation
import Observation
import XCTest
import MinisCore
@testable import MinisCanvasApp

@MainActor
final class SafeModeKillSwitchTests: XCTestCase {
    private final class InvalidationCounter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    private func makeCenter() -> (SettingsCenter, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3Safe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        return (center, directory)
    }

    func testDefaultsEnableOptionalModulesAndPreserveCoreCapabilities() {
        let (center, _) = makeCenter()

        XCTAssertFalse(center.safeModeEnabled)
        XCTAssertFalse(center.killSwitchEnabled)
        XCTAssertFalse(center.optionalModulesDisabled)
        XCTAssertTrue(center.chatBackupRecoveryRemainEnabled)
        XCTAssertTrue(center.safetyFeatureFlags.allSatisfy(\.isReadOnly))
        XCTAssertEqual(center.safetyFeatureFlags.count, SafetyControlFeature.allCases.count)
        XCTAssertTrue(center.safetyFeatureFlags.allSatisfy {
            !$0.owner.isEmpty
                && !$0.deletionCondition.isEmpty
                && !$0.cleanupStage.isEmpty
        })
    }

    func testSafeModeDisablesEveryOptionalModuleButNotChatBackupOrRecovery() {
        let (center, _) = makeCenter()
        center.enableSafeMode()

        XCTAssertTrue(center.safeModeEnabled)
        XCTAssertTrue(center.optionalModulesDisabled)
        XCTAssertTrue(center.chatBackupRecoveryRemainEnabled)
        for feature in SafetyControlFeature.allCases {
            XCTAssertEqual(
                center.isSafetyFeatureEnabled(feature),
                feature.isForced,
                feature.rawValue
            )
        }
    }

    func testKillSwitchIsOfflineLocalAndRestorable() {
        let (center, directory) = makeCenter()
        center.engageKillSwitch()

        XCTAssertTrue(center.killSwitchEnabled)
        XCTAssertTrue(center.optionalModulesDisabled)
        XCTAssertTrue(center.chatBackupRecoveryRemainEnabled)

        let reloaded = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        XCTAssertTrue(reloaded.killSwitchEnabled)
        XCTAssertTrue(reloaded.optionalModulesDisabled)
        XCTAssertTrue(reloaded.chatBackupRecoveryRemainEnabled)
    }

    func testDisengagingKillSwitchPublishesDefaultStateAndPersistsIt() {
        let (center, directory) = makeCenter()
        var transitions: [SafetyControlState] = []
        center.onSafetyRuntimeSnapshotChanged = { transitions.append($0) }

        center.engageKillSwitch()
        XCTAssertEqual(
            center.safetyRuntimeSnapshot,
            SafetyControlState(killSwitchEnabled: true)
        )

        center.disengageKillSwitch()

        XCTAssertEqual(center.safetyRuntimeSnapshot, .defaults)
        XCTAssertEqual(
            transitions,
            [SafetyControlState(killSwitchEnabled: true), .defaults]
        )
        XCTAssertFalse(center.optionalModulesDisabled)
        XCTAssertTrue(center.chatBackupRecoveryRemainEnabled)

        let reloaded = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        XCTAssertEqual(reloaded.safetyControlState, .defaults)
        XCTAssertFalse(reloaded.optionalModulesDisabled)
    }

    func testSafetyStateIsObservableAndRestoreDefaultsPersists() {
        let (center, directory) = makeCenter()
        let invalidationCounter = InvalidationCounter()
        withObservationTracking {
            _ = center.safeModeEnabled
            _ = center.killSwitchEnabled
        } onChange: {
            invalidationCounter.increment()
        }

        center.setSafeMode(true)
        XCTAssertEqual(invalidationCounter.count, 1)
        center.setKillSwitch(true)
        center.restoreSafetyControlDefaults()

        let reloaded = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        XCTAssertFalse(reloaded.safeModeEnabled)
        XCTAssertFalse(reloaded.killSwitchEnabled)
        XCTAssertFalse(reloaded.optionalModulesDisabled)
    }

    func testResetToDefaultsRestoresSafetyStateWithOtherSettings() {
        let (center, _) = makeCenter()
        center.safeModeEnabled = true
        center.killSwitchEnabled = true
        center.appearance = .dark

        center.resetToDefaults()

        XCTAssertFalse(center.safeModeEnabled)
        XCTAssertFalse(center.killSwitchEnabled)
        XCTAssertFalse(center.optionalModulesDisabled)
        XCTAssertEqual(center.appearance, .system)
    }

    func testSafetyRuntimeSnapshotExposesSingleSettingsFactSource() {
        let (center, _) = makeCenter()
        var received: SafetyRuntimeSnapshot?
        center.onSafetyRuntimeSnapshotChanged = { received = $0 }

        center.engageKillSwitch()

        XCTAssertEqual(received, center.safetyRuntimeSnapshot)
        XCTAssertTrue(center.safetyRuntimeSnapshot.scope.contains("画布"))
        XCTAssertTrue(center.safetyRuntimeSnapshot.source.contains("SettingsCenter"))
        XCTAssertTrue(center.safetyRuntimeSnapshot.effectiveState.contains("对话"))
    }

    func testPersistedSafetyPayloadIsCanonicalAndRoundTripsAsOneState() throws {
        let state = SafetyControlState(safeModeEnabled: true, killSwitchEnabled: true)
        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set(["schemaVersion", "safeModeEnabled", "killSwitchEnabled"])
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, SafetyControlState.currentVersion)
        XCTAssertEqual(
            try JSONDecoder().decode(SafetyControlState.self, from: data),
            state
        )
    }

    func testStaleOrFutureSafetyPayloadFailsClosedOnRestart() throws {
        for version in [0, -1, SafetyControlState.currentVersion + 1] {
            let data = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": version,
                "safeModeEnabled": false,
                "killSwitchEnabled": true
            ])

            XCTAssertEqual(
                try JSONDecoder().decode(SafetyControlState.self, from: data),
                .failClosedDefaults,
                "unsupported schema \(version) must keep both safety locks active"
            )
        }
    }

    func testMalformedPersistedSafetyPayloadFailsClosedOnRestart() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3Safe-corrupt-\(UUID().uuidString)", isDirectory: true)
        let initial = AppSettings(providerSettings: [
            SafetyControlState.settingsKey: [
                SafetyControlState.payloadKey: "{not-json"
            ]
        ])
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory, initial: initial),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(center.safetyControlState, .failClosedDefaults)
        XCTAssertTrue(center.safeModeEnabled)
        XCTAssertTrue(center.killSwitchEnabled)
    }
}
