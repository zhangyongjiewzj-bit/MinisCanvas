import Foundation
import CryptoKit

// MARK: - Rule model

public enum PersistentApprovalRuleKind: String, Codable, Sendable {
    /// `shell_execute`: executable name plus subcommand, e.g. `git status`.
    case shellCommandPrefix = "shell-command-prefix"
    /// `file_write` / `file_edit`: a canonical session authorization root.
    case projectDirectory = "project-directory"
    /// `web_fetch`: one normalized host in the existing project scope.
    case webHost = "web-host"
    /// `mcp_*`: one MCP tool of one server configuration (`<服务器配置指纹>:<工具全名>`).
    /// Never a wildcard: a server whose command/args/url changes no longer matches.
    case mcpTool = "mcp-tool"
    /// `session_read` / `session_send` / `external_session_send`: one target session
    /// (`app:<UUID>` or `external:<来源>:<UUID>`), never a wildcard, not bound to a project.
    case sessionTarget = "session-target"
}

/// 规则类别（对齐 Claude Code /permissions）：允许（命中免问）、拒绝（命中直接拒绝，
/// 所有档位包括绕过档，优先级最高）、每次询问（命中一定弹卡，绕过档除外，卡上不提供"以后都允许"）。
/// 旧规则文件里没有这个字段，一律按"允许"读。
public enum PersistentApprovalRuleBehavior: String, Codable, Sendable {
    case allow, deny, ask
}

/// 规则来源：审批卡上点的"以后都允许" / 面板里手动新增 / 从 Claude Code 设置文件导入。
public enum PersistentApprovalRuleOrigin: String, Codable, Sendable {
    case approvalCard = "approval-card"
    case manual
    case imported
}

/// One user-created "allow from now on" rule. A rule never replaces the
/// per-call approval receipt: a rule hit still mints a call-bound receipt in
/// `ComposerPolicyEnforcedToolExecutor`.
public struct PersistentApprovalRule: Codable, Sendable, Identifiable, Equatable {
    /// 全局规则的项目键：不绑定项目，所有项目都适用。
    public static let globalProjectKey = "*global*"

    public let id: String
    /// Stable digest of the canonical session authorization roots in force
    /// when the rule was created. A different project never matches.
    public let projectKey: String
    public let projectRoots: [String]
    public let kind: PersistentApprovalRuleKind
    public let capability: String
    /// Command prefix (`git status`) or canonical root directory.
    public let pattern: String
    public let createdAt: Date
    public let behavior: PersistentApprovalRuleBehavior
    public let origin: PersistentApprovalRuleOrigin
    /// 最近一次命中时间（写盘按分钟节流，只用于面板显示）。
    public var lastMatchedAt: Date?

    public var isGlobal: Bool { projectKey == Self.globalProjectKey }

    public init(
        id: String = UUID().uuidString,
        projectKey: String,
        projectRoots: [String],
        kind: PersistentApprovalRuleKind,
        capability: String,
        pattern: String,
        createdAt: Date = Date(),
        behavior: PersistentApprovalRuleBehavior = .allow,
        origin: PersistentApprovalRuleOrigin = .approvalCard,
        lastMatchedAt: Date? = nil
    ) {
        self.id = id
        self.projectKey = projectKey
        self.projectRoots = projectRoots
        self.kind = kind
        self.capability = capability
        self.pattern = pattern
        self.createdAt = createdAt
        self.behavior = behavior
        self.origin = origin
        self.lastMatchedAt = lastMatchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectKey, projectRoots, kind, capability, pattern, createdAt, behavior, origin, lastMatchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectKey = try c.decode(String.self, forKey: .projectKey)
        projectRoots = try c.decode([String].self, forKey: .projectRoots)
        kind = try c.decode(PersistentApprovalRuleKind.self, forKey: .kind)
        capability = try c.decode(String.self, forKey: .capability)
        pattern = try c.decode(String.self, forKey: .pattern)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        behavior = try c.decodeIfPresent(PersistentApprovalRuleBehavior.self, forKey: .behavior) ?? .allow
        origin = try c.decodeIfPresent(PersistentApprovalRuleOrigin.self, forKey: .origin) ?? .approvalCard
        lastMatchedAt = try c.decodeIfPresent(Date.self, forKey: .lastMatchedAt)
    }

    /// 命中时间不参与相等判断（它只是显示用的统计）。
    public static func == (lhs: PersistentApprovalRule, rhs: PersistentApprovalRule) -> Bool {
        lhs.id == rhs.id && lhs.projectKey == rhs.projectKey && lhs.projectRoots == rhs.projectRoots
            && lhs.kind == rhs.kind && lhs.capability == rhs.capability && lhs.pattern == rhs.pattern
            && lhs.createdAt == rhs.createdAt && lhs.behavior == rhs.behavior && lhs.origin == rhs.origin
    }
}

/// 规则范围：本会话（只在内存）、本项目、全局。
public enum PersistentApprovalRuleScope: Sendable, Equatable {
    case session(String)
    case project
    case global
}

/// 面板里新增规则时可选的类型。
public enum PermissionRuleType: String, Sendable, CaseIterable, Equatable {
    case shellPrefix, readDirectory, writePath, webHost, mcpTool, webSearch
}

/// 面板里的一行：规则 + 它的范围。
public struct PersistentApprovalRuleEntry: Sendable, Equatable, Identifiable {
    public let rule: PersistentApprovalRule
    public let scope: PersistentApprovalRuleScope
    public var id: String { rule.id }
    public init(rule: PersistentApprovalRule, scope: PersistentApprovalRuleScope) {
        self.rule = rule
        self.scope = scope
    }
}

/// What the approval prompt may offer for one pending call. It grants no
/// authority and is not part of the request identity digest.
public struct ApprovalPersistentAllowOffer: Sendable, Equatable {
    public let capability: String
    /// Human-readable pattern the rule would cover (command prefix or root).
    public let summary: String
    /// Non-nil when "allow from now on" must be hidden or disabled.
    public let unavailableReason: String?
    /// An exact scope constraint for an offered singleton git status rule.
    public let projectKey: String?
    public var isAvailable: Bool { unavailableReason == nil }

    public init(capability: String, summary: String, unavailableReason: String?) {
        self.init(capability: capability, summary: summary, unavailableReason: unavailableReason,
                  projectKey: nil)
    }

    init(capability: String, summary: String, unavailableReason: String?, projectKey: String?) {
        self.capability = capability
        self.summary = summary
        self.unavailableReason = unavailableReason
        self.projectKey = projectKey
    }
}

// MARK: - Matching

public enum PersistentApprovalRuleMatcher {
    public static let skillAlwaysPattern = "skill-action-risk-v1:always"
    public static let skillBypassPattern = "skill-action-risk-v1:bypass"
    public static let supportedCapabilities: Set<String> =
        Set(["shell_execute", "file_write", "file_edit", "file_read", "web_fetch", "web_search"])
            .union(SkillMaintenanceTool.names)

    /// `web_search` 的规则按工具记（不绑定搜索词）：本项目内以后搜索不再询问。
    public static let webSearchAlwaysPattern = "web-search:always"

    /// Shown by the older single-command evaluator for a command that has no entry in
    /// `persistentAllowlist`. Shell rules are now command-prefix rules (see
    /// `ShellRuleEvaluation`); this text is no longer the general reason.
    public static let unsupportedCommandReason = "该命令不支持以后都允许"

    /// How the arguments after the allowlisted prefix are checked.
    enum ArgumentPolicy: Equatable, Sendable {
        /// Build/test runners (`swift build/test`, `npm test`, `yarn test`,
        /// `pnpm test`): ordinary flags only. Options that move the working
        /// directory, package path, scope or registry, `-X…` pass-through flags,
        /// absolute/`~` paths and `..` are rejected (see `isSafeBuildToolArgument`).
        case buildTool
        /// No arguments at all.
        case none
        /// Read-only git: reject config injection, helper programs, file output.
        case gitReadOnly
        /// `git branch` may only list: fixed read-only flags, no positionals.
        case gitBranchList
        /// Flags of plain letters, or relative paths without `..`, `~`, `/` prefix.
        case relativePathsOnly
        /// `npm run <script>`: the pattern also contains the script name; the
        /// remaining arguments follow the `buildTool` rules.
        case scriptName
    }

    /// Argument-check table for the command families that have a dedicated argument rule
    /// (read-only git, build/test runners, `ls`, `pwd`). Key = pattern prefix, value =
    /// argument rule. It is NOT the list of commands that can be remembered: shell
    /// "以后都允许" rules are command-prefix rules for almost any command; the commands that
    /// can never be remembered are in `neverPersistExecutables` and the argument-shape
    /// checks, and every remembered command still goes through `ShellEffectGuard`.
    ///
    /// Why the git entries here are read-only subcommands: `git config` can plant
    /// `core.fsmonitor` / `core.pager` / `alias.*` that make later "harmless" `git status`
    /// run arbitrary code; git arguments are checked by `isSafeGitArgument`.
    /// `swift build/test` and `npm test/run` still execute project code
    /// (Package.swift, package.json scripts); that is inherent to "build/test
    /// this project" and is the trade-off the user accepted. Their arguments
    /// may not redirect the run to another directory or package, though.
    static let persistentAllowlist: [String: ArgumentPolicy] = [
        "git status": .gitReadOnly,
        "git diff": .gitReadOnly,
        "git log": .gitReadOnly,
        "git show": .gitReadOnly,
        "git branch": .gitBranchList,
        "swift build": .buildTool,
        "swift test": .buildTool,
        "npm test": .buildTool,
        "npm run": .scriptName,
        "yarn test": .buildTool,
        "pnpm test": .buildTool,
        "make test": .none,
        "ls": .relativePathsOnly,
        "pwd": .none,
    ]

    public enum Evaluation: Equatable, Sendable {
        case pattern(String)
        case unavailable(String)
    }

    /// ASCII shell syntax that can start a second command or an expansion.
    /// Compared per Unicode scalar: Swift folds "\r\n" (and an operator plus a
    /// combining mark) into one `Character` that never equals ";" or "\n".
    static let shellMetacharacterScalars: Set<Unicode.Scalar> = Set(";&|$()`><".unicodeScalars)

    public static func evaluateWebFetch(input: [String: Any]) -> Evaluation {
        guard let raw = input["url"] as? String, let url = URL(string: raw),
              BrowserNavigationPolicy.isValidWebURL(url),
              let host = url.host.flatMap(BrowserNavigationPolicy.normalizedHost) else {
            return .unavailable("网页地址无效，无法按网站记住")
        }
        return .pattern(host)
    }

    public static func evaluateShell(input: [String: Any], defaultWorkingDirectory: String?) -> Evaluation {
        guard let command = input["command"] as? String else { return .unavailable("命令缺失") }
        if let cwd = ShellToolInput.explicitWorkingDirectory(input) {
            guard let raw = cwd as? String, raw.hasPrefix("/"),
                  let defaultWorkingDirectory,
                  let directory = PolicyRuntimePathBoundary.canonicalPath(raw),
                  let expected = PolicyRuntimePathBoundary.canonicalPath(defaultWorkingDirectory),
                  directory == expected else {
                return .unavailable("工作目录与会话默认目录不同，每次都需询问")
            }
        }
        return evaluateShell(command: command)
    }

