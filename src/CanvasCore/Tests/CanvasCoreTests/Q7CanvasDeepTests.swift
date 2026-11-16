import Foundation
import Testing
@testable import CanvasCore

// MARK: - Q7 画布循环测试第1轮：深度边界测试
//
// 覆盖 GraphModels / DAGScheduler / GraphLayout / NodeExecutors /
// ManjuPipeline / ManjuPromptTemplates / ManjuTicketParser / QC /
// NodeDiagnostics 的边界场景：self-loop、重复边、孤立节点、无输入源节点、
// 缓存键碰撞、断点续跑+缓存、取消、分列布局、执行器路由兜底、诊断截断等。

// MARK: - 测试辅助

/// 输出 = 节点标题的执行上下文（验证无输入源节点各自产出）
private final class TitleOutputContext: NodeExecutionContext {
    var executed: [UUID] = []
    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (UUID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]? {
        nil
    }
    func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
        executed.append(node.id)
        return ["text": node.title]
    }
}

/// 记录输入并原样输出的上下文（验证输入变化使缓存失效）
private final class EchoContext: NodeExecutionContext {
    var executed: [UUID] = []
    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (UUID) -> [String: AnyHashable]?
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
        return ["value": "out_\(node.type)"]
    }
}

/// 可按类型注入失败的上下文
private final class FailByTypeContext: NodeExecutionContext {
    var failTypes: Set<String> = []
    var executed: [UUID] = []
    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (UUID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]? { nil }
    func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
        executed.append(node.id)
        if failTypes.contains(node.type) {
            throw NodeExecutorsError.llmInvocationFailed("mock 失败")
        }
        return ["value": "ok"]
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

// MARK: - GraphModels 边界

struct Q7GraphModelsEdgeTests {

    @Test func selfLoopEdgeQueriesAndCycleDetection() throws {
        let a = makeNode("A")
        var graph = NodeGraph()
        graph.addNode(a)
        let pOut = Port(name: "out", direction: .output, dataType: "text")
        let pIn = Port(name: "in", direction: .input, dataType: "text")
        graph.addEdge(Edge(fromNode: a.id, fromPort: pOut.id, toNode: a.id, toPort: pIn.id))

        // self-loop 查询：邻居含自己、双向边查询含自己
        #expect(graph.neighbors(of: a.id).map(\.id) == [a.id])
        #expect(graph.edges(from: a.id, to: a.id).count == 1)
        #expect(graph.predecessors(of: a.id).map(\.id) == [a.id])
        #expect(graph.successors(of: a.id).map(\.id) == [a.id])

        // self-loop 是环：拓扑排序必须抛 cycleDetected
        do {
            _ = try DAGScheduler.topologicalSort(in: graph)
            Issue.record("self-loop 应被识别为环")
        } catch {
            #expect(error as? DAGSchedulerError == .cycleDetected)
        }
    }

    @Test func duplicateEdgesNeighborsAreUnique() {
        let a = makeNode("A")
        let b = makeNode("B")
        var graph = NodeGraph()
        graph.addNode(a)
        graph.addNode(b)
        let e1 = makeEdge(a, b)
        let e2 = makeEdge(a, b)  // 平行重复边
        graph.addEdge(e1)
        graph.addEdge(e2)

        // 邻居语义是「节点集合」：重复边不应产生重复邻居
        #expect(graph.neighbors(of: a.id).map(\.id) == [b.id])
        #expect(graph.neighbors(of: b.id).map(\.id) == [a.id])
        #expect(graph.successors(of: a.id).map(\.id) == [b.id, b.id] || graph.successors(of: a.id).count == 2)
    }

    @Test func isolatedNodeTopologyAndLayout() throws {
        let a = makeNode("孤岛")
        let graph = makeGraph(nodes: [a])

        let order = try DAGScheduler.topologicalSort(in: graph)
        #expect(order == [a.id])
        let layers = try DAGScheduler.layers(in: graph)
        #expect(layers.count == 1)
        #expect(layers[0] == [a.id])

        let layout = try GraphLayout().layeredLayout(graph: graph)
        #expect(layout[a.id] == Point(x: 0, y: 0), "孤立节点应落在布局原点")
    }

