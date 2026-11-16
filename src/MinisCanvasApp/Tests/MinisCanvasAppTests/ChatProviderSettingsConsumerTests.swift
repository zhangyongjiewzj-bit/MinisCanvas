import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3 chat provider settings consumer")
@MainActor
struct ChatProviderSettingsConsumerTests {
    private func makeCenter() throws -> (SettingsCenter, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3-chat-provider-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain)
        )
        return (center, root)
    }

    @Test func displayRenameUpdatesUsagePresentationWithoutReassigningCalls() async throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        #expect(center.saveProvider(name: "FIXTURE_DISPLAY_API_KEY", credential: .replace("synthetic-only"),
            baseURL: "https://example.invalid/v1", modelNames: ["model-a"], protocolType: .openaiCompatible,
            displayName: "旧 显示名"))
        let record = try #require(center.providerRecords.first { $0.name == "FIXTURE_DISPLAY_API_KEY" })
        center.usageStore.recordCall(provider: record.name, model: "model-a", inputTokens: 4, outputTokens: 2,
            providerRecordID: record.id, providerDisplaySnapshot: record.providerDisplayName)
        _ = await center.usageStore.waitForPersistence()
        #expect(center.saveProvider(name: record.name, credential: .keepExisting,
            baseURL: record.baseURL, modelNames: record.modelNames, protocolType: record.protocolType,
            displayName: "新 显示名"))
        _ = await center.usageStore.waitForPersistence()
        let projection = try #require(center.usageStore.providerUsageProjection.first { $0.providerRecordID == record.id })
        #expect(projection.providerDisplayName == "新 显示名")
        let call = try #require(center.usageStore.callHistory.first { $0.providerRecordID == record.id })
        #expect(call.provider == record.name && call.providerDisplaySnapshot == "旧 显示名")
        #expect(center.providerRecords.first { $0.id == record.id }?.name == record.name)
    }

    private func removeFixture(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("preview validates safe provider metadata and keeps credentials opaque")
    func previewValidationAndEncoding() throws {
        let handle = BL6CredentialHandle(id: "chat-key-handle")
        let preview = try ChatProviderSettingsPreview(
            requestID: "chat-preview",
            providerID: "DEEPSEEK_API_KEY",
            baseURL: "https://api.deepseek.com/v1",
            modelIDs: ["deepseek-v4-flash"],
            protocolType: .openaiCompatible,
            credential: .opaqueHandle(handle),
            expectedRevision: "settings-revision"
        )
        let encoded = try JSONEncoder().encode(preview)
        let wire = String(decoding: encoded, as: UTF8.self)
        #expect(wire.contains("chat-key-handle"))
        #expect(!wire.contains("fixture-secret"))
        #expect(preview.baseURL == "https://api.deepseek.com/v1")
        #expect(throws: ChatProviderSettingsValidationError.invalidBaseURL) {
            try ChatProviderSettingsPreview(
                providerID: "PROVIDER",
                baseURL: "http://remote.example/v1",
                modelIDs: ["model"],
                protocolType: .openaiCompatible,
                expectedRevision: "revision"
            )
        }
        #expect(throws: ChatProviderSettingsValidationError.invalidModelID) {
            try ChatProviderSettingsPreview(
                providerID: "PROVIDER",
                baseURL: "https://provider.example/v1",
                modelIDs: ["model", "model"],
                protocolType: .openaiCompatible,
                expectedRevision: "revision"
            )
        }
    }

    @Test("chat confirm persists metadata and reopen never exposes a key")
    func confirmPersistAndReopen() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        var resolverCalled = false
        center.bl6CredentialResolver = { handle in
            resolverCalled = true
            return handle.id == "opaque" ? "fixture-secret" : nil
        }
        let preview = try center.makeChatProviderSettingsPreview(
            requestID: "persist",
            providerID: "P3_TEST_PROVIDER_API_KEY",
            baseURL: "https://provider.example/v1",
            modelIDs: ["model-a"],
            protocolType: .openaiCompatible,
            credential: .opaqueHandle(BL6CredentialHandle(id: "opaque"))
        ).get()
        let result = center.confirmChatProviderSettings(preview, approvalReceiptID: "confirm-persist")
        guard case .success = result else {
            Issue.record("typed provider confirmation failed: (result)")
            return
        }
        #expect(resolverCalled)
        let reopened = try #require(center.chatProviderSettingsProjection(providerID: "P3_TEST_PROVIDER_API_KEY"))
        #expect(reopened.baseURL == "https://provider.example/v1")
        #expect(reopened.modelIDs == ["model-a"])
        #expect(reopened.credentialPresent)
        #expect(!String(describing: reopened).contains("fixture-secret"))
    }

    @Test("chat panel consumer reopens persisted metadata and exposes only recovery action")
    func panelConsumerClosure() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        center.bl6CredentialResolver = { handle in
            handle.id == "opaque" ? "fixture-secret" : nil
        }
        let result = ModelConfigPanelView.submitChatProviderSettings(
            center: center,
            requestID: "panel-submit",
            providerID: "P3_PANEL_PROVIDER_API_KEY",
            baseURL: "https://provider.example/v1",
            modelIDs: ["model-a"],
            protocolType: .openaiCompatible,
            credential: .opaqueHandle(BL6CredentialHandle(id: "opaque")),
            approvalReceiptID: "panel-approved"
        )
        guard case let .success(state) = result else {
            Issue.record("chat panel submission failed")
            return
        }
        #expect(state.providerID == "P3_PANEL_PROVIDER_API_KEY")
        #expect(state.credentialPresent)
        #expect(state.nextAction == nil)
        #expect(!String(describing: state).contains("fixture-secret"))

        let failedState = ModelConfigPanelView.chatProviderSettingsPanelState(
            center: center,
            providerID: "P3_PANEL_PROVIDER_API_KEY",
            recoveryState: .reopenRequired
        )
        #expect(failedState.nextAction == .reopen)
        #expect(failedState.metadataRevision != nil)
    }

    @Test("provider metadata CAS rejects stale preview and maps recovery safely")
    func metadataCASAndRecovery() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        center.bl6CredentialResolver = { _ in "opaque-secret" }
        let first = try center.makeChatProviderSettingsPreview(
            requestID: "first",
            providerID: "P3_CAS_PROVIDER_API_KEY",
            baseURL: "https://provider.example/v1",
            modelIDs: ["one"],
            protocolType: .openaiCompatible,
            credential: .opaqueHandle(BL6CredentialHandle(id: "one"))
        ).get()
        _ = center.confirmChatProviderSettings(first, approvalReceiptID: "approved")
        let second = try center.makeChatProviderSettingsPreview(
            requestID: "second",
            providerID: "P3_CAS_PROVIDER_API_KEY",
            baseURL: "https://provider.example/v2",
            modelIDs: ["two"],
            protocolType: .openaiCompatible
        ).get()
        let changed = try center.makeChatProviderSettingsPreview(
            requestID: "changed",
            providerID: "P3_CAS_PROVIDER_API_KEY",
            baseURL: "https://provider.example/v3",
            modelIDs: ["three"],
            protocolType: .openaiCompatible
        ).get()
        _ = center.confirmChatProviderSettings(changed, approvalReceiptID: "changed")
        guard case let .failure(error) = center.confirmChatProviderSettings(second, approvalReceiptID: "stale") else {
            Issue.record("stale metadata preview unexpectedly succeeded")
            return
        }
        guard case .staleRevision = error else {
            Issue.record("unexpected stale metadata error: (error)")
            return
        }
        #expect(SettingsCenter.chatProviderSettingsRecoveryState(for: error) == .reopenRequired)
        #expect(SettingsCenter.chatProviderSettingsRecoveryState(for: .transactionUnknown) == .blockedTransactionUnknown)
    }

    @Test("rollback restores metadata only and fences the post-edit revision")
    func metadataOnlyRollback() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        center.bl6CredentialResolver = { _ in "opaque-secret" }
        let initial = try center.makeChatProviderSettingsPreview(
            requestID: "initial",
            providerID: "P3_ROLLBACK_PROVIDER_API_KEY",
            baseURL: "https://provider.example/v1",
            modelIDs: ["one"],
            protocolType: .openaiCompatible,
            credential: .opaqueHandle(BL6CredentialHandle(id: "one"))
        ).get()
        _ = center.confirmChatProviderSettings(initial, approvalReceiptID: "initial")
        let token = try center.captureChatProviderSettingsRollbackToken(providerID: "P3_ROLLBACK_PROVIDER_API_KEY").get()
        let edited = try center.makeChatProviderSettingsPreview(
            requestID: "edited",
            providerID: "P3_ROLLBACK_PROVIDER_API_KEY",
            baseURL: "https://provider.example/v2",
            modelIDs: ["two"],
            protocolType: .openaiCompatible
        ).get()
        _ = center.confirmChatProviderSettings(edited, approvalReceiptID: "edited")
        let afterEdit = try #require(center.chatProviderSettingsProjection(providerID: "P3_ROLLBACK_PROVIDER_API_KEY"))
        let result = center.rollbackChatProviderSettings(
            token,
            approvalReceiptID: "rollback",
            expectedCurrentProviderRevision: afterEdit.metadataRevision
        )
        guard case .success = result else {
            Issue.record("metadata rollback failed: (result)")
            return
        }
        let reopened = try #require(center.chatProviderSettingsProjection(providerID: "P3_ROLLBACK_PROVIDER_API_KEY"))
        #expect(reopened.baseURL == "https://provider.example/v1")
        #expect(reopened.modelIDs == ["one"])
    }

    @Test("rollback requires a non-empty approval receipt")
    func rollbackApprovalFence() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let token = try center.captureChatProviderSettingsRollbackToken(
            providerID: "P3_EMPTY_APPROVAL_PROVIDER"
        ).get()
        guard case let .failure(error) = center.rollbackChatProviderSettings(
            token,
            approvalReceiptID: "   "
        ) else {
            Issue.record("rollback without approval unexpectedly succeeded")
            return
        }
        #expect(error == .dispatch(.approvalRequired))
    }
}