    public static func evaluateShell(command: String) -> Evaluation {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable("命令为空") }
        if let reason = unsafeShellTextReason(command) { return .unavailable(reason) }
        let inspected = TerminalGuard.inspect(trimmed)
        guard inspected.isAllowed, let first = inspected.words.first else {
            return .unavailable("命令不是单条简单命令，每次都需询问")
        }
        guard !first.contains("/"), isPlainToken(first, allowed: executableCharacters) else {
            return .unavailable("以路径方式调用的命令每次都需询问")
        }
        if TerminalPolicySnapshot.productHardDeniedCommands.contains(first) {
            return .unavailable("产品策略不允许该命令")
        }
        let words = inspected.words
        var pattern: String
        let policy: ArgumentPolicy
        var consumed: Int
        if words.count > 1, isPlainToken(words[1], allowed: subcommandCharacters),
           let entry = persistentAllowlist["\(first) \(words[1])"] {
            pattern = "\(first) \(words[1])"; policy = entry; consumed = 2
        } else if let entry = persistentAllowlist[first] {
            pattern = first; policy = entry; consumed = 1
        } else {
            return .unavailable(unsupportedCommandReason)
        }
        if policy == .scriptName {
            guard words.count > 2, !words[2].hasPrefix("-"),
                  isPlainToken(words[2], allowed: scriptCharacters) else {
                return .unavailable("npm run 需要带脚本名才能记住")
            }
            pattern += " \(words[2])"
            consumed = 3
        }
        let arguments = Array(words.dropFirst(consumed))
        guard argumentsAreAcceptable(arguments, policy: policy) else {
            return .unavailable("参数含不在白名单内的选项，每次都需询问")
        }
        return .pattern(pattern)
    }

    /// Scalar-level scan of the raw command text (leading and trailing
    /// whitespace included). Anything that is a metacharacter, a control
    /// character (tab, CR, LF, ...), non-ASCII whitespace or an invisible
    /// format character disables persistent allow.
    static func unsafeShellTextReason(_ command: String, allowingOperators: Bool = false) -> String? {
        var previous: Unicode.Scalar?
        for scalar in command.unicodeScalars {
            defer { previous = scalar }
            if !allowingOperators, shellMetacharacterScalars.contains(scalar) {
                return "命令含 ; & | $ ( ) ` > < ，每次都需询问"
            }
            switch scalar.properties.generalCategory {
            case .control:
                return "命令含换行、回车、制表符或其他控制字符，每次都需询问"
            case .lineSeparator, .paragraphSeparator:
                return "命令含 Unicode 行分隔符，每次都需询问"
            case .spaceSeparator where !scalar.isASCII:
                return "命令含非 ASCII 空白，每次都需询问"
            case .format:
                return "命令含不可见格式字符，每次都需询问"
            case .nonspacingMark, .spacingMark, .enclosingMark:
                if let previous, previous.isASCII,
                   !(previous.properties.isAlphabetic || previous.properties.numericType != nil) {
                    return "命令含紧跟标点或空白的组合符，每次都需询问"
                }
            default:
                break
            }
            if scalar.properties.isWhitespace && !scalar.isASCII {
                return "命令含非 ASCII 空白，每次都需询问"
            }
        }
        return nil
    }

    // MARK: Command-prefix rules (aligned with Claude Code)

    /// 以后都允许的 shell 规则按"命令前缀"保存（如 `npm run test`、`cargo build`），
    /// 任意命令都可以记住；复合命令（`&&` `||` `;` `|`）按每个子命令分别生成前缀，
    /// 命中规则时要求每个子命令都有对应规则。含重定向、命令替换、变量展开的写法
    /// 不提供，避免前缀规则被参数偷换。
    public enum ShellRuleEvaluation: Equatable, Sendable {
        case patterns([String])
        case unavailable(String)
    }

    /// 这些命令不提供"以后都允许"：删除、提权、格式化、关机、杀进程、改权限、
    /// 以及会把参数当作另一条命令执行的解释器和包装器。
    static let neverPersistExecutables: Set<String> = [
        "rm", "rmdir", "unlink", "shred", "sudo", "su", "doas", "dd", "mkfs", "shutdown",
        "reboot", "halt", "passwd", "launchctl", "diskutil", "security", "osascript",
        "kill", "killall", "pkill", "chmod", "chown", "chgrp", "mount", "umount",
        "systemsetup", "networksetup", "kextload",
        "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "eval", "exec", "source", ".",
        "xargs", "env", "nohup", "time", "command", "builtin", "nice", "timeout", "caffeinate",
        // 环境：会把环境变量里的密钥整段打印出来。
        "printenv", "export", "set", "declare", "typeset", "compgen",
        // 外发：能把本机内容送到网络另一端。包管理器和 git 的联网命令不在此列，
        // 它们可以记住，但每次匹配仍要过 ShellEffectGuard。
        "nc", "ncat", "socat", "telnet", "ssh", "scp", "sftp", "ftp", "openssl", "curl", "wget", "rsync",
        // 任意写或执行：参数里就能指定写到哪里或执行什么。
        "tee", "ln", "install", "ditto", "cpio", "pax", "truncate", "hdiutil", "crontab", "at",
        "sqlite3", "awk", "gawk", "sed", "perl", "ruby", "php", "lua",
        // 别名与变体：同样能任意写文件或执行别的命令。
        "gsed", "nawk", "mawk", "busybox",
        // 归档与补丁：参数里能指定写到项目以外的路径（绝对路径、`-P`、`-C`、符号链接）。
        "tar", "gtar", "bsdtar", "unzip", "7z", "7za", "7zr", "7zz", "patch",
        // 工具安装器：把程序装到项目以外。
        "pipx",
        // 系统：改系统设置、签名、剪贴板、打开任意应用、截屏、读剪贴板。
        "defaults", "plutil", "pmset", "scutil", "spctl", "tmutil", "csrutil", "dscl", "sysadminctl",
        "xattr", "codesign", "open", "pbcopy", "pbpaste", "screencapture",
        // 目录与环境：只改当前 shell 的状态，每次执行的目录以 cwd 参数为准。
        // setopt、emulate、hash、zmodload 会改 shell 选项、加载模块或改命令查找，前缀规则管不住。
        "cd", "pushd", "popd", "alias", "unset", "setopt", "emulate", "hash", "zmodload",
    ]

    /// 解释器带版本号的写法（`python3.12`、`pypy3`、`ruby3.3`、`node18`、`perl5.34`）按前缀识别。
    static func interpreterBaseName(_ lowered: String) -> String? {
        for base in ["python", "pypy", "ruby", "node", "perl", "php", "lua"] where lowered.hasPrefix(base) {
            let rest = lowered.dropFirst(base.count)
            if rest.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789._-").contains($0) }) {
                return base
            }
        }
        return nil
    }

    /// 这些子命令把程序或配置装到项目以外，不提供"以后都允许"。
    static let neverPersistSubcommands: [String: Set<String>] = [
        "cargo": ["install"], "go": ["install"], "gem": ["install"], "brew": ["install"], "uv": ["tool"],
        // 包管理器改配置（registry、全局路径、脚本 shell）：整个 config 子命令都不记。
        "npm": ["config"], "pip": ["config"], "pip3": ["config"], "yarn": ["config"], "pnpm": ["config"],
    ]

    /// zsh 保留字和修饰符：作为首词时后面的整段才是真正的命令，按前缀识别会被偷换。
    static let shellReservedFirstWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "foreach", "while", "until", "do", "done",
        "case", "esac", "select", "repeat", "coproc", "function", "time", "noglob", "nocorrect",
        "!", "{", "}", "[[", "-",
    ]

    /// git 的这些子命令能执行外部程序、改配置或访问网络仓库，不提供"以后都允许"。
    static let neverPersistGitSubcommands: Set<String> = [
        "config", "submodule", "bisect", "filter-branch", "difftool", "mergetool", "instaweb",
        "daemon", "archive", "remote", "ls-remote",
        // clone 会拉取并检出任意仓库（模板、钩子、upload-pack 都能执行外部程序）；send-email 把内容发往任意邮件服务器。
        "clone", "send-email",
    ]

    /// 包装器：把后面的词当作另一条命令执行，规则要对被包装的命令再检查一遍。
    /// 返回被包装命令在 `words` 里的起始位置。
    static func wrappedCommandStart(lowered: String, words: [String]) -> Int? {
        let second = words.count > 1 ? words[1] : ""
        switch lowered {
        case "xcrun", "npx": return 1
        case "uv", "poetry": return second == "run" ? 2 : nil
        case "bundle": return second == "exec" ? 2 : nil
        default: return nil
        }
    }

    /// 这些工具的前缀带上子命令：`git status`、`cargo build`。
    static let subcommandTools: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "bun", "cargo", "swift", "make", "go", "docker",
        "brew", "gh", "uv", "pip", "pip3", "rustup", "kubectl", "terraform", "dotnet", "mix",
        "xcrun", "pod", "bundle", "gem", "composer", "mvn", "gradle", "just", "poetry",
    ]
    /// `npm run test`、`uv run pytest`：前缀再带上脚本名。
    static let runStyleTools: Set<String> = ["npm", "yarn", "pnpm", "bun", "uv", "poetry", "bundle"]
    static let runStyleSubcommands: Set<String> = ["run", "exec", "dlx", "x"]
    /// 解释器：前缀带上脚本或模块，`python3 -c` 这类把代码放在参数里的写法不提供。
    static let interpreterTools: Set<String> = [
        "python", "python3", "node", "ruby", "perl", "php", "deno", "lua", "swiftc",
    ]
    private static let inlineCodeFlags: Set<String> = ["-c", "-e", "-E", "-r", "-p", "--eval", "--print", "-x"]
    private static let findDispatchWords: Set<String> = ["-exec", "-execdir", "-ok", "-okdir", "-delete"]

    /// 按引号感知地把复合命令拆成子命令；含重定向、命令替换、展开或后台符之外的
    /// 其他 shell 语法时返回 nil 和原因。
    static func splitShellSubcommands(_ command: String) -> (segments: [String], reason: String?) {
        let detailed = splitShellSubcommandsDetailed(command)
        return (detailed.segments, detailed.reason)
    }

    /// 只认这几种固定写法的"丢弃输出/复制描述符"重定向：它们不写任何文件，可以直接剥掉，
    /// 剥掉后的命令仍按普通命令整体检查。前面必须是行首或空白，后面必须是行尾、空白或操作符。
    private static let strippableRedirections: [[Character]] = [
        Array("2>&1"), Array(">/dev/null"), Array("2>/dev/null"), Array("1>/dev/null"),
        Array("&>/dev/null"), Array("</dev/null"),
    ]

    private static func strippableRedirectionLength(chars: [Character], at index: Int) -> Int? {
        if index > 0, !chars[index - 1].isWhitespace { return nil }
        for pattern in strippableRedirections where index + pattern.count <= chars.count {
            guard Array(chars[index..<(index + pattern.count)]) == pattern else { continue }
            let end = index + pattern.count
            if end == chars.count { return pattern.count }
            let next = chars[end]
            if next.isWhitespace || next == ";" || next == "|" || next == "&" { return pattern.count }
        }
        return nil
    }

    /// 与 `splitShellSubcommands` 相同，另外返回每个子命令后面跟的操作符（`&&`、`||`、`|`、`&`、`;`，
    /// 最后一段为空串），供"开头 cd"这类需要知道连接方式的判定使用。
    static func splitShellSubcommandsDetailed(
        _ command: String
    ) -> (segments: [String], separators: [String], reason: String?) {
        var segments: [String] = []
        var separators: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        let chars = Array(command)
        var index = 0
        func flush(_ separator: String) {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                segments.append(trimmed)
                separators.append(separator)
            }
            current = ""
        }
        while index < chars.count {
            let c = chars[index]
            if escaped { current.append(c); escaped = false; index += 1; continue }
            if inSingle {
                if c == "'" { inSingle = false }
                current.append(c); index += 1; continue
            }
            if c == "\\" { escaped = true; current.append(c); index += 1; continue }
            if inDouble {
                if c == "\"" { inDouble = false }
                else if c == "$" || c == "`" { return ([], [], "命令含变量展开或命令替换，每次都需询问") }
                current.append(c); index += 1; continue
            }
            // 固定写法的 `2>&1`、`>/dev/null` 等：直接剥掉，不写任何文件。
            if c == "2" || c == ">" || c == "1" || c == "&" || c == "<",
               let length = strippableRedirectionLength(chars: chars, at: index) {
                index += length
                continue
            }
            switch c {
            case "'": inSingle = true; current.append(c)
            case "\"": inDouble = true; current.append(c)
            case "$", "`", "(", ")": return ([], [], "命令含变量展开、命令替换或子 shell，每次都需询问")
            case ">", "<": return ([], [], "命令含重定向，每次都需询问")
            case ";": flush(";")
            case "|":
                if index + 1 < chars.count, chars[index + 1] == "|" {
                    flush("||")
                    index += 1
                } else {
                    flush("|")
                }
            case "&":
                if index + 1 < chars.count, chars[index + 1] == "&" {
                    flush("&&")
                    index += 1
                } else {
                    flush("&")
                }
            default: current.append(c)
            }
            index += 1
        }
        if inSingle || inDouble || escaped { return ([], [], "命令引号不完整，每次都需询问") }
        flush("")
        return (segments, separators, segments.isEmpty ? "命令为空" : nil)
    }

    /// 一个子命令对应的规则前缀；nil 时带原因。
    static func shellRulePattern(words: [String]) -> (pattern: String?, reason: String?) {
        guard let first = words.first else { return (nil, "命令为空") }
        guard !first.contains("/"), isPlainToken(first, allowed: executableCharacters) else {
            return (nil, "以路径方式调用的命令每次都需询问")
        }
        if shellReservedFirstWords.contains(first) || first.hasPrefix("-") {
            return (nil, "以 shell 保留字或修饰符开头的命令每次都需询问")
        }
        let lowered = first.lowercased()
        let interpreterBase = interpreterBaseName(lowered)
        if neverPersistExecutables.contains(lowered)
            || ["ruby", "perl", "php", "lua"].contains(interpreterBase ?? "")
            || TerminalPolicySnapshot.productHardDeniedCommands.contains(first) {
            return (nil, "高危命令（\(first)）每次都需询问，不提供以后都允许")
        }
        if TerminalPolicySnapshot.conditionalHardDeniedInvocation(in: words) {
            return (nil, "产品策略不允许该命令")
        }
        if words.contains(where: { findDispatchWords.contains($0) }) {
            return (nil, "命令含会执行或删除文件的选项，每次都需询问")
        }
        if let reason = rejectedArgumentShape(words: words) { return (nil, reason) }
        // 原有只读 git、构建、ls 等家族继续沿用参数白名单（防止 -c core.fsmonitor 之类注入）。
        func finish(_ pattern: String, consumed: Int) -> (pattern: String?, reason: String?) {
            let key = pattern.split(separator: " ").prefix(2).joined(separator: " ")
            let arguments = Array(words.dropFirst(consumed))
            if let policy = persistentAllowlist[key] ?? persistentAllowlist[first] {
                guard argumentsAreAcceptable(arguments, policy: policy) else {
                    return (nil, "参数含不在白名单内的选项，每次都需询问")
                }
            } else if lowered == "git" {
                // git 的所有子命令都套用同一套参数检查（配置注入、外部程序、写文件、--no-index）。
                guard arguments.allSatisfy(isSafeGitArgument) else {
                    return (nil, "参数含不在白名单内的选项，每次都需询问")
                }
            } else if subcommandTools.contains(lowered) {
                // 其余带子命令的工具：不许改工作目录、包路径、作用域、仓库地址，不许透传编译参数。
                guard arguments.allSatisfy(isSafeBuildToolArgument) else {
                    return (nil, "参数含不在白名单内的选项，每次都需询问")
                }
            }
            return (pattern, nil)
        }
        if subcommandTools.contains(lowered) {
            guard words.count > 1 else { return finish(first, consumed: 1) }
            let second = words[1]
            guard !second.hasPrefix("-"), isPlainToken(second, allowed: scriptCharacters) else {
                return (nil, "需要带上子命令才能记住（如 \(first) status），每次都需询问")
            }
            if lowered == "git", neverPersistGitSubcommands.contains(second) {
                return (nil, "git \(second) 每次都需询问，不提供以后都允许")
            }
            if neverPersistSubcommands[lowered]?.contains(second) == true {
                return (nil, "\(first) \(second) 每次都需询问，不提供以后都允许")
            }
            // 包装器（xcrun、npx、uv run、bundle exec、poetry run）：被包装的命令也要能被记住才行。
            if let start = wrappedCommandStart(lowered: lowered, words: words), start < words.count {
                let inner = Array(words[start...])
                let result = shellRulePattern(words: inner)
                if result.pattern == nil {
                    return (nil, "\(first) 包装的命令（\(inner[0])）每次都需询问：" + (result.reason ?? ""))
                }
            }
            if runStyleTools.contains(lowered), runStyleSubcommands.contains(second) {
                guard words.count > 2, !words[2].hasPrefix("-"),
                      isPlainToken(words[2], allowed: scriptCharacters) else {
                    return (nil, "\(first) \(second) 需要带脚本名才能记住")
                }
                return finish("\(first) \(second) \(words[2])", consumed: 3)
            }
            return finish("\(first) \(second)", consumed: 2)
        }
        if interpreterTools.contains(lowered) || interpreterBase != nil {
            if words.dropFirst().contains(where: { inlineCodeFlags.contains($0) }) {
                return (nil, "解释器直接执行参数里的代码，每次都需询问")
            }
            if words.count > 1, !words[1].hasPrefix("-"), !words[1].hasPrefix("/"), !words[1].hasPrefix("~"),
               !words[1].contains(".."),
               isPlainToken(words[1], allowed: scriptCharacters.union(CharacterSet(charactersIn: "./"))) {
                return ("\(first) \(words[1])", nil)
            }
            return (nil, "请带上脚本名后再记住")
        }
        return finish(first, consumed: 1)
    }

    /// 复合命令里每个子命令的词（供匹配与生成前缀共用）。
    static func shellSubcommandWords(command: String) -> (words: [[String]], reason: String?) {
        let analysis = shellCommandAnalysis(command: command)
        return (analysis.words, analysis.reason)
    }

    /// 可以安全剥掉的环境变量前缀：只影响程序的显示或行为开关，不改变命令查找、动态库加载、
    /// 配置位置。PATH、LD_*、DYLD_*、NODE_OPTIONS、GIT_*、BASH_ENV、PYTHONPATH 等不在其中，
    /// 带这些前缀的命令仍按"变量赋值开头"整条拒绝。
    static let strippableEnvironmentNames: Set<String> = [
        "CI", "NODE_ENV", "FORCE_COLOR", "NO_COLOR", "TERM", "LANG", "LC_ALL",
        "RUST_BACKTRACE", "RUST_LOG", "PYTHONUNBUFFERED",
    ]

    private static func isStrippableEnvironmentAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "=") else { return false }
        let name = String(word[..<equals])
        let value = String(word[word.index(after: equals)...])
        guard strippableEnvironmentNames.contains(name) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isTimeoutDuration(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        let digits = "smhd".contains(last) ? String(word.dropLast()) : word
        guard !digits.isEmpty, digits.first?.isNumber == true else { return false }
        return digits.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// 剥掉白名单环境变量前缀，以及无选项的 `time`、`env`、`timeout <时长>` 包装。
    /// 剥完的词仍整体经过效果检查器；`nohup`、带选项的 `env`、`xargs` 不剥。
    static func strippingWrappers(_ original: [String]) -> [String] {
        var words = original
        for _ in 0..<6 {
            guard let first = words.first else { break }
            if isStrippableEnvironmentAssignment(first) {
                words.removeFirst()
                continue
            }
            if first == "time", words.count > 1, !words[1].hasPrefix("-") {
                words.removeFirst()
                continue
            }
            if first == "env", words.count > 1, !words[1].hasPrefix("-"), !words[1].contains("=") {
                words.removeFirst()
                continue
            }
            if first == "timeout", words.count > 2, isTimeoutDuration(words[1]), !words[2].hasPrefix("-") {
                words.removeFirst(2)
                continue
            }
            break
        }
        return words
    }

    /// 复合命令的完整分析：每个子命令的词（已剥掉固定重定向、白名单环境变量前缀和包装），
    /// 以及开头的 `cd <目录> &&`（只认第一段、后面必须是 `&&`）。cd 的目录由 `ShellEffectGuard`
    /// 检查并作为后续命令的基准目录；它本身不生成规则。
    static func shellCommandAnalysis(
        command: String
    ) -> (words: [[String]], leadingDirectory: String?, reason: String?) {
        if let reason = unsafeShellTextReason(command, allowingOperators: true) { return ([], nil, reason) }
        let split = splitShellSubcommandsDetailed(command)
        if let reason = split.reason { return ([], nil, reason) }
        var all: [[String]] = []
        for segment in split.segments {
            let inspected = TerminalGuard.inspect(segment)
            guard inspected.isAllowed, !inspected.words.isEmpty else {
                return ([], nil, "命令含无法按前缀识别的写法，每次都需询问")
            }
            let stripped = strippingWrappers(inspected.words)
            guard !stripped.isEmpty else { return ([], nil, "命令含无法按前缀识别的写法，每次都需询问") }
            all.append(stripped)
        }
        if all.count > 1, all[0].count == 2, all[0][0] == "cd", split.separators.first == "&&",
           !all[0][1].hasPrefix("-"), !all[0][1].isEmpty {
            let directory = all[0][1]
            all.removeFirst()
            return (all, directory, nil)
        }
        return (all, nil, nil)
    }

    public static func evaluateShellRules(command: String) -> ShellRuleEvaluation {
        let analyzed = shellSubcommandWords(command: command)
        if let reason = analyzed.reason { return .unavailable(reason) }
        var patterns: [String] = []
        for words in analyzed.words {
            let result = shellRulePattern(words: words)
            guard let pattern = result.pattern else { return .unavailable(result.reason ?? "该命令每次都需询问") }
            if !patterns.contains(pattern) { patterns.append(pattern) }
        }
        return .patterns(patterns)
    }

    public static func evaluateShellRules(
        input: [String: Any], defaultWorkingDirectory: String?
    ) -> ShellRuleEvaluation {
        guard let command = input["command"] as? String else { return .unavailable("命令缺失") }
        // 工作目录不必等于会话默认目录：只要求是有效的绝对路径；是否在授权根内、
        // 是否落在 .git、构建配置、敏感或应用数据位置，由 ShellEffectGuard 统一检查。
        _ = defaultWorkingDirectory
        if let cwd = ShellToolInput.explicitWorkingDirectory(input) {
            guard let raw = cwd as? String, raw.hasPrefix("/"),
                  PolicyRuntimePathBoundary.canonicalPath(raw) != nil else {
                return .unavailable("工作目录无效，每次都需询问")
            }
        }
        return evaluateShellRules(command: command)
    }

    // MARK: Argument policies

    private static func argumentsAreAcceptable(_ arguments: [String], policy: ArgumentPolicy) -> Bool {
        switch policy {
        case .buildTool, .scriptName:
            return arguments.allSatisfy(isSafeBuildToolArgument)
        case .none:
            return arguments.isEmpty
        case .gitReadOnly:
            return arguments.allSatisfy(isSafeGitArgument)
        case .gitBranchList:
            return arguments.allSatisfy { gitBranchListFlags.contains($0) }
        case .relativePathsOnly:
            return arguments.allSatisfy(isFlagOrRelativePath)
        }
    }

    /// Long options that change the working directory, package path, workspace
    /// scope, cache/config location, registry, or the shell used for scripts.
    /// Abbreviations (`--pack`, `--pre`) and `--name=value` forms are rejected too.
    private static let blockedBuildLongOptions = [
        "--package-path", "--scratch-path", "--cache-path", "--build-path", "--config-path",
        "--security-path", "--prefix", "--cwd", "--dir", "--workspace", "--workspaces",
        "--workspace-root", "--global", "--registry", "--userconfig", "--globalconfig",
        "--cache", "--script-shell",
    ]
    /// Short flags: `-C` (prefix/dir), `-w` (workspace), `-g` (global). Checked
    /// inside clusters (`-gv`) and with attached values (`-C/x`).
    private static let blockedBuildShortFlags: Set<Character> = ["C", "w", "g"]

    static func isSafeBuildToolArgument(_ argument: String) -> Bool {
        // 只拒绝真正的 ".." 路径段（`../x`、`a/../b`、`--opt=..`）；`./...`、`a..b` 这类写法不是上跳。
        if argument.split(whereSeparator: { $0 == "/" || $0 == "=" }).contains("..") { return false }
        let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        if parts.contains(where: { $0.hasPrefix("/") || $0.hasPrefix("~") }) { return false }
        let name = parts.first ?? argument
        if name.hasPrefix("--") {
            guard name.count >= 3 else { return true } // bare "--"
            let lowered = name.lowercased()
            if lowered.hasPrefix("--x") { return false } // --Xswiftc etc.
            return !blockedBuildLongOptions.contains { $0.hasPrefix(lowered) }
        }
        if name.hasPrefix("-") {
            if name.hasPrefix("-X") { return false } // -Xswiftc / -Xlinker / -Xcc / -Xcxx
            return !name.dropFirst().contains { blockedBuildShortFlags.contains($0) }
        }
        return true
    }

    private static let gitBranchListFlags: Set<String> = [
        "-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "--list", "-l", "--show-current",
    ]

    /// Long options that inject configuration, helper programs or file output.
    /// git accepts any unambiguous abbreviation of a long option, so a spelled
    /// abbreviation (`--upload-p`) is rejected as well.
    private static let dangerousGitLongOptions = [
        "--upload-pack", "--receive-pack", "--exec-path", "--open-files-in-pager", "--output",
        "--ext-diff", "--textconv", "--config", "--git-dir", "--work-tree", "--namespace",
        "--super-prefix", "--exec", "--paginate",
        // `git diff --no-index a b` 能读任意两个文件，不受仓库范围限制；`--tree-filter`
        // 会对每个提交执行命令。
        "--no-index", "--tree-filter",
        // clone 的模板目录能带来钩子；send-email 把内容发往任意邮件服务器；apply 的 --unsafe-paths 能写到仓库以外。
        "--template", "--smtp-server", "--unsafe-paths",
    ]

    static func isSafeGitArgument(_ argument: String) -> Bool {
        if argument.hasPrefix("--") {
            let name = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? argument
            if name.count >= 3 {
                return !dangerousGitLongOptions.contains { $0.hasPrefix(name) }
            }
            return true
        }
        if argument.hasPrefix("-") {
            // `-c name=value` (global config injection, also attached as
            // `-cname=value`) and `-O<pager>` are single-dash options.
            // `-x` 是 `git rebase -x <cmd>` 的执行命令选项。
            return !(argument.hasPrefix("-c") || argument.hasPrefix("-O") || argument.hasPrefix("-C")
                || argument.hasPrefix("-x"))
        }
        // `git diff /a /b` 在仓库内也会因为路径落在工作树外而退化成 --no-index：
        // 绝对路径、`~` 开头和 `..` 路径段一律不当作"安全参数"。
        if argument.hasPrefix("/") || argument.hasPrefix("~") { return false }
        if argument.split(separator: "/").contains("..") { return false }
        return true
    }

    /// 带这些参数形态的命令不提供"以后都允许"，规则命中时也不匹配；只读判定同样拒绝。
    /// 它们都能让"看起来只读"的命令写文件、执行别的命令或换一个输出位置。
    static func rejectedArgumentShape(words: [String]) -> String? {
        guard let first = words.first else { return nil }
        let arguments = Array(words.dropFirst())
        /// 短选项簇（`-ro`、`-uT`）里含有指定字母。
        func shortCluster(_ argument: String, containsAny letters: String) -> Bool {
            argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.count > 1
                && argument.dropFirst().contains { letters.contains($0) }
        }
        /// 长选项允许缩写：`--out` 也是 `--output`。
        func longOption(_ argument: String, isPrefixOfAny names: [String]) -> Bool {
            guard argument.hasPrefix("--") else { return false }
            let name = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? argument
            guard name.count >= 3 else { return false }
            return names.contains { $0.hasPrefix(name) }
        }
        let reason = "命令含会写文件或执行别的命令的选项，每次都需询问"
        switch first {
        case "find":
            let blocked: Set<String> = ["-exec", "-execdir", "-ok", "-okdir", "-delete",
                                        "-fprint", "-fprint0", "-fprintf", "-fls"]
            if arguments.contains(where: { blocked.contains($0) }) { return reason }
        case "sort":
            if arguments.contains(where: {
                shortCluster($0, containsAny: "oT") || longOption($0, isPrefixOfAny: ["--output", "--compress-program", "--temporary-directory"])
            }) { return reason }
        case "uniq":
            // `uniq [输入 [输出]]`：第二个位置参数是输出文件。
            let operands = arguments.filter { !$0.hasPrefix("-") }
            if operands.count >= 2 { return reason }
        case "tree":
            if arguments.contains(where: { shortCluster($0, containsAny: "o") || longOption($0, isPrefixOfAny: ["--output"]) }) {
                return reason
            }
        case "file":
            if arguments.contains(where: { shortCluster($0, containsAny: "C") || longOption($0, isPrefixOfAny: ["--compile"]) }) {
                return reason
            }
        case "xxd":
            // `-r`（含 `-revert`、`-pr` 这类带 r 的写法）把十六进制写回二进制文件；
            // `xxd 输入 输出` 的第二个位置参数是输出文件。带值选项（-l 16、-c 8、-s 4、-g 2、-o 8、-n 名）的值不算位置参数。
            var operands = 0
            var skipNext = false
            for argument in arguments {
                if skipNext { skipNext = false; continue }
                if argument.hasPrefix("-"), argument.count > 1 {
                    if argument.dropFirst().contains("r") { return reason }
                    let body = argument.dropFirst()
                    if let letter = body.first, "cglosn".contains(letter), body.allSatisfy({ $0.isLetter }) {
                        skipNext = true
                    }
                } else {
                    operands += 1
                }
            }
            if operands >= 2 { return reason }
        case "man":
            if arguments.contains(where: { shortCluster($0, containsAny: "P") || longOption($0, isPrefixOfAny: ["--pager"]) }) {
                return reason
            }
        case "git":
            if arguments.contains(where: { !isSafeGitArgument($0) }) { return reason }
            // clone 的 `-u` 是 `--upload-pack` 的短写（执行任意程序）；`-u` 在 status、add 等子命令里是别的意思，只在 clone 里拒绝。
            var index = 0
            while index < arguments.count, arguments[index].hasPrefix("-") { index += 1 }
            if index < arguments.count, arguments[index] == "clone",
               arguments[(index + 1)...].contains(where: { $0.hasPrefix("-u") }) {
                return reason
            }
        case "pip", "pip3":
            // 装到用户目录、系统目录或项目以外的位置。
            if arguments.contains(where: {
                ($0.hasPrefix("-t") && !$0.hasPrefix("--")) || longOption($0, isPrefixOfAny: [
                    "--user", "--break-system-packages", "--target", "--prefix", "--root"])
            }) { return reason }
        case "deno":
            // deno eval 直接执行参数里的代码。
            if arguments.first(where: { !$0.hasPrefix("-") }) == "eval" { return reason }
        case "go":
            // go 的 -exec、-toolexec、-vettool 会用指定程序运行测试、编译或检查。
            if arguments.contains(where: { argument in
                let name = argument.drop(while: { $0 == "-" }).split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                return argument.hasPrefix("-") && ["exec", "toolexec", "vettool"].contains(name)
            }) { return reason }
        case "uv":
            if arguments.first == "pip", arguments.contains(where: {
                $0 == "-t" || longOption($0, isPrefixOfAny: ["--user", "--break-system-packages", "--target", "--prefix", "--root"])
            }) { return reason }
        default:
            break
        }
        return nil
    }

    private static func isFlagOrRelativePath(_ argument: String) -> Bool {
        if argument.hasPrefix("-") {
            return !argument.dropFirst().isEmpty
                && argument.unicodeScalars.allSatisfy { flagCharacters.contains($0) }
        }
        if argument.hasPrefix("/") || argument.hasPrefix("~") { return false }
        return !argument.split(separator: "/").contains("..")
    }

    private static let flagCharacters = CharacterSet(
        charactersIn: "-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    // MARK: File rules

    /// Directory names under which a project-directory rule is never offered:
    /// git internals and tool/IDE configuration that can plant executable hooks.
    static let excludedDirectoryNames: Set<String> = [".git", ".claude", ".vscode", ".idea"]
    /// File names (anywhere in the tree) that run code or configure tools.
    static let excludedFileNames: Set<String> = [
        ".mcp.json", ".zshrc", ".bashrc", ".bash_profile", ".profile", ".zprofile",
        ".zshenv", ".zlogin", ".bash_login",
    ]

    /// Build manifests, build scripts and CI/tooling configuration that a
    /// remembered build/test command (`swift build/test`, `npm test/run`,
    /// `yarn test`, `pnpm test`, `make test`) will EXECUTE. A directory rule
    /// must not let the model rewrite these without asking and then run them
    /// without asking, so none of them is ever offered "以后都允许" and a stored
    /// directory rule never covers them (evaluateFile returns `.unavailable`,
    /// and `match` only hits on `.pattern`).
    ///
    /// All entries are lowercase: APFS is case-insensitive by default and the
    /// comparison lowercases the relative path components first.
    ///
    /// Limitation, on purpose: this is NOT a security boundary. It only
    /// shortens the "write config without asking, then run it without asking"
    /// chain. The model can still write ordinary source and test files without
    /// asking and then run them through an allowed `swift test` / `npm test`;
    /// that is inherent to "let the model write code and run the tests". A
    /// list also cannot be complete (other tools, other file names).
    enum BuildConfigExclusions {
        /// Exact file or directory names, matched against every component.
        static let names: Set<String> = [
            // package manifests and lock/registry config
            "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
            ".npmrc", ".pnpmfile.cjs", "package.swift", "package.resolved",
            // make-like and task runners
            "makefile", "gnumakefile", "justfile", "rakefile",
            // other language build files
            "gemfile", "pyproject.toml", "setup.py", "setup.cfg", "tox.ini", "noxfile.py",
            "cmakelists.txt", "dockerfile", "pom.xml", "project.pbxproj",
            // CI files that live at the top of a project
            ".gitlab-ci.yml", ".travis.yml", "azure-pipelines.yml", "jenkinsfile",
            // CI / hook / tooling directories (any depth)
            ".github", ".husky", ".gitlab", ".circleci", ".config",
        ]
        /// Component prefixes: `.yarnrc*`, `build.gradle*`.
        static let prefixes: [String] = [".yarnrc", "build.gradle"]
        /// Component suffixes: `*.mk`, `*.xcconfig`, `*.podspec`.
        static let suffixes: [String] = [".mk", ".xcconfig", ".podspec"]
        /// `docker-compose*.yml`, and `Package@swift-<version>.swift` (SwiftPM reads the versioned manifest).
        static let prefixSuffixPairs: [(prefix: String, suffix: String)] = [
            ("docker-compose", ".yml"), ("package@swift", ".swift"),
        ]
        /// Directories excluded only as the FIRST component below the root
        /// (a nested `src/bin` or `Sources/tools` is ordinary source). `Plugins/` holds SwiftPM build plugins,
        /// which run during `swift build`.
        static let topLevelDirectories: Set<String> = ["scripts", "bin", "tools", "plugins"]

        static func matches(components: [String]) -> Bool {
            if let first = components.first, topLevelDirectories.contains(first) { return true }
            return components.contains { c in
                names.contains(c)
                    || prefixes.contains { c.hasPrefix($0) }
                    || suffixes.contains { c.hasSuffix($0) }
                    || prefixSuffixPairs.contains { c.hasPrefix($0.prefix) && c.hasSuffix($0.suffix) }
            }
        }
    }

    static let buildConfigUnavailableReason = "该文件会被构建命令执行，不支持以后都允许"

    public static func evaluateFile(
        capability: String, input: [String: Any], roots: [String], home: String = NSHomeDirectory()
    ) -> Evaluation {
        guard capability == "file_write" || capability == "file_edit" else {
            return .unavailable("该操作每次都需询问")
        }
        guard let rawPath = input["path"] as? String, rawPath.hasPrefix("/"),
              let canonical = PolicyRuntimePathBoundary.canonicalPath(rawPath) else {
            return .unavailable("目标路径无效")
        }
        if SensitiveFilePolicy.isProtectedGitWritePath(rawPath) || SensitiveFilePolicy.isProtectedGitWritePath(canonical) {
            return .unavailable("Git 控制文件每次都需询问")
        }
        if SensitiveFilePolicy.contains(rawPath) || SensitiveFilePolicy.contains(canonical) {
            return .unavailable("敏感文件每次都需询问")
        }
        let allRoots = roots.compactMap(PolicyRuntimePathBoundary.canonicalPath)
        let homePath = PolicyRuntimePathBoundary.canonicalPath(home) ?? home
        // Raw and canonical forms are both judged, each relative to the roots
        // as given and as canonicalised (a symlinked component can differ).
        let rootCandidates = roots + allRoots
        let homeCandidates = [home, homePath]
        let excluded = homeCandidates.contains { h in
            isExcludedLocation(rawPath, relativeTo: rootCandidates, home: h)
                || isExcludedLocation(canonical, relativeTo: rootCandidates, home: h)
        }
        if excluded {
            let buildOnly = !homeCandidates.contains { h in
                isExcludedLocation(rawPath, relativeTo: rootCandidates, home: h, includeBuildConfig: false)
                    || isExcludedLocation(canonical, relativeTo: rootCandidates, home: h, includeBuildConfig: false)
            }
            if buildOnly { return .unavailable(buildConfigUnavailableReason) }
            return .unavailable("该位置（授权根内的 .git、.claude、IDE 配置、shell 启动文件，或 LaunchAgents 等）每次都需询问")
        }
        if allRoots.contains(where: { root in
            root == "/" || root == homePath || homePath.hasPrefix(root + "/")
        }) {
            return .unavailable("会话授权根覆盖主目录或根目录，范围过大，每次都需询问")
        }
        // Longest root first, so a nested authorization root is not widened.
        for root in allRoots.sorted(by: { $0.count > $1.count })
        where canonical == root || canonical.hasPrefix(root + "/") {
            return .pattern(root)
        }
        return .unavailable("目标不在会话授权根内")
    }

    /// `file_read` 目录规则：对齐 Claude Code 的"允许读取此目录"。规则存的是被读文件所在目录
    /// （递归覆盖其子目录）。敏感文件、MinisCanvas 自身数据目录、根目录/主目录及其上级不提供。
    /// `searchRoot`：file_grep、file_glob 的 path 本身就是被搜索的目录，规则记这个目录（不是它的上一级）。
    public static func evaluateFileRead(
        input: [String: Any], home: String = NSHomeDirectory(), searchRoot: Bool = false
    ) -> Evaluation {
        guard let rawPath = input["path"] as? String, rawPath.hasPrefix("/"),
              let canonical = PolicyRuntimePathBoundary.canonicalPath(rawPath) else {
            return .unavailable("目标路径无效")
        }
        if SensitiveFilePolicy.contains(rawPath) || SensitiveFilePolicy.contains(canonical) {
            return .unavailable("敏感文件每次都需询问")
        }
        var isDirectory: ObjCBool = false
        let directory = searchRoot && FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory)
            && isDirectory.boolValue
            ? canonical : (canonical as NSString).deletingLastPathComponent
        let homePath = PolicyRuntimePathBoundary.canonicalPath(home) ?? home
        if directory.isEmpty || directory == "/" || directory == homePath || homePath.hasPrefix(directory + "/") {
            return .unavailable("所在目录是根目录或主目录，范围过大，每次都需询问")
        }
        if BypassAppDataFloor.violation(path: directory, access: .read) != nil
            || SensitiveFilePolicy.isProtectedStatePath(directory) {
            return .unavailable("MinisCanvas 自身数据目录每次都需询问")
        }
        if isTooBroadForReadRule(directory: directory, homePath: homePath) {
            return .unavailable("所在目录范围过大（主目录下的第一层目录、资源库、系统或外接磁盘根目录等），只提供本次允许")
        }
        return .pattern(directory)
    }

    /// "以后都允许读取此目录"会递归覆盖子目录：主目录下的第一层目录（~/Library、~/.config、~/Documents……）、
    /// 资源库的应用数据、/Volumes/*、/Users/Shared、/Users/<其他用户>、/private、/etc 等宽目录只给本次允许。
    static func isTooBroadForReadRule(directory: String, homePath: String) -> Bool {
        let parts = directory.split(separator: "/").map { $0.lowercased() }
        if parts.count <= 1 { return true }
        if parts[0] == "private", parts.count <= 2 { return true }
        // 系统位置整棵都不提供"以后都允许"：/etc（即 /private/etc）、/System、/Library 下任意深度。
        if parts[0] == "etc" || parts[0] == "system" || parts[0] == "library" { return true }
        if parts[0] == "private", parts.count >= 2, parts[1] == "etc" { return true }
        if parts[0] == "volumes", parts.count <= 2 { return true }
        if parts[0] == "users", parts.count <= 2 { return true }
        if parts == ["users", "shared"] { return true }
        let homeParts = homePath.split(separator: "/").map { $0.lowercased() }
        if parts.count > homeParts.count, Array(parts[..<homeParts.count]) == homeParts {
            let relative = Array(parts[homeParts.count...])
            if relative.count <= 1 { return true }
            if relative[0] == "library" { return true }
        }
        return false
    }

    /// Path components after the longest of `roots` that is a prefix of `path`;
    /// nil when `path` is under none of them.
    static func componentsRelative(toRoots roots: [String], path: String) -> [String]? {
        let trimmedRoots = roots.map { root -> String in
            var r = root
            while r.count > 1, r.hasSuffix("/") { r.removeLast() }
            return r
        }
        for root in trimmedRoots.sorted(by: { $0.count > $1.count }) {
            if path == root { return [] }
            let prefix = root == "/" ? "/" : root + "/"
            if path.hasPrefix(prefix) {
                return path.dropFirst(prefix.count).split(separator: "/").map { $0.lowercased() }
            }
        }
        return nil
    }

    /// Exclusion is judged on the part of the target BELOW the authorization
    /// root, so a project that itself lives under a `.claude`/`.git`/… directory
    /// (for example `<repo>/.claude/worktrees/abc`) can still get file rules.
    /// LaunchAgents/LaunchDaemons and HOME-level shell startup files are
    /// judged on the absolute path.
    static func isExcludedLocation(
        _ path: String, relativeTo roots: [String], home: String, includeBuildConfig: Bool = true
    ) -> Bool {
        if isExcludedAbsolute(path, home: home) { return true }
        guard let relative = componentsRelative(toRoots: roots, path: path) else { return false }
        if relative.contains(where: { excludedDirectoryNames.contains($0) || excludedFileNames.contains($0) }) {
            return true
        }
        return includeBuildConfig && BuildConfigExclusions.matches(components: relative)
    }

    private static func isExcludedAbsolute(_ path: String, home: String) -> Bool {
        let components = path.split(separator: "/").map { $0.lowercased() }
        for (index, component) in components.enumerated() where component == "library" {
            if index + 1 < components.count,
               ["launchagents", "launchdaemons"].contains(components[index + 1]) { return true }
        }
        var homeTrimmed = home
        while homeTrimmed.count > 1, homeTrimmed.hasSuffix("/") { homeTrimmed.removeLast() }
        let prefix = homeTrimmed + "/"
        if path.lowercased().hasPrefix(prefix.lowercased()) {
            let rest = path.dropFirst(prefix.count).split(separator: "/").map { $0.lowercased() }
            if rest.count == 1, excludedFileNames.contains(rest[0]) { return true }
        }
        return false
    }

    /// Stable project identity from the frozen session authorization roots.
    ///
    /// `sharingOrdinaryWorkspace`：普通会话（不在项目里）每个会话有自己的私有目录，按目录算
    /// 项目键就会让 shell 规则只对一个会话有效。传 true 时，唯一的授权根正好是
    /// `ordinaryWorkspaceBase` 下的一级目录，就改用固定的"私有工作区"键，所有普通会话共享
    /// shell 规则；授权根本身（`allowedWriteRoots`）不变，每次执行前的路径检查仍按各自的根。
    public static func projectScope(
        roots: [String], sharingOrdinaryWorkspace: Bool = false
    ) -> (key: String, roots: [String])? {
        let canonical = Set(roots.compactMap(PolicyRuntimePathBoundary.canonicalPath).filter { $0 != "/" })
        guard !canonical.isEmpty else { return nil }
        if sharingOrdinaryWorkspace, canonical.count == 1, let only = canonical.first,
           let base = ordinaryWorkspaceBase.flatMap(PolicyRuntimePathBoundary.canonicalPath),
           (only as NSString).deletingLastPathComponent == base {
            let digest = SHA256.hash(data: Data(("ordinary-workspace\n" + base).utf8))
                .map { String(format: "%02x", $0) }.joined()
            return (String(digest.prefix(32)), [base])
        }
        let sorted = canonical.sorted()
        let digest = SHA256.hash(data: Data(sorted.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return (String(digest.prefix(32)), sorted)
    }

    private static let ordinaryBaseLock = NSLock()
    nonisolated(unsafe) private static var ordinaryBaseStorage: String?

    /// 普通会话私有工作区的上级目录。应用启动时由 App 设置一次；未设置（测试、隔离环境）
    /// 时每个目录各算各的项目键。
    public static var ordinaryWorkspaceBase: String? {
        get { ordinaryBaseLock.lock(); defer { ordinaryBaseLock.unlock() }; return ordinaryBaseStorage }
        set { ordinaryBaseLock.lock(); ordinaryBaseStorage = newValue; ordinaryBaseLock.unlock() }
    }

    private static let executableCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
    private static let subcommandCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
    private static let scriptCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-")

    private static func isPlainToken(_ token: String, allowed: CharacterSet) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy(allowed.contains)
    }
}

// MARK: - Store

private struct PersistentApprovalRuleFile: Codable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var rules: [PersistentApprovalRule]
    /// 拒绝、每次询问规则单独放一个数组：旧版本读到这个文件时看不到它们（不会把"拒绝"误读成"允许"）。
    var restrictions: [PersistentApprovalRule]?
}