    @Test func removeMiddleNodeKeepsRemainingGraph() {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let d = makeNode("D")
        var graph = NodeGraph()
        [a, b, c, d].forEach { graph.addNode($0) }
        graph.addEdge(makeEdge(a, b))
        graph.addEdge(makeEdge(b, c))
        graph.addEdge(makeEdge(c, d))

        graph.removeNode(id: b.id)

        #expect(graph.nodes.map(\.id) == [a.id, c.id, d.id])
        // 删除 B 只移除与 B 相连的边；C→D 边保留
        #expect(graph.edges.count == 1)
        #expect(graph.edges.first?.fromNode == c.id)
        #expect(graph.edges.first?.toNode == d.id)
    }
}

// MARK: - DAGScheduler 边界

struct Q7DAGSchedulerEdgeTests {

    @Test func selfLoopRunThrowsCycle() {
        let a = makeNode("A")
        var graph = NodeGraph()
        graph.addNode(a)
        graph.addEdge(makeEdge(a, a))
        var scheduler = DAGScheduler()
        do {
            _ = try scheduler.run(graph: graph, context: EchoContext())
            Issue.record("run 前置校验应拦截 self-loop")
        } catch {
            #expect(error as? DAGSchedulerError == .cycleDetected)
        }
    }

    @Test func danglingEdgeThrowsNodeNotFound() {
        let a = makeNode("A")
        let ghost = UUID()
        var graph = NodeGraph()
        graph.addNode(a)
        graph.addEdge(Edge(fromNode: a.id, fromPort: UUID(), toNode: ghost, toPort: UUID()))
        do {
            _ = try DAGScheduler.topologicalSort(in: graph)
            Issue.record("悬空边应抛 nodeNotFound")
        } catch {
            #expect(error as? DAGSchedulerError == .nodeNotFound(ghost))
        }
    }

    @Test func multiEntryMultiExitOrderValid() throws {
        let s1 = makeNode("S1")
        let s2 = makeNode("S2")
        let m = makeNode("M")
        let t1 = makeNode("T1")
        let t2 = makeNode("T2")
        let graph = makeGraph(
            nodes: [s1, s2, m, t1, t2],
            edges: [makeEdge(s1, m), makeEdge(s2, m), makeEdge(m, t1), makeEdge(m, t2)]
        )
        let order = try DAGScheduler.topologicalSort(in: graph)
        #expect(order.count == 5)
        let iS1 = order.firstIndex(of: s1.id) ?? -1
        let iS2 = order.firstIndex(of: s2.id) ?? -1
        let iM = order.firstIndex(of: m.id) ?? -1
        let iT1 = order.firstIndex(of: t1.id) ?? -1
        let iT2 = order.firstIndex(of: t2.id) ?? -1
        #expect(iS1 < iM && iS2 < iM && iM < iT1 && iM < iT2)
    }

    // MARK: 缓存键碰撞（真实 bug 复现）

    @Test func cacheKeyDistinguishesIntFromString() {
        let node = makeNode("N")
        // AnyHashable(5) 与 AnyHashable("5") 的 String(describing:) 都是 "5"
        let intKey = DAGScheduler.cacheKey(node: node, inputs: ["x": AnyHashable(5)])
        let strKey = DAGScheduler.cacheKey(node: node, inputs: ["x": AnyHashable("5")])
        #expect(intKey != strKey, "Int 5 与 String \"5\" 必须产生不同缓存键，否则类型不同的输入互相串缓存")
    }

    @Test func cacheKeyUniqueAcrossInputlessSameTypeNodes() {
        let a = makeNode("A")
        let b = makeNode("B")
        // 两个同类型、均无输入的源节点：当前实现 key 都是 "text|..."（同前缀）
        let keyA = DAGScheduler.cacheKey(node: a, inputs: nil)
        let keyB = DAGScheduler.cacheKey(node: b, inputs: nil)
        #expect(keyA != keyB, "无输入源节点的输出依赖节点自身（标题/内容），key 必须含节点身份")
    }

