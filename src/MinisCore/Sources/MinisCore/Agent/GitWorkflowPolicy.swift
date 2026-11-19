import Foundation

/// Classification only. Execution, root authorization and call-bound approvals stay
/// with TerminalBoundary/ToolExecutor. A false result means ask, never hard deny.
public enum GitWorkflowPolicy {
    public static func automaticallyAllows(command: String) -> Bool {
        guard PersistentApprovalRuleMatcher.unsafeShellTextReason(command) == nil else { return false }
        let inspected = TerminalGuard.inspect(command)
        guard inspected.isAllowed else { return false }
        return automaticallyAllows(words: inspected.words)
    }

    /// Caller supplies tokens from a successful TerminalGuard inspection.
    /// Re-encoding each token preserves quoted spaces and never changes argv.
    public static func automaticallyAllows(words: [String]) -> Bool {
        guard let executable = words.first,
              PersistentApprovalRuleMatcher.unsafeShellTextReason(words.joined(separator: " ")) == nil else { return false }
        let command = words.map(shellQuote).joined(separator: " ")
        guard executable == "git" || executable == "gh" else { return false }
        if executable == "git" {
            if case .pattern(let pattern) = PersistentApprovalRuleMatcher.evaluateShell(command: command),
               pattern.hasPrefix("git ") { return true }
            guard words.count >= 2 else { return false }
            let tail = Array(words.dropFirst(2))
            switch words[1] {
            case "remote": return tail.isEmpty || tail == ["-v"] || tail == ["--verbose"]
            case "stash": return tail == ["list"]
            case "rev-parse", "blame":
                // Reuse the existing gitReadOnly argument policy; do not create
                // another implementation of config/helper/output rejection.
                if case .pattern = PersistentApprovalRuleMatcher.evaluateShell(
                    command: "git log " + tail.map(shellQuote).joined(separator: " ")) { return true }
                return false
            default: return false
            }
        }
        guard words.count >= 3, words[1] == "pr",
              ["view", "list", "status", "diff"].contains(words[2]) else { return false }
        // Explicit finite forms: no gh aliases, --web, --template, extension,
        // authentication commands or arbitrary global flags auto-approve.
        let arguments = Array(words.dropFirst(3))
        let flags: Set<String> = ["--json", "--state", "--limit", "--base", "--head", "--author", "--assignee", "--label", "--search", "--repo", "-R"]
        let switches: Set<String> = ["--comments", "--patch", "--name-only", "--color=never"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if switches.contains(argument) { index += 1; continue }
            if flags.contains(argument) {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else { return false }
                index += 2; continue
            }
            // Only numeric PR selectors; branch/URL selectors still work after approval.
            guard !argument.isEmpty, argument.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            index += 1
        }
        return true
    }

    private static func shellQuote(_ token: String) -> String {
        "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static let workflowInstructions = "提交与 PR：先查看 git status、git diff 和 diffstat，拟定提交消息并交用户确认；多行提交消息用多个 -m，或在双引号里直接换行，不要用 $(cat <<EOF …) 命令替换（会被拒绝）；写入、提交、分支、推送及 gh pr create 均通过命令审批。发现冲突时先列出冲突文件并请用户选择处理方式，不自动 reset、强推或覆盖。认证失败时提示在外部终端完成 gh auth login 后重试，不读取或输出凭据。可选 worktree 隔离必须先审批创建并授权新目录。"

    /// `git commit` 的统一旗标解析（审批摘要与差异统计两处共用）。
    /// 支持 -m、-mMSG、--message MSG、--message=MSG、-a/--all、-am、-ma、
    /// -s/--signoff、-n/--no-verify、-q/--quiet；其余形式（路径、--only 等）标为不支持，
    /// 因为它们的暂存语义不同，不能把“已暂存统计”当作真实差异展示。
    public struct CommitInvocation: Equatable, Sendable {
        public var messages: [String] = []
        public var stageAll = false
        public var supported = true
    }

    public static func parseCommit(words: [String]) -> CommitInvocation? {
        guard words.starts(with: ["git", "commit"]) else { return nil }
        var result = CommitInvocation()
        var index = 2
        while index < words.count {
            let word = words[index]
            if word == "--message" {
                guard words.indices.contains(index + 1) else { result.supported = false; break }
                result.messages.append(words[index + 1]); index += 2; continue
            }
            if word.hasPrefix("--message=") {
                result.messages.append(String(word.dropFirst("--message=".count))); index += 1; continue
            }
            if word == "--all" { result.stageAll = true; index += 1; continue }
            if ["--signoff", "--no-verify", "--quiet"].contains(word) { index += 1; continue }
            if word.hasPrefix("-"), !word.hasPrefix("--"), word.count > 1 {
                var consumedNext = false
                var chars = Array(word.dropFirst())
                var position = 0
                while position < chars.count {
                    let flag = chars[position]
                    if flag == "a" { result.stageAll = true }
                    else if ["s", "n", "q"].contains(flag) { }
                    else if flag == "m" {
                        let attached = String(chars[(position + 1)...])
                        if !attached.isEmpty { result.messages.append(attached) }
                        else if words.indices.contains(index + 1) { result.messages.append(words[index + 1]); consumedNext = true }
                        else { result.supported = false }
                        chars = []
                        break
                    } else { result.supported = false; chars = []; break }
                    position += 1
                }
                index += consumedNext ? 2 : 1
                if !result.supported { break }
                continue
            }
            result.supported = false
            break
        }
        return result
    }

    /// Display context only; this must never grant approval or invent a diffstat.
    public static func approvalContext(command: String, diffstat: String? = nil) -> String? {
        let words = TerminalGuard.inspect(command).words
        guard words.starts(with: ["git", "commit"]) || words.starts(with: ["gh", "pr", "create"]) else { return nil }
        let messages: [String]
        if let commit = parseCommit(words: words) {
            messages = commit.messages
        } else {
            messages = words.indices.compactMap { index -> String? in
                if words[index] == "--title", words.indices.contains(index + 1) { return words[index + 1] }
                if words[index].hasPrefix("--title=") { return String(words[index].dropFirst("--title=".count)) }
                return nil
            }
        }
        var lines = ["提交与 PR 写入需要本次确认", "消息：" + (messages.isEmpty ? "未提供；请先拟定消息" : messages.joined(separator: "\n\n"))]
        if words.starts(with: ["gh", "pr", "create"]), let bodyIndex = words.firstIndex(of: "--body"), words.indices.contains(bodyIndex + 1) {
            lines.append("PR 正文：" + words[bodyIndex + 1])
        }
        lines.append("差异统计：" + (diffstat ?? "尚未读取；请先执行 git diff --stat（暂存提交用 --cached）"))
        return lines.joined(separator: "\n")
    }
}
