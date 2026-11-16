import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-PROVIDER-01 new-session default follows ready Settings", .serialized)
@MainActor
struct NewSessionDefaultProvider1791Tests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-default-1791-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func markReady(
        _ type: ProviderType,
        in store: ProviderReadinessStore,
        records: inout [EnvVarEntry],
        requestedModelID: String? = nil
    ) throws -> String {
        let model = try #require(requestedModelID.flatMap { requested in
            type.builtInModels.first(where: { $0.id == requested })
        } ?? type.builtInModels.first)
        let route = try #require(ChatStore.BuiltinReadinessBinding.route(for: type))
        let record = EnvVarEntry(
            name: type.rawValue.uppercased(), value: "synthetic-fixture-key", isSecret: true,
            baseURL: route.baseURL, modelNames: [model.id], protocolType: route.wire
        )
        records.append(record)
        let checkedAt = Date()
        store.upsert(ProviderReadinessPersistenceRecord(
            providerID: type.rawValue,
            modelID: model.id,
            status: .passed,
            readinessState: .mock,
            checkedAt: checkedAt,
            evidenceID: "mock-provider-default-1791",
            isApplied: false,
            configurationFingerprint: ChatStore.BuiltinReadinessBinding.fingerprint(
                record: record, credentialRevision: "provider-default-1791-revision"
            ),
            expiresAt: checkedAt.addingTimeInterval(3600)
        ))
        #expect(store.applyDiscoveredModels(
            providerID: type.rawValue, modelIDs: [model.id], appliedAt: checkedAt
        ).map(\.modelID) == [model.id])
        return model.id
    }

    @Test("ready changed default reaches new session while old explicit session stays local")
    func readyDefaultOnlyChangesFutureSession() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        var records: [EnvVarEntry] = []
        let openAIModel = try markReady(
            .openAI, in: store, records: &records, requestedModelID: "gpt-4.1"
        )
        let chat = ChatStore(providerReadinessStore: store)
        chat.providerRecordsSource = { records }
        chat.schedulerCredentialVersionSource = { _ in "provider-default-1791-revision" }
        #expect(chat.canSelectChatModel(
            providerID: ProviderType.openAI.rawValue, modelID: openAIModel
        ))
        let oldSession = try #require(chat.activeSessionID)
        chat.setProvider(.local)
        #expect(chat.sessions.first(where: { $0.id == oldSession })?.providerTypeRaw
            == ProviderType.local.rawValue)

        #expect(!chat.applyDefaultProviderModel(general: GeneralSettings(
            defaultProviderID: ProviderType.openAI.rawValue, defaultModelID: openAIModel
        )))
        #expect(chat.activeSessionID == oldSession)
        #expect(chat.selectedProviderType == .local)
        chat.newSession()
        #expect(chat.activeSessionID != oldSession)
        #expect(chat.selectedProviderType == .openAI)
        #expect(chat.selectedModelID == openAIModel)
        #expect(chat.sessions.first(where: { $0.id == oldSession })?.providerTypeRaw
            == ProviderType.local.rawValue)

        chat.switchSession(id: oldSession)
        #expect(chat.selectedProviderType == .local)
        #expect(chat.selectedModelID == nil)
        chat.newSession()
        #expect(chat.selectedProviderType == .openAI)
        #expect(chat.selectedModelID == openAIModel)
    }

    @Test("unready saved default cannot replace the last ready new-session default")
    func unreadyDefaultDoesNotPoisonFutureSession() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        var records: [EnvVarEntry] = []
        let readyModel = try markReady(.anthropic, in: store, records: &records)
        let chat = ChatStore(providerReadinessStore: store)
        chat.providerRecordsSource = { records }
        chat.schedulerCredentialVersionSource = { _ in "provider-default-1791-revision" }
        #expect(chat.canSelectChatModel(
            providerID: ProviderType.anthropic.rawValue, modelID: readyModel
        ))
        #expect(chat.applyDefaultProviderModel(general: GeneralSettings(
            defaultProviderID: ProviderType.anthropic.rawValue, defaultModelID: readyModel
        )))
        let oldSession = try #require(chat.activeSessionID)
        chat.setProvider(.local)

        #expect(!chat.applyDefaultProviderModel(general: GeneralSettings(
            defaultProviderID: ProviderType.openAI.rawValue, defaultModelID: "gpt-4.1"
        )))
        #expect(chat.selectedProviderType == .local)
        chat.newSession()
        #expect(chat.selectedProviderType == .anthropic)
        #expect(chat.selectedModelID == readyModel)
        chat.switchSession(id: oldSession)
        #expect(chat.selectedProviderType == .local)
    }

    @Test("default switch leaves an already running old-session turn alive")
    func oldInFlightTurnSurvivesNewDefaultAndNewSession() async throws {
        let chat = ChatStore()
        defer { chat.stopAllStreamingForSafety() }
        let route = try #require(ChatStore.BuiltinReadinessBinding.route(for: .openAI))
        let configured = EnvVarEntry(
            name: ProviderType.openAI.rawValue.uppercased(),
            value: "synthetic-fixture-key", isSecret: true,
            baseURL: route.baseURL, modelNames: ["gpt-4.1"], protocolType: route.wire
        )
        chat.providerRecordsSource = { [configured] }
        let engine = F3SessionSwitchTests.HangingEngine()
        chat.agentEngine = engine
        #expect(chat.applyDefaultProviderModel(general: GeneralSettings(
            defaultProviderID: ProviderType.openAI.rawValue, defaultModelID: "gpt-4.1"
        )))
        let oldSession = try #require(chat.activeSessionID)
        chat.draftText = "synthetic in-flight turn"
        chat.sendDraft()
        for _ in 0..<100 where !(chat.sessions.first(where: { $0.id == oldSession })?
            .messages.last?.content.contains("部分输出") ?? false) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(chat.isActiveSessionStreaming)
        #expect(chat.sessions.first(where: { $0.id == oldSession })?
            .messages.last?.content.contains("部分输出") == true)

        #expect(chat.applyDefaultProviderModel(general: GeneralSettings(
            defaultProviderID: ProviderType.anthropic.rawValue,
            defaultModelID: try #require(ProviderType.anthropic.builtInModels.first?.id)
        )))
        chat.newSession()
        #expect(chat.selectedProviderType == .anthropic)
        #expect(chat.isStreaming)
        #expect(!chat.isActiveSessionStreaming)
        #expect(engine.interruptCount == 0)
        #expect(chat.sessions.first(where: { $0.id == oldSession })?
            .messages.last?.content.contains("部分输出") == true)
    }
}
