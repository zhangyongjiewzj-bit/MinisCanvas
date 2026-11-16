import Foundation
import Observation
import MinisCore

/// A presentation of an existing, completed assistant message. The transcript
/// remains the plan's sole durable source; this state holds no tool authority.
struct PlanApprovalProposal: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let markdown: String
    let contextMessageID: UUID
}

enum PlanApprovalDecision: Equatable {
    case approveAutoEdit
    case approveManual
    case continuePlanning

    var approvedMode: ComposerTaskMode? {
        switch self {
        case .approveAutoEdit: return .autoEdit
        case .approveManual: return .manual
        case .continuePlanning: return nil
        }
    }

}

@MainActor
@Observable
final class PlanApprovalCoordinator {
    private var proposals: [UUID: PlanApprovalProposal] = [:]

    func proposal(for sessionID: UUID) -> PlanApprovalProposal? {
        proposals[sessionID]
    }

    /// Only the successful turn owner calls this after committing its final
    /// assistant message. Model prose cannot request an approval-mode change.
    @discardableResult
    func offer(sessionID: UUID, message: ChatMessageUI,
               snapshot: ComposerSubmissionSnapshot) -> Bool {
        guard snapshot.mode == .plan, snapshot.sessionID == sessionID.uuidString,
              message.role == .assistant, !message.isStreaming, !message.wasInterrupted,
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        proposals[sessionID] = PlanApprovalProposal(
            id: message.id, sessionID: sessionID, markdown: message.content, contextMessageID: message.id)
        return true
    }

    /// A refused send can leave its visible failure transcript intact. Bind
    /// the restored original plan to that exact tail, never future messages.
    func restoreAfterRejectedSubmission(_ proposal: PlanApprovalProposal, contextMessageID: UUID) {
        guard proposals[proposal.sessionID] == proposal else { return }
        proposals[proposal.sessionID] = PlanApprovalProposal(id: proposal.id,
            sessionID: proposal.sessionID, markdown: proposal.markdown, contextMessageID: contextMessageID)
    }

    @discardableResult
    func dismiss(_ proposal: PlanApprovalProposal) -> Bool {
        guard proposals[proposal.sessionID] == proposal else { return false }
        proposals.removeValue(forKey: proposal.sessionID)
        return true
    }
}
