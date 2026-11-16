import Foundation

// MARK: - P2 分镜表工作台：聚合逻辑（CanvasCore 纯函数）
//
// 设计文档：issues/p2_storyboard_design_20260805.md §4
// 算法：y 排序找锚点 → 三形态判定（未展开/已展开/混合）→ BFS 下游收集
//      （剪枝防串镜、assetRef 共享例外、visited 防环）→ 字段填充。
//
// 边界情况（§4.3）：
//   - 无 storyboard 节点 → 空表（rows = []）
//   - 单分镜节点含多镜文本（未展开）→ 复用 ManjuStoryboardSplitter 切段，每段一行
//   - 已批量展开（分镜 1 有下游，2..N 无）→ 混合模式：1 行带节点组，其余纯文本行
//   - 用户手动为分镜 2..N 连线 → 自动升级为完整行（无需特判，逐锚点收集天然支持）
//   - 多个分镜接同一 assetRef → 资产路径并入各行（共享不独占，不入 nodeIDs 主链）
//   - 图存在环 → visited 截断，不 deadlock
//   - videoGen 已执行但结果未回填 params → outputs["video"] 兜底读取

public enum StoryboardAggregator {

    /// 下游收集类型白名单：只收集镜头生产链节点；
    /// novelImport/plotOutline/script/blenderPreview 为跨镜共享上游文本链，一律不收集。
    private static let collectibleTypes: Set<ManjuNodeType> = [
        .imagePrompt, .videoPrompt, .imageGen, .videoGen,
        .reviewGate, .qcCheck, .assetRef,
    ]

    /// 剪枝判定中的「镜内作用域」类型：候选节点的这类前驱必须全部来自本镜已收集集，
    /// 否则视为串镜（共享下游）拒绝收集。assetRef 为全局共享源，永不阻塞（例外）。
    private static let shotScopedTypes: Set<ManjuNodeType> = [
        .storyboard, .imagePrompt, .videoPrompt, .imageGen, .videoGen,
        .reviewGate, .qcCheck,
    ]

    /// 聚合入口（纯函数）：从图 + 最近执行输出生成有序分镜表。
    /// - Parameters:
    ///   - graph: 当前画布 NodeGraph（权威副本，CanvasStore.graph）
    ///   - outputs: 最近一次执行的结果输出（可选；仅用于 videoRefs 兜底读取
    ///              videoGen 的 outputs["video"]，未回填 params 的场景）
    /// - Returns: StoryboardTable；无任何分镜节点 → 空表（rows = []）
    public static func aggregate(
        graph: NodeGraph,
        outputs: [UUID: [String: AnyHashable]]? = nil,
        mediaAssets: [MediaAsset] = []
    ) -> StoryboardTable {
        let assetsByID = Dictionary(
            mediaAssets.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.version > current.version ? candidate : current
            }
        )
        // Step 1 — 找分镜锚点并排序（确定性）：y 为主、x 为次（批量展开纵向排列，y 即镜序）
        let anchors = graph.nodes
            .filter { $0.type == ManjuNodeType.storyboard.rawValue }
            .sorted { a, b in
                if a.position.y != b.position.y { return a.position.y < b.position.y }
                return a.position.x < b.position.x
            }
        guard !anchors.isEmpty else { return StoryboardTable() }

        // Step 2 — 三形态判定：
        // 未展开 = 单分镜节点且内容可切出多段（切分器与 P1 批量展开同源，
        //          保证「表里看到的行」=「展开后得到的节点」）。
        let anchorContent = content(of: anchors[0])
        let isUnexpanded = anchors.count == 1
            && ManjuStoryboardSplitter.split(script: anchorContent).count > 1

        if isUnexpanded {
            let anchor = anchors[0]
            let segments = ManjuStoryboardSplitter.split(script: anchorContent)
            let rows = segments.enumerated().map { index, segment in
                StoryboardRow(
                    sceneIndex: index + 1,
                    title: anchor.title,
                    prompt: segment,
                    anchor: rowAnchor(of: anchor, collected: []),
                    nodeIDs: [anchor.id]
                )
            }
            return StoryboardTable(rows: rows, sourceNodeID: anchor.id)
        }

