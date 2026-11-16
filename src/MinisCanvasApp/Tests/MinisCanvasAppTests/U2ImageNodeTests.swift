import Testing
import Foundation
@testable import CanvasCore

// MARK: - U2：生图/生视频节点端口与执行链修复
//
// 覆盖 4 项：
// 1. imageGen 节点新增 image 输入端口（ManjuNodeType 规范端口 + 两套流水线模板）
// 2. img2img 语义：上游传入图片路径时 prompt + image 一起传给 ImageGenerating
// 3. 执行链键名一致：上游 LLM/文本节点输出（text 键 / prompt 端口）真实流入 prompt 输入端口
// 4. 无 key 降级任务单（job_ticket）语义不变 + 协议扩展向后兼容（只实现 3 参版的存量 invoker）

@Suite("U2 生图节点端口与执行链")
struct U2ImageNodeTests {

    // MARK: 测试桩

    /// 记录最后一次调用参数的生图 stub（验证 prompt/image 真实到达 invoker）
    private final class CapturingImageInvoker: ImageGenerating, @unchecked Sendable {
        struct Call: Equatable {
            let prompt: String
            let image: String?
        }

        private let lock = NSLock()
        private var stored: Call?

        func generate(
            node: CanvasNode, prompt: String, backend: NodeBackendConfig?
        ) async throws -> ImageGenerationOutcome {
            .image(path: "/tmp/u2_txt2img.png")
        }

        func generate(
            node: CanvasNode, prompt: String, image: String?, backend: NodeBackendConfig?
        ) async throws -> ImageGenerationOutcome {
            record(Call(prompt: prompt, image: image))
            return .image(path: image == nil ? "/tmp/u2_txt2img.png" : "/tmp/u2_img2img.png")
        }

        private func record(_ call: Call) {
            lock.lock(); defer { lock.unlock() }
            stored = call
        }

        func lastCall() -> Call? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    /// 只实现 3 参文生图签名的存量 invoker（U2 向后兼容：协议扩展不得破坏既有实现）
    private struct LegacyImageInvoker: ImageGenerating {
        func generate(
            node: CanvasNode, prompt: String, backend: NodeBackendConfig?
        ) async throws -> ImageGenerationOutcome {
            .image(path: "/tmp/u2_legacy.png")
        }
    }

    /// 无 key 降级 invoker：永远返回任务单（验证 job_ticket 语义）
    private struct NoKeyImageInvoker: ImageGenerating {
        func generate(
            node: CanvasNode, prompt: String, backend: NodeBackendConfig?
        ) async throws -> ImageGenerationOutcome {
            .jobTicket(prompt: prompt, markdown: "# 生成任务单 · 图片\n\n## 完整提示词")
        }
    }

    /// echo LLM stub：把拼好的 prompt 原样返回（验证 LLM 输出流入下游 prompt 端口）
    private struct EchoLLMInvoker: LLMInvoker {
        func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String {
            prompt
        }
    }

    private func makeContext(
        image invoker: any ImageGenerating,
        llm: (any LLMInvoker)? = nil,
        video: (any VideoGenerating)? = nil
    ) -> GraphExecutionContext {
        GraphExecutionContext(
            executors: NodeExecutors(llmInvoker: llm),
            imageInvoker: invoker,
            videoInvoker: video
        )
    }

    // MARK: - 1) imageGen 规范端口：含 image 输入端口

