import Testing
import Foundation
@testable import CanvasCore

// MARK: - B1 边界：DAGScheduler reviewGate 审核闸口拦截边界测试
//
// 本轮补边界（现有 B1ReviewGateBlockingTests 8 用例未覆盖）：
// 1. 空图执行不崩溃
// 2. 无 reviewGate 节点图正常执行
// 3. reviewGate 输出无 status 键 / 未知 status 值（如 "succeeded"）不拦截
// 4. 状态判定大小写敏感契约：小写 "reject" 当前按未知值放行（记录行为，见 issues 报告 P3）
// 5. 多个 reviewGate 串联：上游 REJECT → 下游 gate 同样被跳过、不执行执行器
// 6. REJECT 后手动 PASS 放行再执行（同 scheduler 二次 run；闸口失败输出不写缓存）
// 7. 拦截时 gateFailureReason 透传格式（REJECT 带 reasons / REJECT 不带 / PENDING 三段精确断言）
// 8. 三级下游全部被拦，且各级跳过原因同为根因描述（原样传播）
// 9. 双分支隔离：一个 gate REJECT 只拦自己分支，另一分支正常执行
// 10. 手动 PENDING 拦截（执行输出 PASS 也被手动 PENDING 覆盖）

// MARK: - 测试替身（本文件私有，避免与既有测试文件冲突）