        // 已展开 / 混合：每锚点一行；分镜 1 有下游 → 收集节点组，分镜 2..N 无连线 →
        // 收集结果为空 → 天然退化为纯文本行（prompt 回落锚点内容、nodeIDs = [锚点]）。
        var rows: [StoryboardRow] = []
        for (index, anchor) in anchors.enumerated() {
            let collected = collectDownstream(of: anchor, in: graph)
            let prompt = firstNonEmptyContent(of: .videoPrompt, in: collected.nodes)
                ?? firstNonEmptyContent(of: .imagePrompt, in: collected.nodes)
                ?? content(of: anchor)

            var imageRefs: [String] = []
            var videoRefs: [String] = []
            var seenImage = Set<String>()
            var seenVideo = Set<String>()

            // 字段填充：本镜 imageGen / videoGen 结果媒体（result.path + kind 门控）
            for node in collected.nodes {
                switch ManjuNodeType(rawValue: node.type) {
                case .imageGen:
                    if let path = mediaPath(of: node, kind: "image", assetsByID: assetsByID) {
                        appendUnique(&imageRefs, &seenImage, path)
                    }
                case .videoGen:
                    if let path = mediaPath(of: node, kind: "video", assetsByID: assetsByID) {
                        appendUnique(&videoRefs, &seenVideo, path)
                    } else if let any = outputs?[node.id]?["video"],
                              let fallback = any.base as? String,
                              !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // 兜底：执行结果已产出但未回填 params
                        appendUnique(&videoRefs, &seenVideo, fallback)
                    }
                default:
                    break
                }
            }
            // 上游 assetRef：共享例外，媒体路径并入各行（不入 nodeIDs 主链）
            for asset in collected.assetRefs {
                if let mediaID = asset.mediaAssetID,
                   let canonical = assetsByID[mediaID],
                   let path = canonical.localURL ?? canonical.remoteURL,
                   canonical.status != .deleted {
                    if canonical.kind == .image {
                        appendUnique(&imageRefs, &seenImage, path)
                    } else if canonical.kind == .video {
                        appendUnique(&videoRefs, &seenVideo, path)
                    }
                }
                for path in ManjuPipelineTemplate.parseAssetImages(
                    asset.backendConfig?.params[ManjuPipelineTemplate.assetImagesKey]
                ) {
                    appendUnique(&imageRefs, &seenImage, path)
                }
                for path in ManjuPipelineTemplate.parseAssetVideos(
                    asset.backendConfig?.params[ManjuPipelineTemplate.assetVideosKey]
                ) {
                    appendUnique(&videoRefs, &seenVideo, path)
                }
            }

            // 审核三态 + 备注（review.reason 只读支持）
            let reviewGate = collected.nodes.first { $0.type == ManjuNodeType.reviewGate.rawValue }
            let status = reviewGate.map { StoryboardReviewStatus.fromParams($0.backendConfig?.params) } ?? .pending
            let notes = reviewGate.flatMap { $0.backendConfig?.params["review.reason"] } ?? ""

