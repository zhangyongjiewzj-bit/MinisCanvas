import Foundation
import Testing
@testable import MinisCore

private actor M07AutoEditEffectProbe: ToolExecutor {
    private(set) var names: [String] = []

    nonisolated func execute(name: String, input: [String: Any]) async throws -> String {
        await record(name)
        return "synthetic-effect"
    }

    private func record(_ name: String) { names.append(name) }
}

private actor M07AutoEditDenyDelegate: ApprovalDelegate {
    private(set) var names: [String] = []

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        names.append(request.toolName)
        return .deny
    }
}

@Suite("D-POLICY-04 auto-edit approves only file edits automatically")
struct P3AcceptanceM07AutoEditBoundaryTests {
    @Test func nonFileSideEffectsStillAskAndCannotReachExecutorAfterDenial() async throws {
        let now = Date()
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "M07-AutoEdit-\(UUID().uuidString)", isDirectory: true
        )
        let capabilities: Set<String> = ["file_write", "file_edit", "shell_execute", "browser"]
        let snapshot = ComposerSubmissionSnapshot(
            mode: .autoEdit,
            approvalScope: .request,
            effort: .standard,
            sessionID: "synthetic-session",
            turnID: 1,
            taskID: "synthetic-task",
            workspaceID: "synthetic-workspace",
            createdAt: now,
            policyRevision: "synthetic-policy",
            autonomyCeiling: .l2
        )
        let facts = ComposerPolicyFactSource(
            knownCapabilities: capabilities,
            grantedCapabilities: capabilities,
            allowedWriteRoots: [workspace.path],
            workspaceID: "synthetic-workspace",
            revision: "synthetic-policy",
            leaseID: "synthetic-lease",
            expiresAt: now.addingTimeInterval(600),
            autonomyCeiling: .l2
        )
        let probe = M07AutoEditEffectProbe()
        let delegate = M07AutoEditDenyDelegate()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot, facts: facts, now: { now }
            ),
            approvalGate: ApprovalGate(policy: .autoApprove, delegate: delegate)
        )
        let file = workspace.appendingPathComponent("draft.txt").path

        let write = try await executor.execute(
            callID: "file-write", name: "file_write",
            input: ["path": file, "content": "sample"]
        )
        let edit = try await executor.execute(
            callID: "file-edit", name: "file_edit",
            input: ["path": file, "old_string": "sample", "new_string": "updated"]
        )
        #expect(write == "synthetic-effect")
        #expect(edit == "synthetic-effect")
        #expect(await delegate.names.isEmpty)
        #expect(await probe.names == ["file_write", "file_edit"])

        await #expect(throws: ComposerAuthorizationError.self) {
            _ = try await executor.execute(
                callID: "shell", name: "shell_execute",
                input: ["command": "synthetic command; never passed to a shell"]
            )
        }
        await #expect(throws: ComposerAuthorizationError.self) {
            _ = try await executor.execute(
                callID: "browser", name: "browser",
                input: ["action": "click", "selector": "#synthetic"]
            )
        }
        #expect(await delegate.names == ["shell_execute", "browser"])
        #expect(await probe.names == ["file_write", "file_edit"])
    }
}
