import Foundation

/// 绕过模式「全面放开」（用户 2026-10-22 决定）的 Core 侧支撑。
///
/// 仅当 Composer 快照为 `.bypassPermission` 且 `bypassModeConfirmed == true`
/// 时，`ComposerPolicyEnforcedToolExecutor` 才会在真正执行副作用的那一刻
/// 打开 `BypassOpenScope`。检查点恢复由同一 Composer 授权器验证当前单次
/// 恢复快照及确切路径后在效果期间打开；其他模式不会打开。
///
/// 打开后：
///  - 文件工具不再受项目授权根限制。仍然生效：用户自己加的 `deniedRoots`、
///    系统底线、`BypassAppDataFloor`（MinisCanvas 自身数据/设置目录与钥匙串）、
///    凭据保护。默认的「整个 Application Support 拒绝」在绕过下不再整体生效；
///  - `shell_execute` 不再受终端策略的「未登记命令拒绝 / 硬拒绝表」限制，
///    只保留 `BypassSystemFloor.shellViolation` 的尽力匹配，以及用户自己在终端策略里
///    配置的 `userDeniedCommands`（用户 2026-10-22 决定）。
enum BypassOpenScope {
    @TaskLocal static var isActive: Bool = false
}

/// 测试接缝：替换「移入废纸篓」的实际动作，避免测试往真实废纸篓里放东西。
/// 生产代码从不设置它；默认走 `FileManager.trashItem`。
enum BypassTrashSeam {
    @TaskLocal static var mover: (@Sendable (URL) throws -> URL?)? = nil
}

/// 测试接缝：注入「用户主目录」，让 `BypassAppDataFloor` 的受保护目录落在临时 HOME 下，
/// 测试不必触碰真实的 ~/Library。生产代码从不设置它，默认 `NSHomeDirectory()`。
public enum BypassHomeSeam {
    @TaskLocal public static var homeOverride: String? = nil
    public static var home: String { homeOverride ?? NSHomeDirectory() }
}

/// 绕过底线、凭据路径保护共用的路径归一（复核必改项 1）。
///
/// 在 `PolicyRuntimePathBoundary.canonicalPath`（解析符号链接、保留缺失叶子）之后：
///  - 逐段做大小写与 Unicode 归一化折叠，得到 `folded`（只用于比较）；
///  - 剥掉开头的 `/System/Volumes/Data`（用户数据卷的 firmlink 视图，realpath 不会折回）
///    与 `/private`（`/var`、`/etc`、`/tmp` 的真实位置），使 `/System/Volumes/Data/Users/u/.ssh`
///    与 `/Users/u/.ssh`、`/private/etc/hosts` 与 `/etc/hosts` 判断结果一致。
/// 受保护目录表（家目录、MinisCore 等）也必须用同一个函数归一后再比较。
enum BypassPathNormalizer {
    struct Normalized: Sendable {
        /// 剥前缀后的规范化路径（保留大小写，用于提示信息与取路径段）。
        let real: String
        /// `real` 的折叠形式，只用于比较。
        let folded: String
        var foldedComponents: [String] {
            folded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
    }

    private static let dataVolumeComponents = ["system", "volumes", "data"]

    /// 路径 -> 归一结果（会读文件系统解析符号链接）。
    static func normalize(_ path: String) -> Normalized {
        let canonical = PolicyRuntimePathBoundary.canonicalPath(path)
            ?? URL(fileURLWithPath: path).standardizedFileURL.path
        return strip(canonical)
    }

