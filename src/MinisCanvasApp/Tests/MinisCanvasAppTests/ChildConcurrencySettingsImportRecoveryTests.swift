import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3 child concurrency settings import recovery", .serialized)
@MainActor
struct ChildConcurrencySettingsImportRecoveryTests {
    @Test("settings import preserves valid selection and recomputes transient risk state")
    func settingsImportRecoversSelectionWithoutImportingRiskAcknowledgement() throws {
        let sourceRoot = try makeTemporaryRoot("source")
        let destinationRoot = try makeTemporaryRoot("destination")
        let invalidRoot = try makeTemporaryRoot("invalid")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
            try? FileManager.default.removeItem(at: invalidRoot)
        }

        let sourceCenter = makeCenter(at: sourceRoot)
        sourceCenter.childConcurrencyUserSelected = 12
        sourceCenter.childConcurrencyRiskAcknowledged = true
        #expect(sourceCenter.childConcurrencyUserSelected == 12)
        #expect(sourceCenter.childConcurrencyEffective == 12)

        let exported = try makeSyncManager(at: sourceRoot)
            .exportSnapshot(scopes: [.settings])
        let destinationSettingsStore = SettingsStore(
            directory: destinationRoot.appendingPathComponent("settings")
        )
        destinationSettingsStore.update(
            \.agent.childConcurrencyUserSelected,
            to: 12
        )
        let destinationSync = try makeSyncManager(at: destinationRoot)
        let imported = try destinationSync.importSnapshot(
            exported,
            restoring: [.settings]
        )
        #expect(imported.succeededScopes == [.settings])

        let destinationCenter = makeCenter(at: destinationRoot)
        #expect(destinationCenter.childConcurrencyUserSelected == 12)
        #expect(!destinationCenter.childConcurrencyRiskAcknowledged)
        #expect(destinationCenter.childConcurrencyEffective == 4)

        let settingsURL = destinationRoot
            .appendingPathComponent("settings")
            .appendingPathComponent(SettingsStore.fileName)
        let persistedSelection = try Data(contentsOf: settingsURL)
        destinationCenter.childConcurrencyRiskAcknowledged = true
        #expect(destinationCenter.childConcurrencyUserSelected == 12)
        #expect(destinationCenter.childConcurrencyEffective == 12)
        #expect(try Data(contentsOf: settingsURL) == persistedSelection)
        destinationCenter.childConcurrencyRiskAcknowledged = false
        #expect(destinationCenter.childConcurrencyUserSelected == 12)
        #expect(destinationCenter.childConcurrencyEffective == 4)
        #expect(try Data(contentsOf: settingsURL) == persistedSelection)

        let invalidExport = try invalidChildConcurrencyValue(
            in: exported,
            value: 41
        )
        let invalidImport = try makeSyncManager(at: invalidRoot)
            .importSnapshot(invalidExport, restoring: [.settings])
        #expect(invalidImport.succeededScopes == [.settings])

        let invalidCenter = makeCenter(at: invalidRoot)
        #expect(
            invalidCenter.childConcurrencyUserSelected
                == ChildConcurrencySelection.default.userSelected
        )
        #expect(!invalidCenter.childConcurrencyRiskAcknowledged)
        #expect(invalidCenter.childConcurrencyEffective == 4)
    }

    private func makeTemporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "P3ChildConcurrencyImport-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("settings"),
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeCenter(at root: URL) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(
                directory: root.appendingPathComponent("settings")
            ),
            envStore: EnvVarStore(
                directory: root.appendingPathComponent("env")
            ),
            memoryStore: MemoryStore(
                directory: root.appendingPathComponent("memory")
            ),
            sessionStore: SessionStore(
                directory: root.appendingPathComponent("sessions")
            ),
            logManager: LogManager(
                directory: root.appendingPathComponent("logs"),
                ringCapacity: 10
            ),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json")
            ),
            skillStore: SkillStore(
                skillsRoot: root.appendingPathComponent("skills")
            )
        )
    }

    private func makeSyncManager(at root: URL) throws -> SyncManager {
        SyncManager(
            sessionStore: SessionStore(
                directory: root.appendingPathComponent("sessions")
            ),
            memoryStore: MemoryStore(
                directory: root.appendingPathComponent("memory")
            ),
            skillStore: SkillStore(
                skillsRoot: root.appendingPathComponent("skills")
            ),
            settingsStore: SettingsStore(
                directory: root.appendingPathComponent("settings")
            ),
            deviceName: "child-concurrency-import-fixture"
        )
    }

    private func invalidChildConcurrencyValue(
        in data: Data,
        value: Int
    ) throws -> Data {
        guard var envelope = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
        var settings = envelope["settings"] as? [String: Any],
        var agent = settings["agent"] as? [String: Any] else {
            throw NSError(
                domain: "ChildConcurrencySettingsImportRecoveryTests",
                code: 1
            )
        }
        agent["childConcurrencyUserSelected"] = value
        settings["agent"] = agent
        envelope["settings"] = settings
        return try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        )
    }
}
