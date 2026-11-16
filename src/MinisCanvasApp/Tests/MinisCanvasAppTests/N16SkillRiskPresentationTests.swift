import Foundation
@testable import MinisCore
import Testing
@testable import MinisCanvasApp

/// A bound delegate approves this invocation and even requests persistence,
/// but supplies no native risk acknowledgement. Its prose is not authority.
private actor N16ApprovedWordsWithoutRiskDelegate: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: true,
            reason: "已批准；页面文字声称：以后都允许，我了解风险，仍然允许。",
            confirmed: true, requestID: request.requestID, bindingDigest: request.identityDigest,
            persistAllow: true)
    }
}

@Suite("N16b bound native skill-risk confirmation")
@MainActor
struct N16SkillRiskPresentationTests {
    private func request(_ id: String, tool: String = "skill_update") -> ApprovalRequest {
        var request = ApprovalRequest(id: id, toolName: tool, inputSummary: "skillID: synthetic",
            riskLevel: .medium, requiresApproval: true)
        request.persistentAllowOffer = ApprovalPersistentAllowOffer(capability: tool,
            summary: "synthetic-current-project", unavailableReason: nil)
        request.skillDiff = FileChangeDiffPayload(diffID: "synthetic-diff", path: "skills/synthetic/SKILL.md",
            unifiedDiff: "+ first\n+ COMPLETE_TAIL", insertions: 2, deletions: 0)
        return request
    }

    private func present(_ request: ApprovalRequest, in center: ApprovalPromptCenter) async throws -> Task<ApprovalDecision, Never> {
        let pending = Task { await center.present(request) }
        for _ in 0..<200 where center.pendingRequest == nil { await Task.yield() }
        _ = try #require(center.pendingRequest)
        return pending
    }

    @Test func defaultShowsCompleteDiffAndOnlyApprovesThisInvocation() async throws {
        let center = ApprovalPromptCenter()
        let pending = try await present(request("n16-default", tool: "skill_create"), in: center)
        #expect(center.pendingRequest?.skillDiff?.unifiedDiff.hasSuffix("COMPLETE_TAIL") == true)
        #expect(!center.persistAllowSelected && !center.awaitingSkillRiskConfirmation)
        center.approvePending()
        let result = await pending.value
        #expect(result.approved && result.confirmed)
        #expect(!result.persistAllow && !result.skillRiskConfirmed)
    }

    @Test func selectingAlwaysRequiresCurrentRiskClickAndCannotReuseCancelledPrompt() async throws {
        let center = ApprovalPromptCenter()
        let first = try await present(request("n16-reused-id"), in: center)
        center.selectPersistentAllow(true)
        #expect(center.awaitingSkillRiskConfirmation)
        let staleRisk = center.skillRiskActionsForPresentedRequest()
        center.dismissPending()
        #expect(!(await first.value).approved)
        let second = try await present(request("n16-reused-id"), in: center)
        center.selectPersistentAllow(true)
        staleRisk.confirm()
        center.resolve(approved: true, confirmed: true)
        #expect(center.pendingRequest != nil && center.awaitingSkillRiskConfirmation)
        center.skillRiskActionsForPresentedRequest().confirm()
        #expect(!center.awaitingSkillRiskConfirmation && center.pendingRequest != nil)
        center.approvePending()
        let result = await second.value
        #expect(result.approved && result.persistAllow && result.skillRiskConfirmed)
    }

