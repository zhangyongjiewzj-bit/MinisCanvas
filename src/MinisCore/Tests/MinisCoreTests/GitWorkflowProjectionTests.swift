import XCTest
@testable import MinisCore

final class GitWorkflowProjectionTests: XCTestCase {
    func testPRCreationReturnsURLWithoutInventingState() {
        let fields = GitWorkflowProjection.sessionFields(command: "gh pr create --title fix", exitCode: 0, stdout: "https://github.com/owner/repo/pull/42\n", stderr: "")
        XCTAssertEqual(fields["git_pr_url"], "https://github.com/owner/repo/pull/42")
        XCTAssertNil(fields["git_pr_state"])
    }
    func testPRViewReturnsObservedState() {
        let fields = GitWorkflowProjection.sessionFields(command: "gh pr view 42 --json url,state,isDraft", exitCode: 0, stdout: #"{"url":"https://git.example.org/a/b/pull/42","state":"MERGED","isDraft":false}"#, stderr: "")
        XCTAssertEqual(fields["git_pr_state"], "MERGED")
        XCTAssertEqual(fields["git_pr_draft"], "false")
    }
    func testFailureDoesNotAssociateURLAndDoesNotRepeatCredentials() {
        let fields = GitWorkflowProjection.sessionFields(command: "gh pr create", exitCode: 1, stdout: "https://github.com/a/b/pull/42", stderr: "gh auth login synthetic-secret")
        XCTAssertNil(fields["git_pr_url"])
        XCTAssertFalse(fields.values.joined().contains("synthetic-secret"))
        XCTAssertTrue(fields["git_workflow_notice"]?.contains("认证") == true)
    }
    func testConflictAndMalformedURL() {
        XCTAssertNotNil(GitWorkflowProjection.sessionFields(command: "git merge branch", exitCode: 1, stdout: "CONFLICT", stderr: "")["git_workflow_notice"])
        XCTAssertNil(GitWorkflowProjection.sessionFields(command: "gh pr create", exitCode: 0, stdout: "https://secret@github.com/a/b/pull/3", stderr: "")["git_pr_url"])
    }
}
