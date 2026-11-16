import Foundation

// MARK: - 错误类型

/// 调度器错误
public enum DAGSchedulerError: Error, Equatable, Sendable, LocalizedError {
    /// 图中存在环，无法确定执行顺序
    case cycleDetected
    /// 边引用了不存在的节点
    case nodeNotFound(UUID)
    /// 调度请求针对的图 revision 已变化
    case graphRevisionMismatch(expected: Int, actual: Int)
    /// 调度请求针对的图内容已变化
    case graphFingerprintMismatch(expected: String, actual: String)
    /// 普通 DAG 执行信封无效或与当前图不匹配
    case invalidExecutionEnvelope
    /// 执行信封声明的画布/运行身份不能用于当前结果写回
    case executionIdentityMismatch(DAGWritebackRejection)

    public var errorDescription: String? {
        switch self {
        case .cycleDetected:
            return "图中存在环，无法确定执行顺序"
        case .nodeNotFound(let id):
            return "引用了不存在的节点：\(id)"
        case let .graphRevisionMismatch(expected, actual):
            return "图 revision 不匹配：期望 \(expected)，实际 \(actual)"
        case let .graphFingerprintMismatch(expected, actual):
            return "图 fingerprint 不匹配：期望 \(expected)，实际 \(actual)"
        case .invalidExecutionEnvelope:
            return "DAG 执行信封无效或与当前图不匹配"
        case let .executionIdentityMismatch(rejection):
            return "DAG 执行身份不匹配：\(rejection.rawValue)"
        }
    }
}

// MARK: - 节点执行上下文

/// 节点执行上下文：调度器通过它调用节点的实际逻辑。
/// 本层只做调度编排，不实现具体节点逻辑；具体节点由遵循该协议的执行器提供。
public protocol NodeExecutionContext {
    /// 解析节点的输入值（按边从上游节点输出收集，端口语义由执行器自行处理）。
    /// - Parameters:
    ///   - node: 待解析输入的节点
    ///   - graph: 当前节点图
    ///   - outputs: 按节点 ID 获取该节点已产出的输出值（含缓存命中与断点续跑场景；无输出返回 nil）
    /// - Returns: 节点输入字典（端口名 → 值），无输入时返回 nil
    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (UUID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]?

    /// 执行节点实际逻辑。
    /// - Parameters:
    ///   - node: 待执行节点
    ///   - inputs: resolveInputs 解析出的输入
    /// - Returns: 节点输出字典（端口名 → 值），会被写入结果缓存
    /// - Throws: 执行失败时抛出错误，调度器将把该节点标记为 failed 并跳过其全部下游
    func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable]
}

/// Optional execution-context bridge for callers that have a frozen run-level
/// envelope. Legacy contexts keep using `NodeExecutionContext.execute`.
public protocol DAGExecutionEnvelopeNodeExecutionContext: NodeExecutionContext {
    func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        executionEnvelope: DAGExecutionEnvelope
    ) throws -> [String: AnyHashable]
}

// MARK: - 执行结果

/// 调度执行事件：逐节点反馈流（等价 ComfyUI `executing` / `execution_cached` /
/// `execution_error` / `execution_interrupted` 事件）。在 `run` 同步执行过程中
/// 按顺序回调，UI 据此实时高亮当前节点 / 灰显缓存命中节点 / 显示进度。
public enum DAGExecutionEvent: Codable, Equatable, Sendable {
    /// 节点开始执行（ComfyUI `executing {node}`）
    case nodeStarted(UUID)
    /// 节点执行完成（成功）
    case nodeFinished(UUID)
    /// 节点缓存命中，直接复用结果不重跑（ComfyUI `execution_cached`）
    case nodeCached(UUID)
    /// 节点执行失败
    case nodeFailed(UUID)
    /// 节点被跳过（上游失败 / 中断）
    case nodeSkipped(UUID)
    /// 执行被中断：剩余节点全部跳过（ComfyUI `execution_interrupted`）
    case cancelled

    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public var schemaVersion: Int { Self.currentSchemaVersion }