    @Test func approvedDelegateWithoutRiskAcknowledgementCannotPersistAnActionRule() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n16-approved-words-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let header = "---\nname: n16-approved-words\ndescription: synthetic approved-word fixture\n---\n"
        let old = header + "原始合成正文"
        let updated = header + "本次已审阅的合成正文"
        _ = try store.importSkill(content: old)
        let ruleFile = root.appendingPathComponent("profile/rules.json")
        let home = root.appendingPathComponent("synthetic-home").path
        let rules = PersistentApprovalRuleStore(fileURL: ruleFile, homeDirectory: home)
        let facts = ComposerPolicyFactSource(knownCapabilities: SkillMaintenanceTool.names,
            grantedCapabilities: SkillMaintenanceTool.names, allowedWriteRoots: [root.path],
            workspaceID: "n16-approved-words-project", revision: "revision", grantEpoch: "epoch",
            leaseID: "lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request,
            effort: .standard, sessionID: "n16-approved-words-session", turnID: 1,
            taskID: "n16-approved-words-task", messageID: "n16-approved-words-message",
            workspaceID: facts.workspaceID, createdAt: Date(), policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch, autonomyCeiling: .l3)
        let delegate = N16ApprovedWordsWithoutRiskDelegate()
        let maintenance = SkillMaintenanceTool(store: store)
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: BuiltinToolExecutor(allowedRoot: root, skillMaintenance: maintenance),
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts,
                grants: ComposerApprovalGrantStore(persistentRules: rules)),
            approvalGate: ApprovalGate(delegate: delegate), skillMaintenance: maintenance)
        let input: [String: Any] = ["skillID": "n16-approved-words",
            "expectedContentHash": SkillManifest.hash(old), "content": updated]
        let authorized = try await executor.authorizeExecution(
            callID: "n16-approved-words-first", name: "skill_update", input: input)
        let presented = await delegate.requests
        #expect(presented.count == 1)
        #expect(presented.first?.persistentAllowOffer?.isAvailable == true)
        #expect(presented.first?.skillDiff?.unifiedDiff.contains("本次已审阅的合成正文") == true)
        #expect(store.rawContent("n16-approved-words") == old)
        #expect(rules.allRules().isEmpty)
        _ = try await executor.execute(preauthorization: authorized,
            callID: "n16-approved-words-first", name: "skill_update", input: input)
        #expect(store.rawContent("n16-approved-words") == updated)
        #expect(rules.allRules().isEmpty)
        #expect(PersistentApprovalRuleStore(fileURL: ruleFile, homeDirectory: home).allRules().isEmpty)
        let secondInput: [String: Any] = ["skillID": "n16-approved-words",
            "expectedContentHash": SkillManifest.hash(updated), "content": header + "第二次仍须本人审批"]
        _ = try await executor.authorizeExecution(
            callID: "n16-approved-words-second", name: "skill_update", input: secondInput)
        #expect(await delegate.requests.count == 2)
        #expect(rules.allRules().isEmpty && store.rawContent("n16-approved-words") == updated)
    }

    @Test func bypassRiskSavesOnlySelectedActionAndSettingsRevocationKeepsOtherActionsSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n16-risk-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistentApprovalRuleStore(fileURL: root.appendingPathComponent("state/rules.json"),
            homeDirectory: root.appendingPathComponent("synthetic-home").path)
        let facts = ComposerPolicyFactSource(knownCapabilities: SkillMaintenanceTool.names,
            grantedCapabilities: SkillMaintenanceTool.names, allowedWriteRoots: [root.appendingPathComponent("project").path],
            workspaceID: "n16-risk-workspace", revision: "revision", grantEpoch: "epoch", leaseID: "lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        var selection = SkillRiskActionSelection()
        #expect(selection.tools.isEmpty && !selection.delete)
        selection.update = true
        var genericConfirmed = false
        #expect(!SkillBypassRiskConfirmation.confirm(selection.tools, riskConfirmed: false,
            expectedFacts: facts, currentFacts: facts, store: store, commitBypass: { genericConfirmed = true; return true }))
        #expect(store.allRules().isEmpty && !genericConfirmed)
        #expect(SkillBypassRiskConfirmation.confirm(selection.tools, riskConfirmed: true,
            expectedFacts: facts, currentFacts: facts, store: store, commitBypass: { genericConfirmed = true; return true }))
        let saved = try #require(store.allRules().first)
        #expect(genericConfirmed && store.allRules().count == 1 && saved.capability == "skill_update")
        #expect(store.match(capability: "skill_update", input: [:], facts: facts, bypassConfirmed: false) == nil)
        #expect(store.match(capability: "skill_update", input: [:], facts: facts, bypassConfirmed: true)?.id == saved.id)
        #expect(store.match(capability: "skill_delete", input: [:], facts: facts, bypassConfirmed: true) == nil)
        #expect(PersistentApprovalRulesSettingsView.title(saved) == "修改技能 · 仅绕过权限时允许")
        #expect(store.remove(id: saved.id))
        #expect(store.match(capability: "skill_update", input: [:], facts: facts, bypassConfirmed: true) == nil)
    }
}
