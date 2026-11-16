import Testing
import Foundation
@testable import CanvasCore

// MARK: - P2-2-fix 收尾：数据链 content 回退 + 生视频任务单降级 + QC 任务单识别

/// 覆盖 P2-2 被截断的 3 项收尾：
/// 1. resolveInputs 读 content：源节点（无输入边）时 params["content"] 以 text 端口进入 LLM
/// 2. 生视频无 invoker：videoGen/video 节点降级 9 槽任务单（jobTicket markdown，不阻塞画布）
/// 3. QC 识别 job_ticket：输入为降级任务单时输出「待生成后复检」，不校验成片
struct P2_2VideoTicketFinishTests {

    /// 记录 prompt 的 LLM stub（验证 content 数据链真实进入 LLM 调用）
    private final class CapturingLLMInvoker: LLMInvoker, @unchecked Sendable {
        let lock = NSLock()
        var captured: String?
        func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String {
            set(prompt)
            return "OK"
        }
        // NSLock.lock/unlock 在 async 上下文不可用，经同步辅助函数中转
        private func set(_ prompt: String) {
            lock.lock(); defer { lock.unlock() }
            captured = prompt
        }
        func lastPrompt() -> String? {
            lock.lock(); defer { lock.unlock() }
            return captured
        }
    }

    /// 生图 stub（本组测试不触发生图；仅满足 GraphExecutionContext 注入签名）
    private struct StubImageInvoker: ImageGenerating {
        func generate(
            node: CanvasNode, prompt: String, backend: NodeBackendConfig?
        ) async throws -> ImageGenerationOutcome {
            .jobTicket(prompt: prompt, markdown: "# 生成任务单")
        }
    }

    private func makeContext(
        llm: (any LLMInvoker)? = nil,
        video: (any VideoGenerating)? = nil
    ) -> GraphExecutionContext {
        GraphExecutionContext(
            executors: NodeExecutors(llmInvoker: llm),
            imageInvoker: StubImageInvoker(),
            videoInvoker: video
        )
    }

    // MARK: - 1) resolveInputs 读 content（源节点无输入边 → params["content"] 进入 LLM）

    @Test func resolveInputsReadsContentParamForSourceNode() throws {
        let context = makeContext()
        var graph = NodeGraph()
        let node = CanvasNode(
            type: "llm",
            title: "LLM",
            backendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview",
                params: ["content": "双击粘贴的小说正文……"]
            )
        )
        graph.addNode(node)

