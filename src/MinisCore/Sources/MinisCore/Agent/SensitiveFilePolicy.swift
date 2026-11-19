import Foundation

/// One list shared by risk classification and every approval presentation.
/// Sensitive file bodies are never included, even when the secret redactor
/// does not recognize a value (for example an arbitrary .env canary).
public enum SensitiveFilePolicy {
    // MARK: Protected app state

    /// Exact paths (folded for case / normalization) the app itself owns and
    /// the Agent must never mutate, e.g. the persistent approval rule file.
    /// Reference counted so two stores on one file cannot unprotect each other.
    private static let protectedStateLock = NSLock()
    nonisolated(unsafe) private static var protectedStatePaths: [String: (all: Int, files: Int)] = [:]

    /// Protect `url` and its canonical form (exact match, not descendants).
    /// The file subset shares this registry and registration lifecycle: a file
    /// owner can end while a directory owner of the same canonical path lives.
    static func protectStatePath(_ url: URL, isDirectory: Bool = false) {
        let keys = protectedStateKeys(url)
        protectedStateLock.lock(); defer { protectedStateLock.unlock() }
        for key in keys {
            var references = protectedStatePaths[key] ?? (all: 0, files: 0)
            references.all += 1
            if !isDirectory { references.files += 1 }
            protectedStatePaths[key] = references
        }
    }

    static func unprotectStatePath(_ url: URL, isDirectory: Bool = false) {
        let keys = protectedStateKeys(url)
        protectedStateLock.lock(); defer { protectedStateLock.unlock() }
        for key in keys {
            guard var references = protectedStatePaths[key] else { continue }
            if references.all <= 1 {
                protectedStatePaths[key] = nil
            } else {
                references.all -= 1
                if !isDirectory { references.files -= 1 }
                protectedStatePaths[key] = references
            }
        }
    }

    /// True when `path` is exactly a protected app-state path.
    public static func isProtectedStatePath(_ path: String) -> Bool {
        protectedStateLock.lock()
        let isEmpty = protectedStatePaths.isEmpty
        protectedStateLock.unlock()
        if isEmpty { return false }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var candidates = [standardized]
        if let canonical = PolicyRuntimePathBoundary.canonicalPath(standardized) { candidates.append(canonical) }
        protectedStateLock.lock(); defer { protectedStateLock.unlock() }
        return candidates.contains { protectedStatePaths[PolicyRuntimePathBoundary.foldedForPathComparison($0)] != nil }
    }

    /// All registered files retain the direct command-text guard, including
    /// approval rules and their backups. Directory registrations protect exact
    /// file-tool paths only, never every shell mention of their descendants.
    /// Registration supplies the kind before the file exists; no path guessing.
    static func protectedStateShellViolation(command: String) -> String? {
        let paths = protectedStateLock.withLock {
            protectedStatePaths.compactMap { $0.value.files > 0 ? $0.key : nil }
        }
        let folded = PolicyRuntimePathBoundary.foldedForPathComparison(command)
        return paths.contains(where: { !$0.isEmpty && folded.contains($0) })
            ? "不允许命令访问受保护的应用状态" : nil
    }

    private static func protectedStateKeys(_ url: URL) -> Set<String> {
        let standardized = url.standardizedFileURL.path
        var paths = [standardized]
        if let canonical = PolicyRuntimePathBoundary.canonicalPath(standardized) { paths.append(canonical) }
        return Set(paths.map(PolicyRuntimePathBoundary.foldedForPathComparison))
    }

    public static func isSensitive(_ url: URL) -> Bool { contains(url.path) }
    public static func contains(_ path: String) -> Bool {
        if isProtectedStatePath(path) { return true }
        // Match complete components (including recognized credential filename
        // extensions), not fragments such as docs/credentials-guide.md.
        // Keep raw components too: callers may classify a traversal before
        // the executor rejects it, and must not expose its sensitive body.
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let parts = path.lowercased().split(separator: "/").map(String.init)
            + normalized.lowercased().split(separator: "/").map(String.init)
        // 只认真密钥：Keychain 目录名、credentials.swift、cookies.swift 这类普通源码
        // 按普通文件处理（检查点、grep/glob、预览、风险等级共用此判据）。
        for index in parts.indices {
            let component = parts[index]
            if isCredentialFileName(component)
                || component == ".envrc"
                || [".ssh", ".aws", ".gnupg"].contains(component)
                || isCredentialDataFileName(component, stem: "credentials")
                || isCredentialDataFileName(component, stem: "cookies")
                || component.hasSuffix(".keychain") || component.hasSuffix(".keychain-db") {
                return true
            }
            // 系统钥匙串目录：Library/Keychains
            if component == "keychains", index > 0, parts[index - 1] == "library" { return true }
        }
        return false
    }

