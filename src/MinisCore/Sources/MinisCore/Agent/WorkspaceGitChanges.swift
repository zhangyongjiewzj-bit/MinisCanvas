import Foundation

/// 只读的“工作区改动”：`git status --porcelain` + `git diff HEAD`。
/// 给改动面板和 /diff 用，包含命令行（shell）造成的改动。
/// - 只读：固定参数、不经 shell、不跑外部 diff 程序和钩子，不联网；
/// - 输出封顶（读取 1 MB、显示 200000 字符）并先脱敏；
/// - 敏感路径只列文件名，不读内容也不出现在 diff 里。
public struct WorkspaceGitChanges: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let status: String
        public let path: String
        /// 敏感文件：只列名字，内容与 diff 都不读取。
        public let isSensitive: Bool
        public var id: String { status + "\0" + path }
    }

    public let entries: [Entry]
    public let diff: String
    public let diffTruncated: Bool
    /// 不是 git 仓库、没有提交或读取失败时的中文说明；正常时为 nil。
    public let notice: String?

    public static let maximumReadBytes = 1024 * 1024
    public static let maximumDisplayCharacters = 200_000
    static let timeoutSeconds: TimeInterval = 15

    public static func load(directory: String) async -> WorkspaceGitChanges {
        await Task.detached(priority: .userInitiated) { loadBlocking(directory: directory) }.value
    }

    static func loadBlocking(directory: String) -> WorkspaceGitChanges {
        func empty(_ notice: String) -> WorkspaceGitChanges {
            WorkspaceGitChanges(entries: [], diff: "", diffTruncated: false, notice: notice)
        }
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"),
              FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return empty("当前会话没有可用的工作目录。")
        }
        guard let status = runGit(["status", "--porcelain=v1", "-z", "--untracked-files=normal"], directory: directory),
              status.exitCode == 0 else {
            return empty("这个目录不是 git 仓库，或 git 暂时无法读取。")
        }
        let entries = parseStatus(status.data, directory: directory)
        var diffArguments = ["diff", "HEAD", "--no-ext-diff", "--no-textconv", "--no-color"]
        let hidden = entries.filter(\.isSensitive).map(\.path)
        if !hidden.isEmpty {
            diffArguments.append("--")
            diffArguments.append(".")
            diffArguments += hidden.map { ":(exclude,literal)" + $0 }
        }
        var notice: String?
        var diffText = ""
        var truncated = false
        if let diff = runGit(diffArguments, directory: directory) {
            if diff.exitCode == 0 || diff.truncated {
                let decoded = String(decoding: diff.data, as: UTF8.self)
                diffText = ContentSecretRedactor.redact(decoded, knownSecrets: ModelShellEnvironment.knownCredentialValues())
                if diffText.count > maximumDisplayCharacters {
                    diffText = String(diffText.prefix(maximumDisplayCharacters))
                    truncated = true
                }
                truncated = truncated || diff.truncated
            } else {
                notice = "还没有提交记录，无法对比 HEAD；下面只列出文件状态。"
            }
        } else {
            notice = "git 差异读取失败或超时。"
        }
        if !hidden.isEmpty {
            let extra = "有 \(hidden.count) 个敏感文件的改动不显示内容，只列出文件名。"
            notice = notice.map { $0 + " " + extra } ?? extra
        }
        return WorkspaceGitChanges(entries: entries, diff: diffText, diffTruncated: truncated, notice: notice)
    }

    /// `git status --porcelain=v1 -z`：每项为 "XY path"，改名/复制后面跟一个原路径项。
    static func parseStatus(_ data: Data, directory: String) -> [Entry] {
        let parts = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var entries: [Entry] = []
        var index = 0
        while index < parts.count {
            let item = parts[index]
            index += 1
            guard item.count > 3 else { continue }
            let status = String(item.prefix(2))
            let path = String(item.dropFirst(3))
            if status.contains("R") || status.contains("C") { index += 1 }
            let absolute = URL(fileURLWithPath: directory).appendingPathComponent(path).path
            let sensitive = SensitiveFilePolicy.contains(path) || SensitiveFilePolicy.contains(absolute)
                || SensitiveFilePolicy.isCredentialPath(absolute)
            entries.append(Entry(status: status, path: ContentSecretRedactor.redact(path), isSensitive: sensitive))
        }
        return entries
    }

    private struct GitOutput {
        let data: Data
        let exitCode: Int32
        let truncated: Bool
    }

    /// 固定参数的只读 git 调用；不经 shell，不带凭据环境变量。
    private static func runGit(_ arguments: [String], directory: String) -> GitOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // 关掉可能执行外部程序的仓库配置（fsmonitor、钩子目录）。
        process.arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                             "-c", "core.quotepath=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timer)
        defer { timer.cancel() }
        var data = Data()
        var truncated = false
        let reader = pipe.fileHandleForReading
        while true {
            guard let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            if data.count + chunk.count > maximumReadBytes {
                data.append(chunk.prefix(maximumReadBytes - data.count))
                truncated = true
                if process.isRunning { process.terminate() }
                break
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        return GitOutput(data: data, exitCode: process.terminationStatus, truncated: truncated)
    }
}
