import Foundation
import CoreGraphics
import AppKit
import Observation
import CanvasCore

// MARK: - 模板库（M1h）

/// 一键流水线模板库：漫剧全流程 / 仅提示词 / 仅生图 3 个预置模板。
enum PipelineTemplate: String, CaseIterable, Identifiable {
    /// 漫剧全流程：ManjuPipeline.standardPipeline 9 节点（小说导入 → … → QC检查）
    case fullPipeline
    /// 仅提示词：图片 8 槽 + 视频 9 槽提示词节点（注入槽位系统提示词）
    case promptsOnly
    /// 仅生图：生图 → 生视频（I2V 首帧）→ QC检查（生成尾链）
    case generationOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullPipeline: return "漫剧全流程"
        case .promptsOnly: return "仅提示词"
        case .generationOnly: return "仅生图"
        }
    }

    var subtitle: String {
        switch self {
        case .fullPipeline: return "9 节点全流程：小说导入 → 剧情 → 脚本 → 分镜 → 提示词 → 生图/生视频 → QC"
        case .promptsOnly: return "图片 8 槽 + 视频 9 槽，连接生图/生视频节点即用"
        case .generationOnly: return "生图 + 生视频 + QC，接提示词节点即用"
        }
    }

    var icon: String {
        switch self {
        case .fullPipeline: return "square.stack.3d.up.fill"
        case .promptsOnly: return "text.quote"
        case .generationOnly: return "photo.on.rectangle.angled"
        }
    }

    /// 生成后的 toast 提示文案
    var toastMessage: String {
        switch self {
        case .fullPipeline: return "漫剧流水线已生成，从小说导入节点开始"
        case .promptsOnly: return "提示词模板已生成：图片 8 槽 + 视频 9 槽"
        case .generationOnly: return "生图流水线已生成：生图 → 生视频 → QC"
        }
    }
}

// MARK: - 画布状态

/// 画布全局状态：节点图 + 交互中间态 + 调度器。
/// 使用 @Observable，任何变更自动驱动 SwiftUI 刷新。
/// I7 P0-3：标注 @MainActor——状态读写全部串行在主线程；
/// 执行调度经 Task.detached 放后台线程，结果回 MainActor 写回（无竞态、不冻结 UI）。
@MainActor @Observable
final class CanvasStore {
    /// 节点图（核心数据）
    var graph: NodeGraph
    /// 当前选中节点集合（支持 Shift 框选多选）
    var selectedNodeIDs: Set<UUID> = []
    /// 主选中节点（模型面板/执行到此处等单节点操作使用）
    var selectedNodeID: UUID? { selectedNodeIDs.first }
    /// 正在展示模型配置面板的节点（nil = 面板关闭）
    var modelPanelNodeID: UUID?
    /// 执行进行中（工具栏按钮状态）
    var isRunning = false
    /// 执行/操作提示消息
    var statusMessage: String?
    /// 节点最近一次执行错误（failed 节点 → 错误信息，UI 失败提示用）
    var nodeErrors: [UUID: String] = [:]
    /// 正在拖拽创建的连线（输出端口 → 鼠标位置），nil = 无
    var pendingEdge: PendingEdge?
    /// 真实执行上下文：NodeExecutors 按类型路由 + 真实 LLMInvoker（M2l CanvasLLMInvoker，
    /// I7 P0-2 接线；FallbackLLMInvoker 缺 key 时自动降级占位输出）
    /// + 真实 BlenderRenderInvoker（M3b：Blender 白模渲染，直连 MinisCore BlenderBridge）
    /// + 真实 ImageGenerating（M1g：Gimage2Provider 生图，无 key 降级任务单）
    let context: GraphExecutionContext
    /// 调度器（含节点级结果缓存，随 struct 拷贝进出保持跨次执行）
    private var scheduler = DAGScheduler()
    /// 最近一次执行结果（M1f：任务单构建/结果回填时读取上游节点输出）
    private(set) var lastResult: DAGExecutionResult?
    /// 底部 toast 提示（M1h：模板生成后短暂提示，ContentView 观察后自动消失）
    var toastMessage: String?
    /// 递增计数：CanvasView 观察到变化后自动缩放到全图（fit bounds）
    var fitRequestID = 0

    struct PendingEdge {
        var fromNode: UUID
        var fromPort: UUID
        var end: Point
    }

