import Foundation
import Testing
import enum MinisCore.LLMStreamChunk
import protocol MinisCore.LLMProvider
import struct MinisCore.LLMMessage
import struct MinisCore.LLMModel
import struct MinisCore.LLMResponse
@testable import MinisApp

/// MinisApp 纯逻辑单元测试：Markdown 块解析、越界安全下标、命令面板元数据、
/// 会话/应用状态计算。不触碰 UI 渲染，不测试 Ollama 相关功能，不发起网络请求。

// MARK: - Helpers

/// MarkdownBlock 未声明 Equatable，用可读字符串描述后比较。
private func describe(_ block: MarkdownBlock) -> String {
    switch block {
    case .paragraph(let s): return "paragraph:\(s)"
    case .heading(let s): return "heading:\(s)"
    case .listItem(let s): return "listItem:\(s)"
    case .code(let s): return "code:\(s)"
    }
}

private func describe(_ blocks: [MarkdownBlock]) -> [String] {
    blocks.map(describe)
}

// MARK: - MarkdownRenderer.blocks

struct MarkdownBlocksTests {

    @Test func fencedCodeBlockPreservesInnerLines() {
        // 代码块在下一次边界（标题/列表/下一围栏/文本结尾）才冲刷，
        // 因此紧跟代码块的普通段落会先于代码块入列。
        let text = "开头段落\n```swift\nlet x = 1\n  indented\n```\n结尾段落"
        let blocks = MarkdownRenderer.blocks(from: text)
        #expect(describe(blocks) == [
            "paragraph:开头段落",
            "paragraph:结尾段落",
            "code:let x = 1\n  indented",
        ])
    }

    @Test func headingsListsAndParagraphs() {
        let text = """
        # 标题一
        普通段落
        - 列表项一
        * 列表项二
        + 列表项三

           # 缩进标题
        """
        let blocks = MarkdownRenderer.blocks(from: text)
        #expect(describe(blocks) == [
            "heading:标题一",
            "paragraph:普通段落",
            "listItem:列表项一",
            "listItem:列表项二",
            "listItem:列表项三",
            "heading:缩进标题",
        ])
    }

    @Test func numberedListsAndUnclosedFence() {
        let blocks = MarkdownRenderer.blocks(from: "1. 第一步\n12. 第十二步")
        #expect(describe(blocks) == [
            "listItem:第一步",
            "listItem:第十二步",
        ])

        // 未闭合围栏：剩余行全部作为代码块冲刷出来
        let unclosed = MarkdownRenderer.blocks(from: "```\nfoo\nbar")
        #expect(describe(unclosed) == ["code:foo\nbar"])
    }
}

// MARK: - Collection[safe:]

struct SafeSubscriptTests {

    @Test func safeSubscriptReturnsNilOutOfBounds() {
        let array = [1, 2, 3]
        #expect(array[safe: 1] == 2)
        #expect(array[safe: 3] == nil)
        #expect(array[safe: -1] == nil)

        let empty: [Int] = []
        #expect(empty[safe: 0] == nil)
    }
}

// MARK: - PaletteCommand 元数据

struct PaletteCommandTests {

    @Test func allCommandsHaveUniqueKnownIDs() {
        let all = PaletteCommand.all
        #expect(all.count == 5)
        #expect(all.map(\.id) == ["new", "toggleMock", "toggleMessages", "settings", "canvas"])
        #expect(Set(all.map(\.id)).count == all.count)

        let newCommand = all.first { $0.id == "new" }
        #expect(newCommand?.shortcut == "⌘N")
        #expect(all.first { $0.id == "settings" }?.shortcut == nil)
        #expect(all.allSatisfy { !$0.title.isEmpty && !$0.icon.isEmpty })
    }
}

// MARK: - ChatSession / ChatMessageUI 状态计算

@MainActor
struct ChatSessionTests {

    @Test func sessionDefaultsAndLastMessagePreview() {
        let session = ChatSession()
        #expect(session.title == "新会话")
        #expect(session.isPinned == false)
        #expect(session.messages.isEmpty)
        #expect(session.lastMessagePreview == "空会话")

        let message = ChatMessageUI(role: .user, content: "第一行\n第二行")
        #expect(message.isStreaming == false)
        session.messages.append(message)
        // 预览中的换行被替换为空格
        #expect(session.lastMessagePreview == "第一行 第二行")
    }
}

// MARK: - AppState 会话管理 / 命令分发

@MainActor
struct AppStateTests {

    @Test func sessionLifecycleSearchAndDelete() {
        let state = AppState()
        #expect(state.sessions.count == 1)
        #expect(state.selectedSession != nil)

        // 新建会话：插入到最前并选中，清空草稿
        state.draftText = "草稿"
        state.newSession()
        #expect(state.sessions.count == 2)
        #expect(state.sessions.first?.id == state.selectedSessionID)
        #expect(state.draftText.isEmpty)

        // 固定置顶
        let newest = state.sessions[0]
        state.togglePin(newest)
        #expect(newest.isPinned)
        #expect(state.pinnedSessions.map(\.id) == [newest.id])
        #expect(state.unpinnedSessions.count == 1)

        // 搜索：按标题匹配，空白查询返回全部，未知关键词为空
        let original = state.sessions[1]
        original.title = "Swift 画布测试"
        #expect(state.session(matching: "画布").map(\.id) == [original.id])
        #expect(state.session(matching: "   ").count == 2)
        #expect(state.session(matching: "不存在的关键词xyz").isEmpty)

        // 删除当前选中的会话后自动改选第一个
        state.deleteSession(newest)
        #expect(state.sessions.count == 1)
        #expect(state.selectedSessionID == original.id)
    }