/// 按节点注入固定输出的上下文（模拟 reviewGate 执行输出与普通节点输出）
private final class ReviewGateBoundaryContext: NodeExecutionContext {
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

private func bNode(
    _ title: String,
    type: String = "llm",
    config: NodeBackendConfig? = nil
) -> CanvasNode {
    CanvasNode(type: type, title: title, backendConfig: config)
}

/// reviewGate 节点（端口与 ManjuNodeType.reviewGateInputPorts/OutputPorts 一致）；
/// `manualStatus` 非 nil 时写入 backendConfig.params["review.status"]
private func bReviewGateNode(
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

private func bEdge(_ from: CanvasNode, _ to: CanvasNode) -> Edge {
    let pOut = Port(name: "out", direction: .output, dataType: "text")
    let pIn = Port(name: "in", direction: .input, dataType: "text")
    return Edge(fromNode: from.id, fromPort: pOut.id, toNode: to.id, toPort: pIn.id)
}

private func bGraph(nodes: [CanvasNode], edges: [Edge] = []) -> NodeGraph {
    var g = NodeGraph()
    nodes.forEach { g.addNode($0) }
    edges.forEach { g.addEdge($0) }
    return g
}

/// reviewGate 执行输出（与 ReviewGateExecutor 产出同构）
private func bReviewOutput(
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

struct B1BoundaryEdgeTests {

    // MARK: 1) 空图

    @Test func emptyGraphRunsWithoutCrash() throws {
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()

        let result = try scheduler.run(graph: NodeGraph(), context: context)

        #expect(result.statuses.isEmpty, "空图不应产生任何节点状态")
        #expect(result.wasCancelled == false)
        #expect(context.executed.isEmpty)
    }

    // MARK: 2) 无 reviewGate 节点图

    @Test func graphWithoutReviewGateRunsNormally() throws {
        let a = bNode("A", type: "llm")
        let b = bNode("B", type: "imageGen")
        let c = bNode("C", type: "qcCheck")
        let graph = bGraph(nodes: [a, b, c], edges: [bEdge(a, b), bEdge(b, c)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()

        let result = try scheduler.run(graph: graph, context: context)

        #expect(context.executed == [a.id, b.id, c.id], "无审核闸口时全图正常执行")
        #expect(result.status(of: c.id) == .succeeded)
        #expect(result.skipReason(of: b.id) == nil)
    }

    // MARK: 3) reviewGate 输出缺 status / 未知 status 值

    @Test func reviewGateWithoutStatusKeyDoesNotBlock() throws {
        let gate = bReviewGateNode("审核")
        let b = bNode("下游", type: "imageGen")
        let graph = bGraph(nodes: [gate, b], edges: [bEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()
        context.outputsByNode[gate.id] = ["pass": "完整提示词"]   // 无 status 键

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: gate.id) == .succeeded, "无 status 键的审核节点不拦截")
        #expect(result.status(of: b.id) == .succeeded)
        #expect(context.executed == [gate.id, b.id])
    }

    @Test func reviewGateUnknownStatusValueDoesNotBlock() throws {
        let gate = bReviewGateNode("审核")
        let b = bNode("下游", type: "imageGen")
        let graph = bGraph(nodes: [gate, b], edges: [bEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()
        context.outputsByNode[gate.id] = bReviewOutput(status: "succeeded")  // LLM 风格 status

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: gate.id) == .succeeded)
        #expect(result.status(of: b.id) == .succeeded, "未知 status 值按放行处理")
        #expect(context.executed == [gate.id, b.id])
    }

    // MARK: 4) 状态判定大小写敏感契约（记录行为）

    @Test func lowercaseReviewStatusIsNotBlocked() throws {
        // 契约：审核状态判定区分大小写（PASS/REJECT/PENDING 大写）。小写 "reject"
        // 当前按未知值放行 —— 这是既定行为，但存在「小写打回被静默放行」的健壮性
        // 隐患（见 issues/boundary_tests_findings_20260805.md P3 观察）。
        let gate = bReviewGateNode("审核")
        let b = bNode("下游", type: "imageGen")
        let graph = bGraph(nodes: [gate, b], edges: [bEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()
        context.outputsByNode[gate.id] = bReviewOutput(status: "reject")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: gate.id) == .succeeded, "小写 reject 当前不拦截（记录契约）")
        #expect(result.status(of: b.id) == .succeeded)
        #expect(context.executed == [gate.id, b.id])
    }

    // MARK: 5) 多个 reviewGate 串联

    @Test func multipleReviewGatesInSeriesBlockTransitively() throws {
        let gate1 = bReviewGateNode("一审")
        let gate2 = bReviewGateNode("二审")
        let b = bNode("下游", type: "imageGen")
        let graph = bGraph(nodes: [gate1, gate2, b], edges: [bEdge(gate1, gate2), bEdge(gate2, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()
        context.outputsByNode[gate1.id] = bReviewOutput(status: "REJECT", reasons: "一审未过")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: gate1.id) == .failed)
        #expect(result.status(of: gate2.id) == .skipped, "串联的下游审核节点也必须被跳过（不执行）")
        #expect(result.status(of: b.id) == .skipped)
        #expect(context.executed == [gate1.id], "被拦截的审核节点不得执行执行器")
        let reason = try #require(result.skipReason(of: gate2.id))
        #expect(reason.contains("一审"), "跳过原因应追溯到根因节点")
        #expect(reason.contains("REJECT"))
    }

    // MARK: 6) REJECT 后手动放行再执行

    @Test func rejectThenManualPassAllowsReexecution() throws {
        let gate = bReviewGateNode("审核")
        let b = bNode("下游", type: "imageGen")
        let graph = bGraph(nodes: [gate, b], edges: [bEdge(gate, b)])
        var scheduler = DAGScheduler()
        let ctx1 = ReviewGateBoundaryContext()
        ctx1.outputsByNode[gate.id] = bReviewOutput(status: "REJECT", reasons: "r1")

        let r1 = try scheduler.run(graph: graph, context: ctx1)

        #expect(r1.status(of: gate.id) == .failed)
        #expect(r1.status(of: b.id) == .skipped)
        #expect(ctx1.executed == [gate.id])
        #expect(scheduler.cacheCount == 0, "闸口失败输出不得写缓存（否则手动放行后重跑会误命中）")

        // 手动放行：同 scheduler 二次执行，gate 带 manual review.status=PASS 覆盖执行输出 REJECT
        let gate2 = bReviewGateNode("审核", manualStatus: "PASS")
        let b2 = bNode("下游", type: "imageGen")
        let graph2 = bGraph(nodes: [gate2, b2], edges: [bEdge(gate2, b2)])
        let ctx2 = ReviewGateBoundaryContext()
        ctx2.outputsByNode[gate2.id] = bReviewOutput(status: "REJECT", pass: "x", reasons: "r2")

        let r2 = try scheduler.run(graph: graph2, context: ctx2)

        #expect(r2.status(of: gate2.id) == .succeeded, "手动 PASS 应放行曾被 REJECT 的审核节点")
        #expect(r2.status(of: b2.id) == .succeeded, "放行后下游重新执行")
        #expect(ctx2.executed == [gate2.id, b2.id])
        #expect(r2.skipReason(of: b2.id) == nil)
    }

    // MARK: 7) gateFailureReason 透传格式

    @Test func rejectReasonFormatPropagatesVerbatim() throws {
        let gate = bReviewGateNode("审核")
        let b = bNode("下游", type: "imageGen")
        let graph = bGraph(nodes: [gate, b], edges: [bEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()
        context.outputsByNode[gate.id] = bReviewOutput(
            status: "REJECT",
            pass: "【BLOCKED】提示词结构闸口未通过",
            reasons: "文本含 BLOCKED 标记（需修复）"
        )

        let result = try scheduler.run(graph: graph, context: context)

        let reason = try #require(result.skipReason(of: b.id))
        #expect(reason == "上游「审核」闸口未通过：审核未通过（REJECT）：文本含 BLOCKED 标记（需修复）",
                "REJECT 原因应完整透传；实际：\\(reason)")
    }

    @Test func rejectWithoutReasonsUsesCompactFormat() throws {
        let gate = bReviewGateNode("审核")
        let b = bNode("下游", type: "imageGen")
        let graph = bGraph(nodes: [gate, b], edges: [bEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()
        context.outputsByNode[gate.id] = bReviewOutput(status: "REJECT")

        let result = try scheduler.run(graph: graph, context: context)

        let reason = try #require(result.skipReason(of: b.id))
        #expect(reason == "上游「审核」闸口未通过：审核未通过（REJECT）",
                "无 reasons 时使用紧凑格式；实际：\\(reason)")
    }

    @Test func pendingReasonFormat() throws {
        let gate = bReviewGateNode("审核")
        let b = bNode("下游", type: "imageGen")
        let graph = bGraph(nodes: [gate, b], edges: [bEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()
        context.outputsByNode[gate.id] = bReviewOutput(status: "PENDING")

        let result = try scheduler.run(graph: graph, context: context)

        let reason = try #require(result.skipReason(of: b.id))
        #expect(reason == "上游「审核」闸口未通过：审核待审（PENDING）",
                "PENDING 原因格式；实际：\\(reason)")
    }

    // MARK: 8) 三级下游全部被拦

    @Test func threeLevelDownstreamAllBlockedWithSameRootReason() throws {
        let gate = bReviewGateNode("审核")
        let b = bNode("下游1", type: "imageGen")
        let c = bNode("下游2", type: "qcCheck")
        let d = bNode("下游3", type: "llm")
        let graph = bGraph(nodes: [gate, b, c, d],
                           edges: [bEdge(gate, b), bEdge(b, c), bEdge(c, d)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()
        context.outputsByNode[gate.id] = bReviewOutput(status: "REJECT", reasons: "根因描述")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: b.id) == .skipped)
        #expect(result.status(of: c.id) == .skipped)
        #expect(result.status(of: d.id) == .skipped)
        #expect(context.executed == [gate.id])
        let reasonB = try #require(result.skipReason(of: b.id))
        let reasonD = try #require(result.skipReason(of: d.id))
        #expect(reasonB == reasonD, "各级跳过原因应同为根因描述（原样传播）")
        #expect(reasonD.contains("审核"))
        #expect(reasonD.contains("REJECT"))
        #expect(reasonD.contains("根因描述"))
    }

    // MARK: 9) 双分支隔离

    @Test func gateRejectIsolatesItsOwnBranch() throws {
        let gate1 = bReviewGateNode("审核A")
        let b1 = bNode("分支A下游", type: "imageGen")
        let gate2 = bReviewGateNode("审核B")
        let b2 = bNode("分支B下游", type: "imageGen")
        let graph = bGraph(nodes: [gate1, b1, gate2, b2],
                           edges: [bEdge(gate1, b1), bEdge(gate2, b2)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()
        context.outputsByNode[gate1.id] = bReviewOutput(status: "REJECT")
        context.outputsByNode[gate2.id] = bReviewOutput(status: "PASS", pass: "ok")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: b1.id) == .skipped, "REJECT 分支被拦")
        #expect(result.status(of: b2.id) == .succeeded, "PASS 分支不受影响")
        #expect(context.executed == [gate1.id, gate2.id, b2.id])
        let reason = try #require(result.skipReason(of: b1.id))
        #expect(reason.contains("审核A"), "跳过原因应指向自己的根因节点")
    }

    // MARK: 10) 手动 PENDING 拦截

    @Test func manualPendingBlocksDownstream() throws {
        // 执行输出 PASS，但手动 review.status=PENDING → 拦截（手动状态优先）
        let gate = bReviewGateNode("审核", manualStatus: "PENDING")
        let b = bNode("下游", type: "imageGen")
        let graph = bGraph(nodes: [gate, b], edges: [bEdge(gate, b)])
        var scheduler = DAGScheduler()
        let context = ReviewGateBoundaryContext()
        context.outputsByNode[gate.id] = bReviewOutput(status: "PASS", pass: "完整提示词")

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: gate.id) == .failed, "手动 PENDING 应覆盖执行输出 PASS")
        #expect(result.status(of: b.id) == .skipped)
        #expect(context.executed == [gate.id])
        let reason = try #require(result.skipReason(of: b.id))
        #expect(reason.contains("PENDING"))
    }
}