    @Test func twoInputlessSourceNodesProduceOwnOutputs() throws {
        let a = CanvasNode(type: "text", title: "小说A")
        let b = CanvasNode(type: "text", title: "小说B")
        let graph = makeGraph(nodes: [a, b])
        var scheduler = DAGScheduler()
        let context = TitleOutputContext()

        let result = try scheduler.run(graph: graph, context: context)

        #expect(context.executed == [a.id, b.id], "两个无输入源节点都必须执行，不能互相吃缓存")
        #expect(result.output(of: a.id)?["text"] as? String == "小说A")
        #expect(result.output(of: b.id)?["text"] as? String == "小说B", "B 不能拿到 A 的缓存输出")
    }

    // MARK: 断点续跑 + 缓存

    @Test func resumeFromRestoresCachedOutputs() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])
        var scheduler = DAGScheduler()
        let context = EchoContext()
        _ = try scheduler.run(graph: graph, context: context)  // 全量执行并写缓存
        #expect(scheduler.cacheCount == 3)

        // 断点续跑 A/B：应从缓存恢复输出并标记 cached；C 不在 resumeFrom 但首次运行已写缓存 → cached
        let resume = try scheduler.run(graph: graph, context: context, resumeFrom: [a.id, b.id])
        #expect(context.executed == [a.id, b.id, c.id])
        #expect(resume.status(of: a.id) == .cached)
        #expect(resume.status(of: b.id) == .cached)
        #expect(resume.status(of: c.id) == .cached, "C 同输入命中首次运行缓存，标记 cached 不重跑")
        #expect(resume.output(of: a.id)?["value"] as? String == "out_llm", "断点续跑应恢复缓存输出")
        #expect(resume.output(of: c.id)?["value"] as? String == "out_llm")
    }

    @Test func rerunAfterFailureExecutesAgain() throws {
        let a = makeNode("A", type: "boom")
        let graph = makeGraph(nodes: [a])
        let ctx = FailByTypeContext()
        ctx.failTypes = ["boom"]
        var s1 = DAGScheduler()
        let r1 = try s1.run(graph: graph, context: ctx)
        #expect(r1.status(of: a.id) == .failed)
        #expect(s1.cacheCount == 0, "失败不写缓存")

        // 修复后重跑（新调度器）：必须真正重新执行
        let ctx2 = FailByTypeContext()
        var s2 = DAGScheduler()
        let r2 = try s2.run(graph: graph, context: ctx2)
        #expect(r2.status(of: a.id) == .succeeded)
        #expect(ctx2.executed == [a.id])
    }

    @Test func cancelFromStartSkipsEverything() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let graph = makeGraph(nodes: [a, b], edges: [makeEdge(a, b)])
        var scheduler = DAGScheduler()
        let context = EchoContext()
        let result = try scheduler.run(
            graph: graph, context: context,
            isCancelled: { true }
        )
        #expect(result.wasCancelled)
        #expect(context.executed.isEmpty)
        #expect(result.status(of: a.id) == .skipped)
        #expect(result.status(of: b.id) == .skipped)
    }

    @Test func duplicateEdgesScheduleEachNodeOnce() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        var graph = NodeGraph()
        [a, b, c].forEach { graph.addNode($0) }
        graph.addEdge(makeEdge(a, b))
        graph.addEdge(makeEdge(a, b))  // 平行重复边
        graph.addEdge(makeEdge(b, c))
        var scheduler = DAGScheduler()
        let context = EchoContext()
        let result = try scheduler.run(graph: graph, context: context)
        #expect(result.status(of: a.id) == .succeeded)
        #expect(result.status(of: b.id) == .succeeded, "重复边不应导致重复执行或死循环")
        #expect(result.status(of: c.id) == .succeeded)
        #expect(context.executed == [a.id, b.id, c.id])
    }

    @Test func cacheInvalidatedOnInputChange() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let graph = makeGraph(nodes: [a, b], edges: [makeEdge(a, b)])
        var scheduler = DAGScheduler()
        let context = EchoContext()
        _ = try scheduler.run(graph: graph, context: context)
        #expect(scheduler.cacheCount == 2)

        // 上游输出变化 → 下游输入变化 → 缓存失效重新执行（B 的 key 含输入哈希）
        // 用新图模拟输入变化：A 执行产出不同值
        let a2 = makeNode("A2")
        let graph2 = makeGraph(nodes: [a2, b], edges: [makeEdge(a2, b)])
        let before = context.executed.count
        _ = try scheduler.run(graph: graph2, context: context)
        #expect(context.executed.count == before + 2, "输入变化后 A2 与 B 都应重新执行")
        #expect(scheduler.cacheCount == 4, "新 key 应新增缓存条目而非覆盖")
    }
}

