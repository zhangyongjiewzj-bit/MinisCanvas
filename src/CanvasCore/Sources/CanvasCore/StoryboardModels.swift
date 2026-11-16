import Foundation

// MARK: - P2 分镜表工作台：数据模型（CanvasCore 纯逻辑层）
//
// 设计文档：issues/p2_storyboard_design_20260805.md §3 数据模型契约
// 契约键：content / review.status / result.path / result.kind / result.name /
//         asset.images / asset.videos / review.reason（只读支持；写入口待总控批准）
// 依赖方向：CanvasCore 不反向依赖 App 层任何类型；与 App 层 ReviewStatus 的
//           语义一致性由 App 层一行转换函数 + 一致性测试守护。

/// 审核三态契约（与 App 层 ReviewStatus / ReviewGateExecutor 输出一致）：
/// 值 = 大写字符串 "PASS"/"REJECT"/"PENDING"，未设置/未知一律归一为 .pending。
/// 注：App 层已有同语义 enum（CanvasStore.swift:551），本类型为 CanvasCore 独立契约，
/// 两处映射函数各自实现、由一致性测试守护，本轮不做跨层搬移（避免行为变更）。
public enum StoryboardReviewStatus: String, Equatable, Sendable, Codable {
    case pass = "PASS"
    case reject = "REJECT"
    case pending = "PENDING"

    /// 从节点 params 读取审核三态（键 `review.status`）；未设置/未知值一律归一为 .pending。
    public static func fromParams(_ params: [String: String]?) -> StoryboardReviewStatus {
        guard let raw = params?["review.status"],
              let status = StoryboardReviewStatus(rawValue: raw) else { return .pending }
        return status
    }

    /// UI 展示标签（与 App 层 ReviewStatus.label 语义一致）
    public var label: String {
        switch self {
        case .pass: return "通过"
        case .reject: return "打回"
        case .pending: return "待审"
        }
    }
}

/// 分镜锚点：镜头画面内的归一化构图参考点（x/y ∈ 0...1，0,0 = 内容区左上角）。
/// 存储契约：节点 `params["anchor"]` = "x,y"（逗号分隔、两位小数，如 "0.50,0.30"）。
/// 用途：分镜标记关键构图位置（角色站位/焦点），画布标记可视化可拖动，导出随行落盘。
/// Codable：随 StoryboardRow 导出 JSON；与 App 层 CanvasStore.anchorKey 键名一致由测试守护。
public struct StoryboardAnchor: Equatable, Sendable, Codable {
    /// 归一化横坐标（0...1）
    public var x: Double
    /// 归一化纵坐标（0...1）
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// 解析 params["anchor"] 字符串 "x,y"；缺失/非法/越界容忍（越界钳制）→ nil。
    /// 与 CanvasStore.setAnchor 的 encoded() 严格互逆（round-trip 测试守护）。
    public static func parse(_ raw: String?) -> StoryboardAnchor? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              x.isFinite, y.isFinite else { return nil }
        return StoryboardAnchor(x: x, y: y).clamped()
    }

    /// 序列化为 "x,y"（两位小数；与 parse 互逆）
    public func encoded() -> String {
        String(format: "%.2f,%.2f", x, y)
    }

    /// 钳制到 0...1 归一化范围（防御脏数据；parse 已钳制，显式调用防直接构造越界）
    public func clamped() -> StoryboardAnchor {
        StoryboardAnchor(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

/// 分镜表的一行 = 一个镜头（scene）。
/// 字段与画布分析报告缺口的原始诉求对齐：序号/提示词/参考图/参考视频/审核状态/备注/锚点。
/// Codable：可 JSON 序列化（导出分镜脚本表 / 断点续传 / 测试 round-trip）。
public struct StoryboardRow: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    /// 镜号（1-based，按画布纵向位置排序后的序号，确定性）
    public var sceneIndex: Int
    /// 镜头名（默认取分镜节点标题，如 "分镜3"；批量展开后 = "分镜N"）
    public var title: String
    /// 提示词（优先级：本镜 videoPrompt 节点内容 → imagePrompt 节点内容 → 分镜节点内容）
    public var prompt: String
    /// 参考图路径列表（本镜 imageGen 结果图 + 上游 assetRef 的 asset.images 解析 + 首帧图）
    public var imageRefs: [String]
    /// 参考视频路径列表（本镜 videoGen 结果视频 + assetRef 的 asset.videos 解析，V2V 参考）
    public var videoRefs: [String]
    /// 审核状态（本镜 reviewGate 节点 params["review.status"]；无审核节点 → .pending）
    public var reviewStatus: StoryboardReviewStatus
    /// 备注（打回意见 / 人工标注；数据源为契约键 `review.reason`，只读）
    public var notes: String
    /// 分镜锚点（镜头画面内归一化构图参考点；nil = 未标记）。
    /// 数据源：锚点节点（分镜节点）params["anchor"] 优先，否则取本镜收集集中首个带锚点的节点。
    public var anchor: StoryboardAnchor?
    /// 本镜关联的画布节点 id（按数据流顺序：分镜 → 提示词 → 生成 → 审核 → 质检），
    /// 供 UI「选中分镜行 = 定位对应节点组」联动（缺口原文 :130 要求）。
    public var nodeIDs: [UUID]

    public init(
        id: UUID = UUID(),
        sceneIndex: Int,
        title: String,
        prompt: String = "",
        imageRefs: [String] = [],
        videoRefs: [String] = [],
        reviewStatus: StoryboardReviewStatus = .pending,
        notes: String = "",
        anchor: StoryboardAnchor? = nil,
        nodeIDs: [UUID] = []
    ) {
        self.id = id
        self.sceneIndex = sceneIndex
        self.title = title
        self.prompt = prompt
        self.imageRefs = imageRefs
        self.videoRefs = videoRefs
        self.reviewStatus = reviewStatus
        self.notes = notes
        self.anchor = anchor
        self.nodeIDs = nodeIDs
    }
}

/// 分镜表：整部剧的镜头汇总（工作台数据源）。
public struct StoryboardTable: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    /// 表标题（默认 "分镜表"；可带画布名）
    public var title: String
    /// 有序分镜行（sceneIndex 升序）
    public var rows: [StoryboardRow]
    /// 生成来源：批量展开前的分镜节点 id（未展开场景）；已展开/混合场景 = nil
    public var sourceNodeID: UUID?
    /// 聚合生成时间（App 层重算时刷新）
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "分镜表",
        rows: [StoryboardRow] = [],
        sourceNodeID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.rows = rows
        self.sourceNodeID = sourceNodeID
        self.updatedAt = updatedAt
    }
}
