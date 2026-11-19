import Foundation

/// 统一的 shell 效果检查器。
///
/// 规则（"以后都允许"、本对话内都允许）、计划模式的只读命令、自动档的免问命令，
/// 都只能替代"弹卡"这一步，不能替代对这条具体命令的效果检查：命令的每个子命令都要
/// 重新过一遍下面几项，任一项不过就退回正常弹卡（这次的卡也不再提供"以后都允许"）。
///
/// 1. 路径包含：判为路径的操作数（含 `/`、以 `~` 或 `.` 开头、含 `..`、含通配符、
///    `--opt=值` 与 `-ofile` 里的值、相对 cwd 能 stat 到的词）全部规范化（解析符号链接），
///    必须落在授权根内；通配符先展开再逐个检查。
/// 2. 敏感与底线：敏感文件、凭据路径、应用自身数据、受保护状态；写类命令再加 git 控制文件、
///    构建配置、shell 启动文件等位置。
/// 3. 授权根覆盖家目录或 `/` 时，shell 规则不可用。
/// 4. 规则模式下 cwd 可以不同于会话默认目录，但要在授权根内且不落在 .git、构建配置、敏感或应用数据位置；
///    开头的 `cd <目录> &&` 同样检查，后面的命令以该目录为基准。
/// 5. 首词不能是 zsh 保留字或修饰符，也不能是路径调用或变量赋值。
/// 6. 参数形态：find 的 -exec/-delete/-fprint、sort -o、uniq 的输出文件、git --no-index 等。
///
/// 它不是沙箱：脚本文件里写什么、构建命令执行什么，文本检查看不到。
/// shell_execute 的 cwd 参数。有的模型（如 ChatGPT 账号的 gpt-6.1）会把可选参数全部填上，
/// 没有目录时给空字符串；空字符串按"没给"处理，沿用会话默认目录，和不传一致。
enum ShellToolInput {
    static func explicitWorkingDirectory(_ input: [String: Any]) -> Any? {
        guard let value = input["cwd"] else { return nil }
        if let text = value as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return value
    }
}

enum ShellEffectGuard {
    enum Mode: Sendable, Equatable {
        /// 持久规则或"本对话内都允许"命中后：任何命令都可以，但每个子命令都要过检查。
        case rule
        /// 计划模式、自动档对只读命令免问：每个子命令都必须是只读命令。
        case readOnly
        /// 自动档：只读命令，以及项目内的构建、测试命令。
        case auto
    }

    struct Context: Sendable, Equatable {
        /// 会话的授权根（`allowedWriteRoots`）。
        var roots: [String]
        /// 会话默认工作目录；nil 时用第一个授权根。
        var baseDirectory: String?
        var home: String = NSHomeDirectory()
        /// 规则模式：命令带 cwd 时必须等于默认目录。
        var requireDefaultCWD: Bool = false
    }

    /// `fileOp`：mkdir、touch、mv、cp（自动档免问；所有路径操作数照样过路径与排除位置检查）。
    private enum CommandClass { case readOnly, buildTest, fileOp, other }

    private static let fileOperationExecutables: Set<String> = ["mkdir", "touch", "mv", "cp"]

