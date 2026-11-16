import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Durable provider model picker reopen and rebind")
@MainActor
struct ProviderModelPickerDurableRebindDirectTests {
    @Test("confirmed choice survives a fresh durable reopen")
    func confirmPersistsAndReopens() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let readiness = ProviderReadinessStore(directory: directory)
        readiness.upsert(record(
            providerID: "luna",
            modelID: "gpt-5.6-luna",
            evidenceID: "luna-ready"
        ))
        let reference = ProviderModelSelectionReference(
            providerID: "luna",
            modelID: "gpt-5.6-luna"
        )
        let selectionStore = ProviderModelSelectionStore(directoryURL: directory)
        #expect(selectionStore.replace(ProviderModelSelectionCatalog(
            candidates: [candidate(reference: reference)],
            defaultSelection: reference
        )))

        let luna = EnvVarEntry(
            name: "LUNA",
            value: "fixture-secret",
            isSecret: true,
            baseURL: "https://fixture.invalid",
            modelNames: [reference.modelID],
            protocolType: .openaiCompatible
        )
        let chat = ChatStore(providerReadinessStore: readiness)
        chat.providerRecordsSource = { [luna] }
        var consumer = ConversationModelPickerConsumer(
            chat: chat,
            selectionStore: selectionStore
        )

        let previewed = consumer.preview(
            providerID: reference.providerID,
            modelID: reference.modelID
        )
        #expect(previewed)
        let confirmed = consumer.confirmPreview()
        #expect(confirmed)
        #expect(selectionStore.catalog.persistedSelection == reference)
        #expect(selectionStore.catalog.defaultSelection == reference)

        let reopened = consumer.reopened()
        #expect(reopened.selectionStore?.recoveryState == .loaded)
        #expect(reopened.selectionStore?.catalog.persistedSelection == reference)
        #expect(reopened.currentReference == reference)
    }

    @Test("rebind reopens the durable store and makes the successor fail closed")
    func rebindInvalidatesAuthorizationAfterReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = ProviderModelSelectionReference(
            providerID: "luna",
            modelID: "gpt-5.6-luna"
        )
        let store = ProviderModelSelectionStore(directoryURL: directory)
        #expect(store.replace(ProviderModelSelectionCatalog(
            candidates: [candidate(reference: reference)],
            defaultSelection: reference,
            persistedSelection: reference,
            activeCredentialVersions: ["luna": "credential-v1"]
        )))

        var consumer = ConversationModelPickerConsumer(
            chat: ChatStore(),
            selectionStore: store
        )
        let reboundResult = consumer.rebindProvider(
            providerID: "luna",
            to: "luna-successor"
        )
        #expect(reboundResult)
        let reopened = try #require(consumer.selectionStore)
        #expect(reopened.recoveryState == .loaded)
        #expect(reopened.catalog.persistedSelection?.providerID == "luna-successor")
        #expect(reopened.catalog.activeCredentialVersions["luna"] == nil)
        let decision = reopened.catalog.decision(for: ProviderModelSelectionReference(
            providerID: "luna-successor",
            modelID: reference.modelID
        ))
        #expect(decision.isSelectable == false)
        #expect(decision.isFailClosed)
        #expect(decision.availability == .unknown)
    }

    private func candidate(
        reference: ProviderModelSelectionReference
    ) -> ProviderModelSelectionCandidate {
        ProviderModelSelectionCandidate(
            providerID: reference.providerID,
            modelID: reference.modelID,
            isConfigured: true,
            status: .passed,
            readinessState: .mock,
            credentialVersion: "credential-v1"
        )
    }

    private func record(
        providerID: String,
        modelID: String,
        evidenceID: String
    ) -> ProviderReadinessPersistenceRecord {
        ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            status: .passed,
            readinessState: .mock,
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
            evidenceID: evidenceID,
            isApplied: true
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-rebind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
