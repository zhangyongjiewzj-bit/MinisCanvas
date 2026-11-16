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
}

/// One user-created "allow from now on" rule. A rule never replaces the
/// per-call approval receipt: a rule hit still mints a call-bound receipt in
/// `ComposerPolicyEnforcedToolExecutor`.
public struct PersistentApprovalRule: Codable, Equatable, Sendable, Identifiable {
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

    public init(
        id: String = UUID().uuidString,
        projectKey: String,
        projectRoots: [String],
        kind: PersistentApprovalRuleKind,
        capability: String,
        pattern: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectKey = projectKey
        self.projectRoots = projectRoots
        self.kind = kind
        self.capability = capability
        self.pattern = pattern
        self.createdAt = createdAt
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
        Set(["shell_execute", "file_write", "file_edit", "web_fetch"]).union(SkillMaintenanceTool.names)

    /// Shown for every command that is not on `persistentAllowlist`.
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

    /// The ONLY commands that can ever be remembered ("允许以后都" is an
    /// allowlist, not a denylist). Key = pattern prefix, value = argument rule.
    ///
    /// Deliberately NOT here, and why:
    /// - `git config / checkout / restore / reset / clean / push / fetch /
    ///   pull / commit / rebase / stash / apply`: they rewrite the work tree,
    ///   the index, history or `.git/config`, or talk to a network remote;
    ///   `git config` can also plant `core.fsmonitor` / `core.pager` /
    ///   `alias.*` that make later "harmless" `git status` run arbitrary code.
    /// - `npm install / ci / publish / exec / x`, `yarn add / dlx`, `pnpm add /
    ///   dlx`: run lifecycle scripts or download and run remote code.
    /// - `make <anything but test>`: targets are arbitrary shell recipes.
    /// - `cat`, `head`, `find`, `grep`, `echo`, `open`, `curl`, interpreters,
    ///   `rm`/`mv`/`cp`/`mkdir`/`touch`: read arbitrary files, write, or take
    ///   arbitrary behaviour from their arguments.
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
        if let cwd = input["cwd"] {
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
    static func unsafeShellTextReason(_ command: String) -> String? {
        var previous: Unicode.Scalar?
        for scalar in command.unicodeScalars {
            defer { previous = scalar }
            if shellMetacharacterScalars.contains(scalar) {
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
        if argument.contains("..") { return false }
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
    ]

    private static func isSafeGitArgument(_ argument: String) -> Bool {
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
            return !(argument.hasPrefix("-c") || argument.hasPrefix("-O") || argument.hasPrefix("-C"))
        }
        return true
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
    public static func projectScope(roots: [String]) -> (key: String, roots: [String])? {
        let canonical = Set(roots.compactMap(PolicyRuntimePathBoundary.canonicalPath).filter { $0 != "/" })
        guard !canonical.isEmpty else { return nil }
        let sorted = canonical.sorted()
        let digest = SHA256.hash(data: Data(sorted.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return (String(digest.prefix(32)), sorted)
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
}

/// Read side of the file: one unrecognised rule (for example a `kind` written
/// by a newer build) is skipped and counted instead of failing the whole file.
private struct PersistentApprovalRuleFileReader: Decodable {
    var schemaVersion: Int
    var entries: [Entry]

    struct Entry: Decodable {
        let rule: PersistentApprovalRule?
        init(from decoder: Decoder) throws {
            rule = try? PersistentApprovalRule(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, rules }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        entries = try container.decode([Entry].self, forKey: .rules)
    }
}

/// Durable rule list. A store without a file URL is inert: it offers and
/// matches nothing, so isolated tests and fixtures never touch user data.
public final class PersistentApprovalRuleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var fileURL: URL?
    private let homeDirectory: String
    private var rules: [PersistentApprovalRule] = []
    private var diagnosticLog: [String] = []

    /// `homeDirectory` is injectable so tests can exercise the "session root
    /// covers the home directory" exclusion without touching the real home.
    public init(fileURL: URL? = nil, homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
        if let fileURL { attach(fileURL: fileURL) }
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(PersistentApprovalRuleFileReader.self, from: data)
            guard file.schemaVersion == PersistentApprovalRuleFile.currentSchemaVersion else {
                record("规则文件版本 \(file.schemaVersion) 不受支持，按无规则处理")
                setAside(fileURL)
                return
            }
            var skipped = 0
            for entry in file.entries {
                if let rule = entry.rule, Self.isRecognised(rule) { rules.append(rule) } else { skipped += 1 }
            }
            if skipped > 0 {
                record("规则文件中有 \(skipped) 条无法识别的规则，已跳过；原文件已复制为 .unrecognized")
                let copy = fileURL.appendingPathExtension("unrecognized")
                try? FileManager.default.removeItem(at: copy)
                try? FileManager.default.copyItem(at: fileURL, to: copy)
            }
        } catch {
            record("规则文件读取失败，按无规则处理：\(error.localizedDescription)")
            setAside(fileURL)
        }
    }

    private static func isRecognised(_ rule: PersistentApprovalRule) -> Bool {
        switch rule.kind {
        case .shellCommandPrefix: return rule.capability == "shell_execute"
        case .webHost:
            return rule.capability == "web_fetch"
                && BrowserNavigationPolicy.normalizedHost(rule.pattern) == rule.pattern
        case .projectDirectory:
            if SkillMaintenanceTool.names.contains(rule.capability) {
                return [PersistentApprovalRuleMatcher.skillAlwaysPattern,
                        PersistentApprovalRuleMatcher.skillBypassPattern].contains(rule.pattern)
            }
            return rule.capability == "file_write" || rule.capability == "file_edit"
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

    public func allRules() -> [PersistentApprovalRule] {
        lock.lock(); defer { lock.unlock() }
        return rules
    }

    public func diagnostics() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return diagnosticLog
    }

    /// Returns false (and keeps memory unchanged) when the write fails.
    @discardableResult
    public func add(_ rule: PersistentApprovalRule) -> Bool {
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
        guard rules.contains(where: { $0.id == id }) else { return false }
        return commit(rules.filter { $0.id != id })
    }

    @discardableResult
    public func removeAll() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !rules.isEmpty else { return true }
        return commit([])
    }

    // MARK: Decision support

    public func offer(
        capability: String, input: [String: Any], facts: ComposerPolicyFactSource
    ) -> ApprovalPersistentAllowOffer? {
        guard isAttached, PersistentApprovalRuleMatcher.supportedCapabilities.contains(capability) else { return nil }
        switch evaluate(capability: capability, input: input, roots: facts.allowedWriteRoots) {
        case .pattern(let pattern):
            guard let scope = PersistentApprovalRuleMatcher.projectScope(roots: facts.allowedWriteRoots) else {
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

    /// Build the rule the user just chose; nil if the call is not eligible.
    public func makeRule(
        capability: String, input: [String: Any], facts: ComposerPolicyFactSource, now: Date = Date()
    ) -> PersistentApprovalRule? {
        guard isAttached, let scope = PersistentApprovalRuleMatcher.projectScope(roots: facts.allowedWriteRoots),
              case .pattern(let pattern) = evaluate(capability: capability, input: input, roots: facts.allowedWriteRoots)
        else { return nil }
        return PersistentApprovalRule(
            projectKey: scope.key, projectRoots: scope.roots,
            kind: Self.ruleKind(for: capability),
            capability: capability, pattern: pattern, createdAt: now)
    }

    public func match(
        capability: String, input: [String: Any], facts: ComposerPolicyFactSource,
        bypassConfirmed: Bool = false
    ) -> PersistentApprovalRule? {
        guard PersistentApprovalRuleMatcher.supportedCapabilities.contains(capability),
              let scope = PersistentApprovalRuleMatcher.projectScope(roots: facts.allowedWriteRoots),
              case .pattern(let pattern) = evaluate(capability: capability, input: input, roots: facts.allowedWriteRoots)
        else { return nil }
        lock.lock(); defer { lock.unlock() }
        return rules.first {
            $0.projectKey == scope.key && $0.capability == capability && $0.kind == Self.ruleKind(for: capability) &&
                ($0.pattern == pattern || (bypassConfirmed && SkillMaintenanceTool.names.contains(capability)
                    && $0.pattern == PersistentApprovalRuleMatcher.skillBypassPattern))
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

    private static func ruleKind(for capability: String) -> PersistentApprovalRuleKind {
        if capability == "shell_execute" { return .shellCommandPrefix }
        if capability == "web_fetch" { return .webHost }
        return .projectDirectory
    }

    private func evaluate(
        capability: String, input: [String: Any], roots: [String]
    ) -> PersistentApprovalRuleMatcher.Evaluation {
        if SkillMaintenanceTool.names.contains(capability) {
            return .pattern(PersistentApprovalRuleMatcher.skillAlwaysPattern)
        }
        if capability == "web_fetch" { return PersistentApprovalRuleMatcher.evaluateWebFetch(input: input) }
        if capability == "shell_execute" {
            return PersistentApprovalRuleMatcher.evaluateShell(input: input,
                defaultWorkingDirectory: ChildToolWorkspaceScope.current?.workingDirectory)
        }
        return PersistentApprovalRuleMatcher.evaluateFile(
            capability: capability, input: input, roots: roots, home: homeDirectory)
    }

    // MARK: Persistence (call with lock held)

    private func commit(_ next: [PersistentApprovalRule]) -> Bool {
        guard let fileURL else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(PersistentApprovalRuleFile(
                schemaVersion: PersistentApprovalRuleFile.currentSchemaVersion, rules: next))
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
