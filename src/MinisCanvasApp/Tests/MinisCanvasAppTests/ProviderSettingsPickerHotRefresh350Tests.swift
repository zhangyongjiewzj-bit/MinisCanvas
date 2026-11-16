import Foundation
import Observation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// D-PROVIDER-07's production data/Observation consumers, not a native view test.
/// One SettingsCenter, its shared readiness store, and one ChatStore survive
/// every save/delete. The retained picker selection deliberately holds the old
/// record just as an already-open ModelPickerPanel can; no picker is reopened.
@Suite("D-PROVIDER-07 provider settings picker hot refresh", .serialized)
@MainActor
struct TESTREG613LegacyProviderSettingsPickerHotRefresh350Tests {
    @Test("same picker consumers observe real saves and typed deletion without rebinding")
    func saveEditDeleteRefreshesRetainedPickerConsumers() throws {
        let fixture = try Fixture()
        let center = fixture.center
        let chat = fixture.chat
        let providerID = "HOT_REFRESH_350"
        #expect(center.saveProvider(
            name: providerID, apiKey: "synthetic-350-key",
            baseURL: "https://fixture.invalid/v1", modelNames: ["old-model"],
            protocolType: .openaiCompatible
        ))
        fixture.markMockReady(providerID: providerID, modelID: "old-model")
        let original = try #require(center.providerRecords.first)
        var selection = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        selection.selectCustomProvider(original)
        let retainedOption = try #require(selection.selectedOption)
        #expect(customNames(chat) == [providerID])
        #expect(models(retainedOption, chat: chat) == ["old-model"])

        // An identical save is the positive control: keep the existing
        // credential and current readiness, with the same bound instances.
        let unchanged = observe(chat, retainedOption)
        #expect(center.saveProvider(
            name: providerID, credential: .keepExisting,
            baseURL: original.baseURL, modelNames: original.modelNames,
            protocolType: original.protocolType
        ))
        // An equal provider snapshot needs no redraw; effective edit/delete
        // below must still invalidate this exact production read dependency.
        #expect(unchanged.count == 0)
        #expect(models(retainedOption, chat: chat) == ["old-model"])

        let edited = observe(chat, retainedOption)
        #expect(center.saveProvider(
            name: providerID, credential: .keepExisting,
            baseURL: original.baseURL, modelNames: ["new-model"],
            protocolType: original.protocolType
        ))
        #expect(edited.count == 1)
        #expect(center.providerRecords.first?.modelNames == ["new-model"])
        #expect(selection.customProvider?.modelNames == ["old-model"])
        #expect(models(retainedOption, chat: chat).isEmpty)
        #expect(!customNames(chat).contains(providerID))
        #expect(!chat.canSelectChatModel(providerID: providerID, modelID: "old-model"))
        #expect(!chat.canSelectChatModel(providerID: providerID, modelID: "new-model"))
        #expect(!selection.confirmed)
        #expect(chat.selectedCustomProvider == nil)
        #expect(chat.lastChatModelApplyReceipt == nil)

        // Explicitly labelled non-live fixture evidence supplies a fresh
        // selectable positive control; saving metadata alone did not do so.
        fixture.markMockReady(providerID: providerID, modelID: "new-model")
        #expect(models(retainedOption, chat: chat) == ["new-model"])
        #expect(customNames(chat) == [providerID])
        #expect(chat.chatModelPickerItems.allSatisfy { !$0.isLiveVerified })

        let deleted = observe(chat, retainedOption)
        let preview = try center.previewProviderDeletion(name: providerID)
        let approved = preview
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try center.deleteProvider(name: providerID, intent: approved)
        #expect(deleted.count == 1)
        #expect(center.providerRecords.isEmpty)
        #expect(customNames(chat).isEmpty)
        #expect(models(retainedOption, chat: chat).isEmpty)
        #expect(center.providerReadinessStore.records.isEmpty)
        #expect(!chat.canSelectChatModel(providerID: providerID, modelID: "new-model"))
        #expect(!selection.confirmed)
        #expect(chat.lastChatModelApplyReceipt == nil)
        #expect(fixture.transport.calls.count == 0)
    }

    @Test("unconfirmed delete and invalid save cannot remove the current picker rows")
    func rejectedMutationsPreserveCurrentPickerRows() throws {
        let fixture = try Fixture()
        let providerID = "HOT_REFRESH_350_GUARD"
        #expect(fixture.center.saveProvider(
            name: providerID, apiKey: "synthetic-350-key",
            baseURL: "https://fixture.invalid/v1", modelNames: ["guard-model"],
            protocolType: .openaiCompatible
        ))
        fixture.markMockReady(providerID: providerID, modelID: "guard-model")
        let record = try #require(fixture.center.providerRecords.first)
        let option = ChatStore.ChatProvider.custom(record)
        let preview = try fixture.center.previewProviderDeletion(name: providerID)
        #expect(throws: (any Error).self) {
            try fixture.center.deleteProvider(name: providerID, intent: preview)
        }
        #expect(!fixture.center.saveProvider(
            name: "invalid name", credential: .keepExisting,
            baseURL: record.baseURL, modelNames: ["other-model"],
            protocolType: .openaiCompatible
        ))
        #expect(fixture.center.providerRecords.map(\.name) == [providerID])
        #expect(customNames(fixture.chat) == [providerID])
        #expect(models(option, chat: fixture.chat) == ["guard-model"])
        #expect(fixture.chat.lastChatModelApplyReceipt == nil)
        #expect(fixture.transport.calls.count == 0)
    }

    private func customNames(_ chat: ChatStore) -> [String] {
        chat.chatProviderOptions.compactMap {
            if case .custom(let record) = $0 { return record.name }
            return nil
        }
    }

    private func models(_ option: ChatStore.ChatProvider, chat: ChatStore) -> [String] {
        ModelPickerPanel.readinessFilteredModels(for: option, chat: chat).map(\.id)
    }

    private func observe(_ chat: ChatStore, _ option: ChatStore.ChatProvider) -> Counter {
        let counter = Counter()
        withObservationTracking {
            _ = chat.chatProviderOptions
            _ = ModelPickerPanel.readinessFilteredModels(for: option, chat: chat)
        } onChange: { counter.increment() }
        return counter
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private final class Transport: SettingsProviderReadinessTransport, @unchecked Sendable {
        let calls = Counter()
        func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
            calls.increment()
            throw SettingsProviderReadinessTransportError.unavailable
        }
    }

    @MainActor
    private struct Fixture {
        let center: SettingsCenter
        let chat: ChatStore
        let transport = Transport()

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("provider350-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // All stores are explicitly injected. Keep generated evidence;
            // this fixture neither reads production data nor deletes a tree.
            let keychain = KeychainStore(backing: InMemoryKeychainBacking())
            let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("provider"))
            let log = LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20)
            let domain = "provider350." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: domain))
            center = SettingsCenter(
                settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("provider"), keychain: keychain),
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
                logManager: log,
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: .suite(domain)),
                providerReadinessTransport: transport,
                providerReadinessDeployment: .mock,
                providerReadinessStore: readiness
            )
            chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
            let authority = center
            chat.providerRecordsSource = { authority.providerRecords }
        }

        func markMockReady(providerID: String, modelID: String) {
            center.providerReadinessStore.upsert(ProviderReadinessPersistenceRecord(
                providerID: providerID, modelID: modelID, status: .passed,
                readinessState: .mock, checkedAt: Date(),
                evidenceID: "provider350-non-live-fixture", isApplied: true
            ))
        }
    }
}
