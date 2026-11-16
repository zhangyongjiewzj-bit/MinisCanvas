import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Conversation provider model picker production consumer")
@MainActor
struct ProviderModelPickerConsumerDirectTests {
    @Test("rows are provider-qualified, secret-free, and fail closed")
    func rowsUseStableIdentityAndHealthGate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderReadinessStore(directory: directory)
        store.upsert(record(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna",
            status: .passed,
            readinessState: .mock,
            evidenceID: "luna-ready",
            isApplied: true
        ))
        store.upsert(record(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna-stale",
            status: .unavailable,
            readinessState: .blocked,
            evidenceID: nil,
            isApplied: true
        ))

        let chat = ChatStore(providerReadinessStore: store)
        chat.providerRecordsSource = {
            [EnvVarEntry(
                name: "LUNA",
                value: "fixture-secret-must-not-project",
                isSecret: true,
                baseURL: "https://fixture.invalid",
                modelNames: ["gpt-5.6-luna", "gpt-5.6-luna-stale"],
                protocolType: .openaiCompatible
            )]
        }
        let consumer = ConversationModelPickerConsumer(chat: chat)

        let ready = try #require(consumer.rows.first { $0.modelID == "gpt-5.6-luna" })
        let stale = try #require(consumer.rows.first { $0.modelID == "gpt-5.6-luna-stale" })
        #expect(ready.id == "luna/gpt-5.6-luna")
        #expect(ready.accessibilityIdentifier == "conversation.model-picker.luna.gpt-5.6-luna")
        #expect(ready.isSelectable)
        #expect(stale.isSelectable == false)
        #expect(consumer.rows.allSatisfy { row in
            row.id.contains("fixture-secret-must-not-project") == false
        })
    }

    @Test("preview, confirm, and reopen keep the runtime boundary explicit")
    func previewConfirmAndReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readiness = ProviderReadinessStore(directory: directory)
        readiness.upsert(record(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna",
            status: .passed,
            readinessState: .mock,
            evidenceID: "luna-ready",
            isApplied: true
        ))
        let luna = EnvVarEntry(
            name: "LUNA",
            value: "fixture-secret",
            isSecret: true,
            baseURL: "https://fixture.invalid",
            modelNames: ["gpt-5.6-luna"],
            protocolType: .openaiCompatible
        )
        let chat = ChatStore(providerReadinessStore: readiness)
        chat.providerRecordsSource = { [luna] }
        var consumer = ConversationModelPickerConsumer(chat: chat)

        #expect(consumer.currentReference == nil)
        let previewed = consumer.preview(providerID: "LUNA", modelID: "gpt-5.6-luna")
        #expect(previewed)
        #expect(consumer.previewedReference?.providerID == "luna")
        #expect(consumer.currentReference == nil)
        let confirmed = consumer.confirmPreview()
        #expect(confirmed)
        #expect(consumer.currentReference == ProviderModelSelectionReference(
            providerID: "luna",
            modelID: "gpt-5.6-luna"
        ))
        #expect(consumer.selectionMode == .explicitConversationOverride)
        #expect(consumer.previewedReference == nil)

        let reopened = consumer.reopened()
        #expect(reopened.currentReference == consumer.currentReference)
        #expect(reopened.previewedReference == nil)
    }

    @Test("global restore is callback-bound and provider rebind invalidates old auth")
    func restoreAndRebind() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selectionStore = ProviderModelSelectionStore(directoryURL: directory)
        let reference = ProviderModelSelectionReference(providerID: "LUNA", modelID: "gpt-5.6-luna")
        #expect(selectionStore.replace(ProviderModelSelectionCatalog(
            candidates: [ProviderModelSelectionCandidate(
                providerID: "LUNA",
                modelID: "gpt-5.6-luna",
                isConfigured: true,
                status: .passed,
                readinessState: .live,
                credentialVersion: "v1"
            )],
            defaultSelection: reference,
            persistedSelection: reference,
            activeCredentialVersions: ["LUNA": "v1"]
        )))

        let chat = ChatStore()
        var consumer = ConversationModelPickerConsumer(
            chat: chat,
            selectionStore: selectionStore
        )
        var restoreCalls = 0
        #expect(consumer.restoreGlobal {
            restoreCalls += 1
            return true
        })
        #expect(restoreCalls == 1)
        let reboundResult = consumer.rebindProvider(providerID: "LUNA", to: "LUNA-successor")
        #expect(reboundResult)
        let rebound = selectionStore.catalog.decision(for: ProviderModelSelectionReference(
            providerID: "LUNA-successor",
            modelID: "gpt-5.6-luna"
        ))
        #expect(rebound.isSelectable == false)
        #expect(rebound.availability == .unknown)
    }

    @Test("Goal18 blocked models remain visible and cannot be selected")
    func blockedModelsStayVisibleWithoutWeakeningReceiptGate() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let directory = profile.rootDirectory.appendingPathComponent("goal18-picker-\(UUID())", isDirectory: true)
        #expect(directory.standardizedFileURL.path.hasPrefix(profile.rootDirectory.standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readiness = ProviderReadinessStore(directory: directory)
        readiness.upsert(record(providerID: "LUNA", modelID: "blocked-model", status: .unavailable,
                                readinessState: .blocked, evidenceID: nil, isApplied: false))
        let provider = EnvVarEntry(name: "LUNA", value: "", isSecret: true,
            baseURL: "https://fixture.invalid", modelNames: ["unverified-model"], protocolType: .openaiCompatible)
        let chat = ChatStore(providerReadinessStore: readiness)
        chat.providerRecordsSource = { [provider] }
        let option = ChatStore.ChatProvider.custom(provider)
        #expect(Set(ModelPickerPanel.visibleModels(for: option, chat: chat).map(\.id)) == Set(["blocked-model", "unverified-model"]))
        #expect(!ModelPickerPanel.modelSelectionEnabled(for: option, modelID: "blocked-model", chat: chat))
        #expect(!ModelPickerPanel.modelSelectionEnabled(for: option, modelID: "unverified-model", chat: chat))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func record(
        providerID: String,
        modelID: String,
        status: ProviderReadinessPersistenceStatus,
        readinessState: ProviderReadinessState,
        evidenceID: String?,
        isApplied: Bool
    ) -> ProviderReadinessPersistenceRecord {
        ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            status: status,
            readinessState: readinessState,
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
            evidenceID: evidenceID,
            isApplied: isApplied
        )
    }
}
