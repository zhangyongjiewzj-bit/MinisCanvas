import XCTest
import CryptoKit
import os
@testable import MinisCore

private actor SyntheticChildWorktreeExecutor {
    private var calls: [String] = []
    let plan: GitWorktreePlan
    let parent: String
    let child: String
    let createExit: Int32
    init(plan: GitWorktreePlan, parent: String = "/synthetic/repo", child: String? = nil, createExit: Int32 = 0) {
        self.plan = plan; self.parent = parent; self.child = child ?? plan.path; self.createExit = createExit
    }
    func execute(_ command: String, _ directory: String) -> GitWorkflowService.CommandResult {
        calls.append(directory + ":" + command)
        if command == plan.command { return .init(exitCode: createExit, stdout: "", stderr: "synthetic creation result") }
        return .init(exitCode: 0, stdout: directory == plan.workingDirectory ? parent : child, stderr: "")
    }
    func recorded() -> [String] { calls }
}

final class GitChildWorktreeAllocationTests: XCTestCase {
    private let managedRoot = GitChildWorktreeRoot(syntheticRoot: "/synthetic/home/.minis-worktrees")
    private func identity(task: String = "task-one") -> GitChildWorktreeIdentity {
        .init(taskID: task, executionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, parentSessionID: "session", parentContextSnapshotID: "snapshot")
    }
    func testTrustedUUIDDerivesPathAndBranchWithoutTaskInterpolation() throws {
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo", identity: identity(task: "../../model-like text"), managedRoot: managedRoot)
        let hash = SHA256.hash(data: Data("/synthetic/repo".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(plan.path, "/synthetic/home/.minis-worktrees/" + hash + "/00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(plan.command, "git worktree add -b 'minis/child-00000000-0000-0000-0000-000000000001' '" + plan.path + "' 'HEAD'")
    }
    func testSuccessReturnsOriginalIdentityAfterBothCheckoutChecks() async throws {
        let id = identity()
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo", identity: id, managedRoot: managedRoot)
        let executor = SyntheticChildWorktreeExecutor(plan: plan)
        let result = try await GitChildWorktreeService.create(approvedProjectDirectory: "/synthetic/repo", identity: id, managedRoot: managedRoot, executeApproved: { await executor.execute($0, $1) })
        XCTAssertEqual(result.identity, id)
        XCTAssertEqual(result.workingDirectory, plan.path)
        let calls = await executor.recorded()
        XCTAssertEqual(calls, ["/synthetic/repo:git rev-parse --show-toplevel", "/synthetic/repo:" + plan.command, plan.path + ":git rev-parse --show-toplevel"])
    }
    func testParentMismatchNeverCreatesOrFallsBack() async throws {
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo", identity: identity(), managedRoot: managedRoot)
        let executor = SyntheticChildWorktreeExecutor(plan: plan, parent: "/synthetic/other")
        do {
            _ = try await GitChildWorktreeService.create(approvedProjectDirectory: "/synthetic/repo", identity: identity(), managedRoot: managedRoot, executeApproved: { await executor.execute($0, $1) })
            XCTFail("parent mismatch must fail closed")
        } catch let error as GitChildWorktreeService.AllocationError {
            XCTAssertEqual(error, .parentCheckoutMismatch(expected: "/synthetic/repo", actual: "/synthetic/other"))
        }
        let calls = await executor.recorded()
        XCTAssertEqual(calls.count, 1)
    }
    func testCreationFailurePreservesErrorWithoutCheckoutOrDeletion() async throws {
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo", identity: identity(), managedRoot: managedRoot)
        let executor = SyntheticChildWorktreeExecutor(plan: plan, createExit: 128)
        do {
            _ = try await GitChildWorktreeService.create(approvedProjectDirectory: "/synthetic/repo", identity: identity(), managedRoot: managedRoot, executeApproved: { await executor.execute($0, $1) })
            XCTFail("nonzero create must propagate")
        } catch let error as GitWorkflowService.WorkflowError {
            XCTAssertEqual(error, .commandFailed(command: plan.command, exitCode: 128, stdout: "", stderr: "synthetic creation result"))
        }
        let calls = await executor.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls.contains { $0.contains("remove") || $0.contains("delete") })
    }
    func testInvalidIdentityAndRootAreRejectedBeforeExecution() {
        XCTAssertThrowsError(try GitChildWorktreeService.prepare(approvedProjectDirectory: "/", identity: identity(), managedRoot: managedRoot))
        XCTAssertThrowsError(try GitChildWorktreeService.prepare(approvedProjectDirectory: "relative", identity: identity(), managedRoot: managedRoot))
        XCTAssertThrowsError(try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo", identity: identity(task: "\n"), managedRoot: managedRoot))
    }
    func testManagedRootInsideProjectIsRejected() {
        XCTAssertThrowsError(try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo", identity: identity(), managedRoot: .init(syntheticRoot: "/synthetic/repo/inside")))
    }
    func testChildMismatchNeverReturnsAllocation() async throws {
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo", identity: identity(), managedRoot: managedRoot)
        let executor = SyntheticChildWorktreeExecutor(plan: plan, child: "/synthetic/unexpected")
        do {
            _ = try await GitChildWorktreeService.create(approvedProjectDirectory: "/synthetic/repo", identity: identity(), managedRoot: managedRoot, executeApproved: { await executor.execute($0, $1) })
            XCTFail("child mismatch must fail closed")
        } catch let error as GitWorkflowService.WorkflowError {
            XCTAssertEqual(error, .worktreeIdentityMismatch(expected: plan.path, actual: "/synthetic/unexpected"))
        }
    }
}


private struct SyntheticWorktreeRuntimeProfile: GitChildWorktreeRuntimeProfile {
    let home: URL
    let worktreeProfileIsDisposable: Bool
    var worktreeProfileIsBlocked: Bool = false
    func validatedWorktreeProfileHome() throws -> URL { home }
}

extension GitChildWorktreeAllocationTests {
    private func profileRoot(_ path: URL, disposable: Bool = true, blocked: Bool = false,
                             exists: Bool = true, canonical: String? = nil) throws -> GitChildWorktreeRoot {
        try GitChildWorktreeRoot.appManaged(
            profile: SyntheticWorktreeRuntimeProfile(home: path, worktreeProfileIsDisposable: disposable, worktreeProfileIsBlocked: blocked),
            productionHome: URL(fileURLWithPath: "/synthetic/real-home"),
            privateRoots: [URL(fileURLWithPath: "/synthetic/real-home/Library/Application Support")],
            inspect: { url in .init(canonicalPath: canonical ?? url.path, isDirectory: exists) })
    }

    func testFormalAndDisposableProfileUseIsolatedHomeWithoutRealHome() throws {
        for directory in ["/synthetic/formal-profile", "/synthetic/field-profile", "/synthetic/disposable-profile"] {
            let root = try profileRoot(URL(fileURLWithPath: directory))
            let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo", identity: identity(), managedRoot: root)
            XCTAssertTrue(plan.path.hasPrefix(directory + "/.minis-worktrees/"))
            XCTAssertFalse(plan.path.contains("/synthetic/real-home"))
        }
    }

    private func realDisposableWorktreeFixture() throws -> (home: URL, repository: URL, profilePath: String) {
        let darwinTemporaryPath = try XCTUnwrap(
            ChildProcessEnvironment.values(ordinary: [:])["TMPDIR"],
            "Fixture requires the Darwin user temporary directory"
        )
        let temporaryPath = darwinTemporaryPath.hasPrefix("/var/")
            ? "/private" + darwinTemporaryPath : darwinTemporaryPath
        _ = try XCTUnwrap(temporaryPath.hasPrefix("/private/var/") ? temporaryPath : nil,
                          "Fixture requires a Darwin user temporary directory under /private/var")
        let separator = temporaryPath.hasSuffix("/") ? "" : "/"
        let profilePath = temporaryPath + separator + "p03-worktree-profile-" + UUID().uuidString
        let home = URL(fileURLWithPath: profilePath, isDirectory: true)
        let repository = home.appendingPathComponent("workspace/project-j3", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        return (home, repository, profilePath)
    }

    func testRealDisposableProfileUnderPrivateVarUsesManagedRoot() throws {
        let (home, repository, profilePath) = try realDisposableWorktreeFixture()
        let profile = SyntheticWorktreeRuntimeProfile(home: home, worktreeProfileIsDisposable: true)

        let root = try GitChildWorktreeRoot.appManaged(profile: profile)
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: repository.path,
                                                      identity: identity(), managedRoot: root)
        // The qualified disposable /private/var root plans the stable /var
        // spelling of the same managed root, independent of existence.
        let stableProfilePath = "/var/" + profilePath.dropFirst("/private/var/".count)
        XCTAssertTrue(plan.path.hasPrefix(stableProfilePath + "/.minis-worktrees/"), plan.path)
        XCTAssertTrue(root.usesStableVarSpelling)
    }

    func testSyntheticPrivateVarRootKeepsOriginalPlanSpelling() throws {
        let root = GitChildWorktreeRoot(syntheticRoot: "/private/var/synthetic-root-\(UUID().uuidString)")
        XCTAssertFalse(root.usesStableVarSpelling)
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo",
                                                      identity: identity(), managedRoot: root)
        XCTAssertTrue(plan.path.hasPrefix("/private/var/synthetic-root-"), plan.path)
        let publicPlan = try GitWorktreePlan.prepare(repositoryPath: "/synthetic/repo",
            destinationPath: "/private/var/synthetic-public-\(UUID().uuidString)/child", branch: "child")
        XCTAssertTrue(publicPlan.path.hasPrefix("/private/var/synthetic-public-"), publicPlan.path)
    }

    func testNonDisposablePrivateVarProfileKeepsOriginalPlanSpelling() throws {
        let home = URL(fileURLWithPath: "/private/var/synthetic-formal-home", isDirectory: true)
        let root = try GitChildWorktreeRoot.appManaged(
            profile: SyntheticWorktreeRuntimeProfile(home: home, worktreeProfileIsDisposable: false, worktreeProfileIsBlocked: false),
            productionHome: home,
            privateRoots: [],
            inspect: { url in .init(canonicalPath: url.path, isDirectory: true) })
        XCTAssertFalse(root.usesStableVarSpelling)
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo",
                                                      identity: identity(), managedRoot: root)
        XCTAssertTrue(plan.path.hasPrefix(home.path + "/.minis-worktrees/"), plan.path)
    }

    func testStableDarwinVarSpellingChangesOnlyThePrivateVarPrefix() {
        XCTAssertEqual(GitWorktreePlan.stableDarwinVarSpelling("/private/var/folders/a/b"), "/var/folders/a/b")
        XCTAssertEqual(GitWorktreePlan.stableDarwinVarSpelling("/var/folders/a/b"), "/var/folders/a/b")
        XCTAssertEqual(GitWorktreePlan.stableDarwinVarSpelling("/private/tmp/a"), "/private/tmp/a")
        XCTAssertEqual(GitWorktreePlan.stableDarwinVarSpelling("/private/var"), "/private/var")
        XCTAssertEqual(GitWorktreePlan.stableDarwinVarSpelling("/Users/someone/project"), "/Users/someone/project")
    }

    func testCleanupCheckoutIdentityAcceptsOnlyTheFixedVarAliasWithIdenticalSuffix() {
        let expected = "/var/folders/xy/T/owned/.minis-worktrees/hash/uuid"
        XCTAssertTrue(GitChildWorktreeCleanupService.sameCheckout(reported: expected, expected: expected, allowsVarAlias: false))
        XCTAssertTrue(GitChildWorktreeCleanupService.sameCheckout(reported: "/private" + expected, expected: expected, allowsVarAlias: true))
        XCTAssertFalse(GitChildWorktreeCleanupService.sameCheckout(reported: "/private" + expected, expected: expected, allowsVarAlias: false))
        XCTAssertFalse(GitChildWorktreeCleanupService.sameCheckout(reported: "/private" + expected + "-other", expected: expected, allowsVarAlias: true))
        XCTAssertFalse(GitChildWorktreeCleanupService.sameCheckout(reported: "/private/tmp/owned", expected: "/tmp/owned", allowsVarAlias: true))
        XCTAssertFalse(GitChildWorktreeCleanupService.sameCheckout(reported: "/private/var/x", expected: "/private/var/x/..", allowsVarAlias: true))
        XCTAssertFalse(GitChildWorktreeCleanupService.sameCheckout(reported: expected, expected: "/private" + expected, allowsVarAlias: true))
        XCTAssertFalse(GitChildWorktreeCleanupService.sameCheckout(reported: "var/folders/x", expected: "/var/folders/x", allowsVarAlias: true))
    }

    func testRealDarwinWorktreeCreationAcceptsItsGitTopLevel() async throws {
        let (home, repository, _) = try realDisposableWorktreeFixture()
        @Sendable func git(_ arguments: [String], at directory: String) throws -> GitWorkflowService.CommandResult {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path,
                                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errors = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(exitCode: process.terminationStatus,
                         stdout: String(decoding: output, as: UTF8.self),
                         stderr: String(decoding: errors, as: UTF8.self))
        }
        let initResult = try git(["-c", "init.templateDir=", "init", "-q", "-b", "main"], at: repository.path)
        guard initResult.exitCode == 0 else { return XCTFail(String(reflecting: initResult)) }
        let commitResult = try git(["-c", "user.name=Owned J3", "-c", "user.email=j3@example.invalid",
                                    "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Owned J3"],
                                   at: repository.path)
        guard commitResult.exitCode == 0 else { return XCTFail(String(reflecting: commitResult)) }

        let profile = SyntheticWorktreeRuntimeProfile(home: home, worktreeProfileIsDisposable: true)
        let managed = try GitChildWorktreeRoot.appManaged(profile: profile)
        let id = identity()
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: repository.path,
                                                      identity: id, managedRoot: managed)
        XCTAssertTrue(managed.usesStableVarSpelling)
        XCTAssertTrue(plan.path.hasPrefix("/var/"), plan.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.path))
        let branch = "minis/child-" + id.executionID.uuidString.lowercased()
        let revParse = "git rev-parse --show-toplevel"
        let calls = OSAllocatedUnfairLock(initialState: [GitWorkflowService.CommandResult]())
        do {
            let allocation = try await GitChildWorktreeService.create(
                approvedProjectDirectory: repository.path, identity: id, managedRoot: managed
            ) { command, directory in
                let arguments: [String]
                switch (command, directory) {
                case (revParse, plan.workingDirectory), (revParse, plan.path):
                    arguments = ["rev-parse", "--show-toplevel"]
                case (plan.command, plan.workingDirectory):
                    arguments = ["worktree", "add", "-b", branch, plan.path, "HEAD"]
                default:
                    throw GitWorkflowService.WorkflowError.unsupportedWriteCommand
                }
                let result = try git(arguments, at: directory)
                calls.withLock { $0.append(result) }
                print("J3 git command=\(String(reflecting: command)) cwd=\(String(reflecting: directory)) result=\(String(reflecting: result))")
                return result
            }
            XCTAssertEqual(allocation.workingDirectory, plan.path)
            let recomputed = try GitChildWorktreeService.prepare(
                approvedProjectDirectory: allocation.repositoryPath,
                identity: allocation.identity, managedRoot: managed
            )
            let repositoryMatches = allocation.repositoryPath == recomputed.workingDirectory
            let targetMatches = allocation.workingDirectory == recomputed.path
            let branchMatches = allocation.branch == "minis/child-" + allocation.identity.executionID.uuidString.lowercased()
            print("J3 recomputed plan repositoryMatches=\(repositoryMatches) targetMatches=\(targetMatches) branchMatches=\(branchMatches) originalRepository=\(String(reflecting: allocation.repositoryPath)) recomputedRepository=\(String(reflecting: recomputed.workingDirectory)) originalTarget=\(String(reflecting: allocation.workingDirectory)) recomputedTarget=\(String(reflecting: recomputed.path))")
            XCTAssertEqual(recomputed, plan)
        } catch let error as GitWorkflowService.WorkflowError {
            XCTFail("J3 real Git allocation: \(String(reflecting: error))")
        }
        let results = calls.withLock { $0 }
        XCTAssertEqual(results.map(\.exitCode), [0, 0, 0])
        if results.count == 3 {
            let topLevel = results[2].stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(PolicyRuntimePathBoundary.canonicalPath(topLevel),
                           PolicyRuntimePathBoundary.canonicalPath(plan.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.path))
    }

    func testDisposableCannotSelectRealHomeOrDescendant() {
        for path in ["/synthetic/real-home", "/synthetic/real-home/isolated"] {
            XCTAssertThrowsError(try profileRoot(URL(fileURLWithPath: path)))
        }
    }

    func testProfileHomeRejectsPrivateSystemCredentialAndBlockedRoots() {
        for path in ["/synthetic/real-home/Library/Application Support", "/synthetic/profile/Application Support", "/System", "/Library", "/synthetic/.ssh"] {
            XCTAssertThrowsError(try profileRoot(URL(fileURLWithPath: path)))
        }
        XCTAssertThrowsError(try profileRoot(URL(fileURLWithPath: "/synthetic/formal-profile"), blocked: true))
    }

    func testProfileHomeRejectsRelativeMissingAndSymlinkAliasWithoutFallback() {
        XCTAssertThrowsError(try profileRoot(URL(string: "relative")!))
        XCTAssertThrowsError(try profileRoot(URL(fileURLWithPath: "/synthetic/missing"), exists: false))
        XCTAssertThrowsError(try profileRoot(URL(fileURLWithPath: "/synthetic/alias"), canonical: "/synthetic/other"))
    }

    func testProductionKeepsExistingSystemHomeDerivation() throws {
        let root = try profileRoot(URL(fileURLWithPath: "/synthetic/real-home"), disposable: false)
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo", identity: identity(), managedRoot: root)
        XCTAssertTrue(plan.path.hasPrefix("/synthetic/real-home/.minis-worktrees/"))
        XCTAssertThrowsError(try profileRoot(URL(fileURLWithPath: "/synthetic/other-home"), disposable: false))
    }
}
