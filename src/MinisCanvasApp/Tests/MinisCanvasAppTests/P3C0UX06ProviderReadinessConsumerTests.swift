import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3-C0 UX06 设置页 Provider readiness consumer", .serialized)
@MainActor
struct P3C0UX06ProviderReadinessConsumerTests {

    @Test("mock transport 覆盖全阶段并脱敏每个响应")
    func mockTransportClosesAllStages() async throws {
        let transport = UX06MockProviderReadinessTransport(
            responses: [
                .reachability: .init(statusCode: 200, body: "reachable"),
                .authentication: .init(statusCode: 200, body: "authenticated with sk-ux06-secret-1234"),
                .modelDiscovery: .init(
                    statusCode: 200,
                    body: "models for sk-ux06-secret-1234",
                    modelIDs: ["mock-alpha", "mock-beta"]
                ),
                .minimalModelRequest("configured-model"): .init(
                    statusCode: 200,
                    body: "configured response using sk-ux06-secret-1234"
                ),
                .minimalModelRequest("mock-beta"): .init(
                    statusCode: 200,
                    body: "beta response using sk-ux06-secret-1234"
                )
            ]
        )
        let center = try makeCenter(
            transport: transport,
            deployment: .mock
        )
        #expect(center.saveProvider(
            name: "UX06_PROVIDER_API_KEY",
            apiKey: "sk-ux06-secret-1234",
            baseURL: "https://mock.example/v1",
            modelNames: ["configured-model"],
            protocolType: .openaiCompatible
        ))

        let report = try #require(
            await center.startProviderReadinessAfterSave(forProviderName: "UX06_PROVIDER_API_KEY").value
        )

        #expect(report.configuration.status == .passed)
        #expect(report.reachability.status == .passed)
        #expect(report.authentication.status == .passed)
        #expect(report.modelDiscovery.status == .passed)
        #expect(report.discoveredModelIDs == ["mock-alpha", "mock-beta"])
        // 只测用户保存的模型（不拿目录里别的模型顶替），不逐个全测。
        #expect(report.modelChecks.map(\.modelID) == ["configured-model"])
        #expect(report.modelChecks.allSatisfy { $0.status == .passed })
        #expect(report.state == .mock)
        let maskedSecret = ContentSecretRedactor.mask("sk-ux06-secret-1234")
        #expect(report.redactedResult.contains("authenticated with \(maskedSecret)"))
        #expect(report.redactedResult.contains("models for \(maskedSecret)"))
        #expect(report.redactedResult.contains("configured response using \(maskedSecret)"))
        #expect(!report.redactedResult.contains("sk-ux06-secret-1234"))
        #expect(report.modelChecks.allSatisfy {
            $0.redactedResult.contains(maskedSecret)
                && !$0.redactedResult.contains("sk-ux06-secret-1234")
        })
        #expect(await transport.operations() == [
            .reachability,
            .authentication,
            .modelDiscovery,
            .minimalModelRequest("configured-model")
        ])
    }

    @Test("配置无效时不发 transport 请求")
    func invalidConfigurationStopsBeforeTransport() async throws {
        let transport = UX06MockProviderReadinessTransport(responses: [:])
        let center = try makeCenter(transport: transport, deployment: .mock)
        #expect(center.saveProvider(
            name: "UX06_INVALID_API_KEY",
            apiKey: "sk-ux06-invalid-1234",
            baseURL: nil,
            modelNames: ["configured-model"],
            protocolType: .openaiCompatible
        ))

        let report = try #require(
            await center.checkProviderReadiness(forProviderName: "UX06_INVALID_API_KEY")
        )

        #expect(report.configuration.status == .failed)
        #expect(report.reachability.status == .notRun)
        #expect(report.authentication.status == .notRun)
        #expect(report.modelDiscovery.status == .notRun)
        #expect(report.modelChecks.isEmpty)
        #expect(report.state == .blocked)
        #expect(await transport.operations().isEmpty)
    }

    @Test("鉴权失败明确区分可达与模型阶段")
    func authenticationFailureStopsDiscovery() async throws {
        let transport = UX06MockProviderReadinessTransport(
            responses: [
                .reachability: .init(statusCode: 200, body: "reachable"),
                .authentication: .init(statusCode: 401, body: "invalid key sk-ux06-secret-1234")
            ]
        )
        let center = try makeCenter(transport: transport, deployment: .mock)
        #expect(center.saveProvider(
            name: "UX06_AUTH_API_KEY",
            apiKey: "sk-ux06-secret-1234",
            baseURL: "https://mock.example/v1",
            modelNames: ["configured-model"],
            protocolType: .openaiCompatible
        ))

        let report = try #require(
            await center.checkProviderReadiness(forProviderName: "UX06_AUTH_API_KEY")
        )

        #expect(report.configuration.status == .passed)
        #expect(report.reachability.status == .passed)
        #expect(report.authentication.status == .failed)
        #expect(report.modelDiscovery.status == .notRun)
        #expect(report.modelChecks.isEmpty)
        #expect(report.state == .blocked)
        #expect(!report.redactedResult.contains("sk-ux06-secret-1234"))
        #expect(await transport.operations() == [.reachability, .authentication])
    }

    @Test("逐模型最小请求保留单模型失败状态")
    func perModelFailureIsVisible() async throws {
        let transport = UX06MockProviderReadinessTransport(
            responses: [
                .reachability: .init(statusCode: 200),
                .authentication: .init(statusCode: 200),
                .modelDiscovery: .init(
                    statusCode: 200,
                    modelIDs: ["mock-pass", "mock-fail"]
                ),
                .minimalModelRequest("mock-pass"): .init(statusCode: 200, body: "pass"),
                .minimalModelRequest("mock-fail"): .init(statusCode: 500, body: "server failure")
            ]
        )
        let center = try makeCenter(transport: transport, deployment: .mock)
        #expect(center.saveProvider(
            name: "UX06_MODELS_API_KEY",
            apiKey: "sk-ux06-models-1234",
            baseURL: "https://mock.example/v1",
            modelNames: ["mock-pass", "mock-fail"],
            protocolType: .openaiCompatible
        ))

        let report = try #require(
            await center.checkProviderReadiness(forProviderName: "UX06_MODELS_API_KEY")
        )

        #expect(report.modelChecks.count == 2)
        #expect(report.modelChecks[0].modelID == "mock-pass")
        #expect(report.modelChecks[0].status == .passed)
        #expect(report.modelChecks[1].modelID == "mock-fail")
        #expect(report.modelChecks[1].status == .failed)
        #expect(report.state == .unverified)
        #expect(report.modelChecks[1].redactedResult.contains("server failure"))
    }

    @Test("中转站没有 /models（404）时不报鉴权失败，改用一次最小对话请求，且不逐个全测")
    func missingModelsEndpointFallsBackToMinimalChatRequest() async throws {
        let transport = UX06MockProviderReadinessTransport(
            responses: [
                .reachability: .init(statusCode: 200),
                .authentication: .init(statusCode: 404),
                .modelDiscovery: .init(statusCode: 404),
                .minimalModelRequest("relay-a"): .init(statusCode: 200, body: "ok")
            ]
        )
        let center = try makeCenter(transport: transport, deployment: .mock)
        #expect(center.saveProvider(
            name: "UX06_RELAY_API_KEY",
            apiKey: "sk-ux06-relay-1234",
            baseURL: "http://192.168.1.20:3000/v1",
            modelNames: ["relay-a", "relay-b", "relay-c", "relay-d"],
            protocolType: .openaiCompatible
        ))

        let report = try #require(
            await center.checkProviderReadiness(forProviderName: "UX06_RELAY_API_KEY")
        )

        #expect(report.authentication.status == .passed)
        #expect(report.modelDiscovery.status == .passed)
        #expect(report.modelChecks.map(\.modelID).first == "relay-a")
        let operations = await transport.operations()
        #expect(!operations.contains(.modelDiscovery))
        #expect(operations.contains(.minimalModelRequest("relay-a")))
        // 已填写的模型最多检查 3 个，不会把整个目录逐个全测。
        #expect(operations.filter { if case .minimalModelRequest = $0 { return true } else { return false } }.count <= 4)
    }

    @Test("本机服务不填 Key 也能保存并检查连接（内部用占位值）")
    func localServiceSavesWithoutAPIKey() async throws {
        let transport = UX06MockProviderReadinessTransport(
            responses: [.modelDiscovery: .init(statusCode: 200, modelIDs: ["llama3.3"])]
        )
        let center = try makeCenter(transport: transport, deployment: .mock)
        #expect(center.saveProvider(
            name: "OLLAMA_API_KEY",
            credential: .replace(ProviderEndpointPolicy.localPlaceholderAPIKey),
            baseURL: "http://localhost:11434/v1",
            modelNames: ["llama3.3"],
            protocolType: .openaiCompatible
        ))
        let state = await center.probeProviderDraft(
            providerID: "OLLAMA_API_KEY",
            apiKey: "",
            baseURL: "http://localhost:11434/v1",
            protocolType: .openaiCompatible
        )
        #expect(state == .loaded(["llama3.3"]))
    }

    @Test("remote deployment 即使 mock transport 全通过也保持未验证")
    func remoteTransportCannotClaimLive() async throws {
        let transport = UX06MockProviderReadinessTransport(
            responses: [
                .reachability: .init(statusCode: 200),
                .authentication: .init(statusCode: 200),
                .modelDiscovery: .init(statusCode: 200, modelIDs: ["remote-model"]),
                .minimalModelRequest("remote-model"): .init(statusCode: 200, body: "ok")
            ]
        )
        let center = try makeCenter(transport: transport, deployment: .remote)
        #expect(center.saveProvider(
            name: "UX06_REMOTE_API_KEY",
            apiKey: "sk-ux06-remote-1234",
            baseURL: "https://mock.example/v1",
            modelNames: [],
            protocolType: .openaiCompatible
        ))

        let report = try #require(
            await center.checkProviderReadiness(forProviderName: "UX06_REMOTE_API_KEY")
        )

        #expect(report.state == .unverified)
        #expect(report.state != .live)
        #expect(report.modelChecks.first?.readiness?.state == .unverified)
        #expect(report.modelChecks.first?.readiness?.evidenceID == nil)
    }

    @Test("生产设置页消费 readiness 报告而不是只显示静态配置")
    func settingsPageWiresReadinessConsumer() throws {
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
            "checkProviderReadiness(forProviderName: provider.name)",
            "providerReadinessReport(for: provider)",
            "ProviderReadinessReportView(report: report)",
            ".accessibilityIdentifier(\"settings.provider.readiness\")",
            "配置",
            "可达",
            "鉴权",
            "模型发现"
        ] {
            #expect(source.contains(contract), "缺少设置页 readiness consumer contract: \(contract)")
        }
    }

    private func makeCenter(
        transport: any MinisCanvasApp.SettingsProviderReadinessTransport,
        deployment: ProviderDeployment
    ) throws -> SettingsCenter {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UX06ProviderReadiness-\(UUID().uuidString)", isDirectory: true)
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

private actor UX06MockProviderReadinessTransport: MinisCanvasApp.SettingsProviderReadinessTransport {
    private let responses: [ProviderReadinessOperation: ProviderReadinessTransportResponse]
    private var seenOperations: [ProviderReadinessOperation] = []

    init(responses: [ProviderReadinessOperation: ProviderReadinessTransportResponse]) {
        self.responses = responses
    }

    func send(
        _ request: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        seenOperations.append(request.operation)
        guard let response = responses[request.operation] else {
            throw MinisCanvasApp.SettingsProviderReadinessTransportError.unavailable
        }
        return response
    }

    func operations() -> [ProviderReadinessOperation] {
        seenOperations
    }
}