    private final class HomeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Normalized] = [:]
        func value(for home: String) -> Normalized? {
            lock.lock(); defer { lock.unlock() }
            return entries[home]
        }
        func store(_ value: Normalized, for home: String) {
            lock.lock(); defer { lock.unlock() }
            if entries.count >= 32 { entries.removeAll() }
            entries[home] = value
        }
    }
    private static let homeCache = HomeCache()

    /// 家目录的归一结果，按 HOME 字符串缓存（file_grep 每个文件都会判断凭据路径，
    /// 家目录的 realpath 不必重复解析）。
    static func normalizeHome(_ home: String) -> Normalized {
        if let hit = homeCache.value(for: home) { return hit }
        let value = normalize(home)
        homeCache.store(value, for: home)
        return value
    }

    /// shell 大括号展开的总数上限。超过按「拒绝」处理（宁可误拒）：
    /// `{a,b}{a,b}…` 重复约 30 次会指数膨胀，不能真的去展开。
    static let braceExpansionLimit = 64
    /// 参与展开的字符串长度上限（防止超长输入让逐字符扫描变成二次方）；超过同样按超限处理。
    private static let braceInputLimit = 4096

    /// 按 bash 语义展开大括号：支持嵌套（`{a,{b,c}}`）、多组相乘（`{a,b}{c,d}`），
    /// 花括号内可含 `/`（`~/{Library/Application Support/MinisCore,x}`），因为展开发生在整段路径上，
    /// 展开之后才按路径匹配，不会先按 `/` 切开。
    /// 没有顶层逗号的 `{x}` 或没有配对的 `{` 按字面保留（bash 同样不展开）。
    /// 展开结果总数超过 `limit`（或输入过长）返回 nil，调用方必须按「拒绝」处理。
    static func expandBraces(_ input: String, limit: Int = braceExpansionLimit) -> [String]? {
        // 按 Unicode 标量而不是 Character 扫描：`{`、`,`、`}` 后紧跟组合符（如 U+0301）时
        // Character 会把它们合成一个字素簇而不再等于 "{" / "," / "}"，导致不展开；bash 按字节展开。
        let scalars = Array(input.unicodeScalars)
        guard scalars.count <= braceInputLimit else { return nil }
        return expandSlice(scalars[...], limit: limit, depth: 0)
    }

    /// 递归深度上限（嵌套的 `{`，也含「后面还有一组」的尾部递归）。超过按「拒绝」处理。
    /// 说明：每个含逗号的大括号组至少产生 2 项，所以顺序排列超过约 6 组本来就会超过 64 项上限；
    /// 嵌套则项数增长是线性的，必须靠这个深度上限挡住深递归。
    private static let braceDepthLimit = 32

    private static func expandSlice(_ chars: ArraySlice<Unicode.Scalar>, limit: Int, depth: Int) -> [String]? {
        if depth > braceDepthLimit { return nil }
        var i = chars.startIndex
        while i < chars.endIndex {
            guard chars[i] == "{" else { i += 1; continue }
            var level = 0
            var commas: [Int] = []
            var close: Int?
            var j = i
            while j < chars.endIndex {
                let c = chars[j]
                if c == "{" { level += 1 }
                else if c == "}" {
                    level -= 1
                    if level == 0 { close = j; break }
                } else if c == ",", level == 1 { commas.append(j) }
                j += 1
            }
            guard let end = close, !commas.isEmpty else { i += 1; continue } // 字面 `{`
            let head = scalarString(chars[chars.startIndex..<i])
            var bodies: [String] = []
            var partStart = i + 1
            for comma in commas + [end] {
                guard let expanded = expandSlice(chars[partStart..<comma], limit: limit, depth: depth + 1) else { return nil }
                bodies.append(contentsOf: expanded)
                if bodies.count > limit { return nil }
                partStart = comma + 1
            }
            guard let tails = expandSlice(chars[(end + 1)...], limit: limit, depth: depth + 1),
                  bodies.count * tails.count <= limit else { return nil }
            var result: [String] = []
            for body in bodies { for tail in tails { result.append(head + body + tail) } }
            return result
        }
        return [scalarString(chars)]
    }

    private static func scalarString(_ slice: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(slice))
    }

    static func braceOverflowReason(_ path: String) -> String {
        "绕过模式底线：大括号展开超过 \(braceExpansionLimit) 项或过长，无法判断是否触及受保护目录或系统文件，按拒绝处理（\(path.prefix(120))）"
    }

    /// 只做剥前缀与折叠，不碰文件系统（用于受保护目录的「字面」形式）。
    static func strip(_ path: String) -> Normalized {
        var real = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var folded = real.map(PolicyRuntimePathBoundary.foldedForPathComparison)
        var changed = true
        while changed {
            changed = false
            if folded.count >= 3, Array(folded.prefix(3)) == dataVolumeComponents {
                real.removeFirst(3); folded.removeFirst(3); changed = true
            } else if folded.first == "private" {
                real.removeFirst(); folded.removeFirst(); changed = true
            }
        }
        return Normalized(real: "/" + real.joined(separator: "/"),
                          folded: "/" + folded.joined(separator: "/"))
    }
}

