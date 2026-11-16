import Foundation

// MARK: - 漫剧任务单解析器（A5：生视频任务单 9 槽完整导出支持）
//
// 槽位解析 / 拼装 / 参考图提取逻辑从 CanvasApp 的 JobTicket 下沉到 CanvasCore，
// 保证可单测；同时承载视频 9 槽特有的导出增强：
// - MODE 提取（I2V / R2V / V2V）
// - ACTION 时段总和 = 镜头时长校验提示（铁律11：超出=被截断，不足=执行端用未批准动作填满）

/// 解析出的槽位段：槽名 + 内容（保持模板顺序）
public struct ManjuSlotSection: Equatable, Sendable, Hashable, Codable {
    public var name: String
    public var content: String

    public init(name: String, content: String) {
        self.name = name
        self.content = content
    }
}

/// ACTION 槽中的一个时段段（如 0-1秒）
public struct ManjuActionSegment: Equatable, Sendable, Hashable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// 段时长（秒）
    public var duration: Double { end - start }
}

/// 任务单解析与导出工具：纯函数、无状态。
public enum ManjuTicketParser {

    /// 缺槽占位符（兜底拼装时标「（待填）」，结构完整可复制）
    public static let pendingPlaceholder = "（待填）"

    // MARK: - 槽位解析

    /// 解析提示词中的 `[槽名]` 分段（按模板槽位顺序，内容取到下一槽标记前）。
    /// 只认模板中的槽名，避免把正文里的方括号误判为槽位。
    public static func parseSlots(_ text: String, template: ManjuTemplate) -> [ManjuSlotSection] {
        var sections: [ManjuSlotSection] = []
        for (index, slot) in template.slots.enumerated() {
            let marker = "[\(slot.name)]"
            guard let range = text.range(of: marker) else { continue }
            let start = range.upperBound
            let end: String.Index
            if index + 1 < template.slots.count {
                let nextMarker = "[\(template.slots[index + 1].name)]"
                if let nextRange = text.range(of: nextMarker, range: start..<text.endIndex) {
                    end = nextRange.lowerBound
                } else {
                    end = text.endIndex
                }
            } else {
                end = text.endIndex
            }
            let content = text[start..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(ManjuSlotSection(name: slot.name, content: content))
        }
        return sections
    }

    /// 取指定槽位内容；未命中或为空返回 nil。
    public static func slotContent(_ name: String, in text: String, template: ManjuTemplate) -> String? {
        let section = parseSlots(text, template: template).first { $0.name == name }
        let content = section?.content ?? ""
        return content.isEmpty ? nil : content
    }

    /// 从模板槽位 + 参数拼装完整提示词（缺槽标「（待填）」，保持 8/9 槽结构完整）。
    public static func buildPrompt(from template: ManjuTemplate, params: [String: String]) -> String {
        template.slots.map { slot in
            let content = params[ManjuAssetInjection.slotKeyPrefix + slot.name] ?? pendingPlaceholder
            return "[\(slot.name)]\n\(content)"
        }
        .joined(separator: "\n\n")
    }

    // MARK: - 参考图提取（铁律2）

    /// 从提示词文本提取参考图锁定清单（`参考图：X` / `母图：X` / `垫图：X` 后紧跟的资产 ID）。
    /// 只提取锁定清单（铁律2），不解析任何部位细节描述；按出现顺序去重。
    public static func extractReferenceIDs(from text: String) -> [String] {
        var ids: [String] = []
        let patterns = ["参考图：([^\\s，。；;、]+)", "母图：([^\\s，。；;、]+)", "垫图：([^\\s，。；;、]+)"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where match.numberOfRanges > 1 {
                ids.append(ns.substring(with: match.range(at: 1)))
            }
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - 视频 9 槽导出增强

    /// 提取 [MODE] 槽内容（I2V / R2V / V2V）；未命中、为空或为「（待填）」返回 nil。
    public static func mode(from text: String) -> String? {
        guard let range = text.range(of: "[MODE]") else { return nil }
        let rest = text[range.upperBound...]
        let end = rest.firstIndex(of: "[") ?? rest.endIndex
        let value = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != pendingPlaceholder else { return nil }
        return value
    }

    /// 解析 ACTION 槽中的时段段（支持 `0-1秒` / `1-3秒` / `3~5秒` / `0-1s` 写法）。
    /// 只认「数字-数字」连续对，忽略形容词与说明文字。
    public static func parseActionSegments(_ actionText: String) -> [ManjuActionSegment] {
        guard let regex = try? NSRegularExpression(
            pattern: "(\\d+(?:\\.\\d+)?)\\s*[-~—]\\s*(\\d+(?:\\.\\d+)?)"
        ) else { return [] }
        let ns = actionText as NSString
        var segments: [ManjuActionSegment] = []
        for match in regex.matches(in: actionText, range: NSRange(location: 0, length: ns.length))
        where match.numberOfRanges == 3 {
            guard let start = Double(ns.substring(with: match.range(at: 1))),
                  let end = Double(ns.substring(with: match.range(at: 2))),
                  end > start else { continue }
            segments.append(ManjuActionSegment(start: start, end: end))
        }
        return segments
    }

    /// 时段总和（秒）；无时段段返回 0。
    public static func totalDuration(_ segments: [ManjuActionSegment]) -> Double {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// 从后端参数解析镜头时长秒数（支持 `5` / `5s` / `5秒` / `5.0`）。
    public static func shotDurationSeconds(from param: String?) -> Double? {
        guard let param, !param.isEmpty else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "^(\\d+(?:\\.\\d+)?)") else { return nil }
        let ns = param as NSString
        guard let match = regex.firstMatch(in: param, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 2 else { return nil }
        return Double(ns.substring(with: match.range(at: 1)))
    }

    /// 铁律11 校验提示：ACTION 时段总和 vs 镜头时长。
    /// - 未检测到时段的 ACTION 槽 → 提示需补时段
    /// - 未配置镜头时长 → 只报总和，提示人工确认
    /// - 相等 → ✓ 通过；不等 → ⚠️ 铁律11 警告（超出=被截断，不足=执行端用未批准动作填满）
    public static func actionDurationNote(actionText: String, shotDurationSeconds: Double?) -> String {
        let segments = parseActionSegments(actionText)
        guard !segments.isEmpty else {
            return "⚠️ ACTION 槽未检测到时段段（如 0-1秒 / 1-3秒 / 3-5秒）。铁律11：所有时间段之和必须精确等于镜头时长，请补全时段。"
        }
        let total = totalDuration(segments)
        guard let expected = shotDurationSeconds else {
            return "ℹ️ ACTION 时段总和 \(Self.format(total)) 秒（节点未配置镜头时长，请确认与镜头时长一致。铁律11）"
        }
        if abs(total - expected) < 0.01 {
            return "✓ ACTION 时段总和 \(Self.format(total)) 秒 = 镜头时长 \(Self.format(expected)) 秒（铁律11 通过）"
        }
        return "⚠️ ACTION 时段总和 \(Self.format(total)) 秒 ≠ 镜头时长 \(Self.format(expected)) 秒。铁律11：超出=被截断，不足=执行端用未批准动作填满，请修正时段。"
    }

    private static func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}
