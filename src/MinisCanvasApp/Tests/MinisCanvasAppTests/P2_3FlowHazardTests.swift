import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - P2-3 流程隐患修复测试
//
// 覆盖 5 项修复（对应 P1 报告 W-1/W-2/W-3/W-5/W-6）：
// 1. 执行输出写回节点：LLM 节点 outputs["text"] → params["content"]，双击看到执行产物；
//    源节点（novelImport）保留用户粘贴内容不被覆盖
// 2. 无 key 引导：LLM 节点输出明确中文引导「未配置 API Key：请在设置中配置，或检查环境变量」
// 3. QC FAIL 视觉化：QC 校验 FAIL → 节点 .failed（红色）+ Canvas-local report
// 4. BLOCKED 闸口：提示词节点缺槽 → 输出 BLOCKED + 节点标红（铁律7 产出点生效）
// 5. manju skill 部署：Hermes 技能库 manju-* → App SkillStore（幂等、缺源静默）

@Suite("P2-3 流程隐患修复", .serialized)
@MainActor
struct P2_3FlowHazardTests {

    /// T1 测试隔离：unset API key env，LLM 节点必然走无 key 引导路径
    /// （不依赖开发机 shell 是否有真实 key，测试确定）
    init() {
        TestEnvIsolation.hermeticize()
    }

    /// 等待执行结束（主线程挂起让事件投递执行；后台调度线程独立推进）
    private func waitForIdle(_ store: CanvasStore, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && store.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 固定文本 stub（CanvasCore LLMInvoker 协议）
    private struct StubLLMInvoker: LLMInvoker {
        let text: String
        func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String { text }
    }

    // MARK: - 1) 执行输出写回节点（W-2）

    @Test func llmOutputWrittenBackToNodeContent() async throws {
        let store = CanvasStore()
        let node = try #require(store.addNode(ofType: "llm"))
        store.runGraph()
        await waitForIdle(store)

        // 无 key：LLM 节点输出引导文本并写回 content → 双击能看到执行产物（不再空白/旧输入）
        let content = store.content(of: node.id)
        #expect(content.contains("未配置 API Key：请在设置中配置，或检查环境变量"),
                "执行输出应写回节点内容（W-2），实际：\(content.prefix(60))")
        #expect(content.hasPrefix("【未配置 API Key】"))
    }

    @Test func sourceNodeContentPreservedAfterRun() async throws {
        let store = CanvasStore()
        let novel = try #require(store.addNode(ofType: "novelImport"))
        let original = "从前有座山，山里有座庙。庙里有个老和尚在讲故事。"
        store.setContent(nodeID: novel.id, content: original)

        store.runGraph()
        await waitForIdle(store)

        // 源节点（无输入端口）：保留用户粘贴的小说原文，不被执行输出覆盖
        #expect(store.content(of: novel.id) == original)
    }

    // MARK: - 2) 无 key 引导文案（W-3）

    @Test func noKeyGuidanceInsteadOfPlaceholder() async throws {
        let store = CanvasStore()
        let node = try #require(store.addNode(ofType: "llm"))
        store.runGraph()
        await waitForIdle(store)

        let content = store.content(of: node.id)
        #expect(!content.contains("【LLM 占位输出"), "不应再输出旧占位文本")
        #expect(content.contains("请在设置中配置"), "应引导去设置配置")
        #expect(content.contains("DASHSCOPE_API_KEY"), "应提示检查环境变量")
    }

    // MARK: - 3) QC FAIL 视觉化（W-1）

