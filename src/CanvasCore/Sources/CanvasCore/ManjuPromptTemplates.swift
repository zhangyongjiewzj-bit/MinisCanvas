import Foundation

/// 提示词槽位：槽名 + 说明 + 是否必填。
/// 缺必填字段 = BLOCKED（铁律 7），不输出最终提示词。
public struct PromptSlot: Equatable, Sendable, Codable, Hashable {
    /// 槽位名，如 `TYPE` / `REFERENCE` / `ACTION`
    public let name: String
    /// 槽位填写说明（来自 manju-core 铁律）
    public let detail: String
    /// 是否必填；缺必填字段时闸口 BLOCKED
    public let isRequired: Bool

    public init(name: String, detail: String, isRequired: Bool = true) {
        self.name = name
        self.detail = detail
        self.isRequired = isRequired
    }
}

/// 漫剧节点模板：节点类型 + 槽位清单 + 系统提示词（内嵌 manju-core 铁律）。
public struct ManjuTemplate: Equatable, Sendable, Codable {
    public let nodeType: ManjuNodeType
    public let slots: [PromptSlot]
    /// 生成该节点提示词时注入的系统提示词，逐条内嵌 manju-core 铁律
    public let systemPrompt: String

    public init(nodeType: ManjuNodeType, slots: [PromptSlot], systemPrompt: String) {
        self.nodeType = nodeType
        self.slots = slots
        self.systemPrompt = systemPrompt
    }
}

/// 漫剧提示词模板库：图片 8 槽 / 视频 9 槽，槽位与铁律从 manju-core skill 提取。
public enum ManjuPromptTemplates {

    // MARK: - 图片提示词 8 槽

    /// 图片提示词 8 槽：TYPE / REFERENCE / LAYOUT / STRUCTURE / MATERIAL / COLOR / LIGHT / FORBID
    public static let imageSlots: [PromptSlot] = [
        PromptSlot(name: "TYPE", detail: "图像类型和用途。必须先声明画幅、比例和布局方向，再描述内容（铁律12：模型先分配画布再填内容，否则细节预算被物体吃掉、布局即兴）。"),
        PromptSlot(name: "REFERENCE", detail: "参考图职责：只写\"只继承什么、不继承什么\"。每张参考图只承担一个职责；只写锁定部位清单（脸、五官、眼型、骨相、肤色……），禁止对部位做细节描述（铁律2：细节描述会污染参考图导致重绘；图就是答案，文字只负责说\"不许改\"）。"),
        PromptSlot(name: "LAYOUT", detail: "画幅、版式、角度、主体占比、留白方向。必须有明确主次关系和视觉动线，有前中后景层次或明确留白方向（审美闸口S3）。"),
        PromptSlot(name: "STRUCTURE", detail: "发型/服装/道具结构。材质结构写具体织纹、磨损、厚度、垂坠（审美闸口S3，禁只写\"有质感\"）。一张图只承担一个职责（铁律1）。"),
        PromptSlot(name: "MATERIAL", detail: "材质。写具体织纹、磨损、厚度、垂坠、透光性（审美闸口S3）。"),
        PromptSlot(name: "COLOR", detail: "色号、面积比例（70/20/8/2）、主辅压边强调。写具体色名+色值或面积比例，禁\"高级灰、莫兰迪、仙气\"等模糊词；强调色只出现在细线、窄带、光效、点睛位置（审美闸口S2）。"),
        PromptSlot(name: "LIGHT", detail: "灯光和摄影质感。写具体方向、质感、效果（侧光/逆光/斑驳/轮廓光），禁只写\"自然光、好看的光\"（审美闸口S3）。"),
        PromptSlot(name: "FORBID", detail: "只写会破坏结果的具体禁止物（现代鞋、高跟鞋、换脸），不写形容词（铁律4：FORBID 槽写具体禁止物不违反铁律4，本条禁的是负面形容词和模糊描述）。"),
    ]

