import Foundation
import CanvasCore

// MARK: - 任务单（M1f）

/// 任务单：生图/生视频节点执行后产出的结构化「提示词工作单」。
///
/// 背景：用户没有即梦/可灵 API key（网页版会员），生图/生视频走"任务单模式"——
/// 节点产出完整提示词任务单 → 用户复制到网页版手动生成 → 结果文件拖回画布（导入结果）。
///
/// 铁律遵守：
/// - 提示词必须来自 ManjuPromptTemplates（图片 8 槽 / 视频 9 槽完整），缺字段 = BLOCKED；
///   上游提示词节点尚未产出完整槽位文本时，用资产锁定槽位（`slot.<槽名>` 参数）兜底拼装，
///   缺失槽位标「（待填）」，保证任务单结构完整可复制。
/// - FORBID 段单独标注（铁律4：只写具体禁止物，不写形容词）。
/// - 参考图只写锁定清单（铁律2：每张参考图只承担一个职责，只写锁定部位清单）。
/// - 视频任务单（9 槽）：额外导出 MODE（I2V/R2V/V2V）与 ACTION 时段总和 = 镜头时长校验
///   提示（铁律11：超出=被截断，不足=执行端用未批准动作填满）。
///
/// 槽位解析/拼装/参考图提取/时段校验逻辑下沉在 CanvasCore 的 ManjuTicketParser（可单测），
/// 本类型做薄封装并承载导出格式。
struct JobTicket: Codable, Equatable, Sendable {

    /// 任务单槽位段：槽名 + 内容（保持模板顺序）
    struct SlotSection: Codable, Equatable, Sendable, Hashable {
        var name: String
        var content: String
    }

    /// 节点类型（ManjuNodeType.rawValue，如 imageGen / videoGen）
    var nodeType: String
    /// 节点标题（如「生图」）
    var nodeTitle: String
    /// 完整提示词（图片 8 槽 / 视频 9 槽全文，含 FORBID 段）
    var prompt: String
    /// FORBID 段单独标注（铁律4）
    var forbid: String
    /// 模型建议（如 即梦 Seedance / 可灵）
    var suggestedPlatform: String
    /// 参考图锁定清单（asset:// 资产 ID / 本地文件路径）
    var referenceImages: [String]
    /// 生成时间
    var timestamp: Date
    /// 槽位数（8 = 图片 / 9 = 视频）
    var slotCount: Int
    /// 顺序槽位段（供 UI 分段展示）
    var slots: [SlotSection]
    /// 是否为占位任务单（上游提示词节点未产出完整槽位文本，用资产锁定槽位兜底）
    var isFallback: Bool
    /// 视频任务单：生成模式（[MODE] 槽内容，I2V/R2V/V2V；图片任务单为 nil）
    var mode: String?
    /// 视频任务单：ACTION 时段总和 = 镜头时长校验提示（铁律11；图片任务单为 nil）
    var durationNote: String?

    // MARK: - 构造

    /// 从节点 + 上游提示词文本/资产锁定槽位构建任务单。
    /// - Parameters:
    ///   - node: 生图/生视频节点
    ///   - template: 槽位模板（图片 8 槽 / 视频 9 槽）
    ///   - promptText: 上游提示词节点输出文本（可为 nil；含槽位标记时优先使用）
    ///   - fallbackParams: 兜底参数（`slot.<槽名>` = 资产锁定文本，来自上游提示词节点 backendConfig）
    ///   - referenceImages: 参考图锁定清单（由调用方从提示词/上游资产节点提取）
    static func make(
        node: CanvasNode,
        template: ManjuTemplate,
        promptText: String?,
        fallbackParams: [String: String],
        referenceImages: [String]
    ) -> JobTicket {
        let isFallback: Bool
        let fullPrompt: String
        if let text = promptText, !text.isEmpty, !parseSlots(text, template: template).isEmpty {
            // 上游已产出完整槽位提示词 → 原样采用（铁律7：缺字段 = BLOCKED，不在此处补）
            fullPrompt = text
            isFallback = false
        } else {
            // 兜底：资产锁定槽位 + 模板槽名拼装（占位任务单，缺槽标「（待填）」）
            fullPrompt = buildPrompt(from: template, params: fallbackParams)
            isFallback = true
        }
        let sections = parseSlots(fullPrompt, template: template)
        let forbid = sections.first { $0.name == "FORBID" }?.content ?? ""
        // 视频任务单（9 槽）：MODE + ACTION 时段校验（铁律11）
        let hasModeSlot = template.slots.contains { $0.name == "MODE" }
        let mode: String? = hasModeSlot ? ManjuTicketParser.mode(from: fullPrompt) : nil
        let hasActionSlot = template.slots.contains { $0.name == "ACTION" }
        let durationNote: String? = hasActionSlot
            ? ManjuTicketParser.actionDurationNote(
                actionText: sections.first { $0.name == "ACTION" }?.content ?? "",
                shotDurationSeconds: ManjuTicketParser.shotDurationSeconds(
                    from: node.backendConfig?.params["duration"]
                )
            )
            : nil
        return JobTicket(
            nodeType: node.type,
            nodeTitle: node.title,
            prompt: fullPrompt,
            forbid: forbid,
            suggestedPlatform: suggestedPlatform(nodeType: node.type, modelID: node.backendConfig?.modelID),
            referenceImages: referenceImages,
            timestamp: Date(),
            slotCount: template.slots.count,
            slots: sections,
            isFallback: isFallback,
            mode: mode,
            durationNote: durationNote
        )
    }

