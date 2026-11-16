import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - 指令解析测试

@Suite("画布指令解析")
struct CommandParserTests {
    @Test func addNodeKeyword() {
        guard case .addNode(let kw)? = CommandParser.parse("建节点 llm") else {
            Issue.record("应解析为 addNode"); return
        }
        #expect(kw == "llm")
        guard case .addNode(let kw2)? = CommandParser.parse("添加节点 图像生成") else {
            Issue.record("应解析为 addNode"); return
        }
        #expect(kw2 == "图像生成")
    }

    @Test func connectArrow() {
        guard case .connect(let a, let b)? = CommandParser.parse("连线 文本输入 -> LLM 推理") else {
            Issue.record("应解析为 connect"); return
        }
        #expect(a == "文本输入")
        #expect(b == "LLM 推理")
    }

    @Test func connectNatural() {
        guard case .connect(let a, let b)? = CommandParser.parse("把 图像生成 连到 视频生成") else {
            Issue.record("应解析为 connect"); return
        }
        #expect(a == "图像生成")
        #expect(b == "视频生成")
    }

    @Test func runAndLayout() {
        guard case .run? = CommandParser.parse("执行") else {
            Issue.record("应解析为 run"); return
        }
        guard case .layout? = CommandParser.parse("自动布局") else {
            Issue.record("应解析为 layout"); return
        }
        guard case .reset? = CommandParser.parse("重置") else {
            Issue.record("应解析为 reset"); return
        }
    }

    @Test func nonCommandIsNil() {
        #expect(CommandParser.parse("你好，介绍一下自己") == nil)
    }
}

// MARK: - 双向联动集成测试

@Suite("聊天 ↔ 画布 联动")
@MainActor
struct BridgeTests {
    @Test func toolRoleAndToolCallIDRoundTripThroughSessionBridge() {
        let call = LLMToolCall(
            id: "call-bridge-1",
            name: "file_read",
            rawArguments: "{\"path\":\"notes.md\"}",
            arguments: ["path": "notes.md"]
        )
        let coreTool = LLMMessage(
            role: .tool,
            content: "读取完成",
            toolCallID: call.id
        )

        let uiTool = coreTool.asChatMessageUI()
        #expect(uiTool.role == .tool)
        #expect(uiTool.toolCallID == call.id)

        let roundTripped = uiTool.asLLMMessage()
        #expect(roundTripped.role == .tool)
        #expect(roundTripped.toolCallID == call.id)

        let uiAssistant = ChatMessageUI(
            role: .assistant,
            content: "",
            toolCalls: [call]
        )
        let assistantPayload = uiAssistant.asLLMMessage()
        #expect(assistantPayload.role == .assistant)
        #expect(assistantPayload.toolCalls == [call])
    }

    /// F4：等待画布执行 idle（有界轮询 —— 非无限等待；超时即让断言自然失败）。
    /// runGraph 是后台异步调度，立即断言结果必竞态；对齐 ExecutionFeedbackTests.waitForIdle。
    private func waitForIdle(_ canvas: CanvasStore, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && canvas.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func chatToCanvasAddAndConnectAndRun() async {
        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)

        // 聊天 → 画布：建节点（AJ-74：llm 已下线不可新建，用生图 imageGen 验证双节点）
        bridge.chat.draftText = "建节点 text"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        bridge.chat.draftText = "建节点 生图"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        #expect(bridge.canvas.graph.nodes.count == 2)

        // 聊天 → 画布：连线
        bridge.chat.draftText = "连线 文本输入 -> 生图"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        await waitUntil {
            bridge.canvas.graph.edges.count == 1
        }
        #expect(bridge.canvas.graph.edges.count == 1)

        // 聊天 → 画布：执行（F4：runGraph 为后台异步调度 —— 先等 idle 再断言结果，
        // 否则 isRunning/节点状态都还是执行中的中间态）
        bridge.chat.draftText = "执行"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        await waitUntil {
            bridge.canvas.graph.nodes.contains {
                $0.status == .running
                    || $0.status == .succeeded
                    || $0.status == .failed
            }
        }
        await waitForIdle(bridge.canvas)
        #expect(!bridge.canvas.isRunning)
        let statuses = bridge.canvas.graph.nodes.map { $0.status }
        #expect(statuses.contains(.succeeded))

        // 画布 → 聊天：事件提示已写入聊天流（system 消息）
        let systemMessages = bridge.chat.messages.filter { $0.role == .system }
        #expect(!systemMessages.isEmpty)
        let joined = systemMessages.map { $0.content }.joined(separator: "\n")
        await waitUntil {
            let current = bridge.chat.messages
                .filter { $0.role == .system }
                .map(\.content)
                .joined(separator: "\n")
            return current.contains("执行")
        }
        let finalJoined = bridge.chat.messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n")
        #expect(joined.contains("新增节点"))
        #expect(finalJoined.contains("连线"))
        #expect(finalJoined.contains("执行"))
    }

    @Test("Canvas events stay out of Chat transcript and status")
    func canvasEventFlowsToChat() {
        let bridge = BridgeStore()
        let sessionID = bridge.chat.activeSessionID
        let messagesBefore = bridge.chat.messages
        let revisionBefore = bridge.chat.transcriptRevision(forSession: sessionID)
        let streamingBefore = bridge.chat.isStreaming

        let node = bridge.canvas.addNode(ofType: "image")

        #expect(node != nil)
        #expect(bridge.chat.messages == messagesBefore)
        #expect(bridge.chat.transcriptRevision(forSession: sessionID) == revisionBefore)
        #expect(bridge.chat.isStreaming == streamingBefore)
    }

    @Test("Node selection updates Canvas context without writing Chat state")
    func nodeSelectionShowsContextInChat() {
        let bridge = BridgeStore()
        let sessionID = bridge.chat.activeSessionID
        let messagesBefore = bridge.chat.messages
        let revisionBefore = bridge.chat.transcriptRevision(forSession: sessionID)
        let streamingBefore = bridge.chat.isStreaming
        let node = bridge.canvas.addNode(ofType: "llm")
        #expect(node != nil)

        bridge.canvas.selectNode(id: node!.id)
        #expect(bridge.selectedNodeContext != nil)
        #expect(bridge.selectedNodeContext?.title == "LLM 推理")
        #expect(bridge.selectedNodeContext?.type == "llm")
        #expect(bridge.selectedNodeContext?.modelID == "qwen3.8-max-preview")
        #expect(bridge.selectedNodeContext?.inputCount == 2)
        #expect(bridge.chat.messages == messagesBefore)
        #expect(bridge.chat.transcriptRevision(forSession: sessionID) == revisionBefore)
        #expect(bridge.chat.isStreaming == streamingBefore)

        let countBefore = bridge.chat.messages.count
        bridge.canvas.selectNode(id: node!.id)
        #expect(bridge.chat.messages.count == countBefore)

        bridge.canvas.deselectAll()
        #expect(bridge.selectedNodeContext == nil)
        #expect(bridge.chat.messages == messagesBefore)
        #expect(bridge.chat.transcriptRevision(forSession: sessionID) == revisionBefore)
    }
}
