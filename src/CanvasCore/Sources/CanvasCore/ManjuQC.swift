import Foundation

// MARK: - 漫剧 QC 节点：三刻度盘校验 + 审美闸口 S1-S5（A5）
//
// 对应 ManjuPromptTemplates.qcCheckSystemPrompt 的结构闸口 / 审美闸口 / 三刻度盘：
// - 结构闸口（铁律7）：8/9 槽必须齐全、非空、非「（待填）」，缺字段 = BLOCKED
// - 三刻度盘：dial_variance（画面变化度）/ dial_motion（动态强度）/ dial_density（视觉密度），
//   取值 1-10，缺设定或越界 = FAIL；戏型区间（对话/打斗/建立/悬念）只做提示不改判
// - 审美闸口 S1-S5：风格锁一致 / 配色主次 / 构图动线 / 美感70%危险30% / 自检完整性
//
// 纯函数、确定性判定（不依赖 LLM），可在测试中稳定断言 PASS/FAIL。

/// 三刻度盘：画面变化度 / 动态强度 / 视觉密度（1-10）
public struct ManjuQCDials: Equatable, Sendable, Codable, Hashable {
    /// 画面变化度（1-10）
    public var variance: Int
    /// 动态强度（1-10）
    public var motion: Int
    /// 视觉密度（1-10）
    public var density: Int

    public init(variance: Int, motion: Int, density: Int) {
        self.variance = variance
        self.motion = motion
        self.density = density
    }

    /// 三刻度盘是否都在 1-10 合法区间
    public var isValid: Bool {
        [variance, motion, density].allSatisfy { (1...10).contains($0) }
    }

    /// 写入 [QC] 段的规范文本（与 ManjuPromptTemplates 视频模板约定一致）
    public var text: String {
        "dial_variance=\(variance) / dial_motion=\(motion) / dial_density=\(density)"
    }

    /// 伪仙默认基线（视频模板约定：7/5/4）
    public static let weixianBaseline = ManjuQCDials(variance: 7, motion: 5, density: 4)
}

/// QC 状态：PASS / FAIL
public enum ManjuQCStatus: String, Equatable, Sendable, Codable {
    case pass = "PASS"
    case fail = "FAIL"
}

/// 审美闸口单项判定（S1-S5）
public struct ManjuAestheticGateResult: Equatable, Sendable {
    /// 闸口编号，如 "S1"
    public let gate: String
    /// 闸口名，如 "风格锁一致"
    public let name: String
    public let passed: Bool
    /// 判定说明（失败时给原因）
    public let reason: String

    public init(gate: String, name: String, passed: Bool, reason: String) {
        self.gate = gate
        self.name = name
        self.passed = passed
        self.reason = reason
    }
}

/// 模板种类：图片 8 槽 / 视频 9 槽 / 未识别
public enum ManjuQCTemplateKind: String, Equatable, Sendable, Codable {
    case image8 = "图片 8 槽"
    case video9 = "视频 9 槽"
    case unknown = "未识别"

    /// 结构闸口模板（QC 判定按此模板核对槽位完整性）
    var gateTemplate: ManjuTemplate? {
        switch self {
        case .image8:
            return ManjuPromptTemplates.template(for: .imagePrompt)
        case .video9:
            return ManjuPromptTemplates.template(for: .videoPrompt)
        case .unknown:
            return nil
        }
    }
}

/// QC 判定结果：状态 + 三刻度盘 + 审美闸口 + 原因 + 报告文本
public struct ManjuQCResult: Equatable, Sendable {
    public let status: ManjuQCStatus
    public let templateKind: ManjuQCTemplateKind
    /// 缺字段槽位名（结构闸口，铁律7：缺字段 = BLOCKED）
    public let missingSlots: [String]
    /// 解析出的三刻度盘（未设定时为 nil）
    public let dials: ManjuQCDials?
    /// 三刻度盘问题（未设定 / 越界）
    public let dialIssues: [String]
    /// 戏型区间提示（不改判，仅报告）
    public let rangeAdvisory: String?
    /// 审美闸口 S1-S5 判定
    public let aestheticGates: [ManjuAestheticGateResult]
    /// 全部失败原因（结构 + 刻度盘 + 闸口），PASS 时为空
    public let reasons: [String]