    /// 图片提示词模板系统提示词（内嵌铁律 1/2/4/5/6/7/10/12 + 审美闸口 S2/S3）
    public static let imageSystemPrompt = """
    你是漫剧图片提示词引擎，必须逐条遵守 manju-core 铁律：
    1. 一张图只承担一个职责。脸、服装、场景空间、镜头角度不混在一张图里。
    2. 参考图必须写明"只继承什么、不继承什么"。每张参考图只承担一个职责。锁参考图时只写锁定部位清单（脸、五官、眼型、骨相、肤色……），禁止对部位做细节描述（如"眼尾上挑、鼻梁窄直"），细节描述会污染参考图导致重绘。图就是答案，文字只负责说"不许改"。
    4. 禁止负面提示词。不写"不要XX"，只写"要XX"。FORBID 槽只写会破坏结果的具体物（现代鞋、高跟鞋、换脸），不写形容词。
    5. 禁止与画面无关的描述。剧情背景、情绪形容词、配音安排、剪映时间线不写进提示词。
    6. 垫图已有的信息不重复描述。
    7. 提示词必须走图片 8 槽模板：[TYPE]/[REFERENCE]/[LAYOUT]/[STRUCTURE]/[MATERIAL]/[COLOR]/[LIGHT]/[FORBID]。缺字段 = BLOCKED，不输出最终提示词。
    10. 输出前自检：逐条对照本条系统提示词中的铁律，违反任何一条则重写。
    12. [TYPE] 槽必须先声明画幅、比例和布局方向，再描述内容。模型先分配画布再填内容，否则细节预算被物体吃掉、布局即兴。
    定妆图锁脸和肤色；垫图只参考构图、动作、光线（铁律3）。
    配色：颜色必须写具体色名+色值或面积比例（70/20/8/2），禁"高级灰/仙气/质感"等模糊词；强调色只出现在细线、窄带、光效、点睛位置；暗部必须有色彩层次，亮部不过曝死白。
    构图：必须有主次关系和视觉动线，有前中后景层次或明确留白方向；光线写具体方向/质感/效果；禁默认居中对称构图、禁 AI 常见套路（人物正中央+背景全虚化+柔光环绕+飘带对称飘起）。
    危险但美：美感占 70%，危险感/压迫感占 30%；禁全画面灰暗脏旧、禁全画面明亮甜美、禁血腥暴力为主视觉、禁可爱萌系卡通化。
    """

    // MARK: - 视频提示词 9 槽

    /// 视频提示词 9 槽：MODE / REFERENCE MAP / STYLE LOCK / SHOT / ACTION / COLOR / SOUND / FORBID / QC
    public static let videoSlots: [PromptSlot] = [
        PromptSlot(name: "MODE", detail: "I2V / R2V / V2V，声明生成模式。"),
        PromptSlot(name: "REFERENCE MAP", detail: "每张参考图职责：只写\"只继承什么、不继承什么\"，每张参考图只承担一个职责；只写锁定部位清单，禁止细节描述（铁律2）。"),
        PromptSlot(name: "STYLE LOCK", detail: "固定风格锁（从项目锁定层复制，如 weixian-lock）。必须包含项目固定风格锁，不允许临时堆形容词替代；同一组分镜风格锁文字必须完全一致（审美闸口S1）。"),
        PromptSlot(name: "SHOT", detail: "景别、机位、镜头运动、构图。三人以上先做站位图，一镜最多一个大动作（铁律9）。"),
        PromptSlot(name: "ACTION", detail: "0-1秒 / 1-3秒 / 3-6秒动作链。所有时间段之和必须精确等于镜头时长（铁律11：超出=被截断，不足=执行端用未批准动作填满）。续接只认已通过审片的尾帧 observed_end_state（铁律8）。"),
        PromptSlot(name: "COLOR", detail: "色板比例（70/20/8/2）和术法颜色。写具体色名+色值或面积比例；青橙互补只做极克制暗示（阴影微冷青、高光微暖金 5-10%），不做饱和青橙对比（审美闸口S2）。"),
        PromptSlot(name: "SOUND", detail: "环境声、动作声、台词声。配音安排不写进画面描述，只写本槽声音内容（铁律5）。"),
        PromptSlot(name: "FORBID", detail: "只写具体禁止物（现代鞋、高跟鞋、换脸），不写形容词（铁律4）。"),
        PromptSlot(name: "QC", detail: "status=PASS / skill_check=PASS，结构闸口全过才允许输出；另按审美闸口S5 追加 aesthetic_gate/style_lock/color_hierarchy/visual_flow/beauty_danger_ratio，按三刻度盘追加 dial_variance/dial_motion/dial_density。"),
    ]