// MARK: - GraphLayout 边界

struct Q7GraphLayoutEdgeTests {

    @Test func layoutSplitsColumnsBeyondLimit() throws {
        var graph = NodeGraph()
        let nodes = (1...10).map { makeNode("N\($0)") }
        nodes.forEach { graph.addNode($0) }
        let layout = try GraphLayout(maxNodesPerColumn: 4).layeredLayout(graph: graph)

        #expect(layout.count == 10)
        // 4 个/列 → 10 个节点分 3 列
        let xSet = Set(layout.values.map(\.x))
        #expect(xSet.count == 3, "超过每列上限应自动分列，产生 3 个不同的 x")
        // 每列内 y 互不重叠（间距 80）
        for x in xSet {
            let ys = layout.values.filter { $0.x == x }.map(\.y).sorted()
            for i in 1..<ys.count {
                #expect(ys[i] - ys[i - 1] >= 80, "同列节点应保持 nodeSpacing 间距")
            }
        }
    }

    @Test func layoutPreservesManualAndAvoidsOverlap() throws {
        let manual = CanvasNode(type: "text", title: "手动", position: Point(x: 500, y: 300))
        let auto = makeNode("自动")
        let graph = makeGraph(nodes: [manual, auto])
        let layout = try GraphLayout().layeredLayout(graph: graph)

        #expect(layout[manual.id] == Point(x: 500, y: 300), "手动定位节点坐标原样保留")
        let autoPos = layout[auto.id] ?? Point(x: -1, y: -1)
        #expect(autoPos.y != 300, "自动节点应避让同层手动节点")
    }

    @Test func layoutThrowsOnCycle() {
        let a = makeNode("A")
        let b = makeNode("B")
        let graph = makeGraph(nodes: [a, b], edges: [makeEdge(a, b), makeEdge(b, a)])
        do {
            _ = try GraphLayout().layeredLayout(graph: graph)
            Issue.record("环图布局应抛出")
        } catch {
            #expect(error as? DAGSchedulerError == .cycleDetected)
        }
    }
}

// MARK: - NodeExecutors 边界

struct Q7NodeExecutorsEdgeTests {

    @Test func unknownTypeRoutesNil() {
        #expect(NodeExecutors().executor(for: "doesNotExist") == nil)
        #expect(NodeExecutors.executor(for: "doesNotExist") == nil)
        #expect(NodeExecutors().executor(for: "text") != nil)
        #expect(NodeExecutors().executor(for: ManjuNodeType.qcCheck.rawValue) != nil)
        #expect(NodeExecutors().executor(for: ManjuNodeType.assetRef.rawValue) != nil)
    }

    @Test func textExecutorUsesParamsContent() async throws {
        let node = CanvasNode(
            type: "text", title: "粘贴板",
            backendConfig: NodeBackendConfig(params: ["content": "双击粘贴的小说全文"])
        )
        let output = try await TextNodeExecutor().execute(node: node, inputs: nil, backend: nil)
        #expect(output["text"] as? String == "双击粘贴的小说全文", "无输入时应回退读 params[\"content\"]")
    }

    @Test func textExecutorFixedTitleFallback() async throws {
        let titled = CanvasNode(type: "text", title: "我的文本")
        let out1 = try await TextNodeExecutor().execute(node: titled, inputs: nil, backend: nil)
        #expect(out1["text"] as? String == "我的文本")

        let untitled = CanvasNode(type: "text", title: "")
        let out2 = try await TextNodeExecutor().execute(node: untitled, inputs: nil, backend: nil)
        #expect(out2["text"] as? String == "文本节点输出", "无标题时用默认文本，避免空输出")
    }