    public var isPass: Bool { status == .pass }

    /// 完整报告文本（QC 节点 report 输出端口）
    public var report: String {
        var lines: [String] = []
        lines.append("# QC 检查报告")
        lines.append("")
        lines.append("状态: \(status.rawValue)")
        lines.append("模板: \(templateKind.rawValue)")
        if let dials {
            lines.append("三刻度盘: \(dials.text)")
            if dials.isValid {
                lines.append("  - 画面变化度 \(dials.variance) / 动态强度 \(dials.motion) / 视觉密度 \(dials.density)（1-10）✓")
            }
        } else {
            lines.append("三刻度盘: 未设定（缺少 dial_variance / dial_motion / dial_density）")
        }
        if let rangeAdvisory {
            lines.append("戏型区间建议: \(rangeAdvisory)")
        }
        if !missingSlots.isEmpty {
            lines.append("结构闸口: 缺字段 = BLOCKED：\(missingSlots.joined(separator: "、"))（铁律7）")
        } else {
            lines.append("结构闸口: 槽位完整 ✓")
        }
        lines.append("审美闸口:")
        for gate in aestheticGates {
            lines.append("  - \(gate.gate) \(gate.name): \(gate.passed ? "✓" : "✗ \(gate.reason)")")
        }
        if !reasons.isEmpty {
            lines.append("原因:")
            for reason in reasons {
                lines.append("  - \(reason)")
            }
        }
        lines.append("")
        lines.append("判定标准: manju-core 铁律7 结构闸口 + 审美闸口 S1-S5 + 三刻度盘（ManjuPromptTemplates.qcCheckSystemPrompt）")
        return lines.joined(separator: "\n")
    }
}

/// QC 判定器：纯函数、确定性。
public enum ManjuQCEvaluator {

    /// 判定输入文本（应为 8 槽图片提示词或 9 槽视频提示词）。
    /// 自动识别模板种类；无法识别时按结构闸口失败处理（BLOCKED）。
    public static func evaluate(prompt: String?) -> ManjuQCResult {
        guard let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return ManjuQCResult(
                status: .fail,
                templateKind: .unknown,
                missingSlots: [],
                dials: nil,
                dialIssues: ["输入为空：QC 节点需要上游提示词/结果文本"],
                rangeAdvisory: nil,
                aestheticGates: [],
                reasons: ["输入为空：QC 节点需要上游提示词/结果文本（铁律7：缺字段 = BLOCKED）"]
            )
        }

        let kind = detectTemplateKind(text)
        guard let gateTemplate = kind.gateTemplate else {
            return ManjuQCResult(
                status: .fail,
                templateKind: .unknown,
                missingSlots: [],
                dials: nil,
                dialIssues: ["未检测到 8/9 槽结构标记"],
                rangeAdvisory: nil,
                aestheticGates: [],
                reasons: ["未检测到 8/9 槽结构标记（铁律7：提示词必须走 8 槽/9 槽模板，缺字段 = BLOCKED）"]
            )
        }

        // 结构闸口（铁律7）
        let sections = ManjuTicketParser.parseSlots(text, template: gateTemplate)
        let missingSlots = gateTemplate.slots.compactMap { slot -> String? in
            let content = sections.first { $0.name == slot.name }?.content ?? ""
            let isEmpty = content.isEmpty || content == ManjuTicketParser.pendingPlaceholder
            return isEmpty ? slot.name : nil
        }

