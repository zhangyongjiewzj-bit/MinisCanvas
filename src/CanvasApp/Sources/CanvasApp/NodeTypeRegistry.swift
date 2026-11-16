import SwiftUI
import CanvasCore

// MARK: - 面板分组

/// 左侧面板分组：基础节点 / 漫剧流程 / 漫剧工具
enum NodePaletteGroup: String, CaseIterable, Identifiable {
    /// 基础占位节点（text/llm/image/video）
    case basic = "基础节点"
    /// 漫剧流程组：小说→剧情→脚本→分镜→提示词→生图→生视频
    case manjuFlow = "漫剧流程"
    /// 漫剧工具组：Blender 预演 / 资产引用 / QC 检查
    case manjuTools = "漫剧工具"

    var id: String { rawValue }
}

// MARK: - 节点分类（Phase B 产品方向：画布只暴露生成类节点）

/// 节点分类：生成类（画布新建入口可见）vs 文本创作类（仅保留类型定义以兼容旧图数据，
/// 不再出现在画布「添加节点」入口：左侧面板 / 右键菜单 / 搜索面板 / 工具栏 / 建节点命令）。
enum NodeCategory: String, CaseIterable, Sendable {
    /// 生成类：产出可交付物（文本源 / LLM / 图 / 视频 / 预演 / 质检 / 资产）
    case generative = "生成类"
    /// 文本创作类：小说导入 / 剧情 / 脚本 / 分镜 / 提示词撰写等中间创作环节
    case textCreative = "文本创作类"
}

// MARK: - 节点类型注册表
//
// 画布节点类型 = CanvasNode.type 字符串 → 节点规格（标题 / 端口 / 面板颜色 / 图标 / 槽位徽标）。
// 漫剧 11 类节点（ManjuNodeType）与基础节点共用同一注册表，画布渲染层无需改动。

/// 节点类型规格：从类型字符串注册表创建新节点
struct NodeTypeSpec: Identifiable {
    let type: String
    let title: String
    let summary: String
    let color: Color
    let inputs: [CanvasCore.Port]
    let outputs: [CanvasCore.Port]
    /// 节点级默认模型配置（v0.2：创建节点即带默认模型，面板可随时改）
    let defaultBackendConfig: NodeBackendConfig?
    /// SF Symbol 图标（面板条目 + 画布节点标题栏共用）
    var iconName = "square.grid.2x2"
    /// 提示词模板槽位数（>0 时面板标题旁显示 "N槽" 徽标）
    var slotCount: Int?
    /// 面板分组
    var group: NodePaletteGroup = .basic

    var id: String { type }

    /// 创建该类型的一个新节点（默认原点，等待自动布局或用户拖拽）
    func makeNode(position: Point = .zero) -> CanvasNode {
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

/// 内置节点类型注册表：基础 4 类 + 漫剧 11 类
enum NodeTypeRegistry {

    // MARK: Phase B 瘦身（用户产品方向拍板）：画布新建入口只暴露生成类节点
    //
    // 文本创作类（小说导入/剧情/脚本/分镜/图片提示词/视频提示词）与基础占位
    // image/video 的类型定义全部保留（渲染旧图数据 / 执行器 / spec(for:) 查表不受影响），
    // 只是不再出现在「添加节点」入口：左侧面板 / 右键菜单 / 搜索面板 / 工具栏 / 建节点命令。

    /// Phase B 保留清单：画布可新建的 7 类生成类节点。
    /// 基础 image/video 为占位演示节点，imageGen/videoGen 是正式替代，故不进保留清单。
    static let creatableTypes: Set<String> = [
        "text", "llm",
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
            type: "text",
            title: "文本输入",
            summary: "文本内容源",
            color: .teal,
            inputs: [],
            outputs: [CanvasCore.Port(name: "text", direction: .output, dataType: "string")],
            defaultBackendConfig: NodeBackendConfig(
                providerType: .local, providerID: "ollama", modelID: "qwen2.5",
                params: ["temperature": "0.7"]
            ),
            iconName: "text.alignleft"
        ),
        NodeTypeSpec(
            type: "llm",
            title: "LLM 推理",
            summary: "大模型生成",
            color: .blue,
            inputs: [
                CanvasCore.Port(name: "prompt", direction: .input, dataType: "string"),
                CanvasCore.Port(name: "system", direction: .input, dataType: "string"),
            ],
            outputs: [CanvasCore.Port(name: "text", direction: .output, dataType: "string")],
            defaultBackendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview",
                params: ["temperature": "0.7", "maxTokens": "2048"]
            ),
            iconName: "brain.head.profile"
        ),
        NodeTypeSpec(
            type: "image",
            title: "图像生成",
            summary: "文生图",
            color: .purple,
            inputs: [
                CanvasCore.Port(name: "prompt", direction: .input, dataType: "string"),
            ],
            outputs: [CanvasCore.Port(name: "image", direction: .output, dataType: "image")],
            defaultBackendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "gimage2", modelID: "gpt-image-2-official",
                params: ["size": "1024x1024"]
            ),
            iconName: "photo"
        ),
        NodeTypeSpec(
            type: "video",
            title: "视频生成",
            summary: "图生视频（演示失败态）",
            color: .pink,
            inputs: [
                CanvasCore.Port(name: "image", direction: .input, dataType: "image"),
                CanvasCore.Port(name: "prompt", direction: .input, dataType: "string"),
            ],
            outputs: [CanvasCore.Port(name: "video", direction: .output, dataType: "video")],
            defaultBackendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "kling", modelID: "kling-v2",
                params: ["duration": "5s", "resolution": "720p"]
            ),
            iconName: "film"
        ),
    ]

    /// 漫剧 11 类节点（type = ManjuNodeType.rawValue，与流水线模板/资产注入互查）
    static let manjuSpecs: [NodeTypeSpec] = ManjuNodeType.allCases.map { spec(for: $0) }

    /// 全部注册表条目（面板按 group 分组展示）
    static var specs: [NodeTypeSpec] { basicSpecs + manjuSpecs }

    static func spec(for type: String) -> NodeTypeSpec? {
        specs.first { $0.type == type }
    }
}

