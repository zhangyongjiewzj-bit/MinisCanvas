import XCTest
@testable import MinisCore

final class GitWorktreePlanTests: XCTestCase {
    func testPlanKeepsRepositoryAndDestinationDistinct() throws {
        let plan = try GitWorktreePlan.prepare(repositoryPath: "/synthetic/repo", destinationPath: "/synthetic/child one", branch: "codex/child-1")
        XCTAssertEqual(plan.workingDirectory, "/synthetic/repo")
        XCTAssertEqual(plan.path, "/synthetic/child one")
        XCTAssertEqual(plan.command, "git worktree add -b 'codex/child-1' '/synthetic/child one' 'HEAD'")
        XCTAssertFalse(GitWorkflowPolicy.automaticallyAllows(command: plan.command))
    }
    func testUnsafeReferencesAndSameDestinationRejected() {
        for branch in ["-f", "bad..name", "a.lock", "a/.hidden", "bad;name", "@{1}"] {
            XCTAssertThrowsError(try GitWorktreePlan.prepare(repositoryPath: "/synthetic/repo", destinationPath: "/synthetic/child", branch: branch))
        }
        XCTAssertThrowsError(try GitWorktreePlan.prepare(repositoryPath: "/synthetic/repo", destinationPath: "/synthetic/repo/../repo", branch: "child"))
    }
    func testDestinationShellQuoteIsEscapedWithoutExecution() throws {
        let plan = try GitWorktreePlan.prepare(repositoryPath: "/synthetic/repo", destinationPath: "/synthetic/it's child", branch: "child")
        XCTAssertTrue(plan.command.contains("it'\\''s child"))
    }
}
