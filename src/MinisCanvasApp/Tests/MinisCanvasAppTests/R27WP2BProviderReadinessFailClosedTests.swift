import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("R27-WP2-B Provider readiness fail-closed", .serialized)
@MainActor
struct R27WP2BProviderReadinessFailClosedTests {

    @Test("鉴权失败会失效旧的 passed picker 记录")
    func authenticationFailureInvalidatesPreviousPass() async throws {
        let transport = R27WP2BTransport(
            responses: [
                .reachability: [
                    .response(.init(statusCode: 200)),
                    .response(.init(statusCode: 200))
                ],
                .authentication: [
                    .response(.init(statusCode: 200)),
                    .response(.init(statusCode: 401, body: "invalid key"))
                ],
                .modelDiscovery: [
                    .response(.init(statusCode: 200, modelIDs: ["luna-model"]))
                ],
                .minimalModelRequest("luna-model"): [
                    .response(.init(statusCode: 200, body: "ok"))
                ]
            ]
        )
        let center = try makeCenter(transport: transport)
        #expect(center.saveProvider(
            name: "R27_AUTH_API_KEY",
            apiKey: "r27-secret",
            baseURL: "https://mock.example/v1",
            modelNames: ["luna-model"],
            protocolType: .openaiCompatible
        ))

        let first = try #require(
            await center.checkProviderReadiness(forProviderName: "R27_AUTH_API_KEY")
        )
        #expect(first.modelChecks.first?.status == .passed)
        #expect(center.chatModelPickerProjection.items.first?.isSelectable == true)

        let second = try #require(
            await center.checkProviderReadiness(forProviderName: "R27_AUTH_API_KEY")
        )

        #expect(second.authentication.status == .failed)
        #expect(center.providerReadinessStore.records.first?.status == .unavailable)
        #expect(center.chatModelPickerProjection.items.first?.isSelectable == false)
        #expect(!center.chatModelPickerProjection.items.contains { $0.isSelectable })
    }

    @Test("不可达会失效旧记录且不泄露 key")
    func unreachableProviderInvalidatesPreviousPass() async throws {
        let transport = R27WP2BTransport(
            responses: [
                .reachability: [
                    .response(.init(statusCode: 200)),
                    .failure(.unavailable)
                ],
                .authentication: [
                    .response(.init(statusCode: 200))
                ],
                .modelDiscovery: [
                    .response(.init(statusCode: 200, modelIDs: ["luna-model"]))
                ],
                .minimalModelRequest("luna-model"): [
                    .response(.init(statusCode: 200))
                ]
            ]
        )
        let center = try makeCenter(transport: transport)
        #expect(center.saveProvider(
            name: "R27_REACHABILITY_API_KEY",
            apiKey: "r27-unreachable-secret",
            baseURL: "https://mock.example/v1",
            modelNames: ["luna-model"],
            protocolType: .openaiCompatible
        ))

        _ = try #require(
            await center.checkProviderReadiness(forProviderName: "R27_REACHABILITY_API_KEY")
        )
        let report = try #require(
            await center.checkProviderReadiness(forProviderName: "R27_REACHABILITY_API_KEY")
        )

        #expect(report.reachability.status == .failed)
        #expect(center.providerReadinessStore.records.first?.status == .unavailable)
        #expect(center.chatModelPickerProjection.items.first?.isSelectable == false)
        let persisted = try Data(
            contentsOf: center.memoryStore.directory.appendingPathComponent(
                ProviderReadinessStore.fileName
            )
        )
        #expect(!String(decoding: persisted, as: UTF8.self).contains("r27-unreachable-secret"))
    }

    @Test("目录失败会失效旧模型通过记录")
    func directoryFailureInvalidatesPreviousPass() async throws {
        let transport = R27WP2BTransport(
            responses: [
                .reachability: [
                    .response(.init(statusCode: 200)),
                    .response(.init(statusCode: 200))
                ],
                .authentication: [
                    .response(.init(statusCode: 200)),
                    .response(.init(statusCode: 200))
                ],
                .modelDiscovery: [
                    .response(.init(statusCode: 200, modelIDs: ["luna-model"])),
                    .response(.init(statusCode: 200, modelIDs: []))
                ],
                .minimalModelRequest("luna-model"): [
                    .response(.init(statusCode: 200))
                ]
            ]
        )
        let center = try makeCenter(transport: transport)
        #expect(center.saveProvider(
            name: "R27_DIRECTORY_API_KEY",
            apiKey: "r27-directory-secret",
            baseURL: "https://mock.example/v1",
            modelNames: ["luna-model"],
            protocolType: .openaiCompatible
        ))

        _ = try #require(
            await center.checkProviderReadiness(forProviderName: "R27_DIRECTORY_API_KEY")
        )
        let report = try #require(
            await center.checkProviderReadiness(forProviderName: "R27_DIRECTORY_API_KEY")
        )

        #expect(report.modelDiscovery.status == .failed)
        #expect(center.providerReadinessStore.records.first?.status == .unavailable)
        #expect(center.chatModelPickerProjection.items.first?.isSelectable == false)
    }

    @Test("取消与失败区分且同样失效旧记录")
    func cancellationInvalidatesPreviousPassAndKeepsCancelledStage() async throws {
        let transport = R27WP2BTransport(
            responses: [
                .reachability: [
                    .response(.init(statusCode: 200)),
                    .waitForCancellation
                ],
                .authentication: [
                    .response(.init(statusCode: 200))
                ],
                .modelDiscovery: [
                    .response(.init(statusCode: 200, modelIDs: ["luna-model"]))
                ],
                .minimalModelRequest("luna-model"): [
                    .response(.init(statusCode: 200))
                ]
            ]
        )
        let center = try makeCenter(transport: transport)
        #expect(center.saveProvider(
            name: "R27_CANCEL_API_KEY",
            apiKey: "r27-cancel-secret",
            baseURL: "https://mock.example/v1",
            modelNames: ["luna-model"],
            protocolType: .openaiCompatible
        ))

        _ = try #require(
            await center.checkProviderReadiness(forProviderName: "R27_CANCEL_API_KEY")
        )

        let task = Task { @MainActor in
            await center.checkProviderReadiness(forProviderName: "R27_CANCEL_API_KEY")
        }
        while await transport.requestCount < 5 {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        let report = try #require(await task.value)

        #expect(report.reachability.status == .cancelled)
        #expect(center.providerReadinessStore.records.first?.status == .unavailable)
        #expect(center.chatModelPickerProjection.items.first?.isSelectable == false)
    }

    private func makeCenter(
        transport: any SettingsProviderReadinessTransport
    ) throws -> SettingsCenter {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "R27WP2BProviderReadiness-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = ProviderReadinessStore(directory: directory)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 50),
            providerReadinessTransport: transport,
            providerReadinessDeployment: .mock,
            providerReadinessStore: store
        )
        return center
    }
}

private actor R27WP2BTransport: SettingsProviderReadinessTransport {
    enum Response: Sendable {
        case response(ProviderReadinessTransportResponse)
        case failure(SettingsProviderReadinessTransportError)
        case waitForCancellation
    }

    private var responses: [ProviderReadinessOperation: [Response]]
    private(set) var requestCount = 0

    init(responses: [ProviderReadinessOperation: [Response]]) {
        self.responses = responses
    }

    func send(
        _ request: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        requestCount += 1
        guard let next = responses[request.operation]?.first else {
            throw SettingsProviderReadinessTransportError.unavailable
        }
        responses[request.operation]?.removeFirst()
        switch next {
        case .response(let response):
            return response
        case .failure(let error):
            throw error
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60))
            throw SettingsProviderReadinessTransportError.timeout
        }
    }
}