    @Test func runCommandTogglesStateAndProviderLabel() {
        let state = AppState()

        // toggleMessages：翻转消息列表栏可见性，并关闭命令面板
        state.palettePresented = true
        state.runCommand(PaletteCommand.all.first { $0.id == "toggleMessages" }!)
        #expect(state.showMessageList == false)
        #expect(state.palettePresented == false)

        // toggleMock：重置 Provider / 模型选择
        state.selectedProviderType = .openAI
        state.runCommand(PaletteCommand.all.first { $0.id == "toggleMock" }!)
        #expect(state.selectedProviderType == nil)
        #expect(state.selectedModel == nil)
        #expect(state.providerLabel == "Mock 演示")

        // settings：打开设置
        state.runCommand(PaletteCommand.all.first { $0.id == "settings" }!)
        #expect(state.settingsPresented == true)

        // 选中 Provider 但未选模型时的标签
        state.selectedProviderType = .anthropic
        #expect(state.providerLabel == "Anthropic")
    }
}

// MARK: - Streaming session isolation

@MainActor
struct StreamingSessionTests {

    @Test func newSessionCanSendWhilePreviousSessionIsStreaming() async throws {
        let state = AppState()
        state.draftText = "旧会话请求"
        state.sendDraft()
        let firstSession = try #require(state.selectedSession)

        state.newSession()
        let newSession = try #require(state.selectedSession)
        state.draftText = "新会话请求"
        state.sendDraft()

        #expect(newSession.messages.count == 2, "新会话不应被旧会话的流式状态拦截")
        #expect(newSession.messages.first?.content == "新会话请求")
        #expect(state.streamingSessionID == newSession.id)

        var waited = 0
        while newSession.messages.last?.content.contains("新会话请求") != true && waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(newSession.messages.last?.content.contains("新会话请求") == true)
        #expect(firstSession.messages.last?.role == .assistant)

        state.stopStreaming()
    }

    @Test func stoppingStreamingClearsSessionIdentityBeforeNextSend() throws {
        let state = AppState()
        state.draftText = "需要停止"
        state.sendDraft()
        let firstSession = try #require(state.selectedSession)

        state.stopStreaming()
        #expect(state.streamingSessionID == nil)

        state.newSession()
        let newSession = try #require(state.selectedSession)
        state.draftText = "停止后的新请求"
        state.sendDraft()

        #expect(newSession.messages.count == 2)
        #expect(newSession.messages.first?.content == "停止后的新请求")
        #expect(state.streamingSessionID == newSession.id)
        #expect(firstSession.messages.last?.isStreaming == false)

        state.stopStreaming()
    }
}

private actor TestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum DeterministicProviderError: Error {
    case failed
}

private final class DeterministicProvider: LLMProvider, @unchecked Sendable {
    let firstStreamStarted = TestLatch()
    let releaseFirstStream = TestLatch()
    let fails: Bool
    private var streamCount = 0

    init(fails: Bool = false) {
        self.fails = fails
    }

    var name: String { "Deterministic Test Provider" }
    var model: LLMModel = LLMModel(
        id: "deterministic-test",
        displayName: "Deterministic Test",
        provider: "Tests"
    )

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        if fails {
            return AsyncThrowingStream { continuation in
                continuation.yield(.started)
                continuation.finish(throwing: DeterministicProviderError.failed)
            }
        }

        let streamNumber = streamCount
        streamCount += 1
        return AsyncThrowingStream { continuation in
            Task {
                if streamNumber == 0 {
                    await self.firstStreamStarted.open()
                    await self.releaseFirstStream.wait()
                    continuation.yield(.text("迟到正文"))
                } else {
                    continuation.yield(.text("新回合正文"))
                }
                continuation.yield(.finished(stopReason: "end_turn"))
                continuation.finish()
            }
        }
    }
}

@MainActor
struct StreamingTerminalStateTests {

    @Test func providerErrorFinalizesMessageAndClearsStreamingState() async throws {
        let state = AppState(provider: DeterministicProvider(fails: true))
        state.draftText = "失败请求"
        state.sendDraft()
        let session = try #require(state.selectedSession)

        var waited = 0
        while state.streamingSessionID != nil && waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }

        #expect(state.streamingSessionID == nil)
        #expect(session.messages.last?.isStreaming == false)
        #expect(session.messages.last?.content.contains("错误") == true)
    }

    @Test func lateChunkFromStoppedTurnCannotWriteIntoNewTurn() async throws {
        let provider = DeterministicProvider()
        let state = AppState(provider: provider)
        state.draftText = "第一回合"
        state.sendDraft()
        let session = try #require(state.selectedSession)
        await provider.firstStreamStarted.wait()

        state.stopStreaming()
        #expect(state.streamingSessionID == nil)
        #expect(session.messages.last?.isStreaming == false)

        state.draftText = "第二回合"
        state.sendDraft()
        var waited = 0
        while session.messages.last?.content != "新回合正文" && waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(session.messages.last?.content == "新回合正文")
        #expect(session.messages.last?.isStreaming == false)

        await provider.releaseFirstStream.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.messages.last?.content == "新回合正文")
        #expect(state.streamingSessionID == nil)
    }
}
