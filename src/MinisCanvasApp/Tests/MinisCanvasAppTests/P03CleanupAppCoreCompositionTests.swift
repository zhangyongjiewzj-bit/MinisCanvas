import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

// Synthetic source/executor/effect only. This composes the real App controller
// with Core prepare/retire; it does not prove the production scope lease or UI.
private actor P03CompositionFixture: GitChildWorktreeCleanupSource {
    var snapshot: GitChildWorktreeCleanupSnapshot
    var dirty = false
    var occupied = false
    var retired = false
    var commands = 0
    var captureComplete: Bool
    var fieldReplacement: (Int, String)?
    var readSets: [GitChildWorktreeCleanupReadSet] = []
    var moves = 0

    init(snapshot: GitChildWorktreeCleanupSnapshot, captureComplete: Bool) {
        self.snapshot = snapshot
        self.captureComplete = captureComplete
    }
    func currentSnapshot() -> GitChildWorktreeCleanupSnapshot { snapshot }
    func validateExactWorktreePath(_ value: GitChildWorktreeAllocation) throws {
        guard value == snapshot.allocation, !retired else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("fixture resource rejected")
        }
    }
    func withExclusiveCleanupAccess(expected: GitChildWorktreeCleanupSnapshot,
        operation: @Sendable (GitChildWorktreeCleanupSnapshot) async throws -> GitChildWorktreeCleanupResult
    ) async throws -> GitChildWorktreeCleanupResult {
        guard !occupied, !retired, expected == snapshot else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("fixture resource changed")
        }
        occupied = true
        defer { occupied = false }
        let result = try await operation(snapshot)
        retired = true
        return result
    }
    func markDirty() { dirty = true }
    func counts() -> (commands: Int, moves: Int) { (commands, moves) }
    func setCaptureComplete(_ complete: Bool) { captureComplete = complete }
    func replaceField(_ index: Int, value: String) { fieldReplacement = (index, value) }
    func recordedReadSets() -> [GitChildWorktreeCleanupReadSet] { readSets }
    func execute(_ readSet: GitChildWorktreeCleanupReadSet) throws -> GitChildWorktreeCleanupReadSetResult {
        guard readSet == (try GitChildWorktreeCleanupService.readSet(for: snapshot.allocation)) else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("unexpected fixture readset")
        }
        commands += 1
        readSets.append(readSet)
        var fields = [snapshot.allocation.repositoryPath, snapshot.allocation.workingDirectory,
            snapshot.allocation.repositoryPath + "/.git", snapshot.allocation.repositoryPath + "/.git",
            "refs/heads/" + snapshot.allocation.branch,
            dirty ? "?? unsaved.txt" : "", "100644 " + String(repeating: "a", count: 40) + " 0\tfile.swift", String(repeating: "a", count: 40)]
        if let (index, value) = fieldReplacement { fields[index] = value }
        // Completeness is explicit fixture metadata, not inferred from stdout
        // shape or absence of an artifact. Production obtains it from shell.
        return .init(exitCode: 0, stdout: fields.joined(separator: "\0"), stderr: "",
            outputComplete: captureComplete)
    }
    func trash(_ request: GitChildWorktreeCleanupRequest) throws -> URL {
        guard occupied, request.snapshot == snapshot else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("fixture missing resource occupation")
        }
        moves += 1
        return URL(fileURLWithPath: "/synthetic/trash/retained-item")
    }
}

private struct P03OwnedPreviewProfile: GitChildWorktreeRuntimeProfile {
    let home: URL
    var worktreeProfileIsDisposable: Bool { true }
    var worktreeProfileIsBlocked: Bool { false }
    func validatedWorktreeProfileHome() throws -> URL { home }
}

