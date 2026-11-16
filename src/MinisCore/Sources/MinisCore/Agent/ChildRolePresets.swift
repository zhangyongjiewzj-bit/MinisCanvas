import Foundation

/// Instruction presets only. Capability, approval and model selection remain
/// owned by the existing orchestration execution boundary.
public enum ChildRolePreset: String, Codable, CaseIterable, Sendable {
    case research
    case review

    public var instructionPrefix: String {
        switch self {
        case .research:
            return """
            你承担研究角色：先核对问题前提，使用当前任务获准的来源收集证据，区分已核实事实、推断与未验证项。给出来源位置、适用范围和仍缺的证据；不要把搜索命中或旧结论当作当前事实。仅按本次任务授权行动；角色预设不授予额外工具、目录或写入权限。
            """
        case .review:
            return """
            你承担评审角色：依据本次任务的需求与实际差额检查正确性、回归和遗漏，按影响程度列出可操作的问题，附文件位置、触发条件和依据。没有可证问题时明确说明，并列出未运行的验证与剩余不确定性。仅按本次任务授权行动；角色预设不授予额外工具、目录或写入权限。
            """
        }
    }
}
