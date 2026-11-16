import Testing
import Foundation
@testable import CanvasCore

// MARK: - B1 reviewGate 审核闸口调度拦截测试

/// B1：DAGScheduler 层 reviewGate 未过审拦截（复用 F2-② gateFailureReason 闸口机制）。
/// - 执行输出 status == REJECT / PENDING（ReviewGateExecutor 产出）→ 审核节点 failed +
///   全部下游 skipped 且**不执行执行器**，skipReason 注明审核状态
/// - PASS → 正常放行，下游照常执行
/// - 手动 review.status（backendConfig.params["review.status"]）非 nil 时优先于执行输出，
///   双向覆盖：执行 PASS + 手动 REJECT → 拦截；执行 REJECT + 手动 PASS → 放行
/// - 仅 reviewGate 类型节点参与判定：非 reviewGate 节点输出 status=REJECT/PENDING（回归）
///   或携带手动 review.status 均不触发拦截
/// - 手动 REJECT 优先级：即使缓存命中历史 PASS 输出也拦截下游（防御路径）

// MARK: - 测试替身

/// 按节点注入固定输出的上下文（模拟 reviewGate 执行输出与普通节点输出）
private final class ReviewGateFixedContext: NodeExecutionContext {
    var executed: [UUID] = []
    var outputsByNode: [UUID: [String: AnyHashable]] = [:]

    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (UUID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]? { nil }

    func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
        executed.append(node.id)
        return outputsByNode[node.id] ?? ["text": "ok", "status": "succeeded"]
    }
}

private func rgNode(
    _ title: String,
    type: String = "llm",
    config: NodeBackendConfig? = nil
) -> CanvasNode {
    CanvasNode(type: type, title: title, backendConfig: config)
}

/// reviewGate 节点（端口与 ManjuNodeType.reviewGateInputPorts/OutputPorts 一致）；
/// `manualStatus` 非 nil 时写入 backendConfig.params["review.status"]
private func rgReviewGateNode(
    _ title: String = "审核",
    manualStatus: String? = nil
) -> CanvasNode {
    let config: NodeBackendConfig? = manualStatus.map {
        NodeBackendConfig(params: ["review.status": $0])
    }
    return CanvasNode(
        type: ManjuNodeType.reviewGate.rawValue,
        title: title,
        inputs: [Port(name: "text", direction: .input, dataType: "string")],
        outputs: [
            Port(name: "pass", direction: .output, dataType: "string"),
            Port(name: "status", direction: .output, dataType: "string"),
        ],
        backendConfig: config
    )
}

private func rgEdge(_ from: CanvasNode, _ to: CanvasNode) -> Edge {
    let pOut = Port(name: "out", direction: .output, dataType: "text")
    let pIn = Port(name: "in", direction: .input, dataType: "text")
    return Edge(fromNode: from.id, fromPort: pOut.id, toNode: to.id, toPort: pIn.id)
}

private func rgGraph(nodes: [CanvasNode], edges: [Edge] = []) -> NodeGraph {
    var g = NodeGraph()
    nodes.forEach { g.addNode($0) }
    edges.forEach { g.addEdge($0) }
    return g
}

/// reviewGate 执行输出（与 ReviewGateExecutor 产出同构）
private func reviewOutput(
    status: String,
    pass: String? = nil,
    reasons: String? = nil
) -> [String: AnyHashable] {
    var out: [String: AnyHashable] = ["status": status]
    if let pass { out["pass"] = pass }
    if let reasons { out["reasons"] = reasons }
    return out
}

// MARK: - 测试

struct B1ReviewGateBlockingTests {

    // MARK: REJECT：执行输出拦截

    @Test func rejectExecutionBlocksAllDownstream() throws {
        let gate = rgReviewGateNode("审核")
        let b = rgNode("下游A", type: "imageGen")
        let c = rgNode("下游B", type: "qcCheck")
        let graph = rgGraph(nodes: [gate, b, c], edges: [rgEdge(gate, b), rgEdge(b, c)])
        var scheduler = DAGScheduler()
        let context = ReviewGateFixedContext()
        context.outputsByNode[gate.id] = reviewOutput(
            status: "REJECT",
            pass: "【BLOCKED】提示词结构闸口未通过",
            reasons: "文本含 BLOCKED 标记（上游结构闸口未通过，需修复后重新执行）"
        )

        let result = try scheduler.run(graph: graph, context: context)

        // 审核节点本身 failed（打回红；输出保留供上层写回/回执）
        #expect(result.status(of: gate.id) == .failed, "REJECT 审核节点应标记 failed")
        #expect(result.output(of: gate.id)?["status"] as? String == "REJECT", "REJECT 输出必须保留在结果中")
        // 全部（传递）下游 skipped，且执行器从未被调用
        #expect(result.status(of: b.id) == .skipped, "REJECT 直接下游必须跳过")
        #expect(result.status(of: c.id) == .skipped, "REJECT 传递下游必须跳过")
        #expect(context.executed == [gate.id], "被拦截的下游不得执行执行器")
        // 原因可读：含根因节点名 + 审核状态
        let reasonB = try #require(result.skipReason(of: b.id), "被跳过节点必须有原因")
        #expect(reasonB.contains("审核"), "原因应含根因节点名")
        #expect(reasonB.contains("REJECT"), "原因应注明审核状态 REJECT")
        let reasonC = try #require(result.skipReason(of: c.id), "传递下游也必须有原因")
        #expect(reasonC.contains("审核"), "传递下游原因应追溯到根因节点")
    }

