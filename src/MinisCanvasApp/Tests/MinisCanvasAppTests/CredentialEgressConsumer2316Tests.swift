import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private struct Credential2316NoNetwork: SettingsProviderReadinessTransport {
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// The only synthetic component is the offline Provider I/O boundary. It
/// records the actual AgentLoop request and deliberately returns a secret echo.
private final class Credential2316Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    struct Request: Sendable {
        let messages: [LLMMessage]
        let systemPrompt: String
        let toolDefinitions: Data
    }
    let name = "synthetic-credi2316"
    var model = LLMModel(id: "synthetic-model2316", displayName: "Synthetic 2316", provider: "synthetic-credi2316")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "synthetic-credi2316-configuration"
    private let lock = NSLock()
    private var captured: [Request] = []
    private let path: String
    private let sentinel: String
    init(path: String, sentinel: String) { self.path = path; self.sentinel = sentinel }
    var requests: [Request] { lock.withLock { captured } }
    private func reply(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition]) throws -> LLMResponse {
        let definitions = try JSONSerialization.data(withJSONObject: tools.map(\.openAIFunctionDict), options: [.sortedKeys])
        let ordinal = lock.withLock { () -> Int in
            captured.append(Request(messages: messages, systemPrompt: systemPrompt ?? "", toolDefinitions: definitions))
            return captured.count
        }
        if ordinal == 1 {
            let input: [String: Any] = ["path": path, "public_note": "ordinary2316 argument", "opaque_echo": sentinel]
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)
            return LLMResponse(text: "ordinary2316 assistant call " + sentinel, stopReason: "tool_calls", usage: nil,
                toolCalls: [.init(id: "synthetic2316-file-read", name: "file_read", rawArguments: raw, arguments: input)])
        }
        return LLMResponse(text: "ordinary2316 final answer " + sentinel, stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try reply(messages: messages, systemPrompt: systemPrompt, tools: [])
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try reply(messages: messages, systemPrompt: systemPrompt, tools: tools)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class Credential2316ToolObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(ActionRecord, [ToolExecutionReceipt])] = []
    func record(_ action: ActionRecord, receipts: [ToolExecutionReceipt]) {
        lock.withLock { recorded.append((action, receipts)) }
    }
    var values: [(ActionRecord, [ToolExecutionReceipt])] { lock.withLock { recorded } }
}

