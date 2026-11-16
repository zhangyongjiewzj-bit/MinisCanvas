import Foundation

/// 漫剧生产流水线的 11 类画布节点类型。
///
/// 对应 manju-core skill 的生产优先顺序：
/// 剧本/分镜/提示词 → 资产（定妆图/服装/场景）→ 生成（图/视频）→ 预演 → 质检。
public enum ManjuNodeType: String, CaseIterable, Sendable, Codable, Hashable {
    /// 小说导入：原始文本接入
    case novelImport
    /// 剧情大纲：章节/冲突/节奏拆解
    case plotOutline
    /// 剧本：对白、动作、场景描述
    case script
    /// 分镜：首尾帧、镜头拆分
    case storyboard
    /// 图片提示词：按图片 8 槽模板输出
    case imagePrompt
    /// 视频提示词：按视频 9 槽模板输出
    case videoPrompt
    /// 图片生成：定妆图/服装/场景/首尾帧（走对应后端）
    case imageGen
    /// 视频生成：I2V/R2V/V2V（走对应后端）
    case videoGen
    /// Blender 白模预演：多人站位/机位验证
    case blenderPreview
    /// 资产引用：角色锁定卡、色板、场景母图
    case assetRef
    /// 审核：提示词/任务单人工审核闸口（待审黄/通过青/打回红；未通过下游不执行）
    case reviewGate
    /// 质检：结构闸口 + 审美闸口 + 三刻度盘
    case qcCheck

    /// 节点在画布上的展示标题（中文）
    public var displayName: String {
        switch self {
        case .novelImport: return "小说导入"
        case .plotOutline: return "剧情大纲"
        case .script: return "剧本"
        case .storyboard: return "分镜"
        case .imagePrompt: return "图片提示词"
        case .videoPrompt: return "视频提示词"
        case .imageGen: return "图片生成（Beta）"
        case .videoGen: return "视频生成（Beta）"
        case .blenderPreview: return "Blender 预演（Beta·外部插件）"
        case .assetRef: return "资产引用"
        case .reviewGate: return "审核"
        case .qcCheck: return "质检"
        }
    }
}

// MARK: - 生成类节点规范端口（U2）

extension ManjuNodeType {
    /// 生图节点规范输入端口（U2）：`prompt`（提示词，来自图片提示词节点/文本节点）+
    /// `image`（图生图参考图，可选——上游传入图片路径时走 img2img 语义）。
    /// 与 GraphExecutionContext.executeImage 读取的输入键严格一致。
    public static let imageGenInputPorts = ["prompt", "image"]
    /// 生图节点规范输出端口：`image`（生成图片路径/URL；无 key 降级时承载任务单全文）
    public static let imageGenOutputPorts = ["image"]

    /// 生视频节点规范输入端口：`prompt`（视频提示词）+ `image`（I2V 首帧参考图，可选）
    /// + `duration`（镜头时长，如 "5s"/"10s"，可选——覆盖节点默认时长配置）
    /// + `video`（V2V 参考视频基础端口，B2 动态多输入：video/video1/…/video2，最多 3 个）。
    /// 与 GraphExecutionContext.executeVideo 读取的输入键严格一致。
    public static let videoGenInputPorts = ["prompt", "image", "duration", "video"]
    /// 生视频节点规范输出端口：`video`（视频路径/URL；无 key 降级时承载任务单全文）
    public static let videoGenOutputPorts = ["video"]

    /// 审核节点规范输入端口：`text`（待审文本——提示词/任务单；单份文本审核放行语义）
    public static let reviewGateInputPorts = ["text"]
    /// 审核节点规范输出端口：`pass`（通过后输出原文本给下游）+ `status`（PASS/REJECT/PENDING）
    public static let reviewGateOutputPorts = ["pass", "status"]

    // MARK: - B2 动态多输入端口（用户定案：默认 1 个输入节点，拉线占用后自动长出下一个，最多 10 个）

    /// 质检节点（qcCheck）动态输入端口：`image` 类（image/image1/…/image9），
    /// 多张待审图逐个接入（ComfyUI 动态输入槽语义）；上限 10。
    /// 注：`video`（审视频）为**静态基础端口**（上游 videoGen 单路成片，模板主链
    /// videoGen.video → qcCheck.video），不设 video 动态槽——见 qcCheckInputPorts。
    public static let qcCheckDynamicInputDataType = "image"
    public static let qcCheckDynamicInputMax = 10

    /// 生视频节点（videoGen）动态输入端口：`video` 类（video/video1/video2），
    /// 多个参考视频逐个接入（V2V 多视频语义）；用户定案上限 3。
    public static let videoGenVideoDynamicInputDataType = "video"
    public static let videoGenVideoDynamicInputMax = 3

    /// 生图节点（imageGen）动态输入端口：`image` 类（image/image1/…/image9），
    /// 多张参考图逐个接入（img2img 多图语义）；上限 10。
    public static let imageGenDynamicInputDataType = "image"
    public static let imageGenDynamicInputMax = 10

