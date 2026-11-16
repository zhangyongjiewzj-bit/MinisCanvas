import AppKit
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class CredentialModelRecorder: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { true }
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var histories: [[String]] { lock.withLock { recorded } }
    private func record(_ history: [ChatMessageUI]) { lock.withLock { recorded.append(history.map(\.content)) } }
    func streamReply(provider: any LLMProvider, history: [ChatMessageUI], systemPrompt: String,
                     maxTokens: Int) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        record(history)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("正常回复"))
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
    func interrupt() {}
    func compactContext(provider: any LLMProvider, history: [ChatMessageUI], systemPrompt: String,
                        keepRecent: Int) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

/// The real AgentLoopChatEngine calls this offline Provider. The Provider
/// deliberately echoes a synthetic saved value so the output path is tested
/// independently of the input path.
private final class CredentialKnownValueProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "credi-isolated"
    var model = LLMModel(id: "credi-model", displayName: "CREDI", provider: "credi-isolated")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "credi-synthetic"
    private let secret: String
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    private var prompts: [String] = []

    init(secret: String) { self.secret = secret }
    var requests: [[LLMMessage]] { lock.withLock { captured } }
    var systemPrompts: [String] { lock.withLock { prompts } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock {
            captured.append(messages)
            prompts.append(systemPrompt ?? "")
        }
        return LLMResponse(text: "正常答复 " + secret, stopReason: "stop", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Credential production input and durable boundaries") @MainActor
struct ChatCredentialBoundaryTests {
    @Test func confirmedOpaqueCredentialStaysOutOfActualModelTranscriptAndAccessibility() async throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let defaultsDomain = "credi-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        let sessions = SessionStore(directory: root.appendingPathComponent("chat"))
        try #require(chat.attachPersistence(sessions))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID,
            revision: "credi-isolated-policy", grantEpoch: "credi-isolated-epoch",
            leaseID: "credi-isolated-lease", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .auto, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false)
        let sessionID = try #require(chat.activeSessionID)
        let secret = "CREDI-OPAQUE-" + UUID().uuidString
        let request = try #require(chat.credentialBroker.captureSecureField(secret, sessionID: sessionID))
        chat.credentialBroker.attach(center: center, externalNetworkAllowed: false)
        #expect(await CredentialTestSupport.confirm(chat.credentialBroker, request: request) == .savedProbeBlocked)
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == secret)
        #expect(chat.credentialBroker.pending == nil)

        let provider = CredentialKnownValueProvider(secret: secret)
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        chat.agentEngine = engine
        chat.streamingProviderOverride = provider
        chat.draftText = "请解释这段占位符：" + secret
        #expect(!chat.draftText.contains(secret))
        #expect(chat.draftText.contains(ContentSecretRedactor.mask(secret)))
        #expect(chat.credentialBroker.pending == nil)
        chat.submitComposer()
        let deadline = Date().addingTimeInterval(15)
        while chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming)
        let requests = provider.requests
        try #require(requests.count == 1)
        #expect(requests.flatMap { $0 }.allSatisfy { !$0.content.contains(secret) })
        #expect(requests[0].contains {
            $0.role == .user && $0.content.contains(ContentSecretRedactor.mask(secret))
        })
        #expect(provider.systemPrompts.allSatisfy { !$0.contains(secret) })
        #expect(chat.messages.contains {
            $0.role == .assistant && $0.content.contains("正常答复")
                && $0.content.contains(ContentSecretRedactor.mask(secret))
        })
        #expect(chat.messages.allSatisfy { !$0.content.contains(secret) })
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
        #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)

        let redactor = ChatTranscriptRedactor(store: center.envStore)
        #expect(!ChatTranscriptFormatter.plainText(chat.messages, redactor: redactor).contains(secret))
        #expect(!ChatTranscriptFormatter.accessibilityText(chat.messages, redactor: redactor).contains(secret))
        let persisted = try #require(SessionStore(directory: sessions.directory).loadSession(id: sessionID.uuidString))
        #expect(persisted.messages.allSatisfy { !$0.content.contains(secret) })
        try CredentialTestSupport.assertAbsent(secret, under: root)
        chat.stopAllStreamingForSafety()
    }
    @Test func blockedCredentialNeverReachesModelAndOrdinaryTurnStillRuns() async throws {
        let chat = ChatStore()
        let recorder = CredentialModelRecorder()
        chat.agentEngine = recorder
        let secret = "sk-synthetic-model-" + UUID().uuidString
        chat.draftText = "保存 " + secret
        chat.submitComposer()
        #expect(!chat.isStreaming)
        #expect(recorder.histories.isEmpty)
        chat.credentialBroker.cancel()
        chat.draftText = "普通后续问题"
        chat.submitComposer()
        for _ in 0..<100 where chat.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!chat.isStreaming)
        #expect(recorder.histories.count == 1)
        #expect(recorder.histories.flatMap { $0 }.allSatisfy { !$0.contains(secret) })
        chat.stopAllStreamingForSafety()
    }
    @Test func actualShortAndLongPasteNeverInsertCredentialIntoNativeTextView() throws {
        for padding in ["", String(repeating: "引用 ", count: 800)] {
            let chat = ChatStore()
            let value = "sk-synthetic-paste-" + UUID().uuidString
            let view = ComposerPasteAwareTextView(frame: .zero)
            view.string = "body "
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            view.pasteboardStringProvider = { padding + value }
            view.onPasteEvent = { chat.interceptCredentialPaste($0) || PastedTextComposerConsumer.accept($0, in: chat) }
            view.paste(nil)
            #expect(view.string == "body ")
            #expect(!chat.draftText.contains(value))
            #expect(chat.credentialBroker.pending != nil)
            let count = chat.messages.count
            chat.submitComposer()
            #expect(chat.messages.count == count)
            #expect(!chat.isStreaming)
            chat.credentialBroker.cancel()
        }
    }

    @Test func draftCapsuleTranscriptAndRestartNeverPersistNewSyntheticCredential() throws {
        let (center, _, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionStore = SessionStore(directory: root.appendingPathComponent("chat"))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        let chat = ChatStore(logManager: center.logManager)
        #expect(chat.attachPersistence(sessionStore))
        chat.attachDraftStore(drafts)
        let value = "sk-synthetic-durable-" + UUID().uuidString
        chat.draftText = "保存 " + value
        drafts.flushAll()
        #expect(!chat.draftText.contains(value))
        let sessionID = try #require(chat.activeSessionID)
        #expect(chat.setPastedTextDraft(PastedTextDraft(id: UUID(), text: value, source: .pasteboard)))
        chat.appendUser(value)
        chat.appendAssistant(value)
        chat.touchSession(sessionID)
        try CredentialTestSupport.assertAbsent(value, under: root)
        let reopened = SessionStore(directory: sessionStore.directory)
        let persisted = try #require(reopened.loadSession(id: sessionID.uuidString))
        #expect(persisted.messages.allSatisfy { !$0.content.contains(value) })
        #expect(!persisted.title.contains(value))
        chat.credentialBroker.cancel(sessionID: sessionID)
    }

    @Test func streamReplacementAndLateRejectedWritebackCannotLeak() throws {
        let chat = ChatStore()
        chat.appendAssistant("", toSession: chat.activeSessionID, isStreaming: true)
        let session = try #require(chat.activeSessionID)
        let index = chat.messages.count - 1
        let secret = "sk-synthetic-output-" + UUID().uuidString
        for character in secret {
            #expect(chat.updateMessageContent(sessionID: session, at: index, append: String(character)))
            #expect(!chat.messages[index].content.contains(secret))
        }
        #expect(chat.replaceMessageContent(sessionID: session, at: index, with: secret))
        #expect(!chat.messages[index].content.contains(secret))
        let messageID = chat.messages[index].id
        let stale = AgentTurnIdentity(sessionID: session.uuidString, turnID: -1, messageID: messageID.uuidString)
        #expect(!chat.updateMessageContent(sessionID: session, messageID: messageID, identity: stale, append: secret))
        #expect(!chat.messages[index].content.contains(secret))
    }

    @Test func ordinaryTextAndReferencePasteKeepExistingSemantics() {
        let chat = ChatStore()
        chat.draftText = "正常讨论，不含凭据"
        #expect(chat.draftText == "正常讨论，不含凭据")
        #expect(!chat.interceptCredentialPaste(ComposerPasteEvent(text: "普通短文本")))
        #expect(PastedTextComposerConsumer.accept(ComposerPasteEvent(text: String(repeating: "普通引用", count: 600)), in: chat))
        #expect(chat.activePastedTextDraft != nil)
        #expect(chat.credentialBroker.pending == nil)
    }
}
