import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class CredentialMemoryPromptProvider1983: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "credi-memory-fixture"
    var model = LLMModel(id: "credi-memory", displayName: "CREDI Memory", provider: "credi-memory-fixture")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "credi-memory-synthetic"
    private let lock = NSLock()
    private var prompts: [String] = []
    private var requests: [[LLMMessage]] = []

    var capturedPrompts: [String] { lock.withLock { prompts } }
    var capturedRequests: [[LLMMessage]] { lock.withLock { requests } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock {
            prompts.append(systemPrompt ?? "")
            requests.append(messages)
        }
        return LLMResponse(text: "正常回答", stopReason: "stop", usage: nil)
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

@Suite("D-CREDI scoped memory to actual model prompt")
@MainActor
struct CredentialMemoryPromptConsumer1983Tests {
    @Test func savedOpaqueValueInEarlierMemoryCannotReachProviderPrompt() async throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let defaultsDomain = "credi-memory-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        let sessions = SessionStore(directory: root.appendingPathComponent("chat"))
        try #require(chat.attachPersistence(sessions))
        let sessionID = try #require(chat.activeSessionID)
        chat.setProject(.init(id: "credi-project", name: "Synthetic", workingDirectory: root.path), forSession: sessionID)
        let scope = try #require(chat.activeMemoryScope)
        let secret = "CREDI-MEMORY-OPAQUE-" + UUID().uuidString
        // The scoped fact predates local custody of the same opaque value.
        try center.memoryStore.addFact("项目代号是 " + secret + "，普通偏好是晴天",
            sourceSessionID: sessionID.uuidString, memoryScope: scope)
        let request = try #require(chat.credentialBroker.captureSecureField(secret, sessionID: sessionID))
        chat.credentialBroker.attach(center: center, externalNetworkAllowed: false)
        #expect(await CredentialTestSupport.confirm(chat.credentialBroker, request: request) == .savedProbeBlocked)
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == secret)

        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID,
            revision: "credi-memory-policy", grantEpoch: "credi-memory-epoch",
            leaseID: "credi-memory-lease", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.memoryEnabledProvider = { true }
        chat.memoryInjector = MemoryInjector(store: center.memoryStore)
        let provider = CredentialMemoryPromptProvider1983()
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        chat.agentEngine = engine
        chat.streamingProviderOverride = provider
        chat.draftText = "项目代号和普通偏好是什么？"
        chat.submitComposer()
        let deadline = Date().addingTimeInterval(15)
        while chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming)
        try #require(provider.capturedPrompts.count == 1)
        let prompt = provider.capturedPrompts[0]
        #expect(!prompt.contains(secret))
        #expect(prompt.contains(ContentSecretRedactor.mask(secret)))
        #expect(prompt.contains("普通偏好是晴天"))
        #expect(provider.capturedRequests.count == 1)
        #expect(provider.capturedRequests.flatMap { $0 }.allSatisfy { !$0.content.contains(secret) })
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
        chat.stopAllStreamingForSafety()
    }
}
