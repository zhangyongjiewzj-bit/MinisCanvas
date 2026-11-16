import Foundation

/// Converts real shell outcomes to ordinary tool-result fields that return to
/// the conversation. No process, authentication or network access occurs here.
public enum GitWorkflowProjection {
    public static func sessionFields(command: String, exitCode: Int32, stdout: String, stderr: String) -> [String: String] {
        let words = TerminalGuard.inspect(command).words
        guard words.first == "git" || words.first == "gh" else { return [:] }
        if exitCode != 0 {
            let diagnostic = (stdout + "\n" + stderr).lowercased()
            if diagnostic.contains("authentication failed") || diagnostic.contains("gh auth login") || diagnostic.contains("permission denied (publickey)") || diagnostic.contains("not logged") {
                return ["git_workflow_notice": "认证未完成。请在外部终端完成 git/gh 认证后重试；不要在会话中粘贴凭据。"]
            }
            if diagnostic.contains("conflict") || diagnostic.contains("unmerged") {
                return ["git_workflow_notice": "存在合并冲突。先查看 git status 和冲突差异，再确认解决方式；未自动覆盖或重置。"]
            }
            return [:]
        }
        guard words.starts(with: ["gh", "pr"]) else { return [:] }
        var result: [String: String] = [:]
        if let data = stdout.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let url = object["url"] as? String, let normalized = pullRequestURL(url) { result["git_pr_url"] = normalized }
            if let state = object["state"] as? String, ["OPEN", "CLOSED", "MERGED"].contains(state.uppercased()) { result["git_pr_state"] = state.uppercased() }
            if let draft = object["isDraft"] as? Bool { result["git_pr_draft"] = draft ? "true" : "false" }
        }
        if result["git_pr_url"] == nil {
            for line in stdout.split(whereSeparator: \.isNewline) {
                if let url = pullRequestURL(String(line).trimmingCharacters(in: .whitespaces)) { result["git_pr_url"] = url; break }
            }
        }
        // `gh pr create` success gives a URL, not a verified open/merged state.
        return result
    }

    private static func pullRequestURL(_ value: String) -> String? {
        guard let url = URLComponents(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 4, parts[2] == "pull", !parts[3].isEmpty,
              parts[3].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return url.string
    }
}
