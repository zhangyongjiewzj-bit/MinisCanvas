import Foundation

/// 面向用户/调试者的健康诊断入口（对标 Codex 桌面端 `doctor` 命令）。
///
/// ```swift
/// let report = await Doctor.doctor()
/// print(Doctor.humanReadableText(report))
/// let json = try Doctor.json(report)   // pretty JSON
/// ```
public enum Doctor {
    /// 用默认诊断器跑一轮完整检查。
    public static func doctor(runner: DiagnosticRunner = DiagnosticRunner()) async -> HealthReport {
        await runner.runAll()
    }

    /// 人类可读文本报告（分维度分组，按状态着色提示）。
    public static func humanReadableText(_ report: HealthReport) -> String {
        let overall = report.summary.overall
        var lines: [String] = [
            "MinisCanvas 健康诊断（\(Self.timestampText(report.timestamp))）",
            "整体状态: \(Self.statusLabel(overall))"
            + "  [ok \(report.summary.okCount) / warning \(report.summary.warningCount)"
            + " / error \(report.summary.errorCount)]",
            "",
        ]
        for category in HealthCategory.allCases {
            let items = report.items(in: category)
            lines.append("== " + category.displayName + " ==")
            if items.isEmpty {
                lines.append("（无条目）")
            } else {
                for item in items {
                    let marker = Self.statusMarker(item.status)
                    var line = marker + " [" + item.status.rawValue + "] " + item.name + ": " + item.message
                    if !item.details.isEmpty {
                        line += "（" + item.details.joined(separator: "；") + "）"
                    }
                    lines.append(line)
                }
            }
            lines.append("")
        }
        if report.items.isEmpty {
            lines.append("（没有可检查的项）")
        }
        return lines.joined(separator: "\n")
    }

    /// JSON 序列化（pretty printed，`JSONEncoder.dateEncodingStrategy = .iso8601`）。
    public static func jsonData(_ report: HealthReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    /// JSON 字符串（UTF-8）。
    public static func json(_ report: HealthReport) throws -> String {
        let data = try jsonData(report)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 文本辅助

    private static func timestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func statusLabel(_ status: HealthStatus) -> String {
        switch status {
        case .ok: return "✅ 健康"
        case .warning: return "⚠️ 有警告"
        case .error: return "❌ 存在问题"
        }
    }

    private static func statusMarker(_ status: HealthStatus) -> String {
        switch status {
        case .ok: return "✅"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}
