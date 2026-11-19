import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("IF-07B 已保存模型逐项 readiness", .serialized)
@MainActor
struct IF07BProviderModelReadinessTests {

    @Test("单模型入口只检查目标模型，不调用供应商级检查")
    func checksOnlyRequestedSavedModel() async throws {
        let transport = IF07BMockProviderReadinessTransport(
            responses: [
                .minimalModelRequest("saved-pass"): [
                    .response(.init(statusCode: 200, body: "pass"))
                ],
                .minimalModelRequest("saved-fail"): [
                    .response(.init(statusCode: 500, body: "fail"))
                ]
            ]
        )
        let center = try makeCenter(transport: transport, deployment: .mock)
        #expect(center.saveProvider(
            name: "IF07B_PROVIDER_API_KEY",
            apiKey: "if07b-secret",
            baseURL: "https://mock.example/v1",
            modelNames: ["saved-pass", "saved-fail"],
            protocolType: .openaiCompatible
        ))

        let result = await center.checkProviderModelReadiness(
            forProviderName: "IF07B_PROVIDER_API_KEY",
            modelID: "saved-pass"
        )

        #expect(result?.status == .passed)
        #expect(result?.modelID == "saved-pass")
        #expect(center.providerModelReadiness(
            forProviderName: "IF07B_PROVIDER_API_KEY",
            modelID: "saved-fail"
        ) == nil)
        #expect(await transport.operations() == [.minimalModelRequest("saved-pass")])
    }

    @Test("单模型失败和重试彼此隔离")
    func failureAndRetryStayIsolatedPerModel() async throws {
        let transport = IF07BMockProviderReadinessTransport(
            responses: [
                .minimalModelRequest("model-a"): [
                    // 2026-11-16：429/超时/5xx 在检查内会自动重试，所以用不会重试的 400 表示“这个模型失败”。
                    .response(.init(statusCode: 400, body: "model-a failed")),
                    .response(.init(statusCode: 200, body: "model-a recovered"))
                ],
                .minimalModelRequest("model-b"): [
                    .response(.init(statusCode: 200, body: "model-b passed"))
                ]
            ]
        )
        let center = try makeCenter(transport: transport, deployment: .mock)
        #expect(center.saveProvider(
            name: "IF07B_ISOLATION_API_KEY",
            apiKey: "if07b-secret",
            baseURL: "https://mock.example/v1",
            modelNames: ["model-a", "model-b"],
            protocolType: .openaiCompatible
        ))

        let failed = await center.checkProviderModelReadiness(
            forProviderName: "IF07B_ISOLATION_API_KEY",
            modelID: "model-a"
        )
        let passed = await center.checkProviderModelReadiness(
            forProviderName: "IF07B_ISOLATION_API_KEY",
            modelID: "model-b"
        )

        #expect(failed?.status == .failed)
        #expect(passed?.status == .passed)
        #expect(center.providerModelReadiness(
            forProviderName: "IF07B_ISOLATION_API_KEY",
            modelID: "model-a"
        )?.status == .failed)
        #expect(center.providerModelReadiness(
            forProviderName: "IF07B_ISOLATION_API_KEY",
            modelID: "model-b"
        )?.status == .passed)

        let retried = await center.checkProviderModelReadiness(
            forProviderName: "IF07B_ISOLATION_API_KEY",
            modelID: "model-a"
        )

        #expect(retried?.status == .passed)
        #expect(center.providerModelReadiness(
            forProviderName: "IF07B_ISOLATION_API_KEY",
            modelID: "model-b"
        )?.status == .passed)
        #expect(await transport.operations() == [
            .minimalModelRequest("model-a"),
            .minimalModelRequest("model-b"),
            .minimalModelRequest("model-a")
        ])
    }

    @Test("取消只影响目标模型，取消后可以重新检查")
    func cancellationIsPerModelAndRetryable() async throws {
        let transport = IF07BMockProviderReadinessTransport(
            responses: [
                .minimalModelRequest("slow-model"): [
                    .waitForCancellation,
                    .response(.init(statusCode: 200, body: "recovered"))
                ],
                .minimalModelRequest("other-model"): [
                    .response(.init(statusCode: 200, body: "other"))
                ]
            ]
        )
        let center = try makeCenter(transport: transport, deployment: .mock)
        #expect(center.saveProvider(
            name: "IF07B_CANCEL_API_KEY",
            apiKey: "if07b-secret",
            baseURL: "https://mock.example/v1",
            modelNames: ["slow-model", "other-model"],
            protocolType: .openaiCompatible
        ))

        let task = Task { @MainActor in
            await center.checkProviderModelReadiness(
                forProviderName: "IF07B_CANCEL_API_KEY",
                modelID: "slow-model"
            )
        }
        while await transport.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }

        center.cancelProviderModelReadiness(
            forProviderName: "IF07B_CANCEL_API_KEY",
            modelID: "slow-model"
        )
        task.cancel()
        _ = await task.value

        #expect(center.providerModelReadiness(
            forProviderName: "IF07B_CANCEL_API_KEY",
            modelID: "slow-model"
        )?.status == .cancelled)
        #expect(center.providerModelReadiness(
            forProviderName: "IF07B_CANCEL_API_KEY",
            modelID: "other-model"
        ) == nil)

        let otherResult = await center.checkProviderModelReadiness(
            forProviderName: "IF07B_CANCEL_API_KEY",
            modelID: "other-model"
        )
        let retried = await center.checkProviderModelReadiness(
            forProviderName: "IF07B_CANCEL_API_KEY",
            modelID: "slow-model"
        )

        #expect(otherResult?.status == .passed)
        #expect(retried?.status == .passed)
        #expect(await transport.operations() == [
            .minimalModelRequest("slow-model"),
            .minimalModelRequest("other-model"),
            .minimalModelRequest("slow-model")
        ])
    }

    @Test("设置页为每个已保存模型提供独立检查、重试和取消入口")
    func settingsPageContainsPerModelControls() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )

        for contract in [
            "ForEach(provider.modelNames",
            "startProviderModelReadiness(\n                    forProviderName: provider.name,\n                    modelID: modelID",
            "cancelProviderModelReadiness(\n                    forProviderName: provider.name,\n                    modelID: modelID",
            "settings.provider.model.readiness.check",
            "settings.provider.model.readiness.cancel",
            "逐个模型测试 不受此检查替代"
        ] {
            #expect(source.contains(contract), "缺少 IF-07B 设置页 contract: \(contract)")
        }
    }

    @Test("remote transport without live evidence stays unverified and persists telemetry")
    func remoteTransportCannotPromoteLiveEvidence() async throws {
        let transport = IF07BMockProviderReadinessTransport(
            canProduceLiveEvidence: false,
            responses: [
                .minimalModelRequest("remote-model"): [
                    .response(.init(statusCode: 200, body: "ok"))
                ]
            ]
        )
        let center = try makeCenter(transport: transport, deployment: .remote)
        #expect(center.saveProvider(
            name: "IF07B_REMOTE_API_KEY",
            apiKey: "if07b-secret",
            baseURL: "https://mock.example/v1",
            modelNames: ["remote-model"],
            protocolType: .openaiCompatible
        ))

        let result = await center.checkProviderModelReadiness(
            forProviderName: "IF07B_REMOTE_API_KEY",
            modelID: "remote-model"
        )

        #expect(result?.status == .passed)
        #expect(result?.readiness?.state == .unverified)
        #expect(result?.readiness?.evidenceID == nil)
        #expect(result?.latency != nil)
        let persisted = center.providerReadinessStore.records.first {
            $0.modelID == "remote-model"
        }
        #expect(persisted?.readinessState == .unverified)
        #expect(persisted?.evidenceID == nil)
        #expect(persisted?.latency != nil)
    }

    private func makeCenter(
        transport: any SettingsProviderReadinessTransport,
        deployment: ProviderDeployment
    ) throws -> SettingsCenter {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IF07BProviderModelReadiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 50),
            providerReadinessTransport: transport,
            providerReadinessDeployment: deployment
        )
    }
}

