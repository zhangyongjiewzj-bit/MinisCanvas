import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - 用户实际使用流程模拟（端到端静态检查）
// 目标：新建会话 → 发消息 → AI 回复 → 切换画布 → 新建节点 → 生成 → 保存 → 归档 → 设置。
// 静态走查：不调真实 API / 不弹窗，用 Mock Provider 验证流程可达性。

@Suite("用户流程：新建会话→发消息→AI回复")
@MainActor
struct UFNewSessionFlowTests {

    @Test func newSessionCreatesAndSwitches() {
        let chat = ChatStore()
        let first = chat.activeSessionID
        #expect(chat.sessions.count == 1)
        chat.newSession()
        #expect(chat.sessions.count == 2)
        #expect(chat.activeSessionID != first)
        #expect(chat.activeSessionID == chat.sessions.last?.id)
    }

    @Test func sendMessageGetsAssistantReply() async {
        let chat = ChatStore()
        // 无 Provider 选择 → Mock 回复（演示模式）
        chat.draftText = "你好，介绍一下你自己"
        chat.sendDraft()
        // 普通消息不应被画布指令拦截 → 应走 LLM 回复
        #expect(chat.messages.last?.role == .assistant)
        // 等待流式完成（Mock 逐字 20ms/词，有界等待）
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && chat.isStreaming {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        #expect(chat.messages.last?.content.isEmpty == false)
    }

    @Test func workspaceCommandInterceptsButReplyAppears() async {
        let chat = ChatStore()
        // 注入画布指令拦截（真实 App 由 BridgeStore 装配 onSendCommand：拦截后追加
        // .assistant 回执如「✅ 已创建节点」，而非走 LLM 流式回复）。
        chat.onSendCommand = { [weak chat] text, _ in
            guard let chat else { return false }
            if text.hasPrefix("建节点") {
                chat.appendAssistant("✅ 已创建节点「text」")
                return true
            }
            return false
        }
        // 画布指令（建节点）应被拦截，不产生 LLM 流式回复
        chat.draftText = "建节点 text"
        chat.sendDraft()
        // 拦截后追加 .assistant 回执（非 .system，非 LLM 流式回复）
        #expect(chat.messages.last?.role == .assistant)
        #expect(chat.messages.last?.content.contains("已创建节点") == true)
    }
}

@Suite("用户流程：普通对话不应被画布指令误吞")
struct UFCommandParserOverreachTests {

    @Test func normalConversationStartingWithRunIsNotCommand() {
        // 用户正常对话「执行这个功能」不应被解析为画布 run 指令
        #expect(CommandParser.parse("执行这个功能") == nil)
        #expect(CommandParser.parse("运行我的脚本") == nil)
    }

    @Test func exactRunCommandStillParses() {
        #expect(CommandParser.parse("执行") != nil)
        #expect(CommandParser.parse("运行") != nil)
        #expect(CommandParser.parse("执行画布") != nil)
    }

    @Test func shortHelpConversationIsNotHelpCommand() {
        // 「帮助我」是正常求助，不是 help 命令
        #expect(CommandParser.parse("帮助我") == nil)
        // 独立「帮助」仍是 help 命令
        #expect(CommandParser.parse("帮助") != nil)
    }
}

@Suite("用户流程：画布生成")
@MainActor
struct UFCreateRunFlowTests {
    /// 有界等待画布执行 idle
    private func waitForIdle(_ canvas: CanvasStore, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && canvas.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func addNodeAndRun() async {
        let bridge = BridgeStore()
        // 新建节点（工具栏/指令共用 store 入口）
        let node = bridge.canvas.addNode(ofType: "text")
        #expect(node != nil)
        #expect(bridge.canvas.graph.nodes.count == 1)
        // 生成
        bridge.canvas.runGraph()
        await waitForIdle(bridge.canvas)
        #expect(!bridge.canvas.isRunning)
        #expect(bridge.canvas.graph.nodes.first?.status == .succeeded)
    }

    @Test func createPipelineProducesNodes() {
        let bridge = BridgeStore()
        let pipeline = bridge.canvas.createManjuPipeline()
        #expect(pipeline.nodes.count > 5)
        #expect(bridge.canvas.graph.nodes.count == pipeline.nodes.count)
    }
}

@Suite("用户流程：归档与会话管理")
@MainActor
struct UFArchiveFlowTests {

    @Test func archiveAndRestoreSession() {
        let chat = ChatStore()
        chat.newSession()
        let toArchive = chat.activeSessionID!
        chat.archiveSession(id: toArchive)
        #expect(chat.archivedSessions.contains { $0.id == toArchive })
        #expect(!chat.sessions.contains { $0.id == toArchive })
        // 恢复
        chat.restoreSession(id: toArchive)
        #expect(chat.sessions.contains { $0.id == toArchive })
        #expect(chat.activeSessionID == toArchive)
    }

    @Test func deleteAndRestoreArchive() throws {
        let chat = ChatStore()
        chat.newSession()
        let toArchive = chat.activeSessionID!
        chat.archiveSession(id: toArchive)
        let intent = try chat.previewDeletion(id: toArchive, archived: true)
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try chat.deleteArchivedSession(id: toArchive, intent: intent)
        #expect(!chat.archivedSessions.contains { $0.id == toArchive })
    }
}

@Suite("用户流程：设置中心可达")
@MainActor
struct UFSystemSettingsTests {
    @Test func settingsCenterDefaultsAreValid() throws {
        guard let paths = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            Issue.record("formal test isolation contract missing")
            return
        }
        let center = SettingsCenter()
        #expect(center.settings.general.defaultProviderID == nil
                || !center.settings.general.defaultProviderID!.isEmpty)
        #expect(center.settingsStore.directory == paths.settingsDirectory)
        #expect(center.memoryStore.directory == paths.memoryDirectory)
        #expect(center.sessionStore.directory == paths.sessionDirectory)
        #expect(center.mcpManager.fileURL == paths.mcpFileURL)
        #expect(center.skillStore.skillsRoot == paths.skillsRoot)
        #expect(center.usageStore.defaultsDomain == .suite(paths.userDefaultsSuiteName))
    }
}
