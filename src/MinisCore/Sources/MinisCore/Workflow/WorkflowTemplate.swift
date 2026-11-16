import Foundation

// MARK: - WorkflowStepType

/// 工作流步骤类型。与 CanvasCore 的 ManjuNodeType 一一对应（字符串值相同），
/// 但这里仅作元数据——执行阶段统一走文本 LLM（生图/生视频步骤产出 JobTicket 任务单）。
public enum WorkflowStepType: String, Codable, Sendable, Hashable {
    case novelImport = "novel_import"
    case plotOutline = "plot_outline"
    case script = "script"
    case storyboard = "storyboard"
    case imagePrompt = "image_prompt"
    case videoPrompt = "video_prompt"
    case imageGen = "image_gen"
    case videoGen = "video_gen"
    case qcCheck = "qc_check"
    case custom = "custom"
}

// MARK: - WorkflowStep

/// 工作流中的单个步骤。
///
/// 执行语义：把 `promptTemplate` 中的 `{{key}}` 占位符用「用户输入」或
/// 「前面步骤的 outputKey 输出」填充，交给 LLM，返回文本存入 `outputKey`，
/// 供后续步骤引用。
public struct WorkflowStep: Codable, Equatable, Sendable, Identifiable {
    /// 步骤唯一 id（模板内不重复）。
    public let id: String
    /// 步骤类型（元数据，用于 UI 图标/进度展示）。
    public var type: WorkflowStepType
    /// 步骤标题（中文，如「剧情拆解」）。
    public var title: String
    /// 提示词模板，含 `{{inputName}}` 占位符；内容引用 manju 铁律。
    public var promptTemplate: String
    /// 本步骤需要的输入名（来自用户 inputs 或先前步骤 outputKey）。
    public var inputs: [String]
    /// 本步骤输出存入的结果键，供后续步骤引用。
    public var outputKey: String

    public init(
        id: String,
        type: WorkflowStepType,
        title: String,
        promptTemplate: String,
        inputs: [String] = [],
        outputKey: String
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.promptTemplate = promptTemplate
        self.inputs = inputs
        self.outputKey = outputKey
    }
}

// MARK: - WorkflowTemplate

/// 可复用的 Agent 工作流模板：一串有序步骤 + 所需输入清单。
///
/// 预置三个漫剧模板（见 `WorkflowTemplate.presets`）：
/// 1. 漫剧全流程（manju-full）：小说→剧情→脚本→分镜→图片提示词→生图→生视频
/// 2. 小说拆解（manju-novel-breakdown）：小说→剧情→脚本→分镜
/// 3. 分镜提示词（manju-storyboard-prompts）：分镜→8槽图片提示词→9槽视频提示词
public struct WorkflowTemplate: Codable, Equatable, Sendable, Identifiable {
    /// 模板 id（稳定标识，deep link 也用 id/name 查找）。
    public let id: String
    /// 模板名（中文，如「漫剧全流程」）。
    public var name: String
    /// 一句话描述。
    public var description: String
    /// 有序步骤列表。
    public var steps: [WorkflowStep]
    /// 模板所需的顶层输入名（如 ["novel"]）；运行时必须提供。
    public var requiredInputs: [String]

    public init(
        id: String,
        name: String,
        description: String,
        steps: [WorkflowStep],
        requiredInputs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.steps = steps
        self.requiredInputs = requiredInputs
    }