private struct IF07BMockResponse: Sendable {
    let response: ProviderReadinessTransportResponse?
    let waitForCancellation: Bool

    static func response(_ response: ProviderReadinessTransportResponse) -> Self {
        Self(response: response, waitForCancellation: false)
    }

    static let waitForCancellation = Self(response: nil, waitForCancellation: true)
}

private actor IF07BMockProviderReadinessTransport: SettingsProviderReadinessTransport {
    private var responses: [ProviderReadinessOperation: [IF07BMockResponse]]
    private var seenOperations: [ProviderReadinessOperation] = []
    nonisolated private let liveEvidence: Bool

    init(
        canProduceLiveEvidence: Bool = false,
        responses: [ProviderReadinessOperation: [IF07BMockResponse]]
    ) {
        liveEvidence = canProduceLiveEvidence
        self.responses = responses
    }

    nonisolated var canProduceLiveEvidence: Bool {
        liveEvidence
    }

    func send(
        _ request: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        seenOperations.append(request.operation)
        guard let next = responses[request.operation]?.first else {
            throw SettingsProviderReadinessTransportError.unavailable
        }
        responses[request.operation]?.removeFirst()
        if next.waitForCancellation {
            try await Task.sleep(for: .seconds(60))
            throw SettingsProviderReadinessTransportError.timeout
        }
        return next.response ?? .init(statusCode: 500)
    }

    func operations() -> [ProviderReadinessOperation] {
        seenOperations
    }

    var requestCount: Int {
        seenOperations.count
    }
}