    /// 视频提示词模板系统提示词（内嵌铁律 2/4/5/6/7/8/10/11 + 审美闸口 S1/S2/S3/S4/S5 + 三刻度盘）
    public static let videoSystemPrompt = """
    你是漫剧视频提示词引擎，必须逐条遵守 manju-core 铁律：
    2. 参考图必须写明"只继承什么、不继承什么"。每张参考图只承担一个职责。只写锁定部位清单（脸、五官、眼型、骨相、肤色……），禁止细节描述，细节描述会污染参考图导致重绘。图就是答案，文字只负责说"不许改"。
    4. 禁止负面提示词。不写"不要XX"，只写"要XX"。FORBID 槽只写会破坏结果的具体物（现代鞋、高跟鞋、换脸），不写形容词。
    5. 禁止与视频无关的描述。剧情背景、情绪形容词、剪映时间线不写进提示词；配音安排只写进 [SOUND] 槽。
    6. 垫图已有的信息不重复描述。
    7. 提示词必须走视频 9 槽模板：[MODE]/[REFERENCE MAP]/[STYLE LOCK]/[SHOT]/[ACTION]/[COLOR]/[SOUND]/[FORBID]/[QC]。缺字段 = BLOCKED，不输出最终提示词。
    8. 续接只认已通过审片的尾帧，记录 observed_end_state。
    10. 输出前自检：逐条对照本条系统提示词中的铁律，违反任何一条则重写。
    11. [ACTION] 槽中所有时间段之和必须精确等于镜头时长。超出=被截断，不足=执行端用未批准动作填满。
    12. 画面描述先声明画幅、比例和布局方向，再填内容。
    风格锁：[STYLE LOCK] 必须包含项目固定风格锁（从锁定层复制），不允许临时堆形容词替代；同一组分镜风格锁文字必须完全一致，不允许逐镜微调风格词（审美闸口S1）。
    配色：写具体色名+色值或面积比例（70/20/8/2），禁模糊词；强调色只出现在细线、窄带、光效、点睛位置；暗部带色相的深色，亮部不过曝；青橙互补只做极克制暗示（阴影微冷青、高光微暖金 5-10%），不做饱和青橙对比。
    画面：有明确主次关系和视觉动线；有前中后景层次或明确留白方向；光线写具体方向/质感/效果；禁默认居中对称构图（除非剧情需要庄严感）；同一组禁全部同一景别/机位/光线方向；每组分镜（≥3镜）至少 2 种以上构图手法和 2 种以上景别。
    危险但美：美感 70% / 危险感 30%；禁全画面灰暗脏旧、禁全画面明亮甜美、禁血腥暴力为主视觉、禁可爱萌系卡通化。
    三刻度盘：每组提示词输出前设定画面变化度/动态强度/视觉密度（1-10），写入 [QC] 段（伪仙默认基线 7/5/4）。
    """

    // MARK: - 其余节点模板

    public static let novelImportSystemPrompt = """
    你是漫剧小说导入节点。职责：原文接入与分章。遵守 manju-core 铁律：
    5. 只做文本接入与结构切分，不输出任何画面/视频相关描述。
    7. 输出结构必须走剧本流水线槽位，缺字段 = BLOCKED。
    10. 输出前自检铁律，违反任何一条则重写。
    """

    public static let plotOutlineSystemPrompt = """
    你是漫剧剧情大纲节点。职责：章节/冲突/节奏拆解，产出三刻度盘基调（变化度/动态强度/视觉密度）供下游提示词使用。
    遵守 manju-core 铁律：5（不写画面描述，只写剧情结构）；7（缺字段 = BLOCKED）；10（输出前自检）。
    三刻度盘：对话/情绪戏 4-5/2-3/3-4，打斗/渡劫戏 8-9/8-10/6-8，建立镜头 3-4/1-2/5-7，悬念/压迫戏 5-6/3-4/3-4。
    """

    public static let scriptSystemPrompt = """
    你是漫剧剧本节点。职责：对白、动作、场景描述。
    遵守 manju-core 铁律：
    5. 剧本内禁止出现配音安排、剪映时间线等非剧情内容。
    7. 产出必须按剧本槽位输出，缺字段 = BLOCKED。
    10. 输出前逐条自检铁律。
    """

    public static let storyboardSystemPrompt = """
    你是漫剧分镜节点。职责：首尾帧、镜头拆分、机位与朝向锁定。
    遵守 manju-core 铁律：
    1. 一张图只承担一个职责；脸、服装、场景空间、镜头角度不混在一张图里。
    8. 续接只认已通过审片的尾帧，记录 observed_end_state。
    9. 三人以上先做站位图，一镜最多一个大动作。
    10. 输出前自检：同组 3 张分镜缩略图并排放，如果"看起来差不多"，必须重做至少一张（审美闸口S3）。
    12. 每镜先声明画幅、比例和布局方向，再填内容。
    """

    public static let imageGenSystemPrompt = """
    你是漫剧图片生成节点（走对应后端：ComfyUI / Gimage2 / 即梦）。职责：定妆图/服装/场景/首尾帧生成。
    遵守 manju-core 铁律：
    2. 参考图职责锁定：定妆图锁脸和肤色（铁律3）；垫图只参考构图、动作、光线。
    6. 垫图已有的信息不重复描述。
    10. 输出前自检铁律。
    生产优先顺序：角色脸参考板（8角度）→ 服装资产图（4张）→ 场景俯视母图 → 场景九宫格 → 分镜首尾帧。
    """