        // 三刻度盘（视频 9 槽才有 [QC] 槽；图片 8 槽无刻度盘约定，跳过校验）
        let qcContent = sections.first { $0.name == "QC" }?.content ?? ""
        var dialIssues: [String] = []
        var dials: ManjuQCDials? = nil
        if kind == .video9 {
            dials = parseDials(from: qcContent.isEmpty ? text : qcContent)
            if let dials {
                if !dials.isValid {
                    dialIssues.append("三刻度盘越界（须在 1-10）：\(dials.text)")
                }
            } else {
                dialIssues.append("缺少三刻度盘设定（dial_variance / dial_motion / dial_density，1-10）")
            }
        }

        // 戏型区间提示（不改判）
        let rangeAdvisory = sceneRangeAdvisory(for: text)

        // 审美闸口 S1-S5
        let gates = aestheticGates(for: text, sections: sections, kind: kind)

        // 汇总原因
        var reasons: [String] = []
        if !missingSlots.isEmpty {
            reasons.append("缺字段 = BLOCKED：\(missingSlots.joined(separator: "、"))（铁律7，不输出最终提示词）")
        }
        reasons.append(contentsOf: dialIssues)
        reasons.append(contentsOf: gates.filter { !$0.passed }.map { "\($0.gate) \($0.name)：\($0.reason)" })

        let status: ManjuQCStatus = missingSlots.isEmpty && dialIssues.isEmpty
            && gates.allSatisfy(\.passed) ? .pass : .fail

