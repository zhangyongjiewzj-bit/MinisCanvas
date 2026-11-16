import Foundation
import Testing
@testable import MinisCore

// 第二批 V 线（独立复核 30 号 P1-1/P1-2/P1-3）：
//  - session_read、session.<id>.project、scheduler.<id>.enabled 每次必问，不吃范围同意；
//  - 有损摘要请求体积按模型窗口设上限，事实清单仍覆盖全部被压缩消息。

@Suite("Batch2V session_read / project / scheduler enable always ask")
struct Batch2V_ApprovalAlwaysAskTests {
    private func snapshot(scope: ComposerApprovalScope, task: String, mode: ComposerTaskMode = .manual)
        -> ComposerSubmissionSnapshot {
        ComposerSubmissionSnapshot(
            mode: mode, approvalScope: scope, effort: .standard,
            sessionID: "session-2v", turnID: 1, taskID: task,
            attemptID: "attempt-\(task)", messageID: "message-\(task)",
            workspaceID: "workspace-2v", createdAt: Date(),
            policyRevision: "policy-2v", grantEpoch: "e1", autonomyCeiling: .l3)
    }

    private func controller(scope: ComposerApprovalScope, task: String, grants: ComposerApprovalGrantStore)
        -> ComposerAuthorizationController {
        let names: Set<String> = [SessionReadTool.toolName, BL6SettingsToolApproval.toolName,
                                  BL6SettingsToolApproval.catalogToolName]
        var bindings: [String: String] = [:]
        for name in names { bindings[name] = "binding-\(name)" }
        let facts = ComposerPolicyFactSource(
            knownCapabilities: names, grantedCapabilities: names,
            capabilityGrantBindings: bindings, allowedWriteRoots: [],
            workspaceID: "workspace-2v", revision: "policy-2v",
            grantEpoch: "e1", leaseID: "l1",
            expiresAt: Date().addingTimeInterval(600), autonomyCeiling: .l3)
        return ComposerAuthorizationController(
            snapshot: snapshot(scope: scope, task: task), facts: facts, grants: grants)
    }

    private func isPrompt(_ decision: ComposerAuthorizationDecision) -> Bool {
        if case .requestApproval = decision { return true }
        return false
    }

    private func reads() throws -> [ComposerToolInput] {
        [try ComposerToolInput(["scope": "messages", "session_id": "target-A"]),
         try ComposerToolInput(["scope": "messages", "session_id": "target-A"]),
         try ComposerToolInput(["scope": "messages", "session_id": "target-B", "offset": 5]),
         try ComposerToolInput(["scope": "list"]),
         try ComposerToolInput(["scope": "export"])]
    }

    @Test("session_read asks on every call under session and workspace scoped consent",
          arguments: [ComposerApprovalScope.session, .workspace])
    func sessionReadNeverReusesScopedConsent(scope: ComposerApprovalScope) async throws {
        let grants = ComposerApprovalGrantStore()
        let first = controller(scope: scope, task: "t1", grants: grants)
        let inputs = try reads()
        for input in inputs {
            #expect(isPrompt(try await first.authorize(capability: SessionReadTool.toolName, input: input)))
            // The user allowed this call: consent must not be stored for later calls.
            try await first.recordApproval(capability: SessionReadTool.toolName, input: input)
        }
        // Same controller again, and a later task in the same session/workspace.
        let later = controller(scope: scope, task: "t2", grants: grants)
        for input in inputs {
            #expect(isPrompt(try await first.authorize(capability: SessionReadTool.toolName, input: input)))
            #expect(isPrompt(try await later.authorize(capability: SessionReadTool.toolName, input: input)))
        }
    }

    @Test("a second session_read after an approved first still needs a fresh decision (refusal means no read)")
    func refusedSecondReadStaysPrompt() async throws {
        let grants = ComposerApprovalGrantStore()
        let c = controller(scope: .session, task: "t1", grants: grants)
        let one = try ComposerToolInput(["scope": "messages", "session_id": "target-A"])
        let two = try ComposerToolInput(["scope": "messages", "session_id": "target-B"])
        try await c.recordApproval(capability: SessionReadTool.toolName, input: one)
        #expect(isPrompt(try await c.authorize(capability: SessionReadTool.toolName, input: two)))
    }

    private func settings(_ changes: [String: Any]) throws -> ComposerToolInput {
        try ComposerToolInput(["operation": "apply", "changes": changes])
    }

    @Test("session project and scheduler enable ask on every call under scoped consent",
          arguments: [ComposerApprovalScope.session, .workspace])
    func projectAndSchedulerEnableAlwaysAsk(scope: ComposerApprovalScope) async throws {
        let id = UUID().uuidString
        let inputs = [
            try settings(["session.current.project": ["kind": "object", "object": [:]]]),
            try settings(["session.\(id).project": ["kind": "object", "object": [:]]]),
            try settings(["scheduler.\(id).enabled": ["kind": "toggle", "toggle": true]])
        ]
        for input in inputs {
            #expect(ComposerAuthorizationController.isMCPServerManagement(
                capability: BL6SettingsToolApproval.toolName, input: input))
        }
        let grants = ComposerApprovalGrantStore()
        let c = controller(scope: scope, task: "t1", grants: grants)
        let later = controller(scope: scope, task: "t2", grants: grants)
        for input in inputs {
            #expect(isPrompt(try await c.authorize(capability: BL6SettingsToolApproval.toolName, input: input)))
            try await c.recordApproval(capability: BL6SettingsToolApproval.toolName, input: input)
            #expect(isPrompt(try await c.authorize(capability: BL6SettingsToolApproval.toolName, input: input)))
            #expect(isPrompt(try await later.authorize(capability: BL6SettingsToolApproval.toolName, input: input)))
        }
    }

    @Test("title/pin/group changes still reuse a scoped consent (only the dangerous keys always ask)")
    func ordinarySessionKeysKeepScopedConsent() async throws {
        let input = try settings(["session.current.title": ["kind": "text", "text": "x"]])
        #expect(!ComposerAuthorizationController.isMCPServerManagement(
            capability: BL6SettingsToolApproval.toolName, input: input))
    }
}