    @Test func textExecutorPassthroughInputs() async throws {
        let node = CanvasNode(type: "text", title: "透传")
        let out = try await TextNodeExecutor().execute(
            node: node, inputs: ["prompt": AnyHashable("上游内容")], backend: nil
        )
        #expect(out["prompt"] as? String == "上游内容")
    }

    @Test func llmExecutorMissingInvokerThrows() async {
        let node = CanvasNode(type: "llm", title: "LLM")
        do {
            _ = try await LLMNodeExecutor().execute(node: node, inputs: nil, backend: nil)
            Issue.record("未注入 LLMInvoker 必须抛 missingLLMInvoker")
        } catch {
            #expect(error as? NodeExecutorsError == .missingLLMInvoker("llm"))
        }
    }

    @Test func mediaPlaceholderKeepsInputsAndStatus() async throws {
        let node = CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "生图")
        let out = try await MediaPlaceholderExecutor().execute(
            node: node, inputs: ["prompt": AnyHashable("赛博街道")], backend: nil
        )
        #expect(out["prompt"] as? String == "赛博街道")
        #expect(out["status"] as? String == "placeholder")
    }

    @Test func blenderResolveScriptFromTextPortAndFile() async throws {
        // text 端口（画布注册表命名）作为脚本内容
        let node1 = CanvasNode(type: ManjuNodeType.blenderPreview.rawValue, title: "白模")
        let script1 = try BlenderNodeExecutor.resolveScript(
            node: node1, inputs: ["text": AnyHashable("bpy.ops.mesh.primitive_cube_add()")]
        )
        #expect(script1.contains("primitive_cube_add"))

        // script 端口是本地文件路径 → 读文件内容
        let dir = FileManager.default.temporaryDirectory
        let fileURL = dir.appendingPathComponent("q7_blender_\(UUID().uuidString).py")
        try "import bpy\nprint('hi')".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let node2 = CanvasNode(type: ManjuNodeType.blenderPreview.rawValue, title: "白模")
        let script2 = try BlenderNodeExecutor.resolveScript(
            node: node2, inputs: ["script": AnyHashable(fileURL.path)]
        )
        #expect(script2.contains("import bpy"))

        // 都缺失 → 模板兜底（blenderPreview 模板存在，兜底与节点 type 无关）
        let node3 = CanvasNode(type: ManjuNodeType.blenderPreview.rawValue, title: "白模")
        let script3 = try BlenderNodeExecutor.resolveScript(node: node3, inputs: nil)
        #expect(script3.contains("Blender"), "缺失脚本时应兜底模板 systemPrompt")

        // 空输入字典同样走模板兜底（missingBlenderScript 仅在模板被移除时可达）
        let node4 = CanvasNode(type: "blenderPreviewX", title: "未知")
        let script4 = try BlenderNodeExecutor.resolveScript(node: node4, inputs: [:])
        #expect(script4.contains("Blender"), "空输入也应兜底模板")
    }

    @Test func blenderResolveOutputDirAndFrameRange() {
        let withDir: [String: AnyHashable] = ["outputDir": AnyHashable("/tmp/out")]
        #expect(BlenderNodeExecutor.resolveOutputDir(inputs: withDir) == "/tmp/out")
        let defaultDir = BlenderNodeExecutor.resolveOutputDir(inputs: nil)
        #expect(defaultDir.hasSuffix("miniscanvas_blender_output"))

        let withRange: [String: AnyHashable] = ["frameStart": AnyHashable(1), "frameEnd": AnyHashable(24)]
        let range = BlenderNodeExecutor.resolveFrameRange(inputs: withRange)
        #expect(range?.0 == 1 && range?.1 == 24)
        #expect(BlenderNodeExecutor.resolveFrameRange(inputs: nil) == nil, "缺任一帧值返回 nil")
        #expect(BlenderNodeExecutor.resolveFrameRange(inputs: ["frameStart": AnyHashable(1)]) == nil)
    }

    @Test func qcExecutorPassesCompleteImagePrompt() async throws {
        let prompt = """
        [TYPE]
        竖屏 9:16 定妆图，美感 70% / 危险感 30%

        [REFERENCE]
        参考图：asset://weixian-face-8angle。魏衔 定妆图只继承：脸、五官、眼型、骨相、肤色

        [LAYOUT]
        主体左侧 1/3，前中后景层次，右上留白，主次分明

        [STRUCTURE]
        玄色道袍粗麻织纹、袖口磨损起毛、厚垂坠

        [MATERIAL]
        粗麻织纹、厚垂坠、透光性低

        [COLOR]
        玄青(#1F2A33) 70%、灰褐(#6B5D4F) 20%、暗金(#B08D3E) 8%、朱砂(#C2452D) 2%

        [LIGHT]
        左侧硬光、逆光轮廓光

        [FORBID]
        现代鞋、高跟鞋、换脸
        """
        let node = CanvasNode(type: ManjuNodeType.qcCheck.rawValue, title: "QC")
        let out = try await QCNodeExecutor().execute(
            node: node, inputs: ["prompt": AnyHashable(prompt)], backend: nil
        )
        #expect(out["status"] as? String == "PASS")
        #expect(out["qc_status"] as? String == "PASS")
        #expect((out["report"] as? String)?.contains("PASS") == true)
    }

    @Test func qcExecutorFailsEmptyInput() async throws {
        let node = CanvasNode(type: ManjuNodeType.qcCheck.rawValue, title: "QC")
        let out = try await QCNodeExecutor().execute(node: node, inputs: nil, backend: nil)
        #expect(out["status"] as? String == "FAIL")
        #expect((out["report"] as? String)?.contains("输入为空") == true)
    }

    @Test func assetLockExecutorOutputsSummaryAndRefs() async throws {
        let summary = "参考图：asset://weixian-face-8angle。魏衔 定妆图锁定：脸、五官。母图：asset://qingya-hall-master。"
        let node = CanvasNode(
            type: ManjuNodeType.assetRef.rawValue, title: "资产引用",
            backendConfig: NodeBackendConfig(params: [ManjuAssetInjection.assetRefSummaryKey: summary])
        )
        let out = try await AssetLockExecutor().execute(node: node, inputs: nil, backend: nil)
        #expect(out["assets"] as? String == summary)
        #expect(out["summary"] as? String == summary)
        #expect(out["locked"] as? String == "1")
        #expect(out["status"] as? String == "succeeded")
        let refs = out["referenceImages"] as? [String] ?? []
        #expect(refs == ["asset://weixian-face-8angle", "asset://qingya-hall-master"])
    }

    @Test func assetLockExecutorFallbackWithoutSummary() async throws {
        let node = CanvasNode(type: ManjuNodeType.assetRef.rawValue, title: "资产引用")
        let out = try await AssetLockExecutor().execute(node: node, inputs: nil, backend: nil)
        #expect((out["assets"] as? String)?.contains("未注入资产锁定摘要") == true)
        #expect(out["locked"] as? String == "1")
    }
}