/// 绕过模式下也不可越过的硬底线：操作系统文件与用户已安装软件。
///
/// - 文件工具：对规范化后的真实路径（`PolicyRuntimePathBoundary.canonicalPath`，
///   已解析符号链接）做判断，大小写与 Unicode 归一化折叠后比较，这是可靠的部分。
/// - shell：`shellViolation` 只是对命令文本的**尽力匹配，不是安全边界**。
///   它拦不住 `python -c`、脚本文件、`find -exec`、变量拼接、相对路径、
///   `osascript` 等间接写法。可靠的兜底来自 macOS 系统完整性保护（SIP）
///   与废纸篓（file_delete 在绕过模式下移入废纸篓）。
public enum BypassSystemFloor {
    public enum Operation: Sendable { case modify, delete }

    /// 受保护的系统前缀（已小写折叠）。`/usr/local` 单独豁免。
    ///
    /// 别名：macOS 上 `/var`、`/etc`、`/tmp` 是指向 `/private/...` 的符号链接。
    /// `canonical` 会先解析符号链接，所以已存在的路径无论写哪种形式都落到
    /// `/private/...`；这里仍把别名并列写出（`/var/db` 与 `/private/var/db`、
    /// `/etc` 与 `/private/etc`），防止解析不到（例如父目录不可读）时漏掉。
    /// `/tmp` 不在底线范围内，因此没有对应条目。
    /// 用户 2026-10-22 决定新增：/Library/LaunchDaemons、/Library/Frameworks、/etc。
    private static let systemPrefixes: [String] = [
        "/system", "/usr", "/bin", "/sbin", "/private/var/db", "/var/db",
        "/library/apple", "/library/extensions", "/library/systemextensions",
        "/library/preferences/systemconfiguration",
        "/library/launchdaemons", "/library/frameworks",
        "/etc", "/private/etc",
    ]
    private static let systemExemptions: [String] = ["/usr/local"]

    private static func isWithin(_ folded: String, _ root: String) -> Bool {
        folded == root || folded.hasPrefix(root + "/")
    }

    private static let applicationsRoot = "/applications"

    private static func applicationRoots(home: String) -> [String] {
        [applicationsRoot, BypassPathNormalizer.normalizeHome(home).folded + "/applications"]
    }

    /// 返回违反底线的原因；nil 表示没有触碰底线。
    public static func violation(
        path: String,
        operation: Operation,
        home: String = BypassHomeSeam.home,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isDirectory: (String) -> Bool = BypassSystemFloor.realIsDirectory
    ) -> String? {
        // 与 BypassAppDataFloor、凭据路径保护共用同一个归一函数：
        // 符号链接、大小写、/System/Volumes/Data 与 /private 前缀都在这里折回。
        let normalized = BypassPathNormalizer.normalize(path)
        let real = normalized.real
        let folded = normalized.folded
        let verb = operation == .delete ? "删除" : "改写"
        for prefix in systemPrefixes where isWithin(folded, prefix) {
            if systemExemptions.contains(where: { isWithin(folded, $0) }) { continue }
            return "绕过模式底线：不可\(verb)操作系统文件（\(real)）"
        }
        // 删除某个目录会连带删掉它下面的受保护内容（如 / 、/Library、/Applications）。
        if operation == .delete {
            for prefix in systemPrefixes + applicationRoots(home: home)
            where prefix == folded || prefix.hasPrefix(folded == "/" ? "/" : folded + "/") {
                return "绕过模式底线：不可删除包含系统文件或已安装软件的目录（\(real)）"
            }
        }
        let realParts = real.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let foldedParts = folded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let globChars = CharacterSet(charactersIn: "*?[")
        for root in applicationRoots(home: home) where isWithin(folded, root) {
            let rootCount = root.split(separator: "/", omittingEmptySubsequences: true).count
            guard foldedParts.count > rootCount else { continue }
            // 折叠会改变段数（如全角斜杠 U+FF0F 折叠成 `/`）时，真实路径段与折叠段对不上，
            // 无法可靠取出 .app 包名：按更保守的口径拒绝（Goal19，旧行为是跳过这段检查）。
            guard realParts.count == foldedParts.count else {
                return "绕过模式底线：应用目录下的路径折叠后段数与真实段数不一致（含全角斜杠等字符），无法判断是否触及已安装软件，按拒绝处理（\(real)）"
            }
            if operation == .delete {
                // 应用目录下含通配符的词（rm -rf /Applications/*、~/Applications/F*.app）
                // 展开后可能命中已安装软件；文本匹配看不到展开结果，一律按可能含已装软件拒绝。
                if realParts[rootCount...].contains(where: { $0.rangeOfCharacter(from: globChars) != nil }) {
                    return "绕过模式底线：应用目录下含通配符的路径可能包含已安装软件，不可删除或移动（\(real)）"
                }
                // /Applications 下的非 .app 子目录（如 /Applications/Utilities）里装着软件。
                if root == applicationsRoot, foldedParts.count == rootCount + 1,
                   !foldedParts[rootCount].hasSuffix(".app") {
                    let directory = "/" + realParts[0...rootCount].joined(separator: "/")
                    if isDirectory(directory) {
                        return "绕过模式底线：/Applications 下的子目录可能包含已安装软件，不可删除或移动（\(directory)）"
                    }
                }
            }
            // 路径里任一层是 .app 包（含 /Applications/Utilities/Terminal.app 这类嵌套包）。
            guard let appIndex = foldedParts[rootCount...].firstIndex(where: { $0.hasSuffix(".app") }) else { continue }
            let bundle = "/" + realParts[0...appIndex].joined(separator: "/")
            if operation == .delete {
                return "绕过模式底线：不可卸载或删除已安装软件（\(bundle)）"
            }
            if fileExists(bundle) {
                return "绕过模式底线：不可改写已安装软件内部（\(bundle)）"
            }
        }
        return nil
    }

