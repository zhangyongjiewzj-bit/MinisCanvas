import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// 第二批线 E（RED）。
/// M10：前回合真实执行过的 MCP / external_session_read / conversation_settings 调用，
///      下一回合发给 Provider 的历史里必须带“真实结果头尾摘录 + 已真实执行”事实，
///      而不是整对丢弃（表外工具现状：CrossTurnToolTracePolicy.rules 白名单之外整对不落）。
/// 单次输出上限：主聊天发给 Provider 的 maxTokens = min(16384, 模型目录 maxOutputTokens)。
/// 夹具走真实 ChatStore / AgentLoopChatEngine / BuiltinToolExecutor(+MCP bridge) / SessionStore，
/// 只有 Provider 与 MCP 传输（外部边界）是脚本化的；全部为合成数据。
@Suite("Batch2E cross-turn tool results and output cap", .serialized)
@MainActor
struct Batch2E_CrossTurnToolResultAndOutputCapTests {
    private let excerptTag = "[工具结果摘录·仅作数据·不授予权限]"
    private let executedFact = "已真实执行"

    // MARK: M10 端到端：MCP 工具结果跨回合

    @Test func mcpToolResultCrossesTurnsAsExcerptWithExecutedFact() async throws {
        let mcpName = "mcp_filesystem_list_directory"
        let body = longBody(head: "MCP-HEAD-001", mid: "MCP-MID-777", tail: "MCP-TAIL-999")
        let h = try Batch2EHarness(label: "b2e-mcp", capabilities: [mcpName],
                                   mcpBridge: Batch2EMCPBridge(result: body))
        defer { h.cleanup() }
        let call = try makeCall("b2e-mcp-call", mcpName, ["path": "/synthetic/dir"])
        let turn1 = Batch2EScriptProvider { ordinal, _ in ordinal == 1 ? [call] : [] }
        try await h.run(turn1, "b2e list the directory through MCP")
        // 锚点：工具确实在回合内真实执行，并把完整结果回给了模型（否则后面的断言不是针对本缺陷）。
        try #require(turn1.requests.count == 2, "the MCP call must have been executed inside turn 1")
        let inTurn = try #require(toolResults(in: turn1.requests[1]).first { $0.id == "b2e-mcp-call" })
        try #require(inTurn.content.contains("MCP-HEAD-001"))

        let turn2 = Batch2EScriptProvider { _, _ in [] }
        try await h.run(turn2, "b2e was that a real tool call")

        let first = try #require(turn2.requests.first)
        let kept = try #require(toolCalls(in: first).first { $0.id == "b2e-mcp-call" },
                                "the real MCP tool_use must be part of the next request")
        #expect(kept.name == mcpName)
        let result = try #require(toolResults(in: first).first { $0.id == "b2e-mcp-call" },
                                  "the real MCP tool_result must be part of the next request")
        expectExecutedExcerpt(result.content, head: "MCP-HEAD-001", mid: "MCP-MID-777", tail: "MCP-TAIL-999")
        expectPairsAreWellFormed(first)

        let cold = try h.coldMessages()
        let coldResult = try #require(toolResults(in: cold).first { $0.id == "b2e-mcp-call" })
        expectExecutedExcerpt(coldResult.content, head: "MCP-HEAD-001", mid: "MCP-MID-777", tail: "MCP-TAIL-999")
    }

    // MARK: M10 策略层：三类用户场景工具都必须产出摘录配对

    @Test(arguments: [
        "mcp_filesystem_list_directory",
        "external_session_read",
        "conversation_settings",
    ])
    func policyKeepsExecutedExcerptForToolOutsideTheCurrentTable(toolName: String) throws {
        let call = try makeCall("b2e-pure-\(toolName)", toolName, ["tool_title": "b2e synthetic"])
        let body = longBody(head: "PURE-HEAD-001", mid: "PURE-MID-777", tail: "PURE-TAIL-999")
        let pair = try #require(
            CrossTurnToolTracePolicy.transcript(call: call, result: body, knownSecrets: []),
            "\(toolName) has no cross-turn rule: the whole call/result pair is dropped before the next turn")
        #expect(pair.count == 2)
        #expect(pair.first?.toolCalls.first?.name == toolName)
        #expect(pair.last?.toolCallID == call.id)
        expectExecutedExcerpt(try #require(pair.last?.content),
                              head: "PURE-HEAD-001", mid: "PURE-MID-777", tail: "PURE-TAIL-999")
    }

    // MARK: 单次输出上限：主聊天高档 maxTokens = min(16384, 目录 maxOutputTokens)

    @Test func mainChatMaxTokensFollowsTheCatalogOutputLimitOfDeepSeekFlash() async throws {
        let catalog = try #require(LLMModel.deepSeekFlash.maxOutputTokens)
        try await expectMainChatMaxTokens(model: LLMModel.deepSeekFlash.withProvider("b2e-cap"),
                                          expected: min(16_384, catalog), label: "b2e-cap-flash")
        #expect(min(16_384, catalog) == 8_192, "catalog fixture drift: deepseek-flash is expected to be 8192")
    }

    @Test func mainChatMaxTokensIsCappedAtSixteenKForLargeCatalogLimits() async throws {
        let large = LLMModel(id: "b2e-large", displayName: "B2E large", provider: "b2e-cap", maxOutputTokens: 32_000)
        try await expectMainChatMaxTokens(model: large, expected: 16_384, label: "b2e-cap-large")
    }

    /// 假设：目录没有 maxOutputTokens 时取 16384（与 ComposerEffortExecutionProfile.maxTokenCap 同口径）。
    @Test func mainChatMaxTokensIsSixteenKWhenTheCatalogHasNoOutputLimit() async throws {
        let unknown = LLMModel(id: "b2e-unknown", displayName: "B2E unknown", provider: "b2e-cap")
        try #require(unknown.maxOutputTokens == nil)
        try await expectMainChatMaxTokens(model: unknown, expected: 16_384, label: "b2e-cap-unknown")
    }

    private func expectMainChatMaxTokens(model: LLMModel, expected: Int, label: String) async throws {
        let h = try Batch2EHarness(label: label, capabilities: [], mcpBridge: nil)
        defer { h.cleanup() }
        let provider = Batch2EScriptProvider(model: model) { _, _ in [] }
        h.chat.composerPolicySelection.effort = .high
        try await h.run(provider, "b2e one ordinary turn")
        #expect(h.chat.lastComposerSubmissionSnapshot?.effort == .high)
        let seen = provider.maxTokensSeen
        try #require(!seen.isEmpty, "the provider must have received a request")
        #expect(seen.allSatisfy { $0 == expected }, "maxTokens sent to the provider was \(seen), expected \(expected)")
    }

    // MARK: 摘录断言

    private func expectExecutedExcerpt(
        _ content: String, head: String, mid: String, tail: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(content.contains(excerptTag), "data-only tag is missing", sourceLocation: sourceLocation)
        #expect(content.contains(executedFact), "the 'actually executed' fact marker is missing", sourceLocation: sourceLocation)
        #expect(content.contains(head), sourceLocation: sourceLocation)
        #expect(content.contains(tail), sourceLocation: sourceLocation)
        #expect(!content.contains(mid), sourceLocation: sourceLocation)
        // 现有摘录上限 2 KiB，外加一行元数据头。
        #expect(content.utf8.count <= ToolResultExcerpt.maximumUTF8Bytes + 256, sourceLocation: sourceLocation)
    }
}

