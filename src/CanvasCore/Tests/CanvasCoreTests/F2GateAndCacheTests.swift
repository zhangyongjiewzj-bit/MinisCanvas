import Testing
import Foundation
@testable import CanvasCore

// MARK: - F2 画布执行正确性：①缓存 key 含模型配置 ②BLOCKED/QC FAIL 闸口阻断下游

// MARK: - 测试辅助

/// 输出随节点 backendConfig.modelID 变化的上下文（验证切换模型后不复用旧缓存）
private final class ModelAwareContext: NodeExecutionContext {
    var executed: [UUID] = []

    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (UUID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]? { nil }

    func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
        executed.append(node.id)
        let model = node.backendConfig?.modelID ?? "default"
        return ["text": "output_from_\(model)"]
    }
}

/// 按节点注入固定输出的上下文（模拟闸口信号输出：blocked=1 / qc_status=FAIL）
private final class FixedOutputContext: NodeExecutionContext {
    var executed: [UUID] = []
    var outputsByNode: [UUID: [String: AnyHashable]] = [:]
    var failNodeIDs: Set<UUID> = []

    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (UUID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]? { nil }

    func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
        executed.append(node.id)
        if failNodeIDs.contains(node.id) {
            throw NodeExecutorsError.llmInvocationFailed("mock 执行失败")
        }
        return outputsByNode[node.id] ?? ["text": "ok", "status": "succeeded"]
    }
}

private func f2Node(_ title: String, type: String = "llm", config: NodeBackendConfig? = nil) -> CanvasNode {
    CanvasNode(type: type, title: title, backendConfig: config)
}

private func f2Edge(_ from: CanvasNode, _ to: CanvasNode) -> Edge {
    let pOut = Port(name: "out", direction: .output, dataType: "text")
    let pIn = Port(name: "in", direction: .input, dataType: "text")
    return Edge(fromNode: from.id, fromPort: pOut.id, toNode: to.id, toPort: pIn.id)
}

private func f2Graph(nodes: [CanvasNode], edges: [Edge] = []) -> NodeGraph {
    var g = NodeGraph()
    nodes.forEach { g.addNode($0) }
    edges.forEach { g.addEdge($0) }
    return g
}

/// BLOCKED 提示词节点输出（与 LLMNodeExecutor.blockedOutput 同构：blocked=1 + missing_slots）
private func blockedPromptOutput(missing: String) -> [String: AnyHashable] {
    [
        "text": "【BLOCKED】提示词结构闸口未通过（铁律7：缺字段 = BLOCKED，不输出最终提示词）",
        "status": "blocked",
        "blocked": "1",
        "missing_slots": missing,
    ]
}

/// QC FAIL 输出（与 QCNodeExecutor 失败路径同构：qc_status=FAIL + missing_slots/reasons）
private func qcFailOutput(missing: String) -> [String: AnyHashable] {
    [
        "report": "# QC 检查报告\n状态: FAIL",
        "status": "FAIL",
        "qc_status": "FAIL",
        "missing_slots": missing,
        "reasons": "缺字段 = BLOCKED：\(missing)（铁律7，不输出最终提示词）",
    ]
}

// MARK: - F2-① 缓存 key 纳入模型配置

struct F2CacheKeyModelConfigTests {

    // MARK: cacheKey 单元断言

    @Test func cacheKeyDiffersAcrossModelIDProviderIDAndParams() {
        let base = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview",
            params: ["temperature": "0.7"]
        )
        let node = f2Node("A", config: base)
        let inputs: [String: AnyHashable] = ["text": "同样的输入"]

        let keyBase = DAGScheduler.cacheKey(node: node, inputs: inputs)

