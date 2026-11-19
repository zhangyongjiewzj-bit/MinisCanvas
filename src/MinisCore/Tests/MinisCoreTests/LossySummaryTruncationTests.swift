import Foundation
import Testing
@testable import MinisCore

/// C-2：摘要被输出上限截断时，提高上限重试一次；仍截断就明确标注“不完整”，续做提示不再假装完整。
private final class ScriptedSummaryProvider: LLMProvider, @unchecked Sendable {
    var name: String { "ScriptedSummary" }
    var model: LLMModel
    private(set) var maxTokensSeen: [Int] = []
    private(set) var requests: [[LLMMessage]] = []
    /// 每次请求发出时调用方给的缓存提示（摘要请求要关掉缓存断点）。
    private(set) var promptCachingSeen: [Bool] = []
    private var replies: [(String, String)]
    /// 第 N 次请求（从 0 数）抛限流错误。
    private let failingCall: Int?
    init(window: Int = 200_000, maxOutputTokens: Int? = nil, failingCall: Int? = nil,
         replies: [(String, String)]) {
        self.model = LLMModel(id: "summary-trunc", displayName: "T", provider: "test", contextWindow: window,
                              maxOutputTokens: maxOutputTokens)
        self.replies = replies
        self.failingCall = failingCall
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        if failingCall == maxTokensSeen.count { throw LLMError.rateLimited }
        maxTokensSeen.append(maxTokens)
        promptCachingSeen.append(LLMRequestHints.promptCaching)
        requests.append(messages)
        let reply = replies.isEmpty ? ("", "end_turn") : replies.removeFirst()
        return LLMResponse(text: reply.0, stopReason: reply.1, usage: nil)
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

@Suite("摘要被截断")
struct LossySummaryTruncationTests {
    private let messages = (0..<10).map {
        LLMMessage(role: $0 % 2 == 0 ? .user : .assistant, content: "MSG_\($0)_正文")
    }

    @Test(arguments: ["length", "max_tokens", "incomplete(max_output_tokens)", "incomplete"])
    func truncatedSummaryIsRetriedOnceWithALargerLimit(stopReason: String) async throws {
        let provider = ScriptedSummaryProvider(replies: [("半截摘要", stopReason), ("完整摘要：下一步 X", "end_turn")])
        let result = try await LossySummaryCompaction.compact(messages: messages, keepRecent: 2, provider: provider)
        #expect(provider.maxTokensSeen == [4_096, 8_192])
        let body = try #require(result.summary)
        #expect(body.contains("完整摘要：下一步 X"))
        #expect(!body.contains("半截摘要"))
        #expect(body.contains(LossySummaryCompaction.continuationNotice))
        #expect(!body.contains(LossySummaryCompaction.truncationNotice))
    }

    @Test func stillTruncatedAfterRetryIsMarkedIncompleteAndDoesNotPretendToBeComplete() async throws {
        let provider = ScriptedSummaryProvider(replies: [("半截一", "length"), ("半截二", "length")])
        let result = try await LossySummaryCompaction.compact(messages: messages, keepRecent: 2, provider: provider)
        #expect(provider.maxTokensSeen.count == 2)
        let body = try #require(result.summary)
        #expect(body.contains("半截二"))
        #expect(body.contains(LossySummaryCompaction.truncationNotice))
        #expect(body.contains(LossySummaryCompaction.truncatedContinuationNotice))
        #expect(!body.contains(LossySummaryCompaction.continuationNotice))
    }

    /// P3：摘要请求（含被截断后的重试）只发一次、不会被复用，不打 Anthropic 缓存断点；
    /// 压缩之外的请求不受影响（默认仍开）。
    @Test func summaryRequestsAskTheProviderForNoPromptCaching() async throws {
        let provider = ScriptedSummaryProvider(replies: [("半截摘要", "length"), ("完整摘要", "end_turn")])
        _ = try await LossySummaryCompaction.compact(messages: messages, keepRecent: 2, provider: provider)
        #expect(provider.promptCachingSeen == [false, false])
        #expect(LLMRequestHints.promptCaching, "the hint is scoped to the summary request")
    }

    @Test func completeSummaryIsNotRetried() async throws {
        let provider = ScriptedSummaryProvider(replies: [("完整", "end_turn")])
        _ = try await LossySummaryCompaction.compact(messages: messages, keepRecent: 2, provider: provider)
        #expect(provider.maxTokensSeen == [4_096])
    }

    @Test func tinyWindowCannotRaiseTheLimitSoItIsMarkedWithoutRetry() async throws {
        // 窗口 1024：输出预留 = max(512, 256) = 512，重试上限 = max(512, min(8192, 512)) = 512，没有可提高的空间。
        let provider = ScriptedSummaryProvider(window: 1_024, replies: [("半截", "length")])
        let result = try await LossySummaryCompaction.compact(messages: messages, keepRecent: 2, provider: provider)
        #expect(provider.maxTokensSeen.count == 1)
        #expect(try #require(result.summary).contains(LossySummaryCompaction.truncationNotice))
    }

    /// C3-08：重试上限不超过模型自己的最大输出。
    @Test func retryLimitIsCappedByTheModelsMaxOutput() async throws {
        // 最大输出 4096 = 首次上限，没有可提高的空间，不发起重试。
        let small = ScriptedSummaryProvider(maxOutputTokens: 4_096, replies: [("半截", "length"), ("不该被用到", "end_turn")])
        let smallResult = try await LossySummaryCompaction.compact(messages: messages, keepRecent: 2, provider: small)
        #expect(small.maxTokensSeen == [4_096])
        #expect(try #require(smallResult.summary).contains(LossySummaryCompaction.truncationNotice))
        // 最大输出 6000：重试用 6000，而不是 8192。
        let mid = ScriptedSummaryProvider(maxOutputTokens: 6_000, replies: [("半截", "length"), ("完整", "end_turn")])
        _ = try await LossySummaryCompaction.compact(messages: messages, keepRecent: 2, provider: mid)
        #expect(mid.maxTokensSeen == [4_096, 6_000])
    }

    /// C3-08：重试请求失败时沿用第一次被截断的摘要，并标注不完整。
    @Test func failedRetryKeepsTheFirstTruncatedSummary() async throws {
        let provider = ScriptedSummaryProvider(failingCall: 1, replies: [("第一次的半截摘要", "length")])
        let result = try await LossySummaryCompaction.compact(messages: messages, keepRecent: 2, provider: provider)
        #expect(provider.maxTokensSeen == [4_096])
        #expect(result.refusalReason == nil)
        let body = try #require(result.summary)
        #expect(body.contains("第一次的半截摘要"))
        #expect(body.contains(LossySummaryCompaction.truncationNotice))
        #expect(body.contains(LossySummaryCompaction.truncatedContinuationNotice))
    }

    /// R3-03：压缩不再带历史成功回执，摘要要自己写清已成功做过的改动。
    @Test func summaryPromptAsksForCompletedChangesSoSucceededReceiptsNeedNotBeKept() async throws {
        let provider = ScriptedSummaryProvider(replies: [("完整", "end_turn")])
        _ = try await LossySummaryCompaction.compact(messages: messages, keepRecent: 2, provider: provider)
        let request = try #require(provider.requests.first?.first?.content)
        #expect(request.contains("已成功写入、修改、删除、发送的内容"))
        #expect(request.contains("后续不要重复执行"))
    }

    /// C3-09：第一次压缩时历史超出摘要输入预算，最早的用户消息（任务目标）也固定放进请求。
    @Test func firstUserMessageStaysInTheSummaryRequestWhenOlderMessagesAreOmitted() async throws {
        let window = 10_000
        let provider = ScriptedSummaryProvider(window: window, replies: [("完整", "end_turn")])
        var history: [LLMMessage] = [LLMMessage(role: .user, content: "GOAL_FIRST_目标：只改 docs 目录")]
        for index in 1..<40 {
            history.append(LLMMessage(role: index % 2 == 0 ? .user : .assistant,
                                      content: "MSG_\(index)_" + String(repeating: "正文", count: 1_000)))
        }
        _ = try await LossySummaryCompaction.compact(messages: history, keepRecent: 2, provider: provider)
        let request = try #require(provider.requests.first?.first?.content)
        #expect(request.contains("更早内容已省略"))
        #expect(request.contains("GOAL_FIRST_目标：只改 docs 目录"))
        #expect(!request.contains("MSG_1_"))
        #expect(request.contains("MSG_37_"))
        // 目标消息在开头，且只出现一次。
        #expect(request.components(separatedBy: "GOAL_FIRST_").count == 2)
    }

    /// C3-09：用户原话块总量超限时，最早的一条固定保留，其余保留最新的。
    @Test func userQuotesAlwaysKeepTheEarliestOne() {
        let history = (0..<6).map { LLMMessage(role: .user, content: "第\($0)条：" + String(repeating: "字", count: 200)) }
        let quotes = LossySummaryCompaction.userQuotes(messages: history[...], characterLimit: 450)
        let kept = quotes.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(kept.first?.hasPrefix("- 第0条") == true)
        #expect(kept.last?.hasPrefix("- 第5条") == true)
        #expect(kept.count == 2)
        #expect(quotes.contains("（更早的 4 条原话因篇幅省略）"))
    }
}

/// R3-01：检查点要把保留的尾部原文（含图片 base64）整份存盘，单条上限 1MB。
/// 尾部有大图或大段文字时，超出的消息并入摘要，检查点照常存得进去。
@Suite("压缩检查点的尾部大小", .serialized)
struct LossySummaryTailSizeTests {
    private func session(tail: [LLMMessage]) throws -> (SessionStore, ChatSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tail-size-\(UUID())")
        let store = SessionStore(directory: root)
        let created = try store.createSession(id: "tail-size")
        for index in 0..<5 {
            try store.saveMessage(LLMMessage(role: index % 2 == 0 ? .user : .assistant,
                                             content: "早期消息 \(index)"), sessionID: created.id)
        }
        for message in tail { try store.saveMessage(message, sessionID: created.id) }
        return (store, try #require(store.loadSession(id: created.id)), root)
    }

    private func bigImage(_ bytes: Int) -> LLMMessage.ImageAttachment {
        .init(mimeType: "image/png", data: Data(repeating: 7, count: bytes))
    }

    @Test func twoMegabyteImageInTheTailIsSummarizedAndTheCheckpointSaves() async throws {
        // 大图不在最新一条用户消息里（后面还有用户新发的一条），它才会被并入摘要。
        let tail = [
            LLMMessage(role: .assistant, content: "尾部 A"),
            LLMMessage(role: .user, content: "看这张截图", images: [bigImage(2_000_000)]),
            LLMMessage(role: .assistant, content: "尾部 B"),
            LLMMessage(role: .user, content: "再问一句"),
            LLMMessage(role: .assistant, content: "尾部 C"),
        ]
        let (store, source, root) = try session(tail: tail)
        defer { try? FileManager.default.removeItem(at: root) }
        // 带 2MB 图的那条和它之前的并入摘要，保留其后的三条。
        #expect(LossySummaryCompaction.retainedCount(messages: source.messages, keepRecent: 4) == 3)
        let provider = ScriptedSummaryProvider(replies: [("摘要正文", "end_turn")])
        let result = try await LossySummaryCompaction.compact(
            messages: source.messages, keepRecent: 4, provider: provider)
        #expect(result.refusalReason == nil)
        #expect(result.projectionRecentCount == 3)
        let saved = try #require(try store.compareAndSaveCompactionPrefix(
            expectedSession: source, closedPrefixCount: source.messages.count, result: result))
        let restarted = SessionStore(directory: root)
        #expect(try restarted.loadLatestCompactionCheckpoint(sessionID: source.id) == saved)
        // 原始会话里的图片字节原样还在。
        #expect(restarted.loadSession(id: source.id)?.messages[6].images.first?.data.count == 2_000_000)
    }

    @Test func aTailMessageOverOneMegabyteOfTextIsSummarizedAndTheCheckpointSaves() async throws {
        let tail = [
            LLMMessage(role: .assistant, content: "尾部 A"),
            LLMMessage(role: .user, content: String(repeating: "长", count: 500_000)),  // UTF-8 约 1.5MB
            LLMMessage(role: .assistant, content: "尾部 B"),
            LLMMessage(role: .user, content: "再问一句"),
            LLMMessage(role: .assistant, content: "尾部 C"),
        ]
        let (store, source, root) = try session(tail: tail)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(LossySummaryCompaction.retainedCount(messages: source.messages, keepRecent: 4) == 3)
        let result = try await LossySummaryCompaction.compact(
            messages: source.messages, keepRecent: 4,
            provider: ScriptedSummaryProvider(replies: [("摘要正文", "end_turn")]))
        #expect(try store.compareAndSaveCompactionPrefix(
            expectedSession: source, closedPrefixCount: source.messages.count, result: result) != nil)
    }

    /// F-02：尾部预算不许把用户刚发的这条消息挤出去（对齐 Claude Code：自动压缩不压掉用户刚发的消息）。
    /// 最新一条用户消息带 2MB 图：不套预算，存不进检查点就拒绝，本次不压缩、也不先花一次摘要请求。
    @Test func theNewestUserMessageWithABigImageIsNeverCompactedAwayAndTheCompactionIsRefused() async throws {
        let tail = [
            LLMMessage(role: .assistant, content: "尾部 A"),
            LLMMessage(role: .assistant, content: "尾部 B"),
            LLMMessage(role: .user, content: "这张图里写的是什么", images: [bigImage(2_000_000)]),
        ]
        let (_, source, root) = try session(tail: tail)
        defer { try? FileManager.default.removeItem(at: root) }
        // 预算本来会把它挤出尾部（保留 0 条）；现在尾部照常保留三条，含这条消息。
        #expect(LossySummaryCompaction.retainedCount(messages: source.messages, keepRecent: 3) == 3)
        let provider = ScriptedSummaryProvider(replies: [("摘要正文", "end_turn")])
        let result = try await LossySummaryCompaction.compact(
            messages: source.messages, keepRecent: 3, provider: provider)
        #expect(result.refusalReason != nil)
        #expect(result.compactedCount == 0)
        #expect(result.messages == source.messages)
        #expect(provider.requests.isEmpty)
    }

    /// F-02：最新一条用户消息自己放得下但挤不进 1MB 预算时，同样不套预算；尾部总量仍在检查点上限内时照常压缩。
    @Test func theNewestUserMessageStaysInTheTailEvenWhenTheOneMegabyteBudgetWouldDropIt() async throws {
        let tail = [
            LLMMessage(role: .assistant, content: "尾部 A"),
            LLMMessage(role: .user, content: String(repeating: "长", count: 200_000)),   // UTF-8 约 0.6MB
            LLMMessage(role: .assistant, content: String(repeating: "答", count: 200_000)), // 约 0.6MB
        ]
        let (_, source, root) = try session(tail: tail)
        defer { try? FileManager.default.removeItem(at: root) }
        // 两条合计约 1.2MB，超过 1MB 预算；按预算会只留最新的助手回复、把用户消息并入摘要。
        #expect(LossySummaryCompaction.retainedCount(messages: source.messages, keepRecent: 3) == 3)
        let result = try await LossySummaryCompaction.compact(
            messages: source.messages, keepRecent: 3,
            provider: ScriptedSummaryProvider(replies: [("摘要正文", "end_turn")]))
        #expect(result.refusalReason == nil)
        #expect(result.projectionRecentCount == 3)
        #expect(result.messages.contains { $0.content.hasPrefix(String(repeating: "长", count: 100)) })
    }

    @Test func programGeneratedUserMessagesAreNotTheNewestRealUserMessage() {
        let messages = [
            LLMMessage(role: .user, content: "真正的问题"),
            LLMMessage(role: .assistant, content: "回答"),
            LLMMessage(role: .user, content: "<context-summary>\n摘要\n</context-summary>"),
            LLMMessage(role: .user, content: "<retained-store-facts>\nx\n</retained-store-facts>"),
            LLMMessage(role: .user, content: "〔目标续跑〕继续"),
            LLMMessage(role: .assistant, content: "收尾"),
        ]
        #expect(LossySummaryCompaction.latestRealUserMessageIndex(in: messages) == 0)
        let imageOnly = messages + [LLMMessage(role: .user, content: "", images: [bigImage(3)])]
        #expect(LossySummaryCompaction.latestRealUserMessageIndex(in: imageOnly) == 6)
    }

    @Test func userTextQuotingSummaryMarkerIsNotAProgramSummary() {
        let programSummary = LLMMessage(role: .user, content: "<context-summary>\n摘要\n</context-summary>")
        #expect(LossySummaryCompaction.isProgramSummary(programSummary))
        // 用户正文以标记开头，但不是整体被标记包住。
        let quoting = LLMMessage(role: .user, content: "<context-summary> 这个标记是什么意思？", images: [bigImage(3)])
        let quotingText = LLMMessage(role: .user, content: "<context-summary> 这个标记是什么意思？")
        let mentioned = LLMMessage(role: .assistant, content: "<context-summary>\n源码里的字面量\n</context-summary>")
        #expect(!LossySummaryCompaction.isProgramSummary(quoting))
        #expect(!LossySummaryCompaction.isProgramSummary(quotingText))
        #expect(!LossySummaryCompaction.isProgramSummary(mentioned))
        let messages = [LLMMessage(role: .user, content: "早先的问题"), LLMMessage(role: .assistant, content: "回"), quoting]
        #expect(LossySummaryCompaction.latestRealUserMessageIndex(in: messages) == 2)
        #expect(LossySummaryCompaction.firstGoalMessageIndex(in: messages[...]) == 0)
        #expect(LossySummaryCompaction.firstGoalMessageIndex(in: [quotingText][...]) == 0)
        #expect(LossySummaryCompaction.userQuotes(messages: [quotingText][...]).contains("这个标记是什么意思"))
    }

    @Test func smallImagesInTheTailAreStillKeptVerbatim() throws {
        let messages = [
            LLMMessage(role: .user, content: "早"), LLMMessage(role: .assistant, content: "回"),
            LLMMessage(role: .user, content: "图", images: [bigImage(3)]),
            LLMMessage(role: .assistant, content: "好"), LLMMessage(role: .user, content: "再"),
        ]
        #expect(LossySummaryCompaction.retainedCount(messages: messages, keepRecent: 3) == 3)
    }

    @Test func droppingTheOldestTailMessageNeverLeavesAnOrphanToolResult() {
        let call = LLMToolCall(id: "c1", name: "web_search", rawArguments: "{}", arguments: [:])
        let messages = [
            LLMMessage(role: .user, content: "问"),
            LLMMessage(role: .assistant, content: "查", toolCalls: [call]),
            LLMMessage(role: .tool, content: String(repeating: "x", count: 900_000), toolCallID: "c1"),
            LLMMessage(role: .assistant, content: String(repeating: "y", count: 300_000)),
        ]
        // 预算放不下“调用 + 大结果 + 回答”：调用和结果一起并入摘要，不留孤儿结果。
        #expect(LossySummaryCompaction.retainedCount(messages: messages, keepRecent: 3) == 1)
    }

    /// 检查点目录是所有会话共用的。其它会话的检查点合计超过 4MB，不能让新会话的压缩失败。
    @Test func otherSessionsCheckpointsDoNotCountTowardTheFourMegabyteLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-checkpoints-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        var saved: [(String, CompactionCheckpoint)] = []
        // 每个会话的检查点约 0.9MB（尾部保留一条约 0.9MB 的长文本），六个会话合计约 5.4MB。
        for index in 0..<6 {
            let id = "shared-\(index)"
            _ = try store.createSession(id: id)
            for early in 0..<5 {
                try store.saveMessage(LLMMessage(role: early % 2 == 0 ? .user : .assistant,
                                                 content: "早期消息 \(early)"), sessionID: id)
            }
            try store.saveMessage(LLMMessage(role: .assistant, content: String(repeating: "长", count: 300_000)),
                                  sessionID: id)
            let source = try #require(store.loadSession(id: id))
            let result = try await LossySummaryCompaction.compact(
                messages: source.messages, keepRecent: 1,
                provider: ScriptedSummaryProvider(replies: [("摘要正文", "end_turn")]))
            #expect(result.refusalReason == nil)
            let checkpoint = try #require(try store.compareAndSaveCompactionPrefix(
                expectedSession: source, closedPrefixCount: source.messages.count, result: result))
            saved.append((id, checkpoint))
        }
        let sizes = try FileManager.default.contentsOfDirectory(
            at: store.compactionCheckpointsDirectory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .map { try #require(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) }
        #expect(sizes.reduce(0, +) > 4 * 1024 * 1024)     // 前提：目录里的检查点合计已超过 4MB
        let reopened = SessionStore(directory: root)
        for (id, checkpoint) in saved {
            #expect(try reopened.loadLatestCompactionCheckpoint(sessionID: id) == checkpoint)
        }
    }

    /// F-04：同一会话每压缩一次留下一个检查点；尾部常带约 0.9MB 的内容时，不清理旧检查点，
    /// 累计超过 4MB 后每次压缩都存不进去。新检查点提交后，比“上一份”更早的正文要被删掉。
    @Test func sixCheckpointsOfNinetyPercentOfAMegabyteInOneSessionAllSaveAndOldPayloadsArePruned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("six-saves-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let id = "six-saves"
        _ = try store.createSession(id: id)
        var saved: [CompactionCheckpoint] = []
        for round in 0..<6 {
            try store.saveMessage(LLMMessage(role: .user, content: "第 \(round) 轮提问"), sessionID: id)
            try store.saveMessage(LLMMessage(role: .assistant, content: String(repeating: "长", count: 300_000)),
                                  sessionID: id)  // UTF-8 约 0.9MB，作为保留的尾部
            let source = try #require(store.loadSession(id: id))
            let result = try await LossySummaryCompaction.compact(
                messages: source.messages, keepRecent: 1,
                provider: ScriptedSummaryProvider(replies: [("摘要正文", "end_turn")]))
            #expect(result.refusalReason == nil)
            saved.append(try #require(try store.compareAndSaveCompactionPrefix(
                expectedSession: source, closedPrefixCount: source.messages.count, result: result)))
        }
        func payloadURL(_ checkpoint: CompactionCheckpoint) -> URL {
            store.compactionCheckpointsDirectory.appendingPathComponent(checkpoint.checkpointID + ".json")
        }
        // 只留最新一份和上一份的正文。
        for old in saved.dropLast(2) { #expect(!FileManager.default.fileExists(atPath: payloadURL(old).path)) }
        for kept in saved.suffix(2) { #expect(FileManager.default.fileExists(atPath: payloadURL(kept).path)) }
        // 重启后链校验照常通过：最新一份仍可读回，会话仍可恢复。
        let reopened = SessionStore(directory: root)
        #expect(try reopened.loadLatestCompactionCheckpoint(sessionID: id) == saved.last)
        _ = try reopened.resumeMessages(sessionID: id)
        // 清理之后还能继续压缩。
        try reopened.saveMessage(LLMMessage(role: .user, content: "再来一轮"), sessionID: id)
        try reopened.saveMessage(LLMMessage(role: .assistant, content: String(repeating: "长", count: 300_000)),
                                 sessionID: id)
        let source = try #require(reopened.loadSession(id: id))
        let result = try await LossySummaryCompaction.compact(
            messages: source.messages, keepRecent: 1,
            provider: ScriptedSummaryProvider(replies: [("摘要正文", "end_turn")]))
        #expect(try reopened.compareAndSaveCompactionPrefix(
            expectedSession: source, closedPrefixCount: source.messages.count, result: result) != nil)
    }

    @Test func aResultTheStoreCannotPersistIsARefusalNotAnError() async throws {
        let messages = (0..<8).map { LLMMessage(role: $0 % 2 == 0 ? .user : .assistant, content: "M\($0)") }
        let facts = (0..<(CompactionCheckpoint.maxReplacementHistoryCount + 1)).map {
            CompactionRetainedFact(kind: .taskState, text: "任务 \($0)")
        }
        let result = try await LossySummaryCompaction.compact(
            messages: messages, keepRecent: 2,
            provider: ScriptedSummaryProvider(replies: [("摘要正文", "end_turn")]),
            retentionFacts: facts)
        #expect(result.refusalReason != nil)
        #expect(result.compactedCount == 0)
    }
}
