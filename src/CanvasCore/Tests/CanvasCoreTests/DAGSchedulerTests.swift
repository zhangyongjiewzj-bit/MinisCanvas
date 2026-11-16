import Foundation
import Testing
@testable import CanvasCore

// MARK: - 测试辅助：模拟执行上下文

/// 记录执行次数、支持按类型注入失败与固定输出
private final class MockContext: NodeExecutionContext {
    var executed: [CanvasNode.ID] = []
    var failTypes: Set<String> = []
    var outputsByType: [String: [String: AnyHashable]] = [:]
    /// 输入依赖模式：命中类型的节点输出 = 输入快照（模拟「输入变 → 输出变」，
    /// 用于局部重跑测试中让下游随上游输入变化而重跑）
    var inputDependentTypes: Set<String> = []

    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (CanvasNode.ID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]? {
        let preds = graph.predecessors(of: node.id)
        guard !preds.isEmpty else { return nil }
        var result: [String: AnyHashable] = [:]
        for pred in preds {
            if let out = outputs(pred.id), let v = out["value"] {
                result["from_\(pred.id)"] = v
            }
        }
        return result
    }

    func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
        executed.append(node.id)
        if failTypes.contains(node.type) {
            throw DAGSchedulerError.nodeNotFound(node.id)
        }
        if let out = outputsByType[node.type] { return out }
        if inputDependentTypes.contains(node.type) {
            let snapshot = (inputs ?? [:])
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(String(describing: $0.value))" }
                .joined(separator: ",")
            return ["value": "echo[\(snapshot)]"]
        }
        return ["value": "out_\(node.type)"]
    }
}

private func makeNode(_ title: String, type: String = "llm") -> CanvasNode {
    CanvasNode(type: type, title: title)
}

private func makeEdge(_ from: CanvasNode, _ to: CanvasNode) -> Edge {
    let pOut = Port(name: "out", direction: .output, dataType: "text")
    let pIn = Port(name: "in", direction: .input, dataType: "text")
    return Edge(fromNode: from.id, fromPort: pOut.id, toNode: to.id, toPort: pIn.id)
}

private func makeGraph(nodes: [CanvasNode], edges: [Edge] = []) -> NodeGraph {
    var g = NodeGraph()
    nodes.forEach { g.addNode($0) }
    edges.forEach { g.addEdge($0) }
    return g
}

// MARK: - C2-2 执行反馈测试辅助

/// 逐节点事件收集器（同步回调、单线程，无需加锁）
private final class EventCollector: @unchecked Sendable {
    var events: [DAGExecutionEvent] = []
}

/// 中断开关（测试用：事件回调里翻转，模拟「停止」按钮）
private final class CancelSwitch: @unchecked Sendable {
    var cancelled = false
}

// MARK: - DAGScheduler 测试

struct DAGSchedulerTests {

    private func executionEnvelope(
        canvasID: UUID,
        graph: NodeGraph,
        runID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    ) -> DAGExecutionEnvelope {
        DAGExecutionEnvelope(
            canvasID: canvasID,
            runID: runID,
            graphRevision: graph.revision,
            graphFingerprint: graph.fingerprint,
            cancellationGeneration: 0,
            providerSnapshotFingerprint: "provider-fingerprint",
            idempotencyKey: "dag-\(runID.uuidString)"
        )
    }

