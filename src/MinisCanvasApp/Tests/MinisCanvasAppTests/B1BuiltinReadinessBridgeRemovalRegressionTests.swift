import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
struct B1BuiltinReadinessBridgeRemovalRegressionTests {

    @Test
    func missingBuiltinReadinessFailsClosed() throws {
        let directory = try B1ARCHOriginalFixtureSupport.makeRoot("builtin-readiness-regression")
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(directory) }

        let chat = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: directory))
        let modelID = try #require(ProviderType.openAI.builtInModels.first?.id)

        #expect(chat.chatModelPickerModels(forProviderID: ProviderType.openAI.rawValue).isEmpty)
        #expect(!chat.chatProviderOptions.contains(.builtIn(.openAI)))
        #expect(!chat.canSelectChatModel(providerID: ProviderType.openAI.rawValue, modelID: modelID))
        #expect(!chat.applyChatModel(providerID: ProviderType.openAI.rawValue, modelID: modelID))
        #expect(chat.selectedProvider == nil)
        #expect(try chat.activeProvider().name == "Mock")
    }

    @Test
    func builtinApplyAndRevocationUseTheSameReadinessGate() throws {
        let directory = try B1ARCHOriginalFixtureSupport.makeRoot("builtin-readiness-regression")
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(directory) }

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

    @Test
    func sameNameWrongEndpointFailsClosed() throws {
        let directory = try B1ARCHOriginalFixtureSupport.makeRoot("builtin-readiness-regression")
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(directory) }
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

    @Test
    func editingProviderConfigurationInvalidatesProviderReadiness() throws {
        let directory = try B1ARCHOriginalFixtureSupport.makeRoot("builtin-readiness-regression")
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(directory) }

        let readinessStore = ProviderReadinessStore(directory: directory)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: try B1ARCHOriginalFixtureSupport.inputs(directory).env,
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            sessionBadgeStore: try B1ARCHOriginalFixtureSupport.inputs(directory).badges,
            logManager: LogManager(directory: directory, ringCapacity: 50),
            mcpManager: try B1ARCHOriginalFixtureSupport.inputs(directory).mcp,
            skillStore: try B1ARCHOriginalFixtureSupport.inputs(directory).skills,
            usageStore: UsageStore(domain: .suite(try B1ARCHOriginalFixtureSupport.inputs(directory).defaultsSuite)),
            shortcutStore: ShortcutStore(defaults: try B1ARCHOriginalFixtureSupport.inputs(directory).defaults),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
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
}
