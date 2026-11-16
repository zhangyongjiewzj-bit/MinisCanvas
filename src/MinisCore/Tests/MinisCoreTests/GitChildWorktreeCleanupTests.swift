import XCTest
@testable import MinisCore

private actor SyntheticCleanupSource: GitChildWorktreeCleanupSource {
    var snapshot: GitChildWorktreeCleanupSnapshot
    var pathRejected = false
    private var exclusive = false
    init(_ snapshot: GitChildWorktreeCleanupSnapshot) { self.snapshot = snapshot }
    func currentSnapshot() -> GitChildWorktreeCleanupSnapshot { snapshot }
    func set(_ snapshot: GitChildWorktreeCleanupSnapshot) { self.snapshot = snapshot }
    func rejectPath() { pathRejected = true }
    func validateExactWorktreePath(_ allocation: GitChildWorktreeAllocation) throws {
        guard !pathRejected, allocation == snapshot.allocation else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("synthetic path boundary")
        }
    }
    func withExclusiveCleanupAccess(expected: GitChildWorktreeCleanupSnapshot,
        operation: @Sendable (GitChildWorktreeCleanupSnapshot) async throws -> GitChildWorktreeCleanupResult) async throws -> GitChildWorktreeCleanupResult {
        guard !exclusive, snapshot == expected else { throw GitChildWorktreeCleanupService.CleanupError.rejected("synthetic lease changed") }
        exclusive = true
        defer { exclusive = false }
        return try await operation(snapshot)
    }
}

private actor SyntheticCleanupGit {
    let allocation: GitChildWorktreeAllocation
    var status = ""
    var index = "100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0\tfile.swift"
    var head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    var branch: String
    private var trashRequests: [GitChildWorktreeCleanupRequest] = []
    private var commands: [String] = []
    var failTrash = false
    init(_ allocation: GitChildWorktreeAllocation) { self.allocation = allocation; self.branch = "refs/heads/" + allocation.branch }
    func dirty(_ value: String) { status = value }
    func changeHead() { head = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
    func setIndex(_ value: String) { index = value }
    func submodule() { index = "160000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0\tmodule" }
    func failRetirement() { failTrash = true }
    var complete = true
    var exitCode: Int32 = 0
    var segmentOverride: [String]?
    func incomplete() { complete = false }
    func failReadSet() { exitCode = 128 }
    func segments(_ values: [String]) { segmentOverride = values }
    func execute(_ readSet: GitChildWorktreeCleanupReadSet) throws -> GitChildWorktreeCleanupReadSetResult {
        guard readSet == (try GitChildWorktreeCleanupService.readSet(for: allocation)) else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("unexpected fixed readset")
        }
        commands.append(readSet.command)
        let fields = segmentOverride ?? [allocation.repositoryPath, allocation.workingDirectory,
            allocation.repositoryPath + "/.git", allocation.repositoryPath + "/.git",
            branch, status, index, head]
        return .init(exitCode: exitCode, stdout: fields.joined(separator: "\0"),
                     stderr: "", outputComplete: complete)
    }
    func trash(_ request: GitChildWorktreeCleanupRequest) throws -> URL {
        if failTrash { throw GitChildWorktreeCleanupService.CleanupError.rejected("synthetic trash failed") }
        trashRequests.append(request)
        return URL(fileURLWithPath: "/synthetic/trash/item")
    }
    func trashCount() -> Int { trashRequests.count }
    func recordedCommands() -> [String] { commands }
}

