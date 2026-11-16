import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class CredentialToolResultProvider1995: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "credi-tool-result-fixture"
    var model = LLMModel(id: "credi-tool-model", displayName: "CREDI Tool", provider: "credi-tool-result-fixture")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "credi-tool-synthetic"
    private let lock = NSLock()
    private var scripted: [String]
    private var captured: [[LLMMessage]] = []

    init(path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "credi-read", "name": "file_read", "input": ["path": path]
        ]]])
        scripted = [String(decoding: data, as: UTF8.self)]
    }

    var requests: [[LLMMessage]] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let reply = lock.withLock { () -> String in
            captured.append(messages)
            return scripted.isEmpty ? "读取已完成。" : scripted.removeFirst()
        }
        return LLMResponse(text: reply, stopReason: "stop", usage: nil)
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

@Suite("D-CREDI actual tool result outbound")
@MainActor
struct CredentialToolResultOutbound1995Tests {
    @Test func savedOpaqueValueInEarlierFileReadResultNeverReachesNextProviderRequest() async throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let defaultsDomain = "credi-tool-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        let sessions = SessionStore(directory: root.appendingPathComponent("chat"))
        try #require(chat.attachPersistence(sessions))
        let sessionID = try #require(chat.activeSessionID)
        let secret = "CREDI-TOOL-OPAQUE-" + UUID().uuidString
        let source = root.appendingPathComponent("existing-note.txt")
        // The file predates local custody of this exact opaque value.
        try Data(("普通项目记录\n" + secret + "\n").utf8).write(to: source)
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
            revision: "credi-tool-policy", grantEpoch: "credi-tool-epoch",
            leaseID: "credi-tool-lease", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let provider = try CredentialToolResultProvider1995(path: source.path)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            requestBudget: chat.budgetTracker, toolExecutionFactLedger: ledger,
            composerPolicyFacts: facts)
        chat.agentEngine = engine
        chat.streamingProviderOverride = provider
        chat.draftText = "请读取已有项目记录。"
        chat.submitComposer()
        let deadline = Date().addingTimeInterval(15)
        while chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming)
        let requests = provider.requests
        try #require(requests.count == 2)
        let second = requests[1].map(\.content).joined(separator: "\n")
        #expect(second.contains("普通项目记录"))
        let rawAbsent = !second.contains(secret)
        #expect(rawAbsent)
        #expect(second.contains(ContentSecretRedactor.mask(secret)))
        #expect(ledger.facts.count == 1)
        let fact = try #require(ledger.facts.first)
        let sourceText = try String(contentsOf: source, encoding: .utf8)
        #expect(fact.outputSummary == ToolOutputSummary.capture(toolName: "file_read", output: sourceText))
        let ledgerBytes = try Data(contentsOf: root.appendingPathComponent("facts.json"))
        #expect(!String(decoding: ledgerBytes, as: UTF8.self).contains(secret))
        chat.stopAllStreamingForSafety()
    }
}
