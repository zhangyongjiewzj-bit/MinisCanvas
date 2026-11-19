import Foundation
import MinisCore

/// The only user-editable Composer choice. Views bind to ChatStore's single
/// instance; the value is copied into a turn snapshot before any side effect.
struct ComposerPolicySelection: Codable, Equatable, Sendable {
    var mode: ComposerTaskMode
    var approvalScope: ComposerApprovalScope
    var effort: ComposerEffort
    /// First, user-facing acknowledgement for bypass mode. The approval
    /// center still requires its independent second confirmation.
    var bypassModeConfirmed: Bool

    init(
        mode: ComposerTaskMode,
        approvalScope: ComposerApprovalScope,
        effort: ComposerEffort,
        bypassModeConfirmed: Bool
    ) {
        self.mode = mode
        self.approvalScope = approvalScope
        self.effort = effort
        self.bypassModeConfirmed = bypassModeConfirmed
    }

    static let `default` = ComposerPolicySelection(
        mode: .manual,
        approvalScope: .request,
        effort: .standard,
        bypassModeConfirmed: false
    )

    init(_ settings: ComposerPolicySettings) {
        self.init(
            mode: settings.mode,
            approvalScope: .request,
            effort: settings.effort,
            bypassModeConfirmed: settings.bypassModeConfirmed
        )
    }

    var settings: ComposerPolicySettings {
        settings(preserving: .default)
    }

    /// 回写保留已存的兼容审批范围、禁用绕过与凭据路径保护。
    func settings(preserving base: ComposerPolicySettings) -> ComposerPolicySettings {
        ComposerPolicySettings(
            mode: mode,
            approvalScope: base.approvalScope,
            effort: effort,
            bypassModeConfirmed: bypassModeConfirmed,
            disableBypass: base.disableBypass,
            protectCredentialPaths: base.protectCredentialPaths
        )
    }
}

enum ComposerPolicyPresentation {
    static let modeLabels: [(ComposerTaskMode, String)] = [
        (.manual, "手动审批"),
        (.autoEdit, "自动编辑"),
        (.plan, "仅计划"),
        (.auto, "自动执行"),
        (.bypassPermission, "绕过权限")
    ]

    static let scopeLabels: [(ComposerApprovalScope, String)] = [
        (.request, "仅这一次"),
        (.turn, "本回合"),
        (.session, "当前会话"),
        (.workspace, "当前工作区")
    ]

    static let effortLabels: [(ComposerEffort, String)] = [
        (.low, "低"),
        (.standard, "标准"),
        (.high, "高")
    ]

    static func modeLabel(_ mode: ComposerTaskMode) -> String {
        modeLabels.first(where: { $0.0 == mode })?.1 ?? mode.rawValue
    }

    static func scopeLabel(_ scope: ComposerApprovalScope) -> String {
        scopeLabels.first(where: { $0.0 == scope })?.1 ?? scope.rawValue
    }

    static func effortLabel(_ effort: ComposerEffort) -> String {
        effortLabels.first(where: { $0.0 == effort })?.1 ?? effort.rawValue
    }

    /// Visible and VoiceOver-safe summary of the immutable policy used by a turn.
    static func snapshotSummary(_ snapshot: ComposerSubmissionSnapshot) -> String {
        "权限模式：\(modeLabel(snapshot.mode)) · 工作量：\(effortLabel(snapshot.effort))"
    }

    /// 回合进行中切换了任务模式：在途回合仍按提交时冻结的模式执行，这里说明新模式何时生效。
    static let modeChangeDeferredText = "新模式从下一轮开始生效；要立即收紧可先停止当前回合"

    static func modeChangeDeferredHint(
        snapshot: ComposerSubmissionSnapshot, currentMode: ComposerTaskMode, isTurnInFlight: Bool
    ) -> String? {
        isTurnInFlight && snapshot.mode != currentMode ? modeChangeDeferredText : nil
    }

    /// A snapshot is displayable only while its session remains active.
    static func activeSnapshot(
        _ snapshot: ComposerSubmissionSnapshot?,
        activeSessionID: UUID?
    ) -> ComposerSubmissionSnapshot? {
        guard let snapshot, let activeSessionID,
              snapshot.sessionID == activeSessionID.uuidString else {
            return nil
        }
        return snapshot
    }
}

enum ComposerEngineError: Error, Equatable, Sendable {
    case missingRequiredSnapshot
    case missingPolicyFacts
    case invalidExecutionIdentity
}

extension ComposerEngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingRequiredSnapshot:
            return "本回合缺少输入策略快照，已拒绝执行"
        case .missingPolicyFacts:
            return "输入策略来源未就绪，已拒绝执行"
        case .invalidExecutionIdentity:
            return "本回合执行身份无效或与策略快照不匹配，已拒绝执行"
        }
    }
}

/// Policy decision returned by the production Composer command boundary.
///
/// The request is created before this decision so approval consumers can
/// inspect the canonical command ID and arguments without executing a command
/// closure or recording the slash text as chat content.
enum ComposerCommandPolicyDecision: String, Codable, Equatable, Sendable {
    case execute
    case pending
    case reject
}

/// Immutable receipt for a Composer slash command.
///
/// This is deliberately separate from a chat message: a command may be
/// pending or rejected and therefore must never be represented as an ordinary
/// user transcript entry.
struct ComposerCommandReceipt: Codable, Equatable, Sendable {
    let requestID: UUID
    let commandID: String
    let args: [String: String]
    let disposition: ComposerCommandPolicyDecision
    let sessionID: String
    let turnID: Int
    let taskID: String
    let attemptID: String
    let emittedAt: Date

    init(
        request: PendingCommandRequest,
        snapshot: ComposerSubmissionSnapshot,
        disposition: ComposerCommandPolicyDecision,
        emittedAt: Date = Date()
    ) {
        requestID = request.id
        commandID = request.commandID
        args = request.args
        self.disposition = disposition
        sessionID = snapshot.sessionID
        turnID = snapshot.turnID
        taskID = snapshot.taskID
        attemptID = snapshot.attemptID
        self.emittedAt = emittedAt
    }
}