final class GitChildWorktreeCleanupTests: XCTestCase {
    private let root = GitChildWorktreeRoot(syntheticRoot: "/synthetic/home/.minis-worktrees")
    private func snapshot(active: Bool = false, revoked: Bool = true,
                          valid: Bool = true, mismatchedOwner: Bool = false,
                          generation: UUID = UUID()) throws -> GitChildWorktreeCleanupSnapshot {
        let id = GitChildWorktreeIdentity(taskID: "task", executionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                         parentSessionID: "session", parentContextSnapshotID: "context")
        let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: "/synthetic/repo", identity: id, managedRoot: root)
        let allocation = GitChildWorktreeAllocation(identity: id, repositoryPath: plan.workingDirectory, workingDirectory: plan.path,
                                                   branch: "minis/child-" + id.executionID.uuidString.lowercased())
        let owner = mismatchedOwner ? GitChildWorktreeIdentity(taskID: "other", executionID: id.executionID, parentSessionID: "session", parentContextSnapshotID: "context") : id
        return .init(allocation: allocation, parentIdentity: owner, goalID: "goal", scopeID: "scope", leaseID: "lease",
                     generation: generation, taskIsActive: active, childScopeRevoked: revoked, parentAuthorityValid: valid)
    }
    func testCleanRetirementUsesApprovedExactRequestAndRetainsMetadata() async throws {
        let value = try snapshot()
        let source = SyntheticCleanupSource(value)
        let git = SyntheticCleanupGit(value.allocation)
        let request = try await GitChildWorktreeCleanupService.prepare(source: source, managedRoot: root, readOnly: { try await git.execute($0) })
        XCTAssertTrue(request.approvalText.contains(value.allocation.workingDirectory))
        let result = try await GitChildWorktreeCleanupService.retire(request: request, source: source, managedRoot: root,
            readOnly: { try await git.execute($0) }, approvedTrash: { try await git.trash($0) })
        XCTAssertEqual(result.originalPath, value.allocation.workingDirectory)
        XCTAssertEqual(result.trashURL.path, "/synthetic/trash/item")
        XCTAssertEqual(result.message, "目录已移废纸篓，Git 登记与分支保留")
        let count = await git.trashCount()
        XCTAssertEqual(count, 1)
        let commands = await git.recordedCommands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertFalse(commands.contains { $0.contains("remove") || $0.contains("prune") || $0.contains("branch -") || $0.contains("clean") })
    }
    func testActiveUnrevokedInvalidOrCrossTaskOwnerCannotProduceRequest() async throws {
        for value in [try snapshot(active: true), try snapshot(revoked: false), try snapshot(valid: false), try snapshot(mismatchedOwner: true)] {
            let source = SyntheticCleanupSource(value)
            let git = SyntheticCleanupGit(value.allocation)
            do {
                _ = try await GitChildWorktreeCleanupService.prepare(source: source, managedRoot: root, readOnly: { try await git.execute($0) })
                XCTFail("invalid lifecycle must reject")
            } catch {}
            let commands = await git.recordedCommands()
            XCTAssertTrue(commands.isEmpty)
        }
    }
    func testDirtyUntrackedIgnoredOrSubmoduleBlocksPreparation() async throws {
        for status in [" M file", "?? user-data", "!! ignored-directory/"] {
            let value = try snapshot()
            let git = SyntheticCleanupGit(value.allocation)
            await git.dirty(status)
            do {
                _ = try await GitChildWorktreeCleanupService.prepare(source: SyntheticCleanupSource(value), managedRoot: root, readOnly: { try await git.execute($0) })
                XCTFail("nonempty status must reject")
            } catch {}
        }
        let value = try snapshot()
        let git = SyntheticCleanupGit(value.allocation)
        await git.submodule()
        do {
            _ = try await GitChildWorktreeCleanupService.prepare(source: SyntheticCleanupSource(value), managedRoot: root, readOnly: { try await git.execute($0) })
            XCTFail("submodule must reject")
        } catch {}
    }
    func testGitDriftAfterConfirmationDoesNotTrash() async throws {
        let value = try snapshot()
        let source = SyntheticCleanupSource(value)
        let git = SyntheticCleanupGit(value.allocation)
        let request = try await GitChildWorktreeCleanupService.prepare(source: source, managedRoot: root, readOnly: { try await git.execute($0) })
        await git.changeHead()
        do {
            _ = try await GitChildWorktreeCleanupService.retire(request: request, source: source, managedRoot: root,
                readOnly: { try await git.execute($0) }, approvedTrash: { try await git.trash($0) })
            XCTFail("source drift must reject")
        } catch {}
        let count = await git.trashCount()
        XCTAssertEqual(count, 0)
    }
    func testLifecycleOrPathDriftDoesNotTrash() async throws {
        let value = try snapshot()
        let source = SyntheticCleanupSource(value)
        let git = SyntheticCleanupGit(value.allocation)
        let request = try await GitChildWorktreeCleanupService.prepare(source: source, managedRoot: root, readOnly: { try await git.execute($0) })
        await source.rejectPath()
        do {
            _ = try await GitChildWorktreeCleanupService.retire(request: request, source: source, managedRoot: root,
                readOnly: { try await git.execute($0) }, approvedTrash: { try await git.trash($0) })
            XCTFail("path boundary must reject")
        } catch {}
        await source.set(try snapshot(active: true))
        do {
            _ = try await GitChildWorktreeCleanupService.retire(request: request, source: source, managedRoot: root,
                readOnly: { try await git.execute($0) }, approvedTrash: { try await git.trash($0) })
            XCTFail("lifecycle changed")
        } catch {}
        let count = await git.trashCount()
        XCTAssertEqual(count, 0)
    }
    func testTrashFailurePropagatesWithoutFallbackOrSourceMutation() async throws {
        let value = try snapshot()
        let source = SyntheticCleanupSource(value)
        let git = SyntheticCleanupGit(value.allocation)
        let request = try await GitChildWorktreeCleanupService.prepare(source: source, managedRoot: root, readOnly: { try await git.execute($0) })
        await git.failRetirement()
        do {
            _ = try await GitChildWorktreeCleanupService.retire(request: request, source: source, managedRoot: root,
                readOnly: { try await git.execute($0) }, approvedTrash: { try await git.trash($0) })
            XCTFail("trash failure must propagate")
        } catch {}
        let unchanged = await source.currentSnapshot()
        XCTAssertEqual(unchanged, value)
        let count = await git.trashCount()
        XCTAssertEqual(count, 0)
    }
}