            rows.append(StoryboardRow(
                sceneIndex: index + 1,
                title: anchor.title,
                prompt: prompt,
                imageRefs: imageRefs,
                videoRefs: videoRefs,
                reviewStatus: status,
                notes: notes,
                anchor: rowAnchor(of: anchor, collected: collected.nodes),
                nodeIDs: [anchor.id] + collected.nodes.map(\.id)
            ))
        }
        return StoryboardTable(rows: rows)
    }

    // MARK: - 行选中定位（R5-P0-1：只依赖图内稳定锚点，不依赖随机行 id）

    /// 返回包含锚点节点的行（未展开多段分镜每行 nodeIDs 均为同一锚点 → 命中第一镜）。
    /// 视图层选中判定/滚动定位必须走这里：聚合每次重建行、`StoryboardRow.id` 随机生成，
    /// 跨聚合比较行 id 恒失配（审计 R5-P0-1：高亮/详情/滚动全失效）。
    public static func row(containing anchorID: UUID?, in table: StoryboardTable) -> StoryboardRow? {
        guard let anchorID else { return nil }
        return table.rows.first { $0.nodeIDs.contains(anchorID) }
    }

    /// 返回包含锚点节点的行下标（scrollTo 定位目标；行序确定性排序 → 下标跨聚合稳定）。
    public static func index(ofRowContaining anchorID: UUID?, in table: StoryboardTable) -> Int? {
        guard let anchorID else { return nil }
        return table.rows.firstIndex { $0.nodeIDs.contains(anchorID) }
    }

    // MARK: - 私有

    /// 单镜下游收集结果：主链节点（BFS 顺序，不含 assetRef）+ 共享资产源（媒体并入用）
    private struct Collected {
        var nodes: [CanvasNode] = []
        var assetRefs: [CanvasNode] = []
    }

    /// 从锚点沿 successors(of:) 前向 BFS，收集镜头生产链节点：
    /// - 剪枝（防串镜）：候选节点的「镜内作用域」前驱必须全部已在本镜收集集；
    ///   被拒节点不标记 visited，后续经其他路径再遇到时重试（支持菱形结构）。
    /// - assetRef 例外：全局共享源，只取媒体路径并入各行，不入 nodeIDs 主链。
    /// - visited 防环（用户手连可能成环，防御性处理）。
    private static func collectDownstream(of anchor: CanvasNode, in graph: NodeGraph) -> Collected {
        var collected = Collected()
        var collectedIDs: Set<UUID> = [anchor.id]
        var visited: Set<UUID> = [anchor.id]
        var queue = graph.successors(of: anchor.id)

        while !queue.isEmpty {
            let node = queue.removeFirst()
            guard let type = ManjuNodeType(rawValue: node.type),
                  collectibleTypes.contains(type) else { continue }
            guard visited.insert(node.id).inserted else { continue }

            // assetRef 例外：收集媒体路径，不参与主链排序，也不展开其下游（防跨镜串扰）
            if type == .assetRef {
                collected.assetRefs.append(node)
                continue
            }

            // 剪枝（防串镜）：所有镜内作用域前驱必须已在本镜收集集。
            // 环豁免：未收集前驱若可从候选节点沿下游到达（环成员，如 vp→ig→vp），
            // 不阻塞——否则收集集永远凑不齐，形成死锁条件。
            let blocked = graph.predecessors(of: node.id).contains { pred in
                guard let predType = ManjuNodeType(rawValue: pred.type),
                      shotScopedTypes.contains(predType),
                      !collectedIDs.contains(pred.id) else { return false }
                return !isReachable(from: node.id, to: pred.id, in: graph)
            }
            guard !blocked else {
                visited.remove(node.id) // 允许后续经其他路径再遇到时重试
                continue
            }

            collectedIDs.insert(node.id)
            collected.nodes.append(node)

            // 上游 assetRef 共享例外：收集本节点前驱中的资产源（媒体路径并入，不入主链）
            for pred in graph.predecessors(of: node.id)
            where pred.type == ManjuNodeType.assetRef.rawValue {
                if visited.insert(pred.id).inserted {
                    collected.assetRefs.append(pred)
                }
            }

            queue.append(contentsOf: graph.successors(of: node.id))
        }
        return collected
    }

    /// 从 start 沿有向边（successors）能否到达 target（环豁免判定；visited 防环）
    private static func isReachable(from start: UUID, to target: UUID, in graph: NodeGraph) -> Bool {
        guard start != target else { return true }
        var visited: Set<UUID> = [start]
        var queue = graph.successors(of: start).map(\.id)
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if id == target { return true }
            guard visited.insert(id).inserted else { continue }
            queue.append(contentsOf: graph.successors(of: id).map(\.id))
        }
        return false
    }

    /// 行锚点：锚点节点（分镜节点）显式锚点优先；否则取收集集中首个带锚点的节点
    /// （BFS 顺序，即数据流最近优先）。无任何锚点 → nil。
    private static func rowAnchor(of anchor: CanvasNode, collected: [CanvasNode]) -> StoryboardAnchor? {
        StoryboardAnchor.parse(anchor.backendConfig?.params["anchor"])
            ?? collected.compactMap { StoryboardAnchor.parse($0.backendConfig?.params["anchor"]) }.first
    }

    /// 读取节点 params["content"]（节点内容统一存储键，与 CanvasStore.nodeContentKey 一致）
    private static func content(of node: CanvasNode) -> String {
        node.backendConfig?.params["content"] ?? ""
    }

    /// 收集集中指定类型的第一个非空内容（prompt 优先级链用）
    private static func firstNonEmptyContent(of type: ManjuNodeType, in nodes: [CanvasNode]) -> String? {
        for node in nodes where node.type == type.rawValue {
            let value = content(of: node)
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// Resolve canonical MediaAsset first; legacy result.* remains decode-only.
    private static func mediaPath(
        of node: CanvasNode,
        kind: String,
        assetsByID: [UUID: MediaAsset]
    ) -> String? {
        if let assetID = node.mediaAssetID,
           let asset = assetsByID[assetID],
           asset.kind.rawValue == kind,
           asset.status != .deleted,
           let path = asset.localURL ?? asset.remoteURL,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }
        return legacyResultPath(of: node, kind: kind)
    }

    private static func legacyResultPath(of node: CanvasNode, kind: String) -> String? {
        guard let params = node.backendConfig?.params,
              params["result.kind"] == kind,
              let path = params["result.path"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return path
    }

    /// 去重保序追加（imageRefs/videoRefs 共用）
    private static func appendUnique(_ array: inout [String], _ seen: inout Set<String>, _ value: String) {
        if seen.insert(value).inserted {
            array.append(value)
        }
    }
}