    public static func realIsDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    // MARK: - shell 尽力匹配（不是安全边界）

    private static let uninstallBrew: Set<String> = ["uninstall", "remove", "rm", "zap"]
    private static let deleteVerbs: Set<String> = ["rm", "rmdir", "unlink", "srm", "trash", "shred"]
    private static let lastArgVerbs: Set<String> = ["cp", "ditto", "rsync", "install", "ln"]
    private static let allArgVerbs: Set<String> = ["tee", "touch", "mkdir", "truncate"]
    private static let skipFirstVerbs: Set<String> = ["chmod", "chown", "chgrp", "chflags"]
    private static let wrapperVerbs: Set<String> = ["sudo", "command", "env", "nohup", "time", "exec", "builtin"]

    struct Segment {
        var words: [String] = []
        var redirects: [String] = []
    }

    /// 极简分词：处理单双引号、反斜杠、分隔符（; & | ( ) 反引号 换行）与重定向。
    static func segments(_ command: String) -> [Segment] {
        var result: [Segment] = []
        var current = Segment()
        var word = ""
        var hasWord = false
        var pendingRedirect = false
        var quote: Character?
        var escaped = false

        func endWord() {
            guard hasWord else { return }
            if pendingRedirect { current.redirects.append(word); pendingRedirect = false }
            else { current.words.append(word) }
            word = ""; hasWord = false
        }
        func endSegment() {
            endWord()
            if !current.words.isEmpty || !current.redirects.isEmpty { result.append(current) }
            current = Segment()
            pendingRedirect = false
        }

        for ch in command {
            if escaped { word.append(ch); hasWord = true; escaped = false; continue }
            if let q = quote {
                if ch == q { quote = nil }
                else if ch == "\\" && q == "\"" { escaped = true }
                else { word.append(ch) }
                continue
            }
            switch ch {
            case "\\": escaped = true
            case "'", "\"": quote = ch; hasWord = true
            case ";", "&", "|", "(", ")", "`", "\n": endSegment()
            case ">":
                endWord()
                pendingRedirect = true
            case "<", " ", "\t": endWord()
            default: word.append(ch); hasWord = true
            }
        }
        endSegment()
        return result
    }

    private static func expand(_ word: String, home: String) -> String? {
        var w = word
        if w == "~" { w = home }
        else if w.hasPrefix("~/") { w = home + String(w.dropFirst(1)) }
        for token in ["${HOME}", "$HOME"] where w.hasPrefix(token) {
            w = home + String(w.dropFirst(token.count))
            break
        }
        guard w.hasPrefix("/") else { return nil }
        return (w as NSString).standardizingPath
    }

    /// 去掉前置环境变量赋值与常见包装命令（sudo、env、nohup…）。
    private static func stripWrappers(_ input: [String]) -> [String] {
        var words = input
        while let first = words.first {
            let base = (first as NSString).lastPathComponent
            if first.contains("="), !first.hasPrefix("/"), !first.hasPrefix("-") {
                words.removeFirst()
            } else if wrapperVerbs.contains(base) {
                words.removeFirst()
                while let flag = words.first, flag.hasPrefix("-") { words.removeFirst() }
            } else { break }
        }
        return words
    }