// MARK: - 漫剧节点规格

extension NodeTypeRegistry {

    /// 按 ManjuNodeType 构造节点规格：中文标题 + SF Symbol 图标 + 模板槽位徽标
    static func spec(for manjuType: ManjuNodeType) -> NodeTypeSpec {
        // 槽位数取自提示词模板库（图片 8 槽 / 视频 9 槽，其余 0 槽不显示徽标）
        let slotCount = ManjuPromptTemplates.template(for: manjuType)?.slots.count
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
                type: manjuType.rawValue, title: "生图", summary: "定妆图/服装/场景/首尾帧",
                color: .orange,
                inputs: [CanvasCore.Port(name: "prompt", direction: .input, dataType: "string")],
                outputs: [CanvasCore.Port(name: "image", direction: .output, dataType: "image")],
                defaultBackendConfig: NodeBackendConfig(
                    providerType: .cloud, providerID: "gimage2", modelID: "gpt-image-2-official",
                    params: ["size": "1024x1024"]
                ),
                iconName: "photo.on.rectangle.angled", slotCount: slotCount, group: .manjuFlow
            )
        case .videoGen:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "生视频", summary: "I2V/R2V/V2V 执行",
                color: .red,
                inputs: [
                    CanvasCore.Port(name: "image", direction: .input, dataType: "image"),
                    CanvasCore.Port(name: "prompt", direction: .input, dataType: "string"),
                ],
                outputs: [CanvasCore.Port(name: "video", direction: .output, dataType: "video")],
                defaultBackendConfig: NodeBackendConfig(
                    providerType: .cloud, providerID: "kling", modelID: "kling-v2",
                    params: ["duration": "5s", "resolution": "720p"]
                ),
                iconName: "video.fill", slotCount: slotCount, group: .manjuFlow
            )
        case .blenderPreview:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "Blender 白模预演", summary: "多人站位/机位验证",
                color: .green, inputs: [textIn], outputs: [textOut],
                defaultBackendConfig: nil,
                iconName: "arkit", slotCount: slotCount, group: .manjuTools
            )
        case .assetRef:
            // 资产锁定接线（A5）：对应 ManjuAssets 资产锁定层，执行器 AssetLockExecutor
            // 输出 ManjuAssetInjection 注入的资产锁定摘要（角色锁定卡/色板/场景母图）+ 参考图清单，
            // 经 assets 端口喂给下游图片/视频提示词节点（铁律2/6）。
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "资产引用", summary: "资产锁定：角色锁定卡/色板/母图",
                color: .brown, inputs: [], outputs: [textOut],
                defaultBackendConfig: nil,
                iconName: "cube.fill", slotCount: slotCount, group: .manjuTools
            )
        case .qcCheck:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "QC 检查", summary: "结构+审美+三刻度盘（PASS/FAIL）",
                color: .gray, inputs: [textIn], outputs: [textOut],
                defaultBackendConfig: llmConfig,
                iconName: "checkmark.shield.fill", slotCount: slotCount, group: .manjuTools
            )
        case .reviewGate:
            return NodeTypeSpec(
                type: manjuType.rawValue, title: "审核", summary: "单份文本审核（PASS/REJECT/PENDING）",
                color: .indigo, inputs: [textIn],
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

// MARK: - 节点状态 → 颜色

extension NodeStatus {
    /// 状态色映射：pending 灰 / running 蓝 / succeeded 绿 / failed 红 / skipped 暗灰
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

    /// 状态文本（用于节点标题栏角标）
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
