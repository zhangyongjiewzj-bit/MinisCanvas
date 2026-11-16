import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// Models the user pressing Approve on the exact card shown: the decision is
/// bound to that request, as the App's approval center produces it. An
/// unbound `.approve` is rejected by the Composer before execution.
private struct CleanupFixApprovingDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private func cleanupFixGit(_ arguments: [String], in directory: String, home: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path,
                           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                           "GIT_OPTIONAL_LOCKS": "0"]
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    _ = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitChildWorktreeCleanupService.CleanupError.rejected(
            "fixture git failed: " + arguments.joined(separator: " "))
    }
    return String(decoding: output, as: UTF8.self)
}

/// A real temporary repository with a real linked child worktree.
private struct CleanupFixRepository {
    let home: URL
    let repository: URL
    let child: URL
    let identity: GitChildWorktreeIdentity
    let branch: String
    var allocation: GitChildWorktreeAllocation {
        GitChildWorktreeAllocation(identity: identity, repositoryPath: repository.path,
                                   workingDirectory: child.path, branch: branch)
    }

    static func make(parentSessionID: String, under base: URL? = nil) throws -> CleanupFixRepository {
        let home = (base ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("p03-cleanup-fix-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let repository = home.appendingPathComponent("repo", isDirectory: true)
        let child = home.appendingPathComponent("child-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = try cleanupFixGit(["-c", "init.templateDir=", "init", "-q", "-b", "main"], in: repository.path, home: home)
        _ = try cleanupFixGit(["-c", "user.name=Fix", "-c", "user.email=fix@example.invalid",
                               "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "base"],
                              in: repository.path, home: home)
        let identity = GitChildWorktreeIdentity(taskID: "j3-child", executionID: UUID(),
            parentSessionID: parentSessionID, parentContextSnapshotID: "fix-context")
        let branch = "minis/child-" + identity.executionID.uuidString.lowercased()
        _ = try cleanupFixGit(["worktree", "add", "-b", branch, child.path, "HEAD"],
                              in: repository.path, home: home)
        return CleanupFixRepository(home: home, repository: repository, child: child,
                                    identity: identity, branch: branch)
    }
}

@Suite("Residual child worktree cleanup: parent-context read-only check and live status", .serialized)
@MainActor
struct P03CleanupResidualFixTests {
    private func parentContext(sessionID: String, turnController: TurnController,
                               turn: TurnController.TurnHandle) -> AgentExecutionContextSnapshot {
        AgentExecutionContextSnapshot(
            provider: MockProvider.shared, approvalGate: nil, turnController: turnController,
            currentConversationID: sessionID, makeChildBudget: nil,
            // Already expired, as for a parent turn that finished long ago.
            deadline: Date().addingTimeInterval(-60),
            parentTurnHandle: turn,
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: sessionID, conversationID: sessionID,
                turnID: "turn-handle:\(turn.turnID)", taskID: "cleanup-fix-parent", actorID: "app"))
    }

    /// Real production composition (Policy -> Project composite -> real Builtin
    /// shell) under a real Composer approval wrapper, real temporary Git
    /// repository, and the production read-only factory, invoked from a
    /// detached Task exactly as the task-center UI does (no task-local context).
    private func runProductionReadOnly(
        contextSessionOverride: String? = nil,
        finishParentTurnFirst: Bool = false
    ) async throws -> (CleanupFixRepository, GitChildWorktreeCleanupReadSetResult, String) {
        let physicalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p03-cleanup-bridge-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: physicalRoot) }
        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: physicalRoot, sessionDirectory: physicalRoot,
            approvalDelegateOverride: CleanupFixApprovingDelegate(), policyDefaults: .default)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let sessionID = try #require(bridge.chat.activeSessionID?.uuidString)
        let facts = bridge.chat.composerPolicyFacts
        try #require(facts.grantedCapabilities.contains("shell_execute"))

        // Repository and linked worktree live under the production file root.
        let fixture = try CleanupFixRepository.make(parentSessionID: sessionID, under: physicalRoot)
        let allocation = fixture.allocation
        // Git reports the physical top-level path (/private/var/...), while
        // URL.resolvingSymlinksInPath keeps the /var spelling. Resolve it now,
        // before the deferred cleanup removes the directory.
        let resolvedChild = try #require(realpath(fixture.child.path, nil))
        let physicalChild = String(cString: resolvedChild)
        free(resolvedChild)

        let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request,
            effort: .standard, sessionID: sessionID, turnID: 1, taskID: "cleanup-fix-parent",
            attemptID: "cleanup-fix-attempt", messageID: "cleanup-fix-message",
            workspaceID: facts.workspaceID, createdAt: Date(), policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch, autonomyCeiling: facts.autonomyCeiling)
        let composer = ComposerPolicyEnforcedToolExecutor(
            base: engine.composedExecutor,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: ApprovalGate(delegate: CleanupFixApprovingDelegate()))