    @Test func sameGraphStructureOnDifferentCanvasRejectsLateWriteback() throws {
        let node = makeNode("A")
        let graph = makeGraph(nodes: [node])
        let canvasA = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let canvasB = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let expected = executionEnvelope(canvasID: canvasA, graph: graph)
        let current = executionEnvelope(
            canvasID: canvasB,
            graph: graph,
            runID: expected.runID
        )

        #expect(
            validateDAGWriteback(expected: expected, actual: current, isCancelled: false)
                == .rejected(.canvasMismatch)
        )
        #expect(
            validateDAGAssetRegistration(envelope: expected, targetCanvasID: canvasB)
                == .rejected(.canvasMismatch)
        )
    }

    @Test func schedulerResultCarriesFrozenCanvasEnvelope() throws {
        let node = makeNode("A")
        let graph = makeGraph(nodes: [node])
        let canvasID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let envelope = executionEnvelope(canvasID: canvasID, graph: graph)
        var scheduler = DAGScheduler()

        let result = try scheduler.run(
            graph: graph,
            context: MockContext(),
            executionEnvelope: envelope
        )

        #expect(result.executionEnvelope == envelope)
        #expect(
            scheduler.applying(
                result,
                to: graph,
                currentEnvelope: executionEnvelope(
                    canvasID: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
                    graph: graph,
                    runID: envelope.runID
                )
            ) == nil
        )
    }

    @Test func schedulerRejectsEnvelopeForStaleGraphBeforeExecution() throws {
        let node = makeNode("A")
        let graph = makeGraph(nodes: [node])
        let context = MockContext()
        let envelope = DAGExecutionEnvelope(
            canvasID: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!,
            graphRevision: graph.revision,
            graphFingerprint: "stale-fingerprint"
        )
        var scheduler = DAGScheduler()

        #expect(throws: DAGSchedulerError.graphFingerprintMismatch(
            expected: "stale-fingerprint",
            actual: graph.fingerprint
        )) {
            _ = try scheduler.run(
                graph: graph,
                context: context,
                executionEnvelope: envelope
            )
        }
        #expect(context.executed.isEmpty)
    }

    // MARK: - 拓扑排序

    @Test func topologicalSortLinearChain() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])

        let order = try DAGScheduler.topologicalSort(in: graph)
        #expect(order == [a.id, b.id, c.id], "线性链应严格按依赖顺序输出")
    }

    @Test func topologicalSortDiamond() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let d = makeNode("D")
        let graph = makeGraph(
            nodes: [a, b, c, d],
            edges: [makeEdge(a, b), makeEdge(a, c), makeEdge(b, d), makeEdge(c, d)]
        )

        let order = try DAGScheduler.topologicalSort(in: graph)
        #expect(order.count == 4, "菱形图应包含全部 4 个节点")
        #expect(order.first == a.id, "入度为 0 的 A 应排在最前")
        #expect(order.last == d.id, "出度为 0 的 D 应排在最后")

        // 前驱必须先于后继（B 在 D 前，C 在 D 前）
        let indexB = order.firstIndex(of: b.id) ?? -1
        let indexC = order.firstIndex(of: c.id) ?? -1
        let indexD = order.firstIndex(of: d.id) ?? -1
        #expect(indexB < indexD && indexC < indexD)
    }

    @Test func topologicalSortIndependentNodes() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c])

        let order = try DAGScheduler.topologicalSort(in: graph)
        #expect(order == [a.id, b.id, c.id], "无依赖节点按图中插入顺序输出（确定性）")
    }

    // MARK: - 环检测

    @Test func cycleDetectionTwoNodeCycle() {
        let a = makeNode("A")
        let b = makeNode("B")
        let graph = makeGraph(nodes: [a, b], edges: [makeEdge(a, b), makeEdge(b, a)])

        do {
            _ = try DAGScheduler.topologicalSort(in: graph)
            Issue.record("应当抛出 cycleDetected")
        } catch {
            #expect(error as? DAGSchedulerError == .cycleDetected)
        }
    }

    @Test func cycleDetectionThreeNodeCycle() {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(
            nodes: [a, b, c],
            edges: [makeEdge(a, b), makeEdge(b, c), makeEdge(c, a)]
        )

        do {
            _ = try DAGScheduler.layers(in: graph)
            Issue.record("分层应同样检测到环并抛出")
        } catch {
            #expect(error as? DAGSchedulerError == .cycleDetected)
        }
    }

    // MARK: - 分层

    @Test func layersAssignLongestPathDepth() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let d = makeNode("D")
        let graph = makeGraph(
            nodes: [a, b, c, d],
            edges: [makeEdge(a, b), makeEdge(a, c), makeEdge(b, d), makeEdge(c, d)]
        )

        let layers = try DAGScheduler.layers(in: graph)
        #expect(layers.count == 3, "菱形图应有 3 层")

        let layer0 = Set(layers[0])
        let layer1 = Set(layers[1])
        let layer2 = Set(layers[2])
        #expect(layer0 == [a.id])
        #expect(layer1 == [b.id, c.id], "B、C 互不依赖，应同层")
        #expect(layer2 == [d.id])

        // 同层内任意两点之间不得有依赖边
        for layer in layers {
            let ids = Set(layer)
            for nodeID in layer {
                let successors = Set(graph.successors(of: nodeID).map(\.id))
                #expect(successors.isDisjoint(with: ids.subtracting([nodeID])),
                        "同层节点之间不应存在依赖边")
            }
        }
    }

    // MARK: - 断点续跑

    @Test func resumeFromSkipsAlreadySucceededNodes() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])
        var scheduler = DAGScheduler()
        let context = MockContext()

        let result = try scheduler.run(graph: graph, context: context, resumeFrom: [a.id, b.id])

        #expect(context.executed == [c.id], "断点续跑应只执行未完成节点 C")
        #expect(result.status(of: a.id) == .succeeded)
        #expect(result.status(of: b.id) == .succeeded)
        #expect(result.status(of: c.id) == .succeeded)
    }

    // MARK: - 失败跳过

    @Test func failureSkipsAllDownstream() throws {
        let a = makeNode("A", type: "ok")
        let b = makeNode("B", type: "boom")
        let c = makeNode("C", type: "ok")
        let d = makeNode("D", type: "ok")
        let graph = makeGraph(
            nodes: [a, b, c, d],
            edges: [makeEdge(a, b), makeEdge(b, c), makeEdge(c, d)]
        )
        var scheduler = DAGScheduler()
        let context = MockContext()
        context.failTypes = ["boom"]

        let result = try scheduler.run(graph: graph, context: context)

        #expect(result.status(of: a.id) == .succeeded)
        #expect(result.status(of: b.id) == .failed)
        #expect(result.status(of: c.id) == .skipped, "失败节点的直接下游应被跳过")
        #expect(result.status(of: d.id) == .skipped, "失败节点的传递下游也应被跳过")
        #expect(context.executed == [a.id, b.id], "被跳过的节点不应执行")
    }

    // MARK: - 缓存命中

    @Test func cacheHitDoesNotReexecute() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])
        var scheduler = DAGScheduler()
        let context = MockContext()

        _ = try scheduler.run(graph: graph, context: context)
        #expect(context.executed == [a.id, b.id, c.id])
        #expect(scheduler.cacheCount == 3, "三个节点执行后均应写入缓存")

        let second = try scheduler.run(graph: graph, context: context)
        #expect(context.executed == [a.id, b.id, c.id], "同输入第二次运行不应重跑任何节点")
        #expect(second.status(of: a.id) == .cached)
        #expect(second.status(of: c.id) == .cached, "缓存命中节点标记 cached（UI 灰显「已缓存」）")
        #expect(second.output(of: c.id)?["value"] as? String == "out_llm", "缓存应返回与首次一致的结果")
    }

    // MARK: - C2-2 执行反馈：逐节点进度事件 / 缓存命中事件 / 中断

    @Test func progressEventSequenceStartedThenFinished() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])
        var scheduler = DAGScheduler()
        let context = MockContext()
        let collector = EventCollector()

        _ = try scheduler.run(graph: graph, context: context) { collector.events.append($0) }

        // 每个节点严格 started → finished 配对，且按拓扑序（ComfyUI executing 事件流等价物）
        #expect(collector.events == [
            .nodeStarted(a.id), .nodeFinished(a.id),
            .nodeStarted(b.id), .nodeFinished(b.id),
            .nodeStarted(c.id), .nodeFinished(c.id),
        ])
    }

    @Test func cacheHitEmitsCachedEventAndMarksCached() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let graph = makeGraph(nodes: [a, b], edges: [makeEdge(a, b)])
        var scheduler = DAGScheduler()
        let context = MockContext()
        _ = try scheduler.run(graph: graph, context: context)

        let collector = EventCollector()
        let second = try scheduler.run(graph: graph, context: context) { collector.events.append($0) }

        #expect(second.status(of: a.id) == .cached)
        #expect(second.status(of: b.id) == .cached)
        #expect(collector.events == [.nodeCached(a.id), .nodeCached(b.id)],
                "缓存命中不触发 started/finished，只发 nodeCached（UI 灰显不重跑）")
    }

    @Test func interruptionSkipsRemainingNodes() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])
        var scheduler = DAGScheduler()
        let context = MockContext()
        let cancelSwitch = CancelSwitch()
        let collector = EventCollector()

        let result = try scheduler.run(
            graph: graph, context: context,
            onEvent: { event in
                collector.events.append(event)
                // A 完成后置中断 → B/C 在节点检查时发现已取消（等价「停止」按钮）
                if event == .nodeFinished(a.id) { cancelSwitch.cancelled = true }
            },
            isCancelled: { cancelSwitch.cancelled }
        )

        #expect(result.wasCancelled == true)
        #expect(context.executed == [a.id], "中断后剩余节点不再执行")
        #expect(result.status(of: a.id) == .succeeded)
        #expect(result.status(of: b.id) == .skipped, "中断后剩余节点标记 skipped")
        #expect(result.status(of: c.id) == .skipped)
        #expect(collector.events.contains(.cancelled), "中断应发出 cancelled 事件")
        #expect(collector.events.filter { $0 == .nodeSkipped(b.id) || $0 == .nodeSkipped(c.id) }.count == 2)
    }

    // MARK: - P0 局部重跑（from + seedOutputs：只重跑根节点及其下游）

    @Test func partialRerunExecutesOnlyFromAndDownstream() throws {
        // echo 模式：输出随输入变化——模拟「上游输出更新 → 下游输入变化 → 必须重跑」
        let a = makeNode("A", type: "echo")
        let b = makeNode("B", type: "echo")
        let c = makeNode("C", type: "echo")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])
        var scheduler = DAGScheduler()
        let context = MockContext()
        context.inputDependentTypes = ["echo"]
        _ = try scheduler.run(graph: graph, context: context)
        #expect(context.executed == [a.id, b.id, c.id])

        // 模拟用户更新了 A 的输出（A 本身已重跑过），从 B 局部重跑
        let collector = EventCollector()
        let seed = [a.id: ["value": "changed"] as [String: AnyHashable]]
        let result = try scheduler.run(
            graph: graph, context: context, from: [b.id], seedOutputs: seed,
            onEvent: { collector.events.append($0) }
        )

        #expect(context.executed == [a.id, b.id, c.id, b.id, c.id],
                "局部重跑只执行 B 及其下游 C，上游 A 不重复执行")
        #expect(result.status(of: a.id) == .pending, "未受影响节点状态沿用图中原状态（pending）")
        #expect(result.status(of: b.id) == .succeeded)
        #expect(result.status(of: c.id) == .succeeded)
        #expect(!collector.events.contains(.nodeStarted(a.id)),
                "未受影响节点不发执行事件（进度计数不含它们）")
        #expect(collector.events.contains(.nodeStarted(b.id)))
        #expect(collector.events.contains(.nodeStarted(c.id)))
    }

    @Test func partialRerunRecoversUpstreamOutputFromSeed() throws {
        // 局部重跑时受影响节点需解析上游输入——上游不执行，输出必须从 seedOutputs 恢复
        let a = makeNode("A")
        let b = makeNode("B")
        let graph = makeGraph(nodes: [a, b], edges: [makeEdge(a, b)])
        var scheduler = DAGScheduler()
        let context = MockContext()
        _ = try scheduler.run(graph: graph, context: context)
        #expect(context.executed == [a.id, b.id])

        let seed = [a.id: ["value": "seed_restored"] as [String: AnyHashable]]
        let result = try scheduler.run(graph: graph, context: context, from: [b.id], seedOutputs: seed)

        #expect(context.executed == [a.id, b.id, b.id], "只有 B 重跑")
        #expect(result.output(of: b.id)?["value"] as? String == "out_llm",
                "B 的输入应从 seed 恢复的 A 输出解析")
        // MockContext.resolveInputs 会把上游输出收集为 from_<id>=<value>
        #expect(result.outputs[b.id] != nil)
    }

    @Test func partialRerunCacheHitWithinAffectedSet() throws {
        // 受影响集合内仍受结果缓存约束：输入未变 → cached 不重跑（ComfyUI 语义）
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])
        var scheduler = DAGScheduler()
        let context = MockContext()
        let first = try scheduler.run(graph: graph, context: context)
        #expect(context.executed == [a.id, b.id, c.id])

        // 第二次局部重跑 B：seed 与首次输出一致 → B、C 输入未变 → 缓存命中，不重跑
        let result = try scheduler.run(
            graph: graph, context: context, from: [b.id], seedOutputs: first.outputs
        )

        #expect(context.executed == [a.id, b.id, c.id], "输入未变时局部重跑应全部缓存命中，不重跑")
        #expect(result.status(of: b.id) == .cached)
        #expect(result.status(of: c.id) == .cached)
    }

    @Test func partialRerunIgnoresStaleUpstreamFailure() throws {
        // 修复 B 后从 B 局部重跑：B 的上游 A 曾失败（affected 集合外），不阻断 B 重跑
        let a = makeNode("A", type: "boom")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])
        var scheduler = DAGScheduler()
        let context = MockContext()
        context.failTypes = ["boom"]

        let first = try scheduler.run(graph: graph, context: context)
        #expect(first.status(of: b.id) == .skipped, "首次运行 A 失败 → B 被跳过")
        #expect(context.executed == [a.id])

        // 用户修复 B（内容/参数），从 B 局部重跑
        let seed = [a.id: ["value": "out_boom"] as [String: AnyHashable]]
        let result = try scheduler.run(graph: graph, context: context, from: [b.id], seedOutputs: seed)

        #expect(result.status(of: b.id) == .succeeded, "A 的旧失败状态不应阻断 B 局部重跑")
        #expect(result.status(of: c.id) == .succeeded)
        #expect(context.executed == [a.id, b.id, c.id], "B、C 应执行，A 不重跑")
    }

    @Test func partialRerunBranchOnlyAffectsDownstream() throws {
        // 分支图：A → B、A → C；从 B 重跑只影响 B 分支，C 分支不受影响
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(a, c)])
        var scheduler = DAGScheduler()
        let context = MockContext()
        _ = try scheduler.run(graph: graph, context: context)
        #expect(context.executed == [a.id, b.id, c.id])

        let seed = [a.id: ["value": "v"] as [String: AnyHashable]]
        let result = try scheduler.run(graph: graph, context: context, from: [b.id], seedOutputs: seed)

        #expect(context.executed == [a.id, b.id, c.id, b.id], "只重跑 B，C 分支不重跑")
        #expect(result.status(of: b.id) == .succeeded)
        #expect(result.status(of: c.id) == .pending, "C 不在受影响集合内，状态沿用图中原状态")
    }
}