// MARK: - ManjuPipeline / 模板 / 任务单

struct Q7ManjuPipelineEdgeTests {

    @Test func standardPipelineAcyclicComplete() throws {
        let graph = ManjuPipeline.standardPipeline()
        #expect(graph.nodes.count == 9, "标准流水线应含 9 节点")
        #expect(graph.edges.count == 9, "标准流水线应含 9 连线")
        // 无环且分层不抛错
        let layers = try DAGScheduler.layers(in: graph)
        #expect(layers.count == 8)
        // 每节点都有默认后端配置
        for node in graph.nodes {
            #expect(node.backendConfig != nil, "\(node.title) 缺默认后端配置")
        }
        // I2V 链路：imageGen → videoGen
        let imageGen = graph.nodes.first { $0.type == ManjuNodeType.imageGen.rawValue }!
        let videoGen = graph.nodes.first { $0.type == ManjuNodeType.videoGen.rawValue }!
        #expect(graph.successors(of: imageGen.id).map(\.id).contains(videoGen.id))
        // 主链：novelImport → ... → qcCheck
        let qc = graph.nodes.first { $0.type == ManjuNodeType.qcCheck.rawValue }!
        #expect(graph.predecessors(of: qc.id).map(\.id).contains(videoGen.id))
    }

    @Test func storyboardCountHeuristics() {
        #expect(ManjuPipeline.storyboardCount(from: "") == 1, "空文本至少 1 个占位分镜")
        #expect(ManjuPipeline.storyboardCount(from: "   \n\n  ") == 1)
        #expect(ManjuPipeline.storyboardCount(from: "第一段\n\n第二段\n\n第三段") == 3)
        let many = (1...30).map { "第\($0)段" }.joined(separator: "\n\n")
        #expect(ManjuPipeline.storyboardCount(from: many) == 24, "上限 24")
        let nodes = ManjuPipeline.storyboardNodes(script: "甲\n\n乙")
        #expect(nodes.count == 2)
        #expect(nodes.allSatisfy { $0.type == ManjuNodeType.storyboard.rawValue })
    }

