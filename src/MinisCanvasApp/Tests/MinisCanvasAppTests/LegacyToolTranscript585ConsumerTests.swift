import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Legacy585Provider: LLMProvider, ProviderRuntimeConfigurationIdentity {
    let name = "legacy585-synthetic"
    var model = LLMModel(id: "legacy585", displayName: "Synthetic", provider: "legacy585-synthetic")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "legacy585-fixed"
    let envelope: String
    private(set) var requests: [[LLMMessage]] = []
    init(envelope: String) { self.envelope = envelope }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        requests.append(messages)
        return LLMResponse(text: requests.count == 1 ? envelope : "synthetic complete",
                           stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        Issue.record("Legacy585 fixture unexpectedly streamed")
        return AsyncThrowingStream { $0.finish() }
    }
}

private struct Legacy585Failure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
private struct Legacy585FailingExecutor: ToolExecutor {
    let text: String
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw Legacy585Failure(text: text)
    }
}

/// Real legacy AgentLoop producer, canonical SessionStore codec and the same
/// restored display/copy/AX consumers. No UI, shared stores or network.
struct LegacyToolTranscript585ConsumerTests {
    private struct Produced {
        let root: URL
        let sessionID: String
        let legacy: LLMMessage
        let nextRequest: [LLMMessage]
        let facts: [ToolExecutionFact]
    }