    private enum CodingKeys: String, CodingKey { case schemaVersion, kind, nodeID }
    private enum Kind: String, Codable {
        case nodeStarted, nodeFinished, nodeCached, nodeFailed, nodeSkipped, cancelled
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CanvasSchema.currentVersion, forKey: .schemaVersion)
        switch self {
        case let .nodeStarted(id): try c.encode(Kind.nodeStarted, forKey: .kind); try c.encode(id, forKey: .nodeID)
        case let .nodeFinished(id): try c.encode(Kind.nodeFinished, forKey: .kind); try c.encode(id, forKey: .nodeID)
        case let .nodeCached(id): try c.encode(Kind.nodeCached, forKey: .kind); try c.encode(id, forKey: .nodeID)
        case let .nodeFailed(id): try c.encode(Kind.nodeFailed, forKey: .kind); try c.encode(id, forKey: .nodeID)
        case let .nodeSkipped(id): try c.encode(Kind.nodeSkipped, forKey: .kind); try c.encode(id, forKey: .nodeID)
        case .cancelled: try c.encode(Kind.cancelled, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .nodeStarted: self = .nodeStarted(try c.decode(UUID.self, forKey: .nodeID))
        case .nodeFinished: self = .nodeFinished(try c.decode(UUID.self, forKey: .nodeID))
        case .nodeCached: self = .nodeCached(try c.decode(UUID.self, forKey: .nodeID))
        case .nodeFailed: self = .nodeFailed(try c.decode(UUID.self, forKey: .nodeID))
        case .nodeSkipped: self = .nodeSkipped(try c.decode(UUID.self, forKey: .nodeID))
        case .cancelled: self = .cancelled
        }
    }
}

/// 一次调度执行的结果
public struct DAGExecutionResult {
    /// 各节点最终状态
    public var statuses: [UUID: NodeStatus]
    /// 各节点输出值（succeeded / cached 且有输出的节点；闸口失败节点（BLOCKED / QC FAIL）
    /// 的输出也保留——上层据此写回节点内容与生成闸口回执）
    public var outputs: [UUID: [String: AnyHashable]]
    /// 本次执行是否被中断（剩余节点被跳过）
    public var wasCancelled: Bool
    /// F2-②：被跳过节点的原因（nodeID → 可读原因）。来源：上游闸口 BLOCKED /
    /// QC FAIL / 上游执行失败 / 上游被跳过（级联）/ 执行中断。未跳过节点无条目。
    public var skipReasons: [UUID: String]
    /// 本次执行冻结的 run-level envelope；nil 仅表示旧兼容调用方未提供 envelope。
    public let executionEnvelope: DAGExecutionEnvelope?

    public init(
        statuses: [UUID: NodeStatus],
        outputs: [UUID: [String: AnyHashable]],
        wasCancelled: Bool = false,
        skipReasons: [UUID: String] = [:],
        executionEnvelope: DAGExecutionEnvelope? = nil
    ) {
        self.statuses = statuses
        self.outputs = outputs
        self.wasCancelled = wasCancelled
        self.skipReasons = skipReasons
        self.executionEnvelope = executionEnvelope
    }

    public func status(of nodeID: UUID) -> NodeStatus {
        statuses[nodeID] ?? .pending
    }

    public func output(of nodeID: UUID) -> [String: AnyHashable]? {
        outputs[nodeID]
    }

    /// 被跳过节点的可读原因（未被跳过返回 nil）
    public func skipReason(of nodeID: UUID) -> String? {
        skipReasons[nodeID]
    }
}

// MARK: - 调度器

/// 有向无环图调度器：拓扑排序 / 分层 / 断点续跑 / 失败跳过 / 节点级结果缓存。
/// 注：因结果值使用 `AnyHashable`（非 Sendable），本结构不做 Sendable 约束；
/// 本层为同步调度，无跨 actor 传递需求。
public struct DAGScheduler {

    /// 节点级结果缓存：key = 节点类型 + 输入哈希（见 `cacheKey`），value = 节点输出
    private var cache: [String: [String: AnyHashable]]

    public init(cache: [String: [String: AnyHashable]] = [:]) {
        self.cache = cache
    }

    // MARK: - 静态分析