    /// 模板自检：步骤非空、id 唯一、outputKey 唯一、promptTemplate 非空、占位符可解析。
    /// 校验失败抛 `WorkflowError.invalidTemplate`。
    public func validate() throws {
        guard !steps.isEmpty else {
            throw WorkflowError.invalidTemplate(id: id, reason: "模板没有步骤")
        }
        var stepIDs = Set<String>()
        var outputKeys = Set<String>()
        for step in steps {
            guard !step.id.isEmpty else {
                throw WorkflowError.invalidTemplate(id: id, reason: "存在空步骤 id")
            }
            guard stepIDs.insert(step.id).inserted else {
                throw WorkflowError.invalidTemplate(id: id, reason: "步骤 id 重复: \(step.id)")
            }
            guard !step.outputKey.isEmpty else {
                throw WorkflowError.invalidTemplate(id: id, reason: "步骤 \(step.id) 的 outputKey 为空")
            }
            guard outputKeys.insert(step.outputKey).inserted else {
                throw WorkflowError.invalidTemplate(id: id, reason: "outputKey 重复: \(step.outputKey)")
            }
            guard !step.promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowError.invalidTemplate(id: id, reason: "步骤 \(step.id) 的 promptTemplate 为空")
            }
        }
    }

    // MARK: - 预置模板

    /// 三个内置漫剧模板。id 稳定，用户可覆盖同名模板（见 WorkflowStore）。
    public static let presets: [WorkflowTemplate] = [
        .manjuFullFlow,
        .manjuNovelBreakdown,
        .manjuStoryboardPrompts,
    ]

    /// 漫剧全流程：小说 → 剧情拆解 → 脚本生成 → 分镜生成 → 图片提示词 → 生图 → 生视频。
    public static let manjuFullFlow = WorkflowTemplate(
        id: "manju-full",
        name: "漫剧全流程",
        description: "从小说原文一键产出到生图/生视频任务单的完整漫剧工作流（7 步）",
        steps: [
            WorkflowStep(
                id: "novel_import",
                type: .novelImport,
                title: "小说导入",
                promptTemplate: """
                你是漫剧工作流引擎。遵守 manju 铁律：先锁风格与世界观，再谈内容；角色定妆一致，肤色防漂移。
                将以下小说原文导入并整理为结构化设定：人物、世界观、风格关键词、核心冲突。
                保留原文细节，不擅自扩写。

                小说原文：
                {{novel}}
                """,
                inputs: ["novel"],
                outputKey: "novel"
            ),
            WorkflowStep(
                id: "plot_outline",
                type: .plotOutline,
                title: "剧情拆解",
                promptTemplate: """
                你是漫剧编剧。遵守 manju 铁律：镜头感优先，剧情服务于画面；每段标注情绪曲线与反转点。
                基于结构化设定，按「开端-发展-高潮-结局」拆解剧情，标注适合做成画面的关键帧节点。
                设定：
                {{novel}}
                """,
                inputs: ["novel"],
                outputKey: "plot"
            ),
            WorkflowStep(
                id: "script",
                type: .script,
                title: "脚本生成",
                promptTemplate: """
                你是漫剧编剧。遵守 manju 铁律：对白口语化、动作可视化、一句一个画面。
                将剧情大纲改写为分场脚本文本：场景、对白、动作描述。
                剧情大纲：
                {{plot}}
                """,
                inputs: ["plot"],
                outputKey: "script"
            ),
            WorkflowStep(
                id: "storyboard",
                type: .storyboard,
                title: "分镜生成",
                promptTemplate: """
                你是漫剧分镜师。遵守 manju 铁律：9:16 竖屏画幅、镜头语言连贯、角色肤色与定妆一致防漂移。
                将脚本文本拆解为分镜列表，每镜给出：镜号、景别、运镜、时长、画面内容、对白/音效。
                脚本文本：
                {{script}}
                """,
                inputs: ["script"],
                outputKey: "storyboard"
            ),
            WorkflowStep(
                id: "image_prompt",
                type: .imagePrompt,
                title: "图片提示词",
                promptTemplate: """
                你是漫剧提示词专家。遵守 manju 铁律：风格锁定、角色定妆一致、肤色防漂移。
                为分镜编写 8 槽图片提示词（8 个关键画面槽位），每槽含：主体、动作、景别、光线、风格。
                分镜：
                {{storyboard}}
                """,
                inputs: ["storyboard"],
                outputKey: "imagePrompt"
            ),
            WorkflowStep(
                id: "image_gen",
                type: .imageGen,
                title: "生图",
                promptTemplate: """
                你是漫剧生图任务单生成器。遵守 manju 铁律：9:16 竖屏、风格统一、角色定妆一致。
                基于图片提示词生成可执行的生图任务单（JobTicket）：每槽完整提示词、参考图要求、负面提示词。
                图片提示词：
                {{imagePrompt}}
                """,
                inputs: ["imagePrompt"],
                outputKey: "imageJob"
            ),
            WorkflowStep(
                id: "video_gen",
                type: .videoGen,
                title: "生视频",
                promptTemplate: """
                你是漫剧生视频任务单生成器。遵守 manju 铁律：首尾帧一致、动作连贯、镜头语言服务于情绪。
                基于生图任务单与分镜，生成 9 槽视频提示词任务单：每槽首帧图、运镜、动作链、时长。
                生图任务单：
                {{imageJob}}

                分镜：
                {{storyboard}}
                """,
                inputs: ["imageJob", "storyboard"],
                outputKey: "videoJob"
            ),
        ],
        requiredInputs: ["novel"]
    )

    /// 小说拆解：小说 → 剧情拆解 → 脚本生成 → 分镜生成。
    public static let manjuNovelBreakdown = WorkflowTemplate(
        id: "manju-novel-breakdown",
        name: "小说拆解",
        description: "只做小说→剧情→脚本→分镜 4 步，产出分镜文本",
        steps: Array(manjuFullFlow.steps.prefix(4)),
        requiredInputs: ["novel"]
    )

    /// 分镜提示词：分镜整理 → 8槽图片提示词 → 9槽视频提示词。
    public static let manjuStoryboardPrompts = WorkflowTemplate(
        id: "manju-storyboard-prompts",
        name: "分镜提示词",
        description: "给定分镜文本，整理后产出 8 槽图片提示词 + 9 槽视频提示词",
        steps: [
            WorkflowStep(
                id: "storyboard_normalize",
                type: .storyboard,
                title: "分镜整理",
                promptTemplate: """
                你是漫剧分镜师。遵守 manju 铁律：9:16 竖屏画幅、镜头语言连贯。
                将分镜文本整理为标准化列表：镜号、景别、运镜、画面内容，逐镜一行。
                分镜：
                {{storyboard}}
                """,
                inputs: ["storyboard"],
                outputKey: "storyboardNormalized"
            ),
            WorkflowStep(
                id: "image_prompt_8slot",
                type: .imagePrompt,
                title: "8槽图片提示词",
                promptTemplate: """
                你是漫剧提示词专家。遵守 manju 铁律：风格锁定、角色定妆一致、肤色防漂移。
                将标准化分镜转换为 8 槽图片提示词，每槽：主体/动作/景别/光线/风格。
                分镜：
                {{storyboardNormalized}}
                """,
                inputs: ["storyboardNormalized"],
                outputKey: "imagePrompt"
            ),
            WorkflowStep(
                id: "video_prompt_9slot",
                type: .videoPrompt,
                title: "9槽视频提示词",
                promptTemplate: """
                你是漫剧提示词专家。遵守 manju 铁律：首尾帧一致、9:16 竖屏、动作链连贯。
                将标准化分镜转换为 9 槽视频提示词，每槽：首帧图/运镜/动作链/时长。
                分镜：
                {{storyboardNormalized}}

                图片提示词（参考）：
                {{imagePrompt}}
                """,
                inputs: ["storyboardNormalized", "imagePrompt"],
                outputKey: "videoPrompt"
            ),
        ],
        requiredInputs: ["storyboard"]
    )
}
