import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class CredentialNativeEchoProvider2027: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "credi-native-echo-fixture"
    var model = LLMModel(id: "credi-native-model", displayName: "CREDI Native", provider: "credi-native-echo-fixture")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "credi-native-synthetic"
    private let lock = NSLock()
    private let path: String
    private let secret: String
    private var captured: [[LLMMessage]] = []

    init(path: String, secret: String) {
        self.path = path
        self.secret = secret
    }

    var requests: [[LLMMessage]] { lock.withLock { captured } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let turn = lock.withLock { () -> Int in
            captured.append(messages)
            return captured.count
        }
        guard turn == 1 else {
            return LLMResponse(text: "读取已完成。", stopReason: "stop", usage: nil)
        }
        let input: [String: Any] = ["path": path, "public_note": "正常注释", "opaque_echo": secret]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: input,
            options: [.sortedKeys]), as: UTF8.self)
        return LLMResponse(text: "正在读取公开记录 " + secret,
            stopReason: "tool_calls", usage: nil, toolCalls: [
                LLMToolCall(id: "credi-native-read", name: "file_read",
                    rawArguments: raw, arguments: input)
            ])
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

@Suite("D-CREDI actual native assistant history outbound")
@MainActor
struct CredentialAssistantHistoryOutbound2027Tests {
    @Test func knownOpaqueEchoInNativeAssistantCallIsAbsentFromSecondProviderRequest() async throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsDomain = "credi-native-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        let sessions = SessionStore(directory: root.appendingPathComponent("chat"))
        try #require(chat.attachPersistence(sessions))
        let sessionID = try #require(chat.activeSessionID)
        let secret = "CREDI-NATIVE-OPAQUE-" + UUID().uuidString
        let source = root.appendingPathComponent("public-note.txt")
        try Data("普通项目记录\n".utf8).write(to: source)
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
            revision: "credi-native-policy", grantEpoch: "credi-native-epoch",
            leaseID: "credi-native-lease", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let provider = CredentialNativeEchoProvider2027(path: source.path, secret: secret)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            requestBudget: chat.budgetTracker, toolExecutionFactLedger: ledger,
            composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        chat.draftText = "请读取公开项目记录。"
        chat.submitComposer()
        let deadline = Date().addingTimeInterval(15)
        while chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming)

        let requests = provider.requests
        try #require(requests.count == 2)
        let assistant = try #require(requests[1].first(where: { !$0.toolCalls.isEmpty }))
        let call = try #require(assistant.toolCalls.first)
        #expect(assistant.content.contains("正在读取公开记录"))
        #expect(call.rawArguments.contains("正常注释"))
        #expect(!assistant.content.contains(secret))
        #expect(!call.rawArguments.contains(secret))
        #expect(assistant.content.contains(ContentSecretRedactor.mask(secret)))
        #expect(call.rawArguments.contains(ContentSecretRedactor.mask(secret)))
        #expect(requests[1].contains { $0.role == .tool && $0.content.contains("普通项目记录") })
        #expect(ledger.facts.count == 1)
        chat.stopAllStreamingForSafety()
    }
}
