import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// D-CHAT-01 / D-PROVIDER-08/17: exercise the directory used by ModelMenuButton,
/// not source-string contracts or the separate diagnostic picker seam.
@Suite("Provider L2 settings-to-main-picker boundary 296", .serialized)
@MainActor
struct ProviderL2Boundary296Tests {
    @Test("six readiness states reach settings and the main picker consistently", arguments: [
        ProviderReadinessState.mock, .local, .live, .beta, .blocked, .unverified
    ])
    func sixStatesReachSettingsAndMainPicker(state: ProviderReadinessState) throws {
        let root = temporaryDirectory()
        let store = ProviderReadinessStore(directory: root)
        let model = try #require(ProviderType.openAI.builtInModels.first)
        let builtin = builtinRecord(models: [model.id])
        let custom = customRecord(models: [model.id])
        store.upsert(record(provider: builtin, modelID: model.id, state: state, builtin: true))
        store.upsert(record(provider: custom, modelID: model.id, state: state))
        let chat = makeChat(store: store, providers: [builtin, custom])
        let allowed = ![ProviderReadinessState.blocked, .unverified].contains(state)

        for option in [ChatStore.ChatProvider.builtIn(.openAI), .custom(custom)] {
            let providerID: String
            switch option {
            case .builtIn(let type): providerID = type.rawValue
            case .custom(let provider): providerID = provider.name
            }
            let item = try #require(chat.chatModelPickerProjection.item(
                providerID: providerID, modelID: model.id
            ))
            #expect(item.projectionState.rawValue == state.rawValue)
            #expect(item.isSelectable == allowed)
            #expect(item.isLiveVerified == (state == .live))
            let summary = ProviderLocalReadinessSummary.aggregate(
                providerID: providerID, projection: chat.chatModelPickerProjection, isChecking: false
            )
            #expect(summary.projectionState?.rawValue == state.rawValue)
            #expect(summary.state == (allowed ? .ready : .blocked))
            let models = ModelPickerPanel.readinessFilteredModels(for: option, chat: chat)
            #expect(models.map(\.id) == (allowed ? [model.id] : []))
            #expect(chat.chatProviderOptions.contains { $0.id == option.id } == allowed)
            #expect(chat.canSelectChatModel(providerID: providerID, modelID: model.id) == allowed)
            #expect(chat.applyChatModel(providerID: providerID, modelID: model.id) == allowed)
        }
    }

    @Test("saved model list is authoritative for built-in and custom providers")
    func settingsModelRemovalRevokesBothPickerPaths() throws {
        let root = temporaryDirectory()
        let store = ProviderReadinessStore(directory: root)
        let models = ProviderType.openAI.builtInModels
        let enabled = try #require(models.first)
        let omitted = try #require(models.dropFirst().first)
        var builtin = builtinRecord(models: [enabled.id])
        var custom = customRecord(models: [enabled.id])
        for model in [enabled, omitted] {
            store.upsert(record(provider: builtin, modelID: model.id, state: .mock, builtin: true))
            store.upsert(record(provider: custom, modelID: model.id, state: .mock))
        }
        let chat = makeChat(store: store, providers: [builtin, custom])
        for providerID in [builtin.name, custom.name] {
            #expect(chat.chatModelPickerModels(forProviderID: providerID).map(\.id) == [enabled.id])
            #expect(!chat.canSelectChatModel(providerID: providerID, modelID: omitted.id))
            #expect(!chat.applyChatModel(providerID: providerID, modelID: omitted.id))
        }
        #expect(chat.applyChatModel(providerID: custom.name, modelID: enabled.id))
        builtin.modelNames = []
        custom.modelNames = []
        chat.providerRecordsSource = { [builtin, custom] }
        for providerID in [builtin.name, custom.name] {
            #expect(chat.chatModelPickerModels(forProviderID: providerID).isEmpty)
            #expect(!chat.canSelectChatModel(providerID: providerID, modelID: enabled.id))
            #expect(!chat.applyChatModel(providerID: providerID, modelID: enabled.id))
        }
        #expect(!chat.chatProviderOptions.contains { $0.id == ChatStore.ChatProvider.builtIn(.openAI).id || $0.id == "custom.L2_CUSTOM" })
        // A current custom selection must fail the production preflight after removal.
        #expect(throws: ChatStoreReadinessError.self) { _ = try chat.activeProvider() }
    }

    @Test("unsupported custom wire cannot appear as a selectable main-menu route")
    func unsupportedCustomProtocolNeverEntersMainPicker() throws {
        let root = temporaryDirectory()
        let store = ProviderReadinessStore(directory: root)
        let unsupported = customRecord(models: ["fixture-model"], protocolType: .other)
        let supported = customRecord(name: "L2_SUPPORTED", models: ["fixture-model"])
        for provider in [unsupported, supported] {
            store.upsert(record(provider: provider, modelID: "fixture-model", state: .mock))
        }
        let chat = makeChat(store: store, providers: [unsupported, supported])
        #expect(chat.chatModelPickerModels(forProviderID: supported.name).map(\.id) == ["fixture-model"])
        #expect(chat.chatProviderOptions.contains { $0.id == "custom.L2_SUPPORTED" })
        #expect(ModelPickerPanel.readinessFilteredModels(for: .custom(unsupported), chat: chat).isEmpty)
        #expect(chat.chatModelPickerModels(forProviderID: unsupported.name).isEmpty)
        #expect(!chat.chatProviderOptions.contains { $0.id == "custom.L2_CUSTOM" })
        #expect(!chat.canSelectChatModel(providerID: unsupported.name, modelID: "fixture-model"))
        #expect(!chat.applyChatModel(providerID: unsupported.name, modelID: "fixture-model"))
    }

    @Test("missing provider configuration exposes Mock identity and chooses the Mock provider")
    func emptyDirectoryRemainsExplicitlyMock() throws {
        let store = ProviderReadinessStore(directory: temporaryDirectory())
        let chat = makeChat(store: store, providers: [])
        #expect(chat.isMockMode)
        #expect(chat.providerLabel == "演示模式")
        #expect(chat.chatModelPickerItems.isEmpty)
        #expect(chat.providerRuntimeFallbackCandidates().isEmpty)
        #expect(try chat.activeProvider().name == "Mock")
    }

    private func makeChat(store: ProviderReadinessStore, providers: [EnvVarEntry]) -> ChatStore {
        let chat = ChatStore(
            providerReadinessStore: store,
            preferencesDefaults: UserDefaults(suiteName: "provider-l2-296-\(UUID().uuidString)")!,
            logManager: LogManager(directory: temporaryDirectory(), ringCapacity: 50)
        )
        chat.providerRecordsSource = { providers }
        chat.schedulerCredentialVersionSource = { _ in "fixture-revision-296" }
        return chat
    }

    private func builtinRecord(models: [String]) -> EnvVarEntry {
        EnvVarEntry(name: ProviderType.openAI.rawValue, value: "fixture-only", isSecret: true,
                    baseURL: "https://api.openai.com/v1", modelNames: models,
                    protocolType: .openaiCompatible)
    }

    private func customRecord(name: String = "L2_CUSTOM", models: [String],
                              protocolType: ProviderWireProtocol = .openaiCompatible) -> EnvVarEntry {
        EnvVarEntry(name: name, value: "fixture-only", isSecret: true,
                    baseURL: "https://fixture.invalid/v1", modelNames: models,
                    protocolType: protocolType)
    }

    private func record(provider: EnvVarEntry, modelID: String, state: ProviderReadinessState,
                        builtin: Bool = false) -> ProviderReadinessPersistenceRecord {
        let status: ProviderReadinessPersistenceStatus = state == .blocked ? .unavailable
            : state == .unverified ? .unverified : .passed
        let evidence: String? = status == .passed
            ? (state == .live ? "live-settings:" + String(repeating: "a", count: 64) : "fixture-296-" + state.rawValue)
            : nil
        return ProviderReadinessPersistenceRecord(
            providerID: provider.name, modelID: modelID, status: status, readinessState: state,
            checkedAt: Date(), evidenceID: evidence, isApplied: true,
            configurationFingerprint: builtin ? ChatStore.BuiltinReadinessBinding.fingerprint(
                record: provider, credentialRevision: "fixture-revision-296"
            ) : nil
        )
    }

    private func temporaryDirectory() -> URL {
        // Preserve this bounded synthetic evidence fixture; never inspect user data.
        FileManager.default.temporaryDirectory.appendingPathComponent("provider-l2-296-\(UUID().uuidString)")
    }
}
