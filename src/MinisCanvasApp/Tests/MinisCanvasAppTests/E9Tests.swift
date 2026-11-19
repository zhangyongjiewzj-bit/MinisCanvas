import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - E9 深链 / 快捷动作接线测试

@Suite("E9 深链与快捷动作接线")
@MainActor
struct DeepLinkWiringTests {

    private func makeBridge() -> BridgeStore {
        BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
    }

    // MARK: DeepLinkHandler 动作映射

    @Test func newSessionActionCreatesSession() {
        let bridge = makeBridge()
        let before = bridge.chat.sessions.count
        bridge.deepLinkHandler.handle(.newSession)
        #expect(bridge.chat.sessions.count == before + 1)
        #expect(bridge.chat.messages.contains { $0.content.contains("深链") })
    }

    @Test func createPipelineBuildsFullManjuGraph() {
        let bridge = makeBridge()
        bridge.deepLinkHandler.handle(.createPipeline)
        // P2-1：createPipeline 由 4 节点链升级为完整漫剧流水线（12 节点 · 16 连线）
        #expect(bridge.canvas.graph.nodes.count == 12)
        #expect(bridge.canvas.graph.edges.count == 16)
        let types = Set(bridge.canvas.graph.nodes.map(\.type))
        #expect(types.contains(ManjuNodeType.novelImport.rawValue))
        #expect(types.contains(ManjuNodeType.qcCheck.rawValue))
        #expect(types.contains(ManjuNodeType.assetRef.rawValue))
        // 无环：可分层
        #expect((try? DAGScheduler.layers(in: bridge.canvas.graph)) != nil)
    }

    @Test func sendPromptRoutesThroughChat() async {
        let bridge = makeBridge()
        bridge.deepLinkHandler.handle(.sendPrompt(text: "建节点 text", session: nil))
        await awaitLegacyCanvasCommandCompletion(bridge)
        // 画布指令优先：聊天输入被解析为建节点
        #expect(bridge.canvas.graph.nodes.count == 1)
        #expect(bridge.chat.messages.contains { $0.role == .user && $0.content == "建节点 text" })
    }

    @Test func openSettingsInvokesCallback() {
        let bridge = makeBridge()
        var opened: String? = "unset"
        bridge.deepLinkHandler.onOpenSettings = { opened = $0 }
        bridge.deepLinkHandler.handle(.openSettings(id: "provider"))
        #expect(opened == "provider")
        bridge.deepLinkHandler.handle(.openSettings(id: nil))
        #expect(opened == nil)
    }

    @Test func openSessionUnknownDoesNotCrash() {
        let bridge = makeBridge()
        bridge.deepLinkHandler.handle(.openSession(id: "no-such-session"))
        #expect(bridge.chat.messages.contains { $0.role == .system && $0.content.contains("会话不存在") })
        // 会话数不变（不误建新会话）
        #expect(bridge.chat.sessions.count == 1)
    }

    @Test func openSessionSwitchesToExisting() {
        let bridge = makeBridge()
        bridge.chat.newSession()
        let targetID = bridge.chat.sessions[0].id
        bridge.chat.switchSession(id: bridge.chat.sessions[1].id)
        bridge.deepLinkHandler.handle(.openSession(id: targetID.uuidString))
        #expect(bridge.chat.activeSessionID == targetID)
        // 切换成功是静默的：不往会话里追加系统消息。
        #expect(!bridge.chat.messages.contains { $0.role == .system && $0.content.contains("已切换到会话") })
    }

    @Test func externalPromptLinkNeedsConfirmationBeforeSending() {
        let bridge = makeBridge()
        let url = URL(string: "miniscanvas://prompt/hello")!
        var asked: String?
        bridge.deepLinkHandler.handleExternal(url: url) { text in asked = text; return false }
        #expect(asked?.contains("hello") == true)
        #expect(!bridge.chat.messages.contains { $0.role == .user && $0.content == "hello" })
        bridge.deepLinkHandler.handleExternal(url: url) { _ in true }
        // 普通文本不是画布指令，不会产生画布完成任务；用户消息在提交时同步写入。
        #expect(bridge.chat.messages.contains { $0.role == .user && $0.content == "hello" })
    }

    // MARK: 断链处理（不崩）