    /// 反向判定：只有源码类扩展名放行，其余一律按凭据处理
    /// （credentials.json.bak、cookies.sqlite-wal、cookies.sqlite-journal 等多段扩展名也算）。
    private static let sourceCodeExtensions: Set<String> = [
        "swift", "ts", "js", "py", "go", "rs", "java", "kt", "m", "h", "md",
    ]

    /// `credentials` 本身，或 `credentials.<任意扩展名>`；只有最后一段是源码扩展名（如 `credentials.swift`）才不算。
    private static func isCredentialDataFileName(_ name: String, stem: String) -> Bool {
        if name == stem { return true }
        guard name.hasPrefix(stem + ".") else { return false }
        let rest = name.dropFirst(stem.count + 1)
        guard let last = rest.split(separator: ".").last else { return true }
        return !sourceCodeExtensions.contains(String(last))
    }

    /// 真密钥文件（.env*、.pem、.key、.p12、id_rsa 及凭据目录内文件）：允许编辑，
    /// 但不留检查点备份、改动不可撤销（用户 2026-11-16 决定）。
    /// 受保护的应用状态文件不在此列，仍不可改。
    public static func isUncheckpointedSecretFile(_ path: String) -> Bool {
        contains(path) && !isProtectedStatePath(path)
    }

    public static let uncheckpointedSecretNotice = "此文件不留备份，改动不可撤销。"

    /// Repository control files require confirmation on every mutation, even
    /// in bypass mode. This is separate from sensitive-body redaction so reads
    /// of repository configuration remain available. No file is opened here.
    public static func isProtectedGitWritePath(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.path
            .lowercased().split(separator: "/").map(String.init)
        if parts.last == ".git" || parts.last == ".gitmodules" { return true }
        for index in parts.indices where parts[index] == ".git" {
            let next = index + 1
            if next < parts.count,
               parts[next] == "hooks" || (parts[next] == "config" && next == parts.count - 1) {
                return true
            }
        }
        return false
    }

    /// 会改变工具或命令行行为的配置：`.vscode/`、`.husky/`、`.mcp.json`、
    /// `.claude/settings*.json`、shell 启动文件。非绕过模式下每次写入都要确认；
    /// 绕过模式不加确认（用户 2026-10-22 决定），所以这里与 `isProtectedGitWritePath`
    /// 分开，只由 Composer 策略在绕过模式的提前返回之后使用。不打开任何文件。
    public static func isProtectedToolConfigWritePath(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.path
            .lowercased().split(separator: "/").map(String.init)
        guard let last = parts.last else { return false }
        if parts.contains(".vscode") || parts.contains(".husky") { return true }
        if last == ".mcp.json" { return true }
        let shellStartupNames: Set<String> = [
            ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".bashrc", ".bash_profile",
            ".bash_login", ".profile",
        ]
        if shellStartupNames.contains(last) { return true }
        if let index = parts.lastIndex(of: ".claude"), index == parts.count - 2,
           last.hasPrefix("settings"), last.hasSuffix(".json") {
            return true
        }
        return false
    }

    /// Shared by sensitive-body handling and the existing credential guard;
    /// templates use the same suffix exemption in both paths.
    private static func isCredentialFileName(_ name: String) -> Bool {
        if name == ".env" { return true }
        if name.hasPrefix(".env.") {
            return !envTemplateSuffixes.contains(where: { name.hasSuffix($0) })
        }
        return name == "id_rsa" || name == "id_ed25519" || name == "id_dsa" || name == "id_ecdsa"
            || name.hasSuffix(".pem") || name.hasSuffix(".key")
            || name.hasSuffix(".p12") || name.hasSuffix(".pfx")
            || name.hasSuffix(".p8") || name.hasSuffix(".jks") || name.hasSuffix(".keystore")
            || name == ".npmrc" || name == ".pypirc" || name == ".netrc"
            || (name.hasPrefix("service-account") && name.hasSuffix(".json"))
    }
}

// MARK: - 凭据路径保护（用户 2026-10-22 决定 b）