    @Test func image8Video9SlotCompleteness() {
        let image = ManjuPromptTemplates.template(for: .imagePrompt)!
        #expect(image.slots.count == 8)
        #expect(image.slots.map(\.name) == ["TYPE", "REFERENCE", "LAYOUT", "STRUCTURE", "MATERIAL", "COLOR", "LIGHT", "FORBID"])
        let imageAllRequired = image.slots.allSatisfy(\.isRequired)
        #expect(imageAllRequired)

        let video = ManjuPromptTemplates.template(for: .videoPrompt)!
        #expect(video.slots.count == 9)
        #expect(video.slots.map(\.name) == ["MODE", "REFERENCE MAP", "STYLE LOCK", "SHOT", "ACTION", "COLOR", "SOUND", "FORBID", "QC"])
        let videoAllRequired = video.slots.allSatisfy(\.isRequired)
        #expect(videoAllRequired)

        // 全 11 类模板齐全
        #expect(ManjuPromptTemplates.allTemplates.count == ManjuNodeType.allCases.count)
    }

    @Test func actionDurationParsingAndNote() {
        let segments = ManjuTicketParser.parseActionSegments("0-1秒 拔剑；1-3秒 转身；3~5秒 收势")
        #expect(segments.count == 3)
        #expect(abs(ManjuTicketParser.totalDuration(segments) - 5) < 0.001)

        #expect(ManjuTicketParser.shotDurationSeconds(from: "5") == 5)
        #expect(ManjuTicketParser.shotDurationSeconds(from: "5秒") == 5)
        #expect(ManjuTicketParser.shotDurationSeconds(from: "5.0") == 5)
        #expect(ManjuTicketParser.shotDurationSeconds(from: nil) == nil)

        let ok = ManjuTicketParser.actionDurationNote(
            actionText: "0-1秒 起手；1-3秒 连击；3-5秒 收招",
            shotDurationSeconds: 5
        )
        #expect(ok.hasPrefix("✓"), "时段总和=镜头时长应通过铁律11")

        let warn = ManjuTicketParser.actionDurationNote(
            actionText: "0-1秒 起手；1-3秒 连击",
            shotDurationSeconds: 5
        )
        #expect(warn.hasPrefix("⚠️"), "时段不足应警告铁律11")

        let noSeg = ManjuTicketParser.actionDurationNote(actionText: "拔剑收势", shotDurationSeconds: 5)
        #expect(noSeg.hasPrefix("⚠️") && noSeg.contains("未检测到时段段"))
    }

    @Test func modeExtraction() {
        // 标准场景：MODE 槽后跟下一个槽位标记 → 只取 MODE 行
        let full = "[MODE]\nI2V\n\n[REFERENCE MAP]\n参考图：asset://x"
        #expect(ManjuTicketParser.mode(from: full) == "I2V")
        #expect(ManjuTicketParser.mode(from: "[MODE]\n（待填）\n\n[SHOT]\n近景") == nil, "（待填）视为未声明")
        #expect(ManjuTicketParser.mode(from: "没有模式") == nil)
        // MODE 内容含多行时原样返回（直到下一槽标记），保持与 parseSlots 一致
        let multiLine = ManjuTicketParser.mode(from: "[MODE]\nI2V\n附加说明\n\n[SHOT]\n近景")
        #expect(multiLine == "I2V\n附加说明")
    }
}