    init(graph: NodeGraph = NodeGraph(), context: GraphExecutionContext? = nil) {
        self.graph = graph
        self.context = context ?? GraphExecutionContext(
            executors: NodeExecutors(
                llmInvoker: FallbackLLMInvoker(),
                blenderInvoker: CanvasBlenderInvoker()
            ),
            imageInvoker: ImageGenInvoker()
        )
    }

    // MARK: - 节点操作

    /// 从类型注册表添加节点到画布（默认堆叠在画布左上区）
    func addNode(ofType type: String, at position: Point? = nil) {
        guard let spec = NodeTypeRegistry.spec(for: type) else { return }
        let base = position ?? Point(x: 120 + Double(graph.nodes.count % 5) * 40,
                                     y: 120 + Double(graph.nodes.count / 5) * 40)
        graph.addNode(spec.makeNode(position: base))
        if let last = graph.nodes.last?.id { selectedNodeIDs = [last] }
    }

    func moveNode(id: UUID, to position: Point) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[index].position = position
    }

    func removeNode(id: UUID) {
        graph.removeNode(id: id)
        selectedNodeIDs.remove(id)
        context.importedOutputs[id] = nil
        statusMessage = "已删除节点"
    }

    func selectNode(id: UUID?) {
        if let id {
            selectedNodeIDs = [id]
        } else {
            selectedNodeIDs = []
        }
    }

    /// Shift 框选：选中与矩形相交的节点；additive=true 时追加到已有选中（不替换）
    func selectNodes(in rect: CGRect, additive: Bool) {
        var next = additive ? selectedNodeIDs : []
        for node in graph.nodes {
            let frame = CGRect(x: node.position.x, y: node.position.y,
                               width: NodeMetrics.nodeWidth,
                               height: NodeMetrics.nodeHeight(inputs: node.inputs.count,
                                                              outputs: node.outputs.count))
            if frame.intersects(rect) { next.insert(node.id) }
        }
        selectedNodeIDs = next
    }

    /// 批量删除节点（含关联连线），用于多选删除
    func removeNodes(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        graph.nodes.removeAll { set.contains($0.id) }
        graph.edges.removeAll { set.contains($0.fromNode) || set.contains($0.toNode) }
        for id in set { context.importedOutputs[id] = nil }
        selectedNodeIDs.subtract(set)
        statusMessage = "已删除 \(set.count) 个节点"
    }

    /// 点击节点 → 选中并弹出模型配置面板（对齐 OpenMinis 手机端交互）
    func presentModelPanel(for nodeID: UUID) {
        selectedNodeIDs = [nodeID]
        modelPanelNodeID = nodeID
    }

    func closeModelPanel() {
        modelPanelNodeID = nil
    }

    /// 更新节点级模型配置（面板点选即生效）
    func updateBackendConfig(_ config: NodeBackendConfig, for nodeID: UUID) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        graph.nodes[index].backendConfig = config
    }

    /// 清空节点模型配置 → 跟随全局默认
    func clearBackendConfig(for nodeID: UUID) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        graph.nodes[index].backendConfig = nil
    }

    /// 一键生成漫剧流水线：模板工厂生成完整骨架（小说→…→生视频 + 资产锁定注入），替换当前画布
    func installManjuPipeline() {
        graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        selectedNodeIDs = []
        nodeErrors = [:]
        statusMessage = "已生成漫剧流水线：\(graph.nodes.count) 节点 · \(graph.edges.count) 连线"
        showToast("漫剧流水线已生成，从小说导入节点开始")
        requestFit()
    }

    /// 一键漫剧流水线（M1d）：ManjuPipeline.standardPipeline() 全流程 9 节点图，追加模式。
    /// 新节点整体偏移到已有内容右侧，不覆盖已有节点；节点自带分层布局与默认模型配置，
    /// 生图节点模型统一为 gpt-image-2-official（与 NodeTypeRegistry 徽标约定一致）。
    func createPipeline() {
        var pipeline = ManjuPipeline.standardPipeline()
        // 追加偏移：流水线整体放在已有内容右侧（留一列间距），空画布直接用自带位置
        if let maxX = graph.nodes.map(\.position.x).max() {
            let minX = pipeline.nodes.map(\.position.x).min() ?? 120
            let offset = maxX + 280 - minX
            for index in pipeline.nodes.indices {
                pipeline.nodes[index].position.x += offset
            }
        }
        // 默认模型规范化：gimage2 后端默认模型 → gpt-image-2-official（徽标展示约定）
        for index in pipeline.nodes.indices where pipeline.nodes[index].type == ManjuNodeType.imageGen.rawValue {
            if var config = pipeline.nodes[index].backendConfig, config.modelID == "gimage2" {
                config.modelID = "gpt-image-2-official"
                pipeline.nodes[index].backendConfig = config
            }
        }
        for node in pipeline.nodes { graph.addNode(node) }
        for edge in pipeline.edges { graph.addEdge(edge) }
        if let first = pipeline.nodes.first(where: { $0.type == ManjuNodeType.novelImport.rawValue })?.id {
            selectedNodeIDs = [first]
        }
        statusMessage = "漫剧流水线已生成，从'小说导入'节点开始"
        showToast("漫剧流水线已生成，从小说导入节点开始")
        requestFit()
    }

    // MARK: - 模板库（M1h：漫剧全流程 / 仅提示词 / 仅生图）

    /// 请求画布自动缩放到全图（fit bounds；CanvasView 观察 fitRequestID 后执行）
    func requestFit() {
        fitRequestID += 1
    }

    /// 底部 toast 提示（3.5 秒后由 ContentView 的 .task(id:) 自动清除）
    func showToast(_ text: String) {
        toastMessage = text
    }

    /// 模板库一键生成：用所选模板替换当前画布（覆盖模式），清空选中/错误/导入结果，
    /// toast 提示并自动缩放到全图。
    func installTemplate(_ template: PipelineTemplate) {
        graph = makeTemplateGraph(template)
        selectedNodeIDs = []
        nodeErrors = [:]
        context.importedOutputs.removeAll()
        statusMessage = template.toastMessage
        showToast(template.toastMessage)
        requestFit()
    }

    /// 按模板构建新图（替换模式）；生图节点模型统一规范为 gpt-image-2-official（徽标约定）
    func makeTemplateGraph(_ template: PipelineTemplate) -> NodeGraph {
        switch template {
        case .fullPipeline:
            return normalizedPipeline(ManjuPipeline.standardPipeline())
        case .promptsOnly:
            return promptsOnlyGraph()
        case .generationOnly:
            return generationOnlyGraph()
        }
    }

    /// 全流程模板模型规范化：gimage2 后端默认模型 → gpt-image-2-official
    private func normalizedPipeline(_ pipeline: NodeGraph) -> NodeGraph {
        var graph = pipeline
        for index in graph.nodes.indices where graph.nodes[index].type == ManjuNodeType.imageGen.rawValue {
            if var config = graph.nodes[index].backendConfig, config.modelID == "gimage2" {
                config.modelID = "gpt-image-2-official"
                graph.nodes[index].backendConfig = config
            }
        }
        return graph
    }

    /// 仅提示词模板：图片提示词（8 槽）+ 视频提示词（9 槽），注入槽位系统提示词
    private func promptsOnlyGraph() -> NodeGraph {
        var graph = NodeGraph()
        let imagePrompt = CanvasNode(
            type: ManjuNodeType.imagePrompt.rawValue,
            title: "图片提示词",
            position: Point(x: 120, y: 120),
            inputs: [Port(name: "storyboard", direction: .input, dataType: "string")],
            outputs: [Port(name: "prompt", direction: .output, dataType: "string")],
            backendConfig: promptConfig(systemPrompt: ManjuPromptTemplates.imageSystemPrompt)
        )
        let videoPrompt = CanvasNode(
            type: ManjuNodeType.videoPrompt.rawValue,
            title: "视频提示词",
            position: Point(x: 120, y: 340),
            inputs: [Port(name: "storyboard", direction: .input, dataType: "string")],
            outputs: [Port(name: "prompt", direction: .output, dataType: "string")],
            backendConfig: promptConfig(systemPrompt: ManjuPromptTemplates.videoSystemPrompt)
        )
        graph.addNode(imagePrompt)
        graph.addNode(videoPrompt)
        return graph
    }

    /// 仅生图模板：生图 → 生视频（I2V 首帧）→ QC检查（生成尾链）
    private func generationOnlyGraph() -> NodeGraph {
        var graph = NodeGraph()
        let imageGen = CanvasNode(
            type: ManjuNodeType.imageGen.rawValue,
            title: "生图",
            position: Point(x: 120, y: 120),
            inputs: [Port(name: "prompt", direction: .input, dataType: "string")],
            outputs: [Port(name: "image", direction: .output, dataType: "string")],
            backendConfig: imageGenConfig()
        )
        let videoGen = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue,
            title: "生视频",
            position: Point(x: 380, y: 120),
            inputs: [Port(name: "prompt", direction: .input, dataType: "string"),
                     Port(name: "image", direction: .input, dataType: "string")],
            outputs: [Port(name: "video", direction: .output, dataType: "string")],
            backendConfig: ManjuPipeline.defaultVideoGenConfig
        )
        let qcCheck = CanvasNode(
            type: ManjuNodeType.qcCheck.rawValue,
            title: "QC检查",
            position: Point(x: 640, y: 120),
            inputs: [Port(name: "video", direction: .input, dataType: "string")],
            outputs: [Port(name: "report", direction: .output, dataType: "string")],
            backendConfig: ManjuPipeline.defaultLLMConfig
        )
        graph.addNode(imageGen)
        graph.addNode(videoGen)
        graph.addNode(qcCheck)
        connect(imageGen, "image", to: videoGen, "image", in: &graph)
        connect(videoGen, "video", to: qcCheck, "video", in: &graph)
        return graph
    }

    /// 提示词节点配置：默认 LLM + 注入槽位系统提示词
    private func promptConfig(systemPrompt: String) -> NodeBackendConfig {
        var config = ManjuPipeline.defaultLLMConfig
        config.params[ManjuPipelineTemplate.systemPromptKey] = systemPrompt
        return config
    }

    /// 生图节点配置：gimage2 后端 + gpt-image-2-official 模型（徽标约定）
    private func imageGenConfig() -> NodeBackendConfig {
        var config = ManjuPipeline.defaultImageGenConfig
        config.modelID = "gpt-image-2-official"
        return config
    }

    /// 按端口名连线（模板内部自洽校验；端口不匹配即断言暴露）
    private func connect(
        _ from: CanvasNode,
        _ fromPortName: String,
        to: CanvasNode,
        _ toPortName: String,
        in graph: inout NodeGraph
    ) {
        guard
            let fromPort = from.outputs.first(where: { $0.name == fromPortName }),
            let toPort = to.inputs.first(where: { $0.name == toPortName })
        else {
            assertionFailure("模板连线端口不匹配：\(from.type).\(fromPortName) → \(to.type).\(toPortName)")
            return
        }
        graph.addEdge(Edge(fromNode: from.id, fromPort: fromPort.id,
                           toNode: to.id, toPort: toPort.id))
    }

    /// 更新画布资产后重新注入资产锁定到各提示词节点
    func reapplyLockedAssets(_ assets: ManjuAssetLibrary) {
        graph = ManjuAssetInjection.applyLockedAssets(assets, to: graph)
        statusMessage = "资产锁定已重新注入"
    }

    /// 点击空白处：取消选中并结束拖拽连线
    func deselectAll() {
        selectedNodeIDs = []
        pendingEdge = nil
    }

    // MARK: - 连线操作

    /// 开始拖线创建连线：只允许从输出端口发起（输入端口是连线落点，防止拖出反向边）
    func beginEdge(from nodeID: UUID, portID: UUID, at point: Point) {
        guard let node = graph.node(id: nodeID),
              node.outputs.contains(where: { $0.id == portID }) else { return }
        pendingEdge = PendingEdge(fromNode: nodeID, fromPort: portID, end: point)
    }

    func updateEdgeEnd(_ point: Point) {
        pendingEdge?.end = point
    }

    /// 结束连线：若落在某节点输入端口附近则创建 Edge，否则丢弃
    func endEdge(at point: Point) {
        defer { pendingEdge = nil }
        guard let pending = pendingEdge else { return }
        let tolerance: Double = 22.0
        for node in graph.nodes where node.id != pending.fromNode {
            for port in node.inputs {
                let anchor = portAnchor(for: node, port: port)
                let dx = anchor.x - point.x
                let dy = anchor.y - point.y
                if dx * dx + dy * dy <= tolerance * tolerance {
                    // 防重复
                    let exists = graph.edges.contains {
                        $0.fromNode == pending.fromNode && $0.fromPort == pending.fromPort
                            && $0.toNode == node.id && $0.toPort == port.id
                    }
                    if !exists {
                        graph.addEdge(Edge(fromNode: pending.fromNode, fromPort: pending.fromPort,
                                            toNode: node.id, toPort: port.id))
                        statusMessage = "已连接 \(node.title)"
                    }
                    return
                }
            }
        }
    }

    /// 删除单条连线（点击连线时只删该条，不误伤节点其他连线）
    func removeEdge(id: UUID) {
        graph.edges.removeAll { $0.id == id }
    }

    func removeEdges(touching nodeID: UUID) {
        graph.edges.removeAll { $0.fromNode == nodeID || $0.toNode == nodeID }
    }

    // MARK: - 端口锚点（画布坐标）

    /// 计算端口在画布上的锚点位置（与 NodeView 渲染布局一致）
    func portAnchor(for node: CanvasNode, port: CanvasCore.Port) -> Point {
        let width = NodeMetrics.nodeWidth
        let headerHeight = NodeMetrics.headerHeight
        let rowHeight = NodeMetrics.rowHeight
        let rowIndex: Int
        if port.direction == .input {
            rowIndex = node.inputs.firstIndex(where: { $0.id == port.id }) ?? 0
        } else {
            rowIndex = node.outputs.firstIndex(where: { $0.id == port.id }) ?? 0
        }
        let localY = headerHeight + Double(rowIndex) * rowHeight + rowHeight / 2
        let localX = port.direction == .input ? 0 : width
        return Point(x: node.position.x + localX, y: node.position.y + localY)
    }

    // MARK: - 自动布局

    /// 自动布局：整图重排。GraphLayout.layeredLayout 只重排 position == .zero 的节点，
    /// 而点选添加的节点自带默认位置（视为"手动"），所以先清空全部位置再布局，
    /// 保证工具栏"自动布局"对任意画布都生效；完成后自动缩放到全图。
    func autoLayout() {
        do {
            for index in graph.nodes.indices {
                graph.nodes[index].position = .zero
            }
            let positions = try GraphLayout.layeredLayout(graph: graph)
            for index in graph.nodes.indices {
                if let pos = positions[graph.nodes[index].id] {
                    graph.nodes[index].position = pos
                }
            }
            statusMessage = "自动布局完成：\(graph.nodes.count) 节点 · \(graph.edges.count) 连线"
            requestFit()
        } catch {
            statusMessage = "自动布局失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 执行

    /// 执行一次完整调度（DAGScheduler.run → applying 写回状态）。
    /// 断点续跑：上次已 succeeded 的节点经 resumeFrom 跳过，不再重复执行（缓存输出直接恢复）。
    /// 失败节点错误信息从执行上下文回写到 nodeErrors，供 UI 失败提示。
    ///
    /// I7 P0-3：调度移到后台线程（Task.detached）——DAGScheduler.run 为同步接口，
    /// 主线程不再阻塞等待（真实 LLM 最长 300s 也不冻结 UI）；结果经 MainActor.run 回写状态。
    func runGraph() {
        guard !graph.nodes.isEmpty else {
            statusMessage = "画布为空，请先添加节点"
            return
        }
        isRunning = true
        statusMessage = "执行中…"
        let box = GraphRunBox(
            scheduler: scheduler,
            context: context,
            runGraph: graph,
            applyGraph: graph,
            resumeFrom: Set(graph.nodes.filter { $0.status == .succeeded }.map(\.id))
        )
        executeGraph(box)
    }

    /// 执行到此处：只跑目标节点及其全部传递上游（闭包子图），其余节点状态不动。
    func runToNode(_ nodeID: UUID) {
        guard graph.node(id: nodeID) != nil else { return }
        isRunning = true
        statusMessage = "执行到此处…"
        // 闭包：目标节点 + 全部传递上游
        var closure: Set<UUID> = [nodeID]
        var stack = [nodeID]
        while let current = stack.popLast() {
            for pred in graph.predecessors(of: current) where closure.insert(pred.id).inserted {
                stack.append(pred.id)
            }
        }
        let subgraph = NodeGraph(
            nodes: graph.nodes.filter { closure.contains($0.id) },
            edges: graph.edges.filter { closure.contains($0.fromNode) && closure.contains($0.toNode) }
        )
        let box = GraphRunBox(
            scheduler: scheduler,
            context: context,
            runGraph: subgraph,
            applyGraph: graph,   // 完整画布：applying 只覆盖闭包内节点，其余状态保留
            resumeFrom: []
        )
        executeGraph(box)
    }

    /// I7 P0-3：后台执行 + 主线程回写。
    /// - `Task.detached`：同步调度（DAGScheduler.run → context 同步桥）在后台线程跑，
    ///   不占主线程；桥接本身用 `Task.detached` 启动（CanvasCore 下沉实现），
    ///   不继承 MainActor 隔离，信号量等待不会死锁
    /// - `MainActor.run`：状态回写串行在主线程（@MainActor store，无竞态）
    private func executeGraph(_ box: GraphRunBox) {
        Task.detached(priority: .userInitiated) { [box] in
            do {
                var scheduler = box.scheduler
                let result = try scheduler.run(
                    graph: box.runGraph, context: box.context, resumeFrom: box.resumeFrom
                )
                box.scheduler = scheduler
                box.result = result
                box.appliedGraph = scheduler.applying(result, to: box.applyGraph)
            } catch {
                box.errorMessage = error.localizedDescription
            }
            await MainActor.run { [weak self, box] in
                self?.finishGraphRun(box)
            }
        }
    }

    /// 主线程回写执行结果：成功（调度器缓存/结果/节点状态图/错误同步/汇总）或失败信息
    private func finishGraphRun(_ box: GraphRunBox) {
        if let errorMessage = box.errorMessage {
            statusMessage = "执行失败：\(errorMessage)"
        } else if let result = box.result, let appliedGraph = box.appliedGraph {
            scheduler = box.scheduler
            lastResult = result
            graph = appliedGraph
            syncNodeErrors()
            syncGeneratedResults()
            summarize(result.statuses)
        }
        isRunning = false
    }

    /// 从执行上下文同步节点错误信息到可观察属性（供 UI 失败提示）
    private func syncNodeErrors() {
        nodeErrors = context.lastErrors
    }

    /// 真实生图结果回填（M1g）：把生图节点 outputs 的图片路径/URL 同步到
    /// backendConfig.params（与 importResult 相同的键约定），画布显示缩略图，
    /// 且下游生视频节点经 importedImagePath 把生成图当首帧参考（生图→生视频链路）。
    private func syncGeneratedResults() {
        guard let result = lastResult else { return }
        for (nodeID, outputs) in result.outputs {
            guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }),
                  outputs["status"] as? String == "succeeded",
                  let path = outputs["image"] as? String, !path.isEmpty
            else { continue }
            let nodeType = graph.nodes[index].type
            guard nodeType == "image" || nodeType == ManjuNodeType.imageGen.rawValue else { continue }
            var config = graph.nodes[index].backendConfig ?? NodeBackendConfig()
            config.params["result.path"] = path
            config.params["result.kind"] = "image"
            config.params["result.name"] = (path as NSString).lastPathComponent
            graph.nodes[index].backendConfig = config
        }
    }

    /// 汇总执行结果到状态栏（成功 / 失败 / 跳过）
    private func summarize(_ statuses: [UUID: NodeStatus]) {
        let ok = statuses.values.filter { $0 == .succeeded }.count
        let failed = statuses.values.filter { $0 == .failed }.count
        let skipped = statuses.values.filter { $0 == .skipped }.count
        statusMessage = "执行完成：成功 \(ok) / 失败 \(failed) / 跳过 \(skipped)"
    }

    /// 重置所有节点状态为 pending，并清空错误信息
    func resetStatuses() {
        for index in graph.nodes.indices {
            graph.nodes[index].status = .pending
        }
        nodeErrors = [:]
        statusMessage = "已重置状态"
    }

    /// 重置单个节点状态（节点右键菜单用）：状态 → pending，清空该节点错误
    func resetNodeStatus(_ nodeID: UUID) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        graph.nodes[index].status = .pending
        nodeErrors[nodeID] = nil
        statusMessage = "已重置节点状态"
    }

    // MARK: - 任务单（M1f）

    /// 生图/生视频节点是否为任务单模式节点
    func isJobTicketNode(_ nodeID: UUID) -> Bool {
        guard let node = graph.node(id: nodeID),
              let type = ManjuNodeType(rawValue: node.type) else { return false }
        return type == .imageGen || type == .videoGen
    }

    /// 构建节点任务单：完整提示词（8槽/9槽）+ FORBID 段 + 参考图锁定清单 + 平台建议。
    /// 提示词优先取上游提示词节点输出（含槽位标记则原样采用）；
    /// 未产出时用上游资产锁定槽位（`slot.<槽名>` 参数）兜底拼装，缺槽标「（待填）」。
    func jobTicket(for nodeID: UUID) -> JobTicket? {
        guard let node = graph.node(id: nodeID),
              let type = ManjuNodeType(rawValue: node.type),
              type == .imageGen || type == .videoGen else { return nil }
        let template = upstreamPromptTemplate(for: nodeID) ?? defaultTemplate(for: type)
        let promptText = upstreamPromptText(for: nodeID)
        let fallbackParams = upstreamPromptParams(for: nodeID)
        var references = JobTicket.extractReferenceIDs(from: promptText ?? "")
        // 生视频：上游生图节点导入的首帧结果文件也计入参考图（I2V 垫图）
        if type == .videoGen, let path = importedImagePath(for: nodeID) {
            references.append(path)
        }
        return JobTicket.make(
            node: node,
            template: template,
            promptText: promptText,
            fallbackParams: fallbackParams,
            referenceImages: references
        )
    }

    /// 一键复制任务单提示词全文（NSPasteboard）
    func copyPrompt(_ ticket: JobTicket) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ticket.copyableText, forType: .string)
        statusMessage = "提示词已复制（\(ticket.nodeTitle) · \(ticket.slotCount) 槽）"
    }

    /// 导出任务单为 .md 文件（含完整提示词 + FORBID 段 + 参考图锁定清单 + 铁律说明）
    func exportTicket(_ ticket: JobTicket, to url: URL) {
        do {
            try ticket.markdown.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "任务单已导出：\(url.lastPathComponent)"
        } catch {
            statusMessage = "任务单导出失败：\(error.localizedDescription)"
        }
    }

    /// 导入结果回填：把网页端生成的文件路径存入节点 backendConfig.params（画布显示缩略图），
    /// 并写入执行上下文 importedOutputs（下游节点可读取该输出）。
    func importResult(into nodeID: UUID, from url: URL) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        let ext = url.pathExtension.lowercased()
        let imageExts = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"]
        let videoExts = ["mp4", "mov", "m4v", "webm", "avi"]
        let isImage = imageExts.contains(ext)
        let isVideo = videoExts.contains(ext)
        guard isImage || isVideo else {
            statusMessage = "不支持的文件类型：\(ext)。支持：图片 png/jpg/jpeg/heic/gif/webp/tiff，视频 mp4/mov/m4v/webm/avi"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "文件不存在：\(url.lastPathComponent)"
            return
        }
        var config = graph.nodes[index].backendConfig ?? NodeBackendConfig()
        config.params["result.path"] = url.path
        config.params["result.kind"] = isImage ? "image" : "video"
        config.params["result.name"] = url.lastPathComponent
        graph.nodes[index].backendConfig = config
        // 下游可读：按节点输出端口名写入（imageGen → "image"，videoGen → "video"）
        let portName = isImage ? "image" : "video"
        context.importedOutputs[nodeID] = [portName: url.path, "status": "imported"]
        statusMessage = "已导入结果：\(url.lastPathComponent)"
    }

    // MARK: 任务单构建辅助

    /// 上游提示词节点（经 prompt 输入边连接，类型为 imagePrompt/videoPrompt）
    private func upstreamPromptNode(for nodeID: UUID) -> CanvasNode? {
        guard let node = graph.node(id: nodeID) else { return nil }
        for edge in graph.incomingEdges(to: nodeID) {
            guard let toPort = node.inputs.first(where: { $0.id == edge.toPort }),
                  toPort.name == "prompt" else { continue }
            if let upstream = graph.node(id: edge.fromNode),
               let type = ManjuNodeType(rawValue: upstream.type),
               type == .imagePrompt || type == .videoPrompt {
                return upstream
            }
        }
        return nil
    }

    /// 上游提示词节点输出文本（兼容输出端口名 prompt/text 两种命名）
    private func upstreamPromptText(for nodeID: UUID) -> String? {
        guard let upstream = upstreamPromptNode(for: nodeID) else { return nil }
        for edge in graph.edges where edge.fromNode == upstream.id && edge.toNode == nodeID {
            guard let outPort = upstream.outputs.first(where: { $0.id == edge.fromPort }),
                  let output = lastResult?.outputs[upstream.id] else { continue }
            let value = output[outPort.name] ?? output["text"] ?? output["prompt"]
            if let value, !String(describing: value).isEmpty {
                return String(describing: value)
            }
        }
        return nil
    }

    /// 上游提示词节点的资产锁定槽位参数（`slot.<槽名>` + systemPrompt）
    private func upstreamPromptParams(for nodeID: UUID) -> [String: String] {
        guard let upstream = upstreamPromptNode(for: nodeID) else { return [:] }
        let params = upstream.backendConfig?.params ?? [:]
        // 只保留任务单需要的关键字，避免把无关参数拼进提示词
        let kept = params.filter { key, _ in
            key.hasPrefix(ManjuAssetInjection.slotKeyPrefix) || key == ManjuPipelineTemplate.systemPromptKey
        }
        return kept
    }

    /// 槽位模板：优先上游提示词节点模板（8槽图片/9槽视频），否则按节点类型取默认模板
    private func upstreamPromptTemplate(for nodeID: UUID) -> ManjuTemplate? {
        guard let upstream = upstreamPromptNode(for: nodeID),
              let type = ManjuNodeType(rawValue: upstream.type) else { return nil }
        return ManjuPromptTemplates.template(for: type)
    }

    /// 按节点类型取默认槽位模板（生图 → 图片 8 槽，生视频 → 视频 9 槽）
    private func defaultTemplate(for type: ManjuNodeType) -> ManjuTemplate {
        if type == .imageGen {
            return ManjuTemplate(
                nodeType: .imageGen,
                slots: ManjuPromptTemplates.imageSlots,
                systemPrompt: ManjuPromptTemplates.imageSystemPrompt
            )
        }
        return ManjuTemplate(
            nodeType: .videoGen,
            slots: ManjuPromptTemplates.videoSlots,
            systemPrompt: ManjuPromptTemplates.videoSystemPrompt
        )
    }

    /// 生视频节点的 image 输入：上游生图节点导入的结果文件路径（I2V 首帧）
    private func importedImagePath(for nodeID: UUID) -> String? {
        guard let node = graph.node(id: nodeID) else { return nil }
        for edge in graph.incomingEdges(to: nodeID) {
            guard let toPort = node.inputs.first(where: { $0.id == edge.toPort }),
                  toPort.name == "image" else { continue }
            if let upstream = graph.node(id: edge.fromNode),
               let path = upstream.backendConfig?.params["result.path"] {
                return path
            }
        }
        return nil
    }
}