extension GitChildWorktreeCleanupTests {
    func testFixedReadSetContainsEightChecksTwoQuotedPathsAndCompleteChecklist() throws {
        let value = try snapshot()
        let readSet = try GitChildWorktreeCleanupService.readSet(for: value.allocation)
        XCTAssertEqual(readSet.command.components(separatedBy: " && printf '\\000' && ").count, 8)
        XCTAssertEqual(readSet.command.components(separatedBy: "git -C ").count - 1, 8)
        XCTAssertTrue(readSet.command.contains("git -C '/synthetic/repo' rev-parse --show-toplevel"))
        XCTAssertTrue(readSet.approvalChecklist.contains(value.allocation.repositoryPath))
        XCTAssertTrue(readSet.approvalChecklist.contains(value.allocation.workingDirectory))
        XCTAssertTrue(readSet.approvalChecklist.contains("8. git -C "))
        XCTAssertFalse(readSet.command.contains(" -z"))
    }

    func testMissingExtraIncompleteAndNonzeroReadSetsRejectWithoutTrash() async throws {
        let value = try snapshot()
        let valid = [value.allocation.repositoryPath, value.allocation.workingDirectory,
                     "/synthetic/repo/.git", "/synthetic/repo/.git",
                     "refs/heads/" + value.allocation.branch, "", "", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
        for count in [7, 9] {
            let git = SyntheticCleanupGit(value.allocation)
            await git.segments(count == 7 ? Array(valid.prefix(7)) : valid + ["extra"])
            do {
                _ = try await GitChildWorktreeCleanupService.prepare(source: SyntheticCleanupSource(value), managedRoot: root, readOnly: { try await git.execute($0) })
                XCTFail("wrong segment count must reject")
            } catch {}
        }
        for incomplete in [true, false] {
            let git = SyntheticCleanupGit(value.allocation)
            if incomplete { await git.incomplete() } else { await git.failReadSet() }
            do {
                _ = try await GitChildWorktreeCleanupService.prepare(source: SyntheticCleanupSource(value), managedRoot: root, readOnly: { try await git.execute($0) })
                XCTFail("incomplete/nonzero must reject")
            } catch {}
        }
    }

    func testFixedReadSetRejectsControlPathsAndQuotesTrustedApostrophe() throws {
        let value = try snapshot()
        for path in ["/synthetic/repo\nother", "/synthetic/repo\0other", "/synthetic/repo\tother"] {
            let allocation = GitChildWorktreeAllocation(identity: value.allocation.identity, repositoryPath: path,
                workingDirectory: value.allocation.workingDirectory, branch: value.allocation.branch)
            XCTAssertThrowsError(try GitChildWorktreeCleanupService.readSet(for: allocation))
        }
        let allocation = GitChildWorktreeAllocation(identity: value.allocation.identity, repositoryPath: "/synthetic/repo's",
            workingDirectory: value.allocation.workingDirectory, branch: value.allocation.branch)
        let readSet = try GitChildWorktreeCleanupService.readSet(for: allocation)
        XCTAssertTrue(readSet.command.contains("repo'\\''s'"))
    }
}


extension GitChildWorktreeCleanupTests {
    func testStructuredIndexAcceptsRegularExecutableSymlinkAndSHA256() async throws {
        let value = try snapshot()
        let git = SyntheticCleanupGit(value.allocation)
        let sha1 = String(repeating: "a", count: 40)
        let sha256 = String(repeating: "b", count: 64)
        await git.setIndex("100644 " + sha1 + " 0\tregular\n100755 " + sha1 + " 0\texecutable\n120000 " + sha256 + " 0\tsymlink\n")
        _ = try await GitChildWorktreeCleanupService.prepare(source: SyntheticCleanupSource(value), managedRoot: root, readOnly: { try await git.execute($0) })
    }

    func testStructuredIndexRejectsRedactedModeAndAbnormalObjectLength() async throws {
        let sha1 = String(repeating: "a", count: 40)
        for index in ["[REDACTED] " + sha1 + " 0\tmodule",
                      "100644 abc 0\tfile",
                      "100644 " + String(repeating: "a", count: 41) + " 0\tfile"] {
            let value = try snapshot()
            let git = SyntheticCleanupGit(value.allocation)
            await git.setIndex(index)
            do {
                _ = try await GitChildWorktreeCleanupService.prepare(source: SyntheticCleanupSource(value), managedRoot: root, readOnly: { try await git.execute($0) })
                XCTFail("invalid structured evidence must reject")
            } catch let error as GitChildWorktreeCleanupService.CleanupError {
                XCTAssertEqual(error, .rejected("检查输出被改写或结构异常，未移动目录"))
            }
        }
    }
}
