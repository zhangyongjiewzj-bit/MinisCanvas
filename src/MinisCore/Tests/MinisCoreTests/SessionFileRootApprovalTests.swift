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
            #expect(output == "     1\toutside synthetic content")
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
            #expect(readResult == "     1\ta")
        }
        try await ChildToolWorkspaceScope.$current.withValue(scopeB) {
            let readResult = try await owner.execute(name: "file_read", input: ["path": b.appendingPathComponent("note.txt").path])
            #expect(readResult == "     1\tb")
            await #expect(throws: ToolExecutorError.pathViolation(a.appendingPathComponent("note.txt").path)) {
                _ = try await owner.execute(name: "file_read", input: ["path": a.appendingPathComponent("note.txt").path])
            }
        }
    }

    @Test func allowReadingThisDirectoryFromNowOnCoversSiblingFilesWithoutAnotherPrompt() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try "first synthetic".write(to: shared.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "second synthetic".write(to: shared.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let rules = PersistentApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json"),
            homeDirectory: "/nonexistent-home-for-read-rule-tests")
        let delegate = ReadDelegate(approved: true, persistAllow: true)
        let executor = try composed(project: project, delegate: delegate, rules: rules)
        let first = try await executor.execute(callID: "first", name: "file_read",
            input: ["path": shared.appendingPathComponent("a.txt").path])
        #expect(first == "     1\tfirst synthetic")
        #expect(await delegate.requests.first?.persistentAllowOffer?.isAvailable == true)
        #expect(rules.allRules().map(\.capability) == ["file_read"])
        // 同目录的另一个文件：规则命中，不再询问；仍然读得出内容。
        let second = try await executor.execute(callID: "second", name: "file_read",
            input: ["path": shared.appendingPathComponent("b.txt").path])
        #expect(second == "     1\tsecond synthetic")
        #expect(await delegate.requests.count == 1)
        // 项目目录之外的另一个目录不在规则内，仍要问。
        let other = root.appendingPathComponent("other.txt")
        try "other synthetic".write(to: other, atomically: true, encoding: .utf8)
        _ = try await executor.execute(callID: "third", name: "file_read", input: ["path": other.path])
        #expect(await delegate.requests.count == 2)
    }

    @Test func readRuleNeverOffersSensitiveFilesOrBroadDirectories() throws {
        let home = "/synthetic/home"
        #expect(PersistentApprovalRuleMatcher.evaluateFileRead(
            input: ["path": "/synthetic/home/work/.env"], home: home)
            == .unavailable("敏感文件每次都需询问"))
        #expect(PersistentApprovalRuleMatcher.evaluateFileRead(
            input: ["path": "/synthetic/home/notes.txt"], home: home)
            == .unavailable("所在目录是根目录或主目录，范围过大，每次都需询问"))
        #expect(PersistentApprovalRuleMatcher.evaluateFileRead(
            input: ["path": "/synthetic/home/work/proj/notes.txt"], home: home)
            == .pattern("/synthetic/home/work/proj"))
        // 主目录下的第一层目录、资源库、外接磁盘、系统目录范围过大，只给本次允许。
        for path in ["/synthetic/home/work/notes.txt", "/synthetic/home/Library/a.txt",
                     "/synthetic/home/.config/a.txt", "/synthetic/home/Library/Application Support/a.txt",
                     "/Volumes/Disk/a.txt", "/Users/Shared/a.txt", "/private/etc/a.txt", "/etc/a.txt",
                     // 更深的系统目录与资源库子目录同样只给本次允许。
                     "/etc/ssl/certs/a.txt", "/private/etc/ssh/a.txt", "/System/Library/Fonts/a.txt",
                     "/Library/Application Support/Vendor/Deep/a.txt",
                     "/synthetic/home/Library/Application Support/Vendor/Deep/a.txt"] {
            guard case .unavailable = PersistentApprovalRuleMatcher.evaluateFileRead(
                input: ["path": path], home: home) else {
                Issue.record("\(path) must not get a directory rule"); continue
            }
        }
    }

    @Test func outsideWriteAsksAndOnlyTheApprovedFileBecomesWritable() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("elsewhere.txt")
        let delegate = ReadDelegate(approved: true)
        let executor = composedWriter(project: project, delegate: delegate)
        let output = try await executor.execute(callID: "write", name: "file_write",
            input: ["path": target.path, "content": "synthetic"])
        #expect(output == "scoped-write-ok")
        let requests = await delegate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.persistentAllowOffer == nil)
        // 没有批准就不执行。
        let rejected = composedWriter(project: project, delegate: ReadDelegate(approved: false))
        await #expect(throws: ComposerAuthorizationError.approvalDenied(nil)) {
            _ = try await rejected.execute(callID: "write-rejected", name: "file_write",
                input: ["path": target.path, "content": "synthetic"])
        }
    }

    @Test func insideRootWriteNeedsNoApprovalAndSensitiveOutsideWriteStaysRejected() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let delegate = ReadDelegate(approved: true)
        let executor = composedWriter(project: project, delegate: delegate)
        let sensitive = root.appendingPathComponent("keys").appendingPathComponent(".env")
        await #expect(throws: ComposerAuthorizationError.pathOutsideAllowedRoots(sensitive.path)) {
            _ = try await executor.execute(callID: "sensitive", name: "file_write",
                input: ["path": sensitive.path, "content": "synthetic"])
        }
        #expect(await delegate.requests.isEmpty)
        let controller = composedWriterController(project: project)
        let inside = try ComposerToolInput(["path": project.appendingPathComponent("a.txt").path, "content": "x"])
        #expect(try await controller.authorize(capability: "file_write", input: inside) == .execute)
    }

    private actor WriteScopeProbe: ToolExecutor {
        nonisolated func execute(name: String, input: [String: Any]) async throws -> String {
            guard let path = input["path"] as? String,
                  ApprovedFileWriteScope.permits(tool: name, path: path) else { return "outside-denied" }
            return "scoped-write-ok"
        }
    }

    private func composedWriterController(project: URL) -> ComposerAuthorizationController {
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .session, effort: .standard,
            sessionID: "synthetic-session", turnID: 1, taskID: "synthetic-task", messageID: "synthetic-message",
            workspaceID: "synthetic-project", createdAt: now, policyRevision: "v1", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [project.path], workspaceID: "synthetic-project", revision: "v1",
            leaseID: "synthetic-lease", expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3)
        return ComposerAuthorizationController(snapshot: snapshot, facts: facts)
    }

    private func composedWriter(project: URL, delegate: ReadDelegate) -> ComposerPolicyEnforcedToolExecutor {
        let now = Date()
        let goal = GoalEnvelope(scopeID: "synthetic-roots", allowedCapabilities: ["file_write"],
            fileRoots: [project.path], budget: 10, deadline: now.addingTimeInterval(600),
            concurrencyLimit: 1, autonomyLevel: .l3, creatorID: "SessionFileRootApprovalTests", createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: now, expiresAt: goal.deadline)
        let policy = PolicyEnforcedToolExecutor(base: WriteScopeProbe(), goal: goal, lease: lease)
        return ComposerPolicyEnforcedToolExecutor(base: policy,
            controller: composedWriterController(project: project),
            approvalGate: ApprovalGate(delegate: delegate))
    }

    private func composed(project: URL, delegate: ReadDelegate, denied: [URL] = [],
                          rules: PersistentApprovalRuleStore? = nil) throws -> ComposerPolicyEnforcedToolExecutor {
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
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts,
                grants: rules.map { ComposerApprovalGrantStore(persistentRules: $0) } ?? ComposerApprovalGrantStore()),
            approvalGate: ApprovalGate(delegate: delegate))
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private actor ReadDelegate: ApprovalDelegate {
        let approved: Bool
        let persistAllow: Bool
        private(set) var requests: [ApprovalRequest] = []
        init(approved: Bool, persistAllow: Bool = false) {
            self.approved = approved
            self.persistAllow = persistAllow
        }
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            requests.append(request)
            return ApprovalDecision(approved: approved, confirmed: approved,
                requestID: request.requestID, bindingDigest: request.identityDigest,
                persistAllow: persistAllow && request.persistentAllowOffer?.isAvailable == true)
        }
    }
}
