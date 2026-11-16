import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// 第二批线 N（RED）：手动 /compact 改为“像 Claude Code 那样”——旧内容（含工具往来、附件）交给模型摘要（有损），
/// 摘要后附“事实清单”（工具名 + 附件名），tool_use/tool_result 配对完整，不再因旧附件/工具往来拒绝；
/// 摘要模型失败才报“压缩失败”，历史不变。
/// 现状：ChatAgentEngine.swift:5108-5118 旧消息有附件即返回 .unverifiableInformationLoss；
/// 无附件时 :5125/:5163 的 .requireVerbatimText / .sourceAnchoredNatural 把工具组、媒体组原样保留，压不下体积即拒绝
/// （“已跳过压缩：最近的工具往来需要保留”，:5073）。落盘还要过 CompactionCheckpoint.makeProjection（:147/:180）与
/// SessionStore.validateProjectionSource（:5346/:5352）的无损/源锚定闸门。

private final class Batch2NSummaryProvider: LLMProvider, @unchecked Sendable {
    let name = "batch2n-summary"
    var model = LLMModel(id: "batch2n-summary", displayName: "Batch2N", provider: "test")
    static let summaryMarker = "B2N-FIXED-SUMMARY"
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    private let failure: Error?

    init(failure: Error? = nil) { self.failure = failure }

    var requests: [[LLMMessage]] { lock.withLock { captured } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(messages) }
        if let failure { throw failure }
        return LLMResponse(text: "\(Self.summaryMarker)：用户要看设计稿、读 README 并跑测试；README 已读，测试通过，检索到相关议题。",
                           stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}

private struct Batch2NSummaryOffline: LocalizedError {
    var errorDescription: String? { "summary model offline" }
}

private func bulky(_ tag: String) -> String {
    (0..<40).map { "\(tag) 行 \($0)：独立内容 \($0 * 17 + tag.count)，用于撑大体积。" }.joined(separator: "\n")
}

private func payloadBytes(_ messages: [LLMMessage]) -> Int {
    messages.reduce(0) { total, message in
        total + message.content.utf8.count
            + message.toolCalls.reduce(0) { $0 + $1.name.utf8.count + $1.rawArguments.utf8.count }
            + message.images.reduce(0) { $0 + $1.data.count }
    }
}

private func call(_ id: String, _ name: String, _ input: [String: Any]) throws -> LLMToolCall {
    let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
    return LLMToolCall(id: id, name: name, rawArguments: String(decoding: data, as: UTF8.self), arguments: input)
}

@MainActor
private struct Batch2NFixture {
    let root: URL
    let id: UUID
    let store: SessionStore
    let chat: ChatStore
    let sourceMessages: [LLMMessage]

    /// 11 条：旧用户消息带 PNG 附件“设计稿.png”，随后 file_read / shell_execute / mcp_* 三轮工具往来，
    /// 最后 3 条（keepRecent）是一组完整的普通对话，边界不拆 tool 配对。
    static func make() throws -> Batch2NFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch2n-manual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
        let attachment = ChatAttachment(kind: .image, fileName: "设计稿.png", fileType: .image,
                                        mimeType: "image/png", data: png)
        let history: [ChatMessageUI] = [
            ChatMessageUI(role: .user, content: "请先看这张设计稿，再读 README，然后把测试跑一遍。", attachments: [attachment]),
            ChatMessageUI(role: .assistant, content: "我先读一下 README。",
                          toolCalls: [try call("b2n-c1", "file_read", ["path": "/work/proj/README.md"])]),
            ChatMessageUI(role: .tool, content: bulky("README"), toolCallID: "b2n-c1"),
            ChatMessageUI(role: .assistant, content: "再跑测试。",
                          toolCalls: [try call("b2n-c2", "shell_execute", ["command": "swift test"])]),
            ChatMessageUI(role: .tool, content: bulky("测试输出"), toolCallID: "b2n-c2"),
            ChatMessageUI(role: .assistant, content: "再查一下相关议题。",
                          toolCalls: [try call("b2n-c3", "mcp_github_search_issues", ["query": "flaky test"])]),
            ChatMessageUI(role: .tool, content: bulky("议题"), toolCallID: "b2n-c3"),
            ChatMessageUI(role: .assistant, content: "README 已读，测试全部通过，找到 3 个相关议题。"),
            ChatMessageUI(role: .user, content: "把结论整理成三条。"),
            ChatMessageUI(role: .assistant, content: "好的：1) README 完整；2) 测试通过；3) 有 3 个相关议题待跟进。"),
            ChatMessageUI(role: .user, content: "再补一条风险。"),
        ]
        let id = UUID()
        let thread = ChatThread(id: id, messages: history, transcriptRevision: UInt64(history.count))
        let store = SessionStore(directory: root)
        try store.updateSession(thread.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        #expect(chat.applySwitchSession(id: id))
        let source = try #require(store.loadSession(id: id.uuidString)).messages
        return Batch2NFixture(root: root, id: id, store: store, chat: chat, sourceMessages: source)
    }

