import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("IF-07A Provider 表单目录发现")
@MainActor
struct IF07AProviderDirectoryDiscoveryTests {

    private func makeCenter(
        transport: any SettingsProviderReadinessTransport
    ) throws -> SettingsCenter {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IF07A-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 20),
            mcpManager: MCPServerManager(
                fileURL: directory.appendingPathComponent("mcps.json")
            ),
            skillStore: SkillStore(
                skillsRoot: directory.appendingPathComponent("skills")
            ),
            providerReadinessTransport: transport
        )
    }

    @Test("填写 draft 后获取目录不保存供应商")
    func probeUsesDraftFieldsWithoutPersisting() async throws {
        let transport = IF07AMockProviderTransport(
            response: ProviderReadinessTransportResponse(
                statusCode: 200,
                modelIDs: [" manual-model ", "gpt-5.6-luna", "gpt-5.6-luna"]
            )
        )
        let center = try makeCenter(transport: transport)

        let result = await center.probeProviderDraft(
            providerID: "DRAFT_PROVIDER",
            apiKey: "draft-secret",
            baseURL: "https://provider.example/v1",
            protocolType: .openaiCompatible
        )

        #expect(result == .loaded(["manual-model", "gpt-5.6-luna"]))
        #expect(center.providerDraftProbeState == result)
        #expect(center.providerRecords.isEmpty)
        let requests = await transport.requests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.operation == .modelDiscovery)
        #expect(request.providerID == "DRAFT_PROVIDER")
        #expect(request.baseURL == URL(string: "https://provider.example/v1")!)
        #expect(request.apiKey == "draft-secret")
        #expect(request.modelID == nil)
        #expect(request.protocolType == .openaiCompatible)
    }

    @Test("目录为空时保留 empty 状态，不生成模型")
    func emptyDirectoryIsExplicit() async throws {
        let transport = IF07AMockProviderTransport(
            response: ProviderReadinessTransportResponse(statusCode: 200)
        )
        let center = try makeCenter(transport: transport)

        let result = await center.probeProviderDraft(
            providerID: "EMPTY_PROVIDER",
            apiKey: "draft-secret",
            baseURL: "https://provider.example/v1",
            protocolType: .openaiCompatible
        )

        #expect(result == .empty)
        #expect(center.providerDraftProbeState == .empty)
    }

    @Test("缺少 Key 或非法 URL 在 transport 前失败")
    func invalidDraftDoesNotSend() async throws {
        let transport = IF07AMockProviderTransport(
            response: ProviderReadinessTransportResponse(
                statusCode: 200,
                modelIDs: ["must-not-be-used"]
            )
        )
        let center = try makeCenter(transport: transport)

        let missingKey = await center.probeProviderDraft(
            providerID: "INVALID_PROVIDER",
            apiKey: " ",
            baseURL: "https://provider.example/v1",
            protocolType: .openaiCompatible
        )
        let invalidURL = await center.probeProviderDraft(
            providerID: "INVALID_PROVIDER",
            apiKey: "draft-secret",
            baseURL: "ftp://provider.example/v1",
            protocolType: .openaiCompatible
        )

        guard case .failed(let missingKeyMessage) = missingKey,
              case .failed(let invalidURLMessage) = invalidURL else {
            Issue.record("expected validation failures, got \(missingKey), \(invalidURL)")
            return
        }
        #expect(missingKeyMessage.contains("API Key"))
        #expect(invalidURLMessage.contains("获取模型列表失败"))
        #expect(await transport.requestCount == 0)
    }

    @Test("HTTP 错误和 transport 错误都映射为 error")
    func failuresAreVisibleAndRedacted() async throws {
        let httpTransport = IF07AMockProviderTransport(
            response: ProviderReadinessTransportResponse(
                statusCode: 401,
                body: "Bearer draft-secret"
            )
        )
        let httpCenter = try makeCenter(transport: httpTransport)
        let httpResult = await httpCenter.probeProviderDraft(
            providerID: "HTTP_PROVIDER",
            apiKey: "draft-secret",
            baseURL: "https://provider.example/v1",
            protocolType: .openaiCompatible
        )

        guard case .failed(let httpMessage) = httpResult else {
            Issue.record("expected HTTP failure, got \(httpResult)")
            return
        }
        #expect(httpMessage.contains("401"))
        #expect(!httpMessage.contains("draft-secret"))

        let transport = IF07AMockProviderTransport(
            error: IF07AProbeError.transportUnavailable
        )
        let center = try makeCenter(transport: transport)
        let result = await center.probeProviderDraft(
            providerID: "ERROR_PROVIDER",
            apiKey: "draft-secret",
            baseURL: "https://provider.example/v1",
            protocolType: .openaiCompatible
        )

        guard case .failed(let message) = result else {
            Issue.record("expected transport failure, got \(result)")
            return
        }
        #expect(message.contains("mock transport unavailable"))
        #expect(!message.contains("draft-secret"))
    }

    @Test("取消 draft probe 不落盘且回报 cancelled")
    func cancellationIsObservable() async throws {
        let transport = IF07AMockProviderTransport(
            waitUntilCancelled: true
        )
        let center = try makeCenter(transport: transport)
        let task = Task { @MainActor in
            await center.probeProviderDraft(
                providerID: "CANCEL_PROVIDER",
                apiKey: "draft-secret",
                baseURL: "https://provider.example/v1",
                protocolType: .openaiCompatible
            )
        }

        while await transport.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(center.providerDraftProbeState == .loading)
        task.cancel()
        let result = await task.value

        #expect(result == .cancelled)
        #expect(center.providerDraftProbeState == .cancelled)
        #expect(center.providerRecords.isEmpty)
    }

    @Test("应用目录只追加去重项，不覆盖手动模型")
    func applyingDirectoryPreservesManualModels() {
        #expect(
            ProviderDraftModelMerger.merge(
                manual: ["manual-a", " manual-b ", ""],
                discovered: ["manual-b", " discovered-a ", "discovered-a", ""]
            ) == ["manual-a", " manual-b ", "", "discovered-a"]
        )
    }

    @Test("设置页目录流程显式应用后才进入保存 draft")
    func settingsPageRequiresExplicitDirectoryApply() throws {
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
            "settings.provider.fetchModels",
            "Button(\"应用目录\")",
            "applyDiscoveredModels(modelIDs)",
            "ProviderDraftModelMerger.merge(",
            "modelNames: draft.modelNames"
        ] {
            #expect(source.contains(contract), "缺少 Provider draft 目录 consumer contract: \(contract)")
        }
    }
}

private enum IF07AProbeError: Error, LocalizedError, Sendable {
    case transportUnavailable

    var errorDescription: String? {
        "mock transport unavailable"
    }
}

private actor IF07AMockProviderTransport: SettingsProviderReadinessTransport {
    private let response: ProviderReadinessTransportResponse?
    private let error: (any Error & Sendable)?
    private let waitUntilCancelled: Bool
    private var recordedRequests: [ProviderReadinessTransportRequest] = []

    init(
        response: ProviderReadinessTransportResponse? = nil,
        error: (any Error & Sendable)? = nil,
        waitUntilCancelled: Bool = false
    ) {
        self.response = response
        self.error = error
        self.waitUntilCancelled = waitUntilCancelled
    }

    func send(
        _ request: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        recordedRequests.append(request)
        if waitUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        if let error {
            throw error
        }
        return response ?? ProviderReadinessTransportResponse(statusCode: 500)
    }

    func requests() -> [ProviderReadinessTransportRequest] {
        recordedRequests
    }

    var requestCount: Int {
        recordedRequests.count
    }
}
