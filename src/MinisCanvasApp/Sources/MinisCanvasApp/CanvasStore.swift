import Foundation
import CryptoKit
import Darwin
import Observation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CanvasCore
import MinisCore

// MARK: - 画布事件（聊天侧栏订阅，实现 画布 → 聊天 联动）

/// 画布状态变化事件：由 CanvasStore 发出，BridgeStore 转成聊天流提示。
enum CanvasEvent {
    case nodeAdded(title: String, type: String)
    case nodeRemoved(title: String)
    case edgeAdded(fromTitle: String, toTitle: String)
    case runStarted
    case runFinished(summary: String)
    case nodeStatusChanged(title: String, status: NodeStatus)
    case layoutDone
    /// 点击画布节点 → 聊天区显示该节点上下文
    case nodeSelected(title: String, type: String, status: NodeStatus,
                      modelID: String?, inputCount: Int, outputCount: Int)
    /// 点击画布空白 → 清除节点上下文
    case selectionCleared
}

/// 画布节点显式选择的模型。该值只从节点 backendConfig 派生，不读取聊天会话状态。
struct CanvasModelSelection: Equatable {
    let providerType: ProviderKind
    let providerID: String
    let modelID: String
}

// MARK: - 节点类型注册表（新包薄壳，复用 CanvasCore 数据模型）
// I8 P1-1：补齐 v0.2 漫剧 11 类节点（与 CanvasApp 注册表对齐，type = ManjuNodeType.rawValue）。

/// 面板分组：基础节点 / 漫剧流程 / 漫剧工具
enum NodePaletteGroup: String, CaseIterable, Identifiable {
    case basic = "基础节点"
    case manjuFlow = "漫剧流程"
    case manjuTools = "漫剧工具"
    var id: String { rawValue }
}

// MARK: - 节点分类（Phase B 产品方向：画布只暴露生成类节点）

/// 节点分类：生成类（画布新建入口可见）vs 文本创作类（仅保留类型定义以兼容旧图数据，
/// 不再出现在画布「添加节点」入口：右键菜单 / 搜索面板 / 工具栏 / 建节点命令）。
enum NodeCategory: String, CaseIterable, Sendable {
    /// 生成类：产出可交付物（文本源 / 图 / 视频 / 预演 / 质检 / 资产；AJ-74：LLM 推理已下线）
    case generative = "生成类"
    /// 文本创作类：小说导入 / 剧情 / 脚本 / 分镜 / 提示词撰写等中间创作环节
    case textCreative = "文本创作类"
}

/// 节点类型规格：类型字符串 → 标题 / 端口 / 颜色
struct NodeTypeSpec: Identifiable {
    let type: String
    let title: String
    let summary: String
    let color: Color
    let inputs: [CanvasCore.Port]
    let outputs: [CanvasCore.Port]
    /// 节点级默认模型配置（v0.2：创建即带默认模型）
    let defaultBackendConfig: NodeBackendConfig?
    /// SF Symbol 图标（工具栏/面板条目用）
    var iconName = "square.grid.2x2"
    /// 提示词模板槽位数（>0 时显示 "N槽" 徽标）
    var slotCount: Int?
    /// 面板分组
    var group: NodePaletteGroup = .basic

    /// AJ-19/20：参考图输入端口上限（按节点类型；不支持的节点返回 0）。
    /// 由 ManjuNodeType 规格推导（生图 4 / 生视频 1；基础占位等非 Manju 类型 0）。
    var maxReferenceImages: Int {
        ManjuNodeType(rawValue: type)?.maxReferenceImages ?? 0
    }
    /// 该节点类型是否支持动态参考图端口
    var supportsReferenceImages: Bool { maxReferenceImages > 0 }

    var id: String { type }

    func makeNode(position: Point = Point(x: 0, y: 0)) -> CanvasNode {
        CanvasNode(
            type: type,
            title: title,
            position: position,
            inputs: inputs,
            outputs: outputs,
            backendConfig: defaultBackendConfig
        )
    }
}

/// 内置节点类型：基础 4 类 + 漫剧 11 类（与 CanvasApp 一致）
enum NodeTypeRegistry {

    // MARK: Phase B 瘦身（用户产品方向拍板）：画布新建入口只暴露生成类节点
    //
    // 文本创作类（小说导入/剧情/脚本/分镜/图片提示词/视频提示词）与基础占位
    // image/video 的类型定义全部保留（渲染旧图数据 / 执行器 / spec(for:) 查表不受影响），
    // 只是不再出现在「添加节点」入口：右键菜单 / 搜索面板 / 工具栏 / 建节点命令。

    /// Phase B 保留清单：画布可新建的生成类节点。
    /// 基础 image/video 为占位演示节点，imageGen/videoGen 是正式替代，故不进保留清单。
    /// AJ-74：节点×LLM 前台下线——「llm」移出可新建清单（类型定义仍保留，兼容旧图数据渲染/执行）。
    static let creatableTypes: Set<String> = [
        "text",
        ManjuNodeType.imageGen.rawValue, ManjuNodeType.videoGen.rawValue,
        ManjuNodeType.blenderPreview.rawValue, ManjuNodeType.qcCheck.rawValue,
        ManjuNodeType.assetRef.rawValue,
    ]

    /// 文本创作类节点类型：保留定义兼容旧图数据，但从画布新建入口移除。
    static let textCreativeTypes: Set<String> = [
        ManjuNodeType.novelImport.rawValue, ManjuNodeType.plotOutline.rawValue,
        ManjuNodeType.script.rawValue, ManjuNodeType.storyboard.rawValue,
        ManjuNodeType.imagePrompt.rawValue, ManjuNodeType.videoPrompt.rawValue,
    ]

    /// 分类：文本创作类 → .textCreative；其余（含基础 image/video 占位）→ .generative
    static func category(of type: String) -> NodeCategory {
        textCreativeTypes.contains(type) ? .textCreative : .generative
    }

    /// 画布「添加节点」入口可见条目（Phase B 瘦身后 = 保留清单 7 类生成类节点）
    static var creatableSpecs: [NodeTypeSpec] {
        specs.filter { creatableTypes.contains($0.type) }
    }

    /// 基础占位节点（text / llm / image / video）
    static let basicSpecs: [NodeTypeSpec] = [
        NodeTypeSpec(
            type: "text", title: "文本输入", summary: "文本内容源", color: .teal,
            inputs: [],
            outputs: [CanvasCore.Port(name: "text", direction: .output, dataType: "string")],
            defaultBackendConfig: NodeBackendConfig(
                providerType: .local, providerID: "ollama", modelID: "qwen2.5",
                params: ["temperature": "0.7"]
            )
        ),
        // AJ-74：节点×LLM 前台下线——「LLM 推理」已从新建入口移除（creatableTypes 不含 llm），
        // 节点卡片/检查器不再提供模型选择与后端配置 UI（ModelConfigPanelView 显示下线占位）。
        // spec 保留仅为兼容旧图数据渲染/执行：画布按普通节点呈现（不置灰、不崩溃）。
        NodeTypeSpec(
            type: "llm", title: "LLM 推理", summary: "大模型生成", color: .blue,
            inputs: [
                CanvasCore.Port(name: "prompt", direction: .input, dataType: "string"),
                CanvasCore.Port(name: "system", direction: .input, dataType: "string"),
            ],
            outputs: [CanvasCore.Port(name: "text", direction: .output, dataType: "string")],
            defaultBackendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview",
                params: ["temperature": "0.7", "maxTokens": "2048"]
            )
        ),
        NodeTypeSpec(
            type: "image", title: "图像生成", summary: "文生图", color: .purple,
            inputs: [CanvasCore.Port(name: "prompt", direction: .input, dataType: "string")],
            outputs: [CanvasCore.Port(name: "image", direction: .output, dataType: "image")],
            defaultBackendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "gimage2", modelID: "gpt-image-2-official",
                params: ["size": "1024x1024"]
            )
        ),
        NodeTypeSpec(
            type: "video", title: "视频生成", summary: "图生视频", color: .pink,
            inputs: [
                CanvasCore.Port(name: "image", direction: .input, dataType: "image"),
                CanvasCore.Port(name: "prompt", direction: .input, dataType: "string"),
            ],
            outputs: [CanvasCore.Port(name: "video", direction: .output, dataType: "video")],
            defaultBackendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "kling", modelID: "kling-v2",
                params: ["duration": "5s", "resolution": "720p"]
            )
        ),
    ]

    /// 漫剧 11 类节点（type = ManjuNodeType.rawValue，与流水线模板/资产注入互查）
    static let manjuSpecs: [NodeTypeSpec] = ManjuNodeType.allCases.map { spec(for: $0) }

    /// 全部注册表条目（工具栏/指令解析共用）
    static var specs: [NodeTypeSpec] { basicSpecs + manjuSpecs }

    static func spec(for type: String) -> NodeTypeSpec? {
        specs.first { $0.type == type }
    }

    /// 按标题/别名模糊查找类型（聊天指令解析用）
    static func spec(matching keyword: String) -> NodeTypeSpec? {
        let k = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return nil }
        // 匹配优先级：① type 精确 → ② title 子串 → ③ type 子串/反包含 → ④ summary 子串（兜底）。
        // summary 必须放最后：basicSpecs 中「图像生成」占位 summary「文生图」含「生图」，
        // 若提前会误吞「建节点 生图」→ 命中不可新建的 image 占位（AJ-74 合拢时修复）。
        return specs.first { $0.type.lowercased() == k }
            ?? specs.first { $0.title.lowercased().contains(k) }
            ?? specs.first { $0.type.lowercased().contains(k) || k.contains($0.type.lowercased()) }
            ?? specs.first { $0.summary.lowercased().contains(k) }
    }
}

// MARK: - 漫剧节点规格（I8 P1-1：与 CanvasApp 注册表对齐）

extension NodeTypeRegistry {

    /// 按 ManjuNodeType 构造节点规格：中文标题 + SF Symbol 图标 + 模板槽位徽标
    static func spec(for manjuType: ManjuNodeType) -> NodeTypeSpec {
        // 槽位数取自提示词模板库（图片 8 槽 / 视频 9 槽，其余 0 槽不显示徽标）
        let slotCount = ManjuPromptTemplates.template(for: manjuType)?.slots.count
        // 预留：节点×LLM 已前台下线（AJ-74），llmConfig（NodeBackendConfig）接口保留待后续恢复。
        let llmConfig = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview",
            params: ["temperature": "0.7", "maxTokens": "2048"]
        )
        let textIn = CanvasCore.Port(name: "text", direction: .input, dataType: "string")
        let textOut = CanvasCore.Port(name: "text", direction: .output, dataType: "string")

        switch manjuType {
        case .novelImport:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "小说导入", summary: "原文接入与分章",
                color: .teal, inputs: [], outputs: [textOut],
                defaultBackendConfig: nil,
                iconName: "book.fill", slotCount: slotCount, group: .manjuFlow
            )
        case .plotOutline:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "剧情拆解", summary: "章节/冲突/节奏拆解",
                color: .blue, inputs: [textIn], outputs: [textOut],
                defaultBackendConfig: llmConfig,
                iconName: "rectangle.stack.fill", slotCount: slotCount, group: .manjuFlow
            )
        case .script:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "脚本生成", summary: "对白、动作、场景描述",
                color: .indigo, inputs: [textIn], outputs: [textOut],
                defaultBackendConfig: llmConfig,
                iconName: "doc.text.fill", slotCount: slotCount, group: .manjuFlow
            )
        case .storyboard:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "分镜生成", summary: "首尾帧、镜头拆分",
                color: .cyan, inputs: [textIn], outputs: [textOut],
                defaultBackendConfig: llmConfig,
                iconName: "camera.fill", slotCount: slotCount, group: .manjuFlow
            )
        case .imagePrompt:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "图片提示词", summary: "图片 8 槽模板输出",
                color: .purple, inputs: [textIn], outputs: [textOut],
                defaultBackendConfig: llmConfig,
                iconName: "photo.fill", slotCount: slotCount, group: .manjuFlow
            )
        case .videoPrompt:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "视频提示词", summary: "视频 9 槽模板输出",
                color: .pink, inputs: [textIn], outputs: [textOut],
                defaultBackendConfig: llmConfig,
                iconName: "film.fill", slotCount: slotCount, group: .manjuFlow
            )
        case .imageGen:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "生图（Beta）", summary: "定妆图/服装/场景/首尾帧（Beta 未验证）",
                color: .orange,
                inputs: [
                    CanvasCore.Port(name: "prompt", direction: .input, dataType: "string"),
                    CanvasCore.Port(name: "image", direction: .input, dataType: "image"),
                ],
                outputs: [CanvasCore.Port(name: "image", direction: .output, dataType: "image")],
                defaultBackendConfig: NodeBackendConfig(
                    providerType: .cloud, providerID: "gimage2", modelID: "gpt-image-2-official",
                    params: ["size": "1024x1024"]
                ),
                iconName: "photo.on.rectangle.angled", slotCount: slotCount, group: .manjuFlow
            )
        case .videoGen:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "生视频（Beta）", summary: "I2V/R2V/V2V 执行（Beta 未验证）",
                color: .red,
                inputs: [
                    CanvasCore.Port(name: "video", direction: .input, dataType: "video"),
                    CanvasCore.Port(name: "image", direction: .input, dataType: "image"),
                    CanvasCore.Port(name: "prompt", direction: .input, dataType: "string"),
                    CanvasCore.Port(name: "duration", direction: .input, dataType: "string"),
                ],
                outputs: [CanvasCore.Port(name: "video", direction: .output, dataType: "video")],
                // 生视频参数面板（右侧栏 NodeInspectorView 可编辑，与执行器读取键一一对应）：
                //   mode       = 生成模式：i2v 图生视频 / t2v 文生视频 / r2v 首尾帧
                //   resolution = 分辨率：720p / 1080p / 2K
                //   duration   = 时长：5s / 10s / 15s
                //   audio      = 带声音：on / off
                defaultBackendConfig: NodeBackendConfig(
                    providerType: .cloud, providerID: "kling", modelID: "kling-v2",
                    params: ["mode": "i2v", "resolution": "720p", "duration": "5s", "audio": "off"]
                ),
                iconName: "video.fill", slotCount: slotCount, group: .manjuFlow
            )
        case .blenderPreview:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "Blender 白模预演（Beta）", summary: "多人站位/机位验证（Beta·依赖外部插件）",
                color: .green, inputs: [textIn], outputs: [textOut],
                defaultBackendConfig: nil,
                iconName: "arkit", slotCount: slotCount, group: .manjuTools
            )
        case .assetRef:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "资产引用", summary: "资产锁定：角色锁定卡/色板/母图",
                color: .brown, inputs: [],
                // B2：text 输出 = 资产锁定摘要（assets 语义）；video 输出 = 资产参考视频首条
                // （AssetLockExecutor 输出 videoPaths 全量 + video 首条，V2V 参考视频进生视频节点）
                // B7：image 输出 = 资产参考图片首条（与 video/text 并列）——资产应用节点图片输出，
                // 供「生成的图片加载成画布节点」承载缩略图（AssetLockExecutor 输出 imagePaths 全量
                // + image 首条，img2img 参考图进生图节点；contentKind == .image 挂缩略图/导入面板）
                outputs: [
                    textOut,
                    CanvasCore.Port(name: "video", direction: .output, dataType: "video"),
                    CanvasCore.Port(name: "image", direction: .output, dataType: "image"),
                ],
                defaultBackendConfig: nil,
                iconName: "cube.fill", slotCount: slotCount, group: .manjuTools
            )
        case .qcCheck:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "QC 检查", summary: "审图+审视频 · 结构+审美+三刻度盘（PASS/FAIL）",
                color: .gray,
                // 端口契约与 ManjuNodeType.qcCheckInputPorts/OutputPorts 严格一致：
                // image（待审图，动态 image1…image9）/ text（提示词/任务单文本）/ video（上游
                // videoGen 成片，模板主链 videoGen.video → qcCheck.video）→ report/status。
                // 审计详情键（qc_status/images_reviewed/dial_*/reasons/missing_slots）不设端口，
                // 随 report 写回节点内容（只读）+ 状态色 + 聊天回执呈现（见 qcCheckAuditDetailKeys）。
                inputs: [
                    CanvasCore.Port(name: "image", direction: .input, dataType: "image"),
                    CanvasCore.Port(name: "text", direction: .input, dataType: "string"),
                    CanvasCore.Port(name: "video", direction: .input, dataType: "video"),
                ],
                outputs: [
                    CanvasCore.Port(name: "report", direction: .output, dataType: "string"),
                    CanvasCore.Port(name: "status", direction: .output, dataType: "string"),
                ],
                defaultBackendConfig: llmConfig,
                iconName: "checkmark.shield.fill", slotCount: slotCount, group: .manjuTools
            )
        case .reviewGate:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "审核", summary: "单份文本审核（PASS/REJECT/PENDING）",
                color: .indigo,
                inputs: [textIn],
                outputs: [
                    CanvasCore.Port(name: "pass", direction: .output, dataType: "string"),
                    CanvasCore.Port(name: "status", direction: .output, dataType: "string"),
                ],
                defaultBackendConfig: llmConfig,
                iconName: "checkmark.seal.fill", slotCount: slotCount, group: .manjuTools
            )
        }
    }
}

// MARK: - 节点渲染度量

enum NodeMetrics {
    static let nodeWidth = 200.0
    static let headerHeight = 34.0
    static let rowHeight = 26.0
    static let bottomPadding = 12.0
    // F12：卡片下挂内容面板高度（overlay 悬挂，不改卡片本体布局/端口锚点几何）
    static let textPanelHeight = 56.0
    static let imagePanelHeight = 92.0
    static let videoPanelHeight = 34.0

    static func nodeHeight(inputs: Int, outputs: Int) -> Double {
        headerHeight + Double(max(inputs, outputs)) * rowHeight + bottomPadding
    }
}

/// U-3：粘贴后「揭示请求」——渲染层（CanvasView）观察到新 token 后自动平移视口，
/// 把粘贴内容居中到可视区域（防止粘贴落点出屏导致用户"看不到粘贴的节点"）。
/// token 用 UUID 保证每次粘贴都是新值（@Observable 只对变化触发 onChange）。
struct RevealRequest: Equatable {
    let center: Point
    let token: UUID
}

// MARK: - AJ-21 画布组（参照 ComfyUI 组：矩形容器框住一组节点，可拖动/折叠/连线跟随）

/// 画布组：ComfyUI 风格矩形容器，框住一组节点。
/// - `origin` 为组左上角世界坐标；`size` 为组尺寸（世界坐标）。
/// - 成员节点记录于 `nodeIDs`；移动组时成员节点同步平移（连线锚定节点，自动跟随）。
/// - 折叠时仅显示标题栏，成员节点隐藏（渲染层跳过）。
struct CanvasGroup: Identifiable, Equatable {
    let id: UUID
    var title: String
    var origin: Point
    var size: CGSize
    var nodeIDs: Set<UUID>
    var isCollapsed: Bool
    var color: Color

    /// 标题栏高度（世界坐标）
    static let titleBarHeight = 28.0
    /// 组内边距（建组时节点包围盒外扩的留白）
    static let padding = 20.0
    /// 默认组背景色（半透明，给节点留出可读性）；色相对齐 AJ-38 赭橙 accent（#9D623D）。
    static let defaultColor = Color(red: 0.616, green: 0.384, blue: 0.239).opacity(0.10)

    /// B10：组自定义颜色预设（10 色——红橙黄绿青蓝紫粉棕灰），半透明填充给节点留可读性。
    static let groupColors: [(name: String, color: Color)] = [
        ("红", Color(red: 0.85, green: 0.32, blue: 0.32).opacity(0.12)),
        ("橙", Color(red: 0.95, green: 0.60, blue: 0.25).opacity(0.12)),
        ("黄", Color(red: 0.90, green: 0.80, blue: 0.28).opacity(0.12)),
        ("绿", Color(red: 0.35, green: 0.74, blue: 0.40).opacity(0.12)),
        ("青", Color(red: 0.22, green: 0.68, blue: 0.72).opacity(0.12)),
        ("蓝", Color(red: 0.30, green: 0.50, blue: 0.85).opacity(0.12)),
        ("紫", Color(red: 0.60, green: 0.40, blue: 0.80).opacity(0.12)),
        ("粉", Color(red: 0.92, green: 0.55, blue: 0.70).opacity(0.12)),
        ("棕", Color(red: 0.62, green: 0.42, blue: 0.28).opacity(0.12)),
        ("灰", Color(red: 0.52, green: 0.54, blue: 0.58).opacity(0.12)),
    ]

    init(
        id: UUID = UUID(),
        title: String,
        origin: Point,
        size: CGSize,
        nodeIDs: Set<UUID> = [],
        isCollapsed: Bool = false,
        color: Color = CanvasGroup.defaultColor
    ) {
        self.id = id
        self.title = title
        self.origin = origin
        self.size = size
        self.nodeIDs = nodeIDs
        self.isCollapsed = isCollapsed
        self.color = color
    }

    /// 渲染高度（折叠时仅标题栏）
    var displayHeight: Double { isCollapsed ? Self.titleBarHeight : size.height }
    /// 渲染中心（SwiftUI .position 中心坐标语义；折叠时高度收成标题栏）
    var center: Point {
        Point(x: origin.x + size.width / 2, y: origin.y + displayHeight / 2)
    }
}

// MARK: - 画布状态

/// 执行进度（C2-2：ComfyUI ProgressRegistry value/max 等价物）。
/// value = 已定稿（完成/缓存/失败/跳过）节点数；max = 节点总数。
struct ExecutionProgress: Equatable {
    var value: Int
    var max: Int
    /// 正在执行的节点标题（nil = 当前无执行中节点）
    var currentNodeTitle: String?
    var fraction: Double { max > 0 ? Double(value) / Double(max) : 0 }
}

/// C5 画布剪贴板（LiteGraph copyToClipboard 载荷）：节点 + 子图内部连线。
/// 粘贴时按 old→new 相对 id 映射重建（_relative_id 语义），内存态，不落盘。
struct CanvasClipboard: Equatable, Sendable {
    var nodes: [CanvasNode]
    var edges: [CanvasCore.Edge]
}

/// 跨线程中断标志：调度器在后台线程逐节点轮询，主线程点「停止」置位。
/// （DAGScheduler 为同步调度，只能节点间中断；NSLock 保证跨线程可见）
private final class ExecutionCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        cancelled = false
    }
}

/// 调度器线程安全盒：DAGScheduler 含非 Sendable 结果缓存（AnyHashable），
/// 后台执行线程与主线程共用同一实例，锁内跑完整 run（缓存跨次执行保留）。
private final class SchedulerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduler = DAGScheduler()
    func run(
        graph: NodeGraph,
        context: NodeExecutionContext,
        resumeFrom: Set<UUID> = [],
        from: Set<UUID>? = nil,
        seedOutputs: [UUID: [String: AnyHashable]] = [:],
        executionEnvelope: DAGExecutionEnvelope? = nil,
        onEvent: @escaping (DAGExecutionEvent) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> DAGExecutionResult {
        lock.lock(); defer { lock.unlock() }
        return try scheduler.run(
            graph: graph, context: context,
            resumeFrom: resumeFrom, from: from, seedOutputs: seedOutputs,
            onEvent: onEvent, isCancelled: isCancelled,
            executionEnvelope: executionEnvelope
        )
    }
}

/// P0 局部重跑 seed 包装盒：上次执行结果输出（AnyHashable 非 Sendable），
/// 经 @unchecked Sendable 盒跨线程传递（与 SchedulerBox 同模式——盒内数据
/// 只在锁/任务边界外只读使用，无实际竞态）。
private final class SeedBox: @unchecked Sendable {
    let value: [UUID: [String: AnyHashable]]
    init(_ value: [UUID: [String: AnyHashable]]) { self.value = value }
}

// MARK: - P0-1 RunEnvelope（canvasID + runID + graphRevision 写回前校验）

/// 运行信封：canvasID + runID + 图结构版本。防止「旧运行结果覆盖当前画布」——
/// 运行开始时记录图的结构版本，运行结束写回前校验当前图版本是否仍一致；
/// 不一致（用户中途加了/删了节点、改了连线/内容/模型配置）→ 不覆盖并提示结果可能过期。
struct RunEnvelope: Equatable, Sendable {
    /// 本次运行的唯一标识（区分同图多次运行）
    let runID: UUID
    /// 运行开始时的画布 ID；旧测试/持久化调用缺省时保留仅按图版本校验的兼容行为
    let canvasID: UUID?
    /// 运行开始时图的结构版本（排除执行状态）
    let graphRevision: Int
    /// L7 运行级执行信封；nil 表示旧测试/调用方的兼容路径
    let executionEnvelope: DAGExecutionEnvelope?

    init(
        runID: UUID,
        canvasID: UUID? = nil,
        graphRevision: Int,
        executionEnvelope: DAGExecutionEnvelope? = nil
    ) {
        self.runID = runID
        self.canvasID = canvasID
        self.graphRevision = graphRevision
        self.executionEnvelope = executionEnvelope
    }

    /// 当前画布是否仍与运行开始时一致
    func isCanvasCurrent(_ currentCanvasID: UUID) -> Bool {
        canvasID == nil || canvasID == currentCanvasID
    }
    /// 当前图是否仍与运行开始时一致（结构未变）
    func isGraphCurrent(_ currentRevision: Int) -> Bool {
        currentRevision == graphRevision
    }
}

extension NodeGraph {
    /// P0-1：图结构版本（结构语义哈希，确定性、与进程无关）。
    /// 只对结构字段做哈希：节点 id/type/title/位置/端口/模型配置 + 连线。
    /// 刻意排除执行状态（status）——执行中增量写回状态不应使版本失效，
    /// 否则正常执行也会被误判为「画布已被修改」。
    var structuralRevision: Int {
        let offset = 0x9E37_79B9_7F4A_7C15 as UInt64
        var h: UInt64 = offset
        for node in nodes {
            h = _mix(h, node.id.uuidString)
            h = _mix(h, node.type)
            h = _mix(h, node.title)
            h = _mix(h, String(node.position.x.bitPattern))
            h = _mix(h, String(node.position.y.bitPattern))
            for port in node.inputs {
                h = _mix(h, port.id.uuidString)
                h = _mix(h, port.name)
                h = _mix(h, port.dataType)
            }
            for port in node.outputs {
                h = _mix(h, port.id.uuidString)
                h = _mix(h, port.name)
                h = _mix(h, port.dataType)
            }
            if let bc = node.backendConfig {
                h = _mix(h, bc.providerType.rawValue)
                h = _mix(h, bc.providerID)
                h = _mix(h, bc.modelID)
                for (k, v) in bc.params.sorted(by: { $0.key < $1.key }) {
                    h = _mix(h, k)
                    h = _mix(h, v)
                }
            }
        }
        for edge in edges {
            h = _mix(h, edge.id.uuidString)
            h = _mix(h, edge.fromNode.uuidString)
            h = _mix(h, edge.fromPort.uuidString)
            h = _mix(h, edge.toNode.uuidString)
            h = _mix(h, edge.toPort.uuidString)
        }
        // CanvasExecutionIdentity requires nonnegative revisions. Preserve the
        // deterministic structural hash while clearing only the sign bit so
        // every graph can be represented by a valid persisted identity.
        return Int(h & UInt64(Int.max))
    }

    /// FNV-1a 64 位混合：确定性、稳定、与进程无关（避免 Hasher 每进程随机盐）。
    private func _mix(_ state: UInt64, _ s: String) -> UInt64 {
        var h = state
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h &*= 0x1000_0000_01B3
        }
        return h
    }
}

// MARK: - 审核三态（B1：reviewGate 节点 待审/通过/打回）

/// 审核节点三态：与 ReviewGateExecutor 输出（PASS/REJECT/PENDING）及持久化契约一致。
/// 值 = `backendConfig.params[CanvasStore.reviewStatusKey]` 的大写字符串；
/// 未设置 / 未知值一律归一为 `.pending`（待审）。
/// 纯函数部分（fromParams / label / hexColor / color）可单测。
enum ReviewStatus: String, Equatable, Sendable {
    case pass = "PASS"
    case reject = "REJECT"
    case pending = "PENDING"

    /// 从节点 params 解析三态（未设置或未知值 → pending）
    static func fromParams(_ params: [String: String]?) -> ReviewStatus {
        guard let raw = params?[CanvasStore.reviewStatusKey],
              let status = ReviewStatus(rawValue: raw) else { return .pending }
        return status
    }

    /// 徽标文案：待审 / 通过 / 打回
    var label: String {
        switch self {
        case .pass: return "通过"
        case .reject: return "打回"
        case .pending: return "待审"
        }
    }

    /// 三态语义色（十六进制；UI 层转 Color，纯函数可单测）
    var hexColor: String {
        switch self {
        case .pass: return "#78BFC8"    // 青：放行
        case .reject: return "#E06060"  // 红：打回
        case .pending: return "#E0B94D" // 黄：待审
        }
    }

    /// 三态语义色（SwiftUI 直用）
    var color: Color {
        switch self {
        case .pass: return Color(red: 0x78 / 255, green: 0xBF / 255, blue: 0xC8 / 255)
        case .reject: return Color(red: 0xE0 / 255, green: 0x60 / 255, blue: 0x60 / 255)
        case .pending: return Color(red: 0xE0 / 255, green: 0xB9 / 255, blue: 0x4D / 255)
        }
    }
}

// MARK: - 多画布（M4：按项目多个无限画布，参照 ComfyUI 多工作流标签）

/// 独立画布任务的持久化投影。详细任务记录仍由任务存储维护，文档保留归属和恢复索引。
struct CanvasTaskReference: Codable, Equatable, Sendable {
    var taskID: String
    var state: String
    var idempotencyKey: String
    var updatedAt: Date
}

/// 单个画布文档：图、资产、任务、视口、选择和预览均按 canvasID 独立保存。
/// 当前活动画布的图与 `CanvasStore.graph` 保持同步（`graph` 为当前画布权威副本）；
/// 非当前画布的图暂存于本文档，切换时互写。
struct CanvasDocument: Identifiable, Equatable {
    let id: UUID
    var name: String
    var graph: NodeGraph
    var assetIDs: Set<UUID>
    var tasks: [CanvasTaskReference]
    var viewport: CanvasViewportState
    var selection: Set<UUID>
    var selectionOrder: [UUID]
    var selectedGroupID: UUID?
    var previewNodeID: UUID?
    var groups: [CanvasDraft.Group]
    /// 独立草稿 key（各画布图分别落盘）。首个画布复用旧版 `DraftStore.canvasKey`（兼容迁移）。
    var draftKey: String

    init(
        id: UUID,
        name: String,
        graph: NodeGraph,
        draftKey: String,
        assetIDs: Set<UUID> = [],
        tasks: [CanvasTaskReference] = [],
        viewport: CanvasViewportState = CanvasViewportState(),
        selection: Set<UUID> = [],
        selectionOrder: [UUID] = [],
        selectedGroupID: UUID? = nil,
        previewNodeID: UUID? = nil,
        groups: [CanvasDraft.Group] = []
    ) {
        self.id = id
        self.name = name
        self.graph = graph
        self.assetIDs = assetIDs
        self.tasks = tasks
        self.viewport = viewport
        self.selection = selection
        self.selectionOrder = selectionOrder
        self.selectedGroupID = selectedGroupID
        self.previewNodeID = previewNodeID
        self.groups = groups
        self.draftKey = draftKey
    }
}

/// 画布集合持久化元数据（落盘 `canvas_collection.json`）：id / 名称 / 草稿 key / 顺序。
/// 仅存元数据，图内容由各画布草稿（draftKey → draft JSON）单独承载。
struct CanvasCollectionMeta: Codable, Equatable {
    static let currentSchemaVersion = 2

    var id: UUID
    var name: String
    var draftKey: String
    var schemaVersion: Int
    var assetIDs: Set<UUID>
    var tasks: [CanvasTaskReference]
    var viewport: CanvasViewportState
    var selection: Set<UUID>
    var selectionOrder: [UUID]
    var selectedGroupID: UUID?
    var previewNodeID: UUID?

    init(
        id: UUID,
        name: String,
        draftKey: String,
        schemaVersion: Int = 2,
        assetIDs: Set<UUID> = [],
        tasks: [CanvasTaskReference] = [],
        viewport: CanvasViewportState = CanvasViewportState(),
        selection: Set<UUID> = [],
        selectionOrder: [UUID] = [],
        selectedGroupID: UUID? = nil,
        previewNodeID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.draftKey = draftKey
        self.schemaVersion = schemaVersion
        self.assetIDs = assetIDs
        self.tasks = tasks
        self.viewport = viewport
        self.selection = selection
        self.selectionOrder = selectionOrder
        self.selectedGroupID = selectedGroupID
        self.previewNodeID = previewNodeID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, draftKey, schemaVersion, assetIDs, tasks, viewport
        case selection, selectionOrder, selectedGroupID, previewNodeID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(draftKey, forKey: .draftKey)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        // Canonical byte validation must survive decoding into a fresh Set.
        // Preserve ordered arrays; sort only these two unordered collections.
        try c.encode(assetIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .assetIDs)
        try c.encode(tasks, forKey: .tasks)
        try c.encode(viewport, forKey: .viewport)
        try c.encode(selection.sorted { $0.uuidString < $1.uuidString }, forKey: .selection)
        try c.encode(selectionOrder, forKey: .selectionOrder)
        try c.encodeIfPresent(selectedGroupID, forKey: .selectedGroupID)
        try c.encodeIfPresent(previewNodeID, forKey: .previewNodeID)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        draftKey = try c.decode(String.self, forKey: .draftKey)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        assetIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .assetIDs) ?? []
        tasks = try c.decodeIfPresent([CanvasTaskReference].self, forKey: .tasks) ?? []
        viewport = try c.decodeIfPresent(CanvasViewportState.self, forKey: .viewport) ?? CanvasViewportState()
        selection = try c.decodeIfPresent(Set<UUID>.self, forKey: .selection) ?? []
        selectionOrder = try c.decodeIfPresent([UUID].self, forKey: .selectionOrder) ?? []
        selectedGroupID = try c.decodeIfPresent(UUID.self, forKey: .selectedGroupID)
        previewNodeID = try c.decodeIfPresent(UUID.self, forKey: .previewNodeID)
    }
}

