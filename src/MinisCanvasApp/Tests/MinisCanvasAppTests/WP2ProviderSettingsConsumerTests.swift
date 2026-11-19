import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("WP-2 Provider Settings production consumer", .serialized)
@MainActor
struct WP2ProviderSettingsConsumerTests {

    @Test("保存供应商只建立 secret-free applied discovery facts")
    func savedModelsAreAppliedButNotSelectableBeforeReadiness() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = try makeCenter(
            directory: directory,
            transport: WP2ProviderSettingsTransport(responses: [:]),
            deployment: .mock
        )

        #expect(center.saveProvider(
            name: "WP2_PROVIDER_API_KEY",
            apiKey: "sk-wp2-secret-1234",
            baseURL: "https://mock.example/v1",
            modelNames: ["manual-model", "catalog-model"],
            protocolType: .openaiCompatible
        ))

        let records = center.providerReadinessStore.records
        #expect(records.map(\.modelID) == ["catalog-model", "manual-model"])
        #expect(records.allSatisfy {
            $0.providerID == "wp2_provider_api_key"
                && $0.status == .discovered
                && $0.isApplied
                && $0.evidenceID == nil
        })
        #expect(center.chatModelPickerProjection.items.map(\.modelID) == [
            "catalog-model",
            "manual-model"
        ])
        #expect(center.chatModelPickerProjection.items.allSatisfy { !$0.isSelectable })

        let persisted = try Data(
            contentsOf: directory.appendingPathComponent(ProviderReadinessStore.fileName)
        )
        let json = String(decoding: persisted, as: UTF8.self)
        #expect(!json.contains("sk-wp2-secret-1234"))
    }

    @Test("模型 readiness 写入 selector projection 且 mock 不冒充 live")
    func modelReadinessFeedsProjection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = WP2ProviderSettingsTransport(
            responses: [
                .minimalModelRequest("mock-model"): .init(
                    statusCode: 200,
                    body: "ok using sk-wp2-secret-5678"
                )
            ]
        )
        let center = try makeCenter(
            directory: directory,
            transport: transport,
            deployment: .mock
        )
        #expect(center.saveProvider(
            name: "WP2_PROVIDER_API_KEY",
            apiKey: "sk-wp2-secret-5678",
            baseURL: "https://mock.example/v1",
            modelNames: ["mock-model"],
            protocolType: .openaiCompatible
        ))

        let result = try #require(
            await center.checkProviderModelReadiness(
                forProviderName: "WP2_PROVIDER_API_KEY",
                modelID: "mock-model"
            )
        )
        #expect(result.status == .passed)

        let item = try #require(
            center.chatModelPickerProjection.items.first
        )
        #expect(item.id == "wp2_provider_api_key/mock-model")
        #expect(item.isSelectable)
        #expect(!item.isLiveVerified)
        #expect(center.providerReadinessStore.records.first?.status == .passed)
        #expect(center.providerReadinessStore.records.first?.readinessState == .mock)

        let persisted = try Data(
            contentsOf: directory.appendingPathComponent(ProviderReadinessStore.fileName)
        )
        let json = String(decoding: persisted, as: UTF8.self)
        #expect(!json.contains("sk-wp2-secret-5678"))
    }

    @Test("remote readiness 没有 live evidence 时保持未验证且不可选")
    func remoteReadinessFailsClosed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = WP2ProviderSettingsTransport(
            responses: [
                .minimalModelRequest("remote-model"): .init(statusCode: 200, body: "ok")
            ]
        )
        let center = try makeCenter(
            directory: directory,
            transport: transport,
            deployment: .remote
        )
        #expect(center.saveProvider(
            name: "WP2_REMOTE_API_KEY",
            apiKey: "sk-wp2-remote-9999",
            baseURL: "https://remote.example/v1",
            modelNames: ["remote-model"],
            protocolType: .openaiCompatible
        ))

        _ = await center.checkProviderModelReadiness(
            forProviderName: "WP2_REMOTE_API_KEY",
            modelID: "remote-model"
        )

        let item = try #require(
            center.chatModelPickerProjection.items.first
        )
        #expect(item.status == .passed)
        #expect(item.readinessState == .unverified)
        #expect(!item.isSelectable)
        #expect(item.evidenceID == nil)
    }

    @Test("供应商级检查同样按模型写入 applied 与 pending 投影")
    func providerReportProjectsConfiguredAndDiscoveredModels() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = WP2ProviderSettingsTransport(
            responses: [
                .reachability: .init(statusCode: 200),
                .authentication: .init(statusCode: 200),
                .modelDiscovery: .init(
                    statusCode: 200,
                    modelIDs: ["configured-model", "new-model"]
                ),
                .minimalModelRequest("configured-model"): .init(statusCode: 200),
                .minimalModelRequest("new-model"): .init(statusCode: 200)
            ]
        )
        let center = try makeCenter(
            directory: directory,
            transport: transport,
            deployment: .mock
        )
        #expect(center.saveProvider(
            name: "WP2_PROVIDER_API_KEY",
            apiKey: "sk-wp2-report-1234",
            baseURL: "https://mock.example/v1",
            modelNames: ["configured-model"],
            protocolType: .openaiCompatible
        ))

        let report = try #require(
            await center.checkProviderReadiness(
                forProviderName: "WP2_PROVIDER_API_KEY"
            )
        )
        #expect(report.modelChecks.count == 1)

        let projection = center.chatModelPickerProjection
        #expect(projection.items.map(\.modelID) == ["configured-model"])
        #expect(projection.items.first?.isSelectable == true)
        #expect(projection.pending.map(\.modelID) == ["new-model"])
        #expect(projection.pending.first?.isSelectable == false)
    }

    @Test("删除供应商同时清理 picker 中的 applied 与 pending 模型")
    func deletingProviderRemovesReadinessProjection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = try makeCenter(
            directory: directory,
            transport: WP2ProviderSettingsTransport(responses: [:]),
            deployment: .mock
        )

        #expect(center.saveProvider(
            name: "WP2_DELETE_API_KEY",
            apiKey: "sk-wp2-delete-1234",
            baseURL: "https://mock.example/v1",
            modelNames: ["applied-model"],
            protocolType: .openaiCompatible
        ))
        center.providerReadinessStore.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "WP2_DELETE_API_KEY",
                modelID: "pending-model",
                status: .discovered,
                readinessState: .unverified,
                checkedAt: Date().addingTimeInterval(1),
                isApplied: false
            )
        )

        #expect(center.chatModelPickerProjection.items.map(\.modelID) == [
            "applied-model"
        ])
        #expect(center.chatModelPickerProjection.pending.map(\.modelID) == [
            "pending-model"
        ])

        let deletion = try center.previewProviderDeletion(name: "WP2_DELETE_API_KEY")
        let intent = deletion
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try center.deleteProvider(
            name: "WP2_DELETE_API_KEY",
            intent: intent
        )

        #expect(center.providerRecords.isEmpty)
        #expect(center.chatModelPickerProjection.items.isEmpty)
        #expect(center.chatModelPickerProjection.pending.isEmpty)
        #expect(center.providerReadinessStore.records.isEmpty)
    }

    private func makeCenter(
        directory: URL,
        transport: any SettingsProviderReadinessTransport,
        deployment: ProviderDeployment
    ) throws -> SettingsCenter {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 50),
            providerReadinessTransport: transport,
            providerReadinessDeployment: deployment,
            providerReadinessStore: ProviderReadinessStore(directory: directory)
        )
    }

    private func temporaryDirectory() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wp2-provider-settings-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}

actor WP2ProviderSettingsTransport: SettingsProviderReadinessTransport {
    let responses: [ProviderReadinessOperation: ProviderReadinessTransportResponse]

    init(responses: [ProviderReadinessOperation: ProviderReadinessTransportResponse]) {
        self.responses = responses
    }

    func send(
        _ request: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        guard let response = responses[request.operation] else {
            throw SettingsProviderReadinessTransportError.unavailable
        }
        return response
    }
}
