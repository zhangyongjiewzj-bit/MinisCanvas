import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Batch2GCompactProvider: LLMProvider, @unchecked Sendable {
    let name = "batch2g-compact"
    var model = LLMModel(id: "batch2g-compact", displayName: "Fixture", provider: "test")
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        // A blank reply is no summary, so the compaction is refused.
        LLMResponse(text: "   ", stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Batch2G RED 4：/compact 被拒绝（摘要模型没有返回可用摘要）时，右下角结果与对话通知措辞一致。
/// 压缩改为“旧内容由模型摘要”后，附件和工具往来不再造成跳过；拒绝只剩摘要为空这一种，
/// 文案统一为“没有可压缩的旧内容”。
@Suite("Batch2G compact skip presentation", .serialized)
@MainActor
struct Batch2G_CompactSkipPresentationTests {
    @Test("a refused compaction reports 已完成：没有可压缩的旧内容 in the corner presentation, matching the notice")
    func protectiveSkipCornerMessageMatchesNotice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch2g-compact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let image = LLMMessage.ImageAttachment(mimeType: "image/png", data: Data([1, 2, 3]))
        let history = [
            LLMMessage(role: .user, content: "Goal and constraint with an image that text cannot retain.", images: [image]),
            LLMMessage(role: .assistant, content: "The earlier image remains part of the canonical history."),
            LLMMessage(role: .user, content: "Continue without losing that image.")
        ]
        let thread = ChatThread(id: id, messages: history.map { $0.asChatMessageUI() },
            transcriptRevision: UInt64(history.count))
        let store = SessionStore(directory: root)
        try store.updateSession(thread.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let before = try #require(chat.sessions.first(where: { $0.id == id }))

        await chat.runCompaction(history: before.messages, keepRecent: 1, sessionID: id,
            expectedTranscriptRevision: before.transcriptRevision,
            providerBox: LLMProviderBox(value: Batch2GCompactProvider()))

        let after = try #require(chat.sessions.first(where: { $0.id == id }))
        #expect(after.messages.last?.content.contains("没有可压缩的旧内容") == true)
        #expect(!(after.messages.last?.content.contains("已跳过压缩") ?? false))
        let corner = try #require(chat.compactionPresentation)
        #expect(corner.message == "/compact 已完成：没有可压缩的旧内容")
        #expect(!corner.message.contains("未完成"))
    }
}

/// Batch2G RED 5a：审批卡范围名中文。ApprovalPromptCenter.swift:1286-1294 只映射 request/session/workspace，
/// "turn" 落入 default 分支，原样显示“范围：turn”。
@Suite("Batch2G approval scope labels")
struct Batch2G_ApprovalScopeLabelTests {
    @Test("turn scope shows 本回合, never the raw English name")
    func turnScopeIsChinese() {
        let request = ApprovalRequest(id: "batch2g-scope", toolName: "shell_execute", inputSummary: "<redacted>",
            riskLevel: .high, requiresApproval: true, approvalScope: "turn")
        let scope = ApprovalSummaryPresentation(request: request).scope
        #expect(scope == "范围：本回合")
        #expect(!scope.contains("turn"))
    }
}

/// Batch2G RED 5b：Hooks 页最近一次状态。HookRuntime.swift:259（PreToolUse/UserPromptSubmit 退出码 2）与
/// :250（PreToolUse 超时）都以 deny 实际拦截了调用，但 HooksSettingsSection.swift:121-122 仍写
/// “非零退出（未影响决策）…返回 deny”/“超时（未影响决策）…返回 deny”，自相矛盾。
@Suite("Batch2G hooks last-run status text")
struct Batch2G_HooksStatusTextTests {
    private func record(_ status: HookRunStatus, exit: Int32?, decision: String?) -> HookRunRecord {
        HookRunRecord(key: "k", source: .user, hookID: "h", event: .preToolUse,
            startedAt: Date(timeIntervalSince1970: 0), durationMilliseconds: 12, status: status,
            exitCode: exit, decision: decision, summary: "blocked by policy")
    }

    @Test("a hook that denied the call is reported as 已拦截, not 未影响决策",
          arguments: [HookRunStatus.nonZeroExit, HookRunStatus.timedOut])
    func denyingRunIsReportedAsBlocked(status: HookRunStatus) {
        let text = HooksSettingsController.statusText(record(status, exit: 2, decision: "deny"))
        #expect(text.contains("已拦截"))
        #expect(!text.contains("未影响决策"))
    }

    @Test("a non-zero exit that did not decide keeps 未影响决策")
    func nonDecidingRunKeepsNoEffectWording() {
        let text = HooksSettingsController.statusText(record(.nonZeroExit, exit: 1, decision: nil))
        #expect(text.contains("未影响决策"))
        #expect(!text.contains("已拦截"))
    }
}