        // 只改 modelID → key 必须不同（切换模型不得命中旧模型缓存）
        var switchedModel = node
        switchedModel.backendConfig?.modelID = "gpt-5.5"
        #expect(DAGScheduler.cacheKey(node: switchedModel, inputs: inputs) != keyBase,
                "同节点同输入不同 modelID 必须产生不同缓存键")

        // 只改 providerID → key 必须不同（切换 Provider 不得命中旧 Provider 缓存）
        var switchedProvider = node
        switchedProvider.backendConfig?.providerID = "openai"
        #expect(DAGScheduler.cacheKey(node: switchedProvider, inputs: inputs) != keyBase,
                "同节点同输入不同 providerID 必须产生不同缓存键")

        // 只改 providerType（本地/云端）→ key 必须不同
        var switchedType = node
        switchedType.backendConfig?.providerType = .local
        #expect(DAGScheduler.cacheKey(node: switchedType, inputs: inputs) != keyBase,
                "同节点同输入不同 providerType 必须产生不同缓存键")

        // 只改 params（temperature）→ key 必须不同（采样参数变化结果不同）
        var switchedParams = node
        switchedParams.backendConfig?.params["temperature"] = "1.2"
        #expect(DAGScheduler.cacheKey(node: switchedParams, inputs: inputs) != keyBase,
                "同节点同输入不同 params 必须产生不同缓存键")
    }

    @Test func cacheKeyStableForSameConfigAndDiffersForNilConfig() {
        // 同配置（含相同 params，字典序无关——backendConfigKey 内部按键排序）→ key 相同
        let config1 = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview",
            params: ["temperature": "0.7", "maxTokens": "2048"]
        )
        let config2 = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview",
            params: ["maxTokens": "2048", "temperature": "0.7"]  // 插入顺序不同，key 仍须稳定
        )
        let a = CanvasNode(id: UUID(), type: "llm", title: "A", backendConfig: config1)
        let b = CanvasNode(id: a.id, type: "llm", title: "A", backendConfig: config2)
        #expect(DAGScheduler.cacheKey(node: a, inputs: nil) == DAGScheduler.cacheKey(node: b, inputs: nil),
                "同节点同配置（params 无序差异不计）缓存键必须稳定，否则同配置重跑无法命中")

        // nil 配置（全局默认）vs 显式配置 → key 必须不同
        let unconfigured = CanvasNode(id: a.id, type: "llm", title: "A", backendConfig: nil)
        #expect(DAGScheduler.cacheKey(node: unconfigured, inputs: nil) != DAGScheduler.cacheKey(node: a, inputs: nil),
                "未配置（全局默认）与显式配置必须区分，切换前后不得串缓存")
    }

    // MARK: 调度端到端：切换模型不命中缓存，同配置命中

    @Test func switchingModelMissesCacheSameConfigHits() throws {
        let configV1 = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview"
        )
        var node = f2Node("A", config: configV1)
        let graph = f2Graph(nodes: [node])
        var scheduler = DAGScheduler()
        let context = ModelAwareContext()

        // 首次执行：真实运行，输出来自 qwen3.8-max-preview
        let first = try scheduler.run(graph: graph, context: context)
        #expect(context.executed == [node.id])
        #expect(first.status(of: node.id) == .succeeded)
        #expect(first.output(of: node.id)?["text"] as? String == "output_from_qwen3.8-max-preview")

        // 同配置重跑：命中缓存，不重跑
        let second = try scheduler.run(graph: graph, context: context)
        #expect(context.executed == [node.id], "同配置重跑应命中缓存，不再执行执行器")
        #expect(second.status(of: node.id) == .cached)

        // 切换模型后重跑：不得命中旧模型缓存 → 重新执行，输出来自新模型
        node.backendConfig?.modelID = "gpt-5.5"
        let switchedGraph = f2Graph(nodes: [node])
        let third = try scheduler.run(graph: switchedGraph, context: context)
        #expect(context.executed == [node.id, node.id], "切换 modelID 后必须重新执行（不复用旧模型结果）")
        #expect(third.status(of: node.id) == .succeeded)
        #expect(third.output(of: node.id)?["text"] as? String == "output_from_gpt-5.5",
                "重跑输出应来自新模型")

        // 新模型配置重跑：命中新缓存
        let fourth = try scheduler.run(graph: switchedGraph, context: context)
        #expect(context.executed.count == 2, "新模型配置第二次运行应命中缓存")
        #expect(fourth.status(of: node.id) == .cached)
        #expect(scheduler.cacheCount == 2, "两个模型配置各一条缓存，互不覆盖")
    }
}

