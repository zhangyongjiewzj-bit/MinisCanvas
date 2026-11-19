import Foundation

// 规则管理面板（对齐 Claude Code /permissions）的纯逻辑：拒绝、每次询问规则的命中判定，
// 面板里手动新增规则的校验，以及从 .claude/settings.json 导入。
// 这里不持有任何状态；规则的存取在 PersistentApprovalRuleStore，授权链接入在 ComposerApprovalPolicy。

// MARK: - 命中判定（拒绝、每次询问）

/// 拒绝、每次询问规则的命中判定。方向与"允许"相反：宁可多命中。
/// 前缀匹配比允许规则宽松（首词不分大小写、剥任意环境变量前缀、跳过 git 全局选项和透明包装）。
/// 已知限制（与 Claude Code 一样）：命令里读取被拒文件（`cat` 等）、搜索根是被拒目录的上级，这里都不拦；
/// 那些路径由敏感文件判定、授权根和效果检查器各自负责。
enum PermissionRuleMatching {
    /// 这些命令会把后面的词当作另一条命令执行：前缀规则在它们后面的任意位置也算命中（`bash -c "git push"`）。
    static let wrapperWords: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "env", "xargs", "sudo", "doas", "nohup", "time",
        "timeout", "command", "exec", "eval", "nice", "caffeinate", "watch", "su", "stdbuf",
    ]

    static let readCapabilities: Set<String> = ["file_read", "file_grep", "file_glob"]
    static let writeCapabilities: Set<String> = ["file_write", "file_edit", "file_delete"]

    static func matches(
        rule: PersistentApprovalRule, capability: String, input: [String: Any]
    ) -> Bool {
        switch rule.kind {
        case .shellCommandPrefix:
            guard capability == "shell_execute", let command = input["command"] as? String else { return false }
            return shellPrefixMatches(prefix: rule.pattern, command: command)
        case .webHost:
            guard let url = webURL(capability: capability, input: input),
                  let host = url.host.flatMap(BrowserNavigationPolicy.normalizedHost) else { return false }
            return hostMatches(pattern: rule.pattern, host: host)
        case .mcpTool:
            guard capability.hasPrefix("mcp_") else { return false }
            return capability == rule.pattern || (rule.pattern.hasSuffix("_") && capability.hasPrefix(rule.pattern))
        case .projectDirectory:
            if rule.capability == "web_search" { return capability == "web_search" }
            let applies = rule.capability == "file_read"
                ? readCapabilities.contains(capability)
                : writeCapabilities.contains(capability)
            guard applies, let raw = input["path"] as? String else { return false }
            var candidates = [raw]
            if let canonical = PolicyRuntimePathBoundary.canonicalPath(raw) { candidates.append(canonical) }
            return pathMatches(pattern: rule.pattern, candidates: candidates)
        case .sessionTarget:
            return false
        }
    }

    private static func webURL(capability: String, input: [String: Any]) -> URL? {
        if capability == WebFetchToolContract.toolName {
            return (input["url"] as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if BrowserSideEffectPolicy.browserToolNames.contains(capability.lowercased()),
           (input["action"] as? String) == "navigate" {
            return (input["url"] as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return nil
    }

    static func hostMatches(pattern: String, host: String) -> Bool {
        host == pattern || host.hasSuffix("." + pattern)
    }

    // MARK: shell

    /// 每个子命令的词表：优先用规范解析（已剥掉固定重定向和包装），再并上一个粗拆分的结果，
    /// 这样 `$(…)`、重定向、引号不完整这类解析不了的写法也会被前缀规则看到。
    static func shellWordLists(_ command: String) -> [[String]] {
        var lists: [[String]] = []
        let analyzed = PersistentApprovalRuleMatcher.shellSubcommandWords(command: command)
        if analyzed.reason == nil { lists.append(contentsOf: analyzed.words) }
        let separators = CharacterSet(charactersIn: ";&|\n\r()`<>")
        let quotes = CharacterSet(charactersIn: "'\"\\")
        for segment in command.components(separatedBy: separators) {
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { String($0).trimmingCharacters(in: quotes) }
                .filter { !$0.isEmpty }
            guard !words.isEmpty else { continue }
            lists.append(words)
            lists.append(PersistentApprovalRuleMatcher.strippingWrappers(words))
        }
        return lists
    }

    /// 拒绝、询问方向才用的宽松归一：这些词开头的段会被当作"下一个词才是真命令"。
    static let reservedFirstWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "for", "case", "esac",
        "select", "function", "{", "}", "!",
    ]
    /// 只是把后面的词转交执行、自身不改变命令含义的包装。
    static let transparentWrappers: Set<String> = ["command", "builtin", "exec", "nohup", "time", "env"]
    /// git 全局选项里带单独取值词的几个（`git -C 路径 push`）。
    static let gitGlobalOptionsWithValue: Set<String> = [
        "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env",
    ]

    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let head = name.unicodeScalars.first, head == "_" || CharacterSet.letters.contains(head) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }

    /// 一个子命令词表的所有"可能的真命令"写法（含原样）：去掉词内引号和反斜杠、全小写、
    /// 循环剥掉任意 `VAR=值` 前缀、保留字、透明包装和 git 全局选项。只用于拒绝、询问规则；允许规则不走这里。
    static func restrictiveVariants(_ original: [String]) -> [[String]] {
        let quoteChars = CharacterSet(charactersIn: "'\"\\")
        func clean(_ word: String) -> String {
            word.unicodeScalars.filter { !quoteChars.contains($0) }.map(String.init).joined()
        }
        func baseName(_ word: String) -> String {
            word.contains("/") ? (word as NSString).lastPathComponent : word
        }
        var results: [[String]] = []
        var seen = Set<[String]>()
        var pending: [[String]] = [original.map { clean($0).lowercased() }.filter { !$0.isEmpty }]
        while let words = pending.popLast(), results.count < 64 {
            guard let first = words.first, seen.insert(words).inserted else { continue }
            results.append(words)
            let base = baseName(first)
            if base != first { pending.append([base] + words.dropFirst()) }
            if isEnvironmentAssignment(first) || reservedFirstWords.contains(first) {
                pending.append(Array(words.dropFirst()))
            } else if transparentWrappers.contains(base) {
                var rest = Array(words.dropFirst())
                pending.append(rest)
                while let flag = rest.first, flag.hasPrefix("-") { rest.removeFirst() }
                pending.append(rest)
            } else if base == "git" {
                var index = 1
                while index < words.count, words[index].hasPrefix("-") {
                    index += gitGlobalOptionsWithValue.contains(words[index]) ? 2 : 1
                }
                if index > 1, index <= words.count { pending.append([base] + words[index...]) }
            }
        }
        return results
    }

    static func shellPrefixMatches(prefix: String, command: String) -> Bool {
        let target = prefix.split(separator: " ").map { $0.lowercased() }
        guard !target.isEmpty else { return false }
        for original in shellWordLists(command) {
            for words in restrictiveVariants(original) {
                if words.starts(with: target) { return true }
                guard let first = words.first, wrapperWords.contains(first), words.count > target.count else { continue }
                for start in 1...(words.count - target.count)
                where Array(words[start..<(start + target.count)]) == target { return true }
            }
        }
        return false
    }

    // MARK: path

    private static let globCharacters = CharacterSet(charactersIn: "*?[")

    static func isGlob(_ pattern: String) -> Bool {
        pattern.rangeOfCharacter(from: globCharacters) != nil
    }

    /// 规则路径是文件或目录（目录递归覆盖子路径）；含通配符时按 fnmatch 匹配（`*` 可跨目录）。
    /// 比较时统一折叠大小写和 Unicode 规范化（macOS 卷默认不区分）。
    static func pathMatches(pattern: String, candidates: [String]) -> Bool {
        // 规则路径和候选路径都剥掉 /System/Volumes/Data、/private 前缀再比较（绕过档下这些写法能打开同一个文件）。
        func comparable(_ path: String) -> String {
            path.hasPrefix("/")
                ? BypassPathNormalizer.strip(path).folded
                : PolicyRuntimePathBoundary.foldedForPathComparison(path)
        }
        var folded = comparable(pattern)
        while folded.count > 1, folded.hasSuffix("/") { folded.removeLast() }
        for candidate in candidates {
            var path = comparable(candidate)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if !isGlob(folded) {
                if path == folded || path.hasPrefix(folded + "/") { return true }
                continue
            }
            if folded.hasSuffix("/**") {
                let base = String(folded.dropLast(3))
                if !isGlob(base), path == base || path.hasPrefix(base + "/") { return true }
            }
            var variants = [folded]
            if folded.contains("/**/") { variants.append(folded.replacingOccurrences(of: "/**/", with: "/")) }
            if variants.contains(where: { fnmatch($0, path, 0) == 0 }) { return true }
        }
        return false
    }
}

// MARK: - 手动新增规则

public struct PermissionRuleDraft: Sendable, Equatable {
    public var behavior: PersistentApprovalRuleBehavior
    public var type: PermissionRuleType
    public var pattern: String
    public var scope: PersistentApprovalRuleScope

    public init(
        behavior: PersistentApprovalRuleBehavior, type: PermissionRuleType, pattern: String,
        scope: PersistentApprovalRuleScope
    ) {
        self.behavior = behavior
        self.type = type
        self.pattern = pattern
        self.scope = scope
    }
}

/// 创建规则时需要的当前会话信息（面板从会话的授权事实里取）。
public struct PermissionRuleContext: Sendable {
    public var trustedProjectRoot: String?
    public var allowedRoots: [String]
    public var home: String
    /// 把 MCP 工具全名解析成"服务器配置指纹 + 工具名"身份；解析不到（服务器未连接）就不能创建 MCP 允许规则。
    public var mcpIdentity: (@Sendable (String) -> MCPToolRuleIdentity?)?

    public init(
        trustedProjectRoot: String?, allowedRoots: [String], home: String = NSHomeDirectory(),
        mcpIdentity: (@Sendable (String) -> MCPToolRuleIdentity?)? = nil
    ) {
        self.trustedProjectRoot = trustedProjectRoot
        self.allowedRoots = allowedRoots
        self.home = home
        self.mcpIdentity = mcpIdentity
    }
}

public struct PermissionRuleRejection: Error, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

public enum PermissionRuleBuilder {
    /// 与 `PersistentApprovalRuleStore.ruleScope` 同一算法：主授权根在授权根内时只按主根算键。
    static func projectScope(context: PermissionRuleContext) -> (key: String, roots: [String])? {
        if let primary = context.trustedProjectRoot.flatMap(PolicyRuntimePathBoundary.canonicalPath), primary != "/",
           context.allowedRoots.compactMap(PolicyRuntimePathBoundary.canonicalPath).contains(primary) {
            return PersistentApprovalRuleMatcher.projectScope(roots: [primary], sharingOrdinaryWorkspace: true)
        }
        return PersistentApprovalRuleMatcher.projectScope(roots: context.allowedRoots, sharingOrdinaryWorkspace: true)
    }

    /// 校验并生成规则。"允许"规则沿用审批卡上的全部安全判定（不可记住的命令、敏感文件、构建配置、
    /// 宽目录、授权根外写入等），不通过就给出原因；"拒绝""询问"不会放宽任何东西，所以不受这些限制。
    public static func build(
        draft: PermissionRuleDraft, origin: PersistentApprovalRuleOrigin, context: PermissionRuleContext,
        id: String = UUID().uuidString, createdAt: Date = Date()
    ) -> Result<PersistentApprovalRule, PermissionRuleRejection> {
        let projectKey: String
        let projectRoots: [String]
        switch draft.scope {
        case .global:
            projectKey = PersistentApprovalRule.globalProjectKey
            projectRoots = []
        case .project:
            guard let scope = projectScope(context: context) else {
                return .failure(.init("当前没有项目目录，无法保存为本项目规则。请改选“全局”，或在项目会话里添加。"))
            }
            projectKey = scope.key
            projectRoots = scope.roots
        case .session:
            let scope = projectScope(context: context)
            projectKey = scope?.key ?? PersistentApprovalRule.globalProjectKey
            projectRoots = scope?.roots ?? []
        }
        let core: (kind: PersistentApprovalRuleKind, capability: String, pattern: String)
        switch buildCore(draft: draft, context: context) {
        case .success(let value): core = value
        case .failure(let rejection): return .failure(rejection)
        }
        if draft.behavior == .allow, case .global = draft.scope, core.kind == .shellCommandPrefix,
           executesProjectCode(prefix: core.pattern) {
            return .failure(.init("这类命令会执行项目里的脚本或构建配置，换一个不受信的项目也会免问。请把范围改为“本项目”或“本会话”。"))
        }
        return .success(PersistentApprovalRule(
            id: id, projectKey: projectKey, projectRoots: projectRoots, kind: core.kind,
            capability: core.capability, pattern: core.pattern, createdAt: createdAt,
            behavior: draft.behavior, origin: origin))
    }

    /// 会执行项目自带脚本、构建配置或源码的命令前缀：不能设为全局允许。
    static func executesProjectCode(prefix: String) -> Bool {
        let words = prefix.split(separator: " ").map { $0.lowercased() }
        guard let first = words.first else { return false }
        let second = words.count > 1 ? words[1] : ""
        if PersistentApprovalRuleMatcher.interpreterTools.contains(first)
            || PersistentApprovalRuleMatcher.interpreterBaseName(first) != nil { return true }
        let projectRunners: Set<String> = [
            "make", "gradle", "gradlew", "mvn", "mvnw", "just", "rake", "npx", "swiftc", "bash", "sh", "zsh",
        ]
        if projectRunners.contains(first) { return true }
        let byTool: [String: Set<String>] = [
            "npm": ["run", "run-script", "test", "t", "start", "exec", "x", "ci", "install", "i", "build", "rum"],
            "yarn": ["run", "test", "start", "exec", "dlx", "install", "build"],
            "pnpm": ["run", "test", "start", "exec", "dlx", "install", "i", "build"],
            "bun": ["run", "test", "x", "install", "build"],
            "swift": ["build", "test", "run", "package"],
            "cargo": ["run", "test", "build", "bench", "check", "clippy", "install"],
            "go": ["run", "test", "build", "generate", "vet", "install"],
            "uv": ["run", "sync", "pip"], "poetry": ["run", "install"], "bundle": ["exec", "install"],
            "dotnet": ["run", "test", "build"], "mix": ["run", "test", "compile"],
            "pip": ["install"], "pip3": ["install"], "composer": ["run", "run-script", "install"],
        ]
        if let subcommands = byTool[first] { return second.isEmpty || subcommands.contains(second) }
        return false
    }

    private static func buildCore(
        draft: PermissionRuleDraft, context: PermissionRuleContext
    ) -> Result<(kind: PersistentApprovalRuleKind, capability: String, pattern: String), PermissionRuleRejection> {
        let allow = draft.behavior == .allow
        let text = draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        switch draft.type {
        case .webSearch:
            return .success((.projectDirectory, "web_search", PersistentApprovalRuleMatcher.webSearchAlwaysPattern))
        case .shellPrefix:
            return shellCore(text: text, allow: allow)
        case .webHost:
            var host = text
            if host.lowercased().hasPrefix("domain:") { host = String(host.dropFirst(7)) }
            if host.contains("://") { host = URL(string: host)?.host ?? "" }
            guard let normalized = BrowserNavigationPolicy.normalizedHost(host) else {
                return .failure(.init("网站域名无效：不支持通配符，请写具体域名，如 example.com。"))
            }
            return .success((.webHost, "web_fetch", normalized))
        case .mcpTool:
            return mcpCore(text: text, allow: allow, context: context)
        case .readDirectory:
            return pathCore(text: text, allow: allow, write: false, context: context)
        case .writePath:
            return pathCore(text: text, allow: allow, write: true, context: context)
        }
    }

    private static func shellCore(
        text: String, allow: Bool
    ) -> Result<(kind: PersistentApprovalRuleKind, capability: String, pattern: String), PermissionRuleRejection> {
        var prefix = text
        for suffix in [":*", " *"] where prefix.hasSuffix(suffix) { prefix = String(prefix.dropLast(2)) }
        let words = prefix.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first else { return .failure(.init("请填写命令前缀，如 npm test。")) }
        if prefix.unicodeScalars.contains(where: { PersistentApprovalRuleMatcher.shellMetacharacterScalars.contains($0) })
            || prefix.contains("*") || prefix.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .failure(.init("命令前缀只能是命令名加子命令（如 git push），不能含 ; & | $ ( ) ` > < * 或换行。"))
        }
        let joined = words.joined(separator: " ")
        if allow {
            let lowered = first.lowercased()
            if PersistentApprovalRuleMatcher.subcommandTools.contains(lowered), words.count == 1 {
                return .failure(.init("请写到子命令，如 \(first) status；只写 \(first) 不能设为允许。"))
            }
            let result = PersistentApprovalRuleMatcher.shellRulePattern(words: words)
            guard let pattern = result.pattern, pattern == joined else {
                return .failure(.init(result.reason ?? "该命令前缀不能设为允许，每次都需询问。"))
            }
        }
        return .success((.shellCommandPrefix, "shell_execute", joined))
    }

    private static func mcpCore(
        text: String, allow: Bool, context: PermissionRuleContext
    ) -> Result<(kind: PersistentApprovalRuleKind, capability: String, pattern: String), PermissionRuleRejection> {
        guard let name = normalizedMCPName(text) else {
            return .failure(.init("MCP 工具名无法识别。请写 mcp__服务器__工具，或 mcp__服务器 表示该服务器的全部工具。"))
        }
        if !allow { return .success((.mcpTool, name, name)) }
        guard !name.hasSuffix("_") else {
            return .failure(.init("允许规则只能针对具体的一个 MCP 工具，不能写整个服务器。"))
        }
        guard let identity = context.mcpIdentity?(name) else {
            return .failure(.init("这个 MCP 工具当前没有连接或未授权，无法按服务器配置指纹创建允许规则。请先连接服务器，或在审批卡上选“以后都允许”。"))
        }
        return .success((.mcpTool, identity.fullName, identity.rulePattern))
    }

    /// `mcp__服务器__工具`（Claude Code 写法）或 `mcp_服务器_工具`（本应用工具名）→ 本应用工具全名；
    /// 整个服务器（`mcp__服务器`、`mcp__服务器__*`）→ 以下划线结尾的前缀。
    static func normalizedMCPName(_ raw: String) -> String? {
        guard raw.hasPrefix("mcp_") else { return nil }
        if raw.hasPrefix("mcp__") {
            var parts = raw.dropFirst(5).components(separatedBy: "__")
            guard let server = parts.first, !server.isEmpty else { return nil }
            parts.removeFirst()
            let tool = parts.joined(separator: "__")
            if tool.isEmpty || tool == "*" {
                let probe = MCPBoundTool.makeFullName(serverID: server, toolName: "t")
                guard probe.hasSuffix("_t") else { return nil }
                return String(probe.dropLast(1))
            }
            return MCPBoundTool.makeFullName(serverID: server, toolName: tool)
        }
        if raw.hasSuffix("*") {
            let prefix = String(raw.dropLast(1))
            return prefix.hasSuffix("_") && prefix.count > 4 ? prefix : nil
        }
        return raw
    }

    private static func pathCore(
        text: String, allow: Bool, write: Bool, context: PermissionRuleContext
    ) -> Result<(kind: PersistentApprovalRuleKind, capability: String, pattern: String), PermissionRuleRejection> {
        let capability = write ? "file_write" : "file_read"
        var path = text
        if path == "~" { path = context.home } else if path.hasPrefix("~/") { path = context.home + String(path.dropFirst(1)) }
        if !path.hasPrefix("/"), let root = context.trustedProjectRoot ?? context.allowedRoots.first, !path.isEmpty {
            path = (root as NSString).appendingPathComponent(path.hasPrefix("./") ? String(path.dropFirst(2)) : path)
        }
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\0") else {
            return .failure(.init("请填写绝对路径（可用 ~ 开头），或相对当前项目的路径。"))
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if !allow {
            if PermissionRuleMatching.isGlob(path) { return .success((.projectDirectory, capability, path)) }
            return .success((.projectDirectory, capability, PolicyRuntimePathBoundary.canonicalPath(path) ?? path))
        }
        if PermissionRuleMatching.isGlob(path) {
            return .failure(.init("允许规则只支持具体的目录或文件，不支持通配符。"))
        }
        guard let canonical = PolicyRuntimePathBoundary.canonicalPath(path) else {
            return .failure(.init("路径无效，无法保存。"))
        }
        if write {
            guard !context.allowedRoots.isEmpty else {
                return .failure(.init("当前会话没有授权根目录，无法创建写入允许规则。"))
            }
            for probe in [canonical, canonical + "/x"] {
                if case .unavailable(let reason) = PersistentApprovalRuleMatcher.evaluateFile(
                    capability: "file_write", input: ["path": probe], roots: context.allowedRoots, home: context.home) {
                    return .failure(.init(reason))
                }
            }
            return .success((.projectDirectory, capability, canonical))
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), !isDirectory.boolValue {
            return .failure(.init("读取允许规则针对目录，请填写文件所在的目录。"))
        }
        switch PersistentApprovalRuleMatcher.evaluateFileRead(input: ["path": canonical + "/x"], home: context.home) {
        case .pattern(let directory): return .success((.projectDirectory, capability, directory))
        case .unavailable(let reason): return .failure(.init(reason))
        }
    }
}