// MARK: - QC 判定边界

struct Q7QCEvaluatorEdgeTests {

    @Test func qcDetectsVideo9ViaQCAndListsMissing() {
        let partial = "[QC]\ndial_variance=7 / dial_motion=5 / dial_density=4\n"
        let result = ManjuQCEvaluator.evaluate(prompt: partial)
        #expect(result.templateKind == .video9, "含 [QC] 标记应识别为视频 9 槽")
        #expect(result.status == .fail)
        #expect(result.missingSlots.contains("MODE"))
        #expect(result.missingSlots.contains("ACTION"))
        #expect(!result.missingSlots.contains("QC"), "QC 槽本身非空不应列入缺槽")
    }

    @Test func qcUnknownTemplateFails() {
        let result = ManjuQCEvaluator.evaluate(prompt: "随便一段没有槽位标记的文字")
        #expect(result.templateKind == .unknown)
        #expect(result.status == .fail)
        #expect(result.reasons.first?.contains("未检测到") == true)
    }

    @Test func qcEmptyAndWhitespaceInputFails() {
        let empty = ManjuQCEvaluator.evaluate(prompt: nil)
        #expect(empty.status == .fail)
        #expect(empty.reasons.first?.contains("输入为空") == true)

        let blank = ManjuQCEvaluator.evaluate(prompt: "   \n  ")
        #expect(blank.status == .fail)
    }

    @Test func qcImage8DetectionAndDialSkip() {
        let image = """
        [TYPE]
        竖屏 9:16，美感 70% / 危险感 30%

        [REFERENCE]
        参考图：asset://face。只继承：脸

        [LAYOUT]
        主次分明，前中后景

        [STRUCTURE]
        织纹磨损

        [MATERIAL]
        粗麻织纹

        [COLOR]
        玄青(#1F2A33) 70%

        [LIGHT]
        侧光

        [FORBID]
        现代鞋
        """
        let result = ManjuQCEvaluator.evaluate(prompt: image)
        #expect(result.templateKind == .image8)
        #expect(result.status == .pass, "图片 8 槽无三刻度盘约定，不应判 dial 缺失")
        #expect(result.missingSlots.isEmpty)
    }
}

// MARK: - NodeDiagnostics 边界

struct Q7NodeDiagnosticsEdgeTests {

    @Test func describeValueTruncationBoundary() {
        let exactly = String(repeating: "a", count: NodeDiagnostics.maxValueDescriptionLength)
        #expect(NodeDiagnostics.describeValue(exactly) == exactly, "恰好 800 字符不截断")

        let over = String(repeating: "a", count: NodeDiagnostics.maxValueDescriptionLength + 1)
        let described = NodeDiagnostics.describeValue(over)
        #expect(described.contains("已截断"))
        #expect(described.contains("原始 801 字符"))

        // 非 String 值走 String(describing:)
        #expect(NodeDiagnostics.describeValue(42) == "42")
        #expect(NodeDiagnostics.describeValue(true) == "true")
    }

    @Test func diagnosticRedactsSensitiveAndKeepsOrder() {
        let node = CanvasNode(type: "llm", title: "脚本")
        let ctx = NodeDiagnostics.collectDiagnostic(
            from: node,
            error: NodeExecutorsError.llmInvocationFailed("boom"),
            inputs: [
                "prompt": AnyHashable("开场"),
                "API_Key": AnyHashable("sk-123"),
                "access_token": AnyHashable("tok"),
                "Bearer": AnyHashable("keep-me"),  // 不在敏感子串表内，原样保留
            ],
            upstreamOutputKeys: ["c", "a", "b"]
        )
        #expect(ctx.inputs["prompt"] == "开场")
        #expect(ctx.inputs["API_Key"] == nil)
        #expect(ctx.inputs["access_token"] == nil)
        #expect(ctx.inputs["Bearer"] == "keep-me", "未命中敏感子串的键名原样保留（当前脱敏表不含 Bearer）")
        #expect(ctx.upstreamOutputKeys == ["a", "b", "c"])
    }
}