    /// 命令里每个子命令的操作数（不含命令名本身）加上重定向目标，供绕过档的敏感文件检查使用。
    /// 与底线共用同一套分词：能处理引号、反斜杠、`;`、`&&`、管道和重定向。尽力匹配。
    static func shellOperands(command: String) -> [String] {
        var operands: [String] = []
        for segment in segments(command) {
            operands.append(contentsOf: stripWrappers(segment.words).dropFirst())
            operands.append(contentsOf: segment.redirects)
        }
        return operands
    }

    /// Explicit irreversible operations visible in the shell command. This
    /// uses the same tokenization as the floors and cannot inspect scripts.
    static func requiresIrreversibleDeletionApproval(command: String) -> Bool {
        segments(command).contains { segment in
            let words = stripWrappers(segment.words)
            guard let executable = words.first else { return false }
            let arguments = words.dropFirst()
            switch (executable as NSString).lastPathComponent {
            case "rm", "unlink", "rmdir", "srm", "shred", "emptyTrash":
                return true
            case "find":
                return arguments.contains("-delete")
            case "git":
                // 不可逆的 git 操作：clean -f、reset --hard、push --force / -f / --force-with-lease。
                let forced: (String) -> Bool = { argument in
                    argument == "--force" || argument.hasPrefix("--force-with-lease")
                        || (argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.contains("f"))
                }
                if arguments.contains("clean") && arguments.contains(where: forced) { return true }
                if arguments.contains("reset") && arguments.contains("--hard") { return true }
                if arguments.contains("push") && arguments.contains(where: { forced($0) || $0.hasPrefix("+") }) { return true }
                let list = Array(arguments)
                // 丢弃工作区改动：checkout -- <路径> / checkout .、restore（只取消暂存的 --staged 除外）。
                if let index = list.firstIndex(of: "checkout") {
                    let tail = list[(index + 1)...]
                    if tail.contains("--") || tail.contains(".") || tail.contains(where: { $0 == "-f" || $0 == "--force" }) {
                        return true
                    }
                }
                if let index = list.firstIndex(of: "restore") {
                    let flags = list[(index + 1)...].filter { $0.hasPrefix("-") }
                    let stagedOnly = flags.contains(where: { $0 == "--staged" || $0 == "-S" })
                        && !flags.contains(where: { $0 == "--worktree" || $0 == "-W" })
                    if !stagedOnly { return true }
                }
                // 丢弃暂存的改动：stash drop / stash clear。
                if let index = list.firstIndex(of: "stash"), list.indices.contains(index + 1),
                   ["drop", "clear"].contains(list[index + 1]) { return true }
                return false
            case "osascript":
                return arguments.contains { $0.localizedCaseInsensitiveContains("empty trash") }
            default:
                return false
            }
        }
    }

    /// 会读取、导出或删除钥匙串内容的 `security` 子命令。
    private static let keychainSecretSubcommands: Set<String> = [
        "find-generic-password", "find-internet-password", "find-key",
        "dump-keychain", "export",
        "delete-keychain", "delete-generic-password", "delete-internet-password",
        "delete-certificate", "delete-identity",
    ]

    /// 凭据保护开启时由 `SensitiveFilePolicy.credentialShellViolation` 调用。
    /// 命中 `security` 的钥匙串读取/导出/删除子命令，或 `security -i`（交互模式，
    /// 子命令从标准输入来，文本里看不到）返回原因。尽力匹配，不是安全边界：
    /// `bash -c "security …"`、脚本文件、变量拼接等间接写法拦不住。
    static func keychainCommandViolation(command: String) -> String? {
        for segment in segments(command) {
            let words = stripWrappers(segment.words)
            guard let first = words.first, (first as NSString).lastPathComponent == "security" else { continue }
            var index = 1
            while index < words.count {
                let word = words[index]
                if word == "-p" { index += 2; continue }
                if word.hasPrefix("-"), !word.hasPrefix("--") {
                    if word.dropFirst().contains("i") {
                        return "凭据保护：不允许模型使用 security 交互模式（可在设置里关闭此保护）"
                    }
                    index += 1
                    continue
                }
                if keychainSecretSubcommands.contains(word) {
                    return "凭据保护：不允许模型通过 security 读取、导出或删除钥匙串（security \(word)；可在设置里关闭此保护）"
                }
                break
            }
        }
        return nil
    }