    func waitForCompaction() async -> Bool {
        for _ in 0..<400 {
            if let state = chat.compactionPresentation?.state, state != .pending { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    func notices() -> [String] {
        chat.messages.filter { $0.role == .system }.map(\.content)
    }
}

@Suite("Batch2N manual /compact is a model summary", .serialized)
@MainActor
struct Batch2N_ManualCompactSummaryTests {
    /// RED 1：旧附件 + 三轮工具往来 → 摘要成功，体积显著变小，最近 3 条原样，事实清单含工具名与附件名。
    @Test func compactSummarizesOldToolExchangesAndAttachmentsIntoOneSummaryWithFactList() async throws {
        let f = try Batch2NFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // 锚点：UI 侧确有带文件名的附件（事实清单的附件名来源）。
        let ui = try #require(f.chat.sessions.first(where: { $0.id == f.id }))
        try #require(ui.messages.first?.attachments.first?.fileName == "设计稿.png")
        let provider = Batch2NSummaryProvider()
        f.chat.compactionProviderOverride = provider

        f.chat.compactContext(keepRecent: 3)
        #expect(await f.waitForCompaction(), "压缩必须在限定时间内到达终态")

        // 不再“已跳过”，也不是失败。
        #expect(f.chat.compactionPresentation?.state == .succeeded)
        #expect(!f.notices().contains { $0.contains("已跳过压缩") || $0.hasPrefix("压缩失败") })

        // 旧内容（含工具往来原文）确实交给了模型。
        let sent = provider.requests.first?.map(\.content).joined(separator: "\n") ?? ""
        #expect(!provider.requests.isEmpty, "摘要必须由模型生成")
        #expect(sent.contains("swift test"))
        #expect(sent.contains("mcp_github_search_issues"))
        #expect(sent.contains("README 行 0"))

        // 落盘的压缩检查点就是之后发给 Provider 的历史。
        let checkpoint = try #require(try f.store.loadLatestCompactionCheckpoint(sessionID: f.id.uuidString))
        let model = checkpoint.replacementHistory
        #expect(try f.store.resumeMessages(sessionID: f.id.uuidString) == model)
        #expect(model.count < f.sourceMessages.count)
        #expect(payloadBytes(model) * 3 < payloadBytes(f.sourceMessages), "压缩后历史体积必须显著变小")

        // 最近 3 条原样。
        #expect(Array(model.suffix(3)) == Array(f.sourceMessages.suffix(3)))

        // 摘要 + 事实清单：模型摘要文字、工具名、附件名。
        let head = model.dropLast(3).map(\.content).joined(separator: "\n")
        #expect(head.contains(Batch2NSummaryProvider.summaryMarker))
        #expect(head.contains("file_read"))
        #expect(head.contains("shell_execute"))
        #expect(head.contains("mcp_github_search_issues"))
        #expect(head.contains("设计稿.png"))

        // tool_use / tool_result 配对完整（旧往来已被摘要，不能留下孤儿）。
        let callIDs = model.flatMap(\.toolCalls).map(\.id).sorted()
        let resultIDs = model.filter { $0.role == .tool }.compactMap(\.toolCallID).sorted()
        #expect(callIDs == resultIDs)

        // 有损摘要不改写规范转录。
        #expect(f.store.loadSession(id: f.id.uuidString)?.messages == f.sourceMessages)
    }

    /// RED 4（护栏）：摘要模型抛错 → 报“压缩失败”，不写检查点，历史不变；不能静默退化成截断摘要。
    /// 现状先被 :5108 的附件拒绝拦下，Provider 一次都没被调用（provider.requests 为 0），所以此条当前也是红。
    @Test func summaryProviderFailureReportsFailureAndLeavesHistoryUntouched() async throws {
        let f = try Batch2NFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let provider = Batch2NSummaryProvider(failure: Batch2NSummaryOffline())
        f.chat.compactionProviderOverride = provider

        f.chat.compactContext(keepRecent: 3)
        #expect(await f.waitForCompaction())

        #expect(!provider.requests.isEmpty, "失败必须来自真实的摘要调用，而不是调用前的拒绝")
        #expect(f.chat.compactionPresentation?.state == .failed)
        let notices = f.notices()
        #expect(notices.contains { $0.hasPrefix("压缩失败") })
        #expect(!notices.contains { $0.contains("已跳过压缩") })
        #expect(try f.store.loadLatestCompactionCheckpoint(sessionID: f.id.uuidString) == nil)
        #expect(f.store.loadSession(id: f.id.uuidString)?.messages == f.sourceMessages)
        #expect(f.chat.messages.filter { $0.role != .system }.map { $0.asLLMMessage() } == f.sourceMessages)
    }
}
