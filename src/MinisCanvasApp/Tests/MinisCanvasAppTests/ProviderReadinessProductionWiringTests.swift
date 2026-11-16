import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor HeldLocalCatalog {
    private var pending: CheckedContinuation<[String], Never>?
    private var started: CheckedContinuation<Void, Never>?

    func fetch(_: URL) async -> [String] {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilCalled() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(with models: [String]) {
        pending?.resume(returning: models)
        pending = nil
    }
}

@Suite("WP-2 Provider readiness production consumer", .serialized)
@MainActor
struct ProviderReadinessProductionWiringTests {

    @Test("local custom ID is visible before readiness, then explicit fixed-endpoint probe authorizes its runtime")
    func localCustomModelUsesFixedEndpointAndApply() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let chat = ChatStore(providerReadinessStore: store)
        let modelID = "qwen2.5-coder:7b"
        let expectedURL = ChatStore.LocalReadinessBinding.modelsURL
        chat.localModelCatalogSource = { url in
            url == expectedURL ? ["another-model", modelID] : []
        }

        #expect(chat.chatProviderOptions.contains(.builtIn(.local)))
        #expect(chat.chatModelPickerModels(forProviderID: ProviderType.local.rawValue).isEmpty)
        #expect(!chat.applyChatModel(providerID: ProviderType.local.rawValue, modelID: modelID))
        let blankAccepted = await chat.prepareLocalModelSelection(modelID: "  ") { true }
        #expect(!blankAccepted)
        let absentAccepted = await chat.prepareLocalModelSelection(modelID: "not-installed") { true }
        #expect(!absentAccepted)
        #expect(!chat.canSelectChatModel(
            providerID: ProviderType.local.rawValue,
            modelID: "not-installed"
        ))
        let accepted = await chat.prepareLocalModelSelection(modelID: modelID) { true }
        #expect(accepted)
        #expect(chat.chatModelPickerModels(forProviderID: ProviderType.local.rawValue).map(\.id) == [modelID])
        #expect(chat.applyChatModel(providerID: ProviderType.local.rawValue, modelID: modelID))
        #expect(chat.lastChatModelApplyReceipt?.modelID == modelID)
        let provider = try chat.activeProvider()
        #expect(provider is LocalOpenAIProvider)
        #expect(provider.model.id == modelID)
        #expect((provider as? LocalOpenAIProvider)?.baseURL.absoluteString
            == ChatStore.LocalReadinessBinding.baseURL)
        #expect(!chat.providerRuntimeFallbackCandidates().contains(where: {
            $0.providerID == ProviderType.local.runtimeProviderID
        }))
        let selectedSession = try #require(chat.activeSessionID)
        chat.newSession()
        chat.switchSession(id: selectedSession)
        #expect(chat.selectedModelID == modelID)
        #expect(try chat.activeProvider().model.id == modelID)
        #expect(!chat.canSelectChatModel(providerID: ProviderType.openAI.rawValue, modelID: modelID))

        chat.localModelCatalogSource = { _ in [] }
        let recheck = await chat.prepareLocalModelSelection(modelID: modelID) { true }
        #expect(!recheck)
        #expect(!chat.canSelectChatModel(providerID: ProviderType.local.rawValue, modelID: modelID))
        #expect(throws: ChatStoreReadinessError.self) { try chat.activeProvider() }
        chat.localModelCatalogSource = { _ in [modelID] }
        let recovered = await chat.prepareLocalModelSelection(modelID: modelID) { true }
        #expect(recovered)
        #expect(try chat.activeProvider().model.id == modelID)
    }

    @Test("local IDs keep exact case instead of remote model-alias normalization")
    func localModelNameIsExactAcrossSessionRestore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: directory))
        let exactID = "GPT-5.6-luna"
        chat.localModelCatalogSource = { _ in [exactID] }
        let accepted = await chat.prepareLocalModelSelection(modelID: exactID) { true }
        #expect(accepted)
        #expect(chat.applyChatModel(providerID: ProviderType.local.rawValue, modelID: exactID))
        let selectedSession = try #require(chat.activeSessionID)
        chat.newSession()
        chat.switchSession(id: selectedSession)
        #expect(chat.selectedModelID == exactID)
        #expect(try chat.activeProvider().model.id == exactID)
    }

    @Test("late local catalog response after selection change cannot persist an Apply")
    func lateLocalProbeIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let chat = ChatStore(providerReadinessStore: store)
        let held = HeldLocalCatalog()
        chat.localModelCatalogSource = { url in await held.fetch(url) }
        var stillSelected = true
        let task = Task { @MainActor in
            await chat.prepareLocalModelSelection(modelID: "local-one") {
                stillSelected
            }
        }
        await held.waitUntilCalled()
        stillSelected = false
        await held.finish(with: ["local-one"])

        #expect(await task.value == false)
        #expect(store.records.isEmpty)
        #expect(!chat.canSelectChatModel(providerID: ProviderType.local.rawValue, modelID: "local-one"))
    }

    @Test("canceled local probe cannot persist a late response")
    func canceledLocalProbeIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let chat = ChatStore(providerReadinessStore: store)
        let held = HeldLocalCatalog()
        chat.localModelCatalogSource = { url in await held.fetch(url) }
        let task = Task { @MainActor in
            await chat.prepareLocalModelSelection(modelID: "local-one") { true }
        }
        await held.waitUntilCalled()
        task.cancel()
        await held.finish(with: ["local-one"])

        #expect(await task.value == false)
        #expect(store.records.isEmpty)
    }

    @Test("another chat selection made during a local probe rejects its late result")
    func concurrentChatSelectionRejectsLocalProbe() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let chat = ChatStore(providerReadinessStore: store)
        let held = HeldLocalCatalog()
        chat.localModelCatalogSource = { url in await held.fetch(url) }
        let task = Task { @MainActor in
            await chat.prepareLocalModelSelection(modelID: "local-one") { true }
        }
        await held.waitUntilCalled()
        chat.setProvider(.local)
        await held.finish(with: ["local-one"])

        #expect(await task.value == false)
        #expect(store.records.isEmpty)
    }

    @Test("a forged or expired local readiness row cannot authorize a send")
    func localReadinessNeedsCurrentModelEndpointFingerprint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let chat = ChatStore(providerReadinessStore: store)
        let modelID = "local-one"
        store.upsert(ProviderReadinessPersistenceRecord(
            providerID: ProviderType.local.rawValue,
            modelID: modelID,
            status: .passed,
            readinessState: .local,
            checkedAt: Date().addingTimeInterval(-240),
            evidenceID: "local-ollama:" + String(repeating: "a", count: 64),
            isApplied: true,
            configurationFingerprint: "wrong-endpoint",
            expiresAt: Date().addingTimeInterval(60)
        ))
        #expect(!chat.applyChatModel(providerID: ProviderType.local.rawValue, modelID: modelID))

        let checkedAt = Date().addingTimeInterval(-120)
        store.upsert(ProviderReadinessPersistenceRecord(
            providerID: ProviderType.local.rawValue,
            modelID: modelID,
            status: .passed,
            readinessState: .local,
            checkedAt: checkedAt,
            evidenceID: "local-ollama:" + String(repeating: "b", count: 64),
            isApplied: true,
            configurationFingerprint: ChatStore.LocalReadinessBinding.fingerprint(modelID: modelID),
            expiresAt: checkedAt.addingTimeInterval(60)
        ))
        #expect(!chat.applyChatModel(providerID: ProviderType.local.rawValue, modelID: modelID))
    }

    @Test("custom Responses configuration constructs the Responses runtime")
    func customResponsesUsesResponsesRuntime() throws {
        let record = EnvVarEntry(
            name: "RESPONSES_CUSTOM_API_KEY",
            value: "fixture-key",
            isSecret: true,
            baseURL: "https://api.openai.com/v1",
            modelNames: ["gpt-4o"],
            protocolType: .openaiResponses
        )
        let provider = try ChatStore().makeCustomProvider(record: record, modelID: "gpt-4o")
        #expect(provider is OpenAIResponsesProvider)
        #expect(provider.model.id == "gpt-4o")
    }

    @Test("configured same-name provider uses only its current secret record")
    func configuredSameNameCredentialIsBoundToCurrentRecord() throws {
        let previous = EnvCredentials.supplementarySource
        defer {
            EnvCredentials.supplementarySource = previous
            unsetenv("LUNA")
        }
        setenv("LUNA", "unconfigured-process-value", 1)
        EnvCredentials.supplementarySource = { name in
            name == "LUNA" ? "fixture-provider-secret" : nil
        }
        let record = EnvVarEntry(
            id: "configured-luna",
            name: "LUNA",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://luna.example.test/v1",
            modelNames: ["test-model"],
            protocolType: .openaiCompatible
        )
        let chat = ChatStore()
        chat.providerRecordsSource = { [record] }
        chat.schedulerCredentialVersionSource = { _ in "fixture-revision" }

        #expect(EnvCredentials.value(for: "LUNA") == nil)
        let provider = try chat.makeCustomProvider(record: record, modelID: "test-model")
        #expect(provider.model.id == "test-model")

        let replaced = EnvVarEntry(
            id: "replacement-luna",
            name: "LUNA",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: record.baseURL,
            modelNames: record.modelNames,
            protocolType: record.protocolType
        )
        chat.providerRecordsSource = { [replaced] }
        var rejected = false
        do { _ = try chat.makeCustomProvider(record: record, modelID: "test-model") }
        catch { rejected = true }
        #expect(rejected)

        chat.providerRecordsSource = { [record] }
        chat.schedulerCredentialVersionSource = { _ in nil }
        rejected = false
        do { _ = try chat.makeCustomProvider(record: record, modelID: "test-model") }
        catch { rejected = true }
        #expect(rejected)
    }

    @Test("production composition root shares one readiness store")
    func productionCompositionRootSharesOneReadinessStore() throws {
        let appSource = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift"
            ),
            encoding: .utf8
        )

        let assemblySource = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ProductionDomainAssembly.swift"
            ), encoding: .utf8
        )
        // Preserve the original source-only wiring check after moving the
        // real construction blocks. Runtime identity is tested separately.
        let source = appSource + "\n" + assemblySource
        #expect(appSource.contains("ProductionDomainAssembly.makeSettings("))
        #expect(appSource.contains("ProductionDomainAssembly.makeBridge("))


        #expect(
            source.components(separatedBy: "let providerReadinessStore = ProviderReadinessStore(").count - 1 == 1,
            "production must construct exactly one readiness store"
        )
        for contract in [
            "let settings = SettingsCenter(",
            "providerReadinessStore: providerReadinessStore"
        ] {
            #expect(
                source.contains(contract),
                "missing production readiness wiring contract: \(contract)"
            )
        }

        // The composition root has two deliberate construction paths: the
        // durable production bridge on bootstrap success and the disposable
        // blocker bridge on bootstrap failure. Keep this test bound to the
        // branch contract, rather than to a stale one-line declaration.
        let bridgeDeclaration = try #require(source.range(of: "let bridge: BridgeStore"))
        let successStart = try #require(source.range(
            of: "if bootstrapFailure == nil {",
            range: bridgeDeclaration.upperBound..<source.endIndex
        ))
        let failureStart = try #require(source.range(
            of: "} else {",
            range: successStart.upperBound..<source.endIndex
        ))
        let schedulerStart = try #require(source.range(
            of: "return bridge",
            range: failureStart.upperBound..<source.endIndex
        ))
        let successBranch = String(source[successStart.upperBound..<failureStart.lowerBound])
        let failureBranch = String(source[failureStart.upperBound..<schedulerStart.lowerBound])

        #expect(successBranch.contains("AppLaunchCoordinator.resolve("))
        #expect(successBranch.contains("try BridgeStore("))
        #expect(successBranch.contains("providerReadinessStore: providerReadinessStore"))
        #expect(failureBranch.contains("BridgeStore("))
        #expect(failureBranch.contains("providerReadinessStore: providerReadinessStore"))
        #expect(
            source.contains("bridge.chat.providerRecordsSource = { settings.providerRecords }"),
            "production chat consumer must read the live SettingsCenter provider directory"
        )
        #expect(
            source.contains("providerReadinessStore: providerReadinessStore"),
            "production chat consumer must retain the shared readiness store"
        )
    }

    @Test("unverified chat model is not listed or selectable")
    func unverifiedChatModelFailsClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let readinessStore = ProviderReadinessStore(directory: directory)
        readinessStore.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "LUNA",
                modelID: "gpt-5.6-luna",
                status: .unverified,
                readinessState: .unverified,
                checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
                evidenceID: nil,
                isApplied: true
            )
        )

        let chat = ChatStore(providerReadinessStore: readinessStore)
        let provider = EnvVarEntry(
            name: "LUNA",
            value: "fixture",
            isSecret: true,
            baseURL: "https://luna.example.test/v1",
            modelNames: ["gpt-5.6-luna"],
            protocolType: .openaiCompatible
        )
        chat.providerRecordsSource = { [provider] }

        #expect(chat.chatModelPickerModels(forProviderID: "LUNA").isEmpty)
        #expect(!chat.canSelectChatModel(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna"
        ))
        #expect(!chat.applyChatModel(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna"
        ))
        #expect(chat.selectedModelID == nil)
    }

    @Test("built-in model without a readiness record cannot bypass the picker")
    func missingBuiltinReadinessFailsClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let chat = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: directory))
        let modelID = try #require(ProviderType.openAI.builtInModels.first?.id)

        #expect(chat.chatModelPickerModels(forProviderID: ProviderType.openAI.rawValue).isEmpty)
        #expect(!chat.chatProviderOptions.contains(.builtIn(.openAI)))
        #expect(!chat.canSelectChatModel(providerID: ProviderType.openAI.rawValue, modelID: modelID))
        #expect(!chat.applyChatModel(providerID: ProviderType.openAI.rawValue, modelID: modelID))
        #expect(chat.selectedProvider == nil)
        #expect(try chat.activeProvider().name == "Mock")
    }

    @Test("built-in model needs Apply evidence and is fenced again before send")
    func builtinApplyAndRevocationUseTheSameReadinessGate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let readinessStore = ProviderReadinessStore(directory: directory)
        let chat = ChatStore(providerReadinessStore: readinessStore)
        let providerID = ProviderType.openAI.rawValue
        let modelID = try #require(ProviderType.openAI.builtInModels.first?.id)
        let checkedAt = Date()
        let evidenceID = "live-settings:" + String(repeating: "a", count: 64)
        let configured = EnvVarEntry(
            name: providerID.uppercased(),
            value: "fixture-key",
            isSecret: true,
            baseURL: "https://api.openai.com/v1",
            modelNames: [modelID],
            protocolType: .openaiCompatible
        )
        chat.providerRecordsSource = { [configured] }
        var revision = "fixture-revision-1"
        chat.schedulerCredentialVersionSource = { _ in revision }
        let fingerprint = ChatStore.BuiltinReadinessBinding.fingerprint(
            record: configured,
            credentialRevision: revision
        )

        readinessStore.upsert(ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: evidenceID,
            isApplied: false,
            configurationFingerprint: fingerprint
        ))
        #expect(chat.chatModelPickerModels(forProviderID: providerID).isEmpty)
        #expect(!chat.canSelectChatModel(providerID: providerID, modelID: modelID))
        #expect(!chat.applyChatModel(providerID: providerID, modelID: modelID))

        let applied = readinessStore.applyDiscoveredModels(
            providerID: providerID,
            modelIDs: [modelID],
            appliedAt: checkedAt
        )
        #expect(applied.map(\.modelID) == [modelID])
        let storedApply = try #require(readinessStore.records.first { $0.modelID == modelID })
        #expect(storedApply.isApplied)
        #expect(storedApply.evidenceID == evidenceID)
        #expect(storedApply.configurationFingerprint == fingerprint)
        #expect(storedApply.applyReceiptID != nil)
        #expect(storedApply.appliedAt != nil)
        #expect(storedApply.applyReceiptID == applied.first?.applyReceiptID)
        #expect(chat.chatProviderOptions.contains(.builtIn(.openAI)))
        #expect(chat.chatModelPickerModels(forProviderID: providerID).map(\.id).contains(modelID))
        #expect(chat.canSelectChatModel(providerID: providerID, modelID: modelID))
        #expect(chat.applyChatModel(providerID: providerID, modelID: modelID))
        #expect(chat.lastChatModelApplyReceipt?.modelID == modelID)
        #expect(try chat.activeProvider().model.id == modelID)

        revision = "fixture-revision-2"
        #expect(!chat.canSelectChatModel(providerID: providerID, modelID: modelID))
        do {
            _ = try chat.activeProvider()
            Issue.record("changed credential revision reached built-in send")
        } catch let error as ChatStoreReadinessError {
            #expect(error == .modelNotReady(providerID: providerID, modelID: modelID))
        }
        revision = "fixture-revision-1"

        readinessStore.upsert(ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            status: .unavailable,
            readinessState: .blocked,
            checkedAt: checkedAt.addingTimeInterval(2),
            evidenceID: nil,
            isApplied: false
        ))
        #expect(!chat.canSelectChatModel(providerID: providerID, modelID: modelID))
        do {
            _ = try chat.activeProvider()
            Issue.record("revoked built-in readiness reached the send provider")
        } catch let error as ChatStoreReadinessError {
            #expect(error == .modelNotReady(providerID: providerID, modelID: modelID))
        }
    }

    @Test("same-name record at the wrong endpoint cannot authorize a built-in")
    func sameNameWrongEndpointFailsClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let chat = ChatStore(providerReadinessStore: store)
        let providerID = ProviderType.openAI.rawValue
        let modelID = try #require(ProviderType.openAI.builtInModels.first?.id)
        let wrong = EnvVarEntry(
            name: providerID,
            value: "fixture-key",
            isSecret: true,
            baseURL: "https://other.example/v1",
            modelNames: [modelID],
            protocolType: .openaiCompatible
        )
        chat.providerRecordsSource = { [wrong] }
        chat.schedulerCredentialVersionSource = { _ in "fixture-revision" }
        store.upsert(ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            status: .passed,
            readinessState: .live,
            checkedAt: Date(),
            evidenceID: "live-settings:" + String(repeating: "a", count: 64),
            isApplied: true,
            configurationFingerprint: ChatStore.BuiltinReadinessBinding.fingerprint(
                record: wrong,
                credentialRevision: "fixture-revision"
            )
        ))
        #expect(chat.chatModelPickerModels(forProviderID: providerID).isEmpty)
        #expect(!chat.applyChatModel(providerID: providerID, modelID: modelID))
    }

    @Test("forged remote receipt cannot reach picker or activeProvider")
    func forgedRemoteReceiptFailsClosedAtProductionConsumer() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let readinessStore = ProviderReadinessStore(directory: directory)
        readinessStore.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "LUNA",
                modelID: "gpt-5.6-luna",
                status: .passed,
                readinessState: .live,
                checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
                evidenceID: "live-settings:not-a-receipt",
                isApplied: true
            )
        )

        let chat = ChatStore(providerReadinessStore: readinessStore)
        let provider = EnvVarEntry(
            name: "LUNA",
            value: "fixture",
            isSecret: true,
            baseURL: "https://luna.example.test/v1",
            modelNames: ["gpt-5.6-luna"],
            protocolType: .openaiCompatible
        )
        chat.providerRecordsSource = { [provider] }

        #expect(chat.chatModelPickerModels(forProviderID: "LUNA").isEmpty)
        #expect(!chat.applyChatModel(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna"
        ))
        #expect(try chat.activeProvider().name == "Mock")
    }

    @Test("editing provider configuration invalidates readiness and Apply evidence by provider")
    func editingProviderConfigurationInvalidatesProviderReadiness() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let readinessStore = ProviderReadinessStore(directory: directory)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 50),
            providerReadinessStore: readinessStore
        )

        #expect(center.saveProvider(
            name: "CONFIG_CHANGE_PROVIDER",
            apiKey: "old-secret",
            baseURL: "https://old.example/v1",
            modelNames: ["old-model"],
            protocolType: .openaiCompatible
        ))
        let checkedAt = Date().addingTimeInterval(1)
        readinessStore.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "CONFIG_CHANGE_PROVIDER",
                modelID: "old-model",
                status: .passed,
                readinessState: .live,
                checkedAt: checkedAt,
                evidenceID: "live-settings:" + String(repeating: "a", count: 64),
                isApplied: true
            )
        )
        readinessStore.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "OTHER_PROVIDER",
                modelID: "untouched-model",
                status: .passed,
                readinessState: .live,
                checkedAt: checkedAt,
                evidenceID: "live-settings:" + String(repeating: "b", count: 64),
                isApplied: true
            )
        )

        #expect(center.saveProvider(
            name: "CONFIG_CHANGE_PROVIDER",
            apiKey: "new-secret",
            baseURL: "https://new.example/v1",
            modelNames: ["new-model"],
            protocolType: .anthropic
        ))

        let changed = readinessStore.records.filter {
            $0.providerID == "config_change_provider"
        }
        #expect(changed.map(\.modelID) == ["new-model", "old-model"])
        #expect(changed.allSatisfy {
            $0.status == .discovered
                && $0.readinessState == .unverified
                && !$0.isApplied
                && $0.evidenceID == nil
                && $0.applyReceiptID == nil
                && $0.appliedAt == nil
        })

        let untouched = readinessStore.records.first {
            $0.providerID == "other_provider"
        }
        #expect(untouched?.status == .passed)
        #expect(untouched?.evidenceID?.hasPrefix("live-settings:") == true)
        #expect(untouched?.isApplied == true)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "provider-readiness-production-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
