import Foundation
import MinisCore

extension ChatStore {
    /// N01's successful-stream completion hook supplies the frozen policy of
    /// that exact turn, never a mutable global/latest submission snapshot.
    func offerCompletedPlan(sessionID: UUID, messageID: UUID,
                            snapshot: ComposerSubmissionSnapshot) {
        guard !isCanonicalWriteIsolated(sessionID),
              let message = messages(forSession: sessionID)?.last(where: { $0.role != .system }),
              message.id == messageID else { return }
        planApproval.offer(sessionID: sessionID, message: message, snapshot: snapshot)
    }

    var activePlanApproval: PlanApprovalProposal? {
        guard let sessionID = activeSessionID,
              let proposal = planApproval.proposal(for: sessionID),
              let history = messages(forSession: sessionID),
              history.last(where: { $0.role != .system })?.id == proposal.contextMessageID,
              let message = history.first(where: { $0.id == proposal.id }), message.role == .assistant,
              !message.isStreaming, !message.wasInterrupted,
              message.content == proposal.markdown else { return nil }
        return proposal
    }

    /// This is the existing Composer eligibility projection. The executor will
    /// still mint a new snapshot and apply its full safety chain on submission.
    func planApprovalDisabledReason(for mode: ComposerTaskMode, allowsCeilingConfirmation: Bool = false) -> String? {
        guard activePlanApproval != nil else { return "计划已更新，请重新规划" }
        guard composerPolicySelection.mode == .plan else { return "当前已离开计划模式" }
        guard !isActiveSessionGenerating,
              !isComposerCredentialPreflightPending,
              !isComposerAttachmentPreflightPending else { return "请等待当前回合结束" }
        guard activeQueuedComposerMessages.isEmpty else { return "请先处理待发送队列" }
        guard !isCanonicalWriteIsolated(activeSessionID) else { return "会话已从磁盘更新，请重新打开应用" }
        guard ComposerModeAvailability.isEnabled(mode, ceiling: composerPolicyFacts.autonomyCeiling)
                || (allowsCeilingConfirmation && composerPolicyFacts.autonomyCeiling != nil) else {
            return ComposerModeAvailability.explanation(mode, ceiling: composerPolicyFacts.autonomyCeiling)
        }
        guard draftText.isEmpty, pendingAttachments.isEmpty, activePastedTextDrafts.isEmpty,
              editingMessageID == nil else { return "请先发送或清空当前草稿" }
        return nil
    }

    func requestPlanApproval(_ decision: PlanApprovalDecision, proposalID: UUID, owner: UUID) async {
        guard activePlanApproval?.id == proposalID else { return }
        if let mode = decision.approvedMode,
           let ceiling = composerPolicyFacts.autonomyCeiling, mode.requiredAutonomyLevel > ceiling {
            guard planApprovalDisabledReason(for: mode, allowsCeilingConfirmation: true) == nil else { return }
            selectInteractiveComposerMode(mode, owner: owner, proposalID: proposalID)
            return
        }
        cancelComposerCeilingRequest(owner: owner)
        _ = await resolvePlanApproval(decision, proposalID: proposalID)
    }

    func confirmPlanApprovalCeiling(proposalID: UUID, owner: UUID) async {
        guard composerCeilingRequest?.proposalID == proposalID, activePlanApproval?.id == proposalID,
              planApprovalDisabledReason(for: .autoEdit, allowsCeilingConfirmation: true) == nil,
              await confirmComposerCeilingRequest(owner: owner) else { return }
        _ = await resolvePlanApproval(.approveAutoEdit, proposalID: proposalID)
    }

    @discardableResult
    func resolvePlanApproval(_ decision: PlanApprovalDecision, proposalID: UUID) async -> Bool {
        guard let proposal = activePlanApproval, proposal.id == proposalID,
              composerPolicySelection.mode == .plan,
              !isActiveSessionGenerating,
              !isComposerCredentialPreflightPending,
              !isComposerAttachmentPreflightPending,
              !isCanonicalWriteIsolated(proposal.sessionID) else { return false }
        guard let mode = decision.approvedMode else {
            // No execution turn and no transcript rewrite: the user can refine
            // the plan in the normal Composer while its policy remains plan.
            return planApproval.dismiss(proposal)
        }
        guard planApprovalDisabledReason(for: mode) == nil else { return false }
        let originalSelection = composerPolicySelection
        var selection = originalSelection
        selection.mode = mode
        selection.bypassModeConfirmed = false
        composerPolicySelection = selection
        draftText = "我批准上述计划，请开始执行。"
        let accepted = await submitComposerAwaitingAdmission(literal: true, userInitiated: true)
        if accepted {
            _ = planApproval.dismiss(proposal)
        } else {
            // Do not overwrite a newer explicit mode selection or newer plan.
            if composerPolicySelection == selection { composerPolicySelection = originalSelection }
            if let tail = messages(forSession: proposal.sessionID)?.last(where: { $0.role != .system }) {
                planApproval.restoreAfterRejectedSubmission(proposal, contextMessageID: tail.id)
            }
        }
        return accepted
    }

    /// One entry for N05's registered /plan command. Running commands continue
    /// to use O06's queue before invoking this API; this method never queues.
    @discardableResult
    func enterPlanMode(description: String? = nil) -> Bool {
        guard !isActiveSessionGenerating,
              !isComposerCredentialPreflightPending,
              !isComposerAttachmentPreflightPending,
              !isCanonicalWriteIsolated(activeSessionID),
              ComposerModeAvailability.isEnabled(.plan, ceiling: composerPolicyFacts.autonomyCeiling) else { return false }
        let task = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !task.isEmpty {
            guard draftText.isEmpty, pendingAttachments.isEmpty,
                  activePastedTextDrafts.isEmpty, editingMessageID == nil else { return false }
        }
        var selection = composerPolicySelection
        selection.mode = .plan
        selection.bypassModeConfirmed = false
        composerPolicySelection = selection
        if !task.isEmpty {
            draftText = task
            submitLiteralComposer()
        }
        return true
    }
}
