import Foundation

/// System git/gh orchestration through the application's existing execution
/// boundary. This type never launches a process or mints an approval itself.
public enum GitWorkflowService {
    public struct CommandResult: Equatable, Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public init(exitCode: Int32, stdout: String, stderr: String) {
            self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
        }
    }
    public typealias CommandExecutor = @Sendable (_ command: String, _ workingDirectory: String) async throws -> CommandResult

    public enum WorkflowError: Error, Equatable, Sendable {
        case invalidWorkingDirectory
        case missingMessage
        case missingPullRequestBase
        case unsupportedWriteCommand
        case commandFailed(command: String, exitCode: Int32, stdout: String, stderr: String)
        case worktreeIdentityMismatch(expected: String, actual: String)
    }

    public struct WriteSummary: Equatable, Sendable {
        public let command: String
        public let workingDirectory: String
        public let status: String
        public let diffstat: String
        public let approvalText: String
    }

    /// Read-only preflight for the exact proposed write command. No write is
    /// executed. Approval must still bind the unchanged command and cwd after
    /// this summary is presented. Diffstat is evidence at preflight time, not
    /// a guarantee that the index remains unchanged until execution.
    public static func prepareWriteSummary(command: String, workingDirectory: String, readOnly: CommandExecutor) async throws -> WriteSummary {
        try validateDirectory(workingDirectory)
        let inspected = TerminalGuard.inspect(command)
        guard inspected.isAllowed else { throw WorkflowError.unsupportedWriteCommand }
        let words = inspected.words
        let commit = words.starts(with: ["git", "commit"])
        guard commit || words.starts(with: ["gh", "pr", "create"]) else { throw WorkflowError.unsupportedWriteCommand }
        // Message must already be explicit so no editor/interactive body opens.
        var stageAll = false
        if commit {
            // 与审批卡共用同一套旗标解析（-am、-ma、--message=、--no-verify 等）。
            // Path-limited/--only/--include commits have different index semantics.
            // Do not present a staged stat as if it described those commands.
            guard let invocation = GitWorkflowPolicy.parseCommit(words: words) else { throw WorkflowError.unsupportedWriteCommand }
            // 先判形式是否受支持：--amend、带路径等形式解析会提前中止，此时 messages 为空不是“缺消息”。
            guard invocation.supported else { throw WorkflowError.unsupportedWriteCommand }
            guard !invocation.messages.isEmpty,
                  invocation.messages.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw WorkflowError.missingMessage }
            stageAll = invocation.stageAll
        } else {
            guard let messageIndex = words.indices.first(where: { words[$0] == "--title" }),
                  words.indices.contains(messageIndex + 1), !words[messageIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkflowError.missingMessage }
            // Explicit body avoids gh opening an editor after approval. An empty
            // body is valid when deliberately supplied as a quoted empty token.
            guard let bodyIndex = words.firstIndex(of: "--body"), words.indices.contains(bodyIndex + 1) else { throw WorkflowError.missingMessage }
        }
        let status = try await checked("git status --short", directory: workingDirectory, execute: readOnly)
        let diffCommand: String
        if commit {
            // -a stages tracked modifications as part of commit; a staged-only
            // stat would omit those actual proposed changes.
            diffCommand = stageAll ? "git diff HEAD --stat" : "git diff --cached --stat"
        } else {
            guard let baseIndex = words.firstIndex(of: "--base"), words.indices.contains(baseIndex + 1) else { throw WorkflowError.missingPullRequestBase }
            let base = words[baseIndex + 1]
            // Validate the branch reference with the same worktree ref contract.
            guard GitWorktreePlan.isValidReference(base) else { throw GitWorktreePlan.PlanError.invalidReference }
            diffCommand = "git diff --stat '" + base + "...HEAD'"
        }
        let diff = try await checked(diffCommand, directory: workingDirectory, execute: readOnly)
        let stat = diff.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = GitWorkflowPolicy.approvalContext(command: command, diffstat: stat.isEmpty ? "无差异统计（命令输出为空）" : stat) ?? ""
        return WriteSummary(command: command, workingDirectory: workingDirectory, status: status.stdout, diffstat: diff.stdout, approvalText: context)
    }

    /// Refreshes PR state via a finite read-only command and returns the same
    /// fields as shell execution. Failure remains an error with its real exit.
    public static func pullRequestState(number: Int, workingDirectory: String, readOnly: CommandExecutor) async throws -> [String: String] {
        try validateDirectory(workingDirectory)
        guard number > 0 else { throw WorkflowError.unsupportedWriteCommand }
        let command = "gh pr view \(number) --json url,state,isDraft"
        let result = try await checked(command, directory: workingDirectory, execute: readOnly)
        return GitWorkflowProjection.sessionFields(command: command, exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    /// executeApproved must route the write through existing call-bound approval.
    /// No authorization is inferred from a plan or from a forged success string.
    /// A failed post-create identity check deliberately preserves the directory;
    /// callers report the failure rather than removing user worktrees.
    public static func createWorktree(plan: GitWorktreePlan, executeApproved: CommandExecutor) async throws -> String {
        _ = try await checked(plan.command, directory: plan.workingDirectory, execute: executeApproved)
        let identity = try await checked("git rev-parse --show-toplevel", directory: plan.path, execute: executeApproved)
        let actual = identity.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actual.hasPrefix("/"),
              URL(fileURLWithPath: actual).standardizedFileURL.path
                == URL(fileURLWithPath: plan.path).standardizedFileURL.path else {
            throw WorkflowError.worktreeIdentityMismatch(expected: plan.path, actual: actual)
        }
        return plan.path
    }

    private static func checked(_ command: String, directory: String, execute: CommandExecutor) async throws -> CommandResult {
        let result = try await execute(command, directory)
        guard result.exitCode == 0 else {
            // Preserve raw diagnostics to the boundary; it must apply the normal
            // ContentSecretRedactor before exposing these strings to UI/model.
            throw WorkflowError.commandFailed(command: command, exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        }
        return result
    }

    private static func validateDirectory(_ path: String) throws {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw WorkflowError.invalidWorkingDirectory }
    }
}