/// Read side of the file: one unrecognised rule (for example a `kind` written
/// by a newer build) is skipped and counted instead of failing the whole file.
private struct PersistentApprovalRuleFileReader: Decodable {
    var schemaVersion: Int
    var entries: [Entry]
    var restrictionEntries: [Entry]

    struct Entry: Decodable {
        let rule: PersistentApprovalRule?
        init(from decoder: Decoder) throws {
            rule = try? PersistentApprovalRule(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, rules, restrictions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        entries = try container.decode([Entry].self, forKey: .rules)
        restrictionEntries = try container.decodeIfPresent([Entry].self, forKey: .restrictions) ?? []
    }
}

/// Durable rule list. A store without a file URL is inert: it offers and
/// matches nothing, so isolated tests and fixtures never touch user data.
public final class PersistentApprovalRuleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var fileURL: URL?
    private let homeDirectory: String
    private var rules: [PersistentApprovalRule] = []
    /// 持久的拒绝、每次询问规则（与允许规则分开存放，匹配路径互不影响）。
    private var restrictions: [PersistentApprovalRule] = []
    private var sessionRules: [(sessionID: String, rule: PersistentApprovalRule)] = []
    /// 本会话的拒绝、每次询问规则（只在内存）。
    private var sessionRestrictions: [(sessionID: String, rule: PersistentApprovalRule)] = []
    private var diagnosticLog: [String] = []
    /// 本会话改过构建配置的会话（仅内存）：自动档之后的构建、测试命令不再免问。
    private var buildConfigTouchedSessions: Set<String> = []
    /// 绕过档下选了"本对话内都允许"的看不清内容的 osascript 会话（仅内存）。
    private var opaqueScriptSessions: Set<String> = []
    /// 非 nil 时这是子任务用的只读视图：自己没有规则、不提供"以后都允许"、不写任何东西，
    /// 匹配全部转给父会话的规则库。
    private let upstream: PersistentApprovalRuleStore?
    private let upstreamSessionID: String?
    private let upstreamProjectRoots: [String]