    /// 尽力匹配：卸载命令 + 对受保护路径的改写/删除。命中返回原因，否则 nil。
    /// 不是安全边界，见类型注释。
    public static func shellViolation(
        command: String,
        home: String = BypassHomeSeam.home,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isDirectory: (String) -> Bool = BypassSystemFloor.realIsDirectory
    ) -> String? {
        for segment in segments(command) {
            let words = stripWrappers(segment.words)
            var targets: [(String, Operation)] = segment.redirects.map { ($0, .modify) }
            if let first = words.first {
                let verb = (first as NSString).lastPathComponent
                let args = Array(words.dropFirst())
                let paths = args.filter { !$0.hasPrefix("-") }
                switch verb {
                case "brew":
                    if let sub = paths.first, uninstallBrew.contains(sub) {
                        return "绕过模式底线：不可卸载已安装软件（brew \(sub)）"
                    }
                case "pkgutil":
                    if args.contains(where: { $0 == "--forget" || $0.hasPrefix("--forget=") }) {
                        return "绕过模式底线：不可卸载已安装软件（pkgutil --forget）"
                    }
                case "mas":
                    if paths.first == "uninstall" {
                        return "绕过模式底线：不可卸载已安装软件（mas uninstall）"
                    }
                case "mv":
                    for (index, p) in paths.enumerated() {
                        targets.append((p, index == paths.count - 1 ? .modify : .delete))
                    }
                case "sed", "perl":
                    if args.contains(where: { $0 == "--in-place" || ($0.hasPrefix("-i") && !$0.hasPrefix("--")) }) {
                        for p in paths { targets.append((p, .modify)) }
                    }
                case "find":
                    if args.contains("-delete") {
                        for p in paths.prefix(while: { !$0.hasPrefix("!") }) { targets.append((p, .delete)) }
                    }
                case "dd":
                    for a in args where a.hasPrefix("of=") { targets.append((String(a.dropFirst(3)), .modify)) }
                default:
                    if deleteVerbs.contains(verb) {
                        for p in paths { targets.append((p, .delete)) }
                    } else if lastArgVerbs.contains(verb), let last = paths.last {
                        targets.append((last, .modify))
                    } else if allArgVerbs.contains(verb) {
                        for p in paths { targets.append((p, .modify)) }
                    } else if skipFirstVerbs.contains(verb) {
                        for p in paths.dropFirst() { targets.append((p, .modify)) }
                    }
                }
            }
            for (rawWord, operation) in targets {
                // 大括号在整词上先展开（花括号内可含 `/`、`~`），展开之后才解析家目录并按路径匹配。
                guard let alternatives = BypassPathNormalizer.expandBraces(rawWord) else {
                    // 展开超限：可能指向绝对路径（或把绝对路径藏在大括号里）的一律拒绝；纯相对路径跳过（与旧行为一致）。
                    // 前缀按 Unicode 标量比较：String.hasPrefix 按字素簇，`{` 后紧跟组合符时不会命中。
                    if ["/", "~", "$HOME", "${HOME}", "{"].contains(where: { rawWord.unicodeScalars.starts(with: $0.unicodeScalars) }) {
                        return BypassPathNormalizer.braceOverflowReason(rawWord)
                    }
                    continue
                }
                for raw in alternatives {
                    guard let path = expand(raw, home: home) else { continue }
                    if let reason = violation(path: path, operation: operation, home: home,
                                              fileExists: fileExists, isDirectory: isDirectory) {
                        return reason
                    }
                    // MinisCanvas 自身数据/设置目录与钥匙串：写入、删除、移动（含 mv 源）都拒绝。
                    if let reason = BypassAppDataFloor.violation(
                        path: path, access: operation == .delete ? .delete : .modify, home: home, globbing: true) {
                        return reason
                    }
                }
            }
        }
        return nil
    }
}