/// 画布集合持久化 envelope。旧版本直接写入 `[CanvasCollectionMeta]`，恢复时仍兼容该格式。
struct CanvasCollectionSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var currentCanvasID: String?
    var documents: [CanvasCollectionMeta]

    init(
        schemaVersion: Int = 1,
        currentCanvasID: String?,
        documents: [CanvasCollectionMeta]
    ) {
        self.schemaVersion = schemaVersion
        self.currentCanvasID = currentCanvasID
        self.documents = documents
    }
}

struct CanvasFileGeneration: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    /// SHA-256 of the canonical bytes persisted at this path.
    let digest: String

    init(device: UInt64, inode: UInt64, digest: String = "") {
        self.device = device
        self.inode = inode
        self.digest = digest
    }
}

enum CanvasCleanupJournalState: String, Codable, Equatable, Sendable {
    case prepared
    case committed
}

private func canvasCleanupTombstoneRootDigest(
    sessionRootPath: String,
    documentScope: String,
    documentEpoch: UInt64,
    epochPreviousDigest: String?,
    epochPreviousRootDigest: String? = nil
) -> String {
    let seed = [
        sessionRootPath,
        documentScope,
        String(documentEpoch),
        epochPreviousDigest ?? "",
        epochPreviousRootDigest ?? ""
    ].joined(separator: "\u{0}")
    return SHA256.hash(data: Data(seed.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func canvasCleanupEpochSuccessorDigest(
    previousRootDigest: String?,
    currentRootDigest: String,
    checkpointRootDigest: String
) -> String? {
    guard let previousRootDigest else { return nil }
    let seed = [previousRootDigest, currentRootDigest, checkpointRootDigest]
        .joined(separator: "\u{0}")
    return SHA256.hash(data: Data(seed.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func canvasCleanupCheckpointRootDigest(
    tombstoneRootDigest: String,
    checkpointDigest: String?
) -> String {
    let seed = [tombstoneRootDigest, checkpointDigest ?? ""].joined(separator: "\u{0}")
    return SHA256.hash(data: Data(seed.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

/// Crash-safe canvas deletion journal. The root path and exact draft key bind
/// recovery to one DraftStore session; no arbitrary path is ever persisted.
struct CanvasCleanupJournal: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sessionRootPath: String
    let removedDraftKey: String
    let collectionAction: String
    let replacementCollection: CanvasCollectionSnapshot?
    let removedDraftGeneration: CanvasFileGeneration?
    let collectionGeneration: CanvasFileGeneration?
    let receiptID: String?
    /// Explicit transaction identity shared by prepared/committed states and
    /// never reused by a different canvas cleanup.
    let transactionID: UUID
    /// Canonical document scope; recovery requires this to equal the draft key.
    let documentScope: String
    /// Stable per-document epoch used to reject older checkpoint resurrection.
    let documentEpoch: UInt64
    /// Digest of the preceding document epoch marker, when one exists.
    let epochPreviousDigest: String?
    /// Root seal of the preceding document epoch, when a rollover is explicit.
    let epochPreviousRootDigest: String?
    /// Derived successor seal binding the previous and current epoch roots.
    let epochSuccessorDigest: String?
    /// Digest of the preceding committed cleanup tombstone in this session.
    let tombstonePredecessorDigest: String?
    /// Monotonic, bounded tombstone history generation.
    let tombstoneGeneration: UInt64
    /// Stable root seal retained across bounded tombstone-history compaction.
    let tombstoneRootDigest: String
    /// SHA-256 of the canonical collection payload (or empty payload for remove).
    let payloadDigest: String
    /// Canonical digest of the committed checkpoint preceding this generation.
    /// It is intentionally equal to `previousDigest` when a predecessor exists.
    let checkpointDigest: String?
    /// Seal binding the checkpoint payload to this tombstone epoch root.
    let checkpointRootDigest: String
    /// Monotonic generation of the checkpoint handed off to this successor.
    let checkpointGeneration: UInt64?
    let state: CanvasCleanupJournalState?
    let transactionGeneration: UInt64
    let previousDigest: String?

    init(
        sessionRootPath: String,
        removedDraftKey: String,
        collectionAction: String,
        replacementCollection: CanvasCollectionSnapshot? = nil,
        removedDraftGeneration: CanvasFileGeneration? = nil,
        collectionGeneration: CanvasFileGeneration? = nil,
        receiptID: String? = UUID().uuidString,
        transactionID: UUID = UUID(),
        documentScope: String? = nil,
        documentEpoch: UInt64 = 1,
        epochPreviousDigest: String? = nil,
        epochPreviousRootDigest: String? = nil,
        epochSuccessorDigest: String? = nil,
        tombstonePredecessorDigest: String? = nil,
        tombstoneGeneration: UInt64 = 1,
        tombstoneRootDigest: String? = nil,
        payloadDigest: String? = nil,
        checkpointDigest: String? = nil,
        checkpointRootDigest: String? = nil,
        checkpointGeneration: UInt64? = nil,
        state: CanvasCleanupJournalState? = .prepared,
        transactionGeneration: UInt64 = 1,
        previousDigest: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionRootPath = sessionRootPath
        self.removedDraftKey = removedDraftKey
        self.collectionAction = collectionAction
        self.replacementCollection = replacementCollection
        self.removedDraftGeneration = removedDraftGeneration
        self.collectionGeneration = collectionGeneration
        self.receiptID = receiptID
        self.transactionID = transactionID
        self.documentScope = documentScope ?? removedDraftKey
        self.documentEpoch = documentEpoch
        self.epochPreviousDigest = epochPreviousDigest
        self.epochPreviousRootDigest = epochPreviousRootDigest
        self.tombstonePredecessorDigest = tombstonePredecessorDigest
        self.tombstoneGeneration = tombstoneGeneration
        self.tombstoneRootDigest = tombstoneRootDigest ?? canvasCleanupTombstoneRootDigest(
            sessionRootPath: sessionRootPath,
            documentScope: self.documentScope,
            documentEpoch: documentEpoch,
            epochPreviousDigest: epochPreviousDigest,
            epochPreviousRootDigest: epochPreviousRootDigest
        )
        self.payloadDigest = payloadDigest ?? Self.defaultPayloadDigest(
            collectionAction: collectionAction,
            replacementCollection: replacementCollection
        )
        self.checkpointDigest = checkpointDigest ?? previousDigest
        self.checkpointRootDigest = checkpointRootDigest ?? canvasCleanupCheckpointRootDigest(
            tombstoneRootDigest: self.tombstoneRootDigest,
            checkpointDigest: self.checkpointDigest
        )
        self.epochSuccessorDigest = epochSuccessorDigest ?? canvasCleanupEpochSuccessorDigest(
            previousRootDigest: epochPreviousRootDigest,
            currentRootDigest: self.tombstoneRootDigest,
            checkpointRootDigest: self.checkpointRootDigest
        )
        self.checkpointGeneration = checkpointGeneration
            ?? (transactionGeneration > 1 ? transactionGeneration - 1 : nil)
        self.state = state
        self.transactionGeneration = transactionGeneration
        self.previousDigest = previousDigest
    }

    private static func defaultPayloadDigest(
        collectionAction: String,
        replacementCollection: CanvasCollectionSnapshot?
    ) -> String {
        let payload = (collectionAction == "replace" && replacementCollection != nil)
            ? (try? CanvasStore.cleanupEncodedData(replacementCollection)) ?? Data()
            : Data()
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct CanvasCleanupReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sessionRootPath: String
    let removedDraftKey: String
    let receiptID: String
    let transactionID: UUID
    let documentScope: String
    let documentEpoch: UInt64
    let epochPreviousDigest: String?
    let epochPreviousRootDigest: String?
    let epochSuccessorDigest: String?
    let tombstonePredecessorDigest: String?
    let tombstoneGeneration: UInt64
    let tombstoneRootDigest: String
    /// Logical generation sealed by this committed cleanup tombstone.
    let transactionGeneration: UInt64
    let checkpointDigest: String?
    let checkpointRootDigest: String
    let journalDigest: String
    let removedDraftGeneration: CanvasFileGeneration?
    let collectionGeneration: CanvasFileGeneration?

    init(
        sessionRootPath: String,
        removedDraftKey: String,
        receiptID: String,
        removedDraftGeneration: CanvasFileGeneration?,
        collectionGeneration: CanvasFileGeneration?,
        transactionID: UUID,
        documentScope: String,
        documentEpoch: UInt64 = 1,
        epochPreviousDigest: String? = nil,
        epochPreviousRootDigest: String? = nil,
        epochSuccessorDigest: String? = nil,
        tombstonePredecessorDigest: String? = nil,
        tombstoneGeneration: UInt64 = 1,
        tombstoneRootDigest: String? = nil,
        transactionGeneration: UInt64 = 0,
        checkpointDigest: String? = nil,
        checkpointRootDigest: String? = nil,
        journalDigest: String = ""
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionRootPath = sessionRootPath
        self.removedDraftKey = removedDraftKey
        self.receiptID = receiptID
        self.transactionID = transactionID
        self.documentScope = documentScope
        self.documentEpoch = documentEpoch
        self.epochPreviousDigest = epochPreviousDigest
        self.epochPreviousRootDigest = epochPreviousRootDigest
        self.tombstonePredecessorDigest = tombstonePredecessorDigest
        self.tombstoneGeneration = tombstoneGeneration
        self.tombstoneRootDigest = tombstoneRootDigest ?? canvasCleanupTombstoneRootDigest(
            sessionRootPath: sessionRootPath,
            documentScope: documentScope,
            documentEpoch: documentEpoch,
            epochPreviousDigest: epochPreviousDigest,
            epochPreviousRootDigest: epochPreviousRootDigest
        )
        self.transactionGeneration = transactionGeneration
        self.checkpointDigest = checkpointDigest
        self.checkpointRootDigest = checkpointRootDigest ?? canvasCleanupCheckpointRootDigest(
            tombstoneRootDigest: self.tombstoneRootDigest,
            checkpointDigest: checkpointDigest
        )
        self.epochSuccessorDigest = epochSuccessorDigest ?? canvasCleanupEpochSuccessorDigest(
            previousRootDigest: epochPreviousRootDigest,
            currentRootDigest: self.tombstoneRootDigest,
            checkpointRootDigest: self.checkpointRootDigest
        )
        self.journalDigest = journalDigest
        self.removedDraftGeneration = removedDraftGeneration
        self.collectionGeneration = collectionGeneration
    }
}

private struct CanvasCleanupJSONScanner {
    let bytes: [UInt8]
    let maxDepth: Int
    let maxObjectFields: Int
    let maxArrayElements: Int
    var index = 0

    mutating func validate() -> Bool {
        guard parseValue(depth: 0) else { return false }
        skipWhitespace()
        return index == bytes.count
    }

    private mutating func parseValue(depth: Int) -> Bool {
        guard depth <= maxDepth else { return false }
        skipWhitespace()
        guard let byte = peek() else { return false }
        switch byte {
        case 0x22: return parseString() != nil
        case 0x7B: return parseObject(depth: depth)
        case 0x5B: return parseArray(depth: depth)
        case 0x74: return parseLiteral("true")
        case 0x66: return parseLiteral("false")
        case 0x6E: return parseLiteral("null")
        case 0x2D, 0x30...0x39: return parseNumber()
        default: return false
        }
    }

    private mutating func parseObject(depth: Int) -> Bool {
        guard consume(0x7B) else { return false }
        skipWhitespace()
        if consume(0x7D) { return true }
        var keys: Set<String> = []
        var fieldCount = 0
        while true {
            guard let key = parseString(), keys.insert(key).inserted else { return false }
            skipWhitespace()
            guard consume(0x3A), parseValue(depth: depth + 1) else { return false }
            fieldCount += 1
            guard fieldCount <= maxObjectFields else { return false }
            skipWhitespace()
            if consume(0x7D) { return true }
            guard consume(0x2C) else { return false }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) -> Bool {
        guard consume(0x5B) else { return false }
        skipWhitespace()
        if consume(0x5D) { return true }
        var elementCount = 0
        while true {
            guard parseValue(depth: depth + 1) else { return false }
            elementCount += 1
            guard elementCount <= maxArrayElements else { return false }
            skipWhitespace()
            if consume(0x5D) { return true }
            guard consume(0x2C) else { return false }
            skipWhitespace()
        }
    }

    private mutating func parseString() -> String? {
        guard consume(0x22) else { return nil }
        var utf8 = Data()
        while let byte = peek() {
            index += 1
            switch byte {
            case 0x22:
                return String(data: utf8, encoding: .utf8)
            case 0x5C:
                guard let escaped = peek() else { return nil }
                index += 1
                switch escaped {
                case 0x22, 0x5C, 0x2F: utf8.append(escaped)
                case 0x62: utf8.append(0x08)
                case 0x66: utf8.append(0x0C)
                case 0x6E: utf8.append(0x0A)
                case 0x72: utf8.append(0x0D)
                case 0x74: utf8.append(0x09)
                case 0x75:
                    guard let scalar = parseUnicodeScalar(),
                          let value = UnicodeScalar(scalar) else { return nil }
                    utf8.append(contentsOf: String(value).utf8)
                default: return nil
                }
            default:
                guard byte >= 0x20 else { return nil }
                utf8.append(byte)
            }
        }
        return nil
    }

    private mutating func parseUnicodeScalar() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = hexValue(bytes[index]) else { return nil }
            value = (value << 4) | UInt32(digit)
            index += 1
        }
        guard !(0xD800...0xDFFF).contains(value), value <= 0x10FFFF else { return nil }
        return value
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private mutating func parseLiteral(_ literal: String) -> Bool {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index..<(index + literalBytes.count)]) == literalBytes else {
            return false
        }
        index += literalBytes.count
        return true
    }

    private mutating func parseNumber() -> Bool {
        let start = index
        _ = consume(0x2D)
        if consume(0x30) {
            if let next = peek(), (0x30...0x39).contains(next) { return false }
        } else {
            guard let first = peek(), (0x31...0x39).contains(first) else { return false }
            index += 1
            while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
        }
        if consume(0x2E) {
            guard let first = peek(), (0x30...0x39).contains(first) else { return false }
            index += 1
            while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
        }
        if let next = peek(), next == 0x65 || next == 0x45 {
            index += 1
            if !consume(0x2B) {
                _ = consume(0x2D)
            }
            guard let first = peek(), (0x30...0x39).contains(first) else { return false }
            index += 1
            while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
        }
        return index > start
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func consume(_ expected: UInt8) -> Bool {
        guard peek() == expected else { return false }
        index += 1
        return true
    }
}

/// 集合恢复时可观察的活动画布诊断。诊断不会阻断安全回退到首画布。
enum CanvasCollectionRestoreDiagnostic: Equatable, Sendable {
    case corruptCollection
    case duplicateCanvasID(UUID)
    case duplicateDraftKey(String)
    case missingCurrentCanvasID
    case invalidCurrentCanvasID(String)
    case unknownCurrentCanvasID(UUID)
}

/// 画布全局状态：节点图 + 交互中间态 + 调度器 + 事件回调。
@MainActor
@Observable
final class CanvasStore {
    var graph: NodeGraph

    /// AJ-12 多选集合：当前选中节点 id（ComfyUI LiteGraph 多选语义）。单选即单元素集合。
    var selectedNodeIDs: Set<UUID> = []

    /// 资产事实源：按画布隔离，迁移/导入/生成结果由上层登记。
    let assetStore = CanvasAssetStore()
    /// 注入的 ArtifactStore（唯一收据事实源，生产默认 ArtifactStore.shared）：
    /// 生产读取 seam 用它把节点 params["artifact.id"] 锚点解析为持久化收据。
    private let artifactStore: ArtifactStore
    /// 当前进程内的轻量引用投影；完整资产内容由 CanvasAssetStore 独立持久化。
    private var assetIDsByCanvas: [UUID: Set<UUID>] = [:]
    /// Synchronous UI projection of the canonical asset fact source.
    /// `result.*` is intentionally absent from new writes and is consulted
    /// only by `resultMedia` for legacy documents.
    private var assetProjectionByID: [UUID: MediaAsset] = [:]
    /// Actor 索引完成异步登记后递增，驱动 AssetPanel 重新查询而不依赖图结构变更竞态。
    private(set) var assetIndexRevision = 0

    /// 画布视口状态由 CanvasView/MiniMapView 共同消费，不允许各 View 另建事实源。
    var viewportState = CanvasViewportState()


    /// 最近选中顺序（主选中投影用；多选时「最近选中」= 主节点，供右键/面板等单节点语义）
    private var selectionOrder: [UUID] = []

    /// 主选中节点（兼容旧单选读取/写入）：读取 = 最近选中节点；写入 = 清空现有选择并单选该节点。
    var selectedNodeID: UUID? {
        get { selectionOrder.last ?? selectedNodeIDs.first }
        set {
            if let id = newValue {
                selectionOrder = [id]
                selectedNodeIDs = [id]
            } else {
                selectionOrder = []
                selectedNodeIDs = []
            }
        }
    }
    /// AJ-21：画布组集合（ComfyUI 组）
    var groups: [CanvasGroup] = []

    /// B4：当前选中组 id（选中后显示四角缩放手柄；单击空白/选中节点时清除）
    var selectedGroupID: UUID?

    // MARK: 多画布（M4）：集合 + 当前指针 + 每画布独立草稿 key

    /// 全部画布文档（当前画布图与 `graph` 同步；切换时互写）
    private(set) var canvasDocuments: [CanvasDocument]
    /// 当前活动画布 id
    private(set) var currentCanvasID: UUID
    /// 最近一次集合恢复的活动画布诊断；nil 表示使用了有效的持久化 ID。
    private(set) var collectionRestoreDiagnostic: CanvasCollectionRestoreDiagnostic?
    /// attachDraftStore 启动的集合恢复任务句柄（无集合文件时保持 nil）。
    /// 测试缝：调用方 await task.value 即可确定性地等待恢复完成，
    /// 替代轮询 canvasDocuments/collectionRestoreDiagnostic（慢 CI 上会静默漏检）。
    private(set) var collectionRestoreTask: Task<Void, Never>?
    /// 集合恢复世代：任何用户态画布变更都会使在途恢复失效。
    private var collectionRestoreGeneration: UInt64 = 0
    /// 仅供确定性 race 测试在后台解码完成、主 actor apply 前暂停。
    @ObservationIgnored
    internal var collectionRestoreBeforeApplyHook: (@Sendable () async -> Void)?
    /// 仅供确定性 cleanup TOCTOU 测试在最终身份复核前替换 cleanup 输入。
    @ObservationIgnored
    internal var cleanupBeforeDraftClearHook: (@Sendable () -> Void)?
    /// 仅供确定性 cleanup journal 测试在 candidate 身份读回后替换 successor。
    @ObservationIgnored
    internal var cleanupAfterCandidateReadHook: (@Sendable () -> Void)?
    /// 仅供确定性测试在 successor promotion 后替换 active checkpoint。
    @ObservationIgnored
    internal var cleanupAfterCheckpointPromotionHook: (@Sendable () -> Void)?
    /// 仅供确定性测试在 marker 验证后重建新一代 marker。
    @ObservationIgnored
    internal var cleanupBeforeMarkerRemovalHook: (@Sendable () -> Void)?
    /// 仅供确定性 crash-window 测试模拟 clear 后 receipt 尚未落盘。
    @ObservationIgnored
    internal var cleanupBeforeReceiptHook: (@Sendable () -> Bool)?

    /// 当前画布文档（兜底取第一个，保证恒非空）
    var currentCanvas: CanvasDocument {
        canvasDocuments.first { $0.id == currentCanvasID } ?? canvasDocuments[0]
    }
    /// 启动恢复门控：后台预读草稿期间只要用户改变过画布，就拒绝旧快照覆盖新状态。
    private(set) var mutationGeneration: UInt64 = 0
    /// 当前画布草稿 key（首画布 = 旧版 `canvas`，兼容既有草稿迁移）
    var currentDraftKey: String { currentCanvas.draftKey }

    /// 画布集合持久化文件名（放在 DraftStore 根目录）
    nonisolated static let collectionFileName = "canvas_collection.json"
    /// 删除画布的崩溃恢复 journal（同一 DraftStore 根目录）。
    nonisolated static let cleanupJournalFileName = "canvas_cleanup.json"
    /// 单个有界 committed successor candidate；恢复永远只检查主 journal + 这一项。
    nonisolated static let cleanupJournalCandidateFileName = "canvas_cleanup.pending.json"
    /// 已消费 cleanup journal 的一次性 receipt。
    nonisolated static let cleanupReceiptFileName = "canvas_cleanup.receipt.json"
    nonisolated static func cleanupJournalURL(at directory: URL) -> URL {
        directory.appendingPathComponent(cleanupJournalFileName)
    }
    nonisolated static func cleanupJournalCandidateURL(at directory: URL) -> URL {
        directory.appendingPathComponent(cleanupJournalCandidateFileName)
    }
    nonisolated static func cleanupReceiptURL(at directory: URL) -> URL {
        directory.appendingPathComponent(cleanupReceiptFileName)
    }
    /// 集合恢复失败时保留原文的隔离路径。
    nonisolated static func collectionQuarantineURL(at directory: URL) -> URL {
        directory
            .appendingPathComponent("quarantine", isDirectory: true)
            .appendingPathComponent(collectionFileName)
    }
    /// 新画布草稿 key（按唯一 id 隔离）
    nonisolated static func canvasDraftKey(for id: UUID) -> String { "canvas.\(id.uuidString)" }
    /// 集合文件是否存在（F7 兼容：多画布模式跳过单画布自动恢复/崩溃提示）
    static func collectionFileExists(at directory: URL) -> Bool {
        isOwnedRegularFile(at: directory.appendingPathComponent(collectionFileName))
    }
    /// 模型选择面板目标节点（非 nil 时 ContentView 呈现 ModelConfigPanelView sheet）
    var modelPanelNodeID: UUID?
    /// 内容编辑面板目标节点（非 nil 时 ContentView 呈现 NodeContentEditorView sheet）
    var contentEditorNodeID: UUID?
    /// 节点内容存储键：E15 双击编辑器 / E16 聊天指令共用 `backendConfig.params[Self.nodeContentKey]`
    static let nodeContentKey = "content"
    /// 审核状态存储键（B1 契约键）：reviewGate 节点三态持久化于
    /// `backendConfig.params[Self.reviewStatusKey]`，值大写 "PASS"/"REJECT"/"PENDING"
    /// （与 ReviewGateExecutor 输出键一致）
    nonisolated static let reviewStatusKey = "review.status"
    /// 分镜锚点存储键（P2 契约键）：节点锚点持久化于 `backendConfig.params[Self.anchorKey]`，
    /// 值 = "x,y"（归一化 0...1，两位小数，与 CanvasCore.StoryboardAnchor.encoded() 一致）。
    /// 键名与 CanvasCore 聚合器/模型一致性由测试守护（跨层契约）。
    nonisolated static let anchorKey = "anchor"
    /// 新资产事实源引用键；result.* 仅保留为旧节点兼容读取/迁移字段。
    nonisolated static let assetIDKey = "asset.id"
    /// 执行时必须使用节点自身 provider/model 的类型。来源节点和纯处理节点不消费模型。
    private static let independentlyConfiguredModelNodeTypes: Set<String> = [
        "llm", "image", "video",
        ManjuNodeType.plotOutline.rawValue,
        ManjuNodeType.script.rawValue,
        ManjuNodeType.storyboard.rawValue,
        ManjuNodeType.imagePrompt.rawValue,
        ManjuNodeType.videoPrompt.rawValue,
        ManjuNodeType.imageGen.rawValue,
        ManjuNodeType.videoGen.rawValue,
        ManjuNodeType.qcCheck.rawValue,
    ]
    var isRunning = false
    var statusMessage: String?
    var pendingEdge: PendingEdge?
    /// E17：拖拽连线中实时吸附到的目标端口（nodeID, portID）→ 端口高亮（LiteGraph 吸附语义）
    private(set) var edgeTarget: (nodeID: UUID, portID: UUID)?
    /// C2-1：吸附目标端口类型是否合法（LiteGraph isValidConnection 语义）→ 合法绿 / 非法红高亮
    private(set) var edgeTargetValid = true
    /// 连线吸附阈值（画布坐标；LiteGraph 端口命中区 ~20px）
    static let edgeSnapTolerance = 22.0
    /// 画布 → 聊天 的事件出口（BridgeStore 注入）
    var onEvent: ((CanvasEvent) -> Void)?

    /// 真实执行上下文（I6 P0-1：协议下沉 CanvasCore，真实 Invoker 注入）：
    /// LLM → MinisCore DashScopeProvider / OpenAICompatibleProvider；
    /// 生图 → Gimage2Provider（无 key 降级任务单）；Blender → BlenderBridge。
    let context: GraphExecutionContext
    private let executionScope: CanvasExecutionScopeBox
    private let recoveryScope: CanvasRecoveryScopeBox
    private let schedulerBox = SchedulerBox()
    /// C2-2 中断标志：主线程「停止」按钮置位，后台调度线程逐节点轮询
    private let cancelFlag = ExecutionCancelFlag()
    /// C2-2 执行进度（nil = 未在执行）：后台事件流 → 主线程更新，进度条/节点名实时展示
    private(set) var executionProgress: ExecutionProgress?
    /// 最近一次执行结果（真实生图结果回填 backendConfig.params 时读取）
    private(set) var lastResult: DAGExecutionResult?
    /// P0-1 当前运行信封（runID + 图结构版本）：运行开始时记录，写回前校验。
    /// 非 nil 表示有一次执行尚未完成；finishRun 时校验并清空。
    private(set) var currentRunEnvelope: RunEnvelope?
    /// 最近一次已接受完成的运行，用于给 finishRun 发起的异步资产投影做
    /// run 级 compare-and-swap；旧任务不能在新运行期间或之后覆盖结果。
    private var lastCompletedRunID: UUID?
    /// U2-r 节点级模型对话状态（nodeID → 独立历史，与 agent 的 ChatStore 完全隔离）
    /// 预留：节点×LLM 已前台下线（AJ-74），NodeChatStore 接口保留待后续恢复。
    var nodeChat = NodeChatStore()

    /// C3-3 会话自动保存：防抖草稿存储（nil = 未装配，测试默认不落盘）。
    /// 由 BridgeStore.attachProductionServices 装配（草稿落 Application Support/MinisCanvas/drafts）。
    private(set) var draftStore: DraftStore?
    /// Canonical directory for the CanvasAssetStore snapshot. It matches the
    /// VideoTaskStore directory used by CanvasTaskCoordinator writeback.
    let assetPersistenceDirectory: URL
    /// Runtime-scoped preferences for inspector layout state.
    private let preferencesDefaults: UserDefaults

    // MARK: C5 画布编辑效率（学 ComfyUI：搜索面板 / 复制粘贴 / 删除 / 撤销）

    /// 节点搜索面板是否展示（双击画布空白触发，ComfyUI showSearchBox 语义）
    private(set) var isNodeSearchPresented = false
    /// 搜索面板弹出位置（世界坐标；回车创建的节点落在此处）
    private(set) var nodeSearchPosition = Point(x: 400, y: 300)
    /// 剪贴板（LiteGraph copyToClipboard：节点 + 子图内部连线相对映射）
    private(set) var clipboard: CanvasClipboard?

    /// U-3：粘贴后揭示请求（渲染层观察并自动平移视口到粘贴内容）
    var revealRequest: RevealRequest?
    /// 撤销快照栈（LiteGraph beforeChange 语义：结构变更前压入整图快照，⌘Z 弹出恢复）
    private var undoStack: [NodeGraph] = []
    private static let maxUndoDepth = 50

    struct PendingEdge {
        var fromNode: UUID
        var fromPort: UUID
        var end: Point
    }

    init(
        graph: NodeGraph = NodeGraph(),
        videoTaskStore: VideoTaskStore? = nil,
        videoAssetDirectory: URL? = nil,
        videoAssetDownloader: any VideoAssetDownloader = URLSessionVideoAssetDownloader(),
        videoProviderFactory: @escaping @Sendable (String) throws -> any CloudVideoGenerator = {
            try MinisCanvasVideoInvoker.resolveVideoProvider($0)
        },
        /// 唯一 ArtifactStore 注入（P3-L1-C0 artifact production consumer）：
        /// 收据事实源只允许一个实例贯穿生产 writeback 路径；生产默认用共享实例，
        /// fixture/测试注入隔离实例。
        artifactStore: ArtifactStore? = nil,
        preferencesDefaults: UserDefaults? = nil
    ) {
        // Resolve the formal test contract before any shared store is touched,
        // including when a caller explicitly injects preferencesDefaults.
        let defaultProfile = RuntimeIsolationProfile.formalTestProfileForDefaultConsumer()
        if defaultProfile == nil, RuntimeIsolationProfile.isRunningInTestProcess() {
            preconditionFailure("Formal test profile required for CanvasStore defaults")
        }
        let preferencesDefaults = preferencesDefaults
            ?? defaultProfile?.makeUserDefaults() ?? .standard
        let videoTaskStore = videoTaskStore ?? defaultProfile.map {
            VideoTaskStore(directory: $0.minisCoreDirectory)
        } ?? .shared
        let artifactStore = artifactStore ?? defaultProfile.map {
            ArtifactStore(directory: $0.minisCoreDirectory.appendingPathComponent("artifacts", isDirectory: true))
        } ?? .shared
        self.graph = graph
        self.assetPersistenceDirectory = videoTaskStore.directory
        self.artifactStore = artifactStore
        self.preferencesDefaults = preferencesDefaults
        // A3：恢复右侧文本面板持久化尺寸
        self.textInspectorWidth = preferencesDefaults.object(forKey: "canvas.textInspectorWidth") as? Double ?? 360
        self.textInspectorHeight = preferencesDefaults.object(forKey: "canvas.textInspectorHeight") as? Double ?? 420
        let firstID = UUID()
        self.canvasDocuments = [CanvasDocument(id: firstID, name: "画布 1", graph: graph, draftKey: DraftStore.canvasKey)]
        self.currentCanvasID = firstID
        self.collectionRestoreDiagnostic = nil
        let executionScope = CanvasExecutionScopeBox()
        self.executionScope = executionScope
        let recoveryScope = CanvasRecoveryScopeBox()
        self.recoveryScope = recoveryScope
        self.context = GraphExecutionContext(
            executors: NodeExecutors(
                llmInvoker: MinisCanvasLLMInvoker(),
                blenderInvoker: MinisCanvasBlenderInvoker(),
                mediaAssetResolver: assetStore
            ),
            imageInvoker: MinisCanvasImageInvoker(),
            videoInvoker: MinisCanvasVideoInvoker(
                taskStore: videoTaskStore,
                assetDirectory: videoAssetDirectory,
                assetDownloader: videoAssetDownloader,
                providerFactory: videoProviderFactory,
                assetStore: assetStore,
                artifactStore: artifactStore,
                scopeProvider: { [executionScope] node in executionScope.identity(for: node) },
                executionLeaseProvider: { [executionScope] node in
                    executionScope.executionLease(for: node)
                },
                workerProjectionProvider: { [executionScope] node, provider in
                    executionScope.workerProjection(for: node, provider: provider)
                },
                recoveryIdentityProvider: { [recoveryScope] context in recoveryScope.identity(for: context) },
                recoveryWorkerProjectionProvider: { [recoveryScope] context in
                    recoveryScope.workerProjection(for: context)
                }
            )
        )
        refreshRecoveryScope()
    }

    /// P2-3 测试注入口：自定义执行上下文（注入 stub Invoker 验证 BLOCKED / 输出写回等流程）。
    /// 生产路径走 `init(graph:)` 默认上下文；本入口仅测试使用。
    /// B1: 资产持久化目录跟随注入上下文的 task-store 目录（test-only seam）。
    /// GraphExecutionContext.videoInvoker 是 `any VideoGenerating` 存在类型，
    /// 无法安全地从中取出 `MinisCanvasVideoInvoker.taskStore.directory`，因此
    /// 显式暴露可选参数；nil 保持原有默认（VideoTaskStore.defaultDirectory()），
    /// 不改变既有测试调用。
    init(
        graph: NodeGraph,
        context: GraphExecutionContext,
        assetPersistenceDirectory: URL? = nil
    ) {
        let defaultProfile = RuntimeIsolationProfile.formalTestProfileForDefaultConsumer()
        if defaultProfile == nil, RuntimeIsolationProfile.isRunningInTestProcess() {
            preconditionFailure("Formal test profile required for CanvasStore defaults")
        }
        self.graph = graph
        self.assetPersistenceDirectory = assetPersistenceDirectory
            ?? defaultProfile?.minisCoreDirectory ?? VideoTaskStore.defaultDirectory()
        self.artifactStore = defaultProfile.map {
            ArtifactStore(directory: $0.minisCoreDirectory.appendingPathComponent("artifacts", isDirectory: true))
        } ?? .shared
        self.preferencesDefaults = defaultProfile?.makeUserDefaults() ?? .standard
        let firstID = UUID()
        self.canvasDocuments = [CanvasDocument(id: firstID, name: "画布 1", graph: graph, draftKey: DraftStore.canvasKey)]
        self.currentCanvasID = firstID
        self.collectionRestoreDiagnostic = nil
        self.executionScope = CanvasExecutionScopeBox()
        self.recoveryScope = CanvasRecoveryScopeBox()
        self.context = context
        refreshRecoveryScope()
    }

    // MARK: - C3-3 会话自动保存（512ms 防抖落盘 + 崩溃恢复）

    /// 装配防抖草稿存储（App 启动时由 BridgeStore 调用）。
    /// 不自动恢复草稿——恢复由 BridgeStore 的「崩溃恢复提示」驱动（聊天提示 → 恢复/丢弃指令）。
    /// M4：装配后若存在画布集合文件（多画布模式），恢复集合 + 各画布图。
    func attachDraftStore(_ store: DraftStore) {
        draftStore = store
        recoverCleanupJournalIfPresent(store)
        restoreCollectionIfPresent()
        // B2: conservative legacy asset snapshot migration at the startup call-site
        // seam. The DraftStore root IS the legacy Session/DraftStore root
        // (<AppSupport>/MinisCanvas); the canonical snapshot lives under the
        // VideoTaskStore root (<AppSupport>/MinisCore). Migration runs before the
        // canonical load so the restored asset store observes migrated assets, and
        // stays at this call-site instead of CanvasAssetStore.loadSnapshot so the
        // existing root assertion tests are untouched. Policy is copy/merge-only and
        // idempotent; the legacy snapshot is always retained and never deleted.
        _ = LegacyCanvasAssetMigration.migrateIfNeeded(
            legacyDirectory: store.directory,
            currentDirectory: assetPersistenceDirectory
        )
        if let snapshot = CanvasAssetStore.loadSnapshot(from: assetPersistenceDirectory) {
            restoreAssetSnapshot(snapshot)
        }
    }

    /// 恢复独立资产事实源及其在画布文档中的引用投影。
    /// 该入口也供 clean-exit 自动恢复使用，因为自动恢复发生在 DraftStore 装配之前。
    func restoreAssetSnapshot(_ snapshot: CanvasAssetStoreSnapshot) {
        assetIDsByCanvas = snapshot.assetsByCanvas.mapValues { Set($0.map(\.id)) }
        // A malformed or legacy snapshot may reuse an asset ID across canvases.
        // Keep the per-canvas fact source intact, while making the UI projection
        // deterministic instead of trapping in Dictionary(uniqueKeysWithValues:).
        var projection: [UUID: MediaAsset] = [:]
        var projectionCanvasIDs: [UUID: UUID] = [:]
        for (canvasID, assets) in snapshot.assetsByCanvas.sorted(by: {
            $0.key.uuidString < $1.key.uuidString
        }) {
            for asset in assets {
                guard let current = projection[asset.id] else {
                    projection[asset.id] = asset
                    projectionCanvasIDs[asset.id] = canvasID
                    continue
                }
                let currentCanvasID = projectionCanvasIDs[asset.id] ?? canvasID
                let shouldReplace =
                    asset.version > current.version
                    || (asset.version == current.version && asset.updatedAt > current.updatedAt)
                    || (
                        asset.version == current.version
                        && asset.updatedAt == current.updatedAt
                        && canvasID.uuidString > currentCanvasID.uuidString
                    )
                if shouldReplace {
                    projection[asset.id] = asset
                    projectionCanvasIDs[asset.id] = canvasID
                }
            }
        }
        assetProjectionByID = projection
        for index in canvasDocuments.indices {
            if let assetIDs = assetIDsByCanvas[canvasDocuments[index].id] {
                canvasDocuments[index].assetIDs = assetIDs
            }
        }
        assetIndexRevision &+= 1
        Task { [assetStore] in
            await assetStore.replace(with: snapshot)
        }
    }

    /// Capture restored canvas graphs for startup-only scoped media validation.
    /// The current graph may be newer than its document projection, so it wins
    /// for the active canvas.
    private func refreshRecoveryScope() {
        recoveryScope.replace(canvasID: currentCanvasID, graph: graph)
    }

    /// 画布图（节点/连线/位置/内容/模型配置）变更后调用：512ms 防抖自动保存（不丢数据）。
    /// 所有图变更入口（增删节点/连线/移动/布局/内容/模型配置/执行写回）均调用本方法；
    /// 防抖窗口内多次变更只落盘最后一次，App 退出前由 flushCanvasDraft() 兜底。
    /// M4：按当前画布的独立草稿 key 落盘（多画布互不覆盖）。
    func noteGraphChanged() {
        mutationGeneration &+= 1
        invalidateCollectionRestore()
        refreshRecoveryScope()
        if let envelope = currentRunEnvelope,
           graph.structuralRevision != envelope.graphRevision {
            executionScope.end()
            cancelFlag.cancel()
        }
        guard let store = draftStore else { return }
        syncCurrentStateToDocument()
        let draft = CanvasDraft(
            graph: graph,
            groups: CanvasDraft.encodeGroups(groups),
            savedAt: Date(),
            assetIDs: currentCanvas.assetIDs,
            tasks: currentCanvas.tasks,
            viewport: viewportState,
            selection: selectedNodeIDs,
            selectionOrder: selectionOrder,
            selectedGroupID: selectedGroupID,
            previewNodeID: previewNodeID
        )
        guard let data = try? JSONEncoder().encode(draft) else { return }
        store.scheduleSave(key: currentDraftKey, payload: data)
        saveCollection()
    }

    /// 立即落盘当前画布草稿（App 退出 / 切画布 / 测试断言；等价 ComfyUI beforeunload flush）
    func flushCanvasDraft() {
        draftStore?.flushNow(key: currentDraftKey)
    }

    /// 磁盘上上次未保存的画布草稿（崩溃恢复提示用）；无则 nil。
    /// M4：多画布模式（集合存在）各画布草稿即持久存储，不触发单画布崩溃恢复提示 → 返回 nil。
    func recoverableCanvasDraft() -> CanvasDraft? {
        guard let store = draftStore else { return nil }
        guard canvasDocuments.count == 1,
              !Self.pathExists(
                  at: store.directory.appendingPathComponent(Self.collectionFileName)
              ) else { return nil }
        guard let data = store.load(key: currentDraftKey),
              data.count <= Self.cleanupPayloadBytesLimit,
              Self.cleanupJSONStructureIsStrict(data),
              let draft = try? JSONDecoder().decode(CanvasDraft.self, from: data),
              (1...3).contains(draft.schemaVersion),
              !draft.nodes.isEmpty,
              (try? draft.toGraph().validate()) != nil else { return nil }
        return draft
    }

    /// 从草稿恢复画布：重建节点图（节点/连线/位置/端口/状态/模型配置/内容）。
    /// 返回是否恢复成功（空草稿返回 false）。
    @discardableResult
    func restoreCanvas(
        from draft: CanvasDraft,
        expectedMutationGeneration: UInt64? = nil
    ) -> Bool {
        if let expectedMutationGeneration,
           expectedMutationGeneration != mutationGeneration {
            return false
        }
        guard !draft.nodes.isEmpty,
              (1...3).contains(draft.schemaVersion) else { return false }
        let restoredGraph = draft.toGraph()
        guard (try? restoredGraph.validate()) != nil else { return false }
        invalidateCollectionRestore()
        graph = restoredGraph
        groups = draft.toGroups()
        // assetRef 输出互斥：旧图「image+video 双端口并存」节点按已挂载资产 kind 唯一化
        Self.normalizeAssetRefPorts(in: &graph)
        let legacyAssets = canonicalizeLegacyMedia(in: &graph, canvasID: currentCanvasID)
        if let index = canvasDocuments.firstIndex(where: { $0.id == currentCanvasID }) {
            canvasDocuments[index].graph = graph
            canvasDocuments[index].groups = CanvasDraft.encodeGroups(groups)
        }
        let draftHasCanvasState = draft.schemaVersion >= 3
        if draftHasCanvasState {
            assetIDsByCanvas[currentCanvasID] = draft.assetIDs
        }
        if let index = canvasDocuments.firstIndex(where: { $0.id == currentCanvasID }) {
            if draftHasCanvasState {
                canvasDocuments[index].assetIDs = draft.assetIDs
            }
            if draftHasCanvasState {
                canvasDocuments[index].tasks = draft.tasks
            }
        }
        if draftHasCanvasState {
            viewportState = draft.viewport
            selectedNodeIDs = draft.selection.filter { graph.node(id: $0) != nil }
            selectionOrder = draft.selectionOrder.filter { selectedNodeIDs.contains($0) }
            if selectionOrder.isEmpty { selectionOrder = Array(selectedNodeIDs) }
            selectedGroupID = draft.selectedGroupID.flatMap { id in groups.contains(where: { $0.id == id }) ? id : nil }
            previewNodeID = draft.previewNodeID.flatMap { graph.node(id: $0) != nil ? $0 : nil }
        } else {
            loadInteractiveState(from: currentCanvas)
        }
        projectLegacyAssets(legacyAssets, canvasID: currentCanvasID)
        statusMessage = "已恢复上次画布草稿（\(draft.nodes.count) 节点 · \(draft.edges.count) 连线）"
        refreshRecoveryScope()
        return true
    }

    /// 丢弃画布草稿（用户选择不恢复 / 恢复完成后清理）
    func discardCanvasDraft() {
        draftStore?.clear(key: currentDraftKey)
    }

    /// 持久化画布归属的任务索引；任务详情由独立任务存储维护。
    func setTaskReferences(_ references: [CanvasTaskReference]) {
        guard let index = canvasDocuments.firstIndex(where: { $0.id == currentCanvasID }) else { return }
        var seen = Set<String>()
        canvasDocuments[index].tasks = references.filter { seen.insert($0.taskID).inserted }
        noteGraphChanged()
    }

    /// 更新当前画布的资产引用集合；资产实体本身由 CanvasAssetStore 维护。
    func setAssetReferences(_ assetIDs: Set<UUID>) {
        assetIDsByCanvas[currentCanvasID] = assetIDs
        noteGraphChanged()
    }

    /// 更新唯一 viewport 事实源并进入同一防抖保存路径。
    func updateViewport(_ viewport: CanvasViewportState) {
        guard viewport.isValid else { return }
        viewportState = viewport
        noteGraphChanged()
    }

    // MARK: - W3 viewport durable binding seam（CanvasView 本地变换 ↔ 唯一事实源）

    /// 将 CanvasView 本地 viewport 变换（zoom + pan，屏幕坐标）投影为 CanvasViewportState
    /// （世界中心 + zoom + canvasSize）写入唯一事实源，并进入同一防抖保存路径。
    /// 这是 CanvasView 本地 viewport 变更的唯一写入口（W3 viewport durable binding）：
    /// 视图不另建事实源，所有 update 经本 seam 与 updateViewport revision gate。
    /// - Returns: 写入成功返回投影后的状态；非法输入（非有限值 / 未布局视口）返回 nil（fail-closed）。
    @discardableResult
    func commitViewport(zoom: Double, pan: CGPoint, viewportSize: CGSize, canvasSize: Size) -> CanvasViewportState? {
        guard viewportSize.width > 0, viewportSize.height > 0,
              zoom.isFinite, zoom > 0,
              pan.x.isFinite, pan.y.isFinite,
              canvasSize.width.isFinite, canvasSize.height.isFinite else { return nil }
        // 世界中心 = 屏幕中心反投影：world = (screen - pan) / zoom，screen = viewportSize / 2
        let center = Point(
            x: (viewportSize.width / 2 - pan.x) / zoom,
            y: (viewportSize.height / 2 - pan.y) / zoom
        )
        guard center.x.isFinite, center.y.isFinite else { return nil }
        let state = CanvasViewportState(center: center, zoom: zoom, canvasSize: canvasSize)
        guard state.isValid else { return nil }
        updateViewport(state)
        return state
    }

    /// 从唯一事实源恢复 CanvasView 本地 viewport 变换（zoom + pan）。
    /// 仅当 store 持有真实视口（canvasSize > 0，即曾通过 seam 写入或从草稿恢复）时返回非 nil；
    /// 全新画布（默认视口）返回 nil，CanvasView 保持视图默认视口（UI 行为不变）。
    func restoredViewport(viewportSize: CGSize) -> (zoom: Double, pan: CGPoint)? {
        guard viewportSize.width > 0, viewportSize.height > 0,
              viewportState.canvasSize.width > 0 || viewportState.canvasSize.height > 0 else { return nil }
        let zoom = viewportState.zoom
        guard zoom.isFinite, zoom > 0 else { return nil }
        let pan = CGPoint(
            x: viewportSize.width / 2 - viewportState.center.x * zoom,
            y: viewportSize.height / 2 - viewportState.center.y * zoom
        )
        guard pan.x.isFinite, pan.y.isFinite else { return nil }
        return (zoom, pan)
    }

    // MARK: - 多画布管理（M4：创建 / 切换 / 重命名 / 删除）

    private func invalidateCollectionRestore() {
        collectionRestoreGeneration &+= 1
        collectionRestoreTask?.cancel()
    }

    /// 离开当前画布时同时停止 DAG 调度和同一运行下的在途媒体任务。
    /// runID 必须在结束 scope 前捕获，取消桥接使用持久化任务记录中的同一身份。
    private func cancelCurrentExecutionBeforeCanvasTransition() {
        invalidateCollectionRestore()
        let runID = currentRunEnvelope?.runID
        executionScope.end()
        cancelFlag.cancel()
        if let runID, let videoInvoker = context.videoInvoker as? MinisCanvasVideoInvoker {
            Task { _ = await videoInvoker.cancelTasks(runID: runID) }
        }
    }

    /// 新建画布（追加到集合末尾并切换过去）。返回新画布文档。
    /// 当前画布先 flush 落盘，再切到空图新画布。
    @discardableResult
    func createCanvas(name: String? = nil) -> CanvasDocument {
        // 离开当前画布时结束旧画布的执行 scope 并置位取消标志（与 switchCanvas /
        // deleteCanvas 同一契约）：旧画布在途媒体任务写回将被拒绝，防止新建画布后
        // 旧运行结果继续落盘到旧画布文档。
        cancelCurrentExecutionBeforeCanvasTransition()
        flushCanvasDraft()
        syncCurrentStateToDocument()
        let id = UUID()
        let doc = CanvasDocument(
            id: id,
            name: name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
                : "画布 \(canvasDocuments.count + 1)",
            graph: NodeGraph(),
            draftKey: Self.canvasDraftKey(for: id)
        )
        canvasDocuments.append(doc)
        currentCanvasID = id
        graph = NodeGraph()
        resetInteractiveState()
        refreshRecoveryScope()
        saveCollection()
        statusMessage = "已新建画布「\(doc.name)」"
        return doc
    }

    /// 重命名画布。空串/纯空白安全忽略（保留原名）；返回是否实际改名。
    @discardableResult
    func renameCanvas(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = canvasDocuments.firstIndex(where: { $0.id == id }) else { return false }
        guard canvasDocuments[index].name != trimmed else { return false }
        invalidateCollectionRestore()
        canvasDocuments[index].name = trimmed
        saveCollection()
        statusMessage = "已重命名为「\(trimmed)」"
        return true
    }

    /// 删除画布（含其草稿）。至少保留一个画布（删除被拒时返回 false）。
    /// 删除当前画布 → 切到相邻剩余画布；删除非当前画布 → 当前保持不变。
    @discardableResult
    func deleteCanvas(id: UUID) -> Bool {
        guard canvasDocuments.count > 1,
              let index = canvasDocuments.firstIndex(where: { $0.id == id }) else { return false }
        let wasCurrent = (id == currentCanvasID)
        let removedName = canvasDocuments[index].name
        let removedKey = canvasDocuments[index].draftKey
        cancelCurrentExecutionBeforeCanvasTransition()
        if wasCurrent {
            flushCanvasDraft()
            syncCurrentStateToDocument()
        }
        let remainingDocuments = canvasDocuments.enumerated().compactMap { offset, document in
            offset == index ? nil : document
        }
        let remainingCurrentID: UUID
        if wasCurrent {
            remainingCurrentID = remainingDocuments[min(index, remainingDocuments.count - 1)].id
        } else {
            remainingCurrentID = currentCanvasID
        }
        let replacementCollection: CanvasCollectionSnapshot? = remainingDocuments.count > 1
            ? collectionSnapshot(for: remainingDocuments, currentID: remainingCurrentID)
            : nil
        let collectionAction = replacementCollection == nil ? "remove" : "replace"
        var cleanupJournalGeneration: CanvasFileGeneration?
        if let store = draftStore {
            let draftURL = store.draftsDirectory
                .appendingPathComponent("\(removedKey).json")
            let collectionURL = store.directory.appendingPathComponent(Self.collectionFileName)
            let receiptURL = Self.cleanupReceiptURL(at: store.directory)
            let previousTombstone: (
                digest: String,
                generation: UInt64,
                rootDigest: String,
                documentEpoch: UInt64,
                epochPreviousDigest: String?,
                epochPreviousRootDigest: String?
            )?
            if Self.pathExists(at: receiptURL) {
                guard let metadata = Self.cleanupTombstoneMetadata(
                    at: receiptURL,
                    sessionRootPath: store.directory.standardizedFileURL.path
                ) else {
                    return false
                }
                previousTombstone = metadata
            } else {
                previousTombstone = nil
            }
            guard previousTombstone == nil
                    || previousTombstone!.generation < UInt64(Self.cleanupTombstoneGenerationLimit) else {
                return false
            }
            let draftGeneration = Self.cleanupFileGeneration(at: draftURL)
            let collectionGeneration = Self.cleanupFileGeneration(at: collectionURL)
            guard !Self.pathExists(at: draftURL) || draftGeneration != nil,
                  !Self.pathExists(at: collectionURL) || collectionGeneration != nil else {
                return false
            }
            guard Self.isCanvasDraftKey(removedKey),
                  writeCleanupJournal(
                      CanvasCleanupJournal(
                          sessionRootPath: store.directory.standardizedFileURL.path,
                          removedDraftKey: removedKey,
                          collectionAction: collectionAction,
                          replacementCollection: replacementCollection,
                          removedDraftGeneration: draftGeneration,
                          collectionGeneration: collectionGeneration,
                          documentEpoch: previousTombstone?.documentEpoch ?? 1,
                          epochPreviousDigest: previousTombstone?.epochPreviousDigest,
                          epochPreviousRootDigest: previousTombstone?.epochPreviousRootDigest,
                          tombstonePredecessorDigest: previousTombstone?.digest,
                          tombstoneGeneration: (previousTombstone?.generation ?? 0) + 1,
                          tombstoneRootDigest: previousTombstone?.rootDigest
                      ),
                      to: store
                  ),
                  let journalGeneration = Self.cleanupFileGeneration(at: Self.cleanupJournalURL(at: store.directory))
            else {
                return false
            }
            cleanupJournalGeneration = journalGeneration
        }
        assetStore.detach(canvasID: id)
        canvasDocuments.remove(at: index)
        let newIndex: Int
        if wasCurrent {
            newIndex = min(index, canvasDocuments.count - 1)
        } else if let current = canvasDocuments.firstIndex(where: { $0.id == currentCanvasID }) {
            newIndex = current
        } else {
            newIndex = 0
        }
        currentCanvasID = canvasDocuments[newIndex].id
        graph = canvasDocuments[newIndex].graph
        loadInteractiveState(from: canvasDocuments[newIndex])
        refreshRecoveryScope()
        guard saveCollection(),
              draftStore?.clear(key: removedKey) ?? true else {
            return false
        }
        if let store = draftStore {
            let journalURL = Self.cleanupJournalURL(at: store.directory)
            guard let journalGeneration = cleanupJournalGeneration,
                  Self.durableRemoveOwnedFile(at: journalURL, expected: journalGeneration),
                  !Self.pathExists(at: journalURL) else { return false }
        }
        statusMessage = "已删除画布「\(removedName)」"
        return true
    }

    /// 切换到指定画布（保存当前 → 加载目标图）。返回是否切换成功。
    @discardableResult
    func switchCanvas(to id: UUID) -> Bool {
        guard id != currentCanvasID,
              canvasDocuments.contains(where: { $0.id == id }) else { return false }
        cancelCurrentExecutionBeforeCanvasTransition()
        flushCanvasDraft()
        syncCurrentStateToDocument()
        currentCanvasID = id
        let target = canvasDocuments.first { $0.id == id }
        graph = target?.graph ?? NodeGraph()
        if let target { loadInteractiveState(from: target) }
        refreshRecoveryScope()
        saveCollection()
        statusMessage = "已切换到「\(currentCanvas.name)」"
        return true
    }

    /// 把当前活动画布的所有可恢复状态写回文档（切换/保存/删除前调用）。
    private func syncCurrentStateToDocument() {
        guard let index = canvasDocuments.firstIndex(where: { $0.id == currentCanvasID }) else { return }
        canvasDocuments[index].graph = graph
        canvasDocuments[index].assetIDs = assetIDsByCanvas[currentCanvasID] ?? canvasDocuments[index].assetIDs
        canvasDocuments[index].viewport = viewportState
        canvasDocuments[index].selection = selectedNodeIDs
        canvasDocuments[index].selectionOrder = selectionOrder
        canvasDocuments[index].selectedGroupID = selectedGroupID
        canvasDocuments[index].previewNodeID = previewNodeID
        canvasDocuments[index].groups = CanvasDraft.encodeGroups(groups)
    }

    /// 从目标文档恢复其画布级状态；切换画布不会串用上一个画布的交互态。
    private func loadInteractiveState(from document: CanvasDocument) {
        viewportState = document.viewport
        selectedNodeIDs = document.selection.filter { document.graph.node(id: $0) != nil }
        selectionOrder = document.selectionOrder.filter { selectedNodeIDs.contains($0) }
        if selectionOrder.isEmpty { selectionOrder = Array(selectedNodeIDs) }
        selectedGroupID = document.selectedGroupID
        previewNodeID = document.previewNodeID
        groups = document.groups.map { group in
            var color = CanvasGroup.defaultColor
            if let rgba = group.colorRGBA, rgba.count >= 4 {
                color = Color(red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3])
            }
            return CanvasGroup(
                id: group.id,
                title: group.title,
                origin: Point(x: group.originX, y: group.originY),
                size: CGSize(width: group.width, height: group.height),
                nodeIDs: Set(group.nodeIDs),
                isCollapsed: group.isCollapsed,
                color: color
            )
        }
    }

    /// 切换/新建/删除后清理画布级交互中间态（撤销栈按画布隔离，切换即清空）。
    private func resetInteractiveState() {
        viewportState = CanvasViewportState()
        selectedNodeID = nil
        selectedNodeIDs.removeAll()
        groups.removeAll()
        renamingGroupID = nil
        pendingEdge = nil
        edgeTarget = nil
        modelPanelNodeID = nil
        contentEditorNodeID = nil
        renamingNodeID = nil
        editingContentNodeID = nil
        previewNodeID = nil
        nodeSearchPosition = Point(x: 400, y: 300)
        isNodeSearchPresented = false
        undoStack.removeAll()
    }

    /// 持久化画布集合元数据（id/名称/草稿 key/顺序）到 DraftStore 根目录。
    @discardableResult
    private func saveCollection() -> Bool {
        guard let store = draftStore else { return true }
        let url = store.directory.appendingPathComponent(Self.collectionFileName)
        // A single canvas uses the legacy draft key and F7 recovery path.
        // Do not create a collection marker for it: that marker means
        // "multi-canvas persistence" and intentionally bypasses auto-restore.
        guard canvasDocuments.count > 1 else {
            if Self.pathExists(at: url) {
                guard let expectedGeneration = Self.cleanupFileGeneration(at: url),
                      Self.durableRemoveOwnedFile(at: url, expected: expectedGeneration),
                      !Self.pathExists(at: url) else { return false }
            }
            return true
        }
        syncCurrentStateToDocument()
        let snapshot = collectionSnapshot(for: canvasDocuments, currentID: currentCanvasID)
        guard let data = try? Self.cleanupEncodedData(snapshot),
              data.count <= Self.cleanupCollectionBytesLimit else { return false }
        do {
            try FileManager.default.createDirectory(
                at: store.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let expectedGeneration: CanvasFileGeneration?
            if Self.pathExists(at: url) {
                guard Self.isOwnedRegularFile(at: url),
                      let generation = Self.cleanupFileGeneration(at: url) else { return false }
                expectedGeneration = generation
            } else {
                expectedGeneration = nil
            }
            return Self.durableAtomicPublish(
                data,
                to: url,
                byteLimit: Self.cleanupCollectionBytesLimit,
                expectedExisting: expectedGeneration,
                requireAbsent: expectedGeneration == nil
            )
        } catch {
            return false
        }
    }

    nonisolated private static func isOwnedRegularFile(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_nlink == 1
    }

    nonisolated static let cleanupFileDigestReadLimit = 8 * 1024 * 1024
    nonisolated static let cleanupJournalBytesLimit = 8 * 1024 * 1024
    nonisolated static let cleanupReceiptBytesLimit = 64 * 1024
    nonisolated static let cleanupCollectionEntryLimit = 1_024
    nonisolated static let cleanupCollectionBytesLimit = 1 * 1024 * 1024
    nonisolated static let cleanupPayloadBytesLimit = 1 * 1024 * 1024
    nonisolated static let cleanupJournalAggregateBytesLimit = 9 * 1024 * 1024
    nonisolated static let cleanupCheckpointPayloadBytesLimit = 8 * 1024 * 1024
    nonisolated static let cleanupCheckpointAggregateBytesLimit = 9 * 1024 * 1024
    nonisolated static let cleanupMarkerHistoryBytesLimit = cleanupCheckpointAggregateBytesLimit
    nonisolated static let cleanupTombstoneGenerationLimit = 1_024
    nonisolated static let cleanupJSONMaxDepth = 32
    nonisolated static let cleanupJSONObjectFieldLimit = 32
    nonisolated static let cleanupJSONArrayElementLimit = 1_024

    nonisolated static func cleanupFileGeneration(at url: URL) -> CanvasFileGeneration? {
        var pathInfo = stat()
        guard lstat(url.path, &pathInfo) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFREG,
              pathInfo.st_size >= 0,
              UInt64(pathInfo.st_size) <= UInt64(cleanupFileDigestReadLimit),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        var openedInfo = stat()
        guard fstat(handle.fileDescriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_dev == pathInfo.st_dev,
              openedInfo.st_ino == pathInfo.st_ino else {
            return nil
        }
        var hasher = SHA256()
        var byteCount = 0
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 64 * 1024),
                      !chunk.isEmpty else {
                    break
                }
                byteCount += chunk.count
                guard byteCount <= cleanupFileDigestReadLimit else { return nil }
                hasher.update(data: chunk)
            } catch {
                return nil
            }
        }
        var finalInfo = stat()
        guard fstat(handle.fileDescriptor, &finalInfo) == 0,
              finalInfo.st_dev == openedInfo.st_dev,
              finalInfo.st_ino == openedInfo.st_ino,
              finalInfo.st_size == openedInfo.st_size,
              UInt64(byteCount) == UInt64(finalInfo.st_size) else {
            return nil
        }
        var finalPathInfo = stat()
        guard lstat(url.path, &finalPathInfo) == 0,
              (finalPathInfo.st_mode & S_IFMT) == S_IFREG,
              finalPathInfo.st_dev == pathInfo.st_dev,
              finalPathInfo.st_ino == pathInfo.st_ino,
              finalPathInfo.st_size == finalInfo.st_size else {
            return nil
        }
        return CanvasFileGeneration(
            device: UInt64(finalInfo.st_dev),
            inode: UInt64(finalInfo.st_ino),
            digest: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    nonisolated static func cleanupReplacementCollectionData(
        _ replacement: CanvasCollectionSnapshot,
        excluding removedDraftKey: String
    ) -> Data? {
        guard replacement.documents.count > 1,
              replacement.documents.count <= cleanupCollectionEntryLimit,
              replacement.schemaVersion == CanvasCollectionSnapshot.currentSchemaVersion,
              Self.collectionValidationDiagnostic(for: replacement.documents) == nil,
              let currentRawID = replacement.currentCanvasID,
              let currentID = UUID(uuidString: currentRawID),
              currentRawID == currentID.uuidString,
              replacement.documents.contains(where: { $0.id == currentID }),
              replacement.documents.enumerated().allSatisfy({ index, document in
                  document.draftKey != removedDraftKey
                      && (document.draftKey == Self.canvasDraftKey(for: document.id)
                          || (index == 0 && document.draftKey == DraftStore.canvasKey))
              }),
              let data = try? Self.cleanupEncodedData(replacement),
              data.count <= cleanupCollectionBytesLimit else {
            return nil
        }
        return data
    }

    nonisolated static func cleanupJSONStructureIsStrict(_ data: Data) -> Bool {
        var scanner = CanvasCleanupJSONScanner(
            bytes: Array(data),
            maxDepth: cleanupJSONMaxDepth,
            maxObjectFields: cleanupJSONObjectFieldLimit,
            maxArrayElements: cleanupJSONArrayElementLimit
        )
        return scanner.validate()
    }

    nonisolated static func cleanupEncodedData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    nonisolated static func cleanupJSONIsCanonical<T: Codable>(_ value: T, data: Data) -> Bool {
        guard let canonical = try? cleanupEncodedData(value) else { return false }
        return canonical == data
    }

    nonisolated static func cleanupJournalDigest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func cleanupPayloadData(
        for journal: CanvasCleanupJournal
    ) -> Data? {
        let data: Data
        switch journal.collectionAction {
        case "remove":
            guard journal.replacementCollection == nil else { return nil }
            data = Data()
        case "replace":
            guard let replacement = journal.replacementCollection,
                  replacement.documents.count > 1,
                  replacement.documents.count <= cleanupCollectionEntryLimit,
                  replacement.schemaVersion == CanvasCollectionSnapshot.currentSchemaVersion,
                  let encoded = try? Self.cleanupEncodedData(replacement) else {
                return nil
            }
            data = encoded
        default:
            return nil
        }
        guard data.count <= cleanupPayloadBytesLimit else { return nil }
        return data
    }

    nonisolated static func cleanupPayloadDigest(
        for journal: CanvasCleanupJournal
    ) -> String? {
        cleanupPayloadData(for: journal).map(cleanupJournalDigest)
    }

    private static func cleanupJournalDataIsBounded(
        _ journal: CanvasCleanupJournal,
        data: Data
    ) -> Bool {
        guard data.count <= cleanupJournalBytesLimit,
              let payload = cleanupPayloadData(for: journal),
              data.count + payload.count <= cleanupJournalAggregateBytesLimit else {
            return false
        }
        return true
    }

    nonisolated static func cleanupMarkerHistoryIsBounded(
        journalData: Data,
        receiptData: Data,
        candidateData: Data? = nil
    ) -> Bool {
        journalData.count <= cleanupJournalBytesLimit
            && (candidateData?.count ?? 0) <= cleanupJournalBytesLimit
            && receiptData.count <= cleanupReceiptBytesLimit
            && journalData.count + (candidateData?.count ?? 0) + receiptData.count
                <= cleanupMarkerHistoryBytesLimit
    }

    private static func cleanupTombstoneMetadata(
        at url: URL,
        sessionRootPath: String
    ) -> (
        digest: String,
        generation: UInt64,
        rootDigest: String,
        documentEpoch: UInt64,
        epochPreviousDigest: String?,
        epochPreviousRootDigest: String?
    )? {
        guard pathExists(at: url),
              isOwnedRegularFile(at: url),
              let initialGeneration = cleanupFileGeneration(at: url),
              let data = try? Data(contentsOf: url),
              data.count <= cleanupReceiptBytesLimit,
              cleanupJSONStructureIsStrict(data),
              let receipt = try? JSONDecoder().decode(CanvasCleanupReceipt.self, from: data),
              cleanupJSONIsCanonical(receipt, data: data),
              receipt.schemaVersion == CanvasCleanupReceipt.currentSchemaVersion,
              receipt.sessionRootPath == sessionRootPath,
              isCanvasDraftKey(receipt.removedDraftKey),
              receipt.documentScope == receipt.removedDraftKey,
              receipt.documentEpoch > 0,
              receipt.documentEpoch == 1
                  ? receipt.epochPreviousDigest == nil
                  : (receipt.epochPreviousDigest.map(cleanupDigestIsCanonical) ?? false),
              receipt.documentEpoch == 1
                  ? receipt.epochPreviousRootDigest == nil
                  : (receipt.epochPreviousRootDigest == nil
                      || receipt.epochPreviousRootDigest.map(cleanupDigestIsCanonical) == true),
              receipt.tombstoneGeneration > 0,
              receipt.tombstoneGeneration <= UInt64(cleanupTombstoneGenerationLimit),
              receipt.transactionGeneration > 0,
              cleanupDigestIsCanonical(receipt.tombstoneRootDigest),
              receipt.tombstoneRootDigest == canvasCleanupTombstoneRootDigest(
                  sessionRootPath: receipt.sessionRootPath,
                  documentScope: receipt.documentScope,
                  documentEpoch: receipt.documentEpoch,
                  epochPreviousDigest: receipt.epochPreviousDigest,
                  epochPreviousRootDigest: receipt.epochPreviousRootDigest
              ),
              cleanupDigestIsCanonical(receipt.checkpointRootDigest),
              receipt.checkpointRootDigest == canvasCleanupCheckpointRootDigest(
                  tombstoneRootDigest: receipt.tombstoneRootDigest,
                  checkpointDigest: receipt.checkpointDigest
              ),
              receipt.epochSuccessorDigest == canvasCleanupEpochSuccessorDigest(
                  previousRootDigest: receipt.epochPreviousRootDigest,
                  currentRootDigest: receipt.tombstoneRootDigest,
                  checkpointRootDigest: receipt.checkpointRootDigest
              ),
              cleanupDigestIsCanonical(receipt.journalDigest),
              receipt.tombstonePredecessorDigest == nil
                  || receipt.tombstonePredecessorDigest.map(cleanupDigestIsCanonical) == true,
              UUID(uuidString: receipt.receiptID)?.uuidString == receipt.receiptID else {
            return nil
        }
        guard let generation = cleanupFileGeneration(at: url),
              generation == initialGeneration,
              generation.digest == cleanupJournalDigest(data) else {
            return nil
        }
        return (
            generation.digest,
            receipt.tombstoneGeneration,
            receipt.tombstoneRootDigest,
            receipt.documentEpoch,
            receipt.epochPreviousDigest,
            receipt.epochPreviousRootDigest
        )
    }

    nonisolated static func cleanupDigestIsCanonical(_ digest: String) -> Bool {
        digest.utf8.count == 64
            && digest.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
            }
    }

    nonisolated private static func durableAtomicPublish(
        _ data: Data,
        to url: URL,
        byteLimit: Int,
        expectedExisting: CanvasFileGeneration? = nil,
        requireAbsent: Bool = false
    ) -> Bool {
        guard data.count <= byteLimit else { return false }
        let directoryURL = url.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let directoryFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        defer { _ = close(directoryFD) }

        let fileFD = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fileFD >= 0 else { return false }
        var writeSucceeded = true
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                writeSucceeded = data.isEmpty
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fileFD,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard written > 0 else {
                    writeSucceeded = false
                    break
                }
                offset += written
            }
        }
        let fileSyncSucceeded = writeSucceeded && fsync(fileFD) == 0
        let fileCloseSucceeded = close(fileFD) == 0
        guard fileSyncSucceeded && fileCloseSucceeded else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return false
        }
        if requireAbsent {
            guard !pathExists(at: url) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return false
            }
        } else if let expectedExisting {
            guard cleanupFileGeneration(at: url) == expectedExisting else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return false
            }
        }
        guard rename(temporaryURL.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return false
        }
        guard fsync(directoryFD) == 0 else { return false }
        return true
    }

    nonisolated private static func durableRemoveOwnedFile(
        at url: URL,
        expected expectedGeneration: CanvasFileGeneration? = nil
    ) -> Bool {
        guard isOwnedRegularFile(at: url),
              expectedGeneration == nil || cleanupFileGeneration(at: url) == expectedGeneration else {
            return false
        }
        let directoryURL = url.deletingLastPathComponent()
        let directoryFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        defer { _ = close(directoryFD) }
        guard expectedGeneration == nil || cleanupFileGeneration(at: url) == expectedGeneration else {
            return false
        }
        do { try FileManager.default.removeItem(at: url) }
        catch { return false }
        return fsync(directoryFD) == 0
    }

    nonisolated private static func pathExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isCanvasDraftKey(_ key: String) -> Bool {
        if key == DraftStore.canvasKey { return true }
        let prefix = "canvas."
        guard key.hasPrefix(prefix),
              let id = UUID(uuidString: String(key.dropFirst(prefix.count))),
              id.uuidString == String(key.dropFirst(prefix.count)) else {
            return false
        }
        return true
    }

    /// Finish a deletion left behind by a crashed process. Invalid journals
    /// remain untouched: recovery never guesses at ownership or a session root.
    private func recoverCleanupJournalIfPresent(_ store: DraftStore) {
        let journalURL = Self.cleanupJournalURL(at: store.directory)
        var journalInfo = stat()
        guard Self.pathExists(at: journalURL),
              Self.isOwnedRegularFile(at: journalURL),
              lstat(journalURL.path, &journalInfo) == 0,
              journalInfo.st_size >= 0,
              UInt64(journalInfo.st_size) <= UInt64(Self.cleanupCheckpointPayloadBytesLimit),
              let initialJournalGeneration = Self.cleanupFileGeneration(at: journalURL),
              let data = try? Data(contentsOf: journalURL),
              let journalGeneration = Self.cleanupFileGeneration(at: journalURL),
              journalGeneration == initialJournalGeneration,
              journalGeneration.digest == Self.cleanupJournalDigest(data),
              Self.cleanupJSONStructureIsStrict(data),
              let journal = try? JSONDecoder().decode(CanvasCleanupJournal.self, from: data),
              Self.cleanupJSONIsCanonical(journal, data: data),
              Self.cleanupJournalDataIsBounded(journal, data: data),
              Self.cleanupPayloadDigest(for: journal) == journal.payloadDigest,
              journal.schemaVersion == CanvasCleanupJournal.currentSchemaVersion,
              journal.sessionRootPath == store.directory.standardizedFileURL.path,
              Self.isCanvasDraftKey(journal.removedDraftKey),
              journal.documentScope == journal.removedDraftKey,
              journal.documentEpoch > 0,
              journal.documentEpoch == 1
                  ? journal.epochPreviousDigest == nil
                  : (journal.epochPreviousDigest.map(Self.cleanupDigestIsCanonical) ?? false),
              journal.documentEpoch == 1
                  ? journal.epochPreviousRootDigest == nil
                  : (journal.epochPreviousRootDigest == nil
                      || journal.epochPreviousRootDigest.map(Self.cleanupDigestIsCanonical) == true),
              journal.tombstoneGeneration > 0,
              journal.tombstoneGeneration <= UInt64(Self.cleanupTombstoneGenerationLimit),
              journal.tombstonePredecessorDigest == nil
                  || journal.tombstonePredecessorDigest.map(Self.cleanupDigestIsCanonical) == true,
              Self.cleanupDigestIsCanonical(journal.tombstoneRootDigest),
              journal.tombstoneRootDigest == canvasCleanupTombstoneRootDigest(
                  sessionRootPath: journal.sessionRootPath,
                  documentScope: journal.documentScope,
                  documentEpoch: journal.documentEpoch,
                  epochPreviousDigest: journal.epochPreviousDigest,
                  epochPreviousRootDigest: journal.epochPreviousRootDigest
              ),
              Self.cleanupDigestIsCanonical(journal.checkpointRootDigest),
              journal.checkpointRootDigest == canvasCleanupCheckpointRootDigest(
                  tombstoneRootDigest: journal.tombstoneRootDigest,
                  checkpointDigest: journal.checkpointDigest
              ),
              journal.epochSuccessorDigest == canvasCleanupEpochSuccessorDigest(
                  previousRootDigest: journal.epochPreviousRootDigest,
                  currentRootDigest: journal.tombstoneRootDigest,
                  checkpointRootDigest: journal.checkpointRootDigest
              ),
              let receiptID = journal.receiptID,
              UUID(uuidString: receiptID)?.uuidString == receiptID,
              journal.state != nil,
              journal.state == .prepared || journal.transactionGeneration > 1,
              journal.transactionGeneration > 0,
              journal.transactionGeneration == 1
                  ? journal.previousDigest == nil
                      && journal.checkpointDigest == nil
                      && journal.checkpointGeneration == nil
                  : (journal.previousDigest.map(Self.cleanupDigestIsCanonical) ?? false)
                      && journal.checkpointDigest == journal.previousDigest
                      && journal.checkpointGeneration == journal.transactionGeneration - 1 else {
            return
        }

        var activeJournal = journal
        var activeData = data
        let candidateURL = Self.cleanupJournalCandidateURL(at: store.directory)
        let receiptURL = Self.cleanupReceiptURL(at: store.directory)
        let existingReceiptData: Data
        let existingReceiptGeneration: CanvasFileGeneration?
        if Self.pathExists(at: receiptURL) {
            var existingReceiptInfo = stat()
            guard Self.isOwnedRegularFile(at: receiptURL),
                  lstat(receiptURL.path, &existingReceiptInfo) == 0,
                  existingReceiptInfo.st_size >= 0,
                  UInt64(existingReceiptInfo.st_size) <= UInt64(Self.cleanupReceiptBytesLimit) else {
                return
            }
            guard let initialReceiptGeneration = Self.cleanupFileGeneration(at: receiptURL),
                  let persistedReceiptData = try? Data(contentsOf: receiptURL),
                  let persistedReceiptGeneration = Self.cleanupFileGeneration(at: receiptURL),
                  persistedReceiptGeneration == initialReceiptGeneration,
                  persistedReceiptGeneration.digest == Self.cleanupJournalDigest(persistedReceiptData) else {
                return
            }
            existingReceiptData = persistedReceiptData
            existingReceiptGeneration = persistedReceiptGeneration
        } else {
            existingReceiptData = Data()
            existingReceiptGeneration = nil
        }
        if Self.pathExists(at: candidateURL) {
            var candidateInfo = stat()
            guard Self.isOwnedRegularFile(at: candidateURL),
                  lstat(candidateURL.path, &candidateInfo) == 0,
                  candidateInfo.st_size >= 0,
                  UInt64(candidateInfo.st_size) <= UInt64(Self.cleanupCheckpointPayloadBytesLimit),
                  let candidateData = try? Data(contentsOf: candidateURL),
                  Self.cleanupJSONStructureIsStrict(candidateData),
                  let candidate = try? JSONDecoder().decode(CanvasCleanupJournal.self, from: candidateData),
                  Self.cleanupJSONIsCanonical(candidate, data: candidateData),
                  Self.cleanupJournalDataIsBounded(candidate, data: candidateData),
                  Self.cleanupPayloadDigest(for: candidate) == candidate.payloadDigest,
                  candidate.schemaVersion == CanvasCleanupJournal.currentSchemaVersion,
                  candidate.sessionRootPath == store.directory.standardizedFileURL.path,
                  Self.isCanvasDraftKey(candidate.removedDraftKey),
                  candidate.documentScope == candidate.removedDraftKey,
                  candidate.documentEpoch > 0,
                  candidate.documentEpoch == 1
                      ? candidate.epochPreviousDigest == nil
                      : (candidate.epochPreviousDigest.map(Self.cleanupDigestIsCanonical) ?? false),
                  candidate.documentEpoch == 1
                      ? candidate.epochPreviousRootDigest == nil
                      : (candidate.epochPreviousRootDigest == nil
                          || candidate.epochPreviousRootDigest.map(Self.cleanupDigestIsCanonical) == true),
                  candidate.tombstoneGeneration > 0,
                  candidate.tombstoneGeneration <= UInt64(Self.cleanupTombstoneGenerationLimit),
                  candidate.tombstonePredecessorDigest == nil
                      || candidate.tombstonePredecessorDigest.map(Self.cleanupDigestIsCanonical) == true,
                  Self.cleanupDigestIsCanonical(candidate.tombstoneRootDigest),
                  candidate.tombstoneRootDigest == canvasCleanupTombstoneRootDigest(
                      sessionRootPath: candidate.sessionRootPath,
                      documentScope: candidate.documentScope,
                      documentEpoch: candidate.documentEpoch,
                      epochPreviousDigest: candidate.epochPreviousDigest,
                      epochPreviousRootDigest: candidate.epochPreviousRootDigest
                  ),
                  Self.cleanupDigestIsCanonical(candidate.checkpointRootDigest),
                  candidate.checkpointRootDigest == canvasCleanupCheckpointRootDigest(
                      tombstoneRootDigest: candidate.tombstoneRootDigest,
                      checkpointDigest: candidate.checkpointDigest
                  ),
                  candidate.epochSuccessorDigest == canvasCleanupEpochSuccessorDigest(
                      previousRootDigest: candidate.epochPreviousRootDigest,
                      currentRootDigest: candidate.tombstoneRootDigest,
                      checkpointRootDigest: candidate.checkpointRootDigest
                  ),
                  let candidateReceiptID = candidate.receiptID,
                  UUID(uuidString: candidateReceiptID)?.uuidString == candidateReceiptID,
                  let candidateState = candidate.state,
                  candidateState == .prepared || candidate.transactionGeneration > 1,
                  candidate.transactionGeneration > 0,
                  candidate.transactionGeneration == 1
                      ? candidate.previousDigest == nil
                          && candidate.checkpointDigest == nil
                          && candidate.checkpointGeneration == nil
                      : (candidate.previousDigest.map(Self.cleanupDigestIsCanonical) ?? false)
                          && candidate.checkpointDigest == candidate.previousDigest
                          && candidate.checkpointGeneration == candidate.transactionGeneration - 1,
                  candidate.sessionRootPath == activeJournal.sessionRootPath,
                  candidate.removedDraftKey == activeJournal.removedDraftKey,
                  candidate.collectionAction == activeJournal.collectionAction,
                  candidate.replacementCollection == activeJournal.replacementCollection,
                  candidate.removedDraftGeneration == activeJournal.removedDraftGeneration,
                  candidate.collectionGeneration == activeJournal.collectionGeneration,
                  candidate.receiptID == activeJournal.receiptID,
                  candidate.transactionID == activeJournal.transactionID,
                  candidate.documentScope == activeJournal.documentScope,
                  candidate.documentEpoch == activeJournal.documentEpoch,
                  candidate.epochPreviousDigest == activeJournal.epochPreviousDigest,
                  candidate.epochPreviousRootDigest == activeJournal.epochPreviousRootDigest,
                  candidate.epochSuccessorDigest == activeJournal.epochSuccessorDigest,
                  candidate.tombstoneGeneration == activeJournal.tombstoneGeneration,
                  candidate.tombstonePredecessorDigest == activeJournal.tombstonePredecessorDigest,
                  candidate.tombstoneRootDigest == activeJournal.tombstoneRootDigest,
                  let candidateGeneration = Self.cleanupFileGeneration(at: candidateURL),
                  candidateGeneration.digest == Self.cleanupJournalDigest(candidateData),
                  Self.cleanupMarkerHistoryIsBounded(
                      journalData: activeData,
                      receiptData: existingReceiptData,
                      candidateData: candidateData
                  ),
                  activeData.count + candidateData.count <= Self.cleanupCheckpointAggregateBytesLimit,
                  Self.cleanupFileGeneration(at: receiptURL) == existingReceiptGeneration,
                  Self.cleanupFileGeneration(at: journalURL)?.digest == Self.cleanupJournalDigest(activeData) else {
                return
            }
            let exactCommittedDuplicate = candidateData == activeData
                && candidateState == .committed
                && activeJournal.state == .committed
            let validCommittedSuccessor = candidateState == .committed
                && activeJournal.state == .prepared
                && activeJournal.transactionGeneration < UInt64.max
                && candidate.transactionGeneration == activeJournal.transactionGeneration + 1
                && candidate.checkpointGeneration == activeJournal.transactionGeneration
                && candidate.previousDigest == Self.cleanupJournalDigest(activeData)
            guard exactCommittedDuplicate || validCommittedSuccessor,
                  Self.cleanupFileGeneration(at: candidateURL) == candidateGeneration else {
                return
            }
            let candidateHook = cleanupAfterCandidateReadHook
            cleanupAfterCandidateReadHook = nil
            candidateHook?()
            guard Self.cleanupFileGeneration(at: candidateURL) == candidateGeneration,
                  Self.cleanupFileGeneration(at: receiptURL) == existingReceiptGeneration else {
                return
            }
            if validCommittedSuccessor {
                guard Self.cleanupFileGeneration(at: journalURL)?.digest == Self.cleanupJournalDigest(activeData),
                      Self.durableAtomicPublish(
                          candidateData,
                          to: journalURL,
                          byteLimit: Self.cleanupJournalBytesLimit,
                          expectedExisting: Self.cleanupFileGeneration(at: journalURL)
                      ),
                      let promotedData = try? Data(contentsOf: journalURL),
                      promotedData == candidateData,
                      let promotedGeneration = Self.cleanupFileGeneration(at: journalURL),
                      promotedGeneration.digest == Self.cleanupJournalDigest(candidateData) else {
                    return
                }
                activeJournal = candidate
                activeData = candidateData
                let promotionHook = cleanupAfterCheckpointPromotionHook
                cleanupAfterCheckpointPromotionHook = nil
                promotionHook?()
                guard Self.cleanupFileGeneration(at: journalURL) == promotedGeneration else {
                    return
                }
            }
            guard Self.durableRemoveOwnedFile(at: candidateURL, expected: candidateGeneration),
                  !Self.pathExists(at: candidateURL) else { return }
        }
        guard let activeState = activeJournal.state else { return }

        if Self.pathExists(at: receiptURL) {
            var receiptInfo = stat()
            guard Self.isOwnedRegularFile(at: receiptURL),
                  lstat(receiptURL.path, &receiptInfo) == 0,
                  receiptInfo.st_size >= 0,
                  UInt64(receiptInfo.st_size) <= UInt64(Self.cleanupReceiptBytesLimit),
                  let initialReceiptGeneration = Self.cleanupFileGeneration(at: receiptURL),
                  let receiptData = try? Data(contentsOf: receiptURL),
                  let receiptGeneration = Self.cleanupFileGeneration(at: receiptURL),
                  receiptGeneration == initialReceiptGeneration,
                  receiptGeneration.digest == Self.cleanupJournalDigest(receiptData),
                  Self.cleanupMarkerHistoryIsBounded(
                      journalData: activeData,
                      receiptData: receiptData
                  ),
                  Self.cleanupJSONStructureIsStrict(receiptData),
                  let receipt = try? JSONDecoder().decode(CanvasCleanupReceipt.self, from: receiptData),
                  Self.cleanupJSONIsCanonical(receipt, data: receiptData),
                  receipt.schemaVersion == CanvasCleanupReceipt.currentSchemaVersion,
                  receipt.sessionRootPath == store.directory.standardizedFileURL.path,
                  Self.isCanvasDraftKey(receipt.removedDraftKey),
                  receipt.documentScope == receipt.removedDraftKey,
                  receipt.documentEpoch > 0,
                  receipt.documentEpoch == 1
                      ? receipt.epochPreviousDigest == nil
                      : (receipt.epochPreviousDigest.map(Self.cleanupDigestIsCanonical) ?? false),
                  receipt.documentEpoch == 1
                      ? receipt.epochPreviousRootDigest == nil
                      : (receipt.epochPreviousRootDigest == nil
                          || receipt.epochPreviousRootDigest.map(Self.cleanupDigestIsCanonical) == true),
                  receipt.tombstoneGeneration > 0,
                  receipt.tombstoneGeneration <= UInt64(Self.cleanupTombstoneGenerationLimit),
                  receipt.tombstonePredecessorDigest == nil
                      || receipt.tombstonePredecessorDigest.map(Self.cleanupDigestIsCanonical) == true,
                  Self.cleanupDigestIsCanonical(receipt.tombstoneRootDigest),
                  receipt.tombstoneRootDigest == canvasCleanupTombstoneRootDigest(
                      sessionRootPath: receipt.sessionRootPath,
                      documentScope: receipt.documentScope,
                      documentEpoch: receipt.documentEpoch,
                      epochPreviousDigest: receipt.epochPreviousDigest,
                      epochPreviousRootDigest: receipt.epochPreviousRootDigest
                  ),
                  Self.cleanupDigestIsCanonical(receipt.checkpointRootDigest),
                  receipt.checkpointRootDigest == canvasCleanupCheckpointRootDigest(
                      tombstoneRootDigest: receipt.tombstoneRootDigest,
                      checkpointDigest: receipt.checkpointDigest
                  ),
                  receipt.epochSuccessorDigest == canvasCleanupEpochSuccessorDigest(
                      previousRootDigest: receipt.epochPreviousRootDigest,
                      currentRootDigest: receipt.tombstoneRootDigest,
                      checkpointRootDigest: receipt.checkpointRootDigest
                  ),
                  receipt.transactionGeneration > 0,
                  Self.cleanupDigestIsCanonical(receipt.journalDigest),
                  UUID(uuidString: receipt.receiptID)?.uuidString == receipt.receiptID else {
                return
            }
            // A transaction UUID is one-shot. Any receipt carrying this
            // transaction must be the exact receipt for this journal; a
            // different receipt is a fork/replay and is left untouched.
            if receipt.transactionID == activeJournal.transactionID {
                guard receipt.receiptID == receiptID,
                      receipt.removedDraftKey == activeJournal.removedDraftKey,
                      receipt.documentScope == activeJournal.documentScope,
                      receipt.documentEpoch == activeJournal.documentEpoch,
                      receipt.epochPreviousDigest == activeJournal.epochPreviousDigest,
                      receipt.epochPreviousRootDigest == activeJournal.epochPreviousRootDigest,
                      receipt.epochSuccessorDigest == activeJournal.epochSuccessorDigest,
                      receipt.tombstoneGeneration == activeJournal.tombstoneGeneration,
                      receipt.tombstonePredecessorDigest == activeJournal.tombstonePredecessorDigest,
                      receipt.tombstoneRootDigest == activeJournal.tombstoneRootDigest,
                      receipt.checkpointRootDigest == activeJournal.checkpointRootDigest,
                      receipt.transactionGeneration == activeJournal.transactionGeneration,
                      receipt.removedDraftGeneration == activeJournal.removedDraftGeneration,
                      receipt.collectionGeneration == activeJournal.collectionGeneration,
                      receipt.checkpointDigest == activeJournal.checkpointDigest,
                      receipt.journalDigest == Self.cleanupJournalDigest(activeData) else {
                    return
                }
                return
            }
            if receipt.receiptID == receiptID {
                guard receipt.transactionID == activeJournal.transactionID,
                      receipt.removedDraftKey == activeJournal.removedDraftKey,
                      receipt.documentScope == activeJournal.documentScope,
                      receipt.documentEpoch == activeJournal.documentEpoch,
                      receipt.epochPreviousDigest == activeJournal.epochPreviousDigest,
                      receipt.epochPreviousRootDigest == activeJournal.epochPreviousRootDigest,
                      receipt.epochSuccessorDigest == activeJournal.epochSuccessorDigest,
                      receipt.tombstoneGeneration == activeJournal.tombstoneGeneration,
                      receipt.tombstonePredecessorDigest == activeJournal.tombstonePredecessorDigest,
                      receipt.tombstoneRootDigest == activeJournal.tombstoneRootDigest,
                      receipt.checkpointRootDigest == activeJournal.checkpointRootDigest,
                      receipt.transactionGeneration == activeJournal.transactionGeneration,
                      receipt.removedDraftGeneration == activeJournal.removedDraftGeneration,
                      receipt.collectionGeneration == activeJournal.collectionGeneration,
                      receipt.checkpointDigest == activeJournal.checkpointDigest,
                      receipt.journalDigest == Self.cleanupJournalDigest(activeData) else {
                    return
                }
                return
            }
            guard activeJournal.tombstoneGeneration == receipt.tombstoneGeneration + 1,
                  activeJournal.tombstoneRootDigest == receipt.tombstoneRootDigest,
                  activeJournal.tombstonePredecessorDigest
                      == Self.cleanupJournalDigest(receiptData) else {
                // A receipt that is neither the current transaction nor the
                // exact predecessor is a replay/forked tombstone.
                return
            }
        } else {
            guard activeJournal.tombstoneGeneration == 1,
                  activeJournal.tombstonePredecessorDigest == nil else {
                return
            }
        }

        let collectionURL = store.directory.appendingPathComponent(Self.collectionFileName)
        let draftURL = store.draftsDirectory
            .appendingPathComponent("\(activeJournal.removedDraftKey).json")
        let currentDraftGeneration = Self.cleanupFileGeneration(at: draftURL)
        guard !Self.pathExists(at: draftURL)
                || (currentDraftGeneration != nil
                    && currentDraftGeneration == activeJournal.removedDraftGeneration) else {
            return
        }
        guard let observedJournalGeneration = Self.cleanupFileGeneration(at: journalURL) else {
            return
        }
        guard observedJournalGeneration.digest == Self.cleanupJournalDigest(activeData),
              Self.cleanupFileGeneration(at: journalURL) == observedJournalGeneration else {
            return
        }

        let committedJournal: CanvasCleanupJournal
        switch activeState {
        case .committed:
            committedJournal = activeJournal
        case .prepared:
            guard activeJournal.transactionGeneration < UInt64.max else {
                return
            }
            let committed = CanvasCleanupJournal(
                sessionRootPath: activeJournal.sessionRootPath,
                removedDraftKey: activeJournal.removedDraftKey,
                collectionAction: activeJournal.collectionAction,
                replacementCollection: activeJournal.replacementCollection,
                removedDraftGeneration: activeJournal.removedDraftGeneration,
                collectionGeneration: activeJournal.collectionGeneration,
                receiptID: receiptID,
                transactionID: activeJournal.transactionID,
                documentScope: activeJournal.documentScope,
                documentEpoch: activeJournal.documentEpoch,
                epochPreviousDigest: activeJournal.epochPreviousDigest,
                epochPreviousRootDigest: activeJournal.epochPreviousRootDigest,
                tombstonePredecessorDigest: activeJournal.tombstonePredecessorDigest,
                tombstoneGeneration: activeJournal.tombstoneGeneration,
                tombstoneRootDigest: activeJournal.tombstoneRootDigest,
                checkpointRootDigest: canvasCleanupCheckpointRootDigest(
                    tombstoneRootDigest: activeJournal.tombstoneRootDigest,
                    checkpointDigest: Self.cleanupJournalDigest(activeData)
                ),
                state: .committed,
                transactionGeneration: activeJournal.transactionGeneration + 1,
                previousDigest: Self.cleanupJournalDigest(activeData)
            )
            guard writeCleanupJournalState(committed, expected: activeJournal, to: store) else {
                return
            }
            guard let committedData = try? Data(contentsOf: journalURL),
                  let committedReadback = try? JSONDecoder().decode(
                      CanvasCleanupJournal.self,
                      from: committedData
                  ),
                  committedReadback == committed,
                  Self.cleanupJSONIsCanonical(committedReadback, data: committedData),
                  Self.cleanupFileGeneration(at: journalURL)?.digest
                      == Self.cleanupJournalDigest(committedData) else {
                return
            }
            activeData = committedData
            committedJournal = committed
        }

        switch activeJournal.collectionAction {
        case "replace":
            guard let replacement = activeJournal.replacementCollection,
                  !Self.pathExists(at: collectionURL)
                      || Self.isOwnedRegularFile(at: collectionURL),
                  let replacementData = Self.cleanupReplacementCollectionData(
                      replacement,
                      excluding: activeJournal.removedDraftKey
                  ) else {
                return
            }
            let replacementDigest = SHA256.hash(data: replacementData)
                .map { String(format: "%02x", $0) }
                .joined()
            guard activeJournal.payloadDigest == replacementDigest else { return }
            let alreadyApplied = Self.cleanupFileGeneration(at: collectionURL)?.digest == replacementDigest
            if !alreadyApplied {
                guard !Self.pathExists(at: collectionURL)
                        || Self.cleanupFileGeneration(at: collectionURL) == activeJournal.collectionGeneration else {
                    return
                }
                guard Self.durableAtomicPublish(
                    replacementData,
                    to: collectionURL,
                    byteLimit: Self.cleanupCollectionBytesLimit,
                    expectedExisting: activeJournal.collectionGeneration,
                    requireAbsent: activeJournal.collectionGeneration == nil
                ) else {
                    return
                }
            }
            guard let persistedCollectionData = try? Data(contentsOf: collectionURL),
                  persistedCollectionData == replacementData,
                  Self.cleanupFileGeneration(at: collectionURL)?.digest == replacementDigest else {
                return
            }
        case "remove":
            guard activeJournal.replacementCollection == nil else { return }
            if Self.pathExists(at: collectionURL) {
                guard let expectedGeneration = activeJournal.collectionGeneration,
                      Self.durableRemoveOwnedFile(at: collectionURL, expected: expectedGeneration),
                      !Self.pathExists(at: collectionURL) else { return }
            } else {
                guard activeJournal.collectionGeneration != nil else { return }
            }
        default:
            return
        }

        guard let committedJournalGeneration = Self.cleanupFileGeneration(at: journalURL) else {
            return
        }

        // Preflight the final receipt before clearing the draft.  A marker
        // history overflow must leave both the draft and journal recoverable;
        // checking only after clear would lose the cleanup evidence.
        let receipt = CanvasCleanupReceipt(
            sessionRootPath: store.directory.standardizedFileURL.path,
            removedDraftKey: committedJournal.removedDraftKey,
            receiptID: receiptID,
            removedDraftGeneration: committedJournal.removedDraftGeneration,
            collectionGeneration: committedJournal.collectionGeneration,
            transactionID: committedJournal.transactionID,
            documentScope: committedJournal.documentScope,
            documentEpoch: committedJournal.documentEpoch,
            epochPreviousDigest: committedJournal.epochPreviousDigest,
            epochPreviousRootDigest: committedJournal.epochPreviousRootDigest,
            epochSuccessorDigest: committedJournal.epochSuccessorDigest,
            tombstonePredecessorDigest: committedJournal.tombstonePredecessorDigest,
            tombstoneGeneration: committedJournal.tombstoneGeneration,
            tombstoneRootDigest: committedJournal.tombstoneRootDigest,
            transactionGeneration: committedJournal.transactionGeneration,
            checkpointDigest: committedJournal.checkpointDigest,
            checkpointRootDigest: committedJournal.checkpointRootDigest,
            journalDigest: committedJournalGeneration.digest
        )
        guard let receiptData = try? Self.cleanupEncodedData(receipt),
              receiptData.count <= Self.cleanupReceiptBytesLimit,
              Self.cleanupMarkerHistoryIsBounded(
                  journalData: activeData,
                  receiptData: receiptData
              ) else {
            return
        }

        let cleanupHook = cleanupBeforeDraftClearHook
        cleanupBeforeDraftClearHook = nil
        cleanupHook?()
        guard Self.cleanupFileGeneration(at: journalURL) == committedJournalGeneration,
              !Self.pathExists(at: draftURL)
                || Self.cleanupFileGeneration(at: draftURL) == committedJournal.removedDraftGeneration,
              store.clear(key: committedJournal.removedDraftKey) else {
            return
        }
        let receiptHook = cleanupBeforeReceiptHook
        cleanupBeforeReceiptHook = nil
        guard receiptHook?() ?? true,
              Self.cleanupFileGeneration(at: journalURL) == committedJournalGeneration,
              writeCleanupReceipt(
                  receipt,
                  replacing: existingReceiptGeneration,
                  to: store
              ),
              let receiptData = try? Data(contentsOf: receiptURL),
              let receiptReadback = try? JSONDecoder().decode(
                  CanvasCleanupReceipt.self,
                  from: receiptData
              ),
              receiptReadback == receipt,
              Self.cleanupJSONIsCanonical(receiptReadback, data: receiptData),
              Self.cleanupMarkerHistoryIsBounded(
                  journalData: activeData,
                  receiptData: receiptData
              ),
              Self.cleanupFileGeneration(at: journalURL) == committedJournalGeneration else {
            return
        }
        guard let receiptGeneration = Self.cleanupFileGeneration(at: receiptURL) else {
            return
        }
        let markerRemovalHook = cleanupBeforeMarkerRemovalHook
        cleanupBeforeMarkerRemovalHook = nil
        markerRemovalHook?()
        guard Self.cleanupFileGeneration(at: journalURL) == committedJournalGeneration,
              Self.cleanupFileGeneration(at: receiptURL) == receiptGeneration,
              !Self.pathExists(at: candidateURL) else {
            return
        }
        guard Self.durableRemoveOwnedFile(at: journalURL, expected: committedJournalGeneration),
              !Self.pathExists(at: journalURL) else { return }
    }

    private func writeCleanupJournal(_ journal: CanvasCleanupJournal, to store: DraftStore) -> Bool {
        let url = Self.cleanupJournalURL(at: store.directory)
        let candidateURL = Self.cleanupJournalCandidateURL(at: store.directory)
        guard !Self.pathExists(at: url), !Self.pathExists(at: candidateURL) else { return false }
        guard let data = try? Self.cleanupEncodedData(journal),
              Self.cleanupJournalDataIsBounded(journal, data: data),
              Self.cleanupPayloadDigest(for: journal) == journal.payloadDigest,
              journal.documentEpoch == 1
                  ? journal.epochPreviousRootDigest == nil
                  : (journal.epochPreviousRootDigest == nil
                      || journal.epochPreviousRootDigest.map(Self.cleanupDigestIsCanonical) == true),
              journal.tombstoneGeneration > 0,
              journal.tombstoneGeneration <= UInt64(Self.cleanupTombstoneGenerationLimit),
              journal.tombstonePredecessorDigest == nil
                  || journal.tombstonePredecessorDigest.map(Self.cleanupDigestIsCanonical) == true,
              Self.cleanupDigestIsCanonical(journal.tombstoneRootDigest),
              journal.tombstoneRootDigest == canvasCleanupTombstoneRootDigest(
                  sessionRootPath: journal.sessionRootPath,
                  documentScope: journal.documentScope,
                  documentEpoch: journal.documentEpoch,
                  epochPreviousDigest: journal.epochPreviousDigest,
                  epochPreviousRootDigest: journal.epochPreviousRootDigest
              ),
              Self.cleanupDigestIsCanonical(journal.checkpointRootDigest),
              journal.checkpointRootDigest == canvasCleanupCheckpointRootDigest(
                  tombstoneRootDigest: journal.tombstoneRootDigest,
                  checkpointDigest: journal.checkpointDigest
              ),
              journal.epochSuccessorDigest == canvasCleanupEpochSuccessorDigest(
                  previousRootDigest: journal.epochPreviousRootDigest,
                  currentRootDigest: journal.tombstoneRootDigest,
                  checkpointRootDigest: journal.checkpointRootDigest
              ) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: store.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return Self.durableAtomicPublish(
                data,
                to: url,
                byteLimit: Self.cleanupJournalBytesLimit,
                requireAbsent: true
            )
        } catch {
            return false
        }
    }

    private func writeCleanupJournalState(
        _ journal: CanvasCleanupJournal,
        expected: CanvasCleanupJournal,
        to store: DraftStore
    ) -> Bool {
        let url = Self.cleanupJournalURL(at: store.directory)
        let candidateURL = Self.cleanupJournalCandidateURL(at: store.directory)
        guard Self.isOwnedRegularFile(at: url),
              !Self.pathExists(at: candidateURL),
              let currentData = try? Data(contentsOf: url),
              Self.cleanupJSONStructureIsStrict(currentData),
              let current = try? JSONDecoder().decode(CanvasCleanupJournal.self, from: currentData),
              Self.cleanupJSONIsCanonical(current, data: currentData),
              Self.cleanupJournalDataIsBounded(current, data: currentData),
              Self.cleanupPayloadDigest(for: current) == current.payloadDigest,
              current == expected,
              expected.transactionGeneration > 0,
              expected.transactionGeneration < UInt64.max,
              journal.receiptID == expected.receiptID,
              journal.transactionID == expected.transactionID,
              journal.documentScope == expected.documentScope,
              journal.documentEpoch == expected.documentEpoch,
              journal.epochPreviousDigest == expected.epochPreviousDigest,
              journal.epochPreviousRootDigest == expected.epochPreviousRootDigest,
              journal.documentEpoch == 1
                  ? journal.epochPreviousRootDigest == nil
                  : (journal.epochPreviousRootDigest == nil
                      || journal.epochPreviousRootDigest.map(Self.cleanupDigestIsCanonical) == true),
              journal.epochSuccessorDigest == canvasCleanupEpochSuccessorDigest(
                  previousRootDigest: journal.epochPreviousRootDigest,
                  currentRootDigest: journal.tombstoneRootDigest,
                  checkpointRootDigest: journal.checkpointRootDigest
              ),
              journal.tombstonePredecessorDigest == expected.tombstonePredecessorDigest,
              journal.tombstoneGeneration == expected.tombstoneGeneration,
              journal.tombstoneRootDigest == expected.tombstoneRootDigest,
              journal.payloadDigest == expected.payloadDigest,
              journal.checkpointGeneration == expected.transactionGeneration,
              journal.transactionGeneration == expected.transactionGeneration + 1,
              journal.previousDigest == Self.cleanupJournalDigest(currentData),
              journal.checkpointDigest == journal.previousDigest,
              Self.cleanupDigestIsCanonical(journal.tombstoneRootDigest),
              journal.tombstoneRootDigest == canvasCleanupTombstoneRootDigest(
                  sessionRootPath: journal.sessionRootPath,
                  documentScope: journal.documentScope,
                  documentEpoch: journal.documentEpoch,
                  epochPreviousDigest: journal.epochPreviousDigest,
                  epochPreviousRootDigest: journal.epochPreviousRootDigest
              ),
              Self.cleanupDigestIsCanonical(journal.checkpointRootDigest),
              journal.checkpointRootDigest == canvasCleanupCheckpointRootDigest(
                  tombstoneRootDigest: journal.tombstoneRootDigest,
                  checkpointDigest: journal.checkpointDigest
              ),
              journal.state == .committed,
              let data = try? Self.cleanupEncodedData(journal),
              Self.cleanupJournalDataIsBounded(journal, data: data),
              Self.cleanupPayloadDigest(for: journal) == journal.payloadDigest else {
            return false
        }
        guard let currentGeneration = Self.cleanupFileGeneration(at: url),
              currentGeneration.digest == Self.cleanupJournalDigest(currentData) else {
            return false
        }
        do {
            guard Self.durableAtomicPublish(
                data,
                to: candidateURL,
                byteLimit: Self.cleanupJournalBytesLimit,
                requireAbsent: true
            ),
                  Self.isOwnedRegularFile(at: candidateURL),
                  let candidateData = try? Data(contentsOf: candidateURL),
                  candidateData == data,
                  let candidateGeneration = Self.cleanupFileGeneration(at: candidateURL),
                  candidateGeneration.digest == Self.cleanupJournalDigest(data),
                  Self.cleanupFileGeneration(at: candidateURL) == candidateGeneration else {
                return false
            }
            guard Self.cleanupFileGeneration(at: url) == currentGeneration else {
                return false
            }
            guard Self.durableAtomicPublish(
                data,
                to: url,
                byteLimit: Self.cleanupJournalBytesLimit,
                expectedExisting: currentGeneration
            ) else {
                return false
            }
            guard Self.isOwnedRegularFile(at: url),
                  let promotedData = try? Data(contentsOf: url),
                  promotedData == data else {
                return false
            }
            guard Self.durableRemoveOwnedFile(at: candidateURL, expected: candidateGeneration),
                  !Self.pathExists(at: candidateURL) else {
                return false
            }
            return true
        }
    }

    private func writeCleanupReceipt(
        _ receipt: CanvasCleanupReceipt,
        replacing expectedGeneration: CanvasFileGeneration?,
        to store: DraftStore
    ) -> Bool {
        let url = Self.cleanupReceiptURL(at: store.directory)
        guard let data = try? Self.cleanupEncodedData(receipt),
              data.count <= Self.cleanupReceiptBytesLimit,
              receipt.documentEpoch == 1
                  ? receipt.epochPreviousRootDigest == nil
                  : (receipt.epochPreviousRootDigest == nil
                      || receipt.epochPreviousRootDigest.map(Self.cleanupDigestIsCanonical) == true),
              Self.cleanupDigestIsCanonical(receipt.tombstoneRootDigest),
              receipt.tombstoneRootDigest == canvasCleanupTombstoneRootDigest(
                  sessionRootPath: receipt.sessionRootPath,
                  documentScope: receipt.documentScope,
                  documentEpoch: receipt.documentEpoch,
                  epochPreviousDigest: receipt.epochPreviousDigest,
                  epochPreviousRootDigest: receipt.epochPreviousRootDigest
              ),
              receipt.epochSuccessorDigest == canvasCleanupEpochSuccessorDigest(
                  previousRootDigest: receipt.epochPreviousRootDigest,
                  currentRootDigest: receipt.tombstoneRootDigest,
                  checkpointRootDigest: receipt.checkpointRootDigest
              ) else {
            return false
        }
        if Self.pathExists(at: url) {
            guard let expectedGeneration,
                  Self.cleanupFileGeneration(at: url) == expectedGeneration else {
                return false
            }
        } else if expectedGeneration != nil {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: store.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return Self.durableAtomicPublish(
                data,
                to: url,
                byteLimit: Self.cleanupReceiptBytesLimit,
                expectedExisting: expectedGeneration,
                requireAbsent: expectedGeneration == nil
            )
        } catch {
            return false
        }
    }

    private func collectionSnapshot(
        for documents: [CanvasDocument],
        currentID: UUID
    ) -> CanvasCollectionSnapshot {
        CanvasCollectionSnapshot(
            currentCanvasID: currentID.uuidString,
            documents: documents.map {
                CanvasCollectionMeta(
                    id: $0.id,
                    name: $0.name,
                    draftKey: $0.draftKey,
                    schemaVersion: 2,
                    assetIDs: $0.assetIDs,
                    tasks: $0.tasks,
                    viewport: $0.viewport,
                    selection: $0.selection,
                    selectionOrder: $0.selectionOrder,
                    selectedGroupID: $0.selectedGroupID,
                    previewNodeID: $0.previewNodeID
                )
            }
        )
    }

    /// 多画布恢复：集合文件存在时，按元数据重建画布集合，并从各画布草稿恢复图。
    /// 不消费草稿（多画布模式下草稿即持久存储）；无草稿的画布用空图。
    ///
    /// BUG-1（R9 卡顿专项，2026-08-06）：原实现 `Data(contentsOf:)` 读集合文件 +
    /// 逐画布草稿读取/解码全在主线程同步执行（调用链 attachDraftStore ← BridgeStore
    /// 装配 ← App .task），违反「主线程同步 I/O 是卡死根源」铁律。现改为
    /// Task.detached 后台 I/O + 解码（参照 ChatStore.addAttachments 既有模式），
    /// 完成后回主线程装配状态。主线程仅保留一次 fileExists 探测（stat 微秒级，
    /// 无集合文件时同步 no-op 不起后台任务——启动时序/测试行为零变化）。
    private func restoreCollectionIfPresent() {
        invalidateCollectionRestore()
        let generation = collectionRestoreGeneration
        guard let store = draftStore else { return }
        let url = store.directory.appendingPathComponent(Self.collectionFileName)
        guard Self.isOwnedRegularFile(at: url),
              let collectionGeneration = Self.cleanupFileGeneration(at: url) else { return }
        let beforeApplyHook = collectionRestoreBeforeApplyHook
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            // —— 后台线程：磁盘 I/O + JSON 解码（不捕获 self，纯 Sendable 值流转）——
            guard !Task.isCancelled,
                  Self.isOwnedRegularFile(at: url),
                  Self.cleanupFileGeneration(at: url) == collectionGeneration else { return }
            guard let data = try? Data(contentsOf: url),
                  data.count <= Self.cleanupCollectionBytesLimit,
                  Self.cleanupJSONStructureIsStrict(data) else {
                Self.quarantineCollection(at: url, expected: collectionGeneration)
                await MainActor.run { [weak self] in
                    guard let self, self.collectionRestoreGeneration == generation else { return }
                    self.collectionRestoreDiagnostic = .corruptCollection
                }
                return
            }
            let decoder = JSONDecoder()
            let restoredPayload: RestoredCollectionPayload
            if let snapshot = try? decoder.decode(CanvasCollectionSnapshot.self, from: data),
               snapshot.schemaVersion == CanvasCollectionSnapshot.currentSchemaVersion,
               !snapshot.documents.isEmpty,
               snapshot.documents.count <= Self.cleanupCollectionEntryLimit,
               Self.cleanupJSONIsCanonical(snapshot, data: data) {
                let current: UUID?
                let diagnostic: CanvasCollectionRestoreDiagnostic?
                if let rawID = snapshot.currentCanvasID {
                    if let parsedID = UUID(uuidString: rawID),
                       parsedID.uuidString == rawID {
                        current = parsedID
                        diagnostic = nil
                    } else {
                        current = nil
                        diagnostic = .invalidCurrentCanvasID(rawID)
                    }
                } else {
                    current = nil
                    diagnostic = .missingCurrentCanvasID
                }
                restoredPayload = RestoredCollectionPayload(
                    metas: snapshot.documents,
                    requestedCurrentCanvasID: current,
                    diagnostic: diagnostic
                )
            } else if let metas = try? decoder.decode([CanvasCollectionMeta].self, from: data),
                      !metas.isEmpty,
                      metas.count <= Self.cleanupCollectionEntryLimit,
                      Self.cleanupJSONIsCanonical(metas, data: data) {
                // Pre-envelope collections have no activity pointer; preserve their
                // first-document behavior while making the migration explicit.
                restoredPayload = RestoredCollectionPayload(
                    metas: metas,
                    requestedCurrentCanvasID: nil,
                    diagnostic: .missingCurrentCanvasID
                )
            } else {
                Self.quarantineCollection(at: url, expected: collectionGeneration)
                await MainActor.run { [weak self] in
                    guard let self, self.collectionRestoreGeneration == generation else { return }
                    self.collectionRestoreDiagnostic = .corruptCollection
                }
                return
            }
            if let duplicate = Self.collectionValidationDiagnostic(for: restoredPayload.metas) {
                await MainActor.run { [weak self] in
                    guard let self, self.collectionRestoreGeneration == generation else { return }
                    self.collectionRestoreDiagnostic = duplicate
                }
                return
            }
            var items: [RestoredCollectionItem] = []
            items.reserveCapacity(restoredPayload.metas.count)
            for meta in restoredPayload.metas {
                let draftURL = store.draftsDirectory
                    .appendingPathComponent("\(meta.draftKey).json")
                let initialDraftGeneration: CanvasFileGeneration?
                if Self.pathExists(at: draftURL) {
                    guard Self.isOwnedRegularFile(at: draftURL),
                          let draftGeneration = Self.cleanupFileGeneration(at: draftURL) else {
                        await MainActor.run { [weak self] in
                            guard let self, self.collectionRestoreGeneration == generation else { return }
                            self.collectionRestoreDiagnostic = .corruptCollection
                        }
                        return
                    }
                    initialDraftGeneration = draftGeneration
                } else {
                    initialDraftGeneration = nil
                }
                var draft: CanvasDraft?
                if let payload = store.load(key: meta.draftKey) {
                    guard payload.count <= Self.cleanupPayloadBytesLimit,
                          let decoded = try? JSONDecoder().decode(CanvasDraft.self, from: payload),
                          (1...3).contains(decoded.schemaVersion),
                          (try? decoded.toGraph().validate()) != nil else {
                        await MainActor.run { [weak self] in
                            guard let self, self.collectionRestoreGeneration == generation else { return }
                            self.collectionRestoreDiagnostic = .corruptCollection
                        }
                        return
                    }
                    draft = decoded
                } else if store.lastLoadError(for: meta.draftKey) != nil {
                    await MainActor.run { [weak self] in
                        guard let self, self.collectionRestoreGeneration == generation else { return }
                        self.collectionRestoreDiagnostic = .corruptCollection
                    }
                    return
                }
                items.append(RestoredCollectionItem(
                    meta: meta,
                    draft: draft,
                    draftGeneration: initialDraftGeneration
                ))
            }
            guard !Task.isCancelled,
                  Self.isOwnedRegularFile(at: url),
                  Self.cleanupFileGeneration(at: url) == collectionGeneration,
                  Self.restoredDraftGenerationsMatch(
                      items,
                      draftsDirectory: store.draftsDirectory
                  ) else { return }
            await beforeApplyHook?()
            guard !Task.isCancelled,
                  Self.isOwnedRegularFile(at: url),
                  Self.cleanupFileGeneration(at: url) == collectionGeneration,
                  Self.restoredDraftGenerationsMatch(
                      items,
                      draftsDirectory: store.draftsDirectory
                  ) else { return }
            // —— 回主线程装配状态（CanvasStore 全部可变状态只在主 actor 写入）——
            let assetRestore = await MainActor.run { [weak self] () -> Task<Void, Never>? in
                guard let self,
                      self.collectionRestoreGeneration == generation,
                      Self.isOwnedRegularFile(at: url),
                      Self.cleanupFileGeneration(at: url) == collectionGeneration,
                      Self.restoredDraftGenerationsMatch(
                          items,
                          draftsDirectory: store.draftsDirectory
                      ) else { return nil }
                return self.applyRestoredCollection(
                    items,
                    requestedCurrentCanvasID: restoredPayload.requestedCurrentCanvasID,
                    diagnostic: restoredPayload.diagnostic,
                    generation: generation
                )
            }
            // Completion includes the follow-up collection write. A caller
            // awaiting restoration can safely start a fresh restore afterward.
            await assetRestore?.value
        }
        collectionRestoreTask = task
    }

    nonisolated private static func collectionValidationDiagnostic(
        for metas: [CanvasCollectionMeta]
    ) -> CanvasCollectionRestoreDiagnostic? {
        guard metas.count > 1 else {
            return .corruptCollection
        }
        var canvasIDs: Set<UUID> = []
        var draftKeys: Set<String> = []
        for meta in metas {
            guard canvasIDs.insert(meta.id).inserted else {
                return .duplicateCanvasID(meta.id)
            }
            guard draftKeys.insert(meta.draftKey).inserted else {
                return .duplicateDraftKey(meta.draftKey)
            }
        }
        guard metas.allSatisfy({
            (1...CanvasCollectionMeta.currentSchemaVersion).contains($0.schemaVersion)
        }) else {
            return .corruptCollection
        }
        guard metas.enumerated().allSatisfy({ index, meta in
            meta.draftKey == Self.canvasDraftKey(for: meta.id)
                || (index == 0 && meta.draftKey == DraftStore.canvasKey)
        }) else {
            return .corruptCollection
        }
        return nil
    }

    nonisolated private static func quarantineCollection(
        at url: URL,
        expected expectedGeneration: CanvasFileGeneration
    ) {
        let fileManager = FileManager.default
        guard isOwnedRegularFile(at: url),
              cleanupFileGeneration(at: url) == expectedGeneration,
              let data = try? Data(contentsOf: url),
              data.count <= cleanupCheckpointPayloadBytesLimit,
              cleanupJournalDigest(data) == expectedGeneration.digest,
              cleanupFileGeneration(at: url) == expectedGeneration else { return }
        let destination = collectionQuarantineURL(at: url.deletingLastPathComponent())
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                guard isOwnedRegularFile(at: destination),
                      let destinationGeneration = cleanupFileGeneration(at: destination),
                      durableRemoveOwnedFile(at: destination, expected: destinationGeneration) else {
                    return
                }
            }
            guard isOwnedRegularFile(at: url),
                  cleanupFileGeneration(at: url) == expectedGeneration,
                  durableAtomicPublish(
                      data,
                      to: destination,
                      byteLimit: cleanupCheckpointPayloadBytesLimit,
                      requireAbsent: true
                  ),
                  durableRemoveOwnedFile(at: url, expected: expectedGeneration),
                  !pathExists(at: url) else { return }
        } catch {
            // Keep the source when quarantine itself fails; the diagnostic remains visible.
        }
    }

    private struct RestoredCollectionPayload: Sendable {
        let metas: [CanvasCollectionMeta]
        let requestedCurrentCanvasID: UUID?
        let diagnostic: CanvasCollectionRestoreDiagnostic?
    }

    /// 后台解码结果跨任务边界的安全载体：全字段 Sendable 值类型，后台任务内只读，
    /// 回主线程后交 applyRestoredCollection 装配（不跨线程共享可变状态）。
    private struct RestoredCollectionItem: Sendable {
        let meta: CanvasCollectionMeta
        let draft: CanvasDraft?
        let draftGeneration: CanvasFileGeneration?
    }

    private nonisolated static func restoredDraftGenerationsMatch(
        _ items: [RestoredCollectionItem],
        draftsDirectory: URL
    ) -> Bool {
        items.allSatisfy { item in
            let url = draftsDirectory
                .appendingPathComponent("\(item.meta.draftKey).json")
            guard let expected = item.draftGeneration else {
                return !Self.pathExists(at: url)
            }
            return Self.isOwnedRegularFile(at: url)
                && Self.cleanupFileGeneration(at: url) == expected
        }
    }

    /// 主线程装配恢复的集合（restoreCollectionIfPresent 后台任务的主线程回写点）：
    /// 草稿 → 节点图 → assetRef 输出互斥规范化 → 覆盖集合/当前画布/交互态。
    /// 语义与旧同步实现完全一致，仅执行位置后移到后台任务完成之后。
    private func applyRestoredCollection(
        _ items: [RestoredCollectionItem],
        requestedCurrentCanvasID: UUID?,
        diagnostic: CanvasCollectionRestoreDiagnostic?,
        generation: UInt64
    ) -> Task<Void, Never> {
        var docs: [CanvasDocument] = []
        var legacyProjectionCanvasIDs: Set<UUID> = []
        docs.reserveCapacity(items.count)
        for item in items {
            var restored = NodeGraph()
            if let draft = item.draft {
                restored = draft.toGraph()
                // assetRef 输出互斥：旧图「image+video 双端口并存」节点按已挂载资产 kind 唯一化
                Self.normalizeAssetRefPorts(in: &restored)
            }
            let draftHasCanvasState = (item.draft?.schemaVersion ?? 0) >= 3
            let restoredGroups = item.draft.map { $0.groups } ?? []
            if !draftHasCanvasState {
                legacyProjectionCanvasIDs.insert(item.meta.id)
            }
            docs.append(CanvasDocument(
                id: item.meta.id,
                name: item.meta.name,
                graph: restored,
                draftKey: item.meta.draftKey,
                assetIDs: draftHasCanvasState ? (item.draft?.assetIDs ?? []) : item.meta.assetIDs,
                tasks: draftHasCanvasState ? (item.draft?.tasks ?? []) : item.meta.tasks,
                viewport: draftHasCanvasState ? (item.draft?.viewport ?? CanvasViewportState()) : item.meta.viewport,
                selection: draftHasCanvasState ? (item.draft?.selection ?? []) : item.meta.selection,
                selectionOrder: draftHasCanvasState ? (item.draft?.selectionOrder ?? []) : item.meta.selectionOrder,
                selectedGroupID: draftHasCanvasState ? item.draft?.selectedGroupID : item.meta.selectedGroupID,
                previewNodeID: draftHasCanvasState ? item.draft?.previewNodeID : item.meta.previewNodeID,
                groups: restoredGroups
            ))
            assetIDsByCanvas[item.meta.id] = draftHasCanvasState ? (item.draft?.assetIDs ?? []) : item.meta.assetIDs
        }
        canvasDocuments = docs
        let restoredCurrentID = requestedCurrentCanvasID.flatMap { id in
            docs.contains(where: { $0.id == id }) ? id : nil
        }
        if let requestedCurrentCanvasID, restoredCurrentID == nil {
            collectionRestoreDiagnostic = .unknownCurrentCanvasID(requestedCurrentCanvasID)
        } else {
            collectionRestoreDiagnostic = diagnostic
        }
        currentCanvasID = restoredCurrentID ?? docs[0].id
        graph = currentCanvas.graph
        loadInteractiveState(from: currentCanvas)
        refreshRecoveryScope()
        return restoreLegacyAssets(
            for: docs,
            projectingLegacyAssetIDsFor: legacyProjectionCanvasIDs,
            generation: generation
        )
    }

    /// Register legacy result fields once per canvas. The deterministic migration ID
    /// makes repeated launches idempotent and keeps old drafts readable.
    private func restoreLegacyAssets(
        for documents: [CanvasDocument],
        projectingLegacyAssetIDsFor projectionCanvasIDs: Set<UUID>,
        generation: UInt64
    ) -> Task<Void, Never> {
        let assetStore = assetStore
        return Task { [weak self] in
            guard let self else { return }
            for document in documents {
                guard self.collectionRestoreGeneration == generation else { return }
                var canonicalGraph = document.graph
                let legacyAssets = canonicalizeLegacyMedia(
                    in: &canonicalGraph,
                    canvasID: document.id
                )
                let migrated = await assetStore.migrateLegacyNodes(document.graph.nodes, canvasID: document.id)
                guard self.collectionRestoreGeneration == generation else { return }
                let graphChanged = canonicalGraph != document.graph
                if graphChanged,
                   let index = canvasDocuments.firstIndex(where: { $0.id == document.id }) {
                    canvasDocuments[index].graph = canonicalGraph
                    if document.id == currentCanvasID {
                        graph = canonicalGraph
                    }
                }
                var changed = !migrated.isEmpty || graphChanged
                if !migrated.isEmpty {
                    await assetStore.persist(to: assetPersistenceDirectory)
                }
                guard self.collectionRestoreGeneration == generation else { return }
                if projectionCanvasIDs.contains(document.id) {
                    let legacyIDs = Set(legacyAssets.map(\.id))
                    let existingIDs = assetIDsByCanvas[document.id, default: []]
                    let addedIDs = legacyIDs.subtracting(existingIDs)
                    if !addedIDs.isEmpty {
                        assetIDsByCanvas[document.id, default: []].formUnion(addedIDs)
                        if let index = canvasDocuments.firstIndex(where: { $0.id == document.id }) {
                            canvasDocuments[index].assetIDs.formUnion(addedIDs)
                        }
                        changed = true
                    }
                }
                if graphChanged {
                    persistCanonicalizedDraft(documentID: document.id, graph: canonicalGraph)
                }
                if changed {
                    assetIndexRevision &+= 1
                }
            }
            guard self.collectionRestoreGeneration == generation else { return }
            syncCurrentStateToDocument()
            saveCollection()
        }
    }

    /// Convert legacy result fields to the stable asset identity while leaving
    /// the old fields intact as a read/migration projection for old documents.
    private func canonicalizeLegacyMedia(
        in graph: inout NodeGraph,
        canvasID: UUID
    ) -> [MediaAsset] {
        let legacyAssets = LegacyMediaMigration.assets(from: graph, canvasID: canvasID)
        for index in graph.nodes.indices {
            guard graph.nodes[index].mediaAssetID == nil,
                  let migrated = LegacyMediaMigration.canonicalize(
                    node: graph.nodes[index],
                    canvasID: canvasID
                  ) else {
                continue
            }
            graph.nodes[index] = migrated.node
        }
        return legacyAssets
    }

    /// Keep the synchronous UI projection usable immediately after recovery and
    /// enqueue the same canonical assets for durable actor persistence.
    private func projectLegacyAssets(_ assets: [MediaAsset], canvasID: UUID) {
        guard !assets.isEmpty else { return }
        assetIDsByCanvas[canvasID, default: []].formUnion(assets.map(\.id))
        if let index = canvasDocuments.firstIndex(where: { $0.id == canvasID }) {
            canvasDocuments[index].assetIDs.formUnion(assets.map(\.id))
        }
        for asset in assets {
            assetProjectionByID[asset.id] = asset
        }
        assetIndexRevision &+= 1
        let assetStore = assetStore
        let persistenceDirectory = assetPersistenceDirectory
        Task {
            for asset in assets {
                await assetStore.register(asset, canvasID: canvasID)
            }
            await assetStore.persist(to: persistenceDirectory)
        }
    }

    /// Persist a non-current canvas after recovery canonicalization. The
    /// collection metadata alone does not carry its graph payload.
    private func persistCanonicalizedDraft(documentID: UUID, graph: NodeGraph) {
        guard let store = draftStore,
              let document = canvasDocuments.first(where: { $0.id == documentID }) else {
            return
        }
        let draft = CanvasDraft(
            graph: graph,
            groups: document.groups,
            savedAt: Date(),
            assetIDs: document.assetIDs,
            tasks: document.tasks,
            viewport: document.viewport,
            selection: document.selection,
            selectionOrder: document.selectionOrder,
            selectedGroupID: document.selectedGroupID,
            previewNodeID: document.previewNodeID
        )
        guard let data = try? JSONEncoder().encode(draft) else { return }
        store.scheduleSave(key: document.draftKey, payload: data)
        store.flushNow(key: document.draftKey)
    }

    // MARK: - 节点操作

    /// 添加节点；返回新建节点（聊天指令回执用）
    /// AJ-66 防线：非有限落点（视口污染时 world() 退化产物）→ 退化为网格默认点，
    /// 绝不把 NaN 写进节点 position（一旦落盘，重启恢复的也是 NaN 位置，画布永久不可见）。
    @discardableResult
    func addNode(ofType type: String, at position: Point? = nil) -> CanvasNode? {
        guard let spec = NodeTypeRegistry.spec(for: type) else { return nil }
        let gridDefault = Point(x: 160 + Double(graph.nodes.count % 5) * 60,
                                y: 160 + Double(graph.nodes.count / 5) * 60)
        let base: Point
        if let position, position.x.isFinite, position.y.isFinite {
            base = position
        } else {
            if position != nil {
                AJ66Diagnostics.logNonFinite(source: "CanvasStore.addNode", zoom: 0, pan: .zero,
                                             input: "position=(\(position!.x),\(position!.y))")
            }
            base = gridDefault
        }
        let node = spec.makeNode(position: base)
        pushUndoState()
        graph.addNode(node)
        noteGraphChanged()
        selectedNodeID = node.id
        onEvent?(.nodeAdded(title: node.title, type: node.type))
        return node
    }

    func moveNode(id: UUID, to position: Point) {
        // AJ-66 防线：非有限目标位置拒绝写入（拖拽 delta 污染 / 历史 NaN 起点），
        // 避免 NaN 经节点 position 落盘。
        guard position.x.isFinite, position.y.isFinite else {
            AJ66Diagnostics.logNonFinite(source: "CanvasStore.moveNode", zoom: 0, pan: .zero,
                                         input: "position=(\(position.x),\(position.y))")
            return
        }
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[index].position = position
        noteGraphChanged()
    }

    // MARK: - AJ-12 多选批量移动（拖动整组：所有选中节点同步平移）

    /// 批量平移指定节点（相对位移 delta）。用于多选拖拽整组：所有选中节点同步平移，
    /// 保持各自的相对位置与连线（连线锚定节点，自动跟随）。一次性 noteGraphChanged。
    /// 不存在的节点 id 自动过滤；空集合 no-op。
    func moveNodes(_ ids: Set<UUID>, by delta: Point) {
        // AJ-66 防线：非有限位移拒绝整批（gesture translation 异常）
        guard delta.x.isFinite, delta.y.isFinite else {
            AJ66Diagnostics.logNonFinite(source: "CanvasStore.moveNodes", zoom: 0, pan: .zero,
                                         input: "delta=(\(delta.x),\(delta.y))")
            return
        }
        let valid = ids.filter { graph.node(id: $0) != nil }
        guard !valid.isEmpty else { return }
        for id in valid {
            guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { continue }
            let p = graph.nodes[index].position
            let next = Point(x: p.x + delta.x, y: p.y + delta.y)
            // AJ-66 防线：结果非有限（起点已污染）→ 跳过该节点，不扩散 NaN
            guard next.x.isFinite, next.y.isFinite else {
                AJ66Diagnostics.logNonFinite(source: "CanvasStore.moveNodes", zoom: 0, pan: .zero,
                                             input: "start=(\(p.x),\(p.y)) delta=(\(delta.x),\(delta.y))")
                continue
            }
            graph.nodes[index].position = next
        }
        noteGraphChanged()
    }

    /// 批量平移所有选中节点（多选拖拽整组的 store 入口）。未选中时 no-op。
    func moveSelectedNodes(by delta: Point) {
        moveNodes(selectedNodeIDs, by: delta)
    }

    // MARK: - AJ-21 画布组操作（参照 ComfyUI 组）

    /// 由一组节点创建画布组：按节点包围盒外扩 padding 生成组矩形，框住这些节点。
    /// 返回新建组；节点集合为空或全部不存在返回 nil。
    @discardableResult
    func createGroup(nodeIDs: Set<UUID>, title: String? = nil) -> CanvasGroup? {
        let ids = nodeIDs.filter { graph.node(id: $0) != nil }
        guard !ids.isEmpty else { return nil }
        let pad = CanvasGroup.padding
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for id in ids {
            guard let node = graph.node(id: id) else { continue }
            let h = NodeMetrics.nodeHeight(inputs: node.inputs.count, outputs: node.outputs.count)
            minX = min(minX, node.position.x - NodeMetrics.nodeWidth / 2)
            minY = min(minY, node.position.y - h / 2)
            maxX = max(maxX, node.position.x + NodeMetrics.nodeWidth / 2)
            maxY = max(maxY, node.position.y + h / 2)
        }
        let group = CanvasGroup(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
                : "组 \(groups.count + 1)",
            origin: Point(x: minX - pad, y: minY - pad),
            size: CGSize(width: maxX - minX + pad * 2, height: maxY - minY + pad * 2),
            nodeIDs: ids
        )
        groups.append(group)
        statusMessage = "已创建分组「\(group.title)」（\(ids.count) 节点）"
        return group
    }

    /// 由当前选中节点建组（画布空白右键「创建分组」入口）。
    /// 未选中节点返回 nil。
    @discardableResult
    func createGroupFromSelection() -> CanvasGroup? {
        guard let group = createGroup(nodeIDs: selectedNodeIDs) else {
            statusMessage = "请先选中节点"
            return nil
        }
        return group
    }

    /// 移动整组：组矩形平移 delta，成员节点同步平移（连线锚定节点，自动跟随）。
    func moveGroup(id: UUID, by delta: Point) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups[index]
        groups[index].origin = Point(x: group.origin.x + delta.x, y: group.origin.y + delta.y)
        for nodeID in group.nodeIDs {
            guard let nodeIndex = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
            graph.nodes[nodeIndex].position = Point(
                x: graph.nodes[nodeIndex].position.x + delta.x,
                y: graph.nodes[nodeIndex].position.y + delta.y)
        }
        noteGraphChanged()
    }

    /// B4：选中组（显示四角缩放手柄）；同时取消节点选中，避免组手柄与节点选中态并存。
    func selectGroup(id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        if selectedNodeID != nil || !selectedNodeIDs.isEmpty || pendingEdge != nil {
            deselectAll()
        }
        selectedGroupID = id
        noteGraphChanged()
    }

    /// B4：缩放组——新 origin+size 应用到组矩形，成员节点相对组左上角的偏移按比例跟随
    /// （ComfyUI 组缩放语义：节点位置随组缩放平移，节点自身尺寸不变）。
    func resizeGroup(id: UUID, newOrigin: Point, newSize: CGSize) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let old = groups[index]
        // AJ-66 同款防线：非有限数值拒绝写入，防 NaN 污染组矩形/节点坐标
        guard old.size.width > 0, old.size.height > 0,
              newSize.width.isFinite, newSize.height.isFinite,
              newOrigin.x.isFinite, newOrigin.y.isFinite else { return }
        let sx = newSize.width / old.size.width
        let sy = newSize.height / old.size.height
        groups[index].origin = newOrigin
        groups[index].size = newSize
        for nodeID in old.nodeIDs {
            guard let nodeIndex = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
            let node = graph.nodes[nodeIndex]
            let dx = node.position.x - old.origin.x
            let dy = node.position.y - old.origin.y
            graph.nodes[nodeIndex].position = Point(
                x: newOrigin.x + dx * sx,
                y: newOrigin.y + dy * sy)
        }
        noteGraphChanged()
    }

    /// B10：设置组颜色（10 色预设之一）。
    func changeGroupColor(id: UUID, color: Color) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        guard groups[index].color != color else { return }
        groups[index].color = color
        noteGraphChanged()
    }

    /// 折叠 / 展开分组（折叠后成员节点隐藏，仅剩标题栏）。
    func toggleGroupCollapsed(id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isCollapsed.toggle()
        // 折叠后成员节点不可见：清理其在选中集合中的残留，避免「隐形节点仍被选中」——
        // Delete 会删除看不见的节点、⌘C 会复制隐形子图、多选拖拽会拖动隐形节点。
        if groups[index].isCollapsed {
            let members = groups[index].nodeIDs
            if !members.isEmpty {
                selectedNodeIDs.subtract(members)
                selectionOrder.removeAll { members.contains($0) }
                if selectedNodeIDs.isEmpty {
                    lastSelectionEventID = nil
                    onEvent?(.selectionCleared)
                }
            }
        }
        statusMessage = groups[index].isCollapsed
            ? "已折叠分组「\(groups[index].title)」"
            : "已展开分组「\(groups[index].title)」"
    }

    /// 折叠分组隐藏的成员节点 id（不可见、不可交互）：
    /// 渲染跳过（nodesLayer）的同时，框选/建组/吸附/全选/拖线目标一律排除，
    /// 保证「看不见的节点不可选中、不可被连线目标命中」的状态一致。
    func collapsedHiddenNodeIDs() -> Set<UUID> {
        Set(groups.filter { $0.isCollapsed }.flatMap { $0.nodeIDs })
    }

    /// 重命名分组（空串/纯空白安全忽略）；返回是否实际改名。
    @discardableResult
    func renameGroup(id: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        guard groups[index].title != trimmed else { return false }
        groups[index].title = trimmed
        statusMessage = "已重命名分组「\(trimmed)」"
        noteGraphChanged()
        return true
    }

    /// 删除分组（仅移除组容器，成员节点保留）。
    func deleteGroup(id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let title = groups[index].title
        groups.remove(at: index)
        if renamingGroupID == id { renamingGroupID = nil }
        if selectedGroupID == id { selectedGroupID = nil }
        statusMessage = "已删除分组「\(title)」"
        noteGraphChanged()
    }

    /// 把节点加入分组（节点与分组均需存在）；返回是否实际加入。
    @discardableResult
    func addNodeToGroup(nodeID: UUID, groupID: UUID) -> Bool {
        guard graph.node(id: nodeID) != nil,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        guard groups[index].nodeIDs.insert(nodeID).inserted else { return false }
        statusMessage = "已加入分组"
        noteGraphChanged()
        return true
    }

    /// 把节点移出分组；返回是否实际移出。
    @discardableResult
    func removeNodeFromGroup(nodeID: UUID, groupID: UUID) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        guard groups[index].nodeIDs.remove(nodeID) != nil else { return false }
        statusMessage = "已移出分组"
        return true
    }

    /// 节点所属的组（可能在多个组；取第一个）。无则 nil。
    func group(containing nodeID: UUID) -> CanvasGroup? {
        groups.first { $0.nodeIDs.contains(nodeID) }
    }

    /// 进入分组标题重命名态（标题栏内联编辑）
    func beginGroupRename(id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        renamingGroupID = id
    }

    func endGroupRename() {
        renamingGroupID = nil
    }

    /// F12-① 节点重命名（ComfyUI 右键 rename 语义）：
    /// 节点卡片标题双击内联编辑 / 右键「重命名」提交后写回 graph 节点 title。
    /// 空串或纯空白安全忽略（保留原标题）；返回是否实际改名。
    @discardableResult
    func renameNode(id: UUID, title newTitle: String) -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return false }
        guard graph.nodes[index].title != trimmed else { return false }
        graph.nodes[index].title = trimmed
        noteGraphChanged()
        statusMessage = "已重命名为「\(trimmed)」"
        return true
    }

    // MARK: - F12 节点卡片内容面板（种类判别 / 摘要 / 图片导入 / 媒体预览）

    /// F12 节点内容面板种类：文本（text/novelImport 等）/ 图片（image/imageGen/assetRef）/ 视频（video/videoGen）
    enum NodeContentKind: Equatable {
        case text
        case image
        case video
    }

    static let textNodeTypes: Set<String> = [
        "text",
        ManjuNodeType.novelImport.rawValue,
        ManjuNodeType.blenderPreview.rawValue,
    ]
    static let imageNodeTypes: Set<String> = [
        "image",
        ManjuNodeType.imageGen.rawValue,
        ManjuNodeType.assetRef.rawValue,
    ]
    static let videoNodeTypes: Set<String> = [
        "video",
        ManjuNodeType.videoGen.rawValue,
    ]

    /// F12 节点卡片面板种类（未知类型返回 nil → 卡片不挂内容面板）
    static func contentKind(of type: String) -> NodeContentKind? {
        if textNodeTypes.contains(type) { return .text }
        if imageNodeTypes.contains(type) { return .image }
        if videoNodeTypes.contains(type) { return .video }
        return nil
    }

    /// F12-② 卡片文本摘要：换行折叠为空格，超长按 N 字符截断加省略号（纯函数，可单测）
    static func contentSummary(_ content: String, limit: Int = 80) -> String {
        let flat = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }

    /// 将媒体登记到当前画布资产索引，并把稳定 asset.id 写回节点；旧 result.* 字段仅作兼容显示。
    private func registerMediaAsset(
        path: String,
        kind: MediaAssetKind,
        source: MediaAssetSource,
        nodeID: UUID,
        runID: UUID? = nil
    ) -> UUID {
        let assetID = UUID()
        let canvasID = currentCanvasID
        let asset = MediaAsset(
            id: assetID,
            kind: kind,
            source: source,
            localURL: path.hasPrefix("http://") || path.hasPrefix("https://") ? nil : path,
            remoteURL: path.hasPrefix("http://") || path.hasPrefix("https://") ? path : nil,
            sourceCanvasID: canvasID,
            sourceNodeID: nodeID,
            runID: runID,
            metadata: ["name": (path as NSString).lastPathComponent]
        )
        assetIDsByCanvas[canvasID, default: []].insert(assetID)
        assetProjectionByID[assetID] = asset
        let persistenceDirectory = assetPersistenceDirectory
        Task { [weak self, assetStore] in
            await assetStore.register(asset, canvasID: canvasID)
            await assetStore.persist(to: persistenceDirectory)
            await MainActor.run {
                self?.assetIndexRevision &+= 1
            }
        }
        return assetID
    }

    /// F12-③ 图片节点直接上传：校验图片可读后绑定 canonical asset ID。
    @discardableResult
    func importImage(fileURL url: URL, for nodeID: UUID) -> Bool {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
        guard Self.contentKind(of: graph.nodes[index].type) == .image else {
            statusMessage = "仅图片类节点支持直接上传图片"
            return false
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            statusMessage = "图片文件读取失败"
            return false
        }
        var config = graph.nodes[index].backendConfig ?? NodeBackendConfig()
        let assetID = registerMediaAsset(path: url.path, kind: .image, source: .imported, nodeID: nodeID)
        config.params[Self.assetIDKey] = assetID.uuidString
        graph.nodes[index].backendConfig = config
        // assetRef 输出互斥：挂载图片 → 输出端口唯一化为 text+image（回收 video 端口与旧连线）
        applyAssetRefKindPorts(nodeID: nodeID)
        noteGraphChanged()
        statusMessage = "已导入图片：\(url.lastPathComponent)"
        return true
    }

    /// B2：视频节点导入本地视频文件（校验：UTType 视频类型 + 文件存在）。
    /// assetRef 输出互斥：资产引用节点同样允许直接上传视频（资产要么是图片要么是视频，
    /// 挂载后输出端口按 kind 唯一化——见 applyAssetRefKindPorts）。
    func importVideo(fileURL url: URL, for nodeID: UUID) -> Bool {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
        let type = graph.nodes[index].type
        guard type == ManjuNodeType.assetRef.rawValue || Self.contentKind(of: type) == .video else {
            statusMessage = "仅视频类节点支持直接上传视频"
            return false
        }
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let isVideoType = {
            if let ut = UTType(filenameExtension: url.pathExtension) {
                return ut.conforms(to: .movie) || ut.conforms(to: .video)
            }
            return ["mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv", "ts"].contains(url.pathExtension.lowercased())
        }()
        guard fileExists, isVideoType else {
            statusMessage = "视频文件读取失败或格式不支持"
            return false
        }
        var config = graph.nodes[index].backendConfig ?? NodeBackendConfig()
        let assetID = registerMediaAsset(path: url.path, kind: .video, source: .imported, nodeID: nodeID)
        config.params[Self.assetIDKey] = assetID.uuidString
        graph.nodes[index].backendConfig = config
        // assetRef 输出互斥：挂载视频 → 输出端口唯一化为 text+video（回收 image 端口与旧连线）
        applyAssetRefKindPorts(nodeID: nodeID)
        noteGraphChanged()
        statusMessage = "已导入视频：\(url.lastPathComponent)"
        return true
    }

    // MARK: - assetRef 输出互斥（资产要么是图片，要么是视频，只能输出一次）

    /// assetRef 输出互斥（用户反馈：图片资产和视频资产同时可连线）——
    /// 按已挂载资产 kind（backendConfig.params["result.kind"]）唯一化输出端口：
    /// 图片资产 → 只保留 text + image；视频资产 → 只保留 text + video。
    /// 对侧媒体端口被移除，调用方需同步回收指向它的连线（防悬空边）。
    /// 非 assetRef / 未挂载资产（无 result.kind）→ nil（不变）。
    /// 端口按 dataType 判别（image/video），文本等其余输出端口恒保留（text/assets…）。
    static func assetRefKindFilteredOutputs(for node: CanvasNode)
        -> (outputs: [CanvasCore.Port], removedPortIDs: Set<UUID>)? {
        guard node.type == ManjuNodeType.assetRef.rawValue else { return nil }
        let kind = node.backendConfig?.params["result.kind"]
        guard kind == "image" || kind == "video" else { return nil }
        let keepMedia = kind == "image" ? "image" : "video"
        let outputs = node.outputs.filter {
            ($0.dataType != "image" && $0.dataType != "video") || $0.dataType == keepMedia
        }
        let removedPortIDs = Set(node.outputs.map(\.id)).subtracting(outputs.map(\.id))
        guard !removedPortIDs.isEmpty else { return nil }
        return (outputs, removedPortIDs)
    }

    /// 对单个 assetRef 节点应用输出互斥过滤（挂载/替换资产后调用），
    /// 并回收指向被移除输出端口的旧连线（如图片资产替换为视频后，image 连线一并移除）。
    private func applyAssetRefKindPorts(nodeID: UUID) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }),
              graph.nodes[index].type == ManjuNodeType.assetRef.rawValue else { return }
        let node = graph.nodes[index]
        let canonicalKind = node.backendConfig?.params[Self.assetIDKey]
            .flatMap(UUID.init(uuidString:))
            .flatMap { assetProjectionByID[$0]?.kind.rawValue }
        let kind = canonicalKind ?? node.backendConfig?.params["result.kind"]
        guard kind == "image" || kind == "video" else { return }
        let keepMedia = kind == "image" ? "image" : "video"
        let outputs = node.outputs.filter {
            ($0.dataType != "image" && $0.dataType != "video") || $0.dataType == keepMedia
        }
        let removedPortIDs = Set(node.outputs.map(\.id)).subtracting(outputs.map(\.id))
        guard !removedPortIDs.isEmpty else { return }
        graph.nodes[index].outputs = outputs
        graph.edges.removeAll { $0.fromNode == nodeID && removedPortIDs.contains($0.fromPort) }
        noteGraphChanged()
    }

    /// 批量规范化（图恢复/加载旧图时调用）：对每个已挂载资产的 assetRef 节点
    /// 执行输出互斥过滤，旧图里「image+video 双端口并存」的资产节点被唯一化。
    static func normalizeAssetRefPorts(in graph: inout NodeGraph) {
        for index in graph.nodes.indices {
            guard let filtered = assetRefKindFilteredOutputs(for: graph.nodes[index]) else { continue }
            let nodeID = graph.nodes[index].id
            graph.nodes[index].outputs = filtered.outputs
            graph.edges.removeAll { $0.fromNode == nodeID && filtered.removedPortIDs.contains($0.fromPort) }
        }
    }

    /// B7：把已有图片结果「加载到画布」——新建 canonical asset reference 节点，
    /// 节点卡片（contentKind == .image）立即显示缩略图，可继续导入替换/连线下游。
    /// 位置默认走 addNode 网格落点；near 提供时落点在该坐标附近（生图节点右键菜单偏移传入）。
    /// 返回新建节点；类型不可建（spec 缺失）返回 nil。
    @discardableResult
    func addImageAssetNode(from path: String, name: String? = nil, near position: Point? = nil) -> CanvasNode? {
        guard !path.isEmpty,
              let node = addNode(ofType: ManjuNodeType.assetRef.rawValue, at: position),
              let index = graph.nodes.firstIndex(where: { $0.id == node.id })
        else { return nil }
        var config = graph.nodes[index].backendConfig ?? NodeBackendConfig()
        let assetID = registerMediaAsset(path: path, kind: .image, source: .imported, nodeID: node.id)
        config.params[Self.assetIDKey] = assetID.uuidString
        graph.nodes[index].backendConfig = config
        // assetRef 输出互斥：挂载图片 → 输出端口唯一化为 text+image（回收 video 端口与旧连线）
        applyAssetRefKindPorts(nodeID: node.id)
        noteGraphChanged()
        statusMessage = "已加载图片到画布：" + (name ?? (path as NSString).lastPathComponent)
        return node
    }

    /// 线G：把已有视频结果「加载到画布」——新建 canonical asset reference 节点，
    /// 节点卡片（contentKind == .video）立即显示视频播放入口，可继续导入替换/连线下游。
    /// 资产锁定互斥与图片版同源：挂载视频 → 输出端口唯一化为 text+video（回收 image 端口与旧连线）。
    /// 位置默认走 addNode 网格落点；near 提供时落点在该坐标附近（生视频节点右键菜单偏移传入）。
    /// 返回新建节点；类型不可建（spec 缺失）返回 nil。
    @discardableResult
    func addVideoAssetNode(from path: String, name: String? = nil, near position: Point? = nil) -> CanvasNode? {
        guard !path.isEmpty,
              let node = addNode(ofType: ManjuNodeType.assetRef.rawValue, at: position),
              let index = graph.nodes.firstIndex(where: { $0.id == node.id })
        else { return nil }
        var config = graph.nodes[index].backendConfig ?? NodeBackendConfig()
        let assetID = registerMediaAsset(path: path, kind: .video, source: .imported, nodeID: node.id)
        config.params[Self.assetIDKey] = assetID.uuidString
        graph.nodes[index].backendConfig = config
        // assetRef 输出互斥：挂载视频 → 输出端口唯一化为 text+video（回收 image 端口与旧连线）
        applyAssetRefKindPorts(nodeID: node.id)
        noteGraphChanged()
        statusMessage = "已加载视频到画布：" + (name ?? (path as NSString).lastPathComponent)
        return node
    }

    /// F12-④ 节点结果媒体信息（kind: image/video；path: 本地路径或 URL）
    struct NodeMedia: Equatable {
        let kind: String
        let path: String
    }

    /// 节点图片解码缓存：按路径缓存 NSImage，避免 SwiftUI body 重算时
    /// 反复同步解码大图（卡顿 + 解码内存峰值）。有界：最多 32 张 / 96MB。
    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    /// 读取节点图片：命中缓存直接返回；未命中解码后入缓存（cost 按图片文件大小近似）。
    /// 卡顿专项（P0）：原实现用 NSImage(contentsOfFile:) 在调用线程（SwiftUI body = 主线程）
    /// 同步全分辨率解码大图（4K×3K≈48MB 内存 + 数百 ms 阻塞首帧）。
    /// 现改为 CGImageSource 限幅缩略图解码（最大边 ≤ thumbnailMaxPixel）：
    ///   · 缩略图（92pt）与预览 sheet（≤760pt）共用一次有界解码即可全覆盖，画质无损（都 ≤1024px）；
    ///   · 解码内存峰值与耗时随保留的最大边平方级下降；
    ///   · NSImage 通过 CGImage 构造，避免全图位图载入内存。签名不变。
    func cachedImage(path: String) -> NSImage? {
        let key = path as NSString
        if let hit = Self.imageCache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let thumb = Self.boundedThumbnail(source: source) else { return nil }
        let image = NSImage(cgImage: thumb, size: NSZeroSize)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 1
        Self.imageCache.setObject(image, forKey: key, cost: fileSize)
        return image
    }

    /// 限幅缩略图解码：最大边 ≤ thumbnailMaxPixel，按比例等比缩放，保留 EXIF 方向。
    /// 用 ImageIO 缩略图解码而非全图解码，避免把整张原图位图载入内存（卡顿主因）。
    private static let thumbnailMaxPixel: CGFloat = 1024

    private static func boundedThumbnail(source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 读取节点结果媒体：优先 backendConfig.params[result.path/result.kind]；
    /// 视频节点兜底最近一次执行 outputs["video"]（未回填 params 的场景）。无结果返回 nil。
    func resultMedia(of nodeID: UUID) -> NodeMedia? {
        guard let node = graph.node(id: nodeID) else { return nil }
        if let assetID = node.backendConfig?.params[Self.assetIDKey]
            .flatMap(UUID.init(uuidString:)),
           let asset = assetProjectionByID[assetID],
           let path = asset.localURL ?? asset.remoteURL,
           !path.isEmpty {
            return NodeMedia(
                kind: asset.kind == .video ? "video" : "image",
                path: path
            )
        }
        if let params = node.backendConfig?.params,
           let path = params["result.path"], !path.isEmpty {
            let kind = params["result.kind"] ?? (Self.videoNodeTypes.contains(node.type) ? "video" : "image")
            return NodeMedia(kind: kind, path: path)
        }
        if Self.videoNodeTypes.contains(node.type),
           let video = lastResult?.outputs[nodeID]?["video"] as? String, !video.isEmpty {
            return NodeMedia(kind: "video", path: video)
        }
        return nil
    }

    /// 媒体预览目标节点（非 nil 时 CanvasView 呈现预览 sheet）
    var previewNodeID: UUID?

    /// M6 资产预览区：是否展示（工具栏开关驱动；集中预览生成/导入素材）
    var assetPanelPresented = false

    /// F12-④ 点击缩略图预览：有结果（图片/视频）才弹出预览 sheet；无结果 no-op 返回 false
    @discardableResult
    func presentPreview(for nodeID: UUID) -> Bool {
        guard resultMedia(of: nodeID) != nil else { return false }
        selectNode(id: nodeID)
        previewNodeID = nodeID
        noteGraphChanged()
        return true
    }

    func closePreview() {
        previewNodeID = nil
        noteGraphChanged()
    }

    // MARK: - AJ-19/20 参考图上限 + 动态端口（按节点类型，参照 ComfyUI 动态输入槽）

    /// 节点现有参考图输入端口（dataType == "image" 的输入端口，即 image/image1/image2/…）。
    /// 基础 `image` 为 U-2 图生图入口，动态新增为 image1/image2/…。
    static func referenceImagePorts(of node: CanvasNode) -> [CanvasCore.Port] {
        node.inputs.filter { $0.dataType == "image" }
    }

    /// 动态添加一张参考图输入端口（image1/image2/…），按节点类型上限约束
    /// （imageGen 4 / videoGen 1；ComfyUI 端口随参考图数量动态加）。
    /// 返回是否成功；失败场景：节点不存在 / 类型不支持参考图 / 已达上限。
    @discardableResult
    func addReferenceImage(nodeID: UUID) -> Bool {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
        let node = graph.nodes[index]
        let maxRefs = NodeTypeRegistry.spec(for: node.type)?.maxReferenceImages ?? 0
        guard maxRefs > 0 else {
            statusMessage = "该节点类型不支持参考图"
            return false
        }
        let refs = Self.referenceImagePorts(of: node)
        guard refs.count < maxRefs else {
            statusMessage = "参考图已达上限（\(maxRefs) 张）"
            return false
        }
        let nextName = refs.count == 0 ? "image" : "image\(refs.count)"
        pushUndoState()
        graph.nodes[index].inputs.append(
            CanvasCore.Port(name: nextName, direction: .input, dataType: "image")
        )
        noteGraphChanged()
        statusMessage = "已添加参考图端口 \(nextName)（\(refs.count + 1)/\(maxRefs)）"
        return true
    }

    /// 动态移除节点最后一张参考图输入端口（仅移除动态新增的 image1/image2/…，保留基础
    /// `image` 图生图入口；同时断开该端口连线）。ComfyUI 端口随数量减少动态减。
    /// 无可移除的动态参考图端口返回 false。
    @discardableResult
    func removeReferenceImage(nodeID: UUID) -> Bool {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
        let extras = graph.nodes[index].inputs.enumerated().filter {
            $0.element.dataType == "image" && $0.element.name != "image"
        }
        guard let last = extras.last else { return false }
        pushUndoState()
        graph.edges.removeAll { $0.toNode == nodeID && $0.toPort == last.element.id }
        graph.nodes[index].inputs.remove(at: last.offset)
        noteGraphChanged()
        statusMessage = "已移除参考图端口 \(last.element.name)"
        return true
    }

    // MARK: - B1 审核节点三态（手动放行/打回 → params["review.status"]）

    /// 读取节点审核状态（未设置 / 未知值 → `.pending` 待审）
    func reviewStatus(of nodeID: UUID) -> ReviewStatus {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return .pending }
        return ReviewStatus.fromParams(graph.nodes[index].backendConfig?.params)
    }

    /// 设置审核节点审核状态（手动放行/打回）：
    /// 写 `backendConfig.params[Self.reviewStatusKey]` 为 "PASS"（pass=true）或
    /// "REJECT"（pass=false），随后 pushUndoState + noteGraphChanged，
    /// statusMessage = 已放行 / 已打回。节点不存在返回 false。
    /// 契约：审核状态持久化键 = params["review.status"]，值大写 PASS/REJECT/PENDING。
    @discardableResult
    func setReviewStatus(nodeID: UUID, pass: Bool) -> Bool {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
        pushUndoState()
        var config = graph.nodes[index].backendConfig ?? NodeBackendConfig()
        config.params[Self.reviewStatusKey] = pass ? ReviewStatus.pass.rawValue : ReviewStatus.reject.rawValue
        graph.nodes[index].backendConfig = config
        noteGraphChanged()
        statusMessage = pass ? "已放行" : "已打回"
        return true
    }

    // MARK: - P2 分镜锚点（数据契约：params["anchor"] = "x,y"，归一化 0...1）

    /// 读取节点锚点（未设置/非法 → nil）。任意节点类型可用；
    /// 语义 = 镜头画面内归一化构图参考点（画布标记可视化 + 导出随行）。
    func anchor(of nodeID: UUID) -> StoryboardAnchor? {
        guard let node = graph.node(id: nodeID) else { return nil }
        return StoryboardAnchor.parse(node.backendConfig?.params[Self.anchorKey])
    }

    /// 设置/清除节点锚点（菜单入口与拖拽结束提交共用）：
    /// 写 `backendConfig.params[Self.anchorKey]` = "x,y"（nil → 移除键），
    /// 随后 pushUndoState + noteGraphChanged。节点不存在返回 false。
    /// 契约：锚点随 backendConfig 一起被 CanvasDraft 持久化（草稿 round-trip 测试守护）。
    @discardableResult
    func setAnchor(_ anchor: StoryboardAnchor?, for nodeID: UUID) -> Bool {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
        pushUndoState()
        var config = graph.nodes[index].backendConfig ?? NodeBackendConfig()
        if let anchor {
            config.params[Self.anchorKey] = anchor.clamped().encoded()
        } else {
            config.params.removeValue(forKey: Self.anchorKey)
        }
        graph.nodes[index].backendConfig = config
        noteGraphChanged()
        if let anchor {
            statusMessage = String(format: "已设置锚点 (%.2f, %.2f)", anchor.x, anchor.y)
        } else {
            statusMessage = "已清除锚点"
        }
        return true
    }

    /// 拖拽微调实时写回（轻量：仅改 params，不 pushUndoState / 不触发草稿落盘，
    /// 保证拖动跟手零卡顿）。拖拽结束由 setAnchor 提交（undo + 落盘 + 状态提示）。
    /// 若拖拽被系统取消未走 onEnded，内存值保留，下次任何图变更落盘时一并持久化。
    func setAnchorLive(_ anchor: StoryboardAnchor, for nodeID: UUID) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var config = graph.nodes[index].backendConfig ?? NodeBackendConfig()
        config.params[Self.anchorKey] = anchor.clamped().encoded()
        graph.nodes[index].backendConfig = config
    }

    // MARK: - B2 动态多输入端口（用户定案：默认 1 个输入节点，拉线占用后自动长出下一个，最多 10 个）

    /// 节点某 dataType 的动态输入端口（qcCheck=image / videoGen=video；含基础端口）。
    static func dynamicPorts(of node: CanvasNode, dataType: String) -> [CanvasCore.Port] {
        node.inputs.filter { $0.dataType == dataType }
    }

    /// 连线成功后自动长出下一个同类型输入端口（ComfyUI 动态输入槽语义）：
    /// 目标节点支持动态多输入（qcCheck/videoGen）且刚连接的端口是**最后一个**该类型端口
    /// （已被占用）→ 追加 `dataType + 序号`（image1/video1/…），直到上限 10。
    /// 返回是否长出。
    @discardableResult
    func ensureDynamicInputPort(toNode: UUID, toPort: UUID) -> Bool {
        guard let index = graph.nodes.firstIndex(where: { $0.id == toNode }) else { return false }
        let node = graph.nodes[index]
        guard let connectedPort = node.inputs.first(where: { $0.id == toPort }) else { return false }
        // 按已连端口的 dataType 匹配配置（videoGen 连 video 端口长 video 槽、连 image 端口长 image 槽）
        guard let config = ManjuNodeType.dynamicInputConfig(for: node.type, dataType: connectedPort.dataType) else { return false }
        let ports = Self.dynamicPorts(of: node, dataType: config.dataType)
        // 只在实际连接的是最后一个空槽时生长（避免占用中间槽也长）
        guard let last = ports.last, last.id == toPort else { return false }
        guard ports.count < config.max else { return false }
        let nextName = "\(config.dataType)\(ports.count)"
        pushUndoState()
        graph.nodes[index].inputs.append(
            CanvasCore.Port(name: nextName, direction: .input, dataType: config.dataType)
        )
        noteGraphChanged()
        statusMessage = "已长出输入端口 \(nextName)（\(ports.count + 1)/\(config.max)）"
        return true
    }

    /// 断开连线/删除节点后回收尾部空槽（保持「端口数 = 占用数 + 1」不变量）：
    /// 从尾部移除无入边的动态端口（基础端口与有入边的端口保留），避免空槽堆积。
    /// 返回移除数量。
    @discardableResult
    func recycleDynamicPorts(nodeID: UUID) -> Int {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return 0 }
        let node = graph.nodes[index]
        var removed = 0
        var changed = false
        var inputs = node.inputs
        // 从后往前：跳过有入边的端口；无入边且不是基础端口（序号 > 0）→ 移除
        // 逐端口按其 dataType 查配置（videoGen 的 image/video 两类动态端口各自回收）
        for i in stride(from: inputs.count - 1, through: 0, by: -1) {
            let port = inputs[i]
            guard let config = ManjuNodeType.dynamicInputConfig(for: node.type, dataType: port.dataType) else { continue }
            // 基础端口（dataType 名，无数字后缀）保留
            if port.name == config.dataType { continue }
            let hasEdge = graph.edges.contains { $0.toNode == nodeID && $0.toPort == port.id }
            if hasEdge { continue }
            inputs.remove(at: i)
            removed += 1
            changed = true
        }
        if changed {
            pushUndoState()
            graph.nodes[index].inputs = inputs
            noteGraphChanged()
        }
        return removed
    }

    /// F12-⑤ 复制指定节点（右键「复制」入口；等价选中后 ⌘C）
    @discardableResult
    func copyNode(id: UUID) -> Bool {
        copySubgraph(nodeIDs: [id])
    }

    /// F12-⑤ 粘贴到指定节点旁（右键「粘贴」入口）：新 UUID + 右下偏移避免完全重叠。
    /// 贴着原节点放、内容本就可见 → 不触发 reveal 视口平移（避免用户视野被拉走）。
    @discardableResult
    func pasteNode(near nodeID: UUID) -> [CanvasNode] {
        guard let node = graph.node(id: nodeID) else { return paste() }
        return paste(at: Point(x: node.position.x + 40, y: node.position.y + 40), reveal: false)
    }

    /// F12-⑥ 右键「添加节点」菜单条目：NodeTypeRegistry.creatableSpecs 按面板分组（组内保持注册顺序）。
    /// Phase B：菜单保留（用户明确要求），条目随 registry 瘦身为 7 类生成类节点。
    func addNodeMenuGroups() -> [(group: NodePaletteGroup, specs: [NodeTypeSpec])] {
        NodePaletteGroup.allCases.compactMap { group in
            let specs = NodeTypeRegistry.creatableSpecs.filter { $0.group == group }
            return specs.isEmpty ? nil : (group, specs)
        }
    }

    // MARK: - F12-①/② 卡片内联编辑态（重命名 / 文本内容）

    /// F12-① 重命名中的节点（非 nil 时 NodeView 标题显示 TextField 内联编辑）
    var renamingNodeID: UUID?
    /// AJ-21：重命名中的分组（非 nil 时 CanvasGroupView 标题栏显示 TextField 内联编辑）
    var renamingGroupID: UUID?
    /// F12-② 卡片内联文本编辑中的节点（非 nil 时文本面板显示 TextEditor）
    var editingContentNodeID: UUID?
    /// A2 右侧文本编辑面板：非 nil 时画布右侧显示大编辑区（画布里太小，选中文本节点即弹）
    var textInspectorNodeID: UUID? {
        didSet {
            // P2 互斥（issues/p2_storyboard_interaction_20260805.md ①）：文本面板打开时收起分镜表，
            // 消除两个右侧悬浮面板同侧叠盖（旧实现工作台 zIndex 31 压文本面板 30）。
            // 冲突面评估：分镜表行节点类型（storyboard/videoPrompt/imageGen/videoGen/
            // reviewGate/qcCheck/assetRef）均不属于 textNodeTypes（text/novelImport/blenderPreview），
            // selectRow 的 selectNode 不会触发本 didSet 误关工作台。
            if textInspectorNodeID != nil { showStoryboardWorkbench = false }
        }
    }
    /// P2 分镜表工作台显隐（工具栏「分镜表」按钮/分镜节点双击打开；纯 UI 状态，无业务逻辑）
    var showStoryboardWorkbench = false {
        didSet {
            // P2 互斥：打开分镜表时收起右侧文本面板（工作台为生产中枢，文本面板让位）
            if showStoryboardWorkbench { textInspectorNodeID = nil }
        }
    }
    /// P2 分镜表工作台选中锚点节点（双击分镜节点/右键菜单打开时 = 该节点 id；行单击 =
    /// row.nodeIDs 首个锚点 id）。⚠️ 不能存 StoryboardRow.id——聚合每次重建行、id 随机生成，
    /// 跨渲染失配；锚点节点 id 在图内稳定，渲染侧反查 nodeIDs 命中当前聚合行。
    var storyboardSelectedNodeID: UUID?
    /// A3 右侧面板尺寸（用户可拖右下角手柄调整，持久化到 UserDefaults）
    var textInspectorWidth: Double = 360 {
        didSet { preferencesDefaults.set(textInspectorWidth, forKey: "canvas.textInspectorWidth") }
    }
    var textInspectorHeight: Double = 420 {
        didSet { preferencesDefaults.set(textInspectorHeight, forKey: "canvas.textInspectorHeight") }
    }
    /// A3 画布内文本节点下挂面板高度覆盖（用户拖拽拉高方便阅读；默认用 NodeMetrics.textPanelHeight）
    private var textPanelHeightOverrides: [UUID: Double] = [:]
    func textPanelHeight(for nodeID: UUID) -> Double {
        textPanelHeightOverrides[nodeID] ?? NodeMetrics.textPanelHeight
    }
    /// 拖拽调整文本面板高度（下限 56 = 默认，上限 320 便于长文本阅读）
    func setTextPanelHeight(_ height: Double, for nodeID: UUID) {
        textPanelHeightOverrides[nodeID] = max(56, min(320, height))
    }

    /// A2 选中文本节点 → 右侧面板跟随显示（选中切换时由渲染层调用）
    func syncTextInspector(with nodeID: UUID?) {
        guard let nodeID else {
            textInspectorNodeID = nil
            return
        }
        guard let node = graph.node(id: nodeID),
              Self.contentKind(of: node.type) == .text else {
            textInspectorNodeID = nil
            return
        }
        textInspectorNodeID = nodeID
    }

    func closeTextInspector() {
        textInspectorNodeID = nil
    }

    /// 进入标题重命名态（双击标题 / 右键「重命名」）
    func beginRename(id: UUID) {
        guard graph.node(id: id) != nil else { return }
        renamingNodeID = id
    }

    func endRename() {
        renamingNodeID = nil
    }

    /// 进入文本内容内联编辑态（点击卡片文本区；仅文本类节点）
    func beginInlineContentEdit(nodeID: UUID) {
        guard let node = graph.node(id: nodeID),
              Self.contentKind(of: node.type) == .text else { return }
        selectNode(id: nodeID)
        // L2（batch-B 第 3 条）根因修复：内联编辑与右侧文本面板互斥——右侧面板
        // NodeTextInspectorView onAppear 会自动抢焦点，卡片 TextEditor 聚焦后随即失焦，
        // 触发失焦提交并退出编辑态（用户实测「单击没反应/焦点被抢」）。进入卡片内联
        // 编辑时关掉右侧面板，让卡片 TextEditor 独占焦点；右侧面板仍由下次 selectNode
        // 的正常路径（非内联编辑入口）重新打开。
        textInspectorNodeID = nil
        editingContentNodeID = nodeID
    }

    func endInlineContentEdit() {
        editingContentNodeID = nil
    }

    // MARK: - P2 分镜表工作台入口（设计文档 issues/p2_storyboard_design_20260805.md §5.1）

    /// 分镜节点类型标识（ManjuNodeType.storyboard 的 rawValue，独立常量便于单测/复用）
    static let storyboardNodeType = ManjuNodeType.storyboard.rawValue

    /// 双击分镜节点是否应打开分镜表工作台（纯函数，可单测）：
    /// 仅 storyboard 类型为 true；其余节点类型（文本/生成/审核等）维持原双击行为（内容编辑）。
    static func shouldOpenWorkbench(nodeType: String) -> Bool {
        nodeType == storyboardNodeType
    }

    /// 分镜节点 → 所在分镜行反查（StoryboardAggregator 实时聚合；nodeIDs 含该节点即命中。
    /// 未展开分镜节点：split 切分后每行 nodeIDs = [该节点]，同样命中）。
    func storyboardRow(for nodeID: UUID) -> StoryboardRow? {
        storyboardTable.rows.first { $0.nodeIDs.contains(nodeID) }
    }

    /// Canonical storyboard projection. Legacy result.* is only consulted by
    /// CanvasCore when no matching asset fact exists.
    var storyboardTable: StoryboardTable {
        StoryboardAggregator.aggregate(
            graph: graph,
            mediaAssets: Array(assetProjectionByID.values)
        )
    }

    /// 打开分镜表工作台并定位到该分镜节点（入口1 双击 / 入口3 右键菜单共用）：
    /// 面板弹出 + 选中该节点（画布选中态 → 工作台左列表按 nodeIDs 反向高亮对应行）+
    /// 记录选中锚点（渲染侧反查该节点所在分镜行，右详情展示该镜）+ reveal 视口定位。
    /// - Returns: 是否成功打开（非分镜节点 / 节点不存在 → false，不改任何状态）。
    @discardableResult
    func openStoryboardWorkbench(for nodeID: UUID) -> Bool {
        guard let node = graph.node(id: nodeID),
              Self.shouldOpenWorkbench(nodeType: node.type) else { return false }
        showStoryboardWorkbench = true
        selectNode(id: nodeID)
        storyboardSelectedNodeID = nodeID
        revealRequest = RevealRequest(center: node.position, token: UUID())
        return true
    }

    /// 关闭分镜表工作台（面板关闭同时清空选中行，避免下次打开残留旧行高亮）
    func closeStoryboardWorkbench() {
        showStoryboardWorkbench = false
        storyboardSelectedNodeID = nil
    }

    // MARK: - P2 分镜表交互（可测纯函数）

    /// P2：节点组世界坐标包围盒中心（min/max 中点）——分镜表行 reveal 定位锚点
    /// （issues/p2_storyboard_interaction_20260805.md ②）。
    /// 语义与粘贴 reveal（paste 内联算法）一致：单节点 → 退化为节点自身 position；
    /// 空组/节点全部缺失 → nil（调用方跳过 reveal）。纯函数，可单测。
    static func boundingBoxCenter(of nodeIDs: [UUID], in graph: NodeGraph) -> Point? {
        let xs = nodeIDs.compactMap { graph.node(id: $0)?.position.x }
        let ys = nodeIDs.compactMap { graph.node(id: $0)?.position.y }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        return Point(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    // MARK: - P1 分镜批量展开（一集几十镜：一键把分镜节点内容切成 N 个分镜节点）

    /// 批量展开分镜：读取分镜节点内容 → ManjuStoryboardSplitter 切分为 N 段 →
    /// 原节点替换为 N 个分镜节点（纵向排列，内容写入各节点 params[content]），
    /// 原入/出边按端口名迁移到第一个分镜节点（主链与用户支线不丢）。
    ///
    /// - Returns: 展开段数；节点非分镜/内容不足 2 段返回原样（0 或 1，不改图）。
    @discardableResult
    func expandStoryboard(nodeID: UUID) -> Int {
        guard let node = graph.node(id: nodeID),
              node.type == ManjuNodeType.storyboard.rawValue else { return 0 }
        let segments = ManjuStoryboardSplitter.split(script: content(of: nodeID))
        guard segments.count > 1 else { return segments.count }

        pushUndoState()
        let base = node.position
        let incoming = graph.edges.filter { $0.toNode == nodeID }
        let outgoing = graph.edges.filter { $0.fromNode == nodeID }
        graph.removeNode(id: nodeID)

        // 新建 N 个分镜节点：端口结构复制原节点（端口名一致，便于边迁移），内容写入
        var newNodeIDs: [UUID] = []
        for (index, segment) in segments.enumerated() {
            var config = node.backendConfig ?? NodeBackendConfig()
            config.params[Self.nodeContentKey] = segment
            let newNode = CanvasNode(
                type: ManjuNodeType.storyboard.rawValue,
                title: "分镜\(index + 1)",
                position: Point(x: base.x, y: base.y + Double(index) * 160),
                inputs: node.inputs.map { Port(name: $0.name, direction: .input, dataType: $0.dataType) },
                outputs: node.outputs.map { Port(name: $0.name, direction: .output, dataType: $0.dataType) },
                backendConfig: config
            )
            graph.addNode(newNode)
            newNodeIDs.append(newNode.id)
        }

        // 原入/出边迁移到第一个分镜节点（按端口名匹配新节点端口 id）
        if let first = graph.node(id: newNodeIDs[0]) {
            for edge in incoming {
                guard let portName = node.inputs.first(where: { $0.id == edge.toPort })?.name,
                      let newPort = first.inputs.first(where: { $0.name == portName }) else { continue }
                graph.addEdge(Edge(fromNode: edge.fromNode, fromPort: edge.fromPort,
                                   toNode: first.id, toPort: newPort.id))
            }
            for edge in outgoing {
                guard let portName = node.outputs.first(where: { $0.id == edge.fromPort })?.name,
                      let newPort = first.outputs.first(where: { $0.name == portName }) else { continue }
                graph.addEdge(Edge(fromNode: first.id, fromPort: newPort.id,
                                   toNode: edge.toNode, toPort: edge.toPort))
            }
        }

        noteGraphChanged()
        selectedNodeID = newNodeIDs[0]
        statusMessage = "已批量展开为 \(segments.count) 个分镜节点"
        return segments.count
    }

    /// 删除节点（单删入口：右键 / 接口）。压入撤销快照。
    func removeNode(id: UUID) {
        removeNode(id: id, pushUndo: true)
    }

    /// 删除节点的内部实现。`pushUndo` 控制是否压入撤销快照：
    /// 单删（右键/接口）压入；批量删除（deleteSelected）由调用方一次性压一个快照，
    /// 避免 N 个节点产生 N 个撤销步 → ⌘Z 一次撤销整批。
    private func removeNode(id: UUID, pushUndo: Bool) {
        if pushUndo { pushUndoState() }
        let title = graph.node(id: id)?.title ?? "节点"
        graph.removeNode(id: id)
        noteGraphChanged()
        // AJ-21：清理节点在分组中的成员记录
        for index in groups.indices where groups[index].nodeIDs.contains(id) {
            groups[index].nodeIDs.remove(id)
        }
        if edgeTarget?.nodeID == id { edgeTarget = nil }
        if contentEditorNodeID == id { contentEditorNodeID = nil }
        // F12：删除节点时清理其内联编辑/预览状态
        if renamingNodeID == id { renamingNodeID = nil }
        if editingContentNodeID == id { editingContentNodeID = nil }
        if previewNodeID == id { previewNodeID = nil }
        // A2：删除节点时关闭右侧文本面板（若正编辑该节点）
        if textInspectorNodeID == id { textInspectorNodeID = nil }
        if selectedNodeIDs.contains(id) {
            selectedNodeIDs.remove(id)
            selectionOrder.removeAll { $0 == id }
            if selectedNodeIDs.isEmpty {
                lastSelectionEventID = nil
                onEvent?(.selectionCleared)
            }
        }
        // U2-r：删除节点时清理其节点对话历史
        nodeChat.removeHistory(nodeID: id)
        statusMessage = "已删除节点"
        onEvent?(.nodeRemoved(title: title))
    }

    func deselectAll() {
        // A2：取消选中 → 关闭右侧文本面板
        textInspectorNodeID = nil
        // B4：取消节点选中同时清除组选中（单击空白隐藏缩放手柄）
        selectedGroupID = nil
        if selectedNodeID != nil || pendingEdge != nil {
            selectedNodeID = nil
            selectedNodeIDs.removeAll()
            pendingEdge = nil
            edgeTarget = nil
            onEvent?(.selectionCleared)
        } else {
            selectedNodeID = nil
            selectedNodeIDs.removeAll()
            pendingEdge = nil
            edgeTarget = nil
        }
        noteGraphChanged()
    }

    /// 点击画布节点：记录选中态并广播节点上下文（同一节点重复点击不重复广播）。
    /// AJ-12：单击 = 单选（清空其他选中）；Shift+点击走 toggleSelectNode 累积成多选。
    func selectNode(id: UUID) {
        guard graph.node(id: id) != nil else { return }
        // B4：选中节点 → 取消组选中（组缩放手柄只在「仅选中组」时显示）
        selectedGroupID = nil
        selectedNodeIDs = [id]
        selectionOrder = [id]
        // A2：选中文本节点 → 右侧大编辑面板跟随显示（画布里太小，右侧编辑方便阅读）
        syncTextInspector(with: id)
        noteGraphChanged()
        guard let node = graph.node(id: id) else { return }
        if lastSelectionEventID == id { return }
        lastSelectionEventID = id
        onEvent?(.nodeSelected(
            title: node.title, type: node.type, status: node.status,
            modelID: node.backendConfig?.modelID,
            inputCount: node.inputs.count, outputCount: node.outputs.count
        ))
    }

    // MARK: - AJ-12 多选 / 全选 / 框选

    /// Shift+点击：切换节点选中态（已在集合则移除，否则加入；其余选中保持不变）。
    /// 清空到空选择时广播 selectionCleared（聊天上下文同步）。
    func toggleSelectNode(id: UUID) {
        guard graph.node(id: id) != nil else { return }
        // B4：节点多选切换时同步取消组选中
        selectedGroupID = nil
        if selectedNodeIDs.contains(id) {
            selectedNodeIDs.remove(id)
            selectionOrder.removeAll { $0 == id }
            if selectedNodeIDs.isEmpty {
                lastSelectionEventID = nil
                onEvent?(.selectionCleared)
            }
        } else {
            selectedNodeIDs.insert(id)
            selectionOrder.append(id)
        }
        noteGraphChanged()
    }

    /// ⌘A 全选：选中画布全部可见节点（折叠分组内的隐形节点排除——不可见即不参与全选）。
    func selectAllNodes() {
        let hidden = collapsedHiddenNodeIDs()
        // B4：全选节点 → 取消组选中
        selectedGroupID = nil
        let ids = graph.nodes.map(\.id).filter { !hidden.contains($0) }
        selectedNodeIDs = Set(ids)
        selectionOrder = ids
        noteGraphChanged()
    }

    /// 框选：把当前选中替换为给定节点集合（空集合 = 取消选择）。
    func selectNodes(_ ids: Set<UUID>) {
        let valid = ids.filter { graph.node(id: $0) != nil }
        // B4：框选节点 → 取消组选中
        selectedGroupID = nil
        selectedNodeIDs = valid
        selectionOrder = Array(valid)
        noteGraphChanged()
        if valid.isEmpty {
            lastSelectionEventID = nil
            onEvent?(.selectionCleared)
        }
    }

    /// 节点世界坐标包围盒（框选命中检测用）。纯函数，可单测。
    /// 节点经 `.position()` 居中渲染，故包围盒 = position ± 半宽/半高。
    static func nodeRect(in node: CanvasNode) -> CGRect {
        let height = NodeMetrics.nodeHeight(inputs: node.inputs.count, outputs: node.outputs.count)
        return CGRect(x: node.position.x - NodeMetrics.nodeWidth / 2,
                      y: node.position.y - height / 2,
                      width: NodeMetrics.nodeWidth, height: height)
    }

    /// 框选命中：返回与选择矩形相交（或包含）的所有节点 id。纯函数，可单测。
    static func nodes(in rect: CGRect, of graph: NodeGraph) -> Set<UUID> {
        var result: Set<UUID> = []
        for node in graph.nodes where nodeRect(in: node).intersects(rect) {
            result.insert(node.id)
        }
        return result
    }

    private var lastSelectionEventID: UUID?

    // MARK: - 模型选择面板（I8：复用 CanvasApp ModelConfigPanelView 交互）

    /// 点击节点 → 选中并弹出模型配置面板（对齐 OpenMinis 手机端交互）
    func presentModelPanel(for nodeID: UUID) {
        selectNode(id: nodeID)
        modelPanelNodeID = nodeID
    }

    func closeModelPanel() {
        modelPanelNodeID = nil
    }

    /// 更新节点级模型配置（面板点选即生效）
    func updateBackendConfig(_ config: NodeBackendConfig, for nodeID: UUID) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        graph.nodes[index].backendConfig = config
        noteGraphChanged()
    }

    /// 返回节点显式配置的画布模型。空白或半配置一律视为未配置。
    func canvasModelSelection(for nodeID: UUID) -> CanvasModelSelection? {
        guard let node = graph.node(id: nodeID),
              Self.independentlyConfiguredModelNodeTypes.contains(node.type),
              let config = node.backendConfig else {
            return nil
        }
        let providerID = config.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = config.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty, !modelID.isEmpty else { return nil }
        return CanvasModelSelection(
            providerType: config.providerType,
            providerID: providerID,
            modelID: modelID
        )
    }

    /// 清空节点模型配置；再次执行前必须为该节点单独选择模型。
    func clearBackendConfig(for nodeID: UUID) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        graph.nodes[index].backendConfig = nil
        noteGraphChanged()
    }

    // MARK: - AJ-12 多选批量改配置

    /// 为所有选中节点批量应用同一模型配置。未选中时 no-op。
    func updateSelectedBackendConfig(_ config: NodeBackendConfig) {
        let ids = selectedNodeIDs.filter { graph.node(id: $0) != nil }
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { continue }
            graph.nodes[index].backendConfig = config
        }
        noteGraphChanged()
        statusMessage = "已更新 \(ids.count) 个节点配置"
    }

    /// 批量清除所有选中节点的模型配置。未选中时 no-op。
    func clearSelectedBackendConfig() {
        let ids = selectedNodeIDs.filter { graph.node(id: $0) != nil }
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { continue }
            graph.nodes[index].backendConfig = nil
        }
        noteGraphChanged()
        statusMessage = "已清除 \(ids.count) 个节点配置"
    }

    // MARK: - U2-r 节点级模型对话（与 agent 对话隔离）
    // 预留：节点×LLM 已前台下线（AJ-74），NodeChatStore 接口保留待后续恢复。

    /// 发送消息到该节点模型：按节点 backendConfig 的 provider/model 调 LLM，
    /// 回复 append 到该节点独立历史（NodeChatStore 内 nodeID 分区）。
    func sendNodeChat(nodeID: UUID, message: String) async {
        let backend = graph.node(id: nodeID)?.backendConfig
        await nodeChat.sendNodeChat(nodeID: nodeID, message: message, backend: backend)
    }

    /// 清空该节点对话历史
    func clearNodeChat(nodeID: UUID) {
        nodeChat.clearHistory(nodeID: nodeID)
    }

    // MARK: - 节点内容编辑（E15：双击弹内容编辑器 + setContent 写回）

    /// 读取节点内容（无内容返回空串）。
    /// 存储与 E16 对话驱动调整共用：`backendConfig.params[CanvasStore.nodeContentKey]`，
    /// 双击编辑器与聊天指令（改/设置/导入小说）读写同一份内容，互不覆盖。
    func content(of nodeID: UUID) -> String {
        nodeContent(id: nodeID) ?? ""
    }

    /// 写入节点内容（setContent 写回；不存在的节点安全忽略）
    func setContent(nodeID: UUID, content: String) {
        guard updateNodeContent(content, for: nodeID) else { return }
        statusMessage = "已保存节点内容"
    }

    /// 双击节点 / 点击编辑按钮 → 选中并弹出内容编辑面板
    func presentContentEditor(for nodeID: UUID) {
        selectNode(id: nodeID)
        contentEditorNodeID = nodeID
    }

    func closeContentEditor() {
        contentEditorNodeID = nil
    }

    /// 按标题关键字查找节点（聊天指令连线/删除用）
    func node(matchingTitle keyword: String) -> CanvasNode? {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return nil }
        return graph.nodes.first { $0.title.lowercased().contains(k.lowercased()) }
    }

    // MARK: - 节点内容（E16 对话驱动调整：写 backendConfig.params[Self.nodeContentKey]，单一事实来源）

    /// 读取节点内容（未设置返回 nil）
    func nodeContent(id: UUID) -> String? {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return nil }
        return graph.nodes[index].backendConfig?.params[Self.nodeContentKey]
    }

    /// 写入节点内容（E16：设置/导入/Agent 调整共用；写 params[Self.nodeContentKey]，
    /// 与双击内容编辑器互通；返回是否成功）
    @discardableResult
    func updateNodeContent(_ content: String, for nodeID: UUID) -> Bool {
        guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
        var config = graph.nodes[index].backendConfig ?? NodeBackendConfig()
        config.params[Self.nodeContentKey] = content
        graph.nodes[index].backendConfig = config
        noteGraphChanged()
        return true
    }

    /// 查找小说节点（类型 novelImport 或标题含「小说」）；无则 nil
    func novelNode() -> CanvasNode? {
        graph.nodes.first {
            $0.type == ManjuNodeType.novelImport.rawValue || $0.title.contains("小说")
        }
    }

    // MARK: - 连线操作

    func beginEdge(from nodeID: UUID, portID: UUID, at point: Point) {
        pendingEdge = PendingEdge(fromNode: nodeID, fromPort: portID, end: point)
        edgeTarget = nil
        edgeTargetValid = true
    }

    func updateEdgeEnd(_ point: Point) {
        guard let pending = pendingEdge else { return }
        pendingEdge?.end = point
        // E17：拖拽中实时计算吸附目标（LiteGraph：松手前高亮可连接口）
        edgeTarget = nearestPort(to: point, excluding: pending.fromNode,
                                 direction: dragTargetDirection(fromPort: pending.fromPort,
                                                                on: pending.fromNode))
        // C2-1：目标合法性实时判定（类型匹配 → 绿，非法 → 红）
        if let target = edgeTarget {
            edgeTargetValid = canConnect(fromNode: pending.fromNode, fromPort: pending.fromPort,
                                         toNode: target.nodeID, toPort: target.portID)
        } else {
            edgeTargetValid = true
        }
    }

    /// 结束拖拽连线：落在目标端口附近则创建 Edge（方向规范化为 output → input，同 LiteGraph connect）
    func endEdge(at point: Point) {
        defer {
            pendingEdge = nil
            edgeTarget = nil
            edgeTargetValid = true
        }
        guard let pending = pendingEdge else { return }
        let direction = dragTargetDirection(fromPort: pending.fromPort, on: pending.fromNode)
        // 优先用拖拽中实时吸附的目标；onEnded 未带最后一次 onChanged 时兜底重扫
        let target = edgeTarget ?? nearestPort(to: point, excluding: pending.fromNode,
                                               direction: direction)
        guard let target else { return }
        let fromNode: UUID, fromPort: UUID, toNode: UUID, toPort: UUID
        if direction == .output {
            // 从输入口反向拖到输出口：连线方向规范化为 output → input
            fromNode = target.nodeID; fromPort = target.portID
            toNode = pending.fromNode; toPort = pending.fromPort
        } else {
            fromNode = pending.fromNode; fromPort = pending.fromPort
            toNode = target.nodeID; toPort = target.portID
        }
        // C2-1：落线前强制类型校验，非法拒绝（LiteGraph connectOutput 内部校验同语义）
        guard canConnect(fromNode: fromNode, fromPort: fromPort, toNode: toNode, toPort: toPort) else {
            statusMessage = "类型不匹配：无法连接"
            return
        }
        connect(fromNode: fromNode, fromPort: fromPort, toNode: toNode, toPort: toPort)
    }

    /// 拖拽目标端口方向：从输出口拖 → 找输入口；从输入口拖 → 找输出口
    private func dragTargetDirection(fromPort: UUID, on nodeID: UUID) -> PortDirection {
        guard let fromNode = graph.node(id: nodeID) else { return .input }
        return fromNode.outputs.contains(where: { $0.id == fromPort }) ? .input : .output
    }

    /// 距 point 最近且在吸附阈值内的候选端口（排除起点节点自身）；nil = 无吸附目标
    private func nearestPort(to point: Point, excluding nodeID: UUID,
                             direction: PortDirection) -> (nodeID: UUID, portID: UUID)? {
        let t = Self.edgeSnapTolerance
        // 折叠分组内的隐形端口不可作为连线目标（不可见即不可交互，防拖线连到看不见的端口）
        let hidden = collapsedHiddenNodeIDs()
        var best: (nodeID: UUID, portID: UUID, distanceSq: Double)?
        for node in graph.nodes where node.id != nodeID && !hidden.contains(node.id) {
            let ports = direction == .input ? node.inputs : node.outputs
            for port in ports {
                let anchor = portAnchor(for: node, port: port)
                let dx = anchor.x - point.x
                let dy = anchor.y - point.y
                let d2 = dx * dx + dy * dy
                if d2 <= t * t {
                    if let current = best {
                        if d2 < current.distanceSq { best = (node.id, port.id, d2) }
                    } else {
                        best = (node.id, port.id, d2)
                    }
                }
            }
        }
        return best.map { ($0.nodeID, $0.portID) }
    }

    /// 连线两端画布坐标（EdgeCurve 渲染与测试共用；与 portAnchor 同一坐标语义）
    func edgeEndpoints(_ edge: CanvasCore.Edge) -> (from: Point, to: Point)? {
        guard let fromNode = graph.node(id: edge.fromNode),
              let toNode = graph.node(id: edge.toNode),
              let fromPort = fromNode.outputs.first(where: { $0.id == edge.fromPort }),
              let toPort = toNode.inputs.first(where: { $0.id == edge.toPort }) else { return nil }
        return (portAnchor(for: fromNode, port: fromPort),
                portAnchor(for: toNode, port: toPort))
    }

    /// 直接创建连线（聊天指令 & 拖拽共用）；防重复
    /// C2-1：入口强制类型校验（非法拒绝）+ 输入口单连线语义（已有入边先移除 → 拖动改接）
    @discardableResult
    func connect(fromNode: UUID, fromPort: UUID, toNode: UUID, toPort: UUID) -> Bool {
        // 类型校验拦截（同 LiteGraph connectOutput 内部强制校验）
        guard canConnect(fromNode: fromNode, fromPort: fromPort, toNode: toNode, toPort: toPort) else {
            statusMessage = "类型不匹配：无法连接"
            return false
        }
        let exists = graph.edges.contains {
            $0.fromNode == fromNode && $0.fromPort == fromPort
                && $0.toNode == toNode && $0.toPort == toPort
        }
        guard !exists else { return false }
        // 输入口单连线（ComfyUI/LiteGraph）：新线接入前移除该输入口旧线 → 拖动改接
        pushUndoState()
        graph.edges.removeAll { $0.toNode == toNode && $0.toPort == toPort }
        graph.addEdge(Edge(fromNode: fromNode, fromPort: fromPort, toNode: toNode, toPort: toPort))
        noteGraphChanged()
        let fromTitle = graph.node(id: fromNode)?.title ?? "?"
        let toTitle = graph.node(id: toNode)?.title ?? "?"
        statusMessage = "已连接 \(toTitle)"
        onEvent?(.edgeAdded(fromTitle: fromTitle, toTitle: toTitle))
        // B2 动态多输入：连线成功且占用的是最后一个同类型空槽 → 自动长出下一个
        // （qcCheck=image / videoGen=video，最多 10 个；ComfyUI 动态输入槽语义）
        ensureDynamicInputPort(toNode: toNode, toPort: toPort)
        return true
    }

    /// 智能连线：from 的第一个输出端口 → to 的第一个输入端口（聊天指令用）
    @discardableResult
    func connectNodes(fromID: UUID, toID: UUID) -> Bool {
        guard let from = graph.node(id: fromID),
              let to = graph.node(id: toID),
              let outPort = from.outputs.first else { return false }
        // 按输出类型匹配第一个兼容输入端口（不固定 inputs.first，
        // 因为多输入节点如 qcCheck[image,text,video] 需按 dataType 匹配正确端口）。
        // 目标节点无输入端口（novelImport/assetRef 等）→ 无法连接，安全返回 false（不崩溃）。
        guard let targetPort = to.inputs.first(where: { inPort in
            canConnect(fromNode: fromID, fromPort: outPort.id, toNode: toID, toPort: inPort.id)
        }) ?? to.inputs.first else { return false }
        return connect(fromNode: fromID, fromPort: outPort.id, toNode: toID, toPort: targetPort.id)
    }

    func removeEdges(touching nodeID: UUID) {
        pushUndoState()
        graph.edges.removeAll { $0.fromNode == nodeID || $0.toNode == nodeID }
        noteGraphChanged()
        // B2 动态多输入：断开该节点全部连线后回收尾部空槽（节点被删时内部安全 no-op）
        recycleDynamicPorts(nodeID: nodeID)
    }

    // MARK: - C5 画布编辑效率（学 ComfyUI：搜索面板 / 复制粘贴 / 删除 / 撤销）

    /// 结构变更前压入整图快照（LiteGraph beforeChange 语义；深度受限防膨胀）。
    /// 所有可撤销的结构变更入口（增删节点/连线/粘贴/删除）在改动前调用。
    private func pushUndoState() {
        undoStack.append(graph)
        if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
    }

    /// ⌘Z 撤销：弹出最近一次结构变更前快照并恢复（无历史返回 false）。
    /// 只回滚画布结构（节点/连线），不涉及执行结果与节点内容。
    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoStack.popLast() else {
            statusMessage = "没有可撤销的操作"
            return false
        }
        graph = snapshot
        selectedNodeID = nil
        pendingEdge = nil
        edgeTarget = nil
        noteGraphChanged()
        statusMessage = "已撤销"
        return true
    }

    // MARK: 节点搜索面板（双击空白弹出；ComfyUI showSearchBox 语义）

    /// 双击画布空白：记录世界坐标并弹出搜索面板（回车创建的节点落在此处）
    /// AJ-66 防线：非有限世界坐标（视口污染时 world() 退化产物 / 双击事件异常）→
    /// 保持上次有效位置，绝不让 NaN 进 nodeSearchPosition（回车建节点会落盘）。
    func presentNodeSearch(at world: Point) {
        guard world.x.isFinite, world.y.isFinite else {
            AJ66Diagnostics.logNonFinite(source: "CanvasStore.presentNodeSearch", zoom: 0, pan: .zero,
                                         input: "world=(\(world.x),\(world.y))")
            return
        }
        nodeSearchPosition = world
        isNodeSearchPresented = true
    }

    func dismissNodeSearch() {
        isNodeSearchPresented = false
    }

    /// 按关键词过滤节点类型（空关键词返回全部可新建类型；type/title/summary 模糊匹配，大小写不敏感）。
    /// Phase B：只搜 creatableSpecs（7 类生成类），文本创作类不出现在新建入口。
    /// 纯函数，供面板实时过滤与单测共用。
    func nodeSearchResults(matching keyword: String) -> [NodeTypeSpec] {
        let k = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return NodeTypeRegistry.creatableSpecs }
        return NodeTypeRegistry.creatableSpecs.filter {
            $0.type.lowercased().contains(k)
                || $0.title.lowercased().contains(k)
                || $0.summary.lowercased().contains(k)
        }
    }

    /// 搜索面板回车：在双击位置创建所选类型节点并关闭面板（返回新建节点）
    @discardableResult
    func createNodeFromSearch(type: String) -> CanvasNode? {
        defer { dismissNodeSearch() }
        return addNode(ofType: type, at: nodeSearchPosition)
    }

    // MARK: 复制粘贴（LiteGraph copyToClipboard / pasteFromClipboard）

    /// ⌘C 复制选中节点子图（含子图内部连线，相对 id 映射）。AJ-12：复制全部选中节点。
    @discardableResult
    func copySelection() -> Bool {
        guard !selectedNodeIDs.isEmpty else {
            statusMessage = "未选中节点"
            return false
        }
        return copySubgraph(nodeIDs: selectedNodeIDs)
    }

    /// 复制指定节点子图（当前单选中；测试与后续多选共用）：
    /// 节点 + 两端均在子图内的连线（外部连线不复制，粘贴后按相对 id 重建）。
    @discardableResult
    func copySubgraph(nodeIDs: Set<UUID>) -> Bool {
        let ids = nodeIDs.filter { graph.node(id: $0) != nil }
        guard !ids.isEmpty else {
            statusMessage = "未选中节点"
            return false
        }
        let nodes = graph.nodes.filter { ids.contains($0.id) }
        let internalEdges = graph.edges.filter { ids.contains($0.fromNode) && ids.contains($0.toNode) }
        clipboard = CanvasClipboard(nodes: nodes, edges: internalEdges)
        statusMessage = "已复制 \(nodes.count) 个节点"
        return true
    }

    /// ⌘V 粘贴剪贴板到目标位置（默认 = 上次搜索面板位置）：
    /// 节点/端口全部换新 UUID，子图内部连线按 old→new 相对映射重建（LiteGraph _relative_id 语义）；
    /// 子图左上角平移到目标点；粘贴后选中首个新节点。返回新建节点数组。
    /// - Parameter reveal: 是否发 U-3 揭示请求（⌘V 用 true 自动平移视口到粘贴内容；
    ///   右键「粘贴」贴原节点旁内容本就可见，传 false 避免视野被拉走）。
    @discardableResult
    func paste(at position: Point? = nil, reveal: Bool = true) -> [CanvasNode] {
        guard let clip = clipboard, !clip.nodes.isEmpty else {
            statusMessage = "剪贴板为空"
            return []
        }
        // AJ-66 防线：剪贴板源节点位置全非有限（历史污染数据）→ 整单拒绝，
        // 不产出 NaN 节点、不压无用撤销快照。
        let finiteSources = clip.nodes.filter { $0.position.x.isFinite && $0.position.y.isFinite }
        guard !finiteSources.isEmpty else {
            AJ66Diagnostics.logNonFinite(source: "CanvasStore.paste", zoom: 0, pan: .zero,
                                         input: "clipboard 节点位置全非有限")
            statusMessage = "剪贴板数据异常，无法粘贴"
            return []
        }
        pushUndoState()
        let minX = finiteSources.map(\.position.x).min() ?? 0
        let minY = finiteSources.map(\.position.y).min() ?? 0
        // AJ-66 防御：粘贴落点非有限（视口/鼠标换算异常产生 NaN）→ 退化为固定默认点，
        // 避免 NaN 位置写进节点（一旦落盘，重启恢复的也是 NaN 位置，画布永久不可见）。
        let fallback = Point(x: 400, y: 300)
        let rawTarget = position ?? nodeSearchPosition
        let target: Point = (rawTarget.x.isFinite && rawTarget.y.isFinite) ? rawTarget : fallback
        let dx = target.x - minX
        let dy = target.y - minY
        var idMap: [UUID: UUID] = [:]
        var portMap: [UUID: UUID] = [:]
        var newNodes: [CanvasNode] = []
        for node in clip.nodes {
            // AJ-66 防线：剪贴板中个别 NaN 源节点跳过（不拷贝、不建映射），
            // 防止 NaN 位置经 copyNode 写进新节点（连到被跳过节点的边自然不重建）。
            guard node.position.x.isFinite, node.position.y.isFinite else {
                AJ66Diagnostics.logNonFinite(source: "CanvasStore.paste", zoom: 0, pan: .zero,
                                             input: "node.position=(\(node.position.x),\(node.position.y))")
                continue
            }
            let newID = UUID()
            idMap[node.id] = newID
            newNodes.append(Self.copyNode(node, newID: newID,
                                          offset: Point(x: dx, y: dy), portMap: &portMap))
        }
        var newEdges: [CanvasCore.Edge] = []
        for edge in clip.edges {
            guard let fromNode = idMap[edge.fromNode], let toNode = idMap[edge.toNode],
                  let fromPort = portMap[edge.fromPort], let toPort = portMap[edge.toPort] else { continue }
            newEdges.append(Edge(fromNode: fromNode, fromPort: fromPort,
                                 toNode: toNode, toPort: toPort))
        }
        for node in newNodes {
            graph.addNode(node)
            onEvent?(.nodeAdded(title: node.title, type: node.type))
        }
        for edge in newEdges { graph.addEdge(edge) }
        noteGraphChanged()
        selectedNodeID = newNodes.first?.id
        statusMessage = "已粘贴 \(newNodes.count) 个节点 · \(newEdges.count) 条连线"
        // U-3：粘贴后发揭示请求（粘贴子图 bounding box 中心）——落点可能在用户视口外
        // （默认落点 nodeSearchPosition 是固定世界坐标，平移/缩放后必出屏），
        // 渲染层收到请求后自动平移视口让用户看见粘贴结果。
        let xs = newNodes.map(\.position.x)
        let ys = newNodes.map(\.position.y)
        if reveal, let minX = xs.min(), let maxX = xs.max(),
           let minY = ys.min(), let maxY = ys.max() {
            let center = Point(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            // AJ-66 防线：bbox 中心非有限（极端输入溢出）→ 不发 NaN 揭示请求
            //（resolveReveal 虽会丢弃，但 handleReveal 在布局未就绪时会把它缓存为 pending）
            guard center.x.isFinite, center.y.isFinite else {
                AJ66Diagnostics.logNonFinite(source: "CanvasStore.paste", zoom: 0, pan: .zero,
                                             input: "reveal center=(\(center.x),\(center.y))")
                return newNodes
            }
            revealRequest = RevealRequest(center: center, token: UUID())
        }
        return newNodes
    }

    /// 深拷贝节点：新 node/port UUID、位置按 offset 平移、状态重置 pending（粘贴为全新节点），
    /// 内容/模型配置保留。portMap 记录 old→new 端口映射供连线重建。
    static func copyNode(_ node: CanvasNode, newID: UUID, offset: Point,
                         portMap: inout [UUID: UUID]) -> CanvasNode {
        var inputs: [CanvasCore.Port] = []
        var outputs: [CanvasCore.Port] = []
        for p in node.inputs {
            let np = CanvasCore.Port(name: p.name, direction: p.direction, dataType: p.dataType)
            portMap[p.id] = np.id
            inputs.append(np)
        }
        for p in node.outputs {
            let np = CanvasCore.Port(name: p.name, direction: p.direction, dataType: p.dataType)
            portMap[p.id] = np.id
            outputs.append(np)
        }
        return CanvasNode(
            id: newID, type: node.type, title: node.title,
            position: Point(x: node.position.x + offset.x, y: node.position.y + offset.y),
            inputs: inputs, outputs: outputs, status: .pending,
            backendID: node.backendID, backendConfig: node.backendConfig
        )
    }

    /// ⌘D 删除选中节点（含其全部连线；无选中时提示并返回 false）。AJ-12：删除全部选中节点。
    /// 批量删除一次性压入撤销快照（单个快照代表「删除整个选中集合」），⌘Z 一次撤销整批。
    @discardableResult
    func deleteSelected() -> Bool {
        let ids = selectedNodeIDs.filter { graph.node(id: $0) != nil }
        guard !ids.isEmpty else {
            statusMessage = "未选中节点"
            return false
        }
        pushUndoState()
        for id in ids { removeNode(id: id, pushUndo: false) }
        return true
    }

    // MARK: - C2-1 连线交互升级：类型校验 / 断开 / 删除 / 改接

    /// 端口类型连通性校验（LiteGraph isValidConnection 语义）：
    /// 空类型 / `*` 通配合法；同类型合法；逗号分隔多类型任一匹配；大小写不敏感。
    static func isValidConnection(_ typeA: String, _ typeB: String) -> Bool {
        let a = typeA.trimmingCharacters(in: .whitespaces).lowercased()
        let b = typeB.trimmingCharacters(in: .whitespaces).lowercased()
        if a.isEmpty || b.isEmpty || a == "*" || b == "*" { return true }
        if !a.contains(",") && !b.contains(",") { return a == b }
        let partsA = a.split(separator: ",").map { String($0) }
        let partsB = b.split(separator: ",").map { String($0) }
        if partsA.contains(where: { $0 == "*" || $0.isEmpty }) { return true }
        if partsB.contains(where: { $0 == "*" || $0.isEmpty }) { return true }
        return partsA.contains { partsB.contains($0) }
    }

    /// 指定节点上的端口（输入/输出统一查找）
    func port(_ id: UUID, on nodeID: UUID) -> CanvasCore.Port? {
        guard let node = graph.node(id: nodeID) else { return nil }
        return node.inputs.first(where: { $0.id == id })
            ?? node.outputs.first(where: { $0.id == id })
    }

    /// 两端端口类型是否可连（拖线高亮 + 落线校验共用）
    func canConnect(fromNode: UUID, fromPort: UUID, toNode: UUID, toPort: UUID) -> Bool {
        guard let from = port(fromPort, on: fromNode),
              let to = port(toPort, on: toNode) else { return false }
        guard Self.isValidConnection(from.dataType, to.dataType) else { return false }
        // assetRef 输出互斥：资产要么是图片要么是视频，image/video 输出不可同时被连线。
        // （挂载资产后端口已被唯一化；本守卫兜底「双端口并存」场景：新建未挂载节点 / 旧图数据。）
        if Self.assetRefKindConflict(nodeID: fromNode, portID: fromPort, in: graph)
            || Self.assetRefKindConflict(nodeID: toNode, portID: toPort, in: graph) {
            return false
        }
        return true
    }

    /// assetRef 输出互斥判定：node 是 assetRef 且 port 是其 image/video 输出端口时，
    /// 若对侧媒体输出端口（video/image）已有连线 → 冲突（image 与 video 不得同时连线）。
    /// 返回 false 表示无冲突（允许连线）。
    static func assetRefKindConflict(nodeID: UUID, portID: UUID, in graph: NodeGraph) -> Bool {
        guard let node = graph.node(id: nodeID),
              node.type == ManjuNodeType.assetRef.rawValue,
              let port = node.outputs.first(where: { $0.id == portID }),
              port.dataType == "image" || port.dataType == "video" else { return false }
        let otherType = port.dataType == "image" ? "video" : "image"
        guard let other = node.outputs.first(where: { $0.dataType == otherType }) else { return false }
        return graph.edges.contains { $0.fromNode == nodeID && $0.fromPort == other.id }
    }

    /// 点已连口断开（LiteGraph click_do_break_link_to）：输出口断开出边、输入口断开入边；
    /// 无连线时 no-op 返回 false。
    @discardableResult
    func disconnectPort(nodeID: UUID, portID: UUID) -> Bool {
        guard let node = graph.node(id: nodeID) else { return false }
        let isOutput = node.outputs.contains { $0.id == portID }
        let isInput = node.inputs.contains { $0.id == portID }
        guard isOutput || isInput else { return false }
        pushUndoState()
        let before = graph.edges.count
        if isOutput {
            graph.edges.removeAll { $0.fromNode == nodeID && $0.fromPort == portID }
        } else {
            graph.edges.removeAll { $0.toNode == nodeID && $0.toPort == portID }
        }
        let removed = graph.edges.count < before
        if removed {
            noteGraphChanged()
            statusMessage = "已断开连线"
            // B2 动态多输入：断开输入口后回收尾部空槽（保持「端口数 = 占用数 + 1」不变量）
            if isInput { recycleDynamicPorts(nodeID: nodeID) }
        }
        return removed
    }

    /// 双击连线删除（EdgeCurve 中点双击命中）
    func removeEdge(id: UUID) {
        let toNode = graph.edges.first { $0.id == id }?.toNode
        pushUndoState()
        graph.removeEdge(id: id)
        noteGraphChanged()
        statusMessage = "已删除连线"
        // B2 动态多输入：输入侧连线被删 → 回收该节点尾部空槽
        if let toNode { recycleDynamicPorts(nodeID: toNode) }
    }

    // MARK: - 端口锚点（画布坐标，与节点渲染布局一致）

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
        // E17：node.position 是 SwiftUI .position() 的「中心坐标」语义（N2：渲染层整体
        // scaleEffect 缩放，position 即世界坐标不再乘 zoom），锚点必须按中心偏移：
        // 输出口在右边缘 = center + width/2，输入口在左边缘 = center - width/2。
        // 旧实现用 position.x + width（左上角语义）差 width/2，导致拖线偏左。
        let localX = port.direction == .input ? -width / 2 : width / 2
        // U-1（08-04 用户实测截图）：Y 同样要中心语义。E17 只修了 X 漏了 Y——
        // localY 是「卡片顶边起算」的左上角语义，直接加到中心坐标上导致所有端口锚点
        // 整体下移 nodeHeight/2（连线起点从节点右下爬出、终点悬在附件区下方，拖线命中区同步错位）。
        // NodeView 卡片已定高 nodeHeight（Divider overlay 不占布局），几何与度量严格一致。
        let centerYOffset = localY - NodeMetrics.nodeHeight(inputs: node.inputs.count,
                                                            outputs: node.outputs.count) / 2
        return Point(x: node.position.x + localX, y: node.position.y + centerYOffset)
    }

    // MARK: - 自动布局

    func autoLayout() {
        do {
            let positions = try GraphLayout.layeredLayout(graph: graph)
            for index in graph.nodes.indices {
                if let pos = positions[graph.nodes[index].id] {
                    graph.nodes[index].position = pos
                }
            }
            noteGraphChanged()
            statusMessage = "自动布局完成"
            onEvent?(.layoutDone)
        } catch {
            statusMessage = "自动布局失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 一键漫剧流水线（P2-1：工具栏按钮 / 对话指令 / DeepLink 共用入口）

    /// 一键生成完整漫剧流水线：`ManjuPipelineTemplate.makeManjuPipeline`（12 节点 · 15 连线，
    /// 主链 小说导入→剧情拆解→脚本生成→分镜生成→图片提示词→视频提示词→生图→生视频→QC检查，
    /// 另含 资产引用 + Blender 预演，资产锁定槽位已注入提示词节点），模板自带 GraphLayout 分层布局。
    /// 追加模式：流水线整体右移到已有内容右侧，不覆盖现有节点；返回生成的流水线图（聊天回执用）。
    ///
    /// Phase B 语义（用户拍板）：本按钮只生成节点骨架，不自动执行全部 —— 执行由用户显式
    /// 触发（`执行` 指令 / 工具栏「执行画布」），避免一键误触发全量 Provider 调用。
    @discardableResult
    func createManjuPipeline() -> NodeGraph {
        var pipeline = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        // 追加偏移：已有内容时整体放到右侧（留一列间距）；空画布直接用模板自带布局
        if let maxX = graph.nodes.map(\.position.x).max() {
            let minX = pipeline.nodes.map(\.position.x).min() ?? 120
            let offset = maxX + 280 - minX
            for index in pipeline.nodes.indices {
                pipeline.nodes[index].position.x += offset
            }
        }
        // 默认模型规范化：gimage2 后端默认模型 → gpt-image-2-official（NodeTypeRegistry 徽标约定）
        for index in pipeline.nodes.indices where pipeline.nodes[index].type == ManjuNodeType.imageGen.rawValue {
            if var config = pipeline.nodes[index].backendConfig, config.modelID == "gimage2" {
                config.modelID = "gpt-image-2-official"
                pipeline.nodes[index].backendConfig = config
            }
        }
        for node in pipeline.nodes { graph.addNode(node) }
        for edge in pipeline.edges { graph.addEdge(edge) }
        noteGraphChanged()
        if let first = pipeline.nodes.first(where: { $0.type == ManjuNodeType.novelImport.rawValue })?.id {
            selectedNodeID = first
        }
        statusMessage = "已生成漫剧流水线：\(pipeline.nodes.count) 节点 · \(pipeline.edges.count) 连线"
        return pipeline
    }

    // MARK: AJ-37 工作流模板库：应用预设节点组合到当前画布（非一键流水线）

    /// 把预设模板应用到当前画布：创建节点 + 按端口连线，然后整体右移（已有内容时）。
    /// 模板是**静态骨架**，不自动执行，由用户手动填写内容后显式「执行」。
    /// - Returns: 应用到画布后的模板子图（节点 + 连线）。
    @discardableResult
    func applyTemplate(_ template: CanvasTemplate) -> NodeGraph {
        var result = WorkflowTemplateStore.buildGraph(for: template)
        // AJ-74：节点×LLM 前台下线——一键流水线模板不再产出 llm 节点。
        // 模板定义（WorkflowTemplateStore）保留不动，消费端此处过滤：跳过 llm 节点及其关联连线。
        if result.nodes.contains(where: { $0.type == "llm" }) {
            let retiredIDs = Set(result.nodes.filter { $0.type == "llm" }.map(\.id))
            result.nodes.removeAll { retiredIDs.contains($0.id) }
            result.edges.removeAll { retiredIDs.contains($0.fromNode) || retiredIDs.contains($0.toNode) }
        }
        // 追加偏移：已有内容时整体放到右侧（留一列间距）；空画布直接用模板自带布局
        if let maxX = graph.nodes.map(\.position.x).max() {
            let minX = result.nodes.map(\.position.x).min() ?? 120
            let offset = maxX + 280 - minX
            for index in result.nodes.indices {
                result.nodes[index].position.x += offset
            }
        }
        pushUndoState()
        for node in result.nodes { graph.addNode(node) }
        for edge in result.edges { graph.addEdge(edge) }
        noteGraphChanged()
        if let first = result.nodes.first {
            selectedNodeID = first.id
        }
        statusMessage = "已应用模板「\(template.name)」：\(result.nodes.count) 节点 · \(result.edges.count) 连线"
        onEvent?(.layoutDone)
        return result
    }

    // MARK: - 执行

    /// 与 DAGScheduler 的局部重跑闭包一致：只校验本次会真正执行的根节点及其下游。
    private func executionNodeIDs(from roots: Set<UUID>?) -> Set<UUID> {
        guard let roots else { return Set(graph.nodes.map(\.id)) }
        var closure = roots
        var stack = Array(roots)
        while let current = stack.popLast() {
            for successor in graph.successors(of: current)
            where closure.insert(successor.id).inserted {
                stack.append(successor.id)
            }
        }
        return closure
    }

    /// 找出本次执行范围内首个未显式选择 provider/model 的模型节点。
    private func firstUnconfiguredModelNode(from roots: Set<UUID>?) -> CanvasNode? {
        let executionIDs = executionNodeIDs(from: roots)
        return graph.nodes.first {
            executionIDs.contains($0.id)
                && Self.independentlyConfiguredModelNodeTypes.contains($0.type)
                && canvasModelSelection(for: $0.id) == nil
        }
    }

    /// 跑完整 DAG（C2-2：后台线程同步调度 + 逐节点事件有序回主线程更新进度，
    /// 主线程不阻塞；「停止」按钮置 cancelFlag → 调度器节点间中断，剩余节点跳过）。
    /// P0 局部重跑：`from` 非空时只执行该节点及其下游，上游复用上次执行结果
    /// （lastResult.outputs 作 seed），符合漫剧迭代制作——改一个提示词节点只重跑
    /// 它和下游，不重复烧上游 LLM token。
    func runGraph(from: Set<UUID>? = nil) {
        guard !graph.nodes.isEmpty else {
            statusMessage = "画布为空，请先添加节点"
            return
        }
        guard !isRunning else { return }
        if let node = firstUnconfiguredModelNode(from: from) {
            statusMessage = "节点「\(node.title)」未单独配置模型，请先选择画布模型"
            return
        }
        isRunning = true
        cancelFlag.reset()
        let runID = UUID()
        let executionEnvelope = DAGExecutionEnvelope(
            canvasID: currentCanvasID,
            runID: runID,
            graph: graph
        )
        // P0-1：运行开始时记录信封（canvasID + runID + 图结构版本），
        // 写回前校验防旧结果覆盖当前画布。
        currentRunEnvelope = RunEnvelope(
            runID: runID,
            canvasID: currentCanvasID,
            graphRevision: graph.structuralRevision,
            executionEnvelope: executionEnvelope
        )
        if let envelope = currentRunEnvelope {
            executionScope.begin(
                canvasID: currentCanvasID,
                runID: envelope.runID,
                graphRevision: envelope.graphRevision,
                graphFingerprint: graph.fingerprint
            )
        }
        let total = graph.nodes.count
        executionProgress = ExecutionProgress(value: 0, max: total, currentNodeTitle: nil)
        statusMessage = from == nil ? "执行中…" : "局部重跑中…"
        onEvent?(.runStarted)

        // 快照：图 / 执行上下文 / 调度器盒 / 中断标志在后台线程使用（均 Sendable）
        let snapshot = graph
        let context = self.context
        let box = schedulerBox
        let flag = cancelFlag
        let before = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.status) })

        // F21a（P0-1 断点续跑）：已成功/已缓存的节点不重复执行——
        // 中断或崩溃后重跑只执行剩余节点，避免重复烧 token/扣费。
        // DAGScheduler 对 resumeFrom 集合内节点：有缓存→.cached+nodeCached 事件，
        // 无缓存→直接 .succeeded，下游正常执行。
        // P0 局部重跑：resumeFrom 与 from 互斥——局部重跑时已成功节点不在 from
        // 下游则天然不执行；在 from 下游的（输入已变）必须重跑，不能按旧状态跳过。
        let resumeSet = from == nil
            ? Set(graph.nodes
                .filter { $0.status == .succeeded || $0.status == .cached }
                .map(\.id))
            : []
        // P0：局部重跑 seed = 上次执行结果输出（上游恢复用；无则空）
        // SeedBox 包装：AnyHashable 非 Sendable，经 @unchecked Sendable 盒跨任务传递
        let seed = SeedBox(lastResult?.outputs ?? [:])

        Task.detached(priority: .userInitiated) {
            do {
                let result = try box.run(
                    graph: snapshot,
                    context: context,
                    resumeFrom: resumeSet,
                    from: from,
                    seedOutputs: seed.value,
                    executionEnvelope: executionEnvelope,
                    onEvent: { event in
                        // 卡顿专项（P0）：事件异步投递主线程而非 DispatchQueue.main.sync——
                        // sync 会让后台调度线程每投一个事件就同步阻塞等主线程跑完 handleExecutionEvent
                        // （内部 setNodeStatus 改图 → @Observable 触发重绘，再排队 flush），
                        // 事件密集时后台线程被逐个事件卡死、UI 逐事件强制刷新。
                        // 改 async 后主队列 FIFO 仍保序，且同一 runloop tick 内的多个事件被 SwiftUI
                        // 合并为一次呈现刷新，显著降低主线程逐事件阻塞与高频重绘。
                        Task { @MainActor in
                            self.handleExecutionEvent(event, total: total)
                        }
                    },
                    isCancelled: { flag.isCancelled }
                )
                await MainActor.run { self.finishRun(result, before: before) }
            } catch {
                await MainActor.run {
                    guard self.isRunning else { return }
                    self.statusMessage = "执行失败：\(error.localizedDescription)"
                    self.onEvent?(.runFinished(summary: "执行失败：\(error.localizedDescription)"))
                    self.isRunning = false
                    self.executionProgress = nil
                    self.currentRunEnvelope = nil
                    self.executionScope.end()
                }
            }
        }
    }

    /// 逐节点事件 → 执行进度（主线程；由后台调度线程有序投递）
    private func handleExecutionEvent(_ event: DAGExecutionEvent, total: Int) {
        guard isRunning else { return }
        var progress = executionProgress
            ?? ExecutionProgress(value: 0, max: total, currentNodeTitle: nil)
        switch event {
        case .nodeStarted(let id):
            progress.currentNodeTitle = graph.node(id: id)?.title
            setNodeStatus(id, .running)   // F21a：状态即时可见
        case .nodeFinished(let id):
            progress.value += 1
            progress.currentNodeTitle = nil
            // F21a（P0-1）：节点完成即增量写回状态 + 防抖落盘——
            // kill/崩溃后重启可凭图内状态断点续跑，不丢已完成进度。
            setNodeStatus(id, .succeeded)
        case .nodeCached(let id):
            progress.value += 1
            progress.currentNodeTitle = nil
            setNodeStatus(id, .cached)
        case .nodeSkipped(let id):
            progress.value += 1
            progress.currentNodeTitle = nil
            setNodeStatus(id, .skipped)
        case .nodeFailed(let id):
            progress.value += 1
            progress.currentNodeTitle = nil
            setNodeStatus(id, .failed)
            // P3：节点失败带上原因（GraphExecutionContext.lastErrors 由 recordFailure
            // 在 nodeFailed 事件投递前写入；主线程读线程安全）。调度器 nodeFailed 事件
            // 本身只带 nodeID，错误详情经执行上下文记录。
            let title = graph.node(id: id)?.title ?? "?"
            if let reason = context.lastErrors[id], !reason.isEmpty {
                statusMessage = "节点失败：\(title)（\(reason)）"
            } else {
                statusMessage = "节点失败：\(title)"
            }
        case .cancelled:
            statusMessage = "正在中断…"
        }
        executionProgress = progress
    }

    /// F21a（P0-1）：单节点状态即时写回图 + 防抖落盘（noteGraphChanged → DraftStore 512ms 防抖；
    /// 优雅退出另有 F7 willTerminate flushNow 兜底）。finishRun 收尾仍会整体 applying 一次，
    /// 与本增量写回幂等（同状态覆盖）。
    private func setNodeStatus(_ id: UUID, _ status: NodeStatus) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        guard graph.nodes[index].status != status else { return }
        graph.nodes[index].status = status
        noteGraphChanged()
    }

    /// 执行收尾（主线程）：写回状态 + 执行输出写回节点内容 + 闸口视觉化
    /// （QC FAIL / BLOCKED → 红色失败态）、统计成功/缓存/失败/跳过、向聊天流推送变化。
    /// P2-3（W-1/W-2）：统计改为基于写回后的图节点状态，QC FAIL/BLOCKED 计入「失败」。
    /// P0-1：写回前先校验 RunEnvelope 画布身份和图版本——用户中途切换画布或改图
    /// 则不覆盖、提示结果可能过期。
    func finishRun(_ result: DAGExecutionResult, before: [UUID: NodeStatus]) {
        guard isRunning else { return }
        // P0-1 写回前校验：当前画布身份和图结构版本 vs 运行开始时信封。
        // 不一致（用户中途切换画布或加了/删了节点、改连线/内容/模型配置）
        // → 旧结果不覆盖当前画布。
        if let envelope = currentRunEnvelope,
           !envelope.isCanvasCurrent(currentCanvasID)
                || !envelope.isGraphCurrent(graph.structuralRevision) {
            let summary = envelope.isCanvasCurrent(currentCanvasID)
                ? "画布在运行期间已修改，执行结果未写回（可能过期）"
                : "画布在运行期间已切换，执行结果未写回（可能过期）"
            statusMessage = summary
            onEvent?(.runFinished(summary: summary))
            isRunning = false
            executionProgress = nil
            currentRunEnvelope = nil
            executionScope.end()
            return
        }
        let applyingScheduler = DAGScheduler()
        let protectedGraph: NodeGraph?
        if result.executionEnvelope != nil {
            guard let envelope = currentRunEnvelope else {
                statusMessage = "执行结果缺少当前运行信封，结果未写回"
                onEvent?(.runFinished(summary: "执行结果未写回"))
                isRunning = false
                executionProgress = nil
                executionScope.end()
                return
            }
            // 增量事件会先写回节点 status；L7 fingerprint 代表运行开始时的
            // 图结构，因此只恢复运行前 status 来构造 compare-and-swap 快照。
            var actualGraph = graph
            for index in actualGraph.nodes.indices {
                if let status = before[actualGraph.nodes[index].id] {
                    actualGraph.nodes[index].status = status
                }
            }
            let actualEnvelope = DAGExecutionEnvelope(
                canvasID: currentCanvasID,
                runID: envelope.runID,
                graph: actualGraph,
                cancellationGeneration: envelope.executionEnvelope?.cancellationGeneration ?? 0,
                providerSnapshotFingerprint: envelope.executionEnvelope?.providerSnapshotFingerprint,
                idempotencyKey: envelope.executionEnvelope?.idempotencyKey
            )
            protectedGraph = applyingScheduler.applying(
                result,
                to: actualGraph,
                currentEnvelope: actualEnvelope,
                // 当前 run 的取消是合法终态：需要写回 skipped 状态并保留
                // lastResult；迟到的节点/资产写回仍由各自 cancellation gate 拦截。
                isCancelled: false
            )
            guard protectedGraph != nil else {
                let summary = "执行结果信封不匹配，执行结果未写回（可能过期）"
                statusMessage = summary
                onEvent?(.runFinished(summary: summary))
                isRunning = false
                executionProgress = nil
                currentRunEnvelope = nil
                executionScope.end()
                return
            }
        } else if currentRunEnvelope?.executionEnvelope == nil {
            protectedGraph = applyingScheduler.applying(result, to: graph)
        } else {
            let summary = "执行结果缺少 DAG 信封，执行结果未写回"
            statusMessage = summary
            onEvent?(.runFinished(summary: summary))
            isRunning = false
            executionProgress = nil
            currentRunEnvelope = nil
            executionScope.end()
            return
        }
        lastResult = result
        lastCompletedRunID = currentRunEnvelope?.runID
        graph = protectedGraph ?? graph
        syncGeneratedResults()
        // P2-3 W-2：执行输出写回节点内容（LLM text / QC report）→ 双击看到产物、E16 基于最新内容
        syncExecutionOutputsToNodeContent()
        // P2-3 W-1：QC FAIL / 提示词 BLOCKED → 节点红色失败态（非绿色成功）
        applyGateStatuses()
        let ok = graph.nodes.filter { $0.status == .succeeded }.count
        let cached = graph.nodes.filter { $0.status == .cached }.count
        let failed = graph.nodes.filter { $0.status == .failed }.count
        let skipped = graph.nodes.filter { $0.status == .skipped }.count
        let gateNotes = gateFailureSummary(result)
        if result.wasCancelled {
            statusMessage = "已中断：成功 \(ok) / 缓存 \(cached) / 跳过 \(skipped)"
        } else {
            statusMessage = "执行完成：成功 \(ok) / 缓存 \(cached) / 失败 \(failed) / 跳过 \(skipped)"
        }
        for node in graph.nodes where before[node.id] != node.status {
            onEvent?(.nodeStatusChanged(title: node.title, status: node.status))
        }
        let base = result.wasCancelled
            ? "已中断：成功 \(ok) · 缓存 \(cached) · 跳过 \(skipped)"
            : "成功 \(ok) · 缓存 \(cached) · 失败 \(failed) · 跳过 \(skipped)"
        onEvent?(.runFinished(summary: base + gateNotes))
        isRunning = false
        executionProgress = nil
        currentRunEnvelope = nil
        executionScope.end()
        noteGraphChanged()
    }

    /// P0-1 测试注入口：注入一个运行信封（测试不同版本校验路径）。
    /// 生产路径由 runGraph 在运行开始时自动记录，本入口仅供测试使用。
    func injectRunEnvelopeForTest(_ envelope: RunEnvelope) {
        currentRunEnvelope = envelope
    }

    /// P3 测试注入口：模拟 runGraph 的 scope.begin，无需跑完整 DAG。
    /// 仅供测试验证画布切换/新建对执行 scope 的失效语义。
    func beginExecutionScopeForTest(
        canvasID: UUID,
        runID: UUID,
        graphRevision: Int,
        graphFingerprint: String? = nil
    ) {
        executionScope.begin(
            canvasID: canvasID,
            runID: runID,
            graphRevision: graphRevision,
            graphFingerprint: graphFingerprint ?? graph.fingerprint
        )
    }

    // MARK: - P2-3 执行输出写回节点（W-2：双击看到执行产物，E16 调整基于最新内容）

    /// LLM 类节点（含 manju 6 类）：outputs["text"] 写回 params["content"]。
    /// 源节点（无输入端口，如 novelImport）保留用户粘贴的原始内容，不覆盖。
    private func isLLMWriteBackNode(_ type: String, inputs: [CanvasCore.Port]) -> Bool {
        guard !inputs.isEmpty else { return false } // 源节点：保留用户输入，不写回
        return type == "llm"
            || type == ManjuNodeType.plotOutline.rawValue
            || type == ManjuNodeType.script.rawValue
            || type == ManjuNodeType.storyboard.rawValue
            || type == ManjuNodeType.imagePrompt.rawValue
            || type == ManjuNodeType.videoPrompt.rawValue
    }

    /// 执行输出写回节点内容：LLM 类节点写回 text、QC 节点写回 report。
    /// 用户双击节点看到执行产物；E16「调整/总结」基于最近一次执行输出（W-2 / P1-1）。
    private func syncExecutionOutputsToNodeContent() {
        guard let result = lastResult else { return }
        for (nodeID, outputs) in result.outputs {
            guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
            let node = graph.nodes[index]
            if isLLMWriteBackNode(node.type, inputs: node.inputs) {
                if let text = outputs["text"] as? String, !text.isEmpty {
                    updateNodeContent(text, for: nodeID)
                }
            } else if node.type == ManjuNodeType.qcCheck.rawValue {
                if let report = outputs["report"] as? String, !report.isEmpty {
                    updateNodeContent(report, for: nodeID)
                }
            }
        }
    }

    // MARK: - P2-3 闸口视觉化（W-1：QC FAIL 红色 + 聊天回执 missing_slots/reasons）

    /// QC 节点校验 FAIL / 提示词节点 BLOCKED → 节点 .failed（红色，非绿色成功），
    /// 下游被跳过（铁律7：缺字段 = BLOCKED，不输出最终提示词）。
    private func applyGateStatuses() {
        guard let result = lastResult else { return }
        for (nodeID, outputs) in result.outputs {
            guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
            let type = graph.nodes[index].type
            if type == ManjuNodeType.qcCheck.rawValue,
               (outputs["qc_status"] as? String) == ManjuQCStatus.fail.rawValue {
                graph.nodes[index].status = .failed
            } else if (type == ManjuNodeType.imagePrompt.rawValue
                       || type == ManjuNodeType.videoPrompt.rawValue),
                      (outputs["blocked"] as? String) == "1" {
                graph.nodes[index].status = .failed
            }
        }
    }

    /// 闸口回执摘要：QC FAIL / BLOCKED 节点明细（missing_slots / reasons），
    /// 拼进 runFinished 聊天回执；无闸口失败返回空串。
    private func gateFailureSummary(_ result: DAGExecutionResult) -> String {
        var notes: [String] = []
        for (nodeID, outputs) in result.outputs {
            guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
            let title = graph.nodes[index].title
            let type = graph.nodes[index].type
            if type == ManjuNodeType.qcCheck.rawValue,
               (outputs["qc_status"] as? String) == ManjuQCStatus.fail.rawValue {
                let missing = outputs["missing_slots"] as? String
                let reasons = outputs["reasons"] as? String
                var parts = ["QC FAIL：\(title)"]
                if let missing, !missing.isEmpty { parts.append("缺字段：\(missing)") }
                if let reasons, !reasons.isEmpty { parts.append("原因：\(reasons)") }
                notes.append(parts.joined(separator: " / "))
            } else if (type == ManjuNodeType.imagePrompt.rawValue
                       || type == ManjuNodeType.videoPrompt.rawValue),
                      (outputs["blocked"] as? String) == "1" {
                let missing = outputs["missing_slots"] as? String ?? ""
                notes.append("BLOCKED：\(title)（缺字段：\(missing)）")
            }
        }
        return notes.isEmpty ? "" : "\n闸口：" + notes.joined(separator: "\n闸口：")
    }

    /// C2-2 中断：停止按钮 → 置位中断标志，调度器在下一个节点前停下并跳过剩余节点
    func cancelRun() {
        guard isRunning else { return }
        executionScope.end()
        let runID = currentRunEnvelope?.runID
        cancelFlag.cancel()
        if let runID, let videoInvoker = context.videoInvoker as? MinisCanvasVideoInvoker {
            Task { _ = await videoInvoker.cancelTasks(runID: runID) }
        }
        statusMessage = "正在停止…"
    }

    /// 真实生图结果回填（M1g）：登记 canonical asset 并绑定其 ID。
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
            let assetID = registerMediaAsset(
                path: path,
                kind: .image,
                source: .generated,
                nodeID: nodeID,
                runID: currentRunEnvelope?.runID
            )
            config.params[Self.assetIDKey] = assetID.uuidString
            graph.nodes[index].backendConfig = config
        }
        syncGeneratedVideoResults(result)
    }

    private func syncGeneratedVideoResults(_ result: DAGExecutionResult) {
        var pendingWritebacks: [(nodeID: UUID, artifactID: String)] = []
        for (nodeID, outputs) in result.outputs {
            guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }),
                  outputs["status"] as? String == "succeeded",
                  let path = outputs["video"] as? String, !path.isEmpty,
                  let artifactID = outputs["artifactID"] as? String, !artifactID.isEmpty,
                  Self.videoNodeTypes.contains(graph.nodes[index].type)
            else { continue }
            pendingWritebacks.append((nodeID: nodeID, artifactID: artifactID))
        }
        guard !pendingWritebacks.isEmpty else { return }

        // All synchronous artifact anchors must be present before capturing the
        // revision; otherwise multiple video nodes would invalidate each
        // other's delayed projection gate.
        let canvasID = currentCanvasID
        let graphRevision = graph.structuralRevision
        let runID = currentRunEnvelope?.runID
        let assetStore = self.assetStore
        for pending in pendingWritebacks {
            let nodeID = pending.nodeID
            let artifactID = pending.artifactID
            Task { [weak self] in
                let assets = await assetStore.assets(canvasID: canvasID)
                guard let asset = assets.first(where: { $0.metadata["artifactID"] == artifactID }) else {
                    return
                }
                await MainActor.run {
                    guard let self,
                          self.currentCanvasID == canvasID,
                          self.graph.structuralRevision == graphRevision,
                          let index = self.graph.nodes.firstIndex(where: { $0.id == nodeID }) else {
                        return
                    }
                    if let runID {
                        let isCurrentRun = self.currentRunEnvelope?.runID == runID
                        let isLastCompletedRun = self.currentRunEnvelope == nil
                            && self.lastCompletedRunID == runID
                        guard isCurrentRun || isLastCompletedRun else { return }
                    }
                    self.assetProjectionByID[asset.id] = asset
                    var canonicalConfig = self.graph.nodes[index].backendConfig ?? NodeBackendConfig()
                    canonicalConfig.params["artifact.id"] = artifactID
                    canonicalConfig.params[Self.assetIDKey] = asset.id.uuidString
                    self.graph.nodes[index].backendConfig = canonicalConfig
                    self.assetIndexRevision &+= 1
                }
            }
        }
    }

    /// 生产读取 seam（ArtifactStore 生产读取 consumer）：把视频节点
    /// backendConfig.params["artifact.id"] 锚点解析为同一注入 ArtifactStore 中的
    /// 持久化收据。闭合计划 C 受控转换链的读取端：
    /// artifact-<taskID> -> metadata[artifactID] -> params[artifact.id] -> receipt。
    /// 无锚点或收据缺失返回 nil（不抛错、不改写任何状态）。
    func artifactReceipt(forNode nodeID: UUID) async -> ArtifactReceipt? {
        guard let node = graph.nodes.first(where: { $0.id == nodeID }),
              let artifactID = node.backendConfig?.params["artifact.id"],
              !artifactID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return await artifactStore.receipt(id: artifactID)
    }

    func resetStatuses() {
        for index in graph.nodes.indices {
            graph.nodes[index].status = .pending
        }
        noteGraphChanged()
        statusMessage = "已重置状态"
    }
}

// MARK: - NodeStatus 显示辅助

extension NodeStatus {
    var color: Color {
        switch self {
        case .pending: return Color(nsColor: .systemGray)
        case .running: return Color(nsColor: .systemBlue)
        case .succeeded: return Color(nsColor: .systemGreen)
        case .cached: return Color(nsColor: .systemGray)
        case .failed: return Color(nsColor: .systemRed)
        case .skipped: return Color(nsColor: .darkGray)
        }
    }

    var label: String {
        switch self {
        case .pending: return "待执行"
        case .running: return "执行中"
        case .succeeded: return "完成"
        case .cached: return "已缓存"
        case .failed: return "失败"
        case .skipped: return "已跳过"
        }
    }
}