    @Test func canonicalGenerationPortsIncludeImageInput() {
        #expect(ManjuNodeType.imageGenInputPorts == ["prompt", "image"],
                "imageGen 应有 prompt + image 两个输入端口（image = 图生图参考图）")
        #expect(ManjuNodeType.imageGenOutputPorts == ["image"])
        #expect(ManjuNodeType.videoGenInputPorts == ["prompt", "image", "duration", "video"],
                "videoGen 应有 prompt + image + duration + video 四个输入端口（video = B2 V2V 参考视频基础端口）")
        #expect(ManjuNodeType.videoGenOutputPorts == ["video"])
        #expect(ManjuNodeType.imageGen.generationInputPortNames == ["prompt", "image"])
        #expect(ManjuNodeType.qcCheck.generationInputPortNames.isEmpty,
                "非生成类节点无生成端口定义")
    }

    @Test func pipelineTemplatesGiveImageGenImageInputPort() throws {
        for graph in [
            ManjuPipelineTemplate.makeManjuPipeline(assets: .demo),
            ManjuPipeline.standardPipeline(),
        ] {
            let imageGen = try #require(
                graph.nodes.first { $0.type == ManjuNodeType.imageGen.rawValue },
                "流水线应含 imageGen 节点"
            )
            #expect(imageGen.inputs.map(\.name).contains("prompt"), "imageGen 应有 prompt 输入端口")
            #expect(imageGen.inputs.map(\.name).contains("image"),
                    "imageGen 应有 image 输入端口（图生图入口）")
            #expect(imageGen.outputs.map(\.name) == ["image"])
        }
    }

    // MARK: - 2) img2img：上游传入图片路径 → prompt + image 一起传给 invoker

    @Test func imageInputTriggersImg2ImgSemantics() async throws {
        let invoker = CapturingImageInvoker()
        let context = makeContext(image: invoker)
        let node = CanvasNode(
            type: ManjuNodeType.imageGen.rawValue, title: "生图",
            inputs: ManjuNodeType.imageGenInputPorts.map { Port(name: $0, direction: .input, dataType: "string") },
            outputs: ManjuNodeType.imageGenOutputPorts.map { Port(name: $0, direction: .output, dataType: "image") }
        )

        let output = try await context.executeAsync(
            node: node,
            inputs: ["prompt": AnyHashable("青崖观夜景，伪仙写实"),
                     "image": AnyHashable("/tmp/ref_first_frame.png")]
        )

        #expect(invoker.lastCall() == .init(prompt: "青崖观夜景，伪仙写实", image: "/tmp/ref_first_frame.png"),
                "prompt 与 image 参考图必须一起传给 ImageGenerating（img2img）")
        #expect(output["status"] as? String == "succeeded")
        #expect(output["mode"] as? String == "img2img", "有参考图时输出应标记 img2img 模式")
        #expect(output["image"] as? String == "/tmp/u2_img2img.png")
    }

    @Test func noImageInputStaysTxt2Img() async throws {
        let invoker = CapturingImageInvoker()
        let context = makeContext(image: invoker)
        let node = CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "生图")

        let output = try await context.executeAsync(
            node: node, inputs: ["prompt": AnyHashable("文生图提示词")]
        )

        #expect(invoker.lastCall()?.image == nil, "无 image 输入时参考图必须为 nil（纯文生图）")
        #expect(output["mode"] as? String == "txt2img")
        #expect(output["status"] as? String == "succeeded")
    }

    @Test func emptyImageInputTreatedAsAbsent() async throws {
        let invoker = CapturingImageInvoker()
        let context = makeContext(image: invoker)
        let node = CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "生图")

        _ = try await context.executeAsync(
            node: node,
            inputs: ["prompt": AnyHashable("提示词"), "image": AnyHashable("   ")]
        )
        #expect(invoker.lastCall()?.image == nil, "空白字符串 image 输入视为未传入")
    }

    // MARK: - 3) 执行链键名一致：上游输出流入 prompt 端口

    @Test func upstreamTextKeyFlowsIntoPromptInput() async throws {
        // LLMNodeExecutor 实际写出的键是 text（上游输出端口名为 prompt 的旧图数据同样兼容）
        let invoker = CapturingImageInvoker()
        let context = makeContext(image: invoker)
        let node = CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "生图")

        _ = try await context.executeAsync(node: node, inputs: ["text": AnyHashable("来自 LLM 的提示词")])
        #expect(invoker.lastCall()?.prompt == "来自 LLM 的提示词",
                "上游 text 键输出应作为 prompt 进入生图（键名兼容）")
    }

    @Test func resolveInputsMapsPromptPortFromTextOutput() throws {
        // ManjuPipelineTemplate 的 imagePrompt 输出端口名是 prompt，但 LLMNodeExecutor
        // 写出的输出键是 text —— 修复前按端口名严格取值 → imageGen 的 prompt 恒为空
        let context = makeContext(image: CapturingImageInvoker())
        var graph = NodeGraph()
        let promptNode = CanvasNode(
            type: ManjuNodeType.imagePrompt.rawValue, title: "图片提示词",
            outputs: [Port(name: "prompt", direction: .output, dataType: "string")]
        )
        let imageGen = CanvasNode(
            type: ManjuNodeType.imageGen.rawValue, title: "生图",
            inputs: ManjuNodeType.imageGenInputPorts.map { Port(name: $0, direction: .input, dataType: "string") }
        )
        graph.addNode(promptNode)
        graph.addNode(imageGen)
        graph.addEdge(Edge(
            fromNode: promptNode.id,
            fromPort: promptNode.outputs.first(where: { $0.name == "prompt" })!.id,
            toNode: imageGen.id,
            toPort: imageGen.inputs.first(where: { $0.name == "prompt" })!.id
        ))

        let inputs = try context.resolveInputs(for: imageGen, in: graph) { nodeID in
            nodeID == promptNode.id
                ? ["text": AnyHashable("8 槽提示词全文"), "status": AnyHashable("succeeded")]
                : nil
        }
        #expect(inputs?["prompt"] as? String == "8 槽提示词全文",
                "上游 prompt 端口（实际输出键 text）必须流入 imageGen 的 prompt 输入")
    }

    @Test func resolveInputsKeepsNonTextPortsStrict() throws {
        // 非文本端口（image）严格按端口名取值，不做 text/prompt 别名回退——
        // 上游只产出 text 键时，名为 image 的输出端口取不到值（不得跨端口语义污染）
        let context = makeContext(image: CapturingImageInvoker())
        var graph = NodeGraph()
        let upstream = CanvasNode(
            type: ManjuNodeType.imageGen.rawValue, title: "上游生图",
            outputs: [Port(name: "image", direction: .output, dataType: "image")]
        )
        let videoGen = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue, title: "生视频",
            inputs: ManjuNodeType.videoGenInputPorts.map { Port(name: $0, direction: .input, dataType: "string") }
        )
        graph.addNode(upstream)
        graph.addNode(videoGen)
        graph.addEdge(Edge(
            fromNode: upstream.id,
            fromPort: upstream.outputs[0].id,
            toNode: videoGen.id,
            toPort: videoGen.inputs.first(where: { $0.name == "image" })!.id
        ))

        // 上游执行器只写出了 text 键（异常上游），image 端口严格取值 → 取空
        let inputs = try context.resolveInputs(for: videoGen, in: graph) { nodeID in
            nodeID == upstream.id ? ["text": AnyHashable("一段文字")] : nil
        }
        #expect(inputs?["image"] == nil, "image 端口不做 text 别名回退（文本不得污染首帧输入）")
    }

    @Test func endToEndLLMNodeFeedsImageGenPrompt() throws {
        // text 节点 → llm 节点 → imageGen：DAGScheduler 全链路调度，
        // 上游输出经 resolveInputs（text/prompt 别名）真实到达生图 invoker
        let invoker = CapturingImageInvoker()
        let context = makeContext(image: invoker, llm: EchoLLMInvoker())

        let textNode = CanvasNode(
            type: "text", title: "小说片段",
            outputs: [Port(name: "text", direction: .output, dataType: "string")],
            backendConfig: NodeBackendConfig(params: ["content": "魏衔拔剑的瞬间"])
        )
        let llmNode = CanvasNode(
            type: "llm", title: "LLM",
            inputs: [Port(name: "prompt", direction: .input, dataType: "string")],
            outputs: [Port(name: "text", direction: .output, dataType: "string")],
            backendConfig: NodeBackendConfig(providerType: .cloud, providerID: "bailian", modelID: "m")
        )
        let imageGen = CanvasNode(
            type: ManjuNodeType.imageGen.rawValue, title: "生图",
            inputs: ManjuNodeType.imageGenInputPorts.map { Port(name: $0, direction: .input, dataType: "string") },
            outputs: ManjuNodeType.imageGenOutputPorts.map { Port(name: $0, direction: .output, dataType: "image") }
        )

        var graph = NodeGraph()
        for node in [textNode, llmNode, imageGen] { graph.addNode(node) }
        graph.addEdge(Edge(
            fromNode: textNode.id, fromPort: textNode.outputs[0].id,
            toNode: llmNode.id, toPort: llmNode.inputs[0].id
        ))
        graph.addEdge(Edge(
            fromNode: llmNode.id, fromPort: llmNode.outputs[0].id,
            toNode: imageGen.id,
            toPort: imageGen.inputs.first(where: { $0.name == "prompt" })!.id
        ))

        var scheduler = DAGScheduler()
        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: textNode.id) == .succeeded)
        #expect(result.status(of: llmNode.id) == .succeeded)
        #expect(result.status(of: imageGen.id) == .succeeded,
                "imageGen 应执行成功而非被跳过（上游链路完整）")
        let received = try #require(invoker.lastCall(), "生图 invoker 必须被调用")
        #expect(received.prompt.contains("魏衔拔剑的瞬间"),
                "上游 LLM 节点输出（含源文本）应流入 imageGen 的 prompt 端口")
        #expect(result.output(of: imageGen.id)?["status"] as? String == "succeeded")
    }

    // MARK: - 4) 无 key 降级任务单语义不变 + 协议向后兼容

    @Test func jobTicketDegradationUnchangedWithoutKey() async throws {
        let context = makeContext(image: NoKeyImageInvoker())
        let node = CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "生图")

        let output = try await context.executeAsync(
            node: node, inputs: ["prompt": AnyHashable("赛博街道夜景")]
        )

        #expect(output["status"] as? String == "job_ticket", "无 key 必须降级任务单而非抛错")
        #expect(output["provider"] as? String == "gimage2")
        let ticket = output["jobTicket"] as? String ?? ""
        #expect(ticket.contains("生成任务单"), "任务单 markdown 应含标题标记（QC 据此识别）")
        #expect(output["prompt"] as? String == "赛博街道夜景", "prompt 端口保留提示词全文")
        #expect((output["image"] as? String) == output["prompt"] as? String,
                "image 端口承载任务单全文供下游/QC 读取")
        #expect(context.lastErrors.isEmpty, "降级是成功执行，不记录错误")
    }

    @Test func jobTicketDegradationUnchangedWithImageInput() async throws {
        // img2img 输入同样不改变任务单语义（有图无 key 仍降级，不阻塞画布）
        let context = makeContext(image: NoKeyImageInvoker())
        let node = CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "生图")

        let output = try await context.executeAsync(
            node: node,
            inputs: ["prompt": AnyHashable("基于首帧的风格迁移"),
                     "image": AnyHashable("/tmp/ref.png")]
        )
        #expect(output["status"] as? String == "job_ticket")
        #expect(output["jobTicket"] != nil)
    }

    @Test func legacyThreeArgInvokerStillWorks() async throws {
        // 只实现 3 参签名的存量 invoker：协议扩展（默认实现桥接）后仍可注入并正常执行
        let context = makeContext(image: LegacyImageInvoker())
        let node = CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "生图")

        let output = try await context.executeAsync(
            node: node,
            inputs: ["prompt": AnyHashable("文生图"), "image": AnyHashable("/tmp/ref.png")]
        )
        #expect(output["status"] as? String == "succeeded")
        #expect(output["image"] as? String == "/tmp/u2_legacy.png")
    }

    // MARK: - 生视频侧：prompt 键名兼容同样生效（任务单语义不变）

    @Test func videoGenPromptKeyFallbackAndTicketUnchanged() async throws {
        let context = makeContext(image: CapturingImageInvoker()) // videoInvoker = nil
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频生成")

        let output = try await context.executeAsync(node: node, inputs: ["text": AnyHashable("[MODE]\nI2V")])
        #expect(output["status"] as? String == "job_ticket", "无 videoInvoker 仍降级 9 槽任务单")
        #expect((output["prompt"] as? String)?.contains("[MODE]") == true,
                "text 键输入应作为 prompt 进入任务单（键名兼容）")
    }
}