    // MARK: - 槽位解析

    /// 解析提示词中的 `[槽名]` 分段（按模板槽位顺序，内容取到下一槽标记前）。
    /// 只认模板中的槽名，避免把正文里的方括号误判为槽位。逻辑下沉 CanvasCore.ManjuTicketParser。
    static func parseSlots(_ text: String, template: ManjuTemplate) -> [SlotSection] {
        ManjuTicketParser.parseSlots(text, template: template)
            .map { SlotSection(name: $0.name, content: $0.content) }
    }

    /// 从模板槽位 + 参数拼装完整提示词（缺槽标「（待填）」，保持 8/9 槽结构完整）。
    static func buildPrompt(from template: ManjuTemplate, params: [String: String]) -> String {
        ManjuTicketParser.buildPrompt(from: template, params: params)
    }

    // MARK: - 参考图提取

    /// 从提示词文本提取参考图锁定清单（`参考图：X` / `母图：X` / `垫图：X` 后紧跟的资产 ID）。
    /// 只提取锁定清单（铁律2），不解析任何部位细节描述。逻辑下沉 CanvasCore.ManjuTicketParser。
    static func extractReferenceIDs(from text: String) -> [String] {
        ManjuTicketParser.extractReferenceIDs(from: text)
    }

    // MARK: - 模型建议

    /// 按节点后端配置推断建议平台；未命中时按节点类型给默认建议。
    static func suggestedPlatform(nodeType: String, modelID: String?) -> String {
        let id = modelID ?? ""
        if id.contains("kling") { return "可灵（网页版）" }
        if id.contains("seedance") { return "即梦 Seedance（网页版）" }
        if id.contains("seedream") { return "即梦 Seedream（网页版）" }
        if id.contains("gimage") { return "Gimage2（或即梦网页版）" }
        if nodeType == ManjuNodeType.imageGen.rawValue { return "即梦 Seedream（网页版）" }
        return "即梦 Seedance / 可灵（网页版）"
    }

    // MARK: - 导出

    /// 复制用：完整提示词全文（一键复制按钮的复制内容）。
    var copyableText: String { prompt }

    /// 导出 Markdown：完整提示词 + FORBID 段 + 参考图锁定清单 + 铁律说明。
    var markdown: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        lines.append("# 生成任务单 · \(nodeTitle)")
        lines.append("")
        lines.append("| 字段 | 值 |")
        lines.append("| --- | --- |")
        lines.append("| 节点 | \(nodeTitle)（\(nodeType)） |")
        lines.append("| 生成时间 | \(dateFormatter.string(from: timestamp)) |")
        lines.append("| 建议平台 | \(suggestedPlatform) |")
        lines.append("| 槽位数 | \(slotCount) 槽 |")
        if let mode {
            lines.append("| 生成模式 | \(mode)（\(slotCount == 9 ? "视频 9 槽" : "图片 8 槽" )） |")
        }
        if isFallback {
            lines.append("| 状态 | ⚠️ 占位任务单（上游提示词节点尚未产出完整槽位文本，标「（待填）」处需手动补全或先执行上游节点） |")
        }
        lines.append("")
        lines.append("## 参考图锁定清单（铁律2：每张参考图只承担一个职责）")
        if referenceImages.isEmpty {
            lines.append("- （无锁定参考图）")
        } else {
            for ref in referenceImages {
                lines.append("- \(ref)")
            }
        }
        lines.append("")
        if let durationNote {
            lines.append("## ACTION 时段校验（铁律11：所有时间段之和必须精确等于镜头时长）")
            lines.append("")
            lines.append(durationNote)
            lines.append("")
        }
        lines.append("## 完整提示词（\(slotCount) 槽，复制到网页版逐槽粘贴）")
        lines.append("")
        lines.append("```text")
        lines.append(prompt)
        lines.append("```")
        lines.append("")
        lines.append("## FORBID 段（铁律4：只写具体禁止物，不写形容词）")
        lines.append("")
        if forbid.isEmpty {
            lines.append("（无）")
        } else {
            lines.append(forbid)
        }
        lines.append("")
        lines.append("## 使用说明（任务单模式）")
        lines.append("")
        lines.append("1. 将「完整提示词」复制到 \(suggestedPlatform) 网页版，按槽位顺序逐槽粘贴。")
        lines.append("2. 参考图按锁定清单上传，每张图只承担一个职责（只继承、不继承），禁止追加部位细节描述（铁律2）。")
        lines.append("3. 生成完成后，把结果文件拖回画布对应节点，点击「导入结果」回填。")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