@Suite("D-CREDI same-assembly egress consumer2316", .serialized)
@MainActor
struct CredentialEgressConsumer2316Tests {
    private struct Fixture {
        let root: URL
        let center: SettingsCenter
        let chat: ChatStore
        let backing: InMemoryKeychainBacking
        let provider: Credential2316Provider
        let ledger: ToolExecutionFactLedger
        let policyFacts: ComposerPolicyFactSource
        let observations: Credential2316ToolObservation
        let providerID: String
        let sentinel: String
    }
    private func fixture() throws -> Fixture {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("Credential2316-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let backing = InMemoryKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let core = root.appendingPathComponent("core"), sessions = root.appendingPathComponent("chat")
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let center = SettingsCenter(settingsStore: SettingsStore(directory: core),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: sessions), memoryFileStore: MemoryFileStore(directory: sessions),
            sessionStore: SessionStore(directory: sessions),
            sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessTransport: Credential2316NoNetwork(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        try #require(chat.attachPersistence(center.sessionStore, badgeStore: badges))
        let session = try #require(chat.activeSessionID)
        chat.setProject(.init(id: "synthetic2316-project", name: "Synthetic 2316", workingDirectory: root.path), forSession: session)
        let scope = try #require(chat.activeMemoryScope)
        center.memoryScopeProvider = { scope }
        _ = try center.memoryStore.addFact("ordinary2316 scoped memory", sourceSessionID: session.uuidString, memoryScope: scope)
        chat.memoryEnabledProvider = { true }
        chat.memoryInjector = MemoryInjector(store: center.memoryStore)
        chat.credentialBroker.attach(center: center, externalNetworkAllowed: false)
        let sentinel = "SYNTHETIC2316-OPAQUE-" + UUID().uuidString
        // Explicitly owned pre-custody input, not an output or a real backup.
        let input = root.appendingPathComponent("synthetic-input-note.txt")
        try Data(("ordinary2316 tool output\n" + sentinel).utf8).write(to: input)
        let provider = Credential2316Provider(path: input.path, sentinel: sentinel)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("tool-facts.json"))
        let observations = Credential2316ToolObservation()
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID, revision: "synthetic2316-policy",
            grantEpoch: "synthetic2316-epoch", leaseID: "synthetic2316-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        chat.streamingProviderOverride = provider
        chat.composerSubmissionDiagnosticsEnabled = true
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: center.skillStore).snapshotForTurn(), mcpBridge: nil)
        }
        return Fixture(root: root, center: center, chat: chat, backing: backing, provider: provider, ledger: ledger, policyFacts: facts,
            observations: observations, providerID: "SYNTHETIC2316_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))_API_KEY",
            sentinel: sentinel)
    }
    private func assembleEngine(_ f: Fixture) {
        let recording = RecordingToolExecutor(base: BuiltinToolExecutor(allowedRoot: f.root, deniedRoots: []),
            onRecorded: { action in f.observations.record(action, receipts: f.ledger.pendingReceipts) },
            knownSecretValues: ChatTranscriptRedactor(store: f.center.envStore).secretValues)
        f.chat.agentEngine = AgentLoopChatEngine(toolExecutor: recording, requestBudget: f.chat.budgetTracker,
            toolExecutionFactLedger: f.ledger, composerPolicyFacts: f.policyFacts)
    }
    private func assertAbsent(_ value: String, from text: String, outlet: String) {
        let rawAbsent = !text.contains(value)
        #expect(rawAbsent, "complete synthetic sentinel absent from \(outlet)")
    }
    private func confirm(_ f: Fixture, request: ChatCredentialBroker.Request, approved: Bool) async -> ChatCredentialBroker.Outcome {
        await f.chat.credentialBroker.confirm(requestID: request.id, sessionID: request.sessionID,
            providerID: f.providerID, baseURL: "https://synthetic2316.invalid/v1", modelIDs: ["synthetic-model2316"],
            protocolType: .openaiCompatible, riskConfirmed: approved)
    }
    @Test func approvedSyntheticCredentialHasOneActualNonUIEgressChain() async throws {
        let f = try fixture()
        defer { UserDefaults(suiteName: f.root.lastPathComponent)?.removePersistentDomain(forName: f.root.lastPathComponent) }
        let sessionID = try #require(f.chat.activeSessionID)
        let request = try #require(f.chat.credentialBroker.captureSecureField(f.sentinel, sessionID: sessionID))
        try #require(await confirm(f, request: request, approved: true) == .savedProbeBlocked)
        let custodyMatches = f.backing.get(f.providerID) == f.sentinel
        try #require(custodyMatches)
        #expect(await confirm(f, request: request, approved: true) == .rejected)
        assembleEngine(f)
        f.chat.draftText = "ordinary2316 user input " + f.sentinel
        assertAbsent(f.sentinel, from: f.chat.draftText, outlet: "composer draft")
        f.chat.submitComposer()
        let task = try #require(f.chat.turnTaskForTests(sessionID: sessionID))
        await task.value
        try #require(!f.chat.isStreaming)
        let requests = f.provider.requests
        try #require(requests.count == 2)
        for request in requests {
            assertAbsent(f.sentinel, from: String(decoding: try JSONEncoder().encode(request.messages), as: UTF8.self), outlet: "model messages and tool call arguments")
            assertAbsent(f.sentinel, from: request.systemPrompt, outlet: "model system prompt")
            assertAbsent(f.sentinel, from: String(decoding: request.toolDefinitions, as: UTF8.self), outlet: "model tool definitions")
            #expect(request.systemPrompt.contains("ordinary2316 scoped memory"))
        }
        #expect(requests[1].messages.contains { $0.role == .tool && $0.content.contains("ordinary2316 tool output") })
        #expect(requests[1].messages.contains { $0.role == .assistant && !$0.toolCalls.isEmpty })
        let observations = f.observations.values
        try #require(observations.count == 1 && observations[0].0.succeeded)
        try #require(observations[0].1.count == 1)
        assertAbsent(f.sentinel, from: String(decoding: try JSONEncoder().encode(observations[0].0), as: UTF8.self), outlet: "actual RecordingToolExecutor action")
        assertAbsent(f.sentinel, from: String(decoding: try JSONEncoder().encode(observations[0].1), as: UTF8.self), outlet: "actual minted tool receipt")
        let fact = try #require(f.ledger.facts.first)
        #expect(f.ledger.facts.count == 1 && fact.toolName == "file_read" && fact.status == .succeeded)
        #expect(fact.receiptID == observations[0].1[0].receiptID)
        #expect(fact.outputSummary != nil && f.ledger.pendingReceipts.isEmpty)
        assertAbsent(f.sentinel, from: String(decoding: try Data(contentsOf: f.root.appendingPathComponent("tool-facts.json")), as: UTF8.self), outlet: "durable tool fact ledger")
        let saved = try #require(SessionStore(directory: f.center.sessionStore.directory).loadSession(id: sessionID.uuidString))
        #expect(saved.messages.contains { $0.role == .assistant && $0.content.contains("ordinary2316 final answer") })
        assertAbsent(f.sentinel, from: String(decoding: try JSONEncoder().encode(saved), as: UTF8.self), outlet: "reopened canonical transcript")
        assertAbsent(f.sentinel, from: String(decoding: try Data(contentsOf: f.center.sessionStore.sessionsDirectory.appendingPathComponent(sessionID.uuidString + ".json")), as: UTF8.self), outlet: "transcript disk bytes")
        let redactor = ChatTranscriptRedactor(store: f.center.envStore)
        let plain = ChatTranscriptFormatter.plainText(f.chat.messages, redactor: redactor)
        #expect(plain.contains("ordinary2316 final answer") && plain.contains(ContentSecretRedactor.mask(f.sentinel)))
        assertAbsent(f.sentinel, from: plain, outlet: "transcript export formatter")
        try #require(!f.center.logManager.recentLogs().isEmpty)
        assertAbsent(f.sentinel, from: f.center.logManager.recentLogsText(), outlet: "actual log ring")
        assertAbsent(f.sentinel, from: String(decoding: try Data(contentsOf: f.root.appendingPathComponent("logs/app.log")), as: UTF8.self), outlet: "actual durable log")
        let diagnostic = DiagnosticExportController(runtimeSummaryProvider: {
            .init(appState: .ready, activeSessionPresent: f.chat.activeSessionID != nil, activeSessionStreaming: f.chat.isStreaming)
        })
        let destination = f.root.appendingPathComponent("owned-diagnostic.json")
        await diagnostic.export(to: destination)
        let receipt = try #require(diagnostic.lastReceipt)
        try #require(receipt.byteCount > 0)
        let exported = try Data(contentsOf: destination)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(DiagnosticBundle.self, from: exported).runtime.activeSessionPresent == true)
        assertAbsent(f.sentinel, from: String(decoding: exported, as: UTF8.self), outlet: "actual diagnostic export")
        assertAbsent(f.sentinel, from: String(describing: receipt), outlet: "actual diagnostic export receipt")
        let backup = f.root.appendingPathComponent("owned-backup.minissync")
        try #require(!f.center.exportBackup(to: backup).isError)
        let bytes = try Data(contentsOf: backup)
        let envelope = try JSONDecoder().decode(SyncSnapshotEnvelope.self, from: bytes)
        #expect(Set(envelope.manifest.scopes) == Set(SyncScope.allCases.map(\.rawValue)))
        #expect(envelope.sessions?.contains { $0.id == sessionID.uuidString && $0.messages.contains { $0.content.contains("ordinary2316 final answer") } } == true)
        #expect(envelope.memories?.contains { $0.text.contains("ordinary2316 scoped memory") } == true)
        assertAbsent(f.sentinel, from: String(decoding: bytes, as: UTF8.self), outlet: "actual four-domain backup bytes")
        f.chat.stopAllStreamingForSafety()
    }
    @Test func unapprovedSyntheticCredentialCannotProduceModelOrToolEffects() async throws {
        let f = try fixture()
        defer { UserDefaults(suiteName: f.root.lastPathComponent)?.removePersistentDomain(forName: f.root.lastPathComponent) }
        let sessionID = try #require(f.chat.activeSessionID)
        let request = try #require(f.chat.credentialBroker.captureSecureField(f.sentinel, sessionID: sessionID))
        #expect(await confirm(f, request: request, approved: false) == .rejected)
        #expect(f.backing.get(f.providerID) == nil)
        assembleEngine(f)
        f.chat.draftText = "ordinary2316 nonempty request before credential approval"
        try #require(f.chat.credentialBroker.pending?.id == request.id)
        let count = f.chat.messages.count
        f.chat.submitComposer()
        #expect(!f.chat.isStreaming && f.provider.requests.isEmpty)
        #expect(f.chat.messages.count == count && f.observations.values.isEmpty)
        #expect(f.ledger.facts.isEmpty && f.ledger.pendingReceipts.isEmpty)
        #expect(f.center.logManager.recentLogsText().contains("credentialCaptureIntercepted"))
        f.chat.credentialBroker.cancel(sessionID: sessionID)
    }
}