        let turnController = TurnController()
        let turn = await turnController.beginTurn()
        defer { Task { await turn.finish() } }
        if finishParentTurnFirst { await turn.finish() }
        let context = parentContext(sessionID: contextSessionOverride ?? sessionID,
                                    turnController: turnController, turn: turn)

        let readOnly = BridgeStore.makeCleanupReadOnlyExecutor(
            allocation: allocation, parentDirectory: fixture.repository.path, parentComposer: composer,
            parentContext: context, parentSessionID: sessionID, assertParent: {})
        let readSet = try GitChildWorktreeCleanupService.readSet(for: allocation)
        let result = try await Task.detached { try await readOnly(readSet) }.value
        return (fixture, result, physicalChild)
    }

    @Test("UI-started read-only check resolves the original parent session and returns the full eight-field read set")
    func readOnlyCheckRunsInParentContextWithoutTaskLocal() async throws {
        let (fixture, result, physicalChild) = try await runProductionReadOnly()
        #expect(result.outputComplete && result.exitCode == 0)
        let fields = result.stdout.components(separatedBy: "\0")
        try #require(fields.count == 8)
        let values = fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(values[1] == physicalChild)
        #expect(values[4] == "refs/heads/" + fixture.branch)
        #expect(values[5].isEmpty)
        #expect(values[7].count == 40)
    }

    @Test("A context whose parent session differs from the resource's parent is still refused")
    func foreignParentContextIsRefused() async throws {
        // The wording comes from the fix commit: before it, the Project
        // executor throws sourceUnavailable instead, so this is expected RED.
        await #expect(throws: GitChildWorktreeCleanupService.CleanupError.rejected(
            "父会话运行身份已变化，未执行只读检查")) {
            _ = try await self.runProductionReadOnly(contextSessionOverride: UUID().uuidString)
        }
    }

    @Test("Cleanup started after the parent turn has finished still returns the full eight-field read set")
    func readOnlyCheckRunsAfterParentTurnFinished() async throws {
        let (fixture, result, _) = try await runProductionReadOnly(finishParentTurnFirst: true)
        #expect(result.outputComplete && result.exitCode == 0)
        let fields = result.stdout.components(separatedBy: "\0")
        try #require(fields.count == 8)
        #expect(fields[4].trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/" + fixture.branch)
    }

    @Test("After the child scope is revoked, refreshing the panel rows no longer reports the task as active")
    func revokedChildScopeIsNotShownAsActiveAfterRefresh() async throws {
        let fixture = try CleanupFixRepository.make(parentSessionID: "cleanup-fix-session")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let parentOwner = BuiltinToolExecutor(allowedRoot: fixture.repository, deniedRoots: [])
        let directory = try parentOwner.validatedApprovedSessionDirectory(fixture.child.path)
        let owner = try parentOwner.copyingAddingAdditionalAllowedRoots([directory])
        let now = Date()
        let goal = GoalEnvelope(scopeID: "cleanup-fix-scope", allowedCapabilities: ["file_read"],
            fileRoots: [directory.path], budget: 10, deadline: now.addingTimeInterval(60))
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: now, expiresAt: goal.deadline)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: goal.fileRoots, workspaceID: "cleanup-fix", revision: "revision",
            grantEpoch: "epoch", leaseID: lease.leaseID.uuidString, expiresAt: goal.deadline)
        let task = SubAgentTask(id: fixture.identity.taskID, title: "j3-child", instructions: "work",
            isolation: .worktree, executionID: "parent:execution:\(fixture.identity.executionID.uuidString)",
            parentContextSnapshotID: fixture.identity.parentContextSnapshotID)
        let scope = try ChildWorktreeExecutionScope(allocation: fixture.allocation, task: task, owner: owner,
            executor: PolicyEnforcedToolExecutor(base: owner, goal: goal, lease: lease), goal: goal,
            lease: lease, facts: facts, cleanupParentAuthority: {})
        try #require(scope.claim(task: task))

        let controller = P03CleanupAppController(platformTrash: { _ in
            throw GitChildWorktreeCleanupService.CleanupError.rejected("not used")
        })
        try await controller.register(P03CleanupAppResource(
            source: scope, managedRoot: GitChildWorktreeRoot(syntheticRoot: "/synthetic/home/.minis-worktrees"),
            readOnly: { _ in throw GitChildWorktreeCleanupService.CleanupError.rejected("not used") }))
        #expect(controller.rows.first?.status == "任务仍活动，不能清理")

        // What AgentOrchestrator's defer does when the child finishes.
        scope.revoke()
        await controller.refreshAll()

        let row = try #require(controller.rows.first)
        #expect(!row.snapshot.taskIsActive)
        #expect(row.status != "任务仍活动，不能清理")
        #expect(row.canPrepare)
    }
}