    /// Kahn 拓扑排序：返回按依赖排序的节点 ID 列表。
    /// 有环时抛出 `.cycleDetected`；边引用不存在的节点时抛出 `.nodeNotFound`。
    public static func topologicalSort(in graph: NodeGraph) throws -> [UUID] {
        var inDegree: [UUID: Int] = [:]
        var adjacency: [UUID: [UUID]] = [:]

        for node in graph.nodes {
            inDegree[node.id] = 0
            adjacency[node.id] = []
        }
        for edge in graph.edges {
            guard inDegree[edge.fromNode] != nil else {
                throw DAGSchedulerError.nodeNotFound(edge.fromNode)
            }
            guard inDegree[edge.toNode] != nil else {
                throw DAGSchedulerError.nodeNotFound(edge.toNode)
            }
            inDegree[edge.toNode, default: 0] += 1
            adjacency[edge.fromNode, default: []].append(edge.toNode)
        }

        // 按图中出现顺序出队，保证结果确定性
        var queue: [UUID] = graph.nodes.compactMap { inDegree[$0.id] == 0 ? $0.id : nil }
        var result: [UUID] = []
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            result.append(current)
            for next in adjacency[current] ?? [] {
                inDegree[next, default: 0] -= 1
                if inDegree[next] == 0 {
                    queue.append(next)
                }
            }
        }