    /// 只读命令的白名单（逐命令再叠加参数形态检查）。比终端策略的自动放行表更窄：
    /// 没有 cd、xargs、history、clear、help。
    private static let readOnlyExecutables: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "grep", "find", "tree", "which", "du", "df",
        "stat", "file", "basename", "dirname", "uname", "sw_vers", "whoami", "date", "echo",
        "cut", "tr", "sort", "uniq", "man", "type",
        // 查看二进制与文件类型的命令（xxd -r 会写文件，在 rejectedArgumentShape 里排除）。
        "od", "hexdump", "xxd", "strings",
    ]

    /// 只处理字符串、不读操作数指向的文件的命令：操作数不做路径检查。
    private static let stringOnlyExecutables: Set<String> = [
        "echo", "basename", "dirname", "date", "uname", "whoami", "sw_vers", "pwd", "which", "type",
    ]

    /// 项目内的构建、测试命令前缀（参数另外按构建工具规则检查）。
    private static let buildTestPrefixes: Set<String> = [
        "swift build", "swift test", "npm test", "npm run build", "npm run test",
        "pnpm test", "pnpm run build", "pnpm run test", "yarn test", "yarn run build", "yarn run test",
        "make test", "cargo build", "cargo test", "cargo check", "go build", "go test", "go vet",
        "pytest",
    ]

    private static let executableScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")

    // MARK: Entry points

    /// nil 表示通过；否则是给用户看的原因（中文，写明下一步是"每次都需询问"）。
    static func violation(input: [String: Any], context: Context, mode: Mode) -> String? {
        guard let command = input["command"] as? String else { return "命令缺失" }
        return violation(command: command, cwd: ShellToolInput.explicitWorkingDirectory(input), context: context, mode: mode)
    }

    static func violation(command: String, cwd rawCwd: Any?, context originalContext: Context, mode: Mode) -> String? {
        // 子任务：效果检查用子任务自己的根（写类命令用写根，只读命令用读根），不用父会话的根。
        var context = originalContext
        var readContext = originalContext
        if let scope = ChildToolWorkspaceScope.current {
            context.roots = scope.writeRoots
            readContext.roots = scope.readRoots
        }
        // 不可逆操作（git reset --hard、clean -f、push -f、checkout -- .、restore、stash drop/clear、rm -rf 等）
        // 规则和免问都不能放行：退回带二次确认的卡。
        if BypassSystemFloor.requiresIrreversibleDeletionApproval(command: command) {
            return "命令含不可逆操作（删除、强制推送、丢弃改动等），每次都需二次确认"
        }
        // 3. 授权根覆盖家目录或 `/`。
        let canonicalRoots = context.roots.compactMap(PolicyRuntimePathBoundary.canonicalPath)
        guard !canonicalRoots.isEmpty else { return "当前没有会话授权根，每次都需询问" }
        let homePath = PolicyRuntimePathBoundary.canonicalPath(context.home) ?? context.home
        if canonicalRoots.contains(where: { $0 == "/" || $0 == homePath || homePath.hasPrefix($0 + "/") }) {
            return "会话授权根覆盖主目录或根目录，范围过大，每次都需询问"
        }
        // 命令文本里直接出现应用状态文件、应用数据目录或钥匙串。
        if SensitiveFilePolicy.protectedStateShellViolation(command: command) != nil
            || BypassAppDataFloor.shellMentionViolation(command: command) != nil
            || BypassSystemFloor.keychainCommandViolation(command: command) != nil {
            return "命令涉及 MinisCanvas 自身数据、受保护状态或钥匙串，每次都需询问"
        }
        // 4. 工作目录。
        var base: String
        if let rawCwd {
            guard let text = rawCwd as? String, text.hasPrefix("/"),
                  let canonical = PolicyRuntimePathBoundary.canonicalPath(text) else {
                return "工作目录无效，每次都需询问"
            }
            // 规则模式：工作目录不必等于会话默认目录，但必须在授权根内，且不能落在
            // .git、构建配置、敏感文件或应用自身数据所在的位置（与写类命令的路径检查同一套）。
            if context.requireDefaultCWD {
                let expected = context.baseDirectory.flatMap(PolicyRuntimePathBoundary.canonicalPath)
                if expected != canonical {
                    let roots = context.roots.compactMap(PolicyRuntimePathBoundary.canonicalPath)
                    if let reason = pathViolation(
                        value: canonical, base: canonical, write: true, canonicalRoots: roots, context: context) {
                        return reason
                    }
                }
            }
            base = canonical
        } else if let directory = context.baseDirectory.flatMap(PolicyRuntimePathBoundary.canonicalPath) {
            base = directory
        } else if let first = canonicalRoots.first {
            base = first
        } else {
            return "没有可用的工作目录，每次都需询问"
        }
        guard PolicyRuntimePathBoundary.isWithinRoots(path: base, roots: context.roots) else {
            return "工作目录不在会话授权根内，每次都需询问"
        }
        // 逐子命令检查。
        let analyzed = PersistentApprovalRuleMatcher.shellCommandAnalysis(command: command)
        if let reason = analyzed.reason { return reason }
        // 开头的 `cd <目录> &&`：目录必须是已存在的目录，在写入根内且不落在排除位置（与写类命令同一套检查），
        // 后面的命令以它为基准目录检查。
        if let directory = analyzed.leadingDirectory {
            guard !hasGlob(directory), directory != "-" else { return "cd 的目录含通配符，每次都需询问" }
            if let reason = pathViolation(
                value: directory, base: base, write: true, canonicalRoots: canonicalRoots, context: context) {
                return reason
            }
            let resolved = resolve(directory, base: base, home: context.home)
            guard let target = resolved.paths?.first,
                  let canonicalTarget = PolicyRuntimePathBoundary.canonicalPath(target) else {
                return resolved.reason ?? "cd 的目录无法解析，每次都需询问"
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonicalTarget, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return "cd 的目录不存在，每次都需询问"
            }
            base = canonicalTarget
        }
        for words in analyzed.words {
            if let reason = segmentViolation(
                words: words, base: base, writeContext: context, readContext: readContext, mode: mode) {
                return reason
            }
        }
        return nil
    }

    // MARK: One sub-command

    private static func segmentViolation(
        words: [String], base: String, writeContext: Context, readContext: Context, mode: Mode
    ) -> String? {
        guard let first = words.first else { return "命令为空" }
        // 5. 首词。
        if PersistentApprovalRuleMatcher.shellReservedFirstWords.contains(first)
            || first.hasPrefix("-") || first.hasPrefix("=") {
            return "命令以 shell 保留字或修饰符开头，每次都需询问"
        }
        guard !first.contains("/"), first.unicodeScalars.allSatisfy({ executableScalars.contains($0) }) else {
            return "以路径方式或变量赋值调用的命令，每次都需询问"
        }
        let kind = classify(words)
        switch mode {
        case .readOnly:
            guard kind == .readOnly else { return "该命令不是只读命令，每次都需询问" }
        case .auto:
            guard kind != .other else {
                return "该命令不是只读命令，也不是项目内的构建、测试或新建、移动、复制文件的命令，每次都需询问"
            }
        case .rule:
            break
        }
        // 6. 参数形态。
        if let reason = PersistentApprovalRuleMatcher.rejectedArgumentShape(words: words) { return reason }
        if let reason = recursiveReadViolation(words: words, mode: mode) { return reason }
        if first == "git" {
            if let reason = gitNetworkViolation(words: words, base: base) { return reason }
            if let reason = gitSensitiveReadViolation(words: words, base: base, home: writeContext.home) { return reason }
        }
        if stringOnlyExecutables.contains(first) { return nil }
        // 1、2. 路径操作数。
        let write = kind != .readOnly
        let context = write ? writeContext : readContext
        let canonicalRoots = context.roots.compactMap(PolicyRuntimePathBoundary.canonicalPath)
        // 写类命令（mkdir、touch、mv、cp 和其它非只读命令）：所有非旗标操作数一律按路径名检查，
        // 不依赖文件是否已经存在（`touch Makefile` 在 Makefile 还不存在时也要被识别为构建配置）。
        let everyOperandIsPath = kind == .fileOp || kind == .other
        for argument in words.dropFirst() {
            for value in candidateValues(argument)
            where looksLikePath(value, base: base)
                || (everyOperandIsPath && !value.isEmpty && !value.contains("://")
                    && value.count <= 255 && !value.contains(where: \.isNewline)) {
                if let reason = pathViolation(
                    value: value, base: base, write: write, canonicalRoots: canonicalRoots, context: context) {
                    return reason
                }
            }
        }
        return nil
    }

    private static func classify(_ words: [String]) -> CommandClass {
        guard let first = words.first else { return .other }
        let arguments = Array(words.dropFirst())
        if first == "git" || first == "gh" {
            return GitWorkflowPolicy.automaticallyAllows(words: words) ? .readOnly : .other
        }
        if readOnlyExecutables.contains(first) {
            if first == "date" {
                return arguments.allSatisfy({ $0.hasPrefix("+") || $0 == "-u" || $0 == "-R" }) ? .readOnly : .other
            }
            return .readOnly
        }
        if fileOperationExecutables.contains(first) {
            // cp 的 -L、-H、--dereference 会把符号链接指向的内容复制进来，不免问。
            let followsLinks = arguments.contains { argument in
                if argument.hasPrefix("--") { return "--dereference".hasPrefix(argument.split(separator: "=").first.map(String.init) ?? argument) && argument.count >= 4 }
                return argument.hasPrefix("-") && argument.dropFirst().contains { $0 == "L" || $0 == "H" }
            }
            return followsLinks ? .other : .fileOp
        }
        for length in [3, 2, 1] where words.count >= length {
            let prefix = words.prefix(length).joined(separator: " ")
            if buildTestPrefixes.contains(prefix) {
                let rest = Array(words.dropFirst(length))
                return rest.allSatisfy(PersistentApprovalRuleMatcher.isSafeBuildToolArgument) ? .buildTest : .other
            }
        }
        return .other
    }

    // MARK: git 联网、递归读取、敏感读取

    private static let gitNetworkSubcommands: Set<String> = ["push", "pull", "fetch", "clone"]

    /// `git [全局选项] <子命令> ...`：第一个不以 `-` 开头的词（全局选项的值已被参数形态检查拒绝）。
    private static func gitSubcommand(_ words: [String]) -> (name: String, index: Int)? {
        var index = 1
        while index < words.count, words[index].hasPrefix("-") { index += 1 }
        return index < words.count ? (words[index], index) : nil
    }

    /// 网址、`user@host:path`、`host:path`、`ext::命令` 这类远端地址写法。
    /// `:分支`（删除远端分支）和 `refs/heads/a:refs/heads/b`（冒号前有 `/`）不是地址。
    private static func looksLikeRemoteAddress(_ value: String) -> Bool {
        if value.contains("://") { return true }
        guard let colon = value.firstIndex(of: ":") else { return false }
        let head = String(value[..<colon])
        return !head.isEmpty && !head.contains("/")
    }

    /// push、pull、fetch、clone 不能把内容送到（或从）任意地址：位置参数里出现网址或 host:path 就不通过；
    /// push 的目标只认当前仓库里已配置的远端名。
    private static func gitNetworkViolation(words: [String], base: String) -> String? {
        guard let sub = gitSubcommand(words), gitNetworkSubcommands.contains(sub.name) else { return nil }
        let reason = "git 联网命令的目标不是已配置的远端（网址或 host:path 写法），每次都需询问"
        var positionals: [String] = []
        for argument in words[(sub.index + 1)...] {
            if argument.contains("://") { return reason }
            if argument.hasPrefix("-") {
                if let equals = argument.firstIndex(of: "=") {
                    let value = String(argument[argument.index(after: equals)...])
                    if looksLikeRemoteAddress(value) { return reason }
                }
                continue
            }
            positionals.append(argument)
        }
        if let target = positionals.first {
            if looksLikeRemoteAddress(target) { return reason }
            if sub.name == "push", !configuredRemotes(base: base).contains(target) { return reason }
        }
        return nil
    }

    /// 从 `base` 向上找到仓库，读 `.git/config`（含 worktree 的 gitdir、commondir）里的 `[remote "名"]`。
    private static func configuredRemotes(base: String) -> Set<String> {
        let manager = FileManager.default
        var directory = base
        for _ in 0..<64 {
            let git = directory + "/.git"
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: git, isDirectory: &isDirectory) {
                var configDirectories: [String] = []
                if isDirectory.boolValue {
                    configDirectories = [git]
                } else if let text = try? String(contentsOfFile: git, encoding: .utf8),
                          let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) {
                    var path = String(line.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
                    if !path.hasPrefix("/") { path = directory + "/" + path }
                    configDirectories = [path]
                    if let common = try? String(contentsOfFile: path + "/commondir", encoding: .utf8) {
                        let trimmed = common.trimmingCharacters(in: .whitespacesAndNewlines)
                        configDirectories.append(trimmed.hasPrefix("/") ? trimmed : path + "/" + trimmed)
                    }
                }
                var names = Set<String>()
                for configDirectory in configDirectories {
                    guard let text = try? String(contentsOfFile: configDirectory + "/config", encoding: .utf8) else { continue }
                    for line in text.split(whereSeparator: \.isNewline) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("[remote \""), trimmed.hasSuffix("\"]") else { continue }
                        names.insert(String(trimmed.dropFirst("[remote \"".count).dropLast(2)))
                    }
                }
                return names
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory || parent.isEmpty { break }
            directory = parent
        }
        return []
    }

    /// 只读模式和自动档：grep、rg、ag 的递归读取会读出目录里的密钥文件，改用会跳过敏感文件的 file_grep。
    private static func recursiveReadViolation(words: [String], mode: Mode) -> String? {
        guard mode != .rule, let first = words.first, ["grep", "egrep", "fgrep", "rg", "ag", "ack"].contains(first) else {
            return nil
        }
        let reason = "递归读取目录可能读出密钥文件，请改用会跳过敏感文件的 file_grep，每次都需询问"
        // rg、ag、ack 默认就递归搜索目录，不需要 -r。
        if ["rg", "ag", "ack"].contains(first) { return reason }
        let arguments = Array(words.dropFirst())
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" { break }
            if argument.hasPrefix("--") {
                let name = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map(String.init) ?? argument
                if name.count >= 4, "--recursive".hasPrefix(name) || "--dereference-recursive".hasPrefix(name) {
                    return reason
                }
                if name.count >= 4, "--directories".hasPrefix(name) {
                    if let equals = argument.firstIndex(of: "=") {
                        if argument[argument.index(after: equals)...] == "recurse" { return reason }
                    } else if index < arguments.count, arguments[index] == "recurse" {
                        return reason
                    }
                }
                continue
            }
            guard argument.hasPrefix("-"), argument.count > 1 else { continue }
            let letters = argument.dropFirst()
            if letters.contains("r") || letters.contains("R") { return reason }
            if letters.hasPrefix("d") {
                if letters == "d" {
                    if index < arguments.count, arguments[index] == "recurse" { return reason }
                } else if letters.dropFirst() == "recurse" {
                    return reason
                }
            }
        }
        return nil
    }

    /// 只看 git 子命令里"会读出敏感文件内容"这一类问题，给免问放行之前补查用
    /// （`GitWorkflowPolicy` 把只读 git 判为低风险免问，不会再走完整的效果检查）。
    /// 命令里没有 git、或解析不了时返回 nil；其余检查仍由调用方原有路径负责。
    static func gitSensitiveReadViolation(
        command: String, workingDirectory: String?, home: String = NSHomeDirectory()
    ) -> String? {
        let analyzed = PersistentApprovalRuleMatcher.shellCommandAnalysis(command: command)
        guard analyzed.reason == nil else { return nil }
        let base = workingDirectory.flatMap(PolicyRuntimePathBoundary.canonicalPath)
            ?? FileManager.default.currentDirectoryPath
        for words in analyzed.words where words.first == "git" {
            if let reason = gitSensitiveReadViolation(words: words, base: base, home: home) { return reason }
        }
        return nil
    }

    /// git 只读命令也能读出敏感文件：`REV:路径` 指向敏感文件；log、show、diff 带 -p 输出补丁时，
    /// 不限路径或路径涉及敏感文件。
    private static func gitSensitiveReadViolation(words: [String], base: String, home: String) -> String? {
        guard let sub = gitSubcommand(words) else { return nil }
        let arguments = Array(words[(sub.index + 1)...])
        let reason = "git 命令会读出敏感文件的内容，每次都需询问"
        func isSensitive(_ path: String) -> Bool {
            let trimmed = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            let absolute = "/" + trimmed
            return SensitiveFilePolicy.contains(absolute)
                || SensitiveFilePolicy.isCredentialPath(absolute, home: home)
        }
        let separator = arguments.firstIndex(of: "--")
        let beforeSeparator = separator.map { Array(arguments[..<$0]) } ?? arguments
        for argument in beforeSeparator where !argument.hasPrefix("-") {
            guard let colon = argument.firstIndex(of: ":") else { continue }
            let path = String(argument[argument.index(after: colon)...])
            if !path.isEmpty, isSensitive(path) { return reason }
        }
        let explicitPatch = arguments.contains {
            $0 == "-p" || $0 == "-u" || $0 == "-c" || $0 == "--cc" || $0.hasPrefix("--patch")
        }
        let suppressesPatch = arguments.contains {
            ["--stat", "--name-only", "--name-status", "--shortstat", "--numstat", "--summary", "--no-patch", "-s"]
                .contains($0) || $0.hasPrefix("--stat=")
        }
        // show、diff、format-patch 默认就输出补丁；log、stash show 要显式要求才输出。
        let patchByDefault = ["show", "diff", "format-patch"].contains(sub.name) && !suppressesPatch
        let stashShow = sub.name == "stash" && arguments.first == "show"
        let mayPrintPatch = (explicitPatch && (["log", "show", "diff", "format-patch"].contains(sub.name) || stashShow))
            || patchByDefault
        if mayPrintPatch {
            // 路径限定只认 `--` 后面具体的、不敏感的文件；`.`、目录、通配符、路径魔法都不算限定。
            guard let separator, separator + 1 < arguments.count else {
                return "git \(sub.name) 可能输出补丁且不限定具体文件，可能读出敏感文件的改动，每次都需询问"
            }
            for path in arguments[(separator + 1)...] {
                let clean = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
                let isDirectory = (try? URL(fileURLWithPath: base).appendingPathComponent(clean)
                    .resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isSensitive(path) { return reason }
                if clean.isEmpty || clean == "." || clean.hasSuffix("/") || clean.hasPrefix(":")
                    || clean.contains("..") || hasGlob(clean) || isDirectory {
                    return "git \(sub.name) 可能输出补丁且路径不是具体文件，可能读出敏感文件的改动，每次都需询问"
                }
            }
        }
        return nil
    }

    /// 绕过档的 shell：不经弹卡直接执行之前，复用路径分析——任一操作数（含重定向目标、`--opt=值`、通配符展开）
    /// 命中敏感判据（`.env`、密钥文件、凭据目录等）就返回原因，调用方改为弹卡。尽力匹配，不是安全边界。
    static func sensitiveOperandViolation(
        command: String, workingDirectory: String?, home: String = NSHomeDirectory()
    ) -> String? {
        let base = workingDirectory.flatMap(PolicyRuntimePathBoundary.canonicalPath)
            ?? FileManager.default.currentDirectoryPath
        for operand in BypassSystemFloor.shellOperands(command: command) {
            // 密钥文件按名字判定，不要求文件已存在（`cat server.pem` 在当前目录没有该文件时也要拦）。
            for value in candidateValues(operand) where !value.isEmpty && !value.contains("://") {
                var raw = value
                for token in ["${HOME}", "$HOME"] where raw.hasPrefix(token) {
                    raw = "~" + String(raw.dropFirst(token.count))
                    break
                }
                let candidates = resolve(raw, base: base, home: home).paths ?? [raw]
                for path in candidates {
                    let canonical = PolicyRuntimePathBoundary.canonicalPath(path) ?? path
                    if SensitiveFilePolicy.contains(path) || SensitiveFilePolicy.contains(canonical)
                        || SensitiveFilePolicy.isCredentialPath(path, home: home)
                        || SensitiveFilePolicy.isCredentialPath(canonical, home: home) {
                        return "命令涉及密钥或凭据类文件（\(path)），需要你确认"
                    }
                }
            }
        }
        return nil
    }

    // MARK: Path operands

    /// 一个参数里可能藏着路径的几个位置：词本身、`--opt=值`、`-ofile`、`-o=值`。
    private static func candidateValues(_ argument: String) -> [String] {
        if argument.hasPrefix("--") {
            guard let equals = argument.firstIndex(of: "=") else { return [] }
            return [String(argument[argument.index(after: equals)...])]
        }
        if argument.hasPrefix("-"), argument.count > 1 {
            var values: [String] = []
            if let equals = argument.firstIndex(of: "=") {
                values.append(String(argument[argument.index(after: equals)...]))
            }
            let tail = String(argument.dropFirst(2))
            if !tail.isEmpty { values.append(tail) }
            return values
        }
        return [argument]
    }

    private static func hasGlob(_ value: String) -> Bool {
        value.unicodeScalars.contains { "*?[{".unicodeScalars.contains($0) }
    }

    private static func looksLikePath(_ value: String, base: String) -> Bool {
        if value.isEmpty { return false }
        // 网址（含 `://`）不是路径：不能当作项目内的相对路径放行；联网命令的网址另由 gitNetworkViolation 拒绝。
        if value.contains("://") { return false }
        if value.contains("/") || value.hasPrefix("~") || value.hasPrefix(".") || hasGlob(value) { return true }
        return FileManager.default.fileExists(atPath: base + "/" + value)
    }

    private static func pathViolation(
        value: String, base: String, write: Bool, canonicalRoots: [String], context: Context
    ) -> String? {
        let resolved = resolve(value, base: base, home: context.home)
        guard let candidates = resolved.paths else { return resolved.reason }
        let homePath = PolicyRuntimePathBoundary.canonicalPath(context.home) ?? context.home
        for path in candidates {
            guard let canonical = PolicyRuntimePathBoundary.canonicalPath(path) else {
                return "命令里有无法解析的路径，每次都需询问"
            }
            guard PolicyRuntimePathBoundary.isWithinRoots(path: path, roots: context.roots) else {
                return "命令涉及授权目录以外的路径，每次都需询问"
            }
            if SensitiveFilePolicy.contains(path) || SensitiveFilePolicy.contains(canonical)
                || SensitiveFilePolicy.isCredentialPath(path, home: context.home)
                || SensitiveFilePolicy.isCredentialPath(canonical, home: context.home)
                || SensitiveFilePolicy.isProtectedStatePath(canonical)
                || BypassAppDataFloor.violation(
                    path: canonical, access: write ? .modify : .read, home: context.home) != nil {
                return "命令涉及敏感文件或应用自身数据，每次都需询问"
            }
            guard write else { continue }
            if SensitiveFilePolicy.isProtectedGitWritePath(path)
                || SensitiveFilePolicy.isProtectedGitWritePath(canonical) {
                return "命令会改写 Git 控制文件，每次都需询问"
            }
            let rootCandidates = context.roots + canonicalRoots
            let excluded = [context.home, homePath].contains { home in
                PersistentApprovalRuleMatcher.isExcludedLocation(path, relativeTo: rootCandidates, home: home)
                    || PersistentApprovalRuleMatcher.isExcludedLocation(canonical, relativeTo: rootCandidates, home: home)
            }
            if excluded {
                return "命令会改写 .git、.claude、IDE 配置、shell 启动文件，或会被构建命令执行的构建配置和脚本目录，这些位置每次都需询问"
            }
        }
        return nil
    }

    /// 把一个操作数变成待检查的绝对路径（通配符展开成真实匹配）。
    private static func resolve(_ value: String, base: String, home: String) -> (paths: [String]?, reason: String?) {
        var raw = value
        if raw.contains("://") { return (nil, "命令里的网址不能当作项目内的路径，每次都需询问") }
        if raw == "~" {
            raw = home
        } else if raw.hasPrefix("~/") {
            raw = home + String(raw.dropFirst())
        } else if raw.hasPrefix("~") {
            return (nil, "命令含 ~用户 形式的路径，每次都需询问")
        }
        if !raw.hasPrefix("/") { raw = base + "/" + raw }
        let components = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.contains("..") { return (nil, "命令含 .. 路径，每次都需询问") }
        let normalized = "/" + components.filter { $0 != "." }.joined(separator: "/")
        guard hasGlob(normalized) else { return ([normalized], nil) }
        // zsh 的 `**/` 递归匹配、`(#…)` 限定符与这里的展开不一致，无法保证检查到全部命中项。
        if normalized.contains("**") || normalized.contains("(") {
            return (nil, "命令含递归通配符或通配限定符，每次都需询问")
        }
        guard let expanded = expandGlob(normalized) else {
            return (nil, "命令里的通配符匹配范围太大或无法展开，每次都需询问")
        }
        return (expanded, nil)
    }

    /// 与 shell 一致的展开：大括号和通配符，没有匹配就保留原样；匹配太多按失败处理。
    private static func expandGlob(_ pattern: String) -> [String]? {
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(pattern, GLOB_BRACE | GLOB_NOCHECK, nil, &matches) == 0 else { return nil }
        let count = Int(matches.gl_pathc)
        guard count <= 2000, let vector = matches.gl_pathv else { return count == 0 ? [pattern] : nil }
        var result: [String] = []
        for index in 0..<count {
            if let item = vector[index] { result.append(String(cString: item)) }
        }
        return result.isEmpty ? [pattern] : result
    }
}
