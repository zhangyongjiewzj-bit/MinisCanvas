import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor HeldM08CredentialRead {
    private var pending: CheckedContinuation<Bool, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func read() async -> Bool {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: Bool) {
        pending?.resume(returning: result)
        pending = nil
    }
}

private final class M08NoNetworkEngine: ChatAgentEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var receivedCount: Int { lock.withLock { calls } }
    var isAvailable: Bool { true }
    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        lock.withLock { calls += 1 }
        return AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int,
        conversationID: String?, authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?, turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity,
        turnRuntimeSnapshot: ChatTurnRuntimeSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        guard conversationID == executionIdentity.turn.sessionID,
              turnID == executionIdentity.turn.turnID,
              composerSnapshot.sessionID == executionIdentity.turn.sessionID,
              composerSnapshot.turnID == executionIdentity.turn.turnID,
              turnRuntimeSnapshot.turn == executionIdentity.turn,
              turnRuntimeSnapshot.skillInjector != nil,
              turnRuntimeSnapshot.mcpBridge != nil else {
            throw ChatTurnRuntimeSnapshotError.identityMismatch
        }
        return try await streamReply(
            provider: provider, history: history,
            systemPrompt: systemPrompt, maxTokens: maxTokens
        )
    }
    func interrupt() {}
    func compactContext(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

@Suite("M08 deferred provider credential at the Composer send boundary", .serialized)
@MainActor
struct P3AcceptanceM08_ProviderCredentialSendPreflightTests {
    private let providerName = "DEEPSEEK_API_KEY"
    private let modelID = "deepseek-v4-pro"

    private func makeCenter(directory: URL, keychain: KeychainStore) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory, keychain: keychain),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m08-credential-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func readyChat(
        record: EnvVarEntry,
        directory: URL,
        records: @escaping () -> [EnvVarEntry],
        revision: @escaping (String) -> String?,
        runtimeCenter: SettingsCenter? = nil
    ) -> ChatStore {
        let readiness = ProviderReadinessStore(directory: directory)
        readiness.upsert(ProviderReadinessPersistenceRecord(
            providerID: record.name,
            modelID: modelID,
            status: .passed,
            readinessState: .live,
            checkedAt: Date(),
            evidenceID: "live-settings:" + String(repeating: "a", count: 64),
            isApplied: true
        ))
        let defaults = UserDefaults(suiteName: "m08-provider-credential-\(UUID().uuidString)")!
        let chat = ChatStore(
            providerReadinessStore: readiness,
            preferencesDefaults: defaults,
            logManager: LogManager(directory: directory, ringCapacity: 20)
        )
        chat.providerRecordsSource = records
        chat.schedulerCredentialVersionSource = revision
        // Match BridgeStore's turn preparation from this isolated profile's
        // actual Skill/MCP stores. An empty catalog is still a prepared turn.
        let center = runtimeCenter ?? makeCenter(
            directory: directory, keychain: KeychainStore(backing: InMemoryKeychainBacking())
        )
        let injector = SkillInjector(store: center.skillStore)
        let registry = MCPToolRegistry(manager: center.mcpManager)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(
                turn: turn, skillInjector: nil,
                skillPreparation: injector.captureTurnPreparation(),
                mcpBridge: nil,
                mcpBridgePreparation: registry.captureTurnSnapshotPreparation()
            )
        }
        #expect(chat.applyChatModel(providerID: record.name, modelID: modelID))
        return chat
    }

    private func waitForSubmission(_ chat: ChatStore) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if !chat.isStreaming && !chat.isComposerCredentialPreflightPending {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test("persisted readiness can send after one async profile-scoped Keychain read")
    func coldCacheResolvesBeforeConsumingDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let original = makeCenter(directory: directory, keychain: keychain)
        #expect(original.saveProvider(
            name: providerName,
            apiKey: "synthetic-deepseek-key",
            baseURL: "https://api.deepseek.com",
            modelNames: [modelID],
            protocolType: .openaiCompatible
        ))
        let reopened = makeCenter(directory: directory, keychain: keychain)
        let record = try #require(reopened.providerRecords.first)
        #expect(record.valueInKeychain && record.value.isEmpty)
        #expect(reopened.envStore.getEnvVar(name: providerName) == nil)
        let revision = try #require(reopened.providerCredentialBinding(recordID: record.id)?.revision)
        let chat = readyChat(
            record: record,
            directory: directory,
            records: { reopened.providerRecords },
            revision: { _ in reopened.providerCredentialBinding(recordID: record.id)?.revision },
            runtimeCenter: reopened
        )
        chat.providerCredentialPreflightSource = { id, name, expectedRevision in
            guard id == record.id, name == record.name, expectedRevision == revision,
                  case .success(let value) = await reopened.providerCredentialReadAsync(named: name),
                  !value.isEmpty else { return false }
            reopened.reloadEnv()
            return reopened.providerCredentialBinding(recordID: id)?.revision == expectedRevision
        }
        let engine = M08NoNetworkEngine()
        chat.agentEngine = engine
        chat.draftText = "你好"
        chat.submitComposer()
        #expect(chat.draftText.isEmpty)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(await waitForSubmission(chat))
        #expect(engine.receivedCount == 1)
        #expect(chat.messages.filter({ $0.role == .user }).count == 1)
        #expect(reopened.providerRecords.first?.value.isEmpty == false)
        #expect(try chat.activeProvider().model.id == modelID)
    }

    @Test("failed Keychain read keeps the committed turn, visibly fails it and invokes no engine")
    func failedReadPreservesDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = EnvVarEntry(
            name: providerName, value: "", isSecret: true, valueInKeychain: true,
            baseURL: "https://api.deepseek.com", modelNames: [modelID],
            protocolType: .openaiCompatible
        )
        let chat = readyChat(record: record, directory: directory,
                             records: { [record] }, revision: { _ in "synthetic-revision" })
        let engine = M08NoNetworkEngine()
        chat.agentEngine = engine
        let held = HeldM08CredentialRead()
        chat.providerCredentialPreflightSource = { _, _, _ in await held.read() }
        chat.draftText = "保留的草稿"
        chat.submitComposer()
        await held.waitUntilStarted()
        await held.finish(false)
        #expect(await waitForSubmission(chat))
        #expect(chat.draftText.isEmpty)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.messages.last?.content.contains("错误") == true)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(engine.receivedCount == 0)
        let sessionID = try #require(chat.activeSessionID)
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .failed)
    }

    @Test("session away-and-back retains the submitted turn and executes exactly once")
    func sessionTransitionRejectsLateRead() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = EnvVarEntry(
            name: providerName, value: "", isSecret: true, valueInKeychain: true,
            baseURL: "https://api.deepseek.com", modelNames: [modelID],
            protocolType: .openaiCompatible
        )
        var current = record
        let chat = readyChat(record: record, directory: directory,
                             records: { [current] }, revision: { _ in "synthetic-revision" })
        let engine = M08NoNetworkEngine()
        chat.agentEngine = engine
        let held = HeldM08CredentialRead()
        chat.providerCredentialPreflightSource = { _, _, _ in
            let available = await held.read()
            if available { current.value = "synthetic-owned-key" }
            return available
        }
        chat.draftText = "原会话草稿"
        let sourceSession = try #require(chat.activeSessionID)
        chat.submitComposer()
        await held.waitUntilStarted()
        chat.newSession()
        chat.switchSession(id: sourceSession)
        await held.finish(true)
        #expect(await waitForSubmission(chat))
        #expect(chat.draftText.isEmpty)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.messages.first { $0.role == .user }?.content == "原会话草稿")
        #expect(chat.messages.last?.isStreaming == false)
        #expect(engine.receivedCount == 1)
    }

    @Test("same-name replacement or credential revision cannot authorize the committed turn", arguments: [false, true])
    func recordRebindRejectsLateRead(replaceRecord: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = EnvVarEntry(
            name: providerName, value: "", isSecret: true, valueInKeychain: true,
            baseURL: "https://api.deepseek.com", modelNames: [modelID],
            protocolType: .openaiCompatible
        )
        var current = record
        var revision = "synthetic-revision-1"
        let chat = readyChat(record: record, directory: directory,
                             records: { [current] }, revision: { _ in revision })
        let engine = M08NoNetworkEngine()
        chat.agentEngine = engine
        let held = HeldM08CredentialRead()
        chat.providerCredentialPreflightSource = { _, _, _ in await held.read() }
        chat.draftText = "保留的草稿"
        chat.submitComposer()
        await held.waitUntilStarted()
        if replaceRecord {
            current = EnvVarEntry(
            name: providerName, value: "", isSecret: true, valueInKeychain: true,
            baseURL: "https://api.deepseek.com", modelNames: [modelID],
            protocolType: .openaiCompatible
        )
        } else {
            revision = "synthetic-revision-2"
        }
        await held.finish(true)
        #expect(await waitForSubmission(chat))
        #expect(chat.draftText.isEmpty)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.messages.last?.content.contains("错误") == true)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(engine.receivedCount == 0)
        let sessionID = try #require(chat.activeSessionID)
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .failed)
    }
}