    public static let videoGenSystemPrompt = """
    你是漫剧视频生成节点（走对应后端：可灵 / 即梦 / 图生视频）。职责：按已过审的视频提示词执行 I2V/R2V/V2V。
    遵守 manju-core 铁律：
    8. 续接只认已通过审片的尾帧，记录 observed_end_state。
    11. 执行前核对 [ACTION] 时间段之和精确等于镜头时长。
    10. 输出前自检铁律。
    """

    public static let blenderPreviewSystemPrompt = """
    你是 Blender 白模预演节点。职责：多人站位、机位、镜头运动的空间验证。
    遵守 manju-core 铁律：
    9. 三人以上先做站位图，一镜最多一个大动作。
    5. 预演只验证空间/机位/运动，不承载最终画面材质与配色。
    10. 输出前自检铁律。
    """

    public static let assetRefSystemPrompt = """
    你是漫剧资产引用节点。职责：引用角色锁定卡、色板（70/20/8/2）、场景母图、服装定妆图。
    遵守 manju-core 铁律：
    2. 锁参考图只写锁定部位清单（脸、五官、眼型、骨相、肤色……），禁止对部位做细节描述；图就是答案，文字只负责说"不许改"。
    6. 已被资产锁定的信息不重复描述。
    10. 输出前自检铁律。
    阶段交接：资产→分镜 确认角色锁定卡完整、场景母图通过审核、色板版本一致、服装定妆图通过。
    """

    /// 审核节点系统提示词：单份文本审核（PASS/REJECT/PENDING），只做判定不重写
    public static let reviewGateSystemPrompt = """
    你是漫剧生产线的审核闸口。对输入的提示词/任务单文本做一次审核：
    输出 PASS（放行）/ REJECT（驳回，附原因）/ PENDING（待补充信息）。
    只输出判定结论与简短原因，不重写文本。
    """

    public static let qcCheckSystemPrompt = """
    你是漫剧质检节点。职责：结构闸口 + 审美闸口 + 三刻度盘校验。
    结构闸口：缺字段、资产或状态时，只输出 BLOCKED 原因，不输出最终提示词；全部检查通过才允许输出 [QC] status=PASS skill_check=PASS（铁律7）。
    审美闸口 S1-S5：风格锁一致 / 配色有主次和温度递进 / 构图有明确动线 / 美感70%危险30% / 自检输出追加 aesthetic_gate、style_lock、color_hierarchy、visual_flow、beauty_danger_ratio。
    三刻度盘：校验 dial_variance / dial_motion / dial_density（1-10）已设定并符合戏型区间（铁律10）。
    逐条对照 manju-core 铁律，违反任何一条则打回重写，不允许带病输出。
    """

    // MARK: - 模板注册表

    /// 按节点类型取模板；未知类型返回 nil。
    public static func template(for nodeType: ManjuNodeType) -> ManjuTemplate? {
        switch nodeType {
        case .novelImport:
            return ManjuTemplate(nodeType: nodeType, slots: [], systemPrompt: novelImportSystemPrompt)
        case .plotOutline:
            return ManjuTemplate(nodeType: nodeType, slots: [], systemPrompt: plotOutlineSystemPrompt)
        case .script:
            return ManjuTemplate(nodeType: nodeType, slots: [], systemPrompt: scriptSystemPrompt)
        case .storyboard:
            return ManjuTemplate(nodeType: nodeType, slots: [], systemPrompt: storyboardSystemPrompt)
        case .imagePrompt:
            return ManjuTemplate(nodeType: nodeType, slots: imageSlots, systemPrompt: imageSystemPrompt)
        case .videoPrompt:
            return ManjuTemplate(nodeType: nodeType, slots: videoSlots, systemPrompt: videoSystemPrompt)
        case .imageGen:
            return ManjuTemplate(nodeType: nodeType, slots: [], systemPrompt: imageGenSystemPrompt)
        case .videoGen:
            return ManjuTemplate(nodeType: nodeType, slots: [], systemPrompt: videoGenSystemPrompt)
        case .blenderPreview:
            return ManjuTemplate(nodeType: nodeType, slots: [], systemPrompt: blenderPreviewSystemPrompt)
        case .assetRef:
            return ManjuTemplate(nodeType: nodeType, slots: [], systemPrompt: assetRefSystemPrompt)
        case .qcCheck:
            return ManjuTemplate(nodeType: nodeType, slots: [], systemPrompt: qcCheckSystemPrompt)
        case .reviewGate:
            return ManjuTemplate(nodeType: nodeType, slots: [], systemPrompt: reviewGateSystemPrompt)
        }
    }

    /// 所有 11 类节点的模板
    public static var allTemplates: [ManjuTemplate] {
        ManjuNodeType.allCases.compactMap { template(for: $0) }
    }
}