    /// `homeDirectory` is injectable so tests can exercise the "session root
    /// covers the home directory" exclusion without touching the real home.
    public init(fileURL: URL? = nil, homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
        self.upstream = nil
        self.upstreamSessionID = nil
        self.upstreamProjectRoots = []
        if let fileURL { attach(fileURL: fileURL) }
    }

    /// 子任务共享父会话的规则库（只读引用）。`parentSessionID` 让父会话里点过的
    /// "本对话内都允许"对子任务也有效；`parentProjectRoots` 是父会话的授权根，用来查规则。
    public init(
        readOnlyUpstream upstream: PersistentApprovalRuleStore, parentSessionID: String,
        parentProjectRoots: [String], homeDirectory: String = NSHomeDirectory()
    ) {
        self.homeDirectory = homeDirectory
        self.upstream = upstream
        self.upstreamSessionID = parentSessionID
        self.upstreamProjectRoots = parentProjectRoots
    }

    /// 效果检查器：规则命中或提供"以后都允许"之前，对这条具体命令再检查一次。
    private func shellGuardViolation(input: [String: Any], facts: ComposerPolicyFactSource) -> String? {
        ShellEffectGuard.violation(
            input: input,
            context: ShellEffectGuard.Context(
                roots: facts.allowedWriteRoots,
                baseDirectory: ChildToolWorkspaceScope.current?.workingDirectory ?? facts.trustedProjectRoot,
                home: homeDirectory, requireDefaultCWD: true),
            mode: .rule)
    }

