import Foundation
import Testing
@testable import MinisCore

@Suite("Provider model picker production consumer")
struct ProviderModelPickerProductionConsumerTests {
    @Test("typed health is fail-closed and exposes a recovery action")
    func typedHealthDecisionsExplainRecovery() {
        let candidates = [
            candidate(modelID: "unknown", health: .unknown),
            candidate(modelID: "unsupported", health: .unsupported),
            candidate(modelID: "degraded", health: .degraded),
            candidate(modelID: "supported", health: .supported)
        ]
        let catalog = ProviderModelSelectionCatalog(candidates: candidates)

        let unknown = catalog.decision(for: reference(modelID: "unknown"))
        #expect(unknown.availability == .unknown)
        #expect(unknown.isSelectable == false)
        #expect(unknown.recoveryAction == .refreshCatalog)
        #expect(unknown.statusLabel == "未知")

        let unsupported = catalog.decision(for: reference(modelID: "unsupported"))
        #expect(unsupported.availability == .unsupported)
        #expect(unsupported.recoveryAction == .chooseSupportedModel)

        let degraded = catalog.decision(for: reference(modelID: "degraded"))
        #expect(degraded.availability == .degraded)
        #expect(degraded.recoveryAction == .retryReadiness)

        let supported = catalog.decision(for: reference(modelID: "supported"))
        #expect(supported.isSelectable)
        #expect(supported.recoveryAction == .none)
        #expect(supported.recoveryActionLabel == nil)
    }

    @Test("ModelEntry produces only secret-free picker identity and candidate metadata")
    func modelEntryBuildsSecretFreeCandidate() {
        let entry = ModelEntry(
            providerInstanceId: "provider-a",
            model: LLMModel(id: "model-a", displayName: "Model A", provider: "Provider A")
        )
        let candidate = entry.selectionCandidate(
            isConfigured: true,
            status: .passed,
            readinessState: .live,
            credentialVersion: "digest-v2",
            health: .supported,
            aliases: ["legacy-a"]
        )

        #expect(entry.selectionReference == ProviderModelSelectionReference(
            providerID: "provider-a", modelID: "model-a"
        ))
        #expect(candidate.id == "provider-a/model-a")
        #expect(candidate.credentialVersion == "digest-v2")
        #expect(candidate.health == .supported)
        #expect(String(describing: candidate).contains("apiKey") == false)
    }

    @Test("store reopens atomically and invalidates authorization during provider rebind")
    func storeReopenAndRebind() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persisted = reference(providerID: "provider-a", modelID: "model-a")
        let catalog = ProviderModelSelectionCatalog(
            candidates: [
                candidate(providerID: "provider-a", modelID: "model-a", health: .supported),
                candidate(providerID: "provider-b", modelID: "model-b", health: .supported)
            ],
            defaultSelection: persisted,
            persistedSelection: persisted,
            activeCredentialVersions: ["provider-a": "digest-a"]
        )
        let store = ProviderModelSelectionStore(directoryURL: directory)
        #expect(store.replace(catalog))

        let reopened = store.reopened()
        #expect(reopened.recoveryState == .loaded)
        #expect(reopened.catalog == catalog)
        #expect(reopened.rebindProvider(providerID: "provider-a", to: "provider-a-successor"))
        #expect(reopened.catalog.defaultSelection?.providerID == "provider-a-successor")
        #expect(reopened.catalog.persistedSelection?.providerID == "provider-a-successor")
        #expect(reopened.catalog.activeCredentialVersions["provider-a"] == nil)
        #expect(reopened.catalog.decision(for: reference(
            providerID: "provider-a-successor", modelID: "model-a"
        )).availability == .unknown)
        #expect(reopened.catalog.decision(for: reference(
            providerID: "provider-b", modelID: "model-b"
        )).isSelectable)
    }

    @Test("corrupt snapshot is quarantined and reopens fail-closed")
    func corruptSnapshotQuarantines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("provider-model-selection.json")
        try Data("not-json".utf8).write(to: fileURL)

        let store = ProviderModelSelectionStore(directoryURL: directory)
        #expect(store.recoveryState == .quarantinedCorrupt)
        #expect(store.catalog.candidates.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test("production picker does not resurrect a removed selected model")
    func productionPickerFencesRemovedSelection() {
        let selected = reference(modelID: "removed-model")
        let consumer = ProviderModelPickerConsumer(
            records: [],
            catalog: ProviderModelSelectionCatalog(
                candidates: [candidate(modelID: "removed-model", health: .supported)],
                persistedSelection: selected
            )
        )

        let decision = consumer.persistedDecision
        #expect(decision?.isSelectable == false)
        #expect(decision?.availability == .missing)
        #expect(consumer.selectableItems.isEmpty)
    }

    private func reference(
        providerID: String = "provider-a",
        modelID: String
    ) -> ProviderModelSelectionReference {
        ProviderModelSelectionReference(providerID: providerID, modelID: modelID)
    }

    private func candidate(
        providerID: String = "provider-a",
        modelID: String,
        health: ProviderModelSelectionHealth
    ) -> ProviderModelSelectionCandidate {
        ProviderModelSelectionCandidate(
            providerID: providerID,
            modelID: modelID,
            isConfigured: true,
            status: .passed,
            readinessState: .live,
            credentialVersion: "digest-v1",
            health: health
        )
    }
}