    @Test func qcFailMarksNodeFailedWithoutWritingChat() async throws {
        let bridge = BridgeStore()
        let text = try #require(bridge.canvas.addNode(ofType: "text"))
        bridge.canvas.setContent(nodeID: text.id, content: "随便一段没有槽位结构的文本")
        let qc = try #require(bridge.canvas.addNode(ofType: "qcCheck"))
        #expect(bridge.canvas.connectNodes(fromID: text.id, toID: qc.id))
        let sessionID = bridge.chat.activeSessionID
        let messagesBefore = bridge.chat.messages
        let revisionBefore = bridge.chat.transcriptRevision(forSession: sessionID)
        let streamingBefore = bridge.chat.isStreaming

        bridge.canvas.runGraph()
        await waitForIdle(bridge.canvas)

        // 节点红色失败态（非绿色成功）
        #expect(bridge.canvas.graph.node(id: qc.id)?.status == .failed,
                "QC FAIL 节点应标记失败（红色）而非成功（绿色）")
        #expect(bridge.canvas.graph.node(id: text.id)?.status == .succeeded)
        // QC report 写回节点内容（双击可见 FAIL 原因）
        let report = bridge.canvas.content(of: qc.id)
        #expect(report.contains("状态: FAIL"))
        #expect(report.contains("铁律7"))
        let output = try #require(bridge.canvas.lastResult?.outputs[qc.id])
        #expect(output["status"] as? String == "FAIL")
        #expect(output["qc_status"] as? String == "FAIL")
        #expect(output["report"] as? String == report)
        #expect((output["reasons"] as? String)?.contains("铁律7") == true)
        #expect(bridge.chat.messages == messagesBefore)
        #expect(bridge.chat.transcriptRevision(forSession: sessionID) == revisionBefore)
        #expect(bridge.chat.isStreaming == streamingBefore)
    }

    @Test func qcPassStaysSucceeded() async throws {
        let bridge = BridgeStore()
        let text = try #require(bridge.canvas.addNode(ofType: "text"))
        bridge.canvas.setContent(nodeID: text.id, content: Self.completeImagePrompt)
        let qc = try #require(bridge.canvas.addNode(ofType: "qcCheck"))
        #expect(bridge.canvas.connectNodes(fromID: text.id, toID: qc.id))
        let sessionID = bridge.chat.activeSessionID
        let messagesBefore = bridge.chat.messages
        let revisionBefore = bridge.chat.transcriptRevision(forSession: sessionID)

        bridge.canvas.runGraph()
        await waitForIdle(bridge.canvas)

        #expect(bridge.canvas.graph.node(id: qc.id)?.status == .succeeded)
        #expect(bridge.chat.messages == messagesBefore)
        #expect(bridge.chat.transcriptRevision(forSession: sessionID) == revisionBefore)
    }

    // MARK: - 4) BLOCKED 闸口（W-6，store 级标红 + 写回）

    @Test func blockedPromptNodeMarkedFailedAndVisible() async throws {
        let context = GraphExecutionContext(
            executors: NodeExecutors(llmInvoker: StubLLMInvoker(text: "没有槽位结构的自由文本")),
            imageInvoker: MinisCanvasImageInvoker()
        )
        let store = CanvasStore(graph: NodeGraph(), context: context)
        let node = try #require(store.addNode(ofType: "imagePrompt"))

        store.runGraph()
        await waitForIdle(store)

        // 缺槽 → 节点红色失败态
        #expect(store.graph.node(id: node.id)?.status == .failed, "BLOCKED 提示词节点应标红")
        // BLOCKED 文本写回节点内容（双击可见缺哪些槽）
        let content = store.content(of: node.id)
        #expect(content.contains("【BLOCKED】"))
        #expect(content.contains("未检测到 8/9 槽结构标记"))
        // 输出带 missing_slots / blocked 标记（供 Canvas report 与下游识别）
        let outputs = store.lastResult?.outputs[node.id]
        #expect(outputs?["blocked"] as? String == "1")
        #expect(outputs?["status"] as? String == "blocked")
    }

    @Test func completePromptNodeSucceeds() async throws {
        let context = GraphExecutionContext(
            executors: NodeExecutors(llmInvoker: StubLLMInvoker(text: Self.completeImagePrompt)),
            imageInvoker: MinisCanvasImageInvoker()
        )
        let store = CanvasStore(graph: NodeGraph(), context: context)
        let node = try #require(store.addNode(ofType: "imagePrompt"))

        store.runGraph()
        await waitForIdle(store)

        #expect(store.graph.node(id: node.id)?.status == .succeeded)
        #expect(store.content(of: node.id).contains("[TYPE]"), "完整提示词应写回节点内容")
    }

    // MARK: - 5) manju skill 部署（W-5）



    // MARK: - 测试数据

    /// 完整 8 槽图片提示词（结构闸口通过）
    static let completeImagePrompt = """
    [TYPE]
    9:16 竖屏定妆图，危险但美（美感70%/危险30%）。

    [REFERENCE]
    参考图：asset://weixian-face-8angle。魏衔 定妆图只继承：脸、五官、眼型、骨相、肤色。

    [LAYOUT]
    主体居中偏右、留白在左，有主次关系和视觉动线。

    [STRUCTURE]
    粗麻织纹、袖口磨损起毛、厚垂坠。

    [MATERIAL]
    粗麻、磨损、垂坠。

    [COLOR]
    玄青(#1F2A33) 70%、灰褐(#6B5D4F) 20%、暗金(#B08D3E) 8%、朱砂(#C2452D) 2%。

    [LIGHT]
    侧逆光、轮廓光、斑驳树影。

    [FORBID]
    现代鞋、高跟鞋、换脸。
    """
}