    deinit { unprotect(fileURL) }

    /// Bind to a file and load it. Unreadable, corrupt or newer-schema data is
    /// treated as "no rules", set aside as `.corrupt`, and recorded. A single
    /// unrecognised rule is skipped (and the original file copied to
    /// `.unrecognized` once) without discarding the remaining rules.
    public func attach(fileURL: URL) {
        lock.lock(); defer { lock.unlock() }
        unprotect(self.fileURL)
        self.fileURL = fileURL
        protect(fileURL)
        rules = []
        restrictions = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(PersistentApprovalRuleFileReader.self, from: data)
            guard file.schemaVersion == PersistentApprovalRuleFile.currentSchemaVersion else {
                // 允许规则不读（不放宽权限）；拒绝、每次询问规则只会收紧，照样保留，避免整体归零后它们悄悄失效。
                for entry in file.restrictionEntries {
                    if let rule = entry.rule, rule.behavior != .allow, Self.isRecognisedRestriction(rule) {
                        restrictions.append(rule)
                    }
                }
                record("规则文件版本 \(file.schemaVersion) 不受支持，允许规则已忽略（原文件备份为 .corrupt），保留了 \(restrictions.count) 条拒绝或每次询问规则")
                setAside(fileURL)
                if !restrictions.isEmpty { _ = commit([]) }
                return
            }
            var skipped = 0
            for entry in file.entries {
                if let rule = entry.rule, rule.behavior == .allow, Self.isRecognised(rule) {
                    rules.append(rule)
                } else { skipped += 1 }
            }
            for entry in file.restrictionEntries {
                if let rule = entry.rule, rule.behavior != .allow, Self.isRecognisedRestriction(rule) {
                    restrictions.append(rule)
                } else { skipped += 1 }
            }
            if skipped > 0 {
                record("规则文件中有 \(skipped) 条无法识别的规则，已跳过；原文件已复制为 .unrecognized")
                let copy = fileURL.appendingPathExtension("unrecognized")
                try? FileManager.default.removeItem(at: copy)
                try? FileManager.default.copyItem(at: fileURL, to: copy)
            }
        } catch {
            // 整体解码失败：尽量从原始 JSON 里单条捞出拒绝、每次询问规则（只收紧，不读允许规则）。
            if let data = try? Data(contentsOf: fileURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = object["restrictions"] as? [Any] {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                for item in raw {
                    if let itemData = try? JSONSerialization.data(withJSONObject: item),
                       let rule = try? decoder.decode(PersistentApprovalRule.self, from: itemData),
                       rule.behavior != .allow, Self.isRecognisedRestriction(rule) {
                        restrictions.append(rule)
                    }
                }
            }
            record("规则文件读取失败，允许规则已忽略（原文件备份为 .corrupt），保留了 \(restrictions.count) 条拒绝或每次询问规则：\(error.localizedDescription)")
            setAside(fileURL)
            if !restrictions.isEmpty { _ = commit([]) }
        }
    }