    @Test func unknownWorkflowReportsNotice() {
        let bridge = makeBridge()
        bridge.deepLinkHandler.handle(.runWorkflow(name: "不存在的流程", input: nil))
        #expect(bridge.chat.messages.contains { $0.content.contains("未找到工作流") })
    }

    @Test func workflowWithRequiredInputsReportsNotice() throws {
        let bridge = makeBridge()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E9Workflow-\(UUID().uuidString)", isDirectory: true)
        let store = WorkflowStore(storeDirectory: dir)
        let template = WorkflowTemplate(
            id: "e9-needs-input", name: "需输入流程", description: "test",
            steps: [WorkflowStep(id: "s1", type: .custom, title: "步骤", promptTemplate: "{{novel}}", outputKey: "out")],
            requiredInputs: ["novel"]
        )
        try store.saveTemplate(template)
        let handler = DeepLinkHandler(bridge: bridge, workflowStore: store)
        handler.handle(.runWorkflow(name: "e9-needs-input", input: nil))
        #expect(bridge.chat.messages.contains { $0.content.contains("需要输入") })
    }

    @Test func runWorkflowExecutesAndCompletes() async throws {
        let bridge = makeBridge()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E9Workflow-\(UUID().uuidString)", isDirectory: true)
        let store = WorkflowStore(storeDirectory: dir)
        let template = WorkflowTemplate(
            id: "e9-ok", name: "E9 测试流程", description: "test",
            steps: [
                WorkflowStep(id: "s1", type: .custom, title: "步骤一", promptTemplate: "输出 hello", outputKey: "out1"),
                WorkflowStep(id: "s2", type: .custom, title: "步骤二", promptTemplate: "再输出 {{out1}}", outputKey: "out2"),
            ],
            requiredInputs: []
        )
        try store.saveTemplate(template)
        let handler = DeepLinkHandler(bridge: bridge, workflowStore: store)
        handler.handle(.runWorkflow(name: "e9-ok", input: nil))
        // MockProvider 立即返回，轮询等待完成提示
        for _ in 0..<100
        where !bridge.chat.messages.contains(where: { $0.content.contains("工作流「E9 测试流程」完成") }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(bridge.chat.messages.contains { $0.content.contains("工作流「E9 测试流程」完成") })
    }

    // MARK: DeepLinkRouter 全链路（parse → handler → 动作）

    @Test func routerDispatchesParsedURL() async {
        let bridge = makeBridge()
        let before = bridge.chat.sessions.count
        DeepLinkRouter.shared.register { action in
            Task { @MainActor in
                bridge.deepLinkHandler.handle(action)
            }
        }
        #expect(DeepLinkRouter.shared.handle(url: URL(string: "miniscanvas://new-session")!) == true)
        for _ in 0..<50 where bridge.chat.sessions.count == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(bridge.chat.sessions.count == before + 1)
    }

    @Test func routerRejectsNonMinisCanvasScheme() async {
        let bridge = makeBridge()
        defer { withExtendedLifetime(bridge) {} }
        var handled: [DeepLinkAction] = []
        DeepLinkRouter.shared.register { action in
            Task { @MainActor in handled.append(action) }
        }
        #expect(DeepLinkRouter.shared.handle(url: URL(string: "https://example.com")!) == false)
        #expect(DeepLinkRouter.shared.handle(url: URL(string: "miniscanvas://bogus-route")!) == false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(handled.isEmpty)
    }

    // MARK: QuickActionStore → 命令面板同路径

    @Test func quickActionPerformsViaRouter() async {
        let bridge = makeBridge()
        let before = bridge.chat.sessions.count
        DeepLinkRouter.shared.register { action in
            Task { @MainActor in
                bridge.deepLinkHandler.handle(action)
            }
        }
        #expect(QuickActionStore.shared.perform(actionID: "new-chat") == true)
        for _ in 0..<50 where bridge.chat.sessions.count == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(bridge.chat.sessions.count == before + 1)
        // 未知 id → false，不崩
        #expect(QuickActionStore.shared.perform(actionID: "no-such-action") == false)
    }

    @Test func defaultActionsAllResolveToSupportedLinks() {
        for action in QuickActionStore.defaultActions {
            #expect(DeepLinkRouter.parse(url: URL(string: action.deepLinkURL)!) != nil,
                     "\(action.id) 的 deepLinkURL 应能被解析")
        }
    }
}
