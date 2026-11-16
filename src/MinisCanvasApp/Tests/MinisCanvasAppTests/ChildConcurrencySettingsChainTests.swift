import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3 child concurrency Settings chain")
@MainActor
struct ChildConcurrencySettingsChainTests {
    @Test
    func agentSettingsPersistsSelectionAndToleratesInvalidValues() throws {
        let selected = AgentSettings(childConcurrencyUserSelected: 40)
        let encoded = try JSONEncoder().encode(selected)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: encoded)
        #expect(decoded.childConcurrencyUserSelected == 40)

        let invalid = Data(#"{"childConcurrencyUserSelected":41}"#.utf8)
        let fallback = try JSONDecoder().decode(AgentSettings.self, from: invalid)
        #expect(fallback.childConcurrencyUserSelected == 4)
    }

    @Test
    func selectionRemainsUserChosenUntilRiskIsAcknowledged() throws {
        let center = try makeCenter()
        center.childConcurrencyUserSelected = 12

        #expect(center.childConcurrencyUserSelected == 12)
        #expect(center.childConcurrencyRecommended == 4)
        #expect(center.childConcurrencyEffective == 4)
        #expect(!center.childConcurrencyRiskAcknowledged)

        center.childConcurrencyRiskAcknowledged = true
        #expect(center.childConcurrencyUserSelected == 12)
        #expect(center.childConcurrencyEffective == 12)
        #expect(center.childConcurrencySelection.effective <= center.childConcurrencyUserSelected)
    }

    @Test
    func resetRestoresDefaultSelectionAndConservativeEffectiveValue() throws {
        let center = try makeCenter()
        center.childConcurrencyUserSelected = 20
        center.childConcurrencyRiskAcknowledged = true
        center.resetChildConcurrencyToDefaults()

        #expect(center.childConcurrencyUserSelected == 4)
        #expect(center.childConcurrencyRecommended == 4)
        #expect(center.childConcurrencyEffective == 4)
        #expect(!center.childConcurrencyRiskAcknowledged)
    }

    @Test
    func productionBridgeReceivesCanonicalSelection() throws {
        let center = try makeCenter()
        center.childConcurrencyUserSelected = 16
        center.childConcurrencyRiskAcknowledged = true
        let selection = center.childConcurrencySelection

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            enableOrchestration: true,
            childConcurrencySelection: selection
        )

        #expect(bridge.childConcurrencySelection == selection)
        #expect(bridge.childConcurrencySelection.userSelected == 16)
        #expect(bridge.childConcurrencySelection.recommended == 4)
        #expect(bridge.childConcurrencySelection.effective == 16)
        #expect(bridge.childConcurrencySelection.globalRequestedCapacity == 16)
    }

    private func makeCenter() throws -> SettingsCenter {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3ChildSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
    }
}
