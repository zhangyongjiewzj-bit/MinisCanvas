import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("N16 existing approval card carries the complete skill diff")
@MainActor
struct N16SkillDiffApprovalTests {
    @Test func skillDiffWaitsForTheCurrentUserAndRetainsItsTail() async throws {
        let center = ApprovalPromptCenter()
        center.rememberSameKindInSession = true
        center.persistAllowSelected = true
        let text = (0..<900).map { "+ owned skill line \($0)" }.joined(separator: "\n") + "\n+ N16_COMPLETE_DIFF_TAIL"
        let diff = FileChangeDiffPayload(diffID: "owned-display-reference", path: "skills/owned/SKILL.md",
            unifiedDiff: text, insertions: 901, deletions: 0)
        var request = ApprovalRequest(id: "n16-owned-ui", toolName: "skill_update",
            inputSummary: "skillID: owned", riskLevel: .medium, requiresApproval: true,
            sessionID: "owned-session", turnID: 1, taskID: "owned-task", attemptID: "owned-attempt",
            approvalScope: "workspace", composerMode: ComposerTaskMode.bypassPermission.rawValue,
            messageID: "owned-message", policyRevision: "owned-policy", grantEpoch: "owned-epoch",
            inputDigest: "owned-input-digest", identityDigest: "owned-identity-digest")
        request.skillDiff = diff
        let pending = Task { await center.present(request) }
        for _ in 0..<200 where center.pendingRequest == nil { await Task.yield() }
        let shown = try #require(center.pendingRequest)
        #expect(shown.skillDiff?.unifiedDiff.hasSuffix("+ N16_COMPLETE_DIFF_TAIL") == true)
        #expect((shown.skillDiff?.unifiedDiff.utf8.count ?? 0) > 4096)
        #expect(shown.persistentAllowOffer == nil)
        center.approvePending()
        let decision = await pending.value
        #expect(decision.approved && decision.confirmed)
        #expect(decision.requestID == request.requestID)
        #expect(!decision.persistAllow)
    }
    @Test func dismissingTheCurrentSkillApprovalRejectsWithoutChangingContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n16-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let old = "---\nname: n16-cancel\ndescription: owned cancellation fixture\n---\n旧正文保持逐字一致"
        _ = try store.importSkill(content: old)
        let skillFile = store.skillDirectoryURL(for: "n16-cancel").appendingPathComponent("SKILL.md")
        let original = try Data(contentsOf: skillFile)
        let originalReceipt = store.lifecycleReceipt(for: "n16-cancel")
        let now = Date()
        let facts = ComposerPolicyFactSource(knownCapabilities: SkillMaintenanceTool.names,
            grantedCapabilities: SkillMaintenanceTool.names, allowedWriteRoots: [root.path],
            workspaceID: "owned-cancel-workspace", revision: "owned-revision", grantEpoch: "owned-epoch",
            leaseID: "owned-lease", expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3)
        let snapshot = ComposerSubmissionSnapshot(mode: .bypassPermission, approvalScope: .request,
            effort: .standard, sessionID: "owned-cancel-session", turnID: 1, taskID: "owned-cancel-task",
            messageID: "owned-cancel-message", workspaceID: facts.workspaceID, createdAt: now,
            policyRevision: facts.revision, grantEpoch: facts.grantEpoch,
            bypassModeConfirmed: true, autonomyCeiling: .l3)
        let center = ApprovalPromptCenter()
        let maintenance = SkillMaintenanceTool(store: store)
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: BuiltinToolExecutor(allowedRoot: root, skillMaintenance: maintenance),
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: ApprovalGate(delegate: ApprovalPromptDelegate(center: center)), skillMaintenance: maintenance)
        // Synchronize with the existing production lifecycle notification,
        // rather than treating a number of scheduler yields as presentation.
        let presentation = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        center.onPendingRequestChanged = { requestID, _ in
            if requestID != nil { presentation.continuation.yield(()) }
        }
        // Construct the non-Sendable Foundation dictionary on its single
        // nonisolated worker; only the immutable String and executor cross in.
        let pending = Task.detached { [executor, old, continuation = presentation.continuation] in
            // An authorization that terminates before presentation closes the
            // stream, so the unchanged pending oracle still fails without a hang.
            defer { continuation.finish() }
            let input: [String: Any] = ["skillID": "n16-cancel", "expectedContentHash": SkillManifest.hash(old),
                "content": "---\nname: n16-cancel\ndescription: owned cancellation fixture\n---\n不应写入的新正文"]
            return try await executor.authorizeExecution(callID: "owned-cancel-call", name: "skill_update", input: input)
        }
        defer {
            center.onPendingRequestChanged = nil
            pending.cancel()
            presentation.continuation.finish()
        }
        var events = presentation.stream.makeAsyncIterator()
        _ = await events.next()
        _ = try #require(center.pendingRequest)
        center.dismissPending()
        #expect(center.lastDiagnostic?.code == .cancelled)
        await #expect(throws: (any Error).self) { _ = try await pending.value }
        #expect(try Data(contentsOf: skillFile) == original)
        #expect(store.lifecycleReceipt(for: "n16-cancel") == originalReceipt)
    }

}