    /// 拒绝、每次询问规则的形状检查：只认面板和导入能生成的几种。
    static func isRecognisedRestriction(_ rule: PersistentApprovalRule) -> Bool {
        guard !rule.pattern.isEmpty else { return false }
        switch rule.kind {
        case .shellCommandPrefix: return rule.capability == "shell_execute"
        case .webHost: return rule.capability == "web_fetch"
        case .mcpTool: return rule.capability.hasPrefix("mcp_") && rule.pattern == rule.capability
        case .sessionTarget: return false
        case .projectDirectory:
            if rule.capability == "web_search" { return rule.pattern == PersistentApprovalRuleMatcher.webSearchAlwaysPattern }
            return ["file_read", "file_write"].contains(rule.capability) && rule.pattern.hasPrefix("/")
        }
    }

    private static func isRecognised(_ rule: PersistentApprovalRule) -> Bool {
        switch rule.kind {
        case .shellCommandPrefix: return rule.capability == "shell_execute"
        case .sessionTarget:
            return SessionTargetApprovalRules.isSessionTargetCapability(rule.capability)
                && (rule.pattern.hasPrefix("app:") || rule.pattern.hasPrefix("external:"))
                && !rule.pattern.contains("*")
        case .mcpTool:
            return rule.capability.hasPrefix("mcp_")
                && rule.pattern.hasSuffix(":" + rule.capability)
                && !rule.pattern.contains("*")
        case .webHost:
            return rule.capability == "web_fetch"
                && BrowserNavigationPolicy.normalizedHost(rule.pattern) == rule.pattern
        case .projectDirectory:
            if SkillMaintenanceTool.names.contains(rule.capability) {
                return [PersistentApprovalRuleMatcher.skillAlwaysPattern,
                        PersistentApprovalRuleMatcher.skillBypassPattern].contains(rule.pattern)
            }
            if rule.capability == "web_search" {
                return rule.pattern == PersistentApprovalRuleMatcher.webSearchAlwaysPattern
            }
            return rule.capability == "file_write" || rule.capability == "file_edit"
                || rule.capability == "file_read"
        }
    }

    /// The rule file, its `.corrupt` / `.unrecognized` siblings and its
    /// directory (exact path) are app state: file tools may not touch them.
    private func protectedURLs(_ url: URL) -> [URL] {
        [url, url.appendingPathExtension("corrupt"), url.appendingPathExtension("unrecognized"),
         url.deletingLastPathComponent()]
    }

    private func protect(_ url: URL) {
        protectedURLs(url).forEach {
            SensitiveFilePolicy.protectStatePath($0, isDirectory: $0 == url.deletingLastPathComponent())
        }
    }

    private func unprotect(_ url: URL?) {
        guard let url else { return }
        protectedURLs(url).forEach {
            SensitiveFilePolicy.unprotectStatePath($0, isDirectory: $0 == url.deletingLastPathComponent())
        }
    }

    public var isAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return fileURL != nil
    }

    /// 全部持久规则（允许 + 拒绝 + 每次询问）。
    public func allRules() -> [PersistentApprovalRule] {
        lock.lock(); defer { lock.unlock() }
        return rules + restrictions
    }

    /// 面板用：持久规则（范围按项目键判断：全局 / 本项目）加上这个会话的内存规则（本会话）。
    public func entries(sessionID: String?) -> [PersistentApprovalRuleEntry] {
        lock.lock(); defer { lock.unlock() }
        var result = (rules + restrictions).map {
            PersistentApprovalRuleEntry(rule: $0, scope: $0.isGlobal ? .global : .project)
        }
        if let sessionID {
            for item in sessionRules + sessionRestrictions where item.sessionID == sessionID {
                result.append(PersistentApprovalRuleEntry(rule: item.rule, scope: .session(sessionID)))
            }
        }
        return result
    }