    /// 生视频节点（videoGen）动态输入端口：`image` 类（image/image1/…/image9），
    /// I2V 多首帧/多参考图逐个接入；上限 10。
    public static let videoGenImageDynamicInputDataType = "image"
    public static let videoGenImageDynamicInputMax = 10

    /// 动态多输入配置：节点类型 → 动态输入端口组（dataType, 上限）。
    /// 质检（qcCheck）image×10（多图待审，无参考图机制；video 为静态基础端口不在此列）、
    /// 生视频（videoGen）video×3（V2V 多参考视频）支持；**imageGen 不在此列**——它的 image 端口走既有参考图机制
    /// （右键手动加、上限 4，AJ-19/20 测试锁定），若也注册动态端口会导致连线自动长出与
    /// 手动参考图语义冲突（连接 image1 意外长出 image2）。
    /// - Note: 与既有 `maxReferenceImages`（imageGen 参考图上限 4）并存——
    ///   参考图端口靠右键菜单手动加；动态多输入端口在**连线成功后自动长出**。
    public static func dynamicInputConfigs(for type: String) -> [(dataType: String, max: Int)] {
        switch ManjuNodeType(rawValue: type) {
        case .qcCheck: return [(qcCheckDynamicInputDataType, qcCheckDynamicInputMax)]
        case .videoGen: return [(videoGenVideoDynamicInputDataType, videoGenVideoDynamicInputMax)]
        default: return []
        }
    }
    /// 单数：按数据类型取该节点类型的动态输入配置（连线自动长端口用）。
    /// 按 dataType 匹配——videoGen 同时支持 image×10 与 video×3，**连了哪个类型的端口就长哪个**。
    public static func dynamicInputConfig(for type: String, dataType: String) -> (dataType: String, max: Int)? {
        dynamicInputConfigs(for: type).first { $0.dataType == dataType }
    }
    /// 质检节点（qcCheck）规范输入端口：`image`（待审图/待复检图片，基础端口，可选）
    /// + `text`（提示词/任务单文本，可选）+ `video`（上游 videoGen 成片或降级任务单，可选——
    /// 模板主链 videoGen.video → qcCheck.video，executor 读取该键识别任务单「待生成后复检」
    /// 或对产物文本做结构/审美闸口）。B2 动态多输入：image 类另有 image/image1/…/image9
    /// 动态槽（qcCheckDynamicInputDataType）。executor 兼容读取 `prompt` 键（文本族别名：
    /// 直接调用/旧数据可携带；图上经 portValue 别名回退落到 text 端口）。
    /// 与 QCNodeExecutor.execute 读取的输入键严格一致（UI 所见 = executor 所读）。
    public static let qcCheckInputPorts = ["image", "text", "video"]
    /// 质检节点（qcCheck）规范输出端口：`report`（完整 QC 报告——内含三刻度盘/缺字段/原因，
    /// 执行后写回节点内容供只读查看）+ `status`（PASS/FAIL/待生成后复检）。
    public static let qcCheckOutputPorts = ["report", "status"]
    /// 质检节点（qcCheck）结构化审计详情键：QCNodeExecutor 随 report/status 一并输出的
    /// **只读审计详情**（不设独立端口，report 全文已聚合呈现）：
    /// - `qc_status`：闸口状态（节点状态色 / DAGScheduler 闸口判定）
    /// - `images_reviewed`：多路审图计数（>1 时写入）
    /// - `dial_variance` / `dial_motion` / `dial_density`：三刻度盘（report 内亦有）
    /// - `reasons` / `missing_slots`：FAIL 原因与缺字段（聊天回执 / 闸口明细）
    /// UI 呈现路径：报告全文（节点内容编辑器）+ 节点状态色 + 运行回执——无幽灵输出。
    public static let qcCheckAuditDetailKeys = [
        "qc_status", "images_reviewed", "dial_variance", "dial_motion",
        "dial_density", "reasons", "missing_slots",
    ]

    /// 生成类节点（imageGen/videoGen）的规范输入端口名；其余类型返回空。
    public var generationInputPortNames: [String] {
        switch self {
        case .imageGen: return Self.imageGenInputPorts
        case .videoGen: return Self.videoGenInputPorts
        default: return []
        }
    }

    /// 生成类节点（imageGen/videoGen）的规范输出端口名；其余类型返回空。
    public var generationOutputPortNames: [String] {
        switch self {
        case .imageGen: return Self.imageGenOutputPorts
        case .videoGen: return Self.videoGenOutputPorts
        default: return []
        }
    }
}

// MARK: - 参考图数量上限（AJ-19/20：按节点类型，动态端口，参照 ComfyUI）

extension ManjuNodeType {
    /// 参考图输入端口上限（含基础 `image` 端口；ComfyUI 动态输入槽语义）。
    /// 生图最多 4 张参考图；生视频仅 I2V 首帧 1 张；其余类型 0（不支持动态参考图）。
    public var maxReferenceImages: Int {
        switch self {
        case .imageGen: return 4
        case .videoGen: return 1
        default: return 0
        }
    }

    /// 该节点类型是否支持动态参考图端口（maxReferenceImages > 0）
    public var supportsReferenceImages: Bool { maxReferenceImages > 0 }
}
