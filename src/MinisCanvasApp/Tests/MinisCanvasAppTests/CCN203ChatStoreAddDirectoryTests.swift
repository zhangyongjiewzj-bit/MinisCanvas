import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("N2-03 ChatStore add-dir approval handoff")
@MainActor struct CCN203ChatStoreAddDirectoryTests {
    @Test func typedDirectoryCommandFreezesPathBeforeTranscriptAndResolvesOnlyItsRequest() throws {
        let chat = ChatStore()
        let before = chat.messages
        var handedRequest: PendingCommandRequest?
        var handedSnapshot: ComposerSubmissionSnapshot?
        chat.onComposerCommandPolicy = { request, snapshot in
            handedRequest = request
            handedSnapshot = snapshot
            return .pending
        }
        chat.draftText = "/add-dir /synthetic/project directory"
        chat.submitComposer()
        let request = try #require(handedRequest)
        let snapshot = try #require(handedSnapshot)
        #expect(request.commandID == "add-dir")
        #expect(request.args["path"] == "/synthetic/project directory")
        #expect(request.requiresPolicyApproval)
        #expect(snapshot.sessionID == chat.activeSessionID?.uuidString)
        #expect(chat.pendingComposerCommand == request)
        #expect(chat.lastComposerCommandReceipt?.requestID == request.id)
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(chat.messages == before)
        #expect(!chat.resolvePendingComposerCommand(requestID: UUID(), disposition: .execute))
        #expect(!chat.resolvePendingComposerCommand(requestID: request.id, disposition: .pending))
        #expect(chat.pendingComposerCommand == request)
        #expect(chat.resolvePendingComposerCommand(requestID: request.id, disposition: .execute))
        #expect(chat.pendingComposerCommand == nil)
        #expect(!chat.resolvePendingComposerCommand(requestID: request.id, disposition: .execute))
        #expect(chat.messages == before)
    }

