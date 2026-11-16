import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// 第二批线 N（RED 3b）：用户说“压缩上下文”，模型应能调用 context_compact 工具，
/// 调用即执行与 /compact 相同的压缩，工具结果回报给模型，压缩检查点落盘。
/// 夹具走真实 ChatStore / AgentLoopChatEngine / BuiltinToolExecutor / SessionStore（照 Batch2E 夹具），
/// 只有 Provider 是脚本化的。
/// 实现提示：ChatStore.performConfirmedCompaction（ChatAgentEngine.swift:5242）开头会 stopStreamingForSwitch()，
/// 在回合内由工具触发时不能走这个入口，否则会打断调用它的这一回合；回合内有“活跃助手气泡”，
/// 应走 performCompaction 的 inFlightAssistantMessageID 路径（:5300 起）。

private let compactCallID = "b2n-compact-call"

private final class Batch2NToolProvider: LLMProvider, @unchecked Sendable {
    let name = "b2n-tool"
    var model = LLMModel(id: "b2n-tool", displayName: "B2N tool", provider: "b2n-tool")
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var dialogue: [[LLMMessage]] = []
    private var summaries: [[LLMMessage]] = []
    private var offered: [[String]] = []
    var dialogueRequests: [[LLMMessage]] { lock.withLock { dialogue } }
    var summaryRequests: [[LLMMessage]] { lock.withLock { summaries } }
    var offeredToolNames: [[String]] { lock.withLock { offered } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { summaries.append(messages) }
        return LLMResponse(text: "B2N-TOOL-SUMMARY：此前四轮讨论的结论已摘要。", stopReason: "stop", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { dialogue.append(messages); offered.append(tools.map(\.name)) }
        if toolResults(in: messages).contains(where: { $0.id == compactCallID }) {
            return LLMResponse(text: "上下文已压缩。", stopReason: "stop", usage: nil)
        }
        if messages.last(where: { $0.role == .user })?.content.contains("请压缩上下文") == true {
            let call = LLMToolCall(id: compactCallID, name: "context_compact", rawArguments: "{}", arguments: [:])
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [call])
        }
        return LLMResponse(text: "收到。", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}

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

@Suite("Batch2N context_compact tool", .serialized)
@MainActor
struct Batch2N_ContextCompactToolTests {
    @Test func modelCallingContextCompactRunsTheSameCompactionAndGetsASuccessResult() async throws {
        let label = "b2n-compact-tool"
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: label, canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        defer { chat.stopAllStreamingForSafety(); try? profile.cleanupDisposableRoots() }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        #expect(chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let sid = chat.applyNewSession(title: label)
        let capabilities: Set<String> = ["context_compact"]
        let facts = ComposerPolicyFactSource(knownCapabilities: capabilities, grantedCapabilities: capabilities,
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID, revision: label,
            grantEpoch: label, leaseID: label, expiresAt: Date().addingTimeInterval(300), autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [], mcpBridge: nil)
        builtin.fileChangeSessionID = sid.uuidString
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: builtin, maxIterations: 10,
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: nil, skillsDisabled: true, mcpBridge: nil)
        }
        let provider = Batch2NToolProvider()
        chat.streamingProviderOverride = provider
        chat.compactionProviderOverride = provider

        func run(_ text: String) async throws {
            chat.draftText = text
            chat.submitComposer()
            await (try #require(chat.turnTaskForTests(sessionID: sid))).value
        }
        // 先攒四轮较长的普通对话作为待压缩历史。
        for round in 1...4 {
            try await run((0..<25).map { "第 \(round) 轮讨论 \($0)：独立内容 \($0 * 11 + round)，用于撑大体积。" }.joined(separator: "\n"))
        }
        try #require(provider.summaryRequests.isEmpty)
        try #require(try sessions.loadLatestCompactionCheckpoint(sessionID: sid.uuidString) == nil)

        try await run("请压缩上下文")

        // 模型看得到这个工具。
        #expect(provider.offeredToolNames.first?.contains("context_compact") == true)
        // 调用后工具结果回到了模型，且是成功回报。
        let last = try #require(provider.dialogueRequests.last)
        let result = try #require(toolResults(in: last).first { $0.id == compactCallID },
                                  "context_compact 的结果必须回给模型")
        #expect(!result.content.isEmpty)
        #expect(result.content.contains("压缩") || result.content.localizedCaseInsensitiveContains("compact"))
        #expect(!result.content.localizedCaseInsensitiveContains("error"))
        // 与 /compact 相同的压缩：模型摘要 + 检查点落盘。
        #expect(!provider.summaryRequests.isEmpty)
        let checkpoint = try #require(try sessions.loadLatestCompactionCheckpoint(sessionID: sid.uuidString))
        #expect(checkpoint.replacementHistory.contains { $0.content.contains("B2N-TOOL-SUMMARY") })
    }
}
