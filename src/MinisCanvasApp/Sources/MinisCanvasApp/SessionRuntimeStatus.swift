import Foundation
import MinisCore

/// Canonical runtime facts plus the exact live approval card, never another ledger.
enum SessionRuntimeStatus: Equatable, Sendable {
    case running
    case waitingApproval
    case needsReview
    case interrupted

    var title: String {
        switch self {
        case .running: "运行中"
        case .waitingApproval: "等待审批"
        case .needsReview: "需复核"
        case .interrupted: "已中断"
        }
    }

    var helpText: String {
        switch self {
        case .running: "该会话正在执行当前回合"
        case .waitingApproval: "该会话有工具操作等待你的审批"
        case .needsReview: "该会话的工具执行结果尚未结算，需要复核"
        case .interrupted: "该会话的回合或审批已中断"
        }
    }

    static func project(
        sessionID: UUID,
        execution: ChatStore.ExecutionSnapshot?,
        events: [MinisCore.ConversationEvent],
        terminalOutcome: ChatRunTerminalOutcome? = nil,
        liveReview: ApprovalReviewPresentation? = nil
    ) -> Self? {
        let (current, terminal, unsettled) = currentEvents(sessionID: sessionID, execution: execution, events: events)
        if unsettled.contains(where: { $0.status == .needsReview }) { return .needsReview }
        if terminalOutcome == .cancelled { return .interrupted }
        if terminalOutcome == .succeeded || terminalOutcome == .failed { return nil }
        if let liveReview, liveReview.matchesCurrentExecution(execution?.executionIdentity),
           unsettled.filter({ liveReview.matches($0) }).count == 1 { return .needsReview }
        if unsettled.contains(where: { $0.kind == .approval && $0.status == .waiting }) { return .waitingApproval }
        if execution?.state == .running { return .running }
        if terminal?.status == .stopped || terminal?.status == .cancelled { return .interrupted }
        if let last = current.max(by: { $0.sequence < $1.sequence }),
           last.kind == .approval, last.approvalDecision == .interrupted { return .interrupted }
        return nil
    }

    static func reviewExplanation(
        sessionID: UUID, execution: ChatStore.ExecutionSnapshot?, events: [MinisCore.ConversationEvent],
        terminalOutcome: ChatRunTerminalOutcome?, liveReview: ApprovalReviewPresentation?
    ) -> String? {
        guard terminalOutcome == nil, let liveReview,
              liveReview.matchesCurrentExecution(execution?.executionIdentity) else { return nil }
        let (_, _, unsettled) = currentEvents(sessionID: sessionID, execution: execution, events: events)
        guard unsettled.filter({ liveReview.matches($0) }).count == 1 else { return nil }
        return ApprovalReviewPresentation.explanation
    }

    private static func currentEvents(
        sessionID: UUID, execution: ChatStore.ExecutionSnapshot?, events: [MinisCore.ConversationEvent]
    ) -> (current: [MinisCore.ConversationEvent], terminal: MinisCore.ConversationEvent?, unsettled: [MinisCore.ConversationEvent]) {
        let sessionEvents = events.filter { UUID(uuidString: $0.identity.sessionID) == sessionID }
        let turn = execution?.turnID.map(String.init)
            ?? sessionEvents.max(by: { $0.sequence < $1.sequence })?.identity.turnID
        let current = sessionEvents.filter { $0.identity.turnID == turn }
        let terminal = current.filter {
            ($0.kind == .task || $0.kind == .stop) && $0.status.isTerminal
        }.max(by: { $0.sequence < $1.sequence })
        let unsettled = current.filter { $0.sequence > (terminal?.sequence ?? -1) }
        return (current, terminal, unsettled)
    }
}