        return ManjuQCResult(
            status: status,
            templateKind: kind,
            missingSlots: missingSlots,
            dials: dials,
            dialIssues: dialIssues,
            rangeAdvisory: rangeAdvisory,
            aestheticGates: gates,
            reasons: reasons
        )
    }

    // MARK: - 模板识别

    /// 自动识别模板种类：视频 9 槽以独有 [QC] 槽识别（MODE 缺失也能识别并列出缺槽）；
    /// 图片 8 槽以 [TYPE] 识别。
    static func detectTemplateKind(_ text: String) -> ManjuQCTemplateKind {
        if text.contains("[QC]") { return .video9 }
        if text.contains("[TYPE]") { return .image8 }
        return .unknown
    }

    // MARK: - 三刻度盘解析

    /// 从文本解析三刻度盘：优先 `dial_variance=7` 键值对，其次 `变化度: 7` 中文写法。
    static func parseDials(from text: String) -> ManjuQCDials? {
        func value(for key: String) -> Int? {
            let pattern = "\(NSRegularExpression.escapedPattern(for: key))\\s*[:=]\\s*(\\d+)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let ns = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges == 2 else { return nil }
            return Int(ns.substring(with: match.range(at: 1)))
        }

        let variance = value(for: "dial_variance") ?? value(for: "画面变化度")
        let motion = value(for: "dial_motion") ?? value(for: "动态强度")
        let density = value(for: "dial_density") ?? value(for: "视觉密度")
        guard let variance, let motion, let density else { return nil }
        return ManjuQCDials(variance: variance, motion: motion, density: density)
    }

    // MARK: - 戏型区间提示

    /// 按戏型关键词给出三刻度盘建议区间（来自 ManjuPromptTemplates.plotOutlineSystemPrompt）。
    static func sceneRangeAdvisory(for text: String) -> String? {
        if text.contains("打斗") || text.contains("渡劫") {
            return "打斗/渡劫戏：变化度 8-9 / 动态强度 8-10 / 视觉密度 6-8"
        }
        if text.contains("悬念") || text.contains("压迫") {
            return "悬念/压迫戏：变化度 5-6 / 动态强度 3-4 / 视觉密度 3-4"
        }
        if text.contains("建立") || text.contains("空镜") || text.contains("环境") {
            return "建立镜头：变化度 3-4 / 动态强度 1-2 / 视觉密度 5-7"
        }
        if text.contains("对话") || text.contains("情绪") {
            return "对话/情绪戏：变化度 4-5 / 动态强度 2-3 / 视觉密度 3-4"
        }
        return nil
    }

    // MARK: - 审美闸口 S1-S5

    /// 审美闸口 S1-S5 判定（确定性关键词启发式）：
    /// - S1 风格锁一致：视频→[STYLE LOCK] 非空；图片→[REFERENCE] 非空
    /// - S2 配色主次：COLOR 槽含色值(#hex)或面积比例(%)
    /// - S3 构图动线：视频→[SHOT]；图片→[LAYOUT] 含主次/动线/景别/留白等结构词
    /// - S4 美感70%危险30%：全文含「美感」与「危险」
    /// - S5 自检完整性：视频→[QC] 含 aesthetic_gate 自检字段；图片→[FORBID] 非空（铁律4 具体禁止物）
    static func aestheticGates(
        for text: String,
        sections: [ManjuSlotSection],
        kind: ManjuQCTemplateKind
    ) -> [ManjuAestheticGateResult] {
        func content(_ name: String) -> String {
            sections.first { $0.name == name }?.content ?? ""
        }

        // S1 风格锁一致
        let s1Name = kind == .video9 ? "STYLE LOCK" : "REFERENCE"
        let s1 = content(s1Name)
        let s1Passed = !s1.isEmpty && s1 != ManjuTicketParser.pendingPlaceholder

        // S2 配色主次（具体色值或面积比例，禁模糊词）
        let color = content("COLOR")
        let hasHex = color.range(of: "#[0-9A-Fa-f]{3,8}", options: .regularExpression) != nil
        let hasRatio = color.contains("%") || color.contains("70/20/8/2")
        let s2Passed = hasHex || hasRatio

        // S3 构图动线
        let layoutSlot = kind == .video9 ? "SHOT" : "LAYOUT"
        let layout = content(layoutSlot)
        let flowKeywords = ["主次", "动线", "景别", "构图", "前中后", "留白", "机位"]
        let s3Passed = flowKeywords.contains { layout.contains($0) }

        // S4 美感70%危险30%
        let s4Passed = text.contains("美感") && text.contains("危险")

        // S5 自检完整性
        let s5Passed: Bool
        let s5Reason: String
        if kind == .video9 {
            let qc = content("QC")
            s5Passed = qc.contains("aesthetic_gate")
            s5Reason = "QC 槽缺少 aesthetic_gate 自检字段（审美闸口S5）"
        } else {
            let forbid = content("FORBID")
            s5Passed = !forbid.isEmpty && forbid != ManjuTicketParser.pendingPlaceholder
            s5Reason = "FORBID 槽为空（铁律4：只写具体禁止物，不写形容词）"
        }

        return [
            ManjuAestheticGateResult(
                gate: "S1", name: "风格锁一致",
                passed: s1Passed,
                reason: "\(s1Name) 槽为空，必须包含锁定清单/项目固定风格锁（审美闸口S1）"
            ),
            ManjuAestheticGateResult(
                gate: "S2", name: "配色主次",
                passed: s2Passed,
                reason: "COLOR 槽需写具体色名+色值(#hex)或面积比例(70/20/8/2)，禁模糊词（审美闸口S2）"
            ),
            ManjuAestheticGateResult(
                gate: "S3", name: "构图动线",
                passed: s3Passed,
                reason: "\(layoutSlot) 槽需有主次关系/视觉动线/景别构图等结构描述（审美闸口S3）"
            ),
            ManjuAestheticGateResult(
                gate: "S4", name: "美感70%危险30%",
                passed: s4Passed,
                reason: "未声明美感70%/危险30%（审美闸口S4，禁全画面灰暗脏旧或明亮甜美）"
            ),
            ManjuAestheticGateResult(
                gate: "S5", name: "自检完整性",
                passed: s5Passed,
                reason: s5Reason
            ),
        ]
    }
}