/// 默认不允许模型读写凭据类路径，只在绕过模式（已确认）下由调用方启用
/// （用户 2026-10-22 决定）；其他模式保持原有审批路径，不在此硬拒绝。
/// 设置里可关闭（`ComposerPolicySettings.protectCredentialPaths`，默认开）。
/// 复用上面的 `.env` / 密钥文件名规则，再加上 home 下的凭据目录。
extension SensitiveFilePolicy {
    private final class CredentialProtectionSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = true
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return enabled }
            set { lock.lock(); enabled = newValue; lock.unlock() }
        }
    }
    private static let credentialSwitch = CredentialProtectionSwitch()

    /// 进程级开关，App 在加载/修改设置时写入；默认 true（安全默认）。
    public static var credentialProtectionEnabled: Bool {
        get { credentialSwitch.value }
        set { credentialSwitch.value = newValue }
    }

    /// home 下的凭据目录（相对 home，小写）。
    static let credentialHomeDirectories: [String] = [
        ".ssh", ".aws", ".gnupg", "library/keychains", ".config/miniscanvas-test",
    ]
    private static let externalCLICredentialHomeFiles = [".codex/auth.json", ".claude/.credentials.json"]
    private static let credentialHomeFiles = [".netrc", ".git-credentials"] + externalCLICredentialHomeFiles
    private static let envTemplateSuffixes: [String] = [".example", ".sample", ".template"]

    /// 路径是否属于凭据类。只看路径名，不读文件内容。
    /// `directoriesOnly == true` 时只看凭据目录和 home 下列出的确切凭据文件，
    /// 不看 `.env` / 密钥文件名——写这类项目内文件仍走原有审批，不在此处硬拒绝。
    /// 不受 `credentialProtectionEnabled` 影响（开关由调用方判断）。
    public static func isCredentialPath(
        _ path: String, home: String = NSHomeDirectory(), directoriesOnly: Bool = false
    ) -> Bool {
        // 与绕过底线共用同一个归一函数：符号链接、大小写、Unicode 折叠，
        // 以及 /System/Volumes/Data 与 /private 前缀（firmlink 视图不能绕过保护）。
        let folded = BypassPathNormalizer.normalize(path).folded
        let homeFolded = BypassPathNormalizer.normalizeHome(home).folded
        for dir in credentialHomeDirectories {
            let root = homeFolded + "/" + dir
            if folded == root || folded.hasPrefix(root + "/") { return true }
        }
        if folded == "/library/keychains" || folded.hasPrefix("/library/keychains/") { return true }
        for file in credentialHomeFiles where folded == homeFolded + "/" + file { return true }
        if directoriesOnly { return false }
        let name = (folded as NSString).lastPathComponent
        return isCredentialFileName(name)
    }

    /// 凭据保护开启且路径属于凭据类时返回拒绝原因。
    /// 读：凭据目录、home 下列出的凭据文件及 `.env`/密钥文件名都拒绝。
    /// 写/改/删：只拒绝凭据目录和 home 下列出的确切凭据文件。
    public static func credentialDenial(for path: String, forWrite: Bool = false) -> String? {
        guard credentialProtectionEnabled,
              isCredentialPath(path, directoriesOnly: forWrite) else { return nil }
        return "凭据保护：不允许模型\(forWrite ? "改写" : "读取")该路径（可在设置里关闭此保护）：\(path)"
    }

    /// shell 里出现凭据目录或外部 CLI 登录文件的路径字面量时返回原因。
    /// 尽力匹配，不是安全边界；只在绕过模式的 shell 上调用。
    public static func credentialShellViolation(command: String, home: String = NSHomeDirectory()) -> String? {
        guard credentialProtectionEnabled else { return nil }
        let lowered = command.lowercased()
        let homeLowered = home.lowercased()
        // 家目录的剥前缀形式（去掉 /private、/System/Volumes/Data）也要匹配。
        let homeStripped = BypassPathNormalizer.normalizeHome(home).folded
        let homePrefixes = ["~/", "$home/", "${home}/", homeLowered + "/", homeStripped + "/"]
        for dir in credentialHomeDirectories {
            for prefix in homePrefixes where lowered.contains(prefix + dir) {
                return "凭据保护：不允许模型访问 ~/\(dir)（可在设置里关闭此保护）"
            }
        }
        let prefixPattern = homePrefixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        for file in externalCLICredentialHomeFiles {
            let filePattern = NSRegularExpression.escapedPattern(for: file)
            // Require shell delimiters so an ordinary sibling such as auth.json.example stays usable.
            let pattern = "(?:^|[\\s\"'=<>;|&()`])(?:\(prefixPattern))\(filePattern)(?=$|[\\s\"'<>;|&()`])"
            if lowered.range(of: pattern, options: .regularExpression) != nil {
                return "凭据保护：不允许模型访问 ~/\(file)（可在设置里关闭此保护）"
            }
        }
        // `security` 的钥匙串读取/导出/删除子命令（同样是尽力匹配）。
        return BypassSystemFloor.keychainCommandViolation(command: command)
    }
}
