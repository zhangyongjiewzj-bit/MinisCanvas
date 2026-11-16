import Foundation
import Testing
@testable import MinisCore

@Suite("Project file roots and approved outside reads")
struct SessionFileRootApprovalTests {
    @Test func outsideReadRequiresFreshApprovalAndConsumesItInRealPolicyAndBuiltin() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let outside = root.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "outside synthetic content".write(to: outside, atomically: true, encoding: .utf8)
        let delegate = ReadDelegate(approved: true)
        let executor = try composed(project: project, delegate: delegate)
        for call in ["first", "second"] {
            let output = try await executor.execute(callID: call, name: "file_read", input: ["path": outside.path])
            #expect(output == "outside synthetic content")
        }
        let requests = await delegate.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.requiresApproval && $0.persistentAllowOffer == nil })
    }

    @Test func outsideReadRejectionAndDeniedDirectoryKeepTheirExistingBoundaries() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let denied = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        let file = denied.appendingPathComponent("note.txt")
        try "synthetic denied content".write(to: file, atomically: true, encoding: .utf8)
        let rejection = ReadDelegate(approved: false)
        let rejected = try composed(project: project, delegate: rejection)
        await #expect(throws: ComposerAuthorizationError.approvalDenied(nil)) {
            _ = try await rejected.execute(callID: "reject", name: "file_read", input: ["path": file.path])
        }
        let approval = ReadDelegate(approved: true)
        let protected = try composed(project: project, delegate: approval, denied: [denied])
        await #expect(throws: ToolExecutorError.pathViolation(file.path)) {
            _ = try await protected.execute(callID: "denied-root", name: "file_read", input: ["path": file.path])
        }
        #expect(await rejection.requests.count == 1)
        #expect(await approval.requests.count == 1)
    }

    @Test func admittedSessionSwitchUsesNewRootWithoutChangingPreviouslyCapturedTurn() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for directory in [a, b] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try directory.lastPathComponent.write(to: directory.appendingPathComponent("note.txt"),
                atomically: true, encoding: .utf8)
        }
        let owner = BuiltinToolExecutor(allowedRoot: a, deniedRoots: [], sessionDerivedRoot: true)
        var admittedA = AgentLoop()
        try admittedA.captureToolWorkspace(directory: a, owner: owner)
        var admittedB = admittedA
        try admittedB.captureToolWorkspace(directory: b, owner: owner)
        let scopeA = try #require(admittedA.childWorkspaceScope)
        let scopeB = try #require(admittedB.childWorkspaceScope)
        try await ChildToolWorkspaceScope.$current.withValue(scopeA) {
            let readResult = try await owner.execute(name: "file_read", input: ["path": a.appendingPathComponent("note.txt").path])
            #expect(readResult == "a")
        }
        try await ChildToolWorkspaceScope.$current.withValue(scopeB) {
            let readResult = try await owner.execute(name: "file_read", input: ["path": b.appendingPathComponent("note.txt").path])
            #expect(readResult == "b")
            await #expect(throws: ToolExecutorError.pathViolation(a.appendingPathComponent("note.txt").path)) {
                _ = try await owner.execute(name: "file_read", input: ["path": a.appendingPathComponent("note.txt").path])
            }
        }
    }

    private func composed(project: URL, delegate: ReadDelegate, denied: [URL] = []) throws -> ComposerPolicyEnforcedToolExecutor {
        let now = Date()
        let goal = GoalEnvelope(scopeID: "synthetic-roots", allowedCapabilities: ["file_read"],
            fileRoots: [project.path], budget: 10, deadline: now.addingTimeInterval(600),
            concurrencyLimit: 1, autonomyLevel: .l3, creatorID: "SessionFileRootApprovalTests", createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: now, expiresAt: goal.deadline)
        let snapshot = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .session, effort: .standard,
            sessionID: "synthetic-session", turnID: 1, taskID: "synthetic-task", messageID: "synthetic-message",
            workspaceID: "synthetic-project", createdAt: now, policyRevision: "v1", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: [project.path], workspaceID: "synthetic-project", revision: "v1",
            leaseID: "synthetic-lease", expiresAt: goal.deadline, autonomyCeiling: .l3)
        let builtin = BuiltinToolExecutor(allowedRoot: project, deniedRoots: denied)
        let policy = PolicyEnforcedToolExecutor(base: builtin, goal: goal, lease: lease)
        return ComposerPolicyEnforcedToolExecutor(base: policy,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: ApprovalGate(delegate: delegate))
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private actor ReadDelegate: ApprovalDelegate {
        let approved: Bool
        private(set) var requests: [ApprovalRequest] = []
        init(approved: Bool) { self.approved = approved }
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            requests.append(request)
            return ApprovalDecision(approved: approved, confirmed: approved,
                requestID: request.requestID, bindingDigest: request.identityDigest)
        }
    }
}