/// 绕过模式下的「MinisCanvas 自身数据」底线（用户 2026-10-22 决定）。
///
/// 默认的 `deniedRoots` 是整个 `~/Library/Application Support`（防止模型读到应用自己的
/// API Key）。绕过模式下这个整体拒绝取消，别的应用放在 Application Support 里的文件可以读写；
/// 只剩下面这些目录仍然拒绝（读、写、删都拒）：
///  - `<Application Support>/MinisCore`：设置、规则（终端策略等）、`envvars.json`、MCP、skills；
///  - `<Application Support>/MinisCanvas`：会话、画布草稿、日志、工作流、Soul 等；
///  - `~/Library/Keychains` 与 `/Library/Keychains`（钥匙串相关路径）；
///  - `~/.config/miniscanvas-test`（测试用配置/密钥目录，复核必改项 5）。
/// 以上是硬底线，**不受**「保护凭据类路径」开关控制。
/// 目录名取自 App 实际使用处（SettingsStore/EnvVarStore/SkillStore/MCPServerManager 用 `MinisCore`，
/// SessionStore/SoulStore/WorkflowStore/LogManager/SessionBadgeStore 用 `MinisCanvas`）。
/// 用户自己在设置里加的拒绝目录仍由执行器的 `deniedRoots` 照旧处理。
///
/// - 文件工具：对 `BypassPathNormalizer` 归一后的路径判断（解析符号链接、大小写与 Unicode 折叠、
///   剥 `/System/Volumes/Data` 与 `/private` 前缀），受保护目录本身也经同一函数归一
///   （每个目录单独解析，目录自己是符号链接也命中），这是可靠的部分。
///   删除这些目录的父目录（如整个 Application Support、~/Library）同样拒绝。
/// - shell：`shellViolation`（经 `BypassSystemFloor.shellViolation` 调用）对 rm/mv/重定向/cp/tee/
///   sed -i 等的**目标**做同样判断，目标含通配符时再判断它是否可能展开到受保护目录或其父目录；
///   `shellMentionViolation` 再对命令文本里字面出现的受保护目录一律拒绝（含只读）。
///   这是**尽力匹配，不是安全边界**：`cd` 之后用相对路径、变量拼接、
///   `python -c`、脚本文件、`find -exec`、`osascript` 等间接写法拦不住。
enum BypassAppDataFloor {
    enum Access: Sendable { case read, modify, delete }

    /// App 在 Application Support 下使用的目录名。
    static let appSupportDirectoryNames: [String] = ["MinisCore", "MinisCanvas"]
    /// 家目录下的测试配置目录（相对 home）。
    static let homeProtectedDirectories: [String] = [".config/miniscanvas-test"]

    private struct Resolved: Sendable {
        let supportRoots: [String]
        let protectedRoots: [String]
    }