    private func wireCenter(_ chat: ChatStore, _ center: ComposerCommandAdjudicationCenter) {
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "n203", grantEpoch: "n203-epoch",
            leaseID: "n203-lease", expiresAt: Date().addingTimeInterval(600), revoked: false, autonomyCeiling: .l3))
        chat.onComposerCommandPolicy = { request, snapshot in
            center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        center.onPendingTerminalResolution = { resolution in
            let disposition: ComposerCommandPolicyDecision
            switch resolution.outcome {
            case .approvedExecuted, .handedToCanonicalSettings: disposition = .execute
            case .deniedByUser, .expiredUnanswered, .supersededByNewCommand,
                 .rejectedByPolicy(_), .unavailableExecutor(_): disposition = .reject
            }
            _ = chat.resolvePendingComposerCommand(requestID: resolution.id, disposition: disposition)
        }
        // This fixture tests the real Center/ChatStore seam with a synthetic
        // producer. It does not claim Bridge directory enforcement or grants.
        center.prepareAdditionalDirectory = { request, snapshot, facts in
            .init(request: request, snapshot: snapshot, facts: facts,
                physicalDirectory: URL(fileURLWithPath: request.args["path"]!),
                directoryIdentity: "synthetic-device:inode", projectID: "synthetic-project",
                workingDirectory: "/synthetic/project", attachmentGeneration: 1)
        }
    }

    @Test func keyboardBypassHandsDirectoryToOriginalExecutorAndChecksReceipt() throws {
        for matchingReceipt in [true, false] {
            let chat = ChatStore()
            chat.applyNewSession()
            let center = ComposerCommandAdjudicationCenter()
            wireCenter(chat, center)
            chat.composerPolicySelection.mode = .bypassPermission
            #expect(chat.confirmComposerBypass(for: chat.activeSessionID))
            var applyCount = 0
            center.applyApprovedAdditionalDirectory = { context in
                applyCount += 1
                #expect(chat.pendingComposerCommand == context.request)
                return .init(requestID: matchingReceipt ? context.request.id : UUID(),
                    sessionID: context.snapshot.sessionID, path: context.physicalDirectory.path)
            }
            chat.draftText = "/add-dir /synthetic/approved directory"
            chat.submitComposerFromKeyboard()
            #expect(applyCount == 1)
            #expect(chat.lastComposerCommandReceipt?.disposition == (matchingReceipt ? .execute : .reject))
            #expect(chat.pendingComposerCommand == nil && center.pendingAdjudication == nil)
        }
    }

    @Test func realCenterApprovesFrozenRequestOnceAndChecksReceiptIdentity() throws {
        for matchingReceipt in [true, false] {
            let chat = ChatStore()
            let center = ComposerCommandAdjudicationCenter()
            wireCenter(chat, center)
            var applyCount = 0
            center.applyApprovedAdditionalDirectory = { context in
                applyCount += 1
                #expect(chat.pendingComposerCommand == context.request)
                #expect(context.snapshot.sessionID == chat.activeSessionID?.uuidString)
                return .init(requestID: matchingReceipt ? context.request.id : UUID(),
                    sessionID: context.snapshot.sessionID, path: context.physicalDirectory.path)
            }
            let before = chat.messages
            chat.draftText = "/add-dir /synthetic/approved directory"
            chat.submitComposer()
            let request = try #require(chat.pendingComposerCommand)
            #expect(applyCount == 0)
            #expect(center.pendingAdjudication?.id == request.id)
            #expect(center.approveCurrentAdjudication() == matchingReceipt)
            #expect(applyCount == 1)
            #expect(chat.pendingComposerCommand == nil)
            #expect(center.pendingAdjudication == nil)
            #expect(!center.approveCurrentAdjudication())
            #expect(applyCount == 1)
            if matchingReceipt {
                #expect(center.lastResolution?.outcome == .approvedExecuted)
            } else {
                #expect(center.lastResolution?.outcome != .approvedExecuted)
            }
            #expect(chat.messages == before)
        }
    }

    @Test func producerStaleRejectionDenialAndExpiryNeverReportApproval() throws {
        for terminal in ["stale", "deny", "expire"] {
            let chat = ChatStore()
            let center = ComposerCommandAdjudicationCenter()
            wireCenter(chat, center)
            var applyCount = 0
            center.applyApprovedAdditionalDirectory = { _ in
                applyCount += 1
                throw CommandExecutionError.disabled(commandID: "add-dir", reason: "synthetic stale producer context")
            }
            chat.draftText = "/add-dir /synthetic/target"
            chat.submitComposer()
            _ = try #require(chat.pendingComposerCommand)
            if terminal == "stale" { #expect(!center.approveCurrentAdjudication()) }
            else if terminal == "deny" { center.denyCurrentAdjudication() }
            else { center.expireCurrentAdjudication() }
            #expect(applyCount == (terminal == "stale" ? 1 : 0))
            #expect(chat.pendingComposerCommand == nil)
            #expect(center.pendingAdjudication == nil)
            #expect(center.lastResolution?.outcome != .approvedExecuted)
            #expect(!center.approveCurrentAdjudication())
        }
    }

    @Test func policyPreparationFailureIsBoundedAndSurvivesSlashGuard() {
        let chat = ChatStore()
        let before = chat.messages
        chat.prepareTopLevelTaskPolicy = { _, _, _, _ in
            chat.reportTaskPolicyPreparationFailure("目录身份已改变 " + String(repeating: "x", count: 800))
            return false
        }
        chat.draftText = "/add-dir /synthetic/target"
        chat.submitComposer()
        #expect(chat.pastedTextActionFeedback?.hasPrefix("任务策略准备失败：目录身份已改变") == true)
        #expect((chat.pastedTextActionFeedback?.count ?? 0) <= 522)
        #expect(chat.messages == before)
        #expect(chat.pendingComposerCommand == nil)
    }

    @Test func ordinaryPolicyFailureBubbleUsesThisAttemptReasonInsteadOfOldFeedback() {
        for suppliesReason in [true, false] {
            let chat = ChatStore()
            chat.streamingProviderOverride = MockProvider.shared
            chat.reportTaskPolicyPreparationFailure("旧的无关粘贴提示")
            #expect(chat.pastedTextActionFeedback?.contains("旧的无关粘贴提示") == true)
            var calls = 0
            chat.prepareTopLevelTaskPolicy = { _, _, _, _ in
                calls += 1
                #expect(chat.pastedTextActionFeedback == nil)
                if suppliesReason { chat.reportTaskPolicyPreparationFailure("本次目录身份已改变") }
                return false
            }
            chat.draftText = "synthetic ordinary message"
            chat.submitComposer()
            #expect(calls == 1)
            let bubble = chat.messages.last?.content ?? ""
            #expect(bubble == (suppliesReason ? "任务策略准备失败：本次目录身份已改变" : "任务策略不可用，本次未向模型发送请求。"))
            #expect(!bubble.contains("旧的无关粘贴提示"))
            #expect(!chat.isActiveSessionGenerating)
        }
    }

    @Test func missingPathDoesNotReachApprovalAndMissingConsumerRejects() {
        let chat = ChatStore()
        var policyCalls = 0
        chat.onComposerCommandPolicy = { _, _ in policyCalls += 1; return .pending }
        chat.draftText = "/add-dir"
        chat.submitComposer()
        #expect(policyCalls == 0)
        #expect(chat.composerCommandValidationFailure != nil)
        #expect(chat.pendingComposerCommand == nil)
        chat.onComposerCommandPolicy = nil
        chat.draftText = "/add-dir /synthetic/project"
        chat.submitComposer()
        #expect(chat.lastComposerCommandReceipt?.commandID == "add-dir")
        #expect(chat.lastComposerCommandReceipt?.disposition == .reject)
        #expect(chat.pendingComposerCommand == nil)
    }
}
