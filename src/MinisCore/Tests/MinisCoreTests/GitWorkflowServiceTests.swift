import XCTest
@testable import MinisCore

private actor SyntheticGitCommands {
    private var calls: [String] = []
    private let results: [String: GitWorkflowService.CommandResult]
    init(_ results: [String: GitWorkflowService.CommandResult]) { self.results = results }
    func execute(_ command: String, _ directory: String) throws -> GitWorkflowService.CommandResult {
        calls.append(directory + ":" + command)
        guard let result = results[command] else { throw GitWorkflowService.WorkflowError.unsupportedWriteCommand }
        return result
    }
    func recorded() -> [String] { calls }
}

final class GitWorkflowServiceTests: XCTestCase {
    func testCommitSummaryUsesRealStagedStatAndNeverExecutesWrite() async throws {
        let fixture = SyntheticGitCommands([
            "git status --short": .init(exitCode: 0, stdout: "M  file.swift", stderr: ""),
            "git diff --cached --stat": .init(exitCode: 0, stdout: "file.swift | 2 +-", stderr: "")
        ])
        let summary = try await GitWorkflowService.prepareWriteSummary(command: "git commit -m '修复恢复'", workingDirectory: "/synthetic/repo", readOnly: { try await fixture.execute($0, $1) })
        XCTAssertEqual(summary.diffstat, "file.swift | 2 +-")
        XCTAssertTrue(summary.approvalText.contains("修复恢复"))
        XCTAssertTrue(summary.approvalText.contains(summary.diffstat))
        let commands = await fixture.recorded()
        XCTAssertEqual(commands.count, 2)
        XCTAssertFalse(commands.contains(where: { $0.contains("git commit") }))
    }
    func testReadFailureDoesNotReturnInventedSummary() async throws {
        do {
            _ = try await GitWorkflowService.prepareWriteSummary(command: "git commit -m fix", workingDirectory: "/synthetic/repo", readOnly: { _, _ in .init(exitCode: 128, stdout: "", stderr: "synthetic failure") })
            XCTFail("failure must propagate")
        } catch let error as GitWorkflowService.WorkflowError {
            XCTAssertEqual(error, .commandFailed(command: "git status --short", exitCode: 128, stdout: "", stderr: "synthetic failure"))
        }
    }
    func testWorktreeChecksTargetBeforeReturningAndNeverRemoves() async throws {
        let plan = try GitWorktreePlan.prepare(repositoryPath: "/synthetic/repo", destinationPath: "/synthetic/child", branch: "child")
        let fixture = SyntheticGitCommands([
            plan.command: .init(exitCode: 0, stdout: "", stderr: ""),
            "git rev-parse --show-toplevel": .init(exitCode: 0, stdout: "/synthetic/child\n", stderr: "")
        ])
        let path = try await GitWorkflowService.createWorktree(plan: plan, executeApproved: { try await fixture.execute($0, $1) })
        XCTAssertEqual(path, plan.path)
        let calls = await fixture.recorded()
        XCTAssertEqual(calls, ["/synthetic/repo:" + plan.command, "/synthetic/child:git rev-parse --show-toplevel"])
    }
    func testWorktreeIdentityMismatchDoesNotReturnSuccess() async throws {
        let plan = try GitWorktreePlan.prepare(repositoryPath: "/synthetic/repo", destinationPath: "/synthetic/child", branch: "child")
        do {
            _ = try await GitWorkflowService.createWorktree(plan: plan, executeApproved: { command, _ in .init(exitCode: 0, stdout: command == plan.command ? "" : "/synthetic/other", stderr: "") })
            XCTFail("identity mismatch must propagate")
        } catch let error as GitWorkflowService.WorkflowError {
            XCTAssertEqual(error, .worktreeIdentityMismatch(expected: plan.path, actual: "/synthetic/other"))
        }
    }
    func testPRStateComesFromInjectedReadResult() async throws {
        let fields = try await GitWorkflowService.pullRequestState(number: 42, workingDirectory: "/synthetic/repo", readOnly: { command, _ in
            XCTAssertEqual(command, "gh pr view 42 --json url,state,isDraft")
            return .init(exitCode: 0, stdout: #"{"url":"https://github.com/a/b/pull/42","state":"OPEN","isDraft":true}"#, stderr: "")
        })
        XCTAssertEqual(fields["git_pr_state"], "OPEN")
    }
    func testPRSummaryReadsExplicitBaseWithoutNetworking() async throws {
        let fixture = SyntheticGitCommands([
            "git status --short": .init(exitCode: 0, stdout: "", stderr: ""),
            "git diff --stat 'main...HEAD'": .init(exitCode: 0, stdout: "feature.swift | 3 +++", stderr: "")
        ])
        let summary = try await GitWorkflowService.prepareWriteSummary(command: "gh pr create --title fix --body detail --base main", workingDirectory: "/synthetic/repo", readOnly: { try await fixture.execute($0, $1) })
        XCTAssertEqual(summary.diffstat, "feature.swift | 3 +++")
        let calls = await fixture.recorded()
        XCTAssertFalse(calls.contains(where: { $0.contains("gh pr create") }))
    }
    func testAllCommitIncludesTrackedWorkingChanges() async throws {
        let fixture = SyntheticGitCommands([
            "git status --short": .init(exitCode: 0, stdout: " M file.swift", stderr: ""),
            "git diff HEAD --stat": .init(exitCode: 0, stdout: "file.swift | 1 +", stderr: "")
        ])
        let summary = try await GitWorkflowService.prepareWriteSummary(command: "git commit --all --message fix", workingDirectory: "/synthetic/repo", readOnly: { try await fixture.execute($0, $1) })
        XCTAssertTrue(summary.approvalText.contains("消息：fix"))
        XCTAssertEqual(summary.diffstat, "file.swift | 1 +")
    }
    func testFailedWorktreeCreationNeverChecksOrAuthorizesTarget() async throws {
        let plan = try GitWorktreePlan.prepare(repositoryPath: "/synthetic/repo", destinationPath: "/synthetic/child", branch: "child")
        let fixture = SyntheticGitCommands([plan.command: .init(exitCode: 128, stdout: "", stderr: "branch exists")])
        do {
            _ = try await GitWorkflowService.createWorktree(plan: plan, executeApproved: { try await fixture.execute($0, $1) })
            XCTFail("creation failure must propagate")
        } catch let error as GitWorkflowService.WorkflowError {
            XCTAssertEqual(error, .commandFailed(command: plan.command, exitCode: 128, stdout: "", stderr: "branch exists"))
        }
        let calls = await fixture.recorded()
        XCTAssertEqual(calls.count, 1)
    }

}