    /// 按 HOME 缓存解析结果，避免 file_grep 对每个文件都重复 realpath。
    /// 缓存的是「受保护目录的解析结果」：受保护目录下不能被模型新建符号链接
    /// （创建本身就会被底线拒绝），所以缓存不会因模型操作而过期。条目数设上限。
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Resolved] = [:]
        func value(for home: String) -> Resolved? {
            lock.lock(); defer { lock.unlock() }
            return entries[home]
        }
        func store(_ value: Resolved, for home: String) {
            lock.lock(); defer { lock.unlock() }
            if entries.count >= 32 { entries.removeAll() }
            entries[home] = value
        }
    }
    private static let cache = Cache()

    private static func resolve(home: String) -> Resolved {
        if let hit = cache.value(for: home) { return hit }
        var supportBases = [home + "/Library/Application Support",
                            BypassPathNormalizer.normalize(home).real + "/Library/Application Support"]
        if let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            supportBases.append(real.path)
        }
        var supportRoots: [String] = []
        var roots: [String] = []
        // 每个受保护目录单独归一：既加入解析符号链接后的形式，也加入字面形式，
        // 所以 MinisCore 自己是符号链接时，指向它的路径和链接本身都命中。
        func add(_ raw: String, into list: inout [String]) {
            list.append(BypassPathNormalizer.normalize(raw).folded)
            list.append(BypassPathNormalizer.strip(URL(fileURLWithPath: raw).standardizedFileURL.path).folded)
        }
        for base in supportBases {
            add(base, into: &supportRoots)
            for name in appSupportDirectoryNames { add(base + "/" + name, into: &roots) }
        }
        add(home + "/Library/Keychains", into: &roots)
        add("/Library/Keychains", into: &roots)
        for directory in homeProtectedDirectories { add(home + "/" + directory, into: &roots) }
        func unique(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.filter { seen.insert($0).inserted }
        }
        let value = Resolved(supportRoots: unique(supportRoots), protectedRoots: unique(roots))
        cache.store(value, for: home)
        return value
    }

    /// 受保护目录（已归一、折叠）。
    static func protectedRoots(home: String = BypassHomeSeam.home) -> [String] {
        resolve(home: home).protectedRoots
    }

    /// 这个拒绝根是不是「整个 Application Support」（默认拒绝项）。绕过模式下它不再整体生效。
    static func isGenericApplicationSupportRoot(_ path: String, home: String = BypassHomeSeam.home) -> Bool {
        let folded = BypassPathNormalizer.normalize(path).folded
        return resolve(home: home).supportRoots.contains(folded)
    }

    private static let globCharacters = CharacterSet(charactersIn: "*?[{")

    /// 返回违反原因；nil 表示没有触碰 MinisCanvas 自身数据或钥匙串。
    /// `globbing == true`（shell 目标）时，含通配符的写/删目标若可能展开到受保护目录
    /// 或其父目录（`~/Library/*`、`~/Library/Application Support/Minis*`）也拒绝。
    static func violation(
        path: String,
        access: Access,
        home: String = BypassHomeSeam.home,
        globbing: Bool = false
    ) -> String? {
        // 直接调用时（测试、非 shell 入口）同样先在整段路径上展开大括号；
        // shellViolation 已展开过，展开后不含大括号，这里不会再递归。
        if globbing, path.unicodeScalars.contains("{") { // 标量比较：String.contains("{") 按字素簇，`{` 后紧跟组合符时会漏
            guard let alternatives = BypassPathNormalizer.expandBraces(path) else {
                return BypassPathNormalizer.braceOverflowReason(path)
            }
            if alternatives != [path] {
                for alternative in alternatives {
                    if let reason = violation(path: alternative, access: access, home: home, globbing: true) {
                        return reason
                    }
                }
                return nil
            }
        }
        let normalized = BypassPathNormalizer.normalize(path)
        let real = normalized.real
        let folded = normalized.folded
        let roots = resolve(home: home).protectedRoots
        if roots.contains(where: { folded == $0 || folded.hasPrefix($0 + "/") }) {
            return "绕过模式底线：不可访问 MinisCanvas 自身数据/设置目录、测试配置或钥匙串（\(real)）"
        }
        if access == .delete {
            let prefix = folded == "/" ? "/" : folded + "/"
            if roots.contains(where: { $0.hasPrefix(prefix) }) {
                return "绕过模式底线：不可删除包含 MinisCanvas 自身数据目录、测试配置或钥匙串的目录（\(real)）"
            }
        }
        if globbing, access != .read, real.rangeOfCharacter(from: globCharacters) != nil {
            let pattern = normalized.foldedComponents
            for root in roots {
                let rootParts = root.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                if possiblyCovers(pattern: pattern, root: rootParts) {
                    return "绕过模式底线：含通配符的路径可能展开到 MinisCanvas 自身数据目录、测试配置或钥匙串，不可删除、移动或改写（\(real)）"
                }
            }
        }
        return nil
    }

    /// 通配符路径（按段）是否可能指向 `root` 本身、它的父目录或它的内部。
    /// 逐段用 fnmatch 比较（大括号已在整段路径上展开，见 `violation`）；模式比根短时，
    /// 只要前缀各段都能匹配，就意味着可能删到根的某个父目录，同样算命中。
    private static func possiblyCovers(pattern: [String], root: [String]) -> Bool {
        guard !pattern.isEmpty else { return false }
        for (index, part) in pattern.enumerated() {
            guard index < root.count else { return true } // 模式更深，且根的各段都已匹配：在根内部
            if !componentMatches(part, root[index]) { return false }
        }
        return true
    }

    private static func componentMatches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    /// 命令文本里字面出现受保护目录（`~/Library/Application Support/MinisCore`、
    /// `$HOME/…`、绝对路径、`/Library/Keychains`、`.config/miniscanvas-test` 等）就拒绝，读也拒绝。
    /// 先去掉引号和反斜杠，让 `Application\ Support`、`"Application Support"` 也能匹配。
    /// 尽力匹配，不是安全边界，见类型注释。
    static func shellMentionViolation(command: String) -> String? {
        let normalized = command.lowercased().filter { $0 != "\\" && $0 != "\"" && $0 != "'" }
        let needles = appSupportDirectoryNames.map { "/library/application support/" + $0.lowercased() }
            + ["/library/keychains"]
            + homeProtectedDirectories.map { "/" + $0.lowercased() }
        for needle in needles where normalized.contains(needle) {
            return "绕过模式底线：不可访问 MinisCanvas 自身数据/设置目录、测试配置或钥匙串（命令中出现 \(needle)）"
        }
        return nil
    }
}