    public func diagnostics() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return diagnosticLog
    }

    /// Returns false (and keeps memory unchanged) when the write fails.
    @discardableResult
    public func add(_ rule: PersistentApprovalRule) -> Bool {
        // 子任务卡片上点的"以后都允许"写进父会话的规则库（这条规则本身只由 makeShellRules 生成，
        // 已按子任务自己的授权根过过效果检查器）。
        if let upstream { return upstream.add(rule) }
        if rule.behavior != .allow { return applyChange(remove: nil, insert: (rule, nil)) }
        lock.lock(); defer { lock.unlock() }
        guard fileURL != nil else { return false }
        if rules.contains(where: {
            $0.projectKey == rule.projectKey && $0.capability == rule.capability
                && $0.kind == rule.kind && $0.pattern == rule.pattern
        }) { return true }
        return commit(rules + [rule])
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if rules.contains(where: { $0.id == id }) {
            return commit(rules.filter { $0.id != id }, restrictions: restrictions)
        }
        if restrictions.contains(where: { $0.id == id }) {
            return commit(rules, restrictions: restrictions.filter { $0.id != id })
        }
        let before = sessionRules.count + sessionRestrictions.count
        sessionRules.removeAll { $0.rule.id == id }
        sessionRestrictions.removeAll { $0.rule.id == id }
        return sessionRules.count + sessionRestrictions.count < before
    }

    @discardableResult
    public func removeAll() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !rules.isEmpty || !restrictions.isEmpty else { return true }
        return commit([], restrictions: [])
    }

    /// 同一把锁里完成"删旧规则 + 插新规则"：持久的改动合成一次写盘，写失败则内存不变。
    /// `insert.sessionID` 非 nil 表示本会话规则（只在内存）。
    fileprivate func applyChange(
        remove id: String?, insert: (rule: PersistentApprovalRule, sessionID: String?)?
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fileURL != nil else { return false }
        var allow = rules, restricted = restrictions
        var sessionAllow = sessionRules, sessionRestricted = sessionRestrictions
        var persistentTouched = false
        if let id {
            if allow.contains(where: { $0.id == id }) { allow.removeAll { $0.id == id }; persistentTouched = true }
            if restricted.contains(where: { $0.id == id }) { restricted.removeAll { $0.id == id }; persistentTouched = true }
            sessionAllow.removeAll { $0.rule.id == id }
            sessionRestricted.removeAll { $0.rule.id == id }
        }
        if let (rule, sessionID) = insert {
            func same(_ other: PersistentApprovalRule) -> Bool {
                other.projectKey == rule.projectKey && other.capability == rule.capability
                    && other.kind == rule.kind && other.pattern == rule.pattern && other.behavior == rule.behavior
            }
            if let sessionID {
                if rule.behavior == .allow {
                    if !sessionAllow.contains(where: { $0.sessionID == sessionID && same($0.rule) }) {
                        sessionAllow.append((sessionID, rule))
                    }
                } else if !sessionRestricted.contains(where: { $0.sessionID == sessionID && same($0.rule) }) {
                    sessionRestricted.append((sessionID, rule))
                }
            } else if rule.behavior == .allow {
                if !allow.contains(where: same) { allow.append(rule); persistentTouched = true }
            } else if !restricted.contains(where: same) {
                restricted.append(rule); persistentTouched = true
            }
        }
        if persistentTouched, !commit(allow, restrictions: restricted) { return false }
        sessionRules = sessionAllow
        sessionRestrictions = sessionRestricted
        return true
    }

    // MARK: Decision support

    /// 项目键只取主授权根（`trustedProjectRoot`）：中途 /add-dir 或挂载外部目录不会让旧规则失效；
    /// 单根会话的键与旧版相同。普通会话（私有目录）共享同一个键。技能规则沿用旧键。
    /// `scopeRoots` 只给子任务的只读视图用（按父会话的授权根算键）。
    private func ruleScope(
        facts: ComposerPolicyFactSource, capability: String? = nil, scopeRoots: [String]? = nil
    ) -> (key: String, roots: [String])? {
        if let capability, SkillMaintenanceTool.names.contains(capability) {
            return PersistentApprovalRuleMatcher.projectScope(roots: scopeRoots ?? facts.allowedWriteRoots)
        }
        if scopeRoots == nil,
           let primary = facts.trustedProjectRoot.flatMap(PolicyRuntimePathBoundary.canonicalPath),
           primary != "/",
           facts.allowedWriteRoots.compactMap(PolicyRuntimePathBoundary.canonicalPath).contains(primary) {
            return PersistentApprovalRuleMatcher.projectScope(roots: [primary], sharingOrdinaryWorkspace: true)
        }
        return PersistentApprovalRuleMatcher.projectScope(
            roots: scopeRoots ?? facts.allowedWriteRoots, sharingOrdinaryWorkspace: true)
    }

    /// 规则是否属于当前项目：新键；旧键（按全部授权根算的键，含旧版各自的普通会话键）；
    /// 旧的多根规则只在授权根集合完全相同（旧键精确匹配）时命中。路径检查仍按当次全部授权根，规则不会因此放宽。
    private func ruleBelongs(
        _ rule: PersistentApprovalRule, scope: (key: String, roots: [String]),
        facts: ComposerPolicyFactSource, scopeRoots: [String]? = nil
    ) -> Bool {
        if rule.projectKey == scope.key { return true }
        // 技能规则风险高，沿用精确的项目键，不做旧键与多根兜底。
        if SkillMaintenanceTool.names.contains(rule.capability) { return false }
        if rule.isGlobal { return true }
        let all = scopeRoots ?? facts.allowedWriteRoots
        for sharing in [true, false] {
            if let legacy = PersistentApprovalRuleMatcher.projectScope(roots: all, sharingOrdinaryWorkspace: sharing),
               legacy.key == rule.projectKey { return true }
        }
        return false
    }

    public func offer(
        capability: String, input: [String: Any], facts: ComposerPolicyFactSource
    ) -> ApprovalPersistentAllowOffer? {
        offer(capability: capability, input: input, facts: facts, scopeRoots: nil)
    }

    func offer(
        capability originalCapability: String, input: [String: Any], facts: ComposerPolicyFactSource,
        scopeRoots: [String]?
    ) -> ApprovalPersistentAllowOffer? {
        // 目录读取规则对 file_read、file_grep、file_glob 通用，统一记成 file_read。
        let searchRoot = originalCapability == "file_grep" || originalCapability == "file_glob"
        let capability = searchRoot ? "file_read" : originalCapability
        // 子任务的只读视图：卡片提供"以后都允许"，规则写进父会话的规则库（按父会话的项目键），
        // 这条具体命令仍用子任务自己的授权根和工作目录过效果检查器。
        if let upstream, capability == "shell_execute" {
            return upstream.offer(capability: capability, input: input, facts: facts,
                                  scopeRoots: scopeRoots ?? upstreamProjectRoots)
        }
        guard isAttached, PersistentApprovalRuleMatcher.supportedCapabilities.contains(capability) else { return nil }
        switch evaluate(capability: capability, input: input, roots: facts.allowedWriteRoots, searchRoot: searchRoot) {
        case .pattern(let pattern):
            // 规则只能跳过弹卡，不能跳过效果检查：这条具体命令过不了检查器，这张卡就不提供"以后都允许"。
            if capability == "shell_execute", let reason = shellGuardViolation(input: input, facts: facts) {
                return ApprovalPersistentAllowOffer(capability: capability, summary: "", unavailableReason: reason)
            }
            guard let scope = ruleScope(facts: facts, capability: capability, scopeRoots: scopeRoots) else {
                return ApprovalPersistentAllowOffer(capability: capability,
                    summary: SkillMaintenanceTool.names.contains(capability) ? "当前没有项目范围" : pattern,
                    unavailableReason: "当前没有会话授权根，无法按项目记住")
            }
            let bindsProject = capability == "shell_execute" && pattern == "git status"
                && facts.allowedWriteRoots.count == 1 && scope.roots.count == 1
            return ApprovalPersistentAllowOffer(capability: capability,
                summary: SkillMaintenanceTool.names.contains(capability) ? scope.roots.joined(separator: "、") : pattern,
                unavailableReason: nil, projectKey: bindsProject ? scope.key : nil)
        case .unavailable(let reason):
            return ApprovalPersistentAllowOffer(capability: capability, summary: "", unavailableReason: reason)
        }
    }

    // MARK: MCP tool rules (one tool of one server configuration, per project)

    /// “以后都允许此 MCP 工具”的提示：键为 项目 + 服务器配置指纹 + 工具名，不含通配。
    public func offerMCP(
        identity: MCPToolRuleIdentity, facts: ComposerPolicyFactSource
    ) -> ApprovalPersistentAllowOffer? {
        guard isAttached else { return nil }
        guard ruleScope(facts: facts) != nil else {
            return ApprovalPersistentAllowOffer(capability: identity.fullName, summary: identity.fullName,
                unavailableReason: "当前没有会话授权根，无法按项目记住")
        }
        return ApprovalPersistentAllowOffer(capability: identity.fullName, summary: identity.fullName,
            unavailableReason: nil)
    }

    public func makeMCPRule(
        identity: MCPToolRuleIdentity, facts: ComposerPolicyFactSource, now: Date = Date()
    ) -> PersistentApprovalRule? {
        guard isAttached, identity.fullName.hasPrefix("mcp_"),
              let scope = ruleScope(facts: facts)
        else { return nil }
        return PersistentApprovalRule(
            projectKey: scope.key, projectRoots: scope.roots, kind: .mcpTool,
            capability: identity.fullName, pattern: identity.rulePattern, createdAt: now)
    }

    public func matchMCP(
        identity: MCPToolRuleIdentity, facts: ComposerPolicyFactSource, sessionID: String? = nil
    ) -> PersistentApprovalRule? {
        guard let scope = ruleScope(facts: facts)
        else { return nil }
        lock.lock()
        let hit = allowCandidates(sessionID: sessionID).first {
            ruleBelongs($0, scope: scope, facts: facts) && $0.kind == .mcpTool
                && $0.capability == identity.fullName && $0.pattern == identity.rulePattern
        }
        lock.unlock()
        if let hit { recordHit(hit) }
        return hit
    }

    /// 持久允许规则 + 这个会话的内存允许规则（调用时须持锁）。
    private func allowCandidates(sessionID: String?) -> [PersistentApprovalRule] {
        guard let sessionID else { return rules }
        return rules + sessionRules.filter { $0.sessionID == sessionID }.map(\.rule)
    }

    /// 记下最近命中时间：内存里立即更新，写盘最多每分钟一次（失败不影响命中）。
    func recordHit(_ rule: PersistentApprovalRule, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            if let last = rules[index].lastMatchedAt, now.timeIntervalSince(last) < 60 { return }
            var next = rules
            next[index].lastMatchedAt = now
            _ = commit(next)
        } else if let index = restrictions.firstIndex(where: { $0.id == rule.id }) {
            if let last = restrictions[index].lastMatchedAt, now.timeIntervalSince(last) < 60 { return }
            var next = restrictions
            next[index].lastMatchedAt = now
            _ = commit(rules, restrictions: next)
        } else if let index = sessionRules.firstIndex(where: { $0.rule.id == rule.id }) {
            sessionRules[index].rule.lastMatchedAt = now
        } else if let index = sessionRestrictions.firstIndex(where: { $0.rule.id == rule.id }) {
            sessionRestrictions[index].rule.lastMatchedAt = now
        }
    }

    /// Build the rule the user just chose; nil if the call is not eligible.
    public func makeRule(
        capability originalCapability: String, input: [String: Any], facts: ComposerPolicyFactSource,
        now: Date = Date()
    ) -> PersistentApprovalRule? {
        // file_grep、file_glob 的目录规则与 file_read 是同一种（"允许读取此目录"）。
        let searchRoot = originalCapability == "file_grep" || originalCapability == "file_glob"
        let capability = searchRoot ? "file_read" : originalCapability
        if capability == "shell_execute" {
            return makeShellRules(input: input, facts: facts, now: now).first
        }
        guard isAttached, let scope = ruleScope(facts: facts, capability: capability),
              case .pattern(let pattern) = evaluate(
                capability: capability, input: input, roots: facts.allowedWriteRoots, searchRoot: searchRoot)
        else { return nil }
        return PersistentApprovalRule(
            projectKey: scope.key, projectRoots: scope.roots,
            kind: Self.ruleKind(for: capability),
            capability: capability, pattern: pattern, createdAt: now)
    }

    /// 复合命令的每个子命令各生成一条前缀规则（单条命令时只有一条）。
    public func makeShellRules(
        input: [String: Any], facts: ComposerPolicyFactSource, now: Date = Date()
    ) -> [PersistentApprovalRule] {
        makeShellRules(input: input, facts: facts, now: now, scopeRoots: nil)
    }

    func makeShellRules(
        input: [String: Any], facts: ComposerPolicyFactSource, now: Date, scopeRoots: [String]?
    ) -> [PersistentApprovalRule] {
        // 子任务的只读视图：规则写进父会话的规则库，键按父会话的授权根；
        // 这条具体命令仍用子任务自己的授权根过效果检查器。
        if let upstream {
            return upstream.makeShellRules(
                input: input, facts: facts, now: now, scopeRoots: scopeRoots ?? upstreamProjectRoots)
        }
        guard isAttached,
              let scope = ruleScope(facts: facts, capability: "shell_execute", scopeRoots: scopeRoots),
              case .patterns(let patterns) = PersistentApprovalRuleMatcher.evaluateShellRules(
                input: input, defaultWorkingDirectory: ChildToolWorkspaceScope.current?.workingDirectory),
              shellGuardViolation(input: input, facts: facts) == nil
        else { return [] }
        return patterns.map {
            PersistentApprovalRule(projectKey: scope.key, projectRoots: scope.roots,
                kind: .shellCommandPrefix, capability: "shell_execute", pattern: $0, createdAt: now)
        }
    }

    /// 网页搜索的"本对话内都允许"：只在内存里记到本会话。
    func addSessionWebSearchRule(sessionID: String, facts: ComposerPolicyFactSource, now: Date = Date()) {
        if let upstream {
            upstream.addSessionWebSearchRule(sessionID: upstreamSessionID ?? sessionID, facts: facts, now: now)
            return
        }
        guard let scope = ruleScope(facts: facts, capability: "web_search") else { return }
        lock.lock(); defer { lock.unlock() }
        guard !sessionRules.contains(where: {
            $0.sessionID == sessionID && $0.rule.capability == "web_search" && $0.rule.projectKey == scope.key
        }) else { return }
        sessionRules.append((sessionID, PersistentApprovalRule(
            projectKey: scope.key, projectRoots: scope.roots, kind: .projectDirectory,
            capability: "web_search", pattern: PersistentApprovalRuleMatcher.webSearchAlwaysPattern,
            createdAt: now)))
    }

    /// "本对话内都允许"：只在内存里保存，随应用退出或会话结束消失，不写入规则文件。
    public func addSessionShellRules(
        sessionID: String, input: [String: Any], facts: ComposerPolicyFactSource, now: Date = Date()
    ) {
        // 子任务点的"本对话内都允许"存到父会话 ID 下。
        let owner = upstream != nil ? (upstreamSessionID ?? sessionID) : sessionID
        let made = makeShellRules(input: input, facts: facts, now: now)
        guard !made.isEmpty else { return }
        if let upstream {
            upstream.addSessionRules(made, sessionID: owner)
            return
        }
        lock.lock(); defer { lock.unlock() }
        for rule in made where !sessionRules.contains(where: {
            $0.sessionID == sessionID && $0.rule.projectKey == rule.projectKey && $0.rule.pattern == rule.pattern
        }) {
            sessionRules.append((sessionID, rule))
        }
    }

    fileprivate func addSessionRules(_ made: [PersistentApprovalRule], sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        for rule in made where !sessionRules.contains(where: {
            $0.sessionID == sessionID && $0.rule.projectKey == rule.projectKey && $0.rule.pattern == rule.pattern
        }) {
            sessionRules.append((sessionID, rule))
        }
    }

    /// 绕过档下"看不清内容的 osascript"的"本对话内都允许"：只在内存里记会话 ID。
    func allowOpaqueScript(sessionID: String) {
        if let upstream {
            upstream.allowOpaqueScript(sessionID: upstreamSessionID ?? sessionID)
            return
        }
        lock.lock(); defer { lock.unlock() }
        opaqueScriptSessions.insert(sessionID)
    }

    func isOpaqueScriptAllowed(sessionID: String) -> Bool {
        if let upstream { return upstream.isOpaqueScriptAllowed(sessionID: upstreamSessionID ?? sessionID) }
        lock.lock(); defer { lock.unlock() }
        return opaqueScriptSessions.contains(sessionID)
    }

    public func clearSessionRules(sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        opaqueScriptSessions.remove(sessionID)
        sessionRules.removeAll { $0.sessionID == sessionID }
        sessionRestrictions.removeAll { $0.sessionID == sessionID }
        buildConfigTouchedSessions.remove(sessionID)
    }

    func markBuildConfigTouched(sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        buildConfigTouchedSessions.insert(sessionID)
    }

    func buildConfigTouched(sessionID: String) -> Bool {
        if let upstream { return upstream.buildConfigTouched(sessionID: upstreamSessionID ?? sessionID) }
        lock.lock(); defer { lock.unlock() }
        return buildConfigTouchedSessions.contains(sessionID)
    }

    /// 复合命令只有每个子命令都被某条规则（持久或本对话）覆盖才算命中，返回第一个子命令的规则。
    ///
    /// 规则只能跳过弹卡，不能跳过效果检查：前缀命中后，这条具体命令的每个子命令还要过
    /// `ShellEffectGuard`（路径、敏感文件、授权根、cwd、保留字），任一项不过都当作没命中，
    /// 退回正常弹卡。`scopeRoots` 只给子任务的只读视图用：规则按父会话的项目键查，
    /// 路径检查仍用子任务自己的授权根和工作目录（`facts`）。
    private func matchShell(
        input: [String: Any], facts: ComposerPolicyFactSource, sessionID: String?,
        scopeRoots: [String]? = nil
    ) -> PersistentApprovalRule? {
        guard let scope = ruleScope(facts: facts, capability: "shell_execute", scopeRoots: scopeRoots),
              case .patterns(let patterns) = PersistentApprovalRuleMatcher.evaluateShellRules(
                input: input, defaultWorkingDirectory: ChildToolWorkspaceScope.current?.workingDirectory),
              shellGuardViolation(input: input, facts: facts) == nil
        else { return nil }
        lock.lock(); defer { lock.unlock() }
        var first: PersistentApprovalRule?
        for pattern in patterns {
            let hit = rules.first {
                ruleBelongs($0, scope: scope, facts: facts, scopeRoots: scopeRoots)
                    && $0.capability == "shell_execute"
                    && $0.kind == .shellCommandPrefix && $0.pattern == pattern
            } ?? sessionRules.first {
                $0.sessionID == sessionID && ruleBelongs($0.rule, scope: scope, facts: facts, scopeRoots: scopeRoots)
                    && $0.rule.capability == "shell_execute" && $0.rule.pattern == pattern
            }?.rule
            guard let hit else { return nil }
            if first == nil { first = hit }
        }
        return first
    }

    public func match(
        capability: String, input: [String: Any], facts: ComposerPolicyFactSource,
        bypassConfirmed: Bool = false, sessionID: String? = nil
    ) -> PersistentApprovalRule? {
        let hit = matchAllow(capability: capability, input: input, facts: facts,
                             bypassConfirmed: bypassConfirmed, sessionID: sessionID)
        if let hit { recordHit(hit) }
        return hit
    }

    private func matchAllow(
        capability: String, input: [String: Any], facts: ComposerPolicyFactSource,
        bypassConfirmed: Bool, sessionID: String?
    ) -> PersistentApprovalRule? {
        // 子任务的只读视图：用父会话的规则库和父会话 ID（本对话规则），自己的授权根与工作目录做检查。
        if let upstream {
            if capability == "shell_execute" {
                return upstream.matchShell(input: input, facts: facts, sessionID: upstreamSessionID,
                                           scopeRoots: upstreamProjectRoots)
            }
            return upstream.match(capability: capability, input: input, facts: facts,
                                  bypassConfirmed: bypassConfirmed, sessionID: upstreamSessionID)
        }
        if capability == "shell_execute" {
            return matchShell(input: input, facts: facts, sessionID: sessionID)
        }
        // 目录读取规则对 file_read、file_grep、file_glob 通用：file_grep、file_glob 的 path 本身是被搜索的目录，
        // 落在规则目录内（含规则目录本身）即命中；敏感文件、应用自身数据照旧不命中。
        if capability == "file_grep" || capability == "file_glob" {
            guard let scope = ruleScope(facts: facts, capability: "file_read"),
                  let raw = input["path"] as? String, raw.hasPrefix("/"),
                  let canonical = PolicyRuntimePathBoundary.canonicalPath(raw),
                  !SensitiveFilePolicy.contains(raw), !SensitiveFilePolicy.contains(canonical),
                  !SensitiveFilePolicy.isProtectedStatePath(canonical),
                  BypassAppDataFloor.violation(path: canonical, access: .read) == nil
            else { return nil }
            lock.lock(); defer { lock.unlock() }
            return allowCandidates(sessionID: sessionID).first {
                ruleBelongs($0, scope: scope, facts: facts) && $0.capability == "file_read"
                    && $0.kind == .projectDirectory
                    && (canonical == $0.pattern || canonical.hasPrefix($0.pattern + "/"))
            }
        }
        guard PersistentApprovalRuleMatcher.supportedCapabilities.contains(capability),
              let scope = ruleScope(facts: facts, capability: capability),
              case .pattern(let pattern) = evaluate(capability: capability, input: input, roots: facts.allowedWriteRoots)
        else { return nil }
        lock.lock(); defer { lock.unlock() }
        if capability == "file_read" {
            // 目录规则：被读文件落在规则目录内（含子目录）即命中。
            return allowCandidates(sessionID: sessionID).first {
                ruleBelongs($0, scope: scope, facts: facts) && $0.capability == "file_read"
                    && $0.kind == .projectDirectory
                    && Self.isPath(input["path"] as? String, within: $0.pattern)
            }
        }
        if capability == "web_search" {
            // 持久规则，或本会话"本对话内都允许"（仅内存）。
            if let hit = rules.first(where: {
                ruleBelongs($0, scope: scope, facts: facts) && $0.capability == "web_search"
                    && $0.pattern == PersistentApprovalRuleMatcher.webSearchAlwaysPattern
            }) { return hit }
            guard let sessionID else { return nil }
            return sessionRules.first(where: {
                $0.sessionID == sessionID && $0.rule.capability == "web_search"
                    && ruleBelongs($0.rule, scope: scope, facts: facts)
            })?.rule
        }
        // 写文件规则覆盖同一目录下的编辑（写 ⊇ 编辑）；编辑规则不覆盖写。
        let acceptedCapabilities = capability == "file_edit" ? ["file_edit", "file_write"] : [capability]
        // 手动新增的"写入路径"允许规则可以只写某个子目录或文件：上面的 evaluate 已确认这条路径在授权根内、
        // 不是敏感文件、构建配置或 .git/.claude 等位置，这里只是再要求它落在规则路径之下。
        let targetPath = (input["path"] as? String).flatMap(PolicyRuntimePathBoundary.canonicalPath)
        return allowCandidates(sessionID: sessionID).first { rule in
            guard ruleBelongs(rule, scope: scope, facts: facts), acceptedCapabilities.contains(rule.capability),
                  rule.kind == Self.ruleKind(for: capability) else { return false }
            if rule.pattern == pattern { return true }
            if bypassConfirmed, SkillMaintenanceTool.names.contains(capability),
               rule.pattern == PersistentApprovalRuleMatcher.skillBypassPattern { return true }
            guard rule.origin != .approvalCard, ["file_write", "file_edit"].contains(capability),
                  let targetPath else { return false }
            return targetPath == rule.pattern || targetPath.hasPrefix(rule.pattern + "/")
        }
    }

    /// Called only by the native risk confirmation UI. Saving still uses the
    /// existing add/remove store; the record grants one action in this project.
    public func makeSkillBypassRule(
        capability: String, facts: ComposerPolicyFactSource, now: Date = Date()
    ) -> PersistentApprovalRule? {
        guard isAttached, SkillMaintenanceTool.names.contains(capability),
              let scope = PersistentApprovalRuleMatcher.projectScope(roots: facts.allowedWriteRoots)
        else { return nil }
        return PersistentApprovalRule(projectKey: scope.key, projectRoots: scope.roots,
            kind: .projectDirectory, capability: capability,
            pattern: PersistentApprovalRuleMatcher.skillBypassPattern, createdAt: now)
    }

    private static func isPath(_ raw: String?, within directory: String) -> Bool {
        guard let raw, let canonical = PolicyRuntimePathBoundary.canonicalPath(raw) else { return false }
        return canonical.hasPrefix(directory + "/")
    }

    private static func ruleKind(for capability: String) -> PersistentApprovalRuleKind {
        if capability == "shell_execute" { return .shellCommandPrefix }
        if capability == "web_fetch" { return .webHost }
        if capability.hasPrefix("mcp_") { return .mcpTool }
        return .projectDirectory
    }

    private func evaluate(
        capability: String, input: [String: Any], roots: [String], searchRoot: Bool = false
    ) -> PersistentApprovalRuleMatcher.Evaluation {
        if SkillMaintenanceTool.names.contains(capability) {
            return .pattern(PersistentApprovalRuleMatcher.skillAlwaysPattern)
        }
        if capability == "web_fetch" { return PersistentApprovalRuleMatcher.evaluateWebFetch(input: input) }
        if capability == "web_search" {
            // 网址形式的 query 不按搜索处理（风险判定已按网址检查），不提供“以后都允许”。
            if let query = input["query"] as? String,
               query.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http") {
                return .unavailable("请求带网址，每次都需询问")
            }
            return .pattern(PersistentApprovalRuleMatcher.webSearchAlwaysPattern)
        }
        if capability == "shell_execute" {
            // 复合命令有多个前缀：卡片上显示全部将保存的前缀。
            switch PersistentApprovalRuleMatcher.evaluateShellRules(input: input,
                defaultWorkingDirectory: ChildToolWorkspaceScope.current?.workingDirectory) {
            case .patterns(let patterns): return .pattern(patterns.joined(separator: "、"))
            case .unavailable(let reason): return .unavailable(reason)
            }
        }
        if capability == "file_read" {
            return PersistentApprovalRuleMatcher.evaluateFileRead(
                input: input, home: homeDirectory, searchRoot: searchRoot)
        }
        return PersistentApprovalRuleMatcher.evaluateFile(
            capability: capability, input: input, roots: roots, home: homeDirectory)
    }

    // MARK: Persistence (call with lock held)

    private func commit(
        _ next: [PersistentApprovalRule], restrictions nextRestrictions: [PersistentApprovalRule]? = nil
    ) -> Bool {
        guard let fileURL else { return false }
        let nextRestrictions = nextRestrictions ?? restrictions
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(PersistentApprovalRuleFile(
                schemaVersion: PersistentApprovalRuleFile.currentSchemaVersion, rules: next,
                restrictions: nextRestrictions.isEmpty ? nil : nextRestrictions))
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Create the temp file already 0600 (no window where it is more
            // open), then replace the real file with one atomic rename.
            let temporary = directory.appendingPathComponent(
                ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(
                atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if rename(temporary.path, fileURL.path) != 0 {
                let code = errno
                try? FileManager.default.removeItem(at: temporary)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            rules = next
            restrictions = nextRestrictions
            return true
        } catch {
            record("规则文件写入失败，规则未保存：\(error.localizedDescription)")
            return false
        }
    }

    private func setAside(_ url: URL) {
        let aside = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    private func record(_ message: String) {
        diagnosticLog.append(message)
        if diagnosticLog.count > 20 { diagnosticLog.removeFirst(diagnosticLog.count - 20) }
    }
}

// MARK: - 会话目标规则（session_read / session_send / external_session_send）

extension PersistentApprovalRuleStore {
    /// 命中：持久规则，或本会话（“本对话内都允许”，仅内存）里记过同一目标。
    public func matchSessionTarget(
        capability: String, input: [String: Any], sessionID: String?
    ) -> PersistentApprovalRule? {
        guard SessionTargetApprovalRules.isSessionTargetCapability(capability),
              case .key(let key, _) = SessionTargetApprovalRules.evaluate(
                capability: capability, input: input, initiatorSessionID: sessionID)
        else { return nil }
        lock.lock(); defer { lock.unlock() }
        // 外部会话发送、run 模式的 session_send 只认“本对话内”规则；旧版本留下的永久规则不再命中。
        if SessionTargetApprovalRules.persistenceRestriction(capability: capability, input: input) == nil,
           let hit = rules.first(where: {
               $0.kind == .sessionTarget && $0.capability == capability && $0.pattern == key
           }) { return hit }
        guard let sessionID else { return nil }
        return sessionRules.first(where: {
            $0.sessionID == sessionID && $0.rule.kind == .sessionTarget
                && $0.rule.capability == capability && $0.rule.pattern == key
        })?.rule
    }

    /// “本对话内都允许（对此目标会话）”：只在内存里记到本会话，不写入规则文件。
    public func addSessionTargetSessionRule(
        sessionID: String, capability: String, input: [String: Any], now: Date = Date()
    ) {
        guard let rule = makeSessionTargetRule(
            capability: capability, input: input, initiatorSessionID: sessionID, now: now) else { return }
        lock.lock(); defer { lock.unlock() }
        guard !sessionRules.contains(where: {
            $0.sessionID == sessionID && $0.rule.kind == .sessionTarget
                && $0.rule.capability == rule.capability && $0.rule.pattern == rule.pattern
        }) else { return }
        sessionRules.append((sessionID, rule))
    }
}

// MARK: - 拒绝、每次询问规则与面板管理

public struct PermissionRuleImportResult: Sendable {
    public let saved: [PersistentApprovalRule]
    public let failed: [ImportedPermissionSkip]
}

extension PersistentApprovalRuleStore {
    /// 命中的第一条拒绝（或每次询问）规则。授权链在三处调用它：执行前复检的 `validate`（拒绝）、
    /// 授权判定 `authorizeResolvingRule`（询问）和审批卡生成（询问卡不提供"以后都允许"）。
    public func matchRestriction(
        _ behavior: PersistentApprovalRuleBehavior, capability: String, input: [String: Any],
        facts: ComposerPolicyFactSource, sessionID: String?
    ) -> PersistentApprovalRule? {
        matchRestriction(behavior, capability: capability, input: input, facts: facts,
                         sessionID: sessionID, scopeRoots: nil)
    }

    func matchRestriction(
        _ behavior: PersistentApprovalRuleBehavior, capability: String, input: [String: Any],
        facts: ComposerPolicyFactSource, sessionID: String?, scopeRoots: [String]?
    ) -> PersistentApprovalRule? {
        // 子任务的只读视图：规则在父会话的库里，按父会话的项目键和会话 ID 查。
        if let upstream {
            return upstream.matchRestriction(
                behavior, capability: capability, input: input, facts: facts,
                sessionID: upstreamSessionID, scopeRoots: scopeRoots ?? upstreamProjectRoots)
        }
        lock.lock()
        var candidates = restrictions
        if let sessionID { candidates += sessionRestrictions.filter { $0.sessionID == sessionID }.map(\.rule) }
        lock.unlock()
        candidates = candidates.filter { $0.behavior == behavior }
        guard !candidates.isEmpty else { return nil }
        let scope = ruleScope(facts: facts, scopeRoots: scopeRoots)
        let hit = candidates.first { rule in
            let belongs = rule.isGlobal
                || (scope.map { ruleBelongs(rule, scope: $0, facts: facts, scopeRoots: scopeRoots) } ?? false)
            return belongs && PermissionRuleMatching.matches(rule: rule, capability: capability, input: input)
        }
        if let hit { recordHit(hit) }
        return hit
    }

    /// 命中的拒绝规则对用户的说明（工具结果里显示）。
    public static func denialMessage(_ rule: PersistentApprovalRule) -> String {
        "已被你设置的“拒绝”规则拦下（\(rule.pattern == PersistentApprovalRuleMatcher.webSearchAlwaysPattern ? "联网搜索" : rule.pattern)），不会执行。如需放行，请到 设置 → 权限 → 规则管理 删除这条规则。"
    }

    /// 面板里新增一条规则。"允许"规则沿用审批卡的全部安全判定，不通过时给出原因。
    public func addManualRule(
        draft: PermissionRuleDraft, origin: PersistentApprovalRuleOrigin = .manual,
        context: PermissionRuleContext, now: Date = Date()
    ) -> Result<PersistentApprovalRule, PermissionRuleRejection> {
        guard isAttached else { return .failure(.init("规则文件未接入，无法保存。")) }
        switch PermissionRuleBuilder.build(draft: draft, origin: origin, context: context, createdAt: now) {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let rule):
            guard applyChange(remove: nil, insert: (rule, Self.sessionID(of: draft.scope))) else {
                return .failure(.init("规则文件写入失败，规则未保存。"))
            }
            return .success(rule)
        }
    }

    /// 面板里编辑一条规则：新内容校验通过才替换，失败则原规则不变；保留 id 和创建时间。
    public func editRule(
        id: String, draft: PermissionRuleDraft, context: PermissionRuleContext, now: Date = Date()
    ) -> Result<PersistentApprovalRule, PermissionRuleRejection> {
        guard isAttached else { return .failure(.init("规则文件未接入，无法保存。")) }
        lock.lock()
        let existing = (rules + restrictions + sessionRules.map(\.rule) + sessionRestrictions.map(\.rule))
            .first { $0.id == id }
        lock.unlock()
        guard let existing else { return .failure(.init("这条规则已不存在。")) }
        let origin: PersistentApprovalRuleOrigin = existing.origin == .approvalCard ? .manual : existing.origin
        switch PermissionRuleBuilder.build(
            draft: draft, origin: origin, context: context, id: id, createdAt: existing.createdAt) {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let rule):
            guard applyChange(remove: id, insert: (rule, Self.sessionID(of: draft.scope))) else {
                return .failure(.init("规则文件写入失败，规则未保存。"))
            }
            return .success(rule)
        }
    }

    /// 导入用户逐条确认过的候选规则；每条仍过手动新增的校验，不通过的列在 failed 里。
    public func importRules(
        _ candidates: [ImportedPermissionCandidate], context: PermissionRuleContext, now: Date = Date()
    ) -> PermissionRuleImportResult {
        var saved: [PersistentApprovalRule] = []
        var failed: [ImportedPermissionSkip] = []
        for candidate in candidates {
            switch addManualRule(draft: candidate.draft, origin: .imported, context: context, now: now) {
            case .success(let rule): saved.append(rule)
            case .failure(let rejection):
                failed.append(.init(id: candidate.id, source: candidate.source, original: candidate.original,
                                    reason: rejection.reason))
            }
        }
        return PermissionRuleImportResult(saved: saved, failed: failed)
    }

    private static func sessionID(of scope: PersistentApprovalRuleScope) -> String? {
        if case .session(let id) = scope { return id }
        return nil
    }
}