// MARK: - 从 Claude Code 设置文件导入

public struct ImportedPermissionCandidate: Identifiable, Sendable, Equatable {
    public let id: String
    /// 来自哪个文件（settings.json / settings.local.json）。
    public let source: String
    /// 原文，如 `Bash(npm test:*)`。
    public let original: String
    public let draft: PermissionRuleDraft
}

public struct ImportedPermissionSkip: Identifiable, Sendable, Equatable {
    public let id: String
    public let source: String
    public let original: String
    public let reason: String
}

public struct ImportedPermissionPreview: Sendable, Equatable {
    public var candidates: [ImportedPermissionCandidate] = []
    public var skipped: [ImportedPermissionSkip] = []
    /// 两个文件都不存在或没有 permissions 时的说明。
    public var note: String?
    public init() {}
}

public enum ClaudeSettingsPermissionsImporter {
    /// 读项目的 `.claude/settings.json` 与 `.claude/settings.local.json`，映射成候选规则（不写入、不生效）。
    public static func preview(projectRoot: String, context: PermissionRuleContext) -> ImportedPermissionPreview {
        var preview = ImportedPermissionPreview()
        var foundFile = false
        for name in ["settings.json", "settings.local.json"] {
            let url = URL(fileURLWithPath: projectRoot).appendingPathComponent(".claude").appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            foundFile = true
            let parsed = parse(data: data, source: name, projectRoot: projectRoot, context: context)
            preview.candidates += parsed.candidates
            preview.skipped += parsed.skipped
        }
        if !foundFile { preview.note = "项目里没有 .claude/settings.json 或 .claude/settings.local.json。" }
        else if preview.candidates.isEmpty && preview.skipped.isEmpty { preview.note = "设置文件里没有 permissions.allow / deny / ask。" }
        return preview
    }