    // MARK: PENDING：执行输出拦截

    @Test func pendingExecutionBlocksDownstream() throws {
        let gate = rgReviewGateNode("审核")
        let b = rgNode("下游", type: "imageGen")
        let graph = rgGraph(nodes: [gate, b], edges: [rgEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateFixedContext()
        context.outputsByNode[gate.id] = reviewOutput(status: "PENDING")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: gate.id) == .failed, "PENDING（待审）审核节点应标记 failed")
        #expect(result.status(of: b.id) == .skipped, "PENDING 下游必须跳过")
        #expect(context.executed == [gate.id], "PENDING 下游不得执行执行器")
        let reason = try #require(result.skipReason(of: b.id))
        #expect(reason.contains("PENDING"), "原因应注明审核状态 PENDING")
    }

    // MARK: PASS：正常放行

    @Test func passAllowsDownstreamExecution() throws {
        let gate = rgReviewGateNode("审核")
        let b = rgNode("下游", type: "imageGen")
        let graph = rgGraph(nodes: [gate, b], edges: [rgEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateFixedContext()
        context.outputsByNode[gate.id] = reviewOutput(status: "PASS", pass: "完整提示词")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: gate.id) == .succeeded, "PASS 审核节点正常成功")
        #expect(result.status(of: b.id) == .succeeded, "PASS 下游正常执行")
        #expect(context.executed == [gate.id, b.id])
        #expect(result.skipReason(of: b.id) == nil)
    }

    // MARK: 手动 review.status 优先于执行输出

    @Test func manualRejectOverridesPassExecution() throws {
        // 执行输出 PASS（放行），但手动 review.status=REJECT → 拦截
        let gate = rgReviewGateNode("审核", manualStatus: "REJECT")
        let b = rgNode("下游", type: "imageGen")
        let graph = rgGraph(nodes: [gate, b], edges: [rgEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateFixedContext()
        context.outputsByNode[gate.id] = reviewOutput(status: "PASS", pass: "完整提示词")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: gate.id) == .failed, "手动 REJECT 应覆盖执行输出 PASS")
        #expect(result.status(of: b.id) == .skipped, "手动 REJECT 下游必须跳过")
        #expect(context.executed == [gate.id], "手动 REJECT 下游不得执行执行器")
        let reason = try #require(result.skipReason(of: b.id))
        #expect(reason.contains("REJECT"))
    }

    @Test func manualRejectOverridesCachedPassOutput() throws {
        // 防御路径：缓存中已有历史 PASS 输出，手动 REJECT 命中缓存时仍拦截下游
        let gate = rgReviewGateNode("审核", manualStatus: "REJECT")
        let b = rgNode("下游", type: "imageGen")
        let graph = rgGraph(nodes: [gate, b], edges: [rgEdge(gate, b)])
        let key = DAGScheduler.cacheKey(node: gate, inputs: nil)
        var scheduler = DAGScheduler(cache: [key: reviewOutput(status: "PASS", pass: "历史放行输出")])
        let context = ReviewGateFixedContext()

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: gate.id) == .failed, "手动 REJECT 缓存命中也不放行")
        #expect(result.status(of: b.id) == .skipped)
        #expect(context.executed == [], "缓存命中 + 手动拦截：执行器不运行")
    }

    @Test func manualPassOverridesRejectExecution() throws {
        // 反向覆盖（契约对称）：执行输出 REJECT，但手动 review.status=PASS → 放行
        let gate = rgReviewGateNode("审核", manualStatus: "PASS")
        let b = rgNode("下游", type: "imageGen")
        let graph = rgGraph(nodes: [gate, b], edges: [rgEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateFixedContext()
        context.outputsByNode[gate.id] = reviewOutput(status: "REJECT", pass: "x", reasons: "r")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: gate.id) == .succeeded, "手动 PASS 应覆盖执行输出 REJECT")
        #expect(result.status(of: b.id) == .succeeded, "手动 PASS 下游正常执行")
        #expect(context.executed == [gate.id, b.id])
        #expect(result.skipReason(of: b.id) == nil)
    }

    // MARK: 回归：非 reviewGate 节点不触发审核拦截

    @Test func nonReviewGateNodeOutputStatusDoesNotBlock() throws {
        // 普通节点输出 status=PENDING（非审核闸口）→ 不得拦截（行为不变）
        let a = rgNode("普通节点", type: "llm")
        let b = rgNode("下游", type: "imageGen")
        let graph = rgGraph(nodes: [a, b], edges: [rgEdge(a, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateFixedContext()
        context.outputsByNode[a.id] = reviewOutput(status: "PENDING")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: a.id) == .succeeded, "非 reviewGate 节点的 PENDING 输出不触发拦截")
        #expect(result.status(of: b.id) == .succeeded, "下游照常执行")
        #expect(context.executed == [a.id, b.id])
    }

    @Test func manualReviewStatusOnNonReviewGateNodeIgnored() throws {
        // 手动 review.status 只对 reviewGate 节点生效；普通节点携带该参数不拦截
        let a = rgNode("普通节点", type: "llm", config: NodeBackendConfig(params: ["review.status": "REJECT"]))
        let b = rgNode("下游", type: "imageGen")
        let graph = rgGraph(nodes: [a, b], edges: [rgEdge(a, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateFixedContext()

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: a.id) == .succeeded, "普通节点上的手动 review.status 不生效")
        #expect(result.status(of: b.id) == .succeeded)
        #expect(context.executed == [a.id, b.id])
    }
}