        let inputs = try context.resolveInputs(for: node, in: graph) { _ in nil }
        #expect(inputs?["text"] as? String == "双击粘贴的小说正文……",
                "源节点无输入边时 resolveInputs 应把 params[content] 以 text 端口交给执行器")
    }

    @Test func contentFlowsIntoLLMInvocationEndToEnd() async throws {
        let llm = CapturingLLMInvoker()
        let context = makeContext(llm: llm)
        var graph = NodeGraph()
        let node = CanvasNode(
            type: "llm",
            title: "LLM",
            backendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview",
                params: ["content": "双击粘贴的小说正文……"]
            )
        )
        graph.addNode(node)

        let resolved = try context.resolveInputs(for: node, in: graph) { _ in nil }
        _ = try await context.executeAsync(node: node, inputs: resolved)

        #expect(llm.lastPrompt()?.contains("text: 双击粘贴的小说正文……") == true,
                "content 应经 resolveInputs → LLMNodeExecutor.buildPrompt 进入真实 LLM 调用")
    }

    // MARK: - 2) 生视频无 invoker → 9 槽任务单降级

    @Test func videoGenWithoutInvokerDegradesToNineSlotTicket() async throws {
        let context = makeContext() // videoInvoker = nil
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频生成")

        let output = try await context.executeAsync(
            node: node,
            inputs: ["prompt": Self.validVideoPrompt]
        )

        #expect(output["status"] as? String == "job_ticket", "无 invoker 应降级任务单而非抛错")
        #expect(output["provider"] as? String == "none")
        let ticket = output["jobTicket"] as? String ?? ""
        #expect(ticket.contains("生成任务单"), "任务单应含标题标记（QC 据此识别）")
        #expect(ticket.contains("## 9 槽结构"), "任务单应为 9 槽结构（铁律7）")
        #expect(ticket.contains("## 完整提示词"), "任务单应含完整提示词导出段")
        #expect((output["video"] as? String) == ticket, "video 端口承载任务单全文供 QC 读取")
        #expect((output["prompt"] as? String)?.contains("[MODE]") == true, "prompt 端口保留提示词全文")
    }

    @Test func builtinVideoNodeDegradesToJobTicketToo() async throws {
        let context = makeContext()
        let node = CanvasNode(type: "video", title: "视频")
        let output = try await context.executeAsync(node: node, inputs: ["prompt": "I2V 一段打斗"])
        #expect(output["status"] as? String == "job_ticket")
        #expect((output["jobTicket"] as? String)?.contains("9 槽") == true)
    }

    @Test func videoGenWithJobTicketInvokerKeepsTicket() async throws {
        // 注入的 invoker 无 key 返回 .jobTicket → 输出仍走任务单（status=job_ticket, provider=video）
        struct NoKeyVideoInvoker: VideoGenerating {
            func generate(
                node: CanvasNode, prompt: String, firstFrame: String?, backend: NodeBackendConfig?
            ) async throws -> VideoGenerationOutcome {
                .jobTicket(prompt: prompt, markdown: "# 生成任务单 · \\(node.title)")
            }
        }
        let context = makeContext(video: NoKeyVideoInvoker())
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频生成")
        let output = try await context.executeAsync(node: node, inputs: ["prompt": Self.validVideoPrompt])
        #expect(output["status"] as? String == "job_ticket")
        #expect(output["provider"] as? String == "video")
        #expect((output["jobTicket"] as? String)?.contains("生成任务单") == true)
    }

    // MARK: - 3) QC 识别 job_ticket → 「待生成后复检」

    @Test func qcRecognizesJobTicketViaVideoPort() async throws {
        let executor = QCNodeExecutor()
        let videoNode = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频生成")
        let ticket = GraphExecutionContext.fallbackVideoTicketMarkdown(node: videoNode, prompt: Self.validVideoPrompt)

        let output = try await executor.execute(
            node: CanvasNode(type: "qcCheck", title: "QC"),
            inputs: ["video": ticket],
            backend: nil
        )
        #expect(output["status"] as? String == "待生成后复检", "任务单输入不应校验成片")
        #expect(output["qc_status"] as? String == "待生成后复检")
        #expect(output["job_ticket"] as? String == "1")
        #expect((output["report"] as? String)?.contains("待真实生成后复检") == true)
    }

    @Test func qcRecognizesJobTicketViaJobTicketPort() async throws {
        let executor = QCNodeExecutor()
        let output = try await executor.execute(
            node: CanvasNode(type: "qcCheck", title: "QC"),
            inputs: ["jobTicket": "## 9 槽结构（铁律7）……"],
            backend: nil
        )
        #expect(output["status"] as? String == "待生成后复检")
        #expect(output["job_ticket"] as? String == "1")
    }

    @Test func qcStillEvaluatesNormalPrompt() async throws {
        let executor = QCNodeExecutor()
        let output = try await executor.execute(
            node: CanvasNode(type: "qcCheck", title: "QC"),
            inputs: ["prompt": Self.validVideoPrompt],
            backend: nil
        )
        #expect(output["status"] as? String == "PASS", "非任务单输入仍走正常结构/审美校验")
        #expect(output["job_ticket"] == nil)
    }

    // MARK: - 测试数据

    /// 合法视频 9 槽提示词（与 ManjuNodeDeepeningTests 同源：三刻度盘 7/5/4，S1-S5 全过）
    static let validVideoPrompt = """
    [MODE]
    I2V

    [REFERENCE MAP]
    参考图：asset://weixian-face-8angle。魏衔 定妆图只继承：脸、五官、眼型、骨相、肤色；以上部位只锁定、不许改，禁止对部位做细节描述（铁律2/3）。

    [STYLE LOCK]
    weixian-lock：伪仙写实、暗部带色相、危险但美（美感70%/危险30%）

    [SHOT]
    中景、机位平视、缓慢推近、主体偏右留白；有主次关系和视觉动线，前中后景层次分明。

    [ACTION]
    0-1秒：转身。1-3秒：拔剑。3-5秒：挥剑定格。所有时间段之和必须精确等于镜头时长（铁律11）。

    [COLOR]
    玄青(#1F2A33) 70%、灰褐(#6B5D4F) 20%、暗金(#B08D3E) 8%、朱砂(#C2452D) 2%；强调色只在点睛位置。

    [SOUND]
    环境风声、衣袍摩擦声、剑鸣声。

    [FORBID]
    现代鞋、高跟鞋、换脸。

    [QC]
    status=PASS / skill_check=PASS / aesthetic_gate=PASS / style_lock=PASS / color_hierarchy=PASS / visual_flow=PASS / beauty_danger_ratio=70:30 / dial_variance=7 / dial_motion=5 / dial_density=4
    """
}