    public static func parse(
        data: Data, source: String, projectRoot: String, context: PermissionRuleContext
    ) -> ImportedPermissionPreview {
        var result = ImportedPermissionPreview()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.skipped.append(.init(id: source + "#file", source: source, original: source, reason: "文件不是有效的 JSON。"))
            return result
        }
        guard let permissions = object["permissions"] as? [String: Any] else { return result }
        let groups: [(String, PersistentApprovalRuleBehavior)] = [("deny", .deny), ("ask", .ask), ("allow", .allow)]
        for (key, behavior) in groups {
            guard let entries = permissions[key] as? [Any] else { continue }
            for (index, raw) in entries.enumerated() {
                let id = "\(source)#\(key)#\(index)"
                guard let original = raw as? String else {
                    result.skipped.append(.init(id: id, source: source, original: "\(raw)", reason: "不是文本写法。"))
                    continue
                }
                switch map(original, behavior: behavior, projectRoot: projectRoot, home: context.home) {
                case .failure(let rejection):
                    result.skipped.append(.init(id: id, source: source, original: original, reason: rejection.reason))
                case .success(let draft):
                    // 导入前先过一遍和手动新增同一套校验：允许规则里不可记住的写法在这里就列为跳过。
                    switch PermissionRuleBuilder.build(draft: draft, origin: .imported, context: context) {
                    case .failure(let rejection):
                        result.skipped.append(.init(id: id, source: source, original: original, reason: rejection.reason))
                    case .success:
                        result.candidates.append(.init(id: id, source: source, original: original, draft: draft))
                    }
                }
            }
        }
        return result
    }

    static func map(
        _ original: String, behavior: PersistentApprovalRuleBehavior, projectRoot: String, home: String
    ) -> Result<PermissionRuleDraft, PermissionRuleRejection> {
        var tool = original.trimmingCharacters(in: .whitespacesAndNewlines)
        var argument: String?
        if let open = tool.firstIndex(of: "("), tool.hasSuffix(")") {
            argument = String(tool[tool.index(after: open)..<tool.index(before: tool.endIndex)])
            tool = String(tool[..<open])
        }
        func draft(_ type: PermissionRuleType, _ pattern: String) -> Result<PermissionRuleDraft, PermissionRuleRejection> {
            .success(PermissionRuleDraft(behavior: behavior, type: type, pattern: pattern, scope: .project))
        }
        switch tool {
        case "Bash":
            guard var command = argument?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
                return .failure(.init("不带内容的 Bash 表示全部命令，无法映射。"))
            }
            for suffix in [":*", " *"] where command.hasSuffix(suffix) { command = String(command.dropLast(2)) }
            guard !command.contains("*") else { return .failure(.init("命令中间含通配符，无法映射为命令前缀。")) }
            return draft(.shellPrefix, command)
        case "Read":
            return pathDraft(argument, type: .readDirectory, behavior: behavior, projectRoot: projectRoot, home: home)
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return pathDraft(argument, type: .writePath, behavior: behavior, projectRoot: projectRoot, home: home)
        case "WebFetch":
            guard let argument, argument.hasPrefix("domain:") else {
                return .failure(.init("只支持 WebFetch(domain:域名) 的写法。"))
            }
            return draft(.webHost, String(argument.dropFirst(7)))
        case "WebSearch":
            return draft(.webSearch, "")
        default:
            if tool.hasPrefix("mcp__"), argument == nil { return draft(.mcpTool, tool) }
            return .failure(.init("无法映射的写法（\(tool.isEmpty ? original : tool)）。"))
        }
    }

    private static func pathDraft(
        _ argument: String?, type: PermissionRuleType, behavior: PersistentApprovalRuleBehavior,
        projectRoot: String, home: String
    ) -> Result<PermissionRuleDraft, PermissionRuleRejection> {
        guard var path = argument?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            return .failure(.init("缺少路径，无法映射。"))
        }
        // Claude Code 路径写法：//开头是绝对路径，~/ 是主目录，/ 开头相对项目根，其余相对项目根。
        if path.hasPrefix("//") { path = String(path.dropFirst(1)) }
        else if path == "~" { path = home }
        else if path.hasPrefix("~/") { path = home + String(path.dropFirst(1)) }
        else if path.hasPrefix("/") { path = (projectRoot as NSString).appendingPathComponent(String(path.dropFirst(1))) }
        else if path.hasPrefix("./") { path = (projectRoot as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        else { path = (projectRoot as NSString).appendingPathComponent(path) }
        if behavior == .allow {
            // 允许规则只认目录：`目录/**`、`目录/*` 去掉尾部通配符。
            for suffix in ["/**", "/*"] where path.hasSuffix(suffix) { path = String(path.dropLast(suffix.count)); break }
        }
        return .success(PermissionRuleDraft(behavior: behavior, type: type, pattern: path, scope: .project))
    }
}
