import XCTest
@testable import MinisCore

final class GitWorkflowPolicyTests: XCTestCase {
    func testReadOnlyFormsAndMutationRemainSeparate() {
        for command in ["git status --short", "git diff --stat", "git log -5", "git show HEAD", "git branch --list", "git remote -v", "git stash list", "git rev-parse HEAD", "git blame file.swift", "gh pr view 12 --json url,state", "gh pr list --state open", "gh pr status", "gh pr diff 12 --name-only"] {
            XCTAssertTrue(GitWorkflowPolicy.automaticallyAllows(command: command), command)
        }
        for command in ["git commit -m change", "git add .", "git branch new", "git push", "git checkout main", "git reset --hard", "git worktree add /tmp/test", "git stash pop", "gh pr create --title change", "gh auth status", "gh pr view --web", "gh alias list"] {
            XCTAssertFalse(GitWorkflowPolicy.automaticallyAllows(command: command), command)
        }
    }

    func testUnsafeArgumentsAndShellCompositionNeverAutoAllow() {
        for command in ["git -c core.pager=evil status", "git diff --output=file", "git log --ext-diff", "git blame --output=file", "git status; git push", "git status\ngit push", "/usr/bin/git status", "gh pr list --template evil", "gh pr list --repo -x", "gh pr view $(evil)"] {
            XCTAssertFalse(GitWorkflowPolicy.automaticallyAllows(command: command), command)
        }
    }

    func testTokenEntryPreservesQuotedArgumentBoundaries() {
        XCTAssertTrue(GitWorkflowPolicy.automaticallyAllows(words: ["git", "diff", "--", "file with spaces.swift"]))
        XCTAssertFalse(GitWorkflowPolicy.automaticallyAllows(words: ["git", "diff", "--output=result"]))
        XCTAssertFalse(GitWorkflowPolicy.automaticallyAllows(words: ["git", "status;git", "push"]))
    }

    func testApprovalContextUsesActualSuppliedDiffstatAndMessage() {
        let context = GitWorkflowPolicy.approvalContext(command: "git commit -m '修复窗口恢复'", diffstat: "2 files changed")
        XCTAssertTrue(context?.contains("修复窗口恢复") == true)
        XCTAssertTrue(context?.contains("2 files changed") == true)
        XCTAssertNil(GitWorkflowPolicy.approvalContext(command: "git status"))
        XCTAssertTrue(GitWorkflowPolicy.approvalContext(command: "gh pr create")?.contains("尚未读取") == true)
    }
}