    private func produce(body: String, fails: Bool = false) async throws -> Produced {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Legacy585-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("owned.txt")
        try Data(body.utf8).write(to: file)
        let sessionID = UUID().uuidString
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: sessionID, turnID: 1, messageID: "message585"),
            operationID: "operation585", attempt: 1)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let envelope = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "call585", "name": "file_read", "input": ["path": file.path]
        ]]])
        let provider = Legacy585Provider(envelope: String(decoding: envelope, as: UTF8.self))
        let executor: any ToolExecutor = fails ? Legacy585FailingExecutor(text: body)
            : BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let loop = AgentLoop(maxIterations: 2, turnController: TurnController(), timeout: 30,
                             toolExecutionFactLedger: ledger)
        let tool = try #require(AgentToolCatalog.makeTools().first { $0.name == "file_read" })
        let result = try await loop.run(messages: [], systemPrompt: "synthetic legacy output",
            provider: provider, toolExecutor: executor, tools: [tool], currentConversationID: sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: sessionID,
                conversationID: sessionID, taskID: "task585", actorID: "fixture585"),
            executionIdentity: identity)
        #expect(provider.requests.count == 2)
        let legacy = try #require(result.messages.first { message in
            message.role == .user && message.toAgentContentParts().contains {
                if case .toolResult(let id, _, _, _, _, _, _, _) = $0 { return id == "call585" }
                return false
            }
        })
        return Produced(root: root, sessionID: sessionID, legacy: legacy,
                        nextRequest: try #require(provider.requests.last), facts: ledger.facts)
    }

    @Test(arguments: [false, true])
    func actualLegacySuccessAndFailureRestoreToSafeDisplay(fails: Bool) async throws {
        let canary = "synthetic-private-585"
        let body = canary + "\n" + String(repeating: "合成输出行\n", count: 1_000)
        let produced = try await produce(body: body, fails: fails)
        let legacy = produced.legacy
        #expect(produced.facts.count == 1)
        let fact = try #require(produced.facts.first)
        #expect(fact.status == (fails ? .failed : .succeeded))
        #expect(fact.toolCallID == "call585")
        #expect(legacy.role == .user)
        #expect(legacy.content.count > ProductRedactionPolicy.maxTranscriptFieldLength)
        #expect(legacy.content.contains(canary))
        let summary = try #require(legacy.legacyToolOutputSummary)
        let nextKeptCanonical = produced.nextRequest.contains(legacy)
        #expect(nextKeptCanonical)
        let originalWireMessage = LLMMessage(role: .user, content: legacy.content)
        let capabilities = ModelCapabilities(supportedModalities: .textOnly, supportedAuth: [.apiKey])
        for pair in [
            (AnthropicProvider.anthropicMessageDict(legacy, mediaCapabilities: capabilities),
             AnthropicProvider.anthropicMessageDict(originalWireMessage, mediaCapabilities: capabilities)),
            (OpenAICompatibleProvider.openAIMessageDict(legacy, mediaCapabilities: capabilities),
             OpenAICompatibleProvider.openAIMessageDict(originalWireMessage, mediaCapabilities: capabilities))
        ] {
            let actual = try JSONSerialization.data(withJSONObject: pair.0, options: [.sortedKeys])
            let original = try JSONSerialization.data(withJSONObject: pair.1, options: [.sortedKeys])
            let wireUnchanged = actual == original
            #expect(wireUnchanged)
            #expect(pair.0["legacyToolOutputSummary"] == nil)
        }
        let parts = try #require(JSONSerialization.jsonObject(with: Data(legacy.content.utf8)) as? [[String: Any]])
        #expect(parts.count == 1)
        #expect(parts.first?["tool_use_id"] as? String == "call585")
        #expect(parts.first?["is_error"] as? Bool == fails)

        let directory = produced.root.appendingPathComponent("sessions")
        let writer = SessionStore(directory: directory)
        try writer.createSession(id: produced.sessionID, title: "synthetic585")
        try writer.saveMessage(legacy, sessionID: produced.sessionID)
        let reader = SessionStore(directory: directory)
        let session = try #require(reader.loadSession(id: produced.sessionID))
        let restored = try #require(session.messages.first)
        let canonicalUnchanged = restored == legacy
        #expect(canonicalUnchanged)
        let message = try #require(session.asThread().messages.first)
        let uiDecoded = try JSONDecoder().decode(ChatMessageUI.self, from: JSONEncoder().encode(message))
        let nextRoundUnchanged = uiDecoded.asLLMMessage() == legacy
        #expect(nextRoundUnchanged)
        let visible = try #require(summary.displaySuffix)
        #expect(message.displayContent == visible)
        #expect(!visible.contains(canary))
        #expect(visible.contains("仅显示统计"))
        #expect(!visible.contains("成功"))
        #expect(visible.count < 200)
        for redactor in [nil, ChatTranscriptRedactor(secretValues: [])] {
            let plain = ChatTranscriptFormatter.plainText([uiDecoded], redactor: redactor)
            let ax = ChatTranscriptFormatter.accessibilityText([uiDecoded], redactor: redactor)
            #expect(plain.contains(visible))
            #expect(ax.contains(visible))
            #expect(!plain.contains(canary))
            #expect(!ax.contains(canary))
        }
    }

    @Test func smallProducedResultKeepsOriginalDisplay() async throws {
        let produced = try await produce(body: "small585")
        #expect(produced.legacy.legacyToolOutputSummary == nil)
        let message = produced.legacy.asChatMessageUI()
        let unchanged = message.displayContent == produced.legacy.content
        #expect(unchanged)
        #expect(produced.facts.first?.status == .succeeded)
    }

    @Test func ordinarySameShapeJSONAndOldStorageDoNotAcquireProducerMetadata() throws {
        let body = String(repeating: "用户自己的文本", count: 1_000)
        let envelope = try JSONSerialization.data(withJSONObject: [[
            "type": "tool_result", "tool_use_id": "call585", "content": body, "is_error": false
        ]])
        let content = String(decoding: envelope, as: UTF8.self)
        let ordinary = LLMMessage(role: .user, content: content)
        let encoded = try JSONEncoder().encode(ordinary)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["legacyToolOutputSummary"] == nil)
        let oldDecoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)
        let message = oldDecoded.asChatMessageUI()
        #expect(message.legacyToolOutputSummary == nil)
        let notMisclassified = message.displayContent == content
        #expect(notMisclassified)
        #expect(!message.displayContent.contains("仅显示统计"))
    }
}