        if result.count != graph.nodes.count {
            throw DAGSchedulerError.cycleDetected
        }
        return result
    }

    /// 分层：同一层内节点互不依赖、可并行执行。返回 `[[UUID]]`，层号从 0 开始。
    /// 层号 = 最长依赖链深度（最长路径分层），保证所有边只从低层指向高层。
    public static func layers(in graph: NodeGraph) throws -> [[UUID]] {
        let order = try topologicalSort(in: graph)
        var layerOf: [UUID: Int] = [:]

        // 拓扑序保证前驱先于后继处理，层号可递推
        for nodeID in order {
            var layer = 0
            for pred in graph.predecessors(of: nodeID) {
                layer = max(layer, (layerOf[pred.id] ?? 0) + 1)
            }
            layerOf[nodeID] = layer
        }

        let count = (layerOf.values.max() ?? -1) + 1
        var result: [[UUID]] = Array(repeating: [], count: count)
        for nodeID in order {
            result[layerOf[nodeID] ?? 0].append(nodeID)
        }
        return result
    }

    // MARK: - 执行

    /// 逐层调度执行整个图：同层节点 running → succeeded / cached / failed / skipped。
    ///
    /// F2-② 闸口阻断：节点执行输出携带闸口失败信号（`blocked == "1"` 提示词结构闸口
    /// BLOCKED / `qc_status == "FAIL"` QC 校验失败 / reviewGate 审核 REJECT 或 PENDING，
    /// 见 `gateFailureReason` / `reviewGateFailureReason`）时，该节点
    /// 标记 `.failed`（输出仍保留在结果中供上层写回节点内容/生成回执），其全部下游
    /// 标记 `.skipped` 且**不执行执行器**，跳过原因写入 `skipReasons`。执行失败（throw）
    /// 与中断的下游跳过同样记录可读原因。
    ///
    /// P0 局部重跑（画布逻辑补强）：`from` 非空时只执行该集合内节点及其（传递）下游，
    /// 其余节点不执行——输出从 `seedOutputs` 恢复（调用方传上次执行结果），状态沿用
    /// 图中原状态。等价 ComfyUI「改节点 A → 只重跑 A 及其下游，上游结果复用」：
    /// 上游 LLM 不重复烧 token，下游仍受结果缓存约束（输入未变 → cached 不重跑）。
    /// 未受影响节点不发执行事件（进度计数不含它们）；受影响节点的上游失败检查只
    /// 考虑受影响集合内的前驱——修复 A 后 A 自身不被旧的上游失败状态阻断。
    ///
    /// - Parameters:
    ///   - graph: 待执行的有向无环图
    ///   - context: 节点执行上下文（输入解析 + 节点逻辑）
    ///   - resumeFrom: 断点续跑——已成功节点集合，这些节点不再执行；
    ///                  若缓存中有其输出则直接恢复；其上游本次失败时仍会被跳过
    ///   - from: 局部重跑根节点集合（含其全部传递下游）；nil = 全图执行
    ///   - seedOutputs: 上次执行结果输出（节点 ID → 输出字典），`from` 非空时
    ///                  用于恢复未受影响节点的输出、供受影响节点解析上游输入
    ///   - onEvent: 逐节点进度回调（开始/完成/缓存命中/失败/跳过/中断），同步执行中按序触发
    ///   - isCancelled: 中断检查——每处理一个节点前询问；返回 true 时剩余节点全部跳过，
    ///                  结果 `wasCancelled = true`（等价 ComfyUI `/interrupt` + execution_interrupted）。
    ///                  注：本层为同步调度，只能做到节点间中断，不能打断正在执行的单个节点
    /// - Returns: 各节点最终状态、输出与被跳过节点的原因（`DAGExecutionResult.skipReasons`）
    public mutating func run(
        graph: NodeGraph,
        context: NodeExecutionContext,
        resumeFrom: Set<UUID> = [],
        from: Set<UUID>? = nil,
        seedOutputs: [UUID: [String: AnyHashable]] = [:],
        onEvent: (DAGExecutionEvent) -> Void = { _ in },
        isCancelled: () -> Bool = { false },
        expectedRevision: Int? = nil,
        expectedFingerprint: String? = nil,
        executionEnvelope: DAGExecutionEnvelope? = nil
    ) throws -> DAGExecutionResult {
        if let executionEnvelope {
            guard executionEnvelope.isValid else {
                throw DAGSchedulerError.invalidExecutionEnvelope
            }
            guard graph.revision == executionEnvelope.graphRevision else {
                throw DAGSchedulerError.graphRevisionMismatch(
                    expected: executionEnvelope.graphRevision,
                    actual: graph.revision
                )
            }
            guard graph.fingerprint == executionEnvelope.graphFingerprint else {
                throw DAGSchedulerError.graphFingerprintMismatch(
                    expected: executionEnvelope.graphFingerprint,
                    actual: graph.fingerprint
                )
            }
        }
        if let expectedRevision {
            guard graph.revision == expectedRevision else {
                throw DAGSchedulerError.graphRevisionMismatch(expected: expectedRevision, actual: graph.revision)
            }
        }
        if let expectedFingerprint {
            let actual = graph.fingerprint
            guard actual == expectedFingerprint else {
                throw DAGSchedulerError.graphFingerprintMismatch(expected: expectedFingerprint, actual: actual)
            }
        }
        // 前置校验：必须无环
        _ = try Self.topologicalSort(in: graph)

        // P0 局部重跑：受影响集合 = from ∪ 其全部传递下游；nil = 全图。
        let affected: Set<UUID>? = from.map { roots in
            var closure: Set<UUID> = roots
            var stack = Array(roots)
            while let current = stack.popLast() {
                for successor in graph.successors(of: current) where closure.insert(successor.id).inserted {
                    stack.append(successor.id)
                }
            }
            return closure
        }

        var statuses: [UUID: NodeStatus] = [:]
        var outputs: [UUID: [String: AnyHashable]] = seedOutputs
        var skipReasons: [UUID: String] = [:]
        for node in graph.nodes {
            statuses[node.id] = .pending
        }

        var wasCancelled = false
        for layer in try Self.layers(in: graph) {
            for nodeID in layer {
                // 中断检查：剩余全部跳过（ComfyUI interrupt 语义）
                if isCancelled() {
                    wasCancelled = true
                    onEvent(.cancelled)
                    for remaining in graph.nodes where statuses[remaining.id] == .pending {
                        statuses[remaining.id] = .skipped
                        skipReasons[remaining.id] = "执行中断（用户取消）"
                        onEvent(.nodeSkipped(remaining.id))
                    }
                    return DAGExecutionResult(
                        statuses: statuses, outputs: outputs, wasCancelled: true,
                        skipReasons: skipReasons,
                        executionEnvelope: executionEnvelope
                    )
                }

                guard let node = graph.node(id: nodeID) else {
                    throw DAGSchedulerError.nodeNotFound(nodeID)
                }

                // P0 局部重跑：非受影响节点不执行——输出从 seed 恢复，状态沿用图中原状态，
                // 不发执行事件（进度计数不含它们）。
                if let affected, !affected.contains(nodeID) {
                    if seedOutputs[nodeID] != nil { outputs[nodeID] = seedOutputs[nodeID] }
                    statuses[nodeID] = node.status
                    continue
                }

                // 上游失败 / 被跳过（含闸口 BLOCKED / QC FAIL 的级联）→ 本节点标记 skipped，不执行。
                // P0 局部重跑：只看受影响集合内的前驱——集合外（被修复节点的祖先）的原失败
                // 状态不阻断本次重跑。
                if let blocking = graph.predecessors(of: nodeID).first(where: {
                    if let affected, !affected.contains($0.id) { return false }
                    return statuses[$0.id] == .failed || statuses[$0.id] == .skipped
                }) {
                    statuses[nodeID] = .skipped
                    // 原因优先取失败/跳过传播时已写入的（更靠近根因），否则按直接上游推导
                    if skipReasons[nodeID] == nil {
                        skipReasons[nodeID] = Self.cascadeSkipReason(
                            predecessor: blocking,
                            predecessorStatus: statuses[blocking.id] ?? .pending,
                            predecessorReason: skipReasons[blocking.id]
                        )
                    }
                    onEvent(.nodeSkipped(nodeID))
                    continue
                }

                let inputs = try context.resolveInputs(for: node, in: graph) { outputs[$0] }
                let key = Self.cacheKey(node: node, inputs: inputs)

                // 断点续跑：已成功节点不执行，仅恢复缓存输出（有缓存 → cached，无 → succeeded）
                if resumeFrom.contains(nodeID) {
                    if let cached = cache[key] {
                        outputs[nodeID] = cached
                        statuses[nodeID] = .cached
                        onEvent(.nodeCached(nodeID))
                    } else {
                        statuses[nodeID] = .succeeded
                        onEvent(.nodeStarted(nodeID))
                        onEvent(.nodeFinished(nodeID))
                    }
                    continue
                }

                // 结果缓存：同输入命中缓存直接返回，标记 cached（UI 灰显，不重跑）。
                // 闸口失败输出不写缓存（见下），故缓存命中值不含闸口失败信号。
                if let cached = cache[key] {
                    outputs[nodeID] = cached
                    // 手动审核状态（review.status）优先：缓存命中 PASS 输出，但手动
                    // REJECT/PENDING 时仍视为审核未通过，拦截下游（不标记 cached）
                    if let gateReason = Self.reviewGateFailureReason(node: node, output: cached) {
                        statuses[nodeID] = .failed
                        onEvent(.nodeFailed(nodeID))
                        markDownstreamSkipped(
                            from: nodeID, graph: graph,
                            statuses: &statuses, skipReasons: &skipReasons,
                            directReason: "上游「\(node.title)」闸口未通过：\(gateReason)"
                        )
                        continue
                    }
                    statuses[nodeID] = .cached
                    onEvent(.nodeCached(nodeID))
                    continue
                }

                // 正常执行：running → succeeded / failed / 闸口失败
                statuses[nodeID] = .running
                onEvent(.nodeStarted(nodeID))
                do {
                    let output: [String: AnyHashable]
                    if let executionEnvelope,
                       let envelopeContext = context as? any DAGExecutionEnvelopeNodeExecutionContext {
                        output = try envelopeContext.execute(
                            node: node,
                            inputs: inputs,
                            executionEnvelope: executionEnvelope
                        )
                    } else {
                        output = try context.execute(node: node, inputs: inputs)
                    }
                    outputs[nodeID] = output
                    // F2-② 闸口信号：BLOCKED / QC FAIL / 审核未通过（REJECT / PENDING，
                    // 手动 review.status 优先于执行输出）→ 本节点 failed（输出保留供上层
                    // 写回内容与回执），全部下游 skipped 且不执行执行器；不写缓存
                    if let gateReason = Self.gateFailureReason(output: output)
                        ?? Self.reviewGateFailureReason(node: node, output: output) {
                        statuses[nodeID] = .failed
                        onEvent(.nodeFailed(nodeID))
                        markDownstreamSkipped(
                            from: nodeID, graph: graph,
                            statuses: &statuses, skipReasons: &skipReasons,
                            directReason: "上游「\(node.title)」闸口未通过：\(gateReason)"
                        )
                        continue
                    }
                    cache[key] = output
                    statuses[nodeID] = .succeeded
                    onEvent(.nodeFinished(nodeID))
                } catch {
                    statuses[nodeID] = .failed
                    onEvent(.nodeFailed(nodeID))
                    markDownstreamSkipped(
                        from: nodeID, graph: graph,
                        statuses: &statuses, skipReasons: &skipReasons,
                        directReason: "上游「\(node.title)」执行失败：\(error.localizedDescription)"
                    )
                }
            }
        }

        return DAGExecutionResult(
            statuses: statuses, outputs: outputs, wasCancelled: wasCancelled,
            skipReasons: skipReasons,
            executionEnvelope: executionEnvelope
        )
    }

    /// 将执行结果写回图（更新节点 status），返回新图。
    public func applying(_ result: DAGExecutionResult, to graph: NodeGraph) -> NodeGraph {
        var updated = graph
        for index in updated.nodes.indices {
            if let status = result.statuses[updated.nodes[index].id] {
                updated.nodes[index].status = status
            }
        }
        return updated
    }

    /// 受 envelope 保护的结果写回。目标 canvas/run/revision/fingerprint 任一
    /// 不匹配时返回 nil，调用方不得再以当前 canvas 猜测资产归属。
    public func applying(
        _ result: DAGExecutionResult,
        to graph: NodeGraph,
        currentEnvelope: DAGExecutionEnvelope,
        isCancelled: Bool = false
    ) -> NodeGraph? {
        guard let expected = result.executionEnvelope,
              graph.revision == currentEnvelope.graphRevision,
              graph.fingerprint == currentEnvelope.graphFingerprint,
              validateDAGWriteback(
                  expected: expected,
                  actual: currentEnvelope,
                  isCancelled: isCancelled
              ) == .accepted else {
            return nil
        }
        return applying(result, to: graph)
    }

    // MARK: - 缓存

    /// 当前缓存条目数
    public var cacheCount: Int { cache.count }

    /// 查询某节点的缓存输出（需提供与该节点相同的输入）
    public func cachedOutput(
        for node: CanvasNode,
        inputs: [String: AnyHashable]?
    ) -> [String: AnyHashable]? {
        cache[Self.cacheKey(node: node, inputs: inputs)]
    }

    /// 构造缓存 key：节点类型 + 节点 ID + **模型配置（backendConfig）** + 排序后的输入
    /// （`端口名=类型:值`）。
    ///
    /// - 含节点 ID：两个同类型、无输入的源节点（输出依赖自身标题/内容）不会互相串缓存；
    ///   同一节点输入变化时 key 随之变化，缓存自然失效。
    /// - 含模型配置（F2-①）：切换 Provider / 模型 / 参数后，旧模型的结果不得被复用——
    ///   providerID / modelID / providerType / params（键排序后稳定化）全部参与 key。
    ///   注：`content`（节点内容）与执行产物回填键（`result.*`）不参与 key——
    ///   前者经 resolveInputs 作为输入进入 key，后者仅是执行后回填的展示数据，
    ///   参与 key 会导致同配置重跑永远命中不了缓存（见 `backendConfigKey`）。
    /// - 值附带动态类型：`Int 5` 与 `String "5"` 的 `String(describing:)` 均为 `"5"`，
    ///   不带类型会错误命中同 key（输入类型不同结果可能不同）。
    /// - 值通过 `String(describing:)` 参与 key 计算，自定义值类型请保证描述稳定。
    public static func cacheKey(
        node: CanvasNode,
        inputs: [String: AnyHashable]?
    ) -> String {
        var parts = [node.type, node.id.uuidString, backendConfigKey(node.backendConfig)]
        let sorted = (inputs ?? [:]).sorted { $0.key < $1.key }
        for (name, value) in sorted {
            let typeName = String(describing: type(of: value.base))
            parts.append("\(name)=\(typeName):\(String(describing: value))")
        }
        return parts.joined(separator: "|")
    }

    /// backendConfig 的稳定化序列化（F2-① 缓存 key 组成部分）：
    /// providerType + providerID + modelID + params（键排序后逐项 `键=值`，确定性）。
    /// nil 配置与空配置不同串（nil = 使用全局默认，切换前后必须区分）。
    /// `content` / `result.*` 键剔除（见 `cacheKey` 注释）。
    static func backendConfigKey(_ config: NodeBackendConfig?) -> String {
        guard let config else { return "backend=none" }
        let excludedPrefixes = ["content", "result."]
        let params = config.params
            .filter { key, _ in !excludedPrefixes.contains { key == $0 || key.hasPrefix($0) } }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return "backend=\(config.providerType.rawValue)|\(config.providerID)|\(config.modelID)|{\(params)}"
    }

    /// 执行输出的闸口失败信号（F2-②）：命中任一即视为闸口未通过、下游不得执行。
    /// - `blocked == "1"`：提示词结构闸口 BLOCKED（LLMNodeExecutor.blockedOutput，铁律7）
    /// - `qc_status == "FAIL"`：QC 校验失败（QCNodeExecutor / ManjuQCStatus.fail）
    /// 返回可读失败原因（供 skipReasons / UI 展示），未命中返回 nil。
    /// 注：QC 任务单降级输出（qc_status == "待生成后复检"）不是 FAIL，不阻断。
    static func gateFailureReason(output: [String: AnyHashable]) -> String? {
        if let blocked = output["blocked"] as? String, blocked == "1" {
            let missing = output["missing_slots"] as? String
            let detail = (missing?.isEmpty == false) ? "缺字段：\(missing!)" : "未检测到 8/9 槽结构标记"
            return "提示词结构闸口 BLOCKED（\(detail)）"
        }
        if let qc = output["qc_status"] as? String, qc == ManjuQCStatus.fail.rawValue {
            let missing = output["missing_slots"] as? String
            let reasons = output["reasons"] as? String
            if let missing, !missing.isEmpty {
                return "QC FAIL（缺字段：\(missing)）"
            }
            if let reasons, !reasons.isEmpty {
                let firstLine = reasons.split(separator: "\n").first.map(String.init) ?? reasons
                return "QC FAIL（\(firstLine)）"
            }
            return "QC FAIL"
        }
        return nil
    }

    /// reviewGate 审核闸口失败信号：审核状态 `REJECT` / `PENDING` → 视为闸口未通过，
    /// 下游不得执行（`PASS` 正常放行）。审核状态取值优先级：
    /// 1. 手动审核状态 `backendConfig.params["review.status"]`（大写 PASS/REJECT/PENDING）；
    ///    nil = 未手动设置，跳过。
    /// 2. 否则取 reviewGate 节点执行输出 `status` 键（ReviewGateExecutor 产出）。
    /// 仅 reviewGate 类型节点参与判定；非 reviewGate 节点的 status 键（如
    /// "succeeded"/"blocked"）不触发。返回可读失败原因（供 skipReasons / UI 展示），
    /// 未命中返回 nil。
    static func reviewGateFailureReason(
        node: CanvasNode,
        output: [String: AnyHashable]
    ) -> String? {
        guard node.type == ManjuNodeType.reviewGate.rawValue else { return nil }
        let status = node.backendConfig?.params["review.status"] ?? (output["status"] as? String)
        switch status {
        case "REJECT":
            let reasons = output["reasons"] as? String
            if let reasons, !reasons.isEmpty {
                return "审核未通过（REJECT）：\(reasons)"
            }
            return "审核未通过（REJECT）"
        case "PENDING":
            return "审核待审（PENDING）"
        default:
            // PASS 或未知值：放行
            return nil
        }
    }

    /// 级联跳过原因推导：本节点因直接上游 `predecessor` 失败/被跳过而跳过时，
    /// 给出可读原因。上游失败传播时已写入 `skipReasons` 的根因描述优先沿用。
    private static func cascadeSkipReason(
        predecessor: CanvasNode,
        predecessorStatus: NodeStatus,
        predecessorReason: String?
    ) -> String {
        switch predecessorStatus {
        case .failed:
            return predecessorReason
                ?? "上游「\(predecessor.title)」执行失败"
        case .skipped:
            if let predecessorReason {
                // 沿链传播：上游的跳过原因通常已含根因节点名，前缀说明级联关系
                return predecessorReason.hasPrefix("上游「")
                    ? predecessorReason
                    : "上游「\(predecessor.title)」被跳过：\(predecessorReason)"
            }
            return "上游「\(predecessor.title)」被跳过"
        default:
            return "上游「\(predecessor.title)」未完成（状态：\(predecessorStatus)）"
        }
    }

    // MARK: - 私有

    /// 失败传播：把节点的所有（传递）下游标记为 skipped，并记录跳过原因。
    /// `directReason` 为根因描述（上游执行失败 / 闸口未通过），逐层原样传播。
    private func markDownstreamSkipped(
        from nodeID: UUID,
        graph: NodeGraph,
        statuses: inout [UUID: NodeStatus],
        skipReasons: inout [UUID: String],
        directReason: String
    ) {
        var visited: Set<UUID> = [nodeID]
        var stack: [UUID] = [nodeID]
        while let current = stack.popLast() {
            for successor in graph.successors(of: current) {
                guard visited.insert(successor.id).inserted else { continue }
                statuses[successor.id] = .skipped
                skipReasons[successor.id] = directReason
                stack.append(successor.id)
            }
        }
    }
}
