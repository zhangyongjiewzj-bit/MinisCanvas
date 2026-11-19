import Foundation
import Testing
@testable import MinisCore

private actor TransferContextProbe: ToolExecutor {
    let path: String
    init(path: String) { self.path = path }
    nonisolated func execute(name: String, input: [String: Any]) async throws -> String {
        guard let access = BrowserTransferFileAccessContext.current else {
            throw ToolExecutorError.toolNotConfigured("browser transfer file access")
        }
        try await access("file_write", URL(fileURLWithPath: path))
        return "checked"
    }
}

@Suite("Browser transfer binds current Composer file policy")
struct BrowserTransferComposerBindingTests {
    @Test func realComposerWrapperAllowsCurrentRootAndRejectsAnotherRoot() async throws {
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .session, effort: .standard,
            sessionID: "synthetic-session", turnID: 1, taskID: "synthetic-task", messageID: "synthetic-message",
            workspaceID: "synthetic-project", createdAt: now, policyRevision: "v1", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["browser", "file_write"],
            grantedCapabilities: ["browser", "file_write"], allowedWriteRoots: ["/synthetic/project"],
            workspaceID: "synthetic-project", revision: "v1", leaseID: "synthetic-lease",
            expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3)
        func wrapped(_ path: String) -> ComposerPolicyEnforcedToolExecutor {
            ComposerPolicyEnforcedToolExecutor(base: TransferContextProbe(path: path),
                controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts), approvalGate: ApprovalGate())
        }
        let allowed = try await wrapped("/synthetic/project/output.txt")
            .execute(callID: "allowed", name: "browser", input: ["action": "screenshot"])
        #expect(allowed == "checked")
        // 授权根外的普通位置：不再直接拒绝，交给浏览器动作自己的审批卡（卡上显示最终目标路径）。
        let outside = try await wrapped("/synthetic/other/output.txt")
            .execute(callID: "outside", name: "browser", input: ["action": "screenshot"])
        #expect(outside == "checked")
        // 底线不变：凭据与密钥位置仍直接拒绝。
        let credential = NSHomeDirectory() + "/.ssh/id_ed25519"
        await #expect(throws: ComposerAuthorizationError.pathOutsideAllowedRoots(credential)) {
            _ = try await wrapped(credential)
                .execute(callID: "credential", name: "browser", input: ["action": "screenshot"])
        }
        #expect(BrowserTransferFileAccessContext.current == nil)
    }
}