// MARK: - P1-3 summary request size

private final class SummaryRecordingProvider: LLMProvider, @unchecked Sendable {
    var name: String { "SummaryRecording" }
    var model: LLMModel
    private(set) var requests: [[LLMMessage]] = []
    init(window: Int) {
        model = LLMModel(id: "batch2v-window", displayName: "Batch2V", provider: "test", contextWindow: window)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        requests.append(messages)
        return LLMResponse(text: "SYNTHETIC_SUMMARY", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens,
                              temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Batch2V lossy summary request is bounded by the model window")
struct Batch2V_LossySummaryBoundTests {
    @Test("oversized history: request stays within half the window, newest kept, facts cover every compacted message")
    func summaryRequestBoundedFactsComplete() async throws {
        let window = 10_000
        let provider = SummaryRecordingProvider(window: window)
        var history: [LLMMessage] = []
        for index in 0..<60 {
            let body = "MSG_\(index)_" + String(repeating: "正文", count: 1_000)
            if index % 2 == 0 {
                history.append(LLMMessage(role: .user, content: body))
            } else {
                history.append(LLMMessage(role: .assistant, content: body, toolCalls: [
                    LLMToolCall(id: "c\(index)", name: "tool_\(index)", rawArguments: "{}",
                                arguments: ["path": "/tmp/file_\(index).txt"])]))
            }
        }
        let attachments: [Int: [String]] = [0: ["oldest-attachment.png"], 20: ["middle-attachment.pdf"]]
        let result = try await LossySummaryCompaction.compact(
            messages: history, keepRecent: 4, provider: provider,
            attachmentNames: attachments)
        let request = try #require(provider.requests.first?.first)
        let budgetCharacters = window * LossySummaryCompaction.summaryInputWindowPercent / 100 * 4
        // The wrapper text around the transcript is a few hundred characters.
        #expect(request.content.count <= budgetCharacters + 600)
        #expect(request.content.contains("更早内容已省略"))
        #expect(request.content.contains("MSG_55_"))
        #expect(!request.content.contains("MSG_0_"))
        // Facts come from the store-side list, not from the bounded transcript.
        let summary = try #require(result.messages.first?.content)
        for index in stride(from: 1, to: 56, by: 2) {
            #expect(summary.contains("tool_\(index)"))
        }
        #expect(summary.contains("oldest-attachment.png") && summary.contains("middle-attachment.pdf"))
        #expect(result.compactedCount == 56)
    }

    @Test func recentSuffixKeepsTheWholeToolExchangeAcrossTheCut() async throws {
        let provider = SummaryRecordingProvider(window: 200_000)
        let old = LLMMessage(role: .user, content: "OLD_SOURCE_3090 " + String(repeating: "旧记录。", count: 100))
        let use = LLMMessage(role: .assistant, content: "BOUNDARY_USE", toolCalls: [
            LLMToolCall(id: "boundary-call", name: "file_read",
                        rawArguments: #"{"path":"/synthetic/owned-note.txt","tool_title":"Read owned note"}"#,
                        arguments: ["path": "/synthetic/owned-note.txt", "tool_title": "Read owned note"])
        ])
        let toolResult = LLMMessage(role: .tool, content: "BOUNDARY_RESULT", toolCallID: "boundary-call")
        let recent = LLMMessage(role: .user, content: "LATEST_USER")
        let keepRecent = 2
        let expectedTail = [use, toolResult, recent]

        let result = try await LossySummaryCompaction.compact(
            messages: [old] + expectedTail, keepRecent: keepRecent, provider: provider)

        #expect(result.compactedCount == 1)
        let retained = try #require(result.projectionRecentCount)
        #expect(retained >= keepRecent)
        #expect(retained == expectedTail.count)
        #expect(Array(result.messages.suffix(expectedTail.count)) == expectedTail)
        try #require(provider.requests.count == 1 && provider.requests[0].count == 1)
        let transcript = provider.requests[0][0].content
        #expect(transcript.contains(old.content))
        for message in expectedTail {
            #expect(!transcript.contains(message.content))
        }
    }

    @Test("history within the budget is sent whole with no omission note")
    func shortHistoryUnchanged() async throws {
        let provider = SummaryRecordingProvider(window: 200_000)
        let history = (0..<10).map { LLMMessage(role: $0 % 2 == 0 ? .user : .assistant, content: "SHORT_\($0)") }
        _ = try await LossySummaryCompaction.compact(messages: history, keepRecent: 2, provider: provider)
        let request = try #require(provider.requests.first?.first)
        #expect(!request.content.contains("更早内容已省略"))
        #expect(request.content.contains("SHORT_0") && request.content.contains("SHORT_7"))
    }
}