// MARK: - 节点渲染度量（与 CanvasView 共用）

enum NodeMetrics {
    /// 节点宽度（画布坐标，未缩放）
    static let nodeWidth = 200.0
    /// 标题区高度
    static let headerHeight = 34.0
    /// 端口行高
    static let rowHeight = 26.0
    /// 底部留白
    static let bottomPadding = 12.0

    /// 节点总高（按端口行数）
    static func nodeHeight(inputs: Int, outputs: Int) -> Double {
        headerHeight + Double(max(inputs, outputs)) * rowHeight + bottomPadding
    }
}

// MARK: - 后台执行盒（I7 P0-3）

/// 后台执行盒：DAGScheduler / DAGExecutionResult 含非 Sendable 的 AnyHashable
/// （CanvasCore 未做 Sendable 约束），经 @unchecked Sendable 盒在
/// Task.detached（后台调度）与 MainActor（状态回写）之间传递，规避 Swift 6 跨 actor 约束。
private final class GraphRunBox: @unchecked Sendable {
    var scheduler: DAGScheduler
    let context: GraphExecutionContext
    /// 调度执行的图（runToNode 时为闭包子图；runGraph 时与 applyGraph 相同）
    let runGraph: NodeGraph
    /// 结果回写目标图（完整画布：applying 只覆盖 runGraph 内节点，其余状态保留）
    let applyGraph: NodeGraph
    let resumeFrom: Set<UUID>
    var result: DAGExecutionResult?
    var appliedGraph: NodeGraph?
    var errorMessage: String?

    init(
        scheduler: DAGScheduler,
        context: GraphExecutionContext,
        runGraph: NodeGraph,
        applyGraph: NodeGraph,
        resumeFrom: Set<UUID>
    ) {
        self.scheduler = scheduler
        self.context = context
        self.runGraph = runGraph
        self.applyGraph = applyGraph
        self.resumeFrom = resumeFrom
    }
}
