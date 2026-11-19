import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P0-A Provider to Chat closure", .serialized)
@MainActor
struct P0AProviderChatClosureTests {
    @Test("unsupported protocol fails closed before draft discovery transport")
    func unsupportedProtocolFailsClosedBeforeDraftTransport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = P0ARecordingTransport(
            response: .init(statusCode: 200, modelIDs: ["should-not-appear"])
        )
        let center = makeCenter(directory: directory, transport: transport)

        let result = await center.probeProviderDraft(
            providerID: "UNSUPPORTED_PROVIDER",
            apiKey: "p0-secret",
            baseURL: "https://provider.example/v1",
            protocolType: .other
        )

        guard case .failed(let message) = result else {
            Issue.record("expected unsupported protocol failure, got \(result)")
            return
        }
        #expect(message.contains("不支持"))
        #expect(!message.contains("p0-secret"))
        #expect(await transport.requests().isEmpty)
    }

    @Test("unsupported saved model cannot reach readiness or active chat selection")
    func unsupportedSavedModelFailsClosedBeforeModelTransport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = P0ARecordingTransport(
            response: .init(statusCode: 200, body: "Bearer p0-secret")
        )
        let center = makeCenter(directory: directory, transport: transport, deployment: .mock)
        #expect(center.saveProvider(
            name: "UNSUPPORTED_PROVIDER",
            apiKey: "p0-secret",
            baseURL: "https://provider.example/v1",
            modelNames: ["manual-model"],
            protocolType: .other
        ))

        let readiness = await center.checkProviderModelReadiness(
            forProviderName: "UNSUPPORTED_PROVIDER",
            modelID: "manual-model"
        )
        #expect(readiness?.status == .failed)
        #expect(readiness?.redactedResult.contains("不支持") == true)
        #expect(!readiness!.redactedResult.contains("p0-secret"))
        #expect(await transport.requests().isEmpty)

        let chat = ChatStore(providerReadinessStore: center.providerReadinessStore)
        let provider = try #require(center.providerRecords.first)
        chat.providerRecordsSource = { [provider] }
        #expect(!chat.applyChatModel(
            providerID: provider.name,
            modelID: "manual-model"
        ))
        #expect(chat.selectedProvider == nil)
        #expect(chat.lastChatModelApplyReceipt == nil)

        let persisted = try String(
            contentsOf: directory.appendingPathComponent(ProviderReadinessStore.fileName),
            encoding: .utf8
        )
        #expect(!persisted.contains("p0-secret"))
    }

    @Test("ModelPicker Apply rejects unsupported custom protocol without mutating chat")
    func pickerApplyRejectsUnsupportedCustomProtocol() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "UNSUPPORTED_PROVIDER",
                modelID: "manual-model",
                status: .passed,
                readinessState: .mock,
                checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
                evidenceID: "mock-readiness",
                isApplied: true
            )
        )
        let chat = ChatStore(providerReadinessStore: store)
        let provider = EnvVarEntry(
            name: "UNSUPPORTED_PROVIDER",
            value: "p0-secret",
            isSecret: true,
            baseURL: "https://provider.example/v1",
            modelNames: ["manual-model"],
            protocolType: .other
        )
        chat.providerRecordsSource = { [provider] }

        var state = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        state.selectCustomProvider(provider)
        state.selectModel("manual-model")
        state.selectTier(.balanced)
        state.apply(to: chat)

        #expect(chat.selectedProvider == nil)
        #expect(chat.selectedModelID == nil)
        #expect(chat.lastChatModelApplyReceipt == nil)
    }

    @Test("manual model survives discovery and explicit apply keeps the same receipt")
    func manualModelSurvivesDiscoveryAndApplyReceipt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let checkedAt = Date(timeIntervalSince1970: 1_787_200_000)
        store.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "LUNA",
                modelID: "manual-model",
                status: .discovered,
                readinessState: .unverified,
                checkedAt: checkedAt,
                isApplied: true
            )
        )
        store.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "LUNA",
                modelID: "discovered-model",
                status: .passed,
                readinessState: .mock,
                checkedAt: checkedAt,
                evidenceID: "mock-discovered-receipt",
                isApplied: false
            )
        )
        _ = store.applyDiscoveredModels(
            providerID: "LUNA",
            modelIDs: ["discovered-model"]
        )

        let chat = ChatStore(providerReadinessStore: store)
        let provider = EnvVarEntry(
            name: "LUNA",
            value: "p0-secret",
            isSecret: true,
            baseURL: "https://luna.example/v1",
            modelNames: ["manual-model", "discovered-model"],
            protocolType: .openaiCompatible
        )
        chat.providerRecordsSource = { [provider] }
        // 已保存但还没检查过的手填模型也列在选择器里（标“未检查”），但仍不可选。
        #expect(chat.chatModelPickerModels(forProviderID: "LUNA").map(\.id) == [
            "discovered-model", "manual-model"
        ])
        #expect(!chat.canSelectChatModel(
            providerID: "LUNA",
            modelID: "manual-model"
        ))
        #expect(chat.applyChatModel(
            providerID: "LUNA",
            modelID: "discovered-model"
        ))
        let receipt = try #require(chat.lastChatModelApplyReceipt)
        #expect(chat.chatModelPickerReceipt(
            providerID: "LUNA",
            modelID: "discovered-model"
        ) == receipt)
        #expect(chat.activeProviderEvidenceID == receipt.evidenceID)
        #expect(!receipt.id.contains("p0-secret"))
    }

    @Test("readiness-backed default row applies the first selectable model")
    func readinessBackedDefaultRowAppliesFirstSelectableModel() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let checkedAt = Date(timeIntervalSince1970: 1_787_200_000)
        let provider = EnvVarEntry(
            name: "LUNA",
            value: "p0-secret",
            isSecret: true,
            baseURL: "https://luna.example/v1",
            modelNames: ["manual-model", "discovered-model"],
            protocolType: .openaiCompatible
        )
        store.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: provider.name,
                modelID: "discovered-model",
                status: .passed,
                readinessState: .mock,
                checkedAt: checkedAt,
                evidenceID: "mock-default-receipt",
                isApplied: true
            )
        )
        let chat = ChatStore(providerReadinessStore: store)
        chat.providerRecordsSource = { [provider] }
        var state = ModelPickerState(provider: nil, modelID: nil, tier: .balanced)
        state.selectCustomProvider(provider)
        state.selectModel(nil)
        state.selectTier(.balanced)

        #expect(state.apply(to: chat))
        #expect(chat.selectedModelID == "discovered-model")
        #expect(chat.lastChatModelApplyReceipt?.evidenceID == "mock-default-receipt")
    }

    @Test("removing the selected custom model fails closed in picker and activeProvider")
    func removedSelectedCustomModelFailsClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "LUNA",
                modelID: "selected-model",
                status: .passed,
                readinessState: .mock,
                checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
                evidenceID: "mock-selected-model",
                isApplied: true
            )
        )

        let configured = EnvVarEntry(
            name: "LUNA",
            value: "p0-secret",
            isSecret: true,
            baseURL: "https://luna.example/v1",
            modelNames: ["selected-model"],
            protocolType: .openaiCompatible
        )
        var currentProvider = configured
        let chat = ChatStore(providerReadinessStore: store)
        chat.providerRecordsSource = { [currentProvider] }
        #expect(chat.applyChatModel(
            providerID: configured.name,
            modelID: "selected-model"
        ))

        currentProvider.modelNames = ["replacement-model"]
        chat.providerRecordsSource = { [currentProvider] }

        #expect(chat.chatModelPickerModels(forProviderID: configured.name).isEmpty)
        #expect(!chat.canSelectChatModel(
            providerID: configured.name,
            modelID: "selected-model"
        ))
        #expect(throws: ChatStoreReadinessError.modelNotReady(
            providerID: configured.name,
            modelID: "selected-model"
        )) {
            try chat.activeProvider()
        }
    }

    private func makeCenter(
        directory: URL,
        transport: any SettingsProviderReadinessTransport,
        deployment: ProviderDeployment = .mock
    ) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 20),
            providerReadinessTransport: transport,
            providerReadinessDeployment: deployment
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p0a-provider-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

private actor P0ARecordingTransport: SettingsProviderReadinessTransport {
    private let response: ProviderReadinessTransportResponse
    private var recordedRequests: [ProviderReadinessTransportRequest] = []

    init(response: ProviderReadinessTransportResponse) {
        self.response = response
    }

    func send(
        _ request: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        recordedRequests.append(request)
        return response
    }

    func requests() -> [ProviderReadinessTransportRequest] {
        recordedRequests
    }
}
