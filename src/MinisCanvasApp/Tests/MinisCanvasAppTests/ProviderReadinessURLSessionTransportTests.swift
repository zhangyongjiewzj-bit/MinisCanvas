import AppKit
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Provider readiness URLSession transport", .serialized)
@MainActor
struct ProviderReadinessURLSessionTransportTests {
    @Test("saved current DeepSeek Flash reaches real readiness wire and the built-in picker; unknown IDs stay closed")
    func currentDeepSeekFlashClosesTheBuiltinReadinessChain() async throws {
        let modelID = "deepseek-flash"
        ReadinessURLProtocol.reset { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/models"):
                return .json(status: 200, object: ["data": [["id": modelID]]])
            case ("POST", "/chat/completions"):
                return .json(status: 200, object: ["choices": [["message": ["content": "owned current Flash probe"]]]])
            default:
                return .json(status: 404, object: ["error": "unexpected endpoint"])
            }
        }
        let center = try makeCenter(
            transport: URLSessionProviderReadinessTransport(remoteContractSession: ReadinessURLProtocol.makeSession()),
            deployment: .remote,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        defer { try? FileManager.default.removeItem(at: center.settingsDirectory) }
        try #require(center.saveProvider(name: ProviderType.deepSeek.rawValue,
            apiKey: "[configured locally]", baseURL: DeepSeekProviderContract.baseURL,
            modelNames: [modelID], protocolType: .openaiCompatible))
        let record = try #require(center.providerRecords.first)
        #expect(ChatStore.BuiltinReadinessBinding.record(for: .deepSeek, in: center.providerRecords)?.id == record.id)
        let report = try #require(await center.checkBuiltInProviderReadiness(for: .deepSeek))
        #expect(report.state == .live)
        #expect(report.modelChecks.map(\.modelID) == [modelID])
        #expect(report.modelChecks.first?.status == .passed)
        let credential = try #require(center.providerCredentialBinding(recordID: record.id))
        let persisted = try #require(center.providerReadinessStore.records.first {
            $0.providerID == ProviderReadinessRevision.canonicalProviderID(record.name) && $0.modelID == modelID
        })
        #expect(persisted.isApplied)
        #expect(persisted.configurationFingerprint == ChatStore.BuiltinReadinessBinding.fingerprint(
            record: record, credentialRevision: credential.revision))

        let chat = ChatStore(providerReadinessStore: center.providerReadinessStore)
        chat.providerRecordsSource = { center.providerRecords }
        chat.schedulerCredentialVersionSource = { providerID in
            guard let current = center.providerRecords.first(where: {
                $0.name.caseInsensitiveCompare(providerID) == .orderedSame
            }) else { return nil }
            return center.providerCredentialBinding(recordID: current.id)?.revision
        }
        #expect(chat.chatModelPickerModels(forProviderID: ProviderType.deepSeek.rawValue).map(\.id) == [modelID])
        #expect(chat.chatProviderOptions.contains(.builtIn(.deepSeek)))
        #expect(chat.applyChatModel(providerID: ProviderType.deepSeek.rawValue, modelID: modelID))
        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedCustomProvider == nil)
        #expect(try chat.activeProvider().model.id == modelID)
        let requests = ReadinessURLProtocol.requests()
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /models", "GET /models", "GET /models", "POST /chat/completions"
        ])
        #expect(requests.allSatisfy { $0.url?.scheme == "https" && $0.url?.host == "api.deepseek.com" })
        let minimum = try #require(requests.last)
        let bytes = try #require(ReadinessURLProtocol.bodyData(from: minimum))
        let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(body["model"] as? String == modelID)
        #expect(body["stream"] as? Bool == false)

        try #require(center.saveProvider(name: record.name, credential: .keepExisting,
            baseURL: record.baseURL, modelNames: ["deepseek-flash-unregistered"],
            protocolType: record.protocolType))
        #expect(ChatStore.BuiltinReadinessBinding.record(for: .deepSeek, in: center.providerRecords) == nil)
        let refused = await center.checkBuiltInProviderReadiness(for: .deepSeek)
        #expect(refused == nil)
        #expect(chat.chatModelPickerModels(forProviderID: ProviderType.deepSeek.rawValue).isEmpty)
        #expect(!chat.applyChatModel(providerID: ProviderType.deepSeek.rawValue, modelID: "deepseek-flash-unregistered"))
        #expect(ReadinessURLProtocol.requests().count == requests.count)
    }


    @Test("Beta 探测结果经真实 Settings 标签呈现；正式配置不可达，仅函数级证据")
    func betaProbeReachesTheProductionSettingsLabel() async throws {
        let modelID = try #require(ProviderType.openAI.builtInModels.first?.id)
        ReadinessURLProtocol.reset { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1"):
                return .json(status: 200, object: ["status": "reachable"])
            case ("GET", "/v1/models"):
                return .json(status: 200, object: ["data": [["id": modelID]]])
            case ("POST", "/v1/chat/completions"):
                return .json(status: 200, object: [
                    "choices": [["message": ["content": "owned beta probe"]]]
                ])
            default:
                return .json(status: 404, object: ["error": "unexpected endpoint"])
            }
        }
        let center = try makeCenter(
            transport: URLSessionProviderReadinessTransport(
                remoteContractSession: ReadinessURLProtocol.makeSession()),
            deployment: .beta,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        defer { try? FileManager.default.removeItem(at: center.settingsDirectory) }
        try #require(center.saveProvider(
            name: ProviderType.openAI.rawValue, apiKey: "sk-owned-beta-fixture-1234",
            baseURL: "https://api.openai.com/v1", modelNames: [modelID],
            protocolType: .openaiCompatible))
        let probed = await center.checkBuiltInProviderReadiness(for: .openAI)
        let report = try #require(probed)
        #expect(report.state == .beta)
        #expect(report.reachability.status == .passed)
        #expect(report.authentication.status == .passed)
        #expect(report.modelDiscovery.status == .passed)
        #expect(report.modelChecks.count == 1)
        #expect(report.modelChecks.first?.status == .passed)
        #expect(report.modelChecks.first?.readiness?.state == .unverified)
        let record = try #require(center.providerRecords.first)
        #expect(center.providerReadinessReport(for: record)?.state == .beta)
        let persisted = try #require(center.providerReadinessStore.records.first {
            $0.providerID == ProviderReadinessRevision.canonicalProviderID(record.name)
                && $0.modelID == modelID
        })
        #expect(persisted.readinessState == .unverified)
        #expect(persisted.isApplied)
        #expect(!persisted.discoveryReceiptID.isEmpty)
        let requests = ReadinessURLProtocol.requests()
        #expect(requests.allSatisfy { $0.url?.host == "api.openai.com" })
        #expect(requests.contains { $0.httpMethod == "GET" && $0.url?.path == "/v1/models" })
        #expect(requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/v1/chat/completions" })

        // Exercise the existing Settings consumer, not a duplicated state-to-label map.
        // This mounted synthetic consumer is not packaged-field evidence.
        let native = SettingsNativeInteractionConsumerTests()
        let host = native.makeSettingsWindow(center: center, initialPageID: "环境变量")
        defer { native.closeSettingsWindow(host) }
        try #require(host.window.isVisible && host.window.isKeyWindow && NSApp.isActive,
            "The owned Settings host must qualify before checking its displayed Beta label")
        let label = NativeConsumerOwnedAX.findDisplayedText(in: host.window, exactText: "就绪状态：Beta")
        #expect(label != nil)
    }

    @Test("built-in Responses uses /models then /responses before picker and runtime")
    func builtInResponsesClosesProductionChain() async throws {
        let modelID = try #require(ProviderType.openAIResponses.builtInModels.first?.id)
        ReadinessURLProtocol.reset { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/models"):
                return .json(status: 200, object: ["data": [["id": modelID]]])
            case ("POST", "/v1/responses"):
                return .json(status: 200, object: [
                    "status": "completed",
                    "output": [[
                        "type": "message",
                        "content": [["type": "output_text", "text": "ok"]]
                    ]]
                ])
            default:
                return .json(status: 404, object: ["error": "unexpected endpoint"])
            }
        }
        let center = try makeCenter(
            transport: URLSessionProviderReadinessTransport(
                remoteContractSession: ReadinessURLProtocol.makeSession()
            ),
            deployment: .remote
        )
        #expect(center.saveProvider(
            name: ProviderType.openAIResponses.rawValue,
            apiKey: "sk-responses-fixture-1234",
            baseURL: "https://api.openai.com/v1",
            modelNames: [modelID],
            protocolType: .openaiResponses
        ))
        let report = try #require(await center.checkBuiltInProviderReadiness(for: .openAIResponses))
        #expect(report.state == .live)
        #expect(report.modelChecks.first?.status == .passed)
        let record = try #require(center.providerRecords.first)
        let binding = try #require(center.providerCredentialBinding(recordID: record.id))
        let persisted = try #require(center.providerReadinessStore.records.first {
            $0.providerID == ProviderReadinessRevision.canonicalProviderID(record.name)
                && $0.modelID == modelID
        })
        #expect(persisted.isApplied)
        #expect(persisted.configurationFingerprint == ChatStore.BuiltinReadinessBinding.fingerprint(
            record: record,
            credentialRevision: binding.revision
        ))

        let chat = ChatStore(providerReadinessStore: center.providerReadinessStore)
        chat.providerRecordsSource = { center.providerRecords }
        chat.schedulerCredentialVersionSource = { providerID in
            guard let current = center.providerRecords.first(where: {
                $0.name.caseInsensitiveCompare(providerID) == .orderedSame
            }) else { return nil }
            return center.providerCredentialBinding(recordID: current.id)?.revision
        }
        #expect(chat.chatModelPickerModels(forProviderID: ProviderType.openAIResponses.rawValue).map(\.id) == [modelID])
        #expect(chat.applyChatModel(providerID: ProviderType.openAIResponses.rawValue, modelID: modelID))
        let activeProvider = try chat.activeProvider()
        #expect(activeProvider is OpenAIResponsesProvider)
        #expect(activeProvider.model.id == modelID)
        let requests = ReadinessURLProtocol.requests()
        #expect(requests.contains { $0.httpMethod == "GET" && $0.url?.path == "/v1/models" })
        let minimum = try #require(requests.first {
            $0.httpMethod == "POST" && $0.url?.path == "/v1/responses"
        })
        #expect(requests.allSatisfy { $0.url?.host == "api.openai.com" })
        let body = try #require(ReadinessURLProtocol.bodyData(from: minimum))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == modelID)
        #expect(object["input"] is [[String: Any]])
        #expect(object["messages"] == nil)
        #expect(object["stream"] as? Bool == false)
    }

    @Test("Responses minimal 2xx malformed or oversized bodies fail closed without retained payload")
    func responsesMinimalResponseValidation() async throws {
        let secret = "sk-responses-error-fixture-1234"
        let cases: [(Int, Data, ProviderReadinessFailureCategory)] = [
            (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8), .malformedResponse),
            (200, Data(#"{"status":"failed","output":[]}"#.utf8), .malformedResponse),
            (200, Data([0xFF, 0xFE]), .malformedResponse),
            (200, Data(repeating: 0x20, count: 1_048_577), .malformedResponse),
            (500, Data("server echoed \(secret)".utf8), .server)
        ]
        let transport = URLSessionProviderReadinessTransport(
            remoteContractSession: ReadinessURLProtocol.makeSession()
        )
        for (status, payload, expectedCategory) in cases {
            ReadinessURLProtocol.reset { _ in .raw(status: status, data: payload) }
            let response = try await transport.send(ProviderReadinessTransportRequest(
                operation: .minimalModelRequest("gpt-4o"),
                providerID: "RESPONSES_TEST",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: secret,
                modelID: "gpt-4o",
                protocolType: .openaiResponses
            ))
            #expect(response.statusCode == status)
            #expect(response.errorCategory == expectedCategory)
            #expect(response.body.isEmpty)
            #expect(response.modelIDs.isEmpty)
            #expect(ReadinessURLProtocol.requests().count == 1)
        }
    }

    @Test("configured built-in OpenAI reaches readiness, Apply, picker and runtime")
    func builtInOpenAIClosesProductionChain() async throws {
        let modelID = try #require(ProviderType.openAI.builtInModels.first?.id)
        let secret = "sk-built-in-fixture-1234"
        ReadinessURLProtocol.reset { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1"):
                return .json(status: 200, object: ["status": "reachable"])
            case ("GET", "/v1/models"):
                return .json(status: 200, object: ["data": [["id": modelID]]])
            case ("POST", "/v1/chat/completions"):
                return .json(status: 200, object: [
                    "choices": [["message": ["content": "ok"]]]
                ])
            default:
                return .json(status: 404, object: ["error": "unexpected endpoint"])
            }
        }
        let center = try makeCenter(
            transport: URLSessionProviderReadinessTransport(
                remoteContractSession: ReadinessURLProtocol.makeSession()
            ),
            deployment: .remote
        )
        #expect(center.saveProvider(
            name: ProviderType.openAI.rawValue,
            apiKey: secret,
            baseURL: "https://api.openai.com/v1",
            modelNames: [modelID],
            protocolType: .openaiCompatible
        ))
        let report = try #require(await center.checkBuiltInProviderReadiness(for: .openAI))
        #expect(report.state == .live)
        #expect(report.modelChecks.first?.status == .passed)
        let record = try #require(center.providerRecords.first)
        let binding = try #require(center.providerCredentialBinding(recordID: record.id))
        let persisted = try #require(center.providerReadinessStore.records.first {
            $0.providerID == ProviderReadinessRevision.canonicalProviderID(record.name)
                && $0.modelID == modelID
        })
        #expect(persisted.isApplied)
        #expect(persisted.configurationFingerprint == ChatStore.BuiltinReadinessBinding.fingerprint(
            record: record,
            credentialRevision: binding.revision
        ))

        let chat = ChatStore(providerReadinessStore: center.providerReadinessStore)
        chat.providerRecordsSource = { center.providerRecords }
        chat.schedulerCredentialVersionSource = { providerID in
            guard let current = center.providerRecords.first(where: {
                $0.name.caseInsensitiveCompare(providerID) == .orderedSame
            }) else { return nil }
            return center.providerCredentialBinding(recordID: current.id)?.revision
        }
        #expect(chat.chatModelPickerModels(forProviderID: ProviderType.openAI.rawValue).map(\.id) == [modelID])
        #expect(chat.applyChatModel(providerID: ProviderType.openAI.rawValue, modelID: modelID))
        #expect(try chat.activeProvider().model.id == modelID)
        #expect(ReadinessURLProtocol.requests().allSatisfy {
            $0.url?.host == "api.openai.com"
        })
    }

    @Test("remote contract receipt flows through user apply, picker, and activeProvider")
    func remoteContractClosesProductionProviderChain() async throws {
        let secret = "sk-r35-remote-contract-secret-1234"
        ReadinessURLProtocol.reset { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1"):
                return .json(status: 200, object: [
                    "status": "reachable",
                    "echo": secret
                ])
            case ("GET", "/v1/models"):
                return .json(status: 200, object: [
                    "data": [
                        ["id": "gpt-5.6-luna"],
                        ["id": "gpt-5.6-luna-mini"]
                    ]
                ])
            case ("POST", "/v1/chat/completions"):
                return .json(status: 200, object: [
                    "choices": [["message": ["content": "ok"]]],
                    "echo": secret
                ])
            default:
                return .json(status: 404, object: ["error": "unexpected endpoint"])
            }
        }

        let transport = URLSessionProviderReadinessTransport(
            remoteContractSession: ReadinessURLProtocol.makeSession()
        )
        let center = try makeCenter(
            transport: transport,
            deployment: .remote
        )
        let draft = await center.probeProviderDraft(
            providerID: "R35_LUNA_API_KEY",
            apiKey: secret,
            baseURL: "https://provider.example/v1",
            protocolType: .openaiCompatible
        )
        #expect(draft == .loaded(["gpt-5.6-luna", "gpt-5.6-luna-mini"]))

        // Saving the user-selected draft model is the explicit Settings Apply
        // boundary; the second discovered model must remain pending.
        #expect(center.saveProvider(
            name: "R35_LUNA_API_KEY",
            apiKey: secret,
            baseURL: "https://provider.example/v1",
            modelNames: ["gpt-5.6-luna"],
            protocolType: .openaiCompatible
        ))
        let saved = try #require(
            center.chatModelPickerProjection.item(
                providerID: "R35_LUNA_API_KEY",
                modelID: "gpt-5.6-luna"
            )
        )
        #expect(saved.isApplied)
        #expect(!saved.isSelectable)

        let report = try #require(
            await center.checkProviderReadiness(forProviderName: "R35_LUNA_API_KEY")
        )
        #expect(report.state == .live)
        #expect(report.modelChecks.map(\.modelID) == [
            "gpt-5.6-luna",
            "gpt-5.6-luna-mini"
        ])
        #expect(report.modelChecks.allSatisfy {
            $0.status == .passed
                && $0.readiness?.state == .live
                && $0.readiness?.evidenceID?.hasPrefix("live-settings:") == true
        })
        #expect(!report.redactedResult.contains(secret))

        let applied = try #require(
            center.chatModelPickerProjection.item(
                providerID: "R35_LUNA_API_KEY",
                modelID: "gpt-5.6-luna"
            )
        )
        let pending = try #require(
            center.chatModelPickerProjection.item(
                providerID: "R35_LUNA_API_KEY",
                modelID: "gpt-5.6-luna-mini"
            )
        )
        #expect(applied.isSelectable)
        #expect(applied.isLiveVerified)
        #expect(pending.isApplied == false)
        #expect(pending.isSelectable == false)

        let chat = ChatStore(providerReadinessStore: center.providerReadinessStore)
        let provider = try #require(center.providerRecords.first)
        chat.providerRecordsSource = { [provider] }
        #expect(chat.chatModelPickerModels(
            forProviderID: provider.name
        ).map(\.id) == ["gpt-5.6-luna"])
        #expect(chat.applyChatModel(
            providerID: provider.name,
            modelID: "gpt-5.6-luna"
        ))

        let receipt = try #require(chat.lastChatModelApplyReceipt)
        #expect(receipt.providerID == ProviderReadinessRevision.canonicalProviderID(provider.name))
        #expect(receipt.modelID == "gpt-5.6-luna")
        #expect(receipt.evidenceID == applied.evidenceID)
        #expect(receipt.isApplied)

        let activeProvider = try chat.activeProvider()
        #expect(activeProvider.name == provider.name)
        #expect(activeProvider.model.id == "gpt-5.6-luna")
        #expect(chat.activeProviderEvidenceID == receipt.evidenceID)
    }

    @Test("SettingsCenter 默认 transport 通过 URLProtocol 覆盖完整 readiness 链路")
    func defaultTransportRunsAllStagesThroughURLSession() async throws {
        let secret = "sk-readiness-urlsession-secret-1234"
        ReadinessURLProtocol.reset { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1"):
                return .json(status: 200, object: [
                    "status": "reachable",
                    "echo": secret
                ])
            case ("GET", "/v1/models"):
                return .json(status: 200, object: [
                    "data": [
                        ["id": "gpt-5.6-luna"],
                        ["id": "gpt-5.6-luna-mini"]
                    ]
                ])
            case ("POST", "/v1/chat/completions"):
                return .json(status: 200, object: [
                    "choices": [["message": ["content": "ok"]]],
                    "echo": secret
                ])
            default:
                return .json(status: 404, object: ["error": "unexpected endpoint"])
            }
        }
        let center = try makeCenter(session: ReadinessURLProtocol.makeSession())
        #expect(center.saveProvider(
            name: "URLSESSION_READINESS_API_KEY",
            apiKey: secret,
            baseURL: "https://provider.example/v1",
            modelNames: ["gpt-5.6-luna"],
            protocolType: .openaiCompatible
        ))

        let report = try #require(
            await center.checkProviderReadiness(forProviderName: "URLSESSION_READINESS_API_KEY")
        )

        #expect(report.reachability.status == .passed)
        #expect(report.authentication.status == .passed)
        #expect(report.modelDiscovery.status == .passed)
        #expect(report.discoveredModelIDs == ["gpt-5.6-luna", "gpt-5.6-luna-mini"])
        #expect(report.modelChecks.map(\.modelID) == ["gpt-5.6-luna", "gpt-5.6-luna-mini"])
        #expect(report.modelChecks.allSatisfy { $0.status == .passed })
        #expect(report.state == .unverified)
        #expect(report.modelChecks.allSatisfy {
            $0.readiness?.state == .unverified
                && $0.readiness?.evidenceID == nil
        })
        #expect(!report.redactedResult.contains(secret))
        #expect(report.redactedResult == ContentSecretRedactor.mask(secret))

        // The saved model is explicitly applied by the user's Save action;
        // the discovered second model remains pending until an explicit apply.
        let pending = try #require(center.chatModelPickerProjection.pending.first)
        #expect(pending.modelID == "gpt-5.6-luna-mini")
        #expect(!pending.isSelectable)
        #expect(!pending.isLiveVerified)
        #expect(center.chatModelPickerProjection.items.map(\.modelID) == [
            "gpt-5.6-luna"
        ])
        #expect(center.chatModelPickerProjection.pending.map(\.modelID) == [
            "gpt-5.6-luna-mini"
        ])

        let chat = ChatStore(providerReadinessStore: center.providerReadinessStore)
        let provider = try #require(center.providerRecords.first)
        chat.providerRecordsSource = { [provider] }
        #expect(chat.chatModelPickerModels(
            forProviderID: provider.name
        ).isEmpty)
        #expect(!chat.applyChatModel(
            providerID: provider.name,
            modelID: "gpt-5.6-luna"
        ))
        let activeProvider = try chat.activeProvider()
        #expect(activeProvider.name == "Mock")

        let requests = ReadinessURLProtocol.requests()
        #expect(requests.count == 5)
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /v1",
            "GET /v1/models",
            "GET /v1/models",
            "POST /v1/chat/completions",
            "POST /v1/chat/completions"
        ])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)"
        })
        #expect(requests.dropFirst(3).allSatisfy { request in
            guard let data = ReadinessURLProtocol.bodyData(from: request),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["model"] as? String != nil
        })
    }

    @Test("DeepSeek bare host uses authenticated /models readiness and chat paths")
    func deepSeekBareHostUsesModelsForReadiness() async throws {
        let secret = "sk-deepseek-transport-fixture-1234"
        ReadinessURLProtocol.reset { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/models"):
                return .json(status: 200, object: [
                    "data": [["id": "deepseek-v4-flash"]]
                ])
            case ("POST", "/chat/completions"):
                return .json(status: 200, object: [
                    "choices": [["message": ["content": "fixture"]]]
                ])
            default:
                return .json(status: 404, object: ["error": "unexpected endpoint"])
            }
        }

        let transport = URLSessionProviderReadinessTransport(
            session: ReadinessURLProtocol.makeSession()
        )
        let baseURL = try #require(URL(string: "https://api.deepseek.com"))
        let requests: [ProviderReadinessTransportRequest] = [
            ProviderReadinessTransportRequest(
                operation: .reachability,
                providerID: "DEEPSEEK_TEST",
                baseURL: baseURL,
                apiKey: secret,
                modelID: "deepseek-v4-flash",
                protocolType: .openaiCompatible
            ),
            ProviderReadinessTransportRequest(
                operation: .authentication,
                providerID: "DEEPSEEK_TEST",
                baseURL: baseURL,
                apiKey: secret,
                modelID: "deepseek-v4-flash",
                protocolType: .openaiCompatible
            ),
            ProviderReadinessTransportRequest(
                operation: .modelDiscovery,
                providerID: "DEEPSEEK_TEST",
                baseURL: baseURL,
                apiKey: secret,
                modelID: nil,
                protocolType: .openaiCompatible
            ),
            ProviderReadinessTransportRequest(
                operation: .minimalModelRequest("deepseek-v4-flash"),
                providerID: "DEEPSEEK_TEST",
                baseURL: baseURL,
                apiKey: secret,
                modelID: "deepseek-v4-flash",
                protocolType: .openaiCompatible
            )
        ]

        var responses: [ProviderReadinessTransportResponse] = []
        for request in requests {
            responses.append(try await transport.send(request))
        }
        #expect(responses.map(\.statusCode) == [200, 200, 200, 200])
        #expect(responses[2].modelIDs == ["deepseek-v4-flash"])
        #expect(responses.allSatisfy { $0.errorCategory == nil && $0.body.isEmpty })
        #expect(ReadinessURLProtocol.requests().map {
            "\($0.httpMethod ?? "") \($0.url?.path ?? "")"
        } == [
            "GET /models",
            "GET /models",
            "GET /models",
            "POST /chat/completions"
        ])
        #expect(ReadinessURLProtocol.requests().allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)"
        })
    }

    @Test("Anthropic adapter uses protocol-specific headers, paths, and catalog schema")
    func anthropicTransportUsesMessagesContract() async throws {
        let secret = "anthropic-test-secret-1234"
        ReadinessURLProtocol.reset { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1"):
                return .json(status: 200, object: ["status": "reachable"])
            case ("GET", "/v1/models"):
                return .json(status: 200, object: [
                    "data": [
                        ["type": "model", "id": "claude-test", "display_name": "Test Claude"]
                    ]
                ])
            case ("POST", "/v1/messages"):
                return .json(status: 200, object: [
                    "id": "msg_test",
                    "type": "message",
                    "content": [["type": "text", "text": "ok"]]
                ])
            default:
                return .json(status: 404, object: ["error": "unexpected endpoint"])
            }
        }

        let transport = URLSessionProviderReadinessTransport(
            session: ReadinessURLProtocol.makeSession()
        )
        let catalog = try await transport.send(
            ProviderReadinessTransportRequest(
                operation: .modelDiscovery,
                providerID: "ANTHROPIC_TEST",
                baseURL: URL(string: "https://provider.example/v1")!,
                apiKey: secret,
                modelID: nil,
                protocolType: .anthropic
            )
        )
        #expect(catalog.modelIDs == ["claude-test"])

        _ = try await transport.send(
            ProviderReadinessTransportRequest(
                operation: .minimalModelRequest("claude-test"),
                providerID: "ANTHROPIC_TEST",
                baseURL: URL(string: "https://provider.example/v1")!,
                apiKey: secret,
                modelID: "claude-test",
                protocolType: .anthropic
            )
        )

        let requests = ReadinessURLProtocol.requests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "x-api-key") == secret
                && $0.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
                && $0.value(forHTTPHeaderField: "Authorization") == nil
        })
        let body = try #require(ReadinessURLProtocol.bodyData(from: requests[1]))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["max_tokens"] as? Int == 1)
        #expect(object["model"] as? String == "claude-test")
    }

    @Test("Other protocol fails closed before URLProtocol")
    func unsupportedProtocolDoesNotSend() async throws {
        ReadinessURLProtocol.reset { _ in
            .json(status: 200, object: ["status": "must not send"])
        }
        let transport = URLSessionProviderReadinessTransport(
            session: ReadinessURLProtocol.makeSession()
        )
        let request = ProviderReadinessTransportRequest(
            operation: .reachability,
            providerID: "OTHER_TEST",
            baseURL: URL(string: "https://provider.example/v1")!,
            apiKey: "other-test-secret-1234",
            modelID: nil,
            protocolType: .other
        )

        await #expect(throws: ProviderReadinessWireAdapterError.unsupportedProtocol(.other)) {
            try await transport.send(request)
        }
        #expect(ReadinessURLProtocol.requests().isEmpty)
    }

    @Test("缺少凭据时默认 transport 不发 URLSession 请求")
    func missingCredentialStopsBeforeURLSession() async throws {
        ReadinessURLProtocol.reset { _ in
            .json(status: 200, object: ["status": "unexpected"])
        }
        let center = try makeCenter(session: ReadinessURLProtocol.makeSession())
        #expect(!center.saveProvider(
            name: "URLSESSION_NO_CREDENTIAL_API_KEY",
            apiKey: "   ",
            baseURL: "https://provider.example/v1",
            modelNames: ["gpt-5.6-luna"],
            protocolType: .openaiCompatible
        ))

        let report = await center.checkProviderReadiness(
            forProviderName: "URLSESSION_NO_CREDENTIAL_API_KEY"
        )
        #expect(report == nil)
        #expect(ReadinessURLProtocol.requests().isEmpty)
    }

    @Test("URLProtocol status responses retain redacted failure categories")
    func statusResponsesMapToRedactedCategories() async throws {
        let secret = "sk-status-test-secret-1234"
        let cases: [(Int, ProviderReadinessFailureCategory)] = [
            (401, .unauthorized),
            (403, .permissionDenied),
            (404, .notFound),
            (429, .rateLimited),
            (500, .server),
            (503, .server)
        ]
        let transport = URLSessionProviderReadinessTransport(
            session: ReadinessURLProtocol.makeSession()
        )
        let request = ProviderReadinessTransportRequest(
            operation: .reachability,
            providerID: "STATUS_TEST",
            baseURL: URL(string: "https://provider.example/v1")!,
            apiKey: secret,
            modelID: nil,
            protocolType: .openaiCompatible
        )

        for (statusCode, category) in cases {
            ReadinessURLProtocol.reset { _ in
                .json(status: statusCode, object: [
                    "error": "Authorization: Bearer \(secret)"
                ])
            }
            let response = try await transport.send(request)
            #expect(response.body.isEmpty)
            #expect(response.errorCategory == category)
            let failure = ProviderReadinessHTTPFailure.make(
                statusCode: response.statusCode,
                headers: statusCode == 429 ? ["Retry-After": "5"] : [:],
                body: response.body,
                secrets: [secret]
            )
            #expect(failure?.failureCategory == category)
            #expect(failure?.redactedDetail.contains(secret) == false)
        }
    }

    @Test("cancelled transport requests and credential echoes fail closed")
    func staleRequestAndCredentialEchoStayClosed() async throws {
        let secret = "sk-stale-transport-secret-1234"
        let transport = URLSessionProviderReadinessTransport(
            session: ReadinessURLProtocol.makeSession()
        )
        let request = ProviderReadinessTransportRequest(
            operation: .modelDiscovery,
            providerID: "STALE_TRANSPORT_TEST",
            baseURL: URL(string: "https://provider.example/v1")!,
            apiKey: secret,
            modelID: nil,
            protocolType: .openaiCompatible
        )

        let cancelled = Task {
            try await transport.send(request)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }

        ReadinessURLProtocol.reset { _ in
            .json(status: 200, object: [
                "data": [["id": "model-\(secret)"]]
            ])
        }
        let response = try await transport.send(request)
        #expect(response.body.isEmpty)
        #expect(response.modelIDs.isEmpty)
        #expect(response.errorCategory == .malformedResponse)
    }

    @Test("模型目录 HTTP 失败先保留状态码，不被错误正文误报为目录格式错误")
    func modelDiscoveryHTTPFailureSkipsCatalogDecode() async throws {
        let secret = "sk-catalog-status-secret-1234"
        ReadinessURLProtocol.reset { _ in
            .json(status: 401, object: [
                "error": "invalid key",
                "hint": "not a model catalog"
            ])
        }
        let transport = URLSessionProviderReadinessTransport(
            session: ReadinessURLProtocol.makeSession()
        )
        let request = ProviderReadinessTransportRequest(
            operation: .modelDiscovery,
            providerID: "CATALOG_STATUS_TEST",
            baseURL: URL(string: "https://provider.example/v1")!,
            apiKey: secret,
            modelID: nil,
            protocolType: .openaiCompatible
        )

        let response = try await transport.send(request)

        #expect(response.statusCode == 401)
        #expect(response.errorCategory == .unauthorized)
        #expect(response.body.isEmpty)
        #expect(response.modelIDs.isEmpty)
        #expect(ReadinessURLProtocol.requests().count == 1)
    }

    @Test("合法的 HTTP 200 空目录保留 empty 语义")
    func emptyModelDiscoveryRemainsEmpty() async throws {
        ReadinessURLProtocol.reset { request in
            guard request.httpMethod == "GET",
                  request.url?.path == "/v1/models" else {
                return .json(status: 404, object: ["error": "unexpected endpoint"])
            }
            return .json(status: 200, object: ["data": []])
        }
        let transport = URLSessionProviderReadinessTransport(
            session: ReadinessURLProtocol.makeSession()
        )
        let request = ProviderReadinessTransportRequest(
            operation: .modelDiscovery,
            providerID: "EMPTY_CATALOG_TEST",
            baseURL: URL(string: "https://provider.example/v1")!,
            apiKey: "sk-empty-catalog-secret-1234",
            modelID: nil,
            protocolType: .openaiCompatible
        )

        let response = try await transport.send(request)

        #expect(response.statusCode == 200)
        #expect(response.modelIDs.isEmpty)
        #expect(ReadinessURLProtocol.requests().count == 1)
    }

    @Test("Anthropic 合法的 HTTP 200 空目录同样保留 empty 语义")
    func emptyAnthropicModelDiscoveryRemainsEmpty() async throws {
        ReadinessURLProtocol.reset { request in
            guard request.httpMethod == "GET",
                  request.url?.path == "/v1/models" else {
                return .json(status: 404, object: ["error": "unexpected endpoint"])
            }
            return .json(status: 200, object: ["data": []])
        }
        let transport = URLSessionProviderReadinessTransport(
            session: ReadinessURLProtocol.makeSession()
        )
        let request = ProviderReadinessTransportRequest(
            operation: .modelDiscovery,
            providerID: "EMPTY_ANTHROPIC_CATALOG_TEST",
            baseURL: URL(string: "https://provider.example/v1")!,
            apiKey: "anthropic-empty-catalog-secret-1234",
            modelID: nil,
            protocolType: .anthropic
        )

        let response = try await transport.send(request)

        #expect(response.statusCode == 200)
        #expect(response.modelIDs.isEmpty)
        #expect(ReadinessURLProtocol.requests().count == 1)
    }

    @Test("HTTP、重定向、服务端错误和超时都 fail-closed")
    func unsafeAndFailedTransportPathsFailClosed() async throws {
        let transport = URLSessionProviderReadinessTransport(
            session: ReadinessURLProtocol.makeSession()
        )
        let request = ProviderReadinessTransportRequest(
            operation: .reachability,
            providerID: "URLSESSION_FAILURES",
            baseURL: URL(string: "https://provider.example/v1")!,
            apiKey: "sk-failure-secret-1234",
            modelID: nil,
            protocolType: .openaiCompatible
        )

        ReadinessURLProtocol.reset { _ in
            .redirect(status: 302, location: "https://redirected.example/v1")
        }
        await #expect(throws: SettingsProviderReadinessTransportError.self) {
            try await transport.send(request)
        }
        #expect(ReadinessURLProtocol.requests().count == 1)

        ReadinessURLProtocol.reset { _ in
            .json(status: 503, object: ["error": "provider unavailable"])
        }
        let response = try await transport.send(request)
        #expect(response.statusCode == 503)
        #expect(response.errorCategory == .server)
        #expect(response.body.isEmpty)

        ReadinessURLProtocol.reset { _ in
            .timeout
        }
        await #expect(throws: SettingsProviderReadinessTransportError.self) {
            try await transport.send(request)
        }

        ReadinessURLProtocol.reset { _ in
            .json(status: 200, object: ["status": "must not send"])
        }
        let unsafeRequest = ProviderReadinessTransportRequest(
            operation: .reachability,
            providerID: "URLSESSION_HTTP",
            baseURL: URL(string: "http://provider.example/v1")!,
            apiKey: "sk-http-secret-1234",
            modelID: nil,
            protocolType: .openaiCompatible
        )
        await #expect(throws: SettingsProviderReadinessTransportError.self) {
            try await transport.send(unsafeRequest)
        }
        #expect(ReadinessURLProtocol.requests().isEmpty)
    }

    @Test("unknown model catalog fields are rejected without forwarding credentials")
    func unknownCatalogFieldsFailClosed() async throws {
        let secret = "sk-unknown-catalog-secret-1234"
        ReadinessURLProtocol.reset { _ in
            .json(status: 200, object: [
                "data": [["id": "gpt-5.6-luna"]],
                "echo": secret
            ])
        }
        let transport = URLSessionProviderReadinessTransport(
            session: ReadinessURLProtocol.makeSession()
        )
        let response = try await transport.send(ProviderReadinessTransportRequest(
            operation: .modelDiscovery,
            providerID: "CATALOG_FIELDS",
            baseURL: URL(string: "https://provider.example/v1")!,
            apiKey: secret,
            modelID: nil,
            protocolType: .openaiCompatible
        ))
        #expect(response.errorCategory == .malformedResponse)
        #expect(response.modelIDs.isEmpty)
        #expect(response.body.isEmpty)
        #expect(ReadinessURLProtocol.requests().count == 1)
    }

    private func makeCenter(session: URLSession) throws -> SettingsCenter {
        try makeCenter(
            transport: URLSessionProviderReadinessTransport(session: session),
            deployment: .remote
        )
    }

    private func makeCenter(
        transport: any SettingsProviderReadinessTransport,
        deployment: ProviderDeployment,
        keychain: KeychainStore = KeychainStore()
    ) throws -> SettingsCenter {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderReadinessURLSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory, keychain: keychain),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 50),
            providerReadinessTransport: transport,
            providerReadinessDeployment: deployment
        )
    }
}

private final class ReadinessURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case json(status: Int, object: [String: Any])
        case raw(status: Int, data: Data)
        case redirect(status: Int, location: String)
        case timeout
    }

    nonisolated(unsafe) private static var handler: ((URLRequest) -> Response)?
    nonisolated(unsafe) private static var seenRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func reset(_ handler: @escaping (URLRequest) -> Response) {
        self.handler = handler
        seenRequests = []
    }

    static func requests() -> [URLRequest] {
        seenRequests
    }

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        configuration.timeoutIntervalForRequest = 0.2
        configuration.timeoutIntervalForResource = 0.2
        return URLSession(configuration: configuration)
    }

    override func startLoading() {
        Self.seenRequests.append(request)
        guard let response = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        switch response {
        case .timeout:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case .redirect(let status, let location):
            guard let url = request.url,
                  let redirectURL = URL(string: location),
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: status,
                      httpVersion: nil,
                      headerFields: ["Location": redirectURL.absoluteString]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: response)
        case .json(let status, let object):
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: status,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .raw(let status, let data):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: status,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