// MARK: - F2-② BLOCKED / QC FAIL 闸口阻断下游

struct F2GateBlockingTests {

    @Test func blockedUpstreamStopsDownstreamWithReadableReason() throws {
        let a = f2Node("图片提示词", type: "imagePrompt")
        let b = f2Node("生图", type: "imageGen")
        let c = f2Node("QC检查", type: "qcCheck")
        let graph = f2Graph(nodes: [a, b, c], edges: [f2Edge(a, b), f2Edge(b, c)])
        var scheduler = DAGScheduler()
        let context = FixedOutputContext()
        context.outputsByNode[a.id] = blockedPromptOutput(missing: "FORBID、LIGHT")

        let result = try scheduler.run(graph: graph, context: context)

        // 闸口节点本身 failed（输出保留供上层写回内容/生成回执）
        #expect(result.status(of: a.id) == .failed, "BLOCKED 闸口节点应标记 failed（红色）")
        #expect(result.output(of: a.id)?["blocked"] as? String == "1", "BLOCKED 输出必须保留在结果中")
        // 下游全部 skipped，且执行器从未被调用
        #expect(result.status(of: b.id) == .skipped, "BLOCKED 上游的直接下游必须跳过")
        #expect(result.status(of: c.id) == .skipped, "BLOCKED 上游的传递下游必须跳过")
        #expect(context.executed == [a.id], "被闸口阻断的下游不得执行执行器")
        // 原因可读：含根因节点名 + 闸口类型 + 缺哪些槽
        let reasonB = try #require(result.skipReason(of: b.id), "被跳过节点必须有原因")
        #expect(reasonB.contains("图片提示词"), "原因应含根因节点名")
        #expect(reasonB.contains("BLOCKED"), "原因应标明 BLOCKED 闸口")
        #expect(reasonB.contains("FORBID"), "原因应含缺的槽位")
        let reasonC = try #require(result.skipReason(of: c.id), "传递下游也必须有原因")
        #expect(reasonC.contains("图片提示词"), "传递下游原因应追溯到根因节点")
    }