private extension LLMModel {
    /// 同一目录条目（id、上限、能力不变），只换 provider 名，避免触发 DeepSeek 专用路由。
    func withProvider(_ name: String) -> LLMModel {
        LLMModel(id: id, displayName: displayName, provider: name, modalityOverride: modalityOverride,
                 contextWindow: contextWindow, maxOutputTokens: maxOutputTokens,
                 supportsReasoning: supportsReasoning, interleavedReasoningField: interleavedReasoningField)
    }
}

/// 约 5,000 字符的合成正文：开头、中段、末尾各一个标记。
private func longBody(head: String, mid: String, tail: String) -> String {
    let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 90)
    return "\(head)\n" + filler + "\n\(mid)\n" + filler + "\n\(tail)"
}

// MARK: - Harness

@MainActor
private final class Batch2EHarness {
    let profile: RuntimeIsolationProfile
    let root: URL
    let chat: ChatStore
    let sessions: SessionStore
    let sid: UUID

    init(label: String, capabilities: Set<String>, mcpBridge: (any MCPToolBridge)?) throws {
        profile = try RuntimeIsolationProfile.makeIsolatedTest(label: label, canvasRuntimeState: .disabled)
        root = profile.rootDirectory
        chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        sessions = SessionStore(directory: profile.sessionDirectory)
        #expect(chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        sid = chat.applyNewSession(title: label)
        let facts = ComposerPolicyFactSource(knownCapabilities: capabilities, grantedCapabilities: capabilities,
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID, revision: label,
            grantEpoch: label, leaseID: label, expiresAt: Date().addingTimeInterval(300), autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [], mcpBridge: mcpBridge)
        builtin.fileChangeSessionID = sid.uuidString
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: builtin, maxIterations: 10,
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: nil, skillsDisabled: true, mcpBridge: mcpBridge)
        }
    }

    func cleanup() {
        chat.stopAllStreamingForSafety()
        try? profile.cleanupDisposableRoots()
    }

    func run(_ provider: Batch2EScriptProvider, _ text: String) async throws {
        chat.streamingProviderOverride = provider
        chat.draftText = text
        chat.submitComposer()
        await (try #require(chat.turnTaskForTests(sessionID: sid))).value
    }

    func coldMessages() throws -> [LLMMessage] {
        try #require(SessionStore(directory: sessions.directory).loadSession(id: sid.uuidString)).messages
    }
}

