import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-06 state-changing Composer gate")
@MainActor
struct P3AcceptanceM05ApprovalGateTests {
    @Test func commandsWithoutExecutorsRejectBeforeAnApprovalCard() {
        let workspaceID = "m05-approval"
        let revision = "m05-approval-policy"
        let epoch = "m05-approval-epoch"
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: workspaceID,
            revision: revision,
            grantEpoch: epoch,
            leaseID: "m05-approval-lease",
            expiresAt: Date().addingTimeInterval(600),
            revoked: false
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: "m05-approval-session",
            turnID: 1,
            taskID: "chat:m05-approval-session:1:attempt",
            workspaceID: workspaceID,
            createdAt: Date(),
            policyRevision: revision,
            grantEpoch: epoch
        )
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let parser = CommandParser()
        let center = ComposerCommandAdjudicationCenter()
        var pendingTerminalEvents: [ComposerCommandAdjudicationCenter.Resolution] = []
        center.onPendingTerminalResolution = { pendingTerminalEvents.append($0) }

        for id in ["boundary.set", "provider.use", "approve", "memory.propose", "canvas.run", "workflow"] {
            let parsed = parser.parse("/\(id)", registry: registry)
            guard let request = registry.makePendingRequest(for: parsed) else {
                Issue.record("/\(id) 未生成规范请求")
                continue
            }
            #expect(request.requiresPolicyApproval)
            #expect(center.evaluate(request: request, snapshot: snapshot, facts: facts) == .reject)
            #expect(center.lastResolution?.id == request.id)
            if id == "boundary.set" {
                let reason = "暂不可用，请在设置→智能体调整最高模式。"
                #expect(center.lastResolution?.outcome == .unavailableExecutor(reason))
                #expect(center.projection?.text == reason)
            } else {
                #expect(center.lastResolution?.outcome == .unavailableExecutor(
                    "当前没有已接线的生产执行入口"
                ))
                #expect(center.projection?.text.contains("/\(id) 无法执行") == true)
            }
            #expect(center.pendingAdjudication == nil)
            #expect(pendingTerminalEvents.isEmpty)
        }
    }

    @Test func genuinePendingTerminalsEmitTheOriginalRequestIDExactlyOnce() {
        let now = Date()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: "m05-terminal", revision: "m05-policy", grantEpoch: "m05-epoch",
            leaseID: "m05-lease", expiresAt: now.addingTimeInterval(600), revoked: false
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: "m05-session", turnID: 1, taskID: "chat:m05-session:1:attempt",
            workspaceID: "m05-terminal", createdAt: now,
            policyRevision: "m05-policy", grantEpoch: "m05-epoch"
        )
        let center = ComposerCommandAdjudicationCenter()
        var events: [ComposerCommandAdjudicationCenter.Resolution] = []
        center.onPendingTerminalResolution = { events.append($0) }

        let denied = PendingCommandRequest(
            id: UUID(), commandID: "compact", requiresPolicyApproval: true
        )
        #expect(center.evaluate(request: denied, snapshot: snapshot, facts: facts) == .pending)
        center.denyCurrentAdjudication()
        center.denyCurrentAdjudication()
        #expect(events.map(\.id) == [denied.id])
        #expect(events.last?.outcome == .deniedByUser)

        let expired = PendingCommandRequest(
            id: UUID(), commandID: "compact", requiresPolicyApproval: true
        )
        #expect(center.evaluate(request: expired, snapshot: snapshot, facts: facts) == .pending)
        center.expireCurrentAdjudication()
        center.expireCurrentAdjudication()
        #expect(events.map(\.id) == [denied.id, expired.id])
        #expect(events.last?.outcome == .expiredUnanswered)

        let superseded = PendingCommandRequest(
            id: UUID(), commandID: "compact", requiresPolicyApproval: true
        )
        let replacement = PendingCommandRequest(
            id: UUID(), commandID: "compact", requiresPolicyApproval: true
        )
        #expect(center.evaluate(request: superseded, snapshot: snapshot, facts: facts) == .pending)
        #expect(center.evaluate(request: replacement, snapshot: snapshot, facts: facts) == .pending)
        #expect(events.map(\.id) == [denied.id, expired.id, superseded.id])
        #expect(events.last?.outcome == .supersededByNewCommand)
        #expect(center.pendingAdjudication?.id == replacement.id)
        center.denyCurrentAdjudication()
        #expect(events.map(\.id) == [denied.id, expired.id, superseded.id, replacement.id])

        var settingsOpenCount = 0
        // H1 canonicalSettingsCommandIDs admits settings.open/settings.reset;
        // model uses the separate N05 desktop picker route.
        center.openCanonicalSettings = { settingsOpenCount += 1 }
        let settings = PendingCommandRequest(
            id: UUID(), commandID: "settings.open", requiresPolicyApproval: true
        )
        #expect(center.evaluate(request: settings, snapshot: snapshot, facts: facts) == .pending)
        #expect(center.pendingAdjudication?.id == settings.id)
        #expect(center.pendingAdjudication?.commandID == "settings.open")
        #expect(settingsOpenCount == 0)
        #expect(center.approveCurrentAdjudication())
        #expect(center.pendingAdjudication == nil)
        #expect(events.map(\.id) == [denied.id, expired.id, superseded.id, replacement.id, settings.id])
        #expect(events.last?.id == settings.id)
        #expect(events.last?.outcome == .handedToCanonicalSettings)
        #expect(settingsOpenCount == 1)
        #expect(!center.approveCurrentAdjudication())
        #expect(events.filter { $0.id == settings.id }.count == 1)
        #expect(settingsOpenCount == 1)
    }

    @Test func restoredUnsupportedPendingRejectsWithItsOriginalIDOnlyOnce() {
        let center = ComposerCommandAdjudicationCenter()
        let request = PendingCommandRequest(
            id: UUID(), commandID: "canvas.run", requiresPolicyApproval: true
        )
        var events: [ComposerCommandAdjudicationCenter.Resolution] = []
        center.onPendingTerminalResolution = { events.append($0) }

        center.adoptRestoredPending(request, sessionID: "restored-session")
        #expect(center.pendingAdjudication == nil)
        #expect(center.lastResolution?.id == request.id)
        #expect(center.lastResolution?.sessionID == "restored-session")
        #expect(center.lastResolution?.outcome == .unavailableExecutor(
            "当前没有已接线的生产执行入口"
        ))
        #expect(center.projection?.text.contains("原待批准请求已拒绝") == true)
        #expect(events.map(\.id) == [request.id])

        center.adoptRestoredPending(request, sessionID: "restored-session")
        #expect(events.map(\.id) == [request.id])
        #expect(center.pendingAdjudication == nil)
    }

    @Test func policyFactsStillTakePrecedenceOverExecutorAvailability() {
        let now = Date()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: "m05-policy-first", revision: "rev", grantEpoch: "epoch",
            leaseID: "lease", expiresAt: now.addingTimeInterval(600), revoked: true
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: "m05-session", turnID: 1, taskID: "chat:m05-session:1:attempt",
            workspaceID: "m05-policy-first", createdAt: now,
            policyRevision: "rev", grantEpoch: "epoch"
        )
        let center = ComposerCommandAdjudicationCenter()
        let request = PendingCommandRequest(
            id: UUID(), commandID: "canvas.run", requiresPolicyApproval: true
        )

        #expect(center.evaluate(request: request, snapshot: snapshot, facts: facts) == .reject)
        #expect(center.lastResolution?.outcome == .rejectedByPolicy("策略租约已吊销"))
        #expect(center.pendingAdjudication == nil)
    }
}