    @Test func qcFailUpstreamStopsDownstreamWithReadableReason() throws {
        let a = f2Node("QC检查", type: "qcCheck")
        let b = f2Node("生视频", type: "videoGen")
        let graph = f2Graph(nodes: [a, b], edges: [f2Edge(a, b)])
        var scheduler = DAGScheduler()
        let context = FixedOutputContext()
        context.outputsByNode[a.id] = qcFailOutput(missing: "MODE")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: a.id) == .failed, "QC FAIL 节点应标记 failed")
        #expect(result.output(of: a.id)?["qc_status"] as? String == "FAIL", "QC FAIL 输出必须保留（报告写回/回执）")
        #expect(result.status(of: b.id) == .skipped, "QC FAIL 上游的下游必须跳过")
        #expect(context.executed == [a.id], "被 QC 闸口阻断的下游不得执行执行器")
        let reason = try #require(result.skipReason(of: b.id))
        #expect(reason.contains("QC FAIL"), "原因应标明 QC FAIL")
        #expect(reason.contains("QC检查"), "原因应含根因节点名")
        #expect(reason.contains("MODE"), "原因应含缺字段")
    }

    @Test func qcJobTicketDegradeDoesNotBlock() throws {
        // 任务单降级（待生成后复检）不是 FAIL：不阻断下游（与降级任务单同一哲学）
        let a = f2Node("QC检查", type: "qcCheck")
        let b = f2Node("汇总", type: "llm")
        let graph = f2Graph(nodes: [a, b], edges: [f2Edge(a, b)])
        var scheduler = DAGScheduler()
        let context = FixedOutputContext()
        context.outputsByNode[a.id] = [
            "report": "输入为生成任务单（无 API key 降级模式）：不校验成片，待真实生成后复检。",
            "status": "待生成后复检",
            "qc_status": "待生成后复检",
            "job_ticket": "1",
        ]

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: a.id) == .succeeded, "任务单降级是成功执行，不得判为闸口失败")
        #expect(result.status(of: b.id) == .succeeded, "任务单降级不得阻断下游")
        #expect(context.executed == [a.id, b.id])
        #expect(result.skipReason(of: b.id) == nil)
    }

    @Test func gateFailureOutputIsNotCached() throws {
        // BLOCKED 输出不写缓存：修复后补齐槽位重跑时不得命中旧的 BLOCKED 结果
        let a = f2Node("图片提示词", type: "imagePrompt")
        let graph = f2Graph(nodes: [a])
        var scheduler = DAGScheduler()
        let context = FixedOutputContext()
        context.outputsByNode[a.id] = blockedPromptOutput(missing: "FORBID")

        let first = try scheduler.run(graph: graph, context: context)
        #expect(first.status(of: a.id) == .failed)
        #expect(scheduler.cacheCount == 0, "闸口失败输出不得写入缓存")

        // 用户补齐槽位后重跑（执行器产出正常输出）→ 必须真实执行而非命中 BLOCKED 缓存
        context.outputsByNode[a.id] = ["text": "完整提示词", "status": "succeeded"]
        let second = try scheduler.run(graph: graph, context: context)
        #expect(context.executed.count == 2, "修复后重跑必须重新执行")
        #expect(second.status(of: a.id) == .succeeded)
        #expect(scheduler.cacheCount == 1, "正常成功输出才写缓存")
    }

    @Test func executionFailureSkipReasonIsReadable() throws {
        // 执行失败（throw）的下游跳过同样带可读原因
        let a = f2Node("脚本生成", type: "script")
        let b = f2Node("分镜生成", type: "storyboard")
        let graph = f2Graph(nodes: [a, b], edges: [f2Edge(a, b)])
        var scheduler = DAGScheduler()
        let context = FixedOutputContext()
        context.failNodeIDs = [a.id]

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: a.id) == .failed)
        #expect(result.status(of: b.id) == .skipped)
        let reason = try #require(result.skipReason(of: b.id), "执行失败导致的跳过也须有原因")
        #expect(reason.contains("脚本生成"), "原因应含失败节点名")
        #expect(reason.contains("执行失败"), "原因应标明执行失败")
    }

    @Test func gateBlockOnlyAffectsDependentBranch() throws {
        // 菱形/并行分支：闸口只阻断依赖它的分支，无关分支正常执行
        let blocked = f2Node("图片提示词", type: "imagePrompt")
        let down = f2Node("生图", type: "imageGen")
        let independent = f2Node("小说导入", type: "novelImport")
        let independentDown = f2Node("剧情拆解", type: "plotOutline")
        let graph = f2Graph(
            nodes: [blocked, down, independent, independentDown],
            edges: [f2Edge(blocked, down), f2Edge(independent, independentDown)]
        )
        var scheduler = DAGScheduler()
        let context = FixedOutputContext()
        context.outputsByNode[blocked.id] = blockedPromptOutput(missing: "LIGHT")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: blocked.id) == .failed)
        #expect(result.status(of: down.id) == .skipped)
        #expect(result.status(of: independent.id) == .succeeded, "无关分支不受闸口影响")
        #expect(result.status(of: independentDown.id) == .succeeded, "无关分支的下游正常执行")
        #expect(context.executed == [blocked.id, independent.id, independentDown.id])
    }

    @Test func cancelledRunSkipReasonsReadable() throws {
        // 中断跳过同样记录原因
        let a = f2Node("A")
        let b = f2Node("B")
        let graph = f2Graph(nodes: [a, b], edges: [f2Edge(a, b)])
        var scheduler = DAGScheduler()
        let context = FixedOutputContext()

        let result = try scheduler.run(graph: graph, context: context, isCancelled: { true })

        #expect(result.wasCancelled)
        #expect(result.status(of: a.id) == .skipped)
        #expect(result.skipReason(of: a.id)?.contains("中断") == true, "中断跳过原因应可读")
        #expect(result.skipReason(of: b.id)?.contains("中断") == true)
    }
}