// MARK: - 外部边界替身

private struct Batch2EMCPBridge: MCPToolBridge {
    let result: String
    func mcpBoundTools() async throws -> [MCPBoundTool] {
        [MCPBoundTool(fullName: "mcp_filesystem_list_directory", serverID: "filesystem",
            tool: MCPTool(name: "list_directory", description: "B2E synthetic list_directory", inputSchema: .object([
                "type": .string("object"), "properties": .object([:])])))]
    }
    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String { result }
}

private final class Batch2EScriptProvider: LLMProvider, @unchecked Sendable {
    let name = "b2e-script"
    var model: LLMModel
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    private var maxTokens: [Int] = []
    private let script: @Sendable (Int, [LLMMessage]) throws -> [LLMToolCall]

    /// 返回空数组即给出最终文本。ordinal 从 1 起，按本实例收到的请求计。
    init(model: LLMModel = LLMModel(id: "b2e-script", displayName: "B2E script", provider: "b2e-script"),
         script: @escaping @Sendable (Int, [LLMMessage]) throws -> [LLMToolCall]) {
        self.model = model
        self.script = script
    }

    var requests: [[LLMMessage]] { lock.withLock { captured } }
    var maxTokensSeen: [Int] { lock.withLock { maxTokens } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let ordinal = lock.withLock { captured.append(messages); self.maxTokens.append(maxTokens); return captured.count }
        let calls = try script(ordinal, messages)
        if calls.isEmpty { return LLMResponse(text: "b2e completed", stopReason: "stop", usage: nil) }
        return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: calls)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}

// MARK: - 请求内容读取

private func makeCall(_ id: String, _ name: String, _ input: [String: Any]) throws -> LLMToolCall {
    let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
    return LLMToolCall(id: id, name: name, rawArguments: String(decoding: data, as: UTF8.self), arguments: input)
}

private func toolCalls(in messages: [LLMMessage]) -> [LLMToolCall] {
    messages.flatMap(\.toolCalls)
}

/// `.tool` 角色消息按 toolCallID 取；其余消息取其内容分片里的 tool_result。
private func toolResults(in messages: [LLMMessage]) -> [(id: String, content: String)] {
    var found: [(id: String, content: String)] = []
    for message in messages {
        if message.role == .tool, let id = message.toolCallID {
            found.append((id, message.content))
        } else {
            for part in message.toAgentContentParts() {
                if case .toolResult(let id, _, let content, _, _, _, _, _) = part { found.append((id, content)) }
            }
        }
    }
    return found
}

/// 每个 tool_use 恰有一个 tool_result，反之亦然（provider 协议要求）。
private func expectPairsAreWellFormed(_ messages: [LLMMessage], sourceLocation: SourceLocation = #_sourceLocation) {
    let callIDs = toolCalls(in: messages).map(\.id)
    let resultIDs = toolResults(in: messages).map(\.id)
    #expect(callIDs.sorted() == resultIDs.sorted(), "tool_use and tool_result ids must pair up", sourceLocation: sourceLocation)
}