@Suite("P03 actual App/Core cleanup composition with synthetic effects")
@MainActor
struct P03CleanupAppCoreCompositionTests {
    private func make() throws -> (P03CleanupAppController, P03CompositionFixture, P03CleanupAppResource, UUID) {
        let root = GitChildWorktreeRoot(syntheticRoot: "/synthetic/home/.minis-worktrees")
        let identity = GitChildWorktreeIdentity(taskID: "task", executionID: UUID(),
            parentSessionID: "parent-session", parentContextSnapshotID: "context")
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repository",
            identity: identity, managedRoot: root)
        let allocation = GitChildWorktreeAllocation(identity: identity, repositoryPath: plan.workingDirectory,
            workingDirectory: plan.path, branch: "minis/child-" + identity.executionID.uuidString.lowercased())
        let fixture = P03CompositionFixture(snapshot: .init(allocation: allocation, parentIdentity: identity,
            goalID: "goal", scopeID: "scope", leaseID: "lease", generation: UUID(),
            taskIsActive: false, childScopeRevoked: true, parentAuthorityValid: true), captureComplete: true)
        let controller = P03CleanupAppController(platformTrash: { try await fixture.trash($0) })
        let resource = P03CleanupAppResource(source: fixture, managedRoot: root,
            readOnly: { try await fixture.execute($0) })
        return (controller, fixture, resource, identity.executionID)
    }

    @Test func ownedDarwinWorktreeReachesReadOnlyCleanupPreview() async throws {
        let temporary = try #require(ChildProcessEnvironment.values(ordinary: [:])["TMPDIR"])
        let physicalTemporary = temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
        try #require(physicalTemporary.hasPrefix("/private/var/"))
        let home = URL(fileURLWithPath: physicalTemporary, isDirectory: true)
            .appendingPathComponent("p03-read-only-preview-\(UUID().uuidString)", isDirectory: true)
        let repository = home.appendingPathComponent("workspace/project-j3", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let git: @Sendable ([String], String) throws -> String = { arguments, directory in
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
            let errors = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw GitWorkflowService.WorkflowError.commandFailed(
                    command: arguments.joined(separator: " "), exitCode: process.terminationStatus,
                    stdout: String(decoding: output, as: UTF8.self), stderr: String(decoding: errors, as: UTF8.self))
            }
            return String(decoding: output, as: UTF8.self)
        }
        _ = try git(["-c", "init.templateDir=", "init", "-q", "-b", "main"], repository.path)
        _ = try git(["-c", "user.name=Owned P03", "-c", "user.email=p03@example.invalid",
                     "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Owned P03"], repository.path)
        let identity = GitChildWorktreeIdentity(taskID: "p03-preview-child", executionID: UUID(),
            parentSessionID: "p03-preview-parent", parentContextSnapshotID: "p03-preview-context")
        let branch = "minis/child-" + identity.executionID.uuidString.lowercased()
        let root = try GitChildWorktreeRoot.appManaged(profile: P03OwnedPreviewProfile(home: home))
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: repository.path,
                                                       identity: identity, managedRoot: root)
        let topLevel = "git rev-parse --show-toplevel"
        let allocation = try await GitChildWorktreeService.create(
            approvedProjectDirectory: repository.path, identity: identity, managedRoot: root
        ) { command, directory in
            let arguments: [String]
            switch (command, directory) {
            case (topLevel, plan.workingDirectory), (topLevel, plan.path):
                arguments = ["rev-parse", "--show-toplevel"]
            case (plan.command, plan.workingDirectory):
                arguments = ["worktree", "add", "-b", branch, plan.path, "HEAD"]
            default:
                throw GitWorkflowService.WorkflowError.unsupportedWriteCommand
            }
            return .init(exitCode: 0, stdout: try git(arguments, directory), stderr: "")
        }
        try #require(root.usesStableVarSpelling)
        try #require(allocation.workingDirectory == plan.path && plan.path.hasPrefix("/var/"))
        let originalRegistration = try git(["worktree", "list", "--porcelain"], allocation.repositoryPath)
        let path = allocation.workingDirectory
        let parentOwner = BuiltinToolExecutor(allowedRoot: repository, deniedRoots: [])
        print("P03 owned checkout created; validating approved directory")
        let directory = try parentOwner.validatedApprovedSessionDirectory(path)
        let owner = try parentOwner.copyingAddingAdditionalAllowedRoots([directory])
        let now = Date()
        let goal = GoalEnvelope(scopeID: "p03-preview-scope", allowedCapabilities: ["file_read"], fileRoots: [directory.path],
            budget: 10, deadline: now.addingTimeInterval(60))
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: now, expiresAt: goal.deadline)
        func makeFacts(for roots: [String]) -> ComposerPolicyFactSource {
            ComposerPolicyFactSource(knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
                allowedWriteRoots: roots, workspaceID: "p03-preview", revision: "revision", grantEpoch: "epoch",
                leaseID: lease.leaseID.uuidString, expiresAt: goal.deadline)
        }
        let facts = makeFacts(for: goal.fileRoots)
        let task = SubAgentTask(id: identity.taskID, title: "Owned P03", instructions: "Read owned output",
            isolation: .worktree, executionID: "parent:execution:\(identity.executionID.uuidString)",
            parentContextSnapshotID: identity.parentContextSnapshotID)
        let otherDirectory = try parentOwner.validatedApprovedSessionDirectory(repository.path)
        try #require(otherDirectory.path != directory.path)
        let otherGoal = GoalEnvelope(goalID: goal.goalID, scopeID: goal.scopeID,
            allowedCapabilities: goal.allowedCapabilities, fileRoots: [otherDirectory.path],
            networkDomains: goal.networkDomains, budget: goal.budget, deadline: goal.deadline,
            concurrencyLimit: goal.concurrencyLimit, autonomyLevel: goal.autonomyLevel,
            creatorID: goal.creatorID, createdAt: goal.createdAt)
        #expect(throws: ToolExecutorError.invalidParameter("child_isolation_binding")) {
            try ChildWorktreeExecutionScope(allocation: allocation, task: task, owner: owner,
                executor: PolicyEnforcedToolExecutor(base: owner, goal: otherGoal, lease: lease),
                goal: otherGoal, lease: lease, facts: makeFacts(for: otherGoal.fileRoots),
                cleanupParentAuthority: {})
        }

        print("P03 owned directory validated; constructing production scope")
        let scope = try ChildWorktreeExecutionScope(allocation: allocation, task: task, owner: owner,
            executor: PolicyEnforcedToolExecutor(base: owner, goal: goal, lease: lease), goal: goal,
            lease: lease, facts: facts, cleanupParentAuthority: {})
        try #require(scope.claim(task: task))
        scope.revoke()
        print("P03 production scope revoked; validating exact worktree identity")
        try await scope.validateExactWorktreePath(allocation)

        let controller = P03CleanupAppController(platformTrash: { _ in
            Issue.record("read-only preview must not call platform Trash")
            throw GitChildWorktreeCleanupService.CleanupError.rejected("read-only fixture")
        })
        let resource = P03CleanupAppResource(source: scope, managedRoot: root, readOnly: { readSet in
            guard readSet.repositoryPath == allocation.repositoryPath,
                  readSet.workingDirectory == allocation.workingDirectory else {
                throw GitChildWorktreeCleanupService.CleanupError.rejected("unexpected owned read set")
            }
            let repo = readSet.repositoryPath
            let child = readSet.workingDirectory
            let fields = try [
                git(["rev-parse", "--show-toplevel"], repo),
                git(["rev-parse", "--show-toplevel"], child),
                git(["rev-parse", "--git-common-dir"], repo),
                git(["rev-parse", "--git-common-dir"], child),
                git(["symbolic-ref", "-q", "HEAD"], child),
                git(["status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching",
                     "--ignore-submodules=none"], child),
                git(["ls-files", "--stage"], child),
                git(["rev-parse", "HEAD"], child),
            ]
            return .init(exitCode: 0, stdout: fields.joined(separator: "\0"), stderr: "", outputComplete: true)
        })
        try await controller.register(resource)
        await controller.refresh(identity.executionID)
        print("P03 exact identity verified; preparing read-only preview")
        await controller.prepare(identity.executionID)
        let preview = try #require(controller.confirmation, "P03 prepare: \(controller.rows.first?.failure ?? "no error")")
        #expect(preview.request.snapshot.allocation == allocation)
        controller.cancelConfirmation()
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try git(["worktree", "list", "--porcelain"], allocation.repositoryPath) == originalRegistration)
    }

    @Test("Prepare and confirm each use one complete eight-field readset, then move once")
    func cleanRequestUsesRealCoreAndRetainsRestoreLocation() async throws {
        let (controller, fixture, resource, id) = try make()
        try await controller.register(resource)
        await controller.prepare(id)
        let confirmation = try #require(controller.confirmation)
        let prepared = await fixture.counts()
        #expect(prepared.commands == 1 && prepared.moves == 0)
        let operation = try #require(controller.confirm(confirmation.id))
        await operation.value
        let completed = await fixture.counts()
        #expect(completed.commands == 2 && completed.moves == 1)
        let readSets = await fixture.recordedReadSets()
        let expected = try GitChildWorktreeCleanupService.readSet(for: confirmation.request.snapshot.allocation)
        #expect(readSets == [expected, expected])
        #expect(expected.approvalChecklist.contains(expected.repositoryPath))
        #expect(expected.approvalChecklist.contains(expected.workingDirectory))
        for number in 1...8 { #expect(expected.approvalChecklist.contains("\(number). git -C ")) }
        let row = try #require(controller.rows.first)
        #expect(row.result?.originalPath == confirmation.request.snapshot.allocation.workingDirectory)
        #expect(row.result?.trashURL.path == "/synthetic/trash/retained-item")
        #expect(row.status == "目录已移废纸篓，Git 登记与分支保留")
        #expect(!row.canPrepare)
        #expect(controller.confirm(confirmation.id) == nil)
    }

    @Test("Cancel has no effect; dirty drift after confirmation preparation fails visibly")
    func cancelAndDirtyRevalidation() async throws {
        let (controller, fixture, resource, id) = try make()
        try await controller.register(resource)
        await controller.prepare(id)
        let cancelled = try #require(controller.confirmation)
        controller.cancelConfirmation()
        #expect(controller.confirm(cancelled.id) == nil)
        let afterCancel = await fixture.counts()
        #expect(afterCancel.moves == 0)
        await controller.prepare(id)
        let pending = try #require(controller.confirmation)
        await fixture.markDirty()
        let operation = try #require(controller.confirm(pending.id))
        await operation.value
        let afterFailure = await fixture.counts()
        #expect(afterFailure.moves == 0)
        let row = try #require(controller.rows.first)
        #expect(row.result == nil)
        #expect(row.failure?.contains("未跟踪") == true)
    }
    @Test("Every field still enforces its original assertion; no partial output can authorize trash")
    func allEightAssertionsAndIncompleteCaptureReject() async throws {
        let invalid = ["/other/repository", "/other/checkout", "/other/parent-common", "/other/child-common",
            "refs/heads/other", "?? unsaved.txt", "160000 " + String(repeating: "a", count: 40) + " 0\tmodule", "not-a-commit"]
        for (index, value) in invalid.enumerated() {
            let (controller, fixture, resource, id) = try make()
            try await controller.register(resource)
            await fixture.replaceField(index, value: value)
            await controller.prepare(id)
            #expect(controller.confirmation == nil)
            #expect(controller.rows.first?.failure != nil)
            let counts = await fixture.counts()
            #expect(counts.commands == 1 && counts.moves == 0)
        }
        let (controller, fixture, resource, id) = try make()
        try await controller.register(resource)
        await controller.prepare(id)
        let pending = try #require(controller.confirmation)
        await fixture.setCaptureComplete(false)
        let operation = try #require(controller.confirm(pending.id))
        await operation.value
        #expect(controller.rows.first?.failure?.contains("不完整") == true)
        let counts = await fixture.counts()
        #expect(counts.commands == 2 && counts.moves == 0)
    }

}
