import CryptoKit
import Foundation
import Darwin

/// One application-wide notice; never includes an environment name or value.
public enum SubprocessEnvironmentNotice {
    public static let notification = Notification.Name("MinisCanvasSubprocessEnvironmentFiltered")
    public static let message = "本地 MCP、Hook 和外部桥继续过滤应用环境变量；所需凭据请在对应配置中提供。模型命令与可见终端默认继承登录 Shell 凭据，可在设置中开启“剥离凭据”。"
    private static let state: EnvironmentNoticeState = {
        do {
            if let root = try ChildProcessEnvironment.profileRoot() {
                return EnvironmentNoticeState(markerURL: root.appendingPathComponent("subprocess-environment-notice"))
            }
            return EnvironmentNoticeState(defaults: .standard)
        } catch {
            preconditionFailure("Invalid subprocess isolation profile")
        }
    }()

    /// Pending delivery survives a spawn before the main window subscribes.
    public static func takePending() -> Bool { state.takePending() }

    static func recordDiscard(name: String) {
        guard state.recordDiscard(name: name) else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    static func credentialLike(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH", "CREDENTIAL"].contains { upper.contains($0) }
    }
}

final class EnvironmentNoticeState: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = false
    private var pending = false
    private let hasPresented: (() -> Bool)?
    private let markPresented: (() -> Void)?
    private let markerURL: URL?
    private static let preferenceKey = "subprocessEnvironmentNoticePresented"

    init(defaults: UserDefaults? = nil, markerURL: URL? = nil) {
        self.hasPresented = defaults.map { defaults in { defaults.bool(forKey: Self.preferenceKey) } }
        self.markPresented = defaults.map { defaults in { defaults.set(true, forKey: Self.preferenceKey) } }
        self.markerURL = markerURL
    }

    /// Pure storage seam for tests; never uses the real preferences domain.
    init(hasPresented: @escaping () -> Bool, markPresented: @escaping () -> Void) {
        self.hasPresented = hasPresented
        self.markPresented = markPresented
        self.markerURL = nil
    }

    func recordDiscard(name: String = "SYNTHETIC_API_KEY") -> Bool {
        guard SubprocessEnvironmentNotice.credentialLike(name) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !recorded else { return false }
        recorded = true
        if hasPresented?() == true { return false }
        if let markerURL, FileManager.default.fileExists(atPath: markerURL.path) { return false }
        pending = true
        return true
    }

    func takePending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pending else { return false }
        pending = false
        // Persist only when a window actually consumes the pending notice.
        // Isolated runs never touch the production preferences domain.
        markPresented?()
        if let markerURL { try? Data("presented\n".utf8).write(to: markerURL, options: .atomic) }
        return true
    }
}

/// Shared environment isolation for model commands, the visible terminal and
/// local MCP servers. This is not a filesystem or network sandbox.
public enum ChildProcessEnvironment {
    // Standard installations remain usable without accepting an arbitrary App
    // PATH, virtualenv, loader variables, or interpreter startup hooks.
    static let executableSearchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static func values() throws -> [String: String] {
        // Read values only for the finite ordinary allowlist. Scan other
        // entries only up to '='; never materialize provider credential values.
        var ordinary: [String: String] = [:]
        for name in ordinaryNames.union(proxyNames) {
            if let value = getenv(name) { ordinary[name] = String(cString: value) }
        }
        let root = try profileRoot()
        let directories = try root.map { try isolatedDirectories(root: $0) }
        let result = values(ordinary: ordinary, directories: directories)
        var index = 0
        while let entry = environ[index] {
            var length = 0
            while entry[length] != 0 && entry[length] != 61 { length += 1 }
            let name = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(entry).assumingMemoryBound(to: UInt8.self), count: length), as: UTF8.self)
            if result[name] == nil, SubprocessEnvironmentNotice.credentialLike(name) {
                SubprocessEnvironmentNotice.recordDiscard(name: name)
                break
            }
            index += 1
        }
        return result
    }

    static let ordinaryNames: Set<String> = [
        "LANG", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_MESSAGES", "LC_MONETARY",
        "LC_NUMERIC", "LC_TIME", "LC_PAPER", "LC_NAME", "LC_ADDRESS", "LC_TELEPHONE",
        "LC_MEASUREMENT", "LC_IDENTIFICATION", "TERM", "COLORTERM"
    ]

    // Only these six ordinary proxy names are read from the parent. ALL_PROXY
    // remains excluded; SSH_AUTH_SOCK and credentials are never imported.
    static let proxyNames: Set<String> = [
        "http_proxy", "https_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"
    ]

    private static func validProxyValue(_ value: String, bypass: Bool) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 2048,
              value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              !value.contains("@"), !value.contains("?"), !value.contains("#"),
              !value.contains("%") else { return false }
        if bypass {
            return value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [UInt8(46), 44, 58, 91, 93, 45, 42, 95, 47].contains($0)
            }
        }
        let address = value.contains("://") ? value : "http://" + value
        guard let parts = URLComponents(string: address),
              parts.scheme == "http" || parts.scheme == "https",
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return false }
        return parts.port.map { (1...65535).contains($0) } ?? true
    }

    static func values(ordinary: [String: String], directories: (home: String, temporary: String)? = nil) -> [String: String] {
        let identity = operatingSystemIdentity()
        var result = [
            "PATH": executableSearchPath,
            "HOME": directories?.home ?? identity.home,
            "USER": identity.user,
            "LOGNAME": identity.user,
            "TMPDIR": directories?.temporary ?? operatingSystemTemporaryDirectory(),
            "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
            // Noninteractive zsh otherwise reads the user's .zshenv and can
            // reintroduce the very credentials removed at the spawn boundary.
            "ZDOTDIR": "/var/empty",
        ]
        for (name, value) in ordinary where ordinaryNames.contains(name) && validOrdinaryValue(value) {
            result[name] = value
        }
        for (name, value) in ordinary where proxyNames.contains(name)
            && validProxyValue(value, bypass: name.lowercased() == "no_proxy") {
            result[name] = value
        }
        return result
    }

    private static func validOrdinaryValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || [UInt8(45), 46, 64, 95].contains($0)
        }
    }

    /// A server's explicitly saved environment is its own allowlist. It may
    /// contain a server-specific token or an explicit toolchain PATH; neither
    /// is inferred from App variables or expanded through the App environment.
    static func mcpValues(configured: [String: String]) throws -> [String: String] {
        var result = try values()
        let isolated = try profileRoot() != nil
        for (name, value) in configured where validName(name) && !value.utf8.contains(0) {
            if isolated && (name == "HOME" || name == "TMPDIR") { continue }
            result[name] = value
        }
        return result
    }

    /// Keep allocations alive through posix_spawn and fail before spawning on
    /// allocation failure. Never substitute `environ` as an error fallback.
    static func withCStringVector(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) -> Int32 {
        let environment: [String: String]
        do { environment = try values() }
        catch { return EINVAL } // Invalid isolation never falls back to the real home.
        var entries = environment.keys.sorted().map { name in
            strdup(name + "=" + (environment[name] ?? ""))
        }
        defer { for entry in entries { free(entry) } }
        guard entries.allSatisfy({ $0 != nil }) else { return ENOMEM }
        entries.append(nil)
        return entries.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return ENOMEM }
            return body(base)
        }
    }

    /// Reuse the existing profile contract, reading only its finite public
    /// configuration fields rather than materializing the App environment.
    static func profileRoot() throws -> URL? {
        let names = [
            FormalTestIsolationPaths.profileMarkerKey, FormalTestIsolationPaths.profileDirectoryKey,
            FormalTestIsolationPaths.profileIdentityKey, FormalTestIsolationPaths.runIDKey,
            FormalTestIsolationPaths.packageKey, FormalTestIsolationPaths.scratchDirectoryKey,
            FormalTestIsolationPaths.rootDeviceKey, FormalTestIsolationPaths.rootInodeKey,
            FormalTestIsolationPaths.rootOwnerKey, "RUN_TESTS_INTERNAL_NATIVE",
            "MINISCANVAS_FIELD_PROFILE", "MINISCANVAS_FIELD_PROFILE_ROOT"
        ]
        var configuration: [String: String] = [:]
        for name in names {
            if let value = getenv(name) { configuration[name] = String(cString: value) }
        }
        return try profileRoot(configuration: configuration,
            arguments: ProcessInfo.processInfo.arguments, processName: ProcessInfo.processInfo.processName)
    }

    static func profileRoot(configuration: [String: String], arguments: [String], processName: String) throws -> URL? {
        if let formal = try FormalTestIsolationPaths.resolve(
            environment: configuration, arguments: arguments, processName: processName) {
            return formal.rootDirectory
        }
        guard configuration["MINISCANVAS_FIELD_PROFILE"] == "1",
              let path = configuration["MINISCANVAS_FIELD_PROFILE_ROOT"] else { return nil }
        guard path.hasPrefix("/"), path != "/" else { throw FormalTestIsolationPaths.IsolationError.unsafeRoot }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0, (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == geteuid() else { throw FormalTestIsolationPaths.IsolationError.unsafeRoot }
        return root
    }

    static func isolatedDirectories(root: URL) throws -> (home: String, temporary: String) {
        let root = root.resolvingSymlinksInPath()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let temporary = root.appendingPathComponent("temporary", isDirectory: true)
        for directory in [home, temporary] {
            guard directory.deletingLastPathComponent().resolvingSymlinksInPath() == root else {
                throw FormalTestIsolationPaths.IsolationError.unsafeRoot
            }
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
                throw FormalTestIsolationPaths.IsolationError.unsafeRoot
            }
            var metadata = stat()
            guard lstat(directory.path, &metadata) == 0, (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  metadata.st_uid == geteuid() else { throw FormalTestIsolationPaths.IsolationError.unsafeRoot }
        }
        return (home.path, temporary.path)
    }

    private static func validName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        func letter(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
        }
        guard let first = bytes.first, letter(first) else { return false }
        return bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) }
    }

    private static func operatingSystemIdentity() -> (home: String, user: String) {
        // passwd, not NSHomeDirectory / USER / HOME, which can be redirected by
        // the launching process. The reentrant lookup avoids shared passwd data.
        var bytes = [CChar](repeating: 0, count: 65_536)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            var record = passwd()
            var found: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(geteuid(), &record, buffer.baseAddress, buffer.count, &found) == 0,
                  found != nil, let home = record.pw_dir, let user = record.pw_name else {
                return ("/var/empty", String(geteuid()))
            }
            let homeValue = String(cString: home)
            let userValue = String(cString: user)
            return (homeValue.hasPrefix("/") ? homeValue : "/var/empty",
                    !userValue.isEmpty && !userValue.contains("\n") ? userValue : String(geteuid()))
        }
    }

    private static func operatingSystemTemporaryDirectory() -> String {
        let required = confstr(Int32(_CS_DARWIN_USER_TEMP_DIR), nil, 0)
        guard required > 0 && required <= 65_536 else { return "/tmp/" }
        var bytes = [CChar](repeating: 0, count: required)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            let copied = confstr(Int32(_CS_DARWIN_USER_TEMP_DIR), buffer.baseAddress, buffer.count)
            guard copied > 0 && copied <= buffer.count, let base = buffer.baseAddress else {
                return "/tmp/"
            }
            let value = String(cString: base)
            return value.hasPrefix("/") ? value : "/tmp/"
        }
    }
}

/// Effective classification shared by the visible terminal and Agent
/// `shell_execute`.  The syntax guard remains a separate structural gate.
public enum TerminalCommandDisposition: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case allowed
    case confirmation
    case denied
    case unknown
}

/// Persisted user-editable command policy. Product hard-deny commands are
/// intentionally absent: they live only in `TerminalPolicySnapshot` and can
/// never be removed by a settings edit or domain reset.
public enum TerminalPolicyDecodingError: Error, Equatable, Sendable {
    case unsupportedProvenanceVersion(Int)
}

public struct TerminalPolicySettings: Codable, Equatable, Sendable {
    public var automaticAllowCommands: [String]
    public var confirmationCommands: [String]
    public var userDeniedCommands: [String]
    public var explicitConfirmationCommands: [String]
    /// nil preserves unknown provenance in legacy persisted settings.
    public var confirmationProvenanceVersion: Int?

    public static let `default` = TerminalPolicySettings(
        automaticAllowCommands: TerminalPolicySnapshot.defaultAutomaticAllowCommands.sorted(),
        confirmationCommands: TerminalPolicySnapshot.defaultConfirmationCommands.sorted(),
        userDeniedCommands: [],
        confirmationProvenanceVersion: 1
    )

    public init(
        automaticAllowCommands: [String] = TerminalPolicySettings.default.automaticAllowCommands,
        confirmationCommands: [String] = TerminalPolicySettings.default.confirmationCommands,
        userDeniedCommands: [String] = TerminalPolicySettings.default.userDeniedCommands,
        explicitConfirmationCommands: [String] = [],
        confirmationProvenanceVersion: Int? = nil
    ) {
        self.automaticAllowCommands = Self.normalize(automaticAllowCommands)
        self.confirmationCommands = Self.normalize(confirmationCommands)
        self.userDeniedCommands = Self.normalize(userDeniedCommands)
        self.explicitConfirmationCommands = Self.normalize(explicitConfirmationCommands)
        self.confirmationProvenanceVersion = confirmationProvenanceVersion
    }

    private enum CodingKeys: String, CodingKey {
        case automaticAllowCommands, confirmationCommands, userDeniedCommands
        case explicitConfirmationCommands, confirmationProvenanceVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .confirmationProvenanceVersion)
        if let version, version != 1 {
            throw TerminalPolicyDecodingError.unsupportedProvenanceVersion(version)
        }
        let decoded = TerminalPolicySettings(
            automaticAllowCommands: try c.decodeIfPresent([String].self, forKey: .automaticAllowCommands)
                ?? TerminalPolicySettings.default.automaticAllowCommands,
            confirmationCommands: try c.decodeIfPresent([String].self, forKey: .confirmationCommands)
                ?? TerminalPolicySettings.default.confirmationCommands,
            userDeniedCommands: try c.decodeIfPresent([String].self, forKey: .userDeniedCommands)
                ?? TerminalPolicySettings.default.userDeniedCommands,
            explicitConfirmationCommands: try c.decodeIfPresent([String].self, forKey: .explicitConfirmationCommands) ?? [],
            confirmationProvenanceVersion: version
        )
        // A persisted payload (legacy file, crash-recovery re-read, or tampered
        // settings JSON) must satisfy the same product hard-deny invariant as an
        // interactive SettingsCenter write: hard-denied executables never appear
        // in a user-editable list. Without this the settings mirror, the editor
        // text, and the consumed snapshot could disagree about a hard-deny name
        // — exactly the “two command categories” F07 shape. This only strips
        // hard entries (fail-closed); legitimate user commands survive.
        self = decoded.normalized()
    }

    public func normalized() -> Self {
        let hard = TerminalPolicySnapshot.productHardDeniedCommands
        let denied = Set(userDeniedCommands).subtracting(hard)
        let confirmation = Set(confirmationCommands)
            .subtracting(hard)
            .subtracting(denied)
        let allowed = Set(automaticAllowCommands)
            .subtracting(hard)
            .subtracting(denied)
            .subtracting(confirmation)
        return Self(
            automaticAllowCommands: allowed.sorted(),
            confirmationCommands: confirmation.sorted(),
            userDeniedCommands: denied.sorted(),
            explicitConfirmationCommands: Set(explicitConfirmationCommands).intersection(confirmation).sorted(),
            confirmationProvenanceVersion: confirmationProvenanceVersion
        )
    }

    /// Only names added by this editor gain explicit provenance.
    public func editingConfirmationCommands(_ newNames: [String]) -> Self {
        var edited = self
        let names = Set(Self.normalize(newNames))
        edited.confirmationCommands = names.sorted()
        edited.explicitConfirmationCommands = Set(explicitConfirmationCommands)
            .intersection(names)
            .union(names.subtracting(confirmationCommands))
            .sorted()
        return edited.normalized()
    }

    private static func normalize(_ values: [String]) -> [String] {
        Array(Set(values.compactMap(TerminalPolicySnapshot.normalizeCommandName))).sorted()
    }
}

/// Immutable policy facts captured at one request boundary. The snapshot is
/// the only command-category source consumed by both terminal entry paths.
public struct TerminalPolicySnapshot: Codable, Equatable, Hashable, Sendable {
    public let revision: String
    public let automaticAllowCommands: Set<String>
    public let confirmationCommands: Set<String>
    public let userDeniedCommands: Set<String>
    public let explicitConfirmationCommands: Set<String>
    public let confirmationProvenanceVersion: Int?
    public let productHardDeniedCommands: Set<String>

    public static let defaultAutomaticAllowCommands: Set<String> = [
        "cd", "ls", "pwd", "echo", "whoami", "date", "cat", "head", "tail",
        "wc", "grep", "find", "tree", "clear", "which", "du", "df", "stat",
        "file", "basename", "dirname", "uname", "sw_vers",
        "sort", "uniq", "cut", "tr", "xargs", "history", "man", "help", "type",
    ]

    public static let defaultConfirmationCommands: Set<String> = [
        "mkdir", "touch", "cp", "mv", "rm", "git", "curl", "wget",
        "swift", "swiftc", "xcodebuild", "brew", "cargo", "python3", "python",
        "chmod", "chown", "kill", "pkill", "sed", "awk", "tar", "unzip", "zip",
        "plutil", "defaults", "install", "ln", "env", "printenv",
        "npm", "npx", "node", "pnpm", "yarn", "make", "pytest", "go", "gh", "jq", "rg", "uv", "docker",
    ]

    public static let productHardDeniedCommands: Set<String> = [
        "open", "osascript", "screencapture", "shutdown", "reboot", "halt",
        "dd", "mkfs", "sudo", "passwd", "launchctl", "diskutil", "kextload",
        "mount", "umount", "systemsetup", "networksetup", "security", "killall",
    ]

    public static let `default` = TerminalPolicySnapshot(settings: .default)

    private enum CodingKeys: String, CodingKey {
        case revision, automaticAllowCommands, confirmationCommands, userDeniedCommands
        case explicitConfirmationCommands, confirmationProvenanceVersion
    }

    public init(settings: TerminalPolicySettings, revision: String? = nil) {
        let normalized = settings.normalized()
        let hard = Self.productHardDeniedCommands
        let denied = Set(normalized.userDeniedCommands).subtracting(hard)
        let confirmation = Set(normalized.confirmationCommands)
            .subtracting(hard)
            .subtracting(denied)
        let allowed = Set(normalized.automaticAllowCommands)
            .subtracting(hard)
            .subtracting(denied)
            .subtracting(confirmation)
        self.automaticAllowCommands = allowed
        self.confirmationCommands = confirmation
        self.userDeniedCommands = denied
        self.explicitConfirmationCommands = Set(normalized.explicitConfirmationCommands).intersection(confirmation)
        self.confirmationProvenanceVersion = normalized.confirmationProvenanceVersion
        self.productHardDeniedCommands = hard
        self.revision = revision ?? Self.makeRevision(
            allowed: allowed,
            confirmation: confirmation,
            denied: denied,
            hard: hard,
            explicit: self.explicitConfirmationCommands,
            provenanceVersion: self.confirmationProvenanceVersion
        )
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TerminalPolicySettings.default
        let version = try c.decodeIfPresent(Int.self, forKey: .confirmationProvenanceVersion)
        if let version, version != 1 {
            throw TerminalPolicyDecodingError.unsupportedProvenanceVersion(version)
        }
        self.init(settings: TerminalPolicySettings(
            automaticAllowCommands: try c.decodeIfPresent([String].self, forKey: .automaticAllowCommands)
                ?? defaults.automaticAllowCommands,
            confirmationCommands: try c.decodeIfPresent([String].self, forKey: .confirmationCommands)
                ?? defaults.confirmationCommands,
            userDeniedCommands: try c.decodeIfPresent([String].self, forKey: .userDeniedCommands)
                ?? defaults.userDeniedCommands,
            explicitConfirmationCommands: try c.decodeIfPresent([String].self, forKey: .explicitConfirmationCommands) ?? [],
            confirmationProvenanceVersion: version
        ))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(revision, forKey: .revision)
        try c.encode(automaticAllowCommands.sorted(), forKey: .automaticAllowCommands)
        try c.encode(confirmationCommands.sorted(), forKey: .confirmationCommands)
        try c.encode(userDeniedCommands.sorted(), forKey: .userDeniedCommands)
        try c.encode(explicitConfirmationCommands.sorted(), forKey: .explicitConfirmationCommands)
        try c.encodeIfPresent(confirmationProvenanceVersion, forKey: .confirmationProvenanceVersion)
    }

    public var settings: TerminalPolicySettings {
        TerminalPolicySettings(
            automaticAllowCommands: automaticAllowCommands.sorted(),
            confirmationCommands: confirmationCommands.sorted(),
            userDeniedCommands: userDeniedCommands.sorted(),
            explicitConfirmationCommands: explicitConfirmationCommands.sorted(),
            confirmationProvenanceVersion: confirmationProvenanceVersion
        )
    }

    /// Normalize a user-entered executable name to the same basename shape as
    /// the production boundary. Shell syntax and path fragments are rejected.
    public static func normalizeCommandName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        // Keep executable matching case-sensitive, matching the original
        // terminal allow-list (`LS` must remain unknown rather than becoming
        // the `ls` entry).
        return name
    }

    public func classify(command: String) -> TerminalCommandDisposition {
        let inspected = TerminalGuard.inspect(command)
        return classify(
            words: inspected.isAllowed
                ? inspected.words
                : Self.policyWords(command, fallback: inspected.words),
            syntaxAllowed: inspected.isAllowed
        )
    }

    /// 命令里命中用户自己配置的拒绝命令（`userDeniedCommands`）时返回命中的可执行名，否则 nil。
    /// 只看用户拒绝表，不看产品硬拒绝表，也不做「未登记即拒绝」。绕过模式（用户 2026-10-22
    /// 决定）取消系统硬拒绝表与未登记拒绝，但用户自己禁用的命令继续禁用，由
    /// `shell_execute` 在绕过范围内调用本方法。命中口径与 `classify(words:)` 的拒绝分支一致：
    /// 语法通过且能解析出被包装的真实可执行文件时只看该可执行文件；否则（语法被拒或无法解析）
    /// 首词以及其后的任一词命中都算。
    public func userDeniedExecutable(in command: String) -> String? {
        guard !userDeniedCommands.isEmpty else { return nil }
        let inspected = TerminalGuard.inspect(command)
        let words = inspected.isAllowed
            ? inspected.words
            : Self.policyWords(command, fallback: inspected.words)
        let normalizedWords = words.compactMap(Self.normalizeCommandName)
        guard let first = normalizedWords.first else { return nil }
        let resolved = inspected.isAllowed
            ? TerminalGuard.effectiveExecutable(in: words).flatMap(Self.normalizeCommandName)
            : nil
        let executable = resolved ?? first
        // 绕过模式下用户拒绝的命令按大小写折叠比较：APFS 默认不区分大小写，
        // `RM`、`/BIN/RM` 与 `rm` 是同一个可执行文件（复核必改项 2）。
        // 只用于本方法；classify 在非绕过模式的行为不变。
        let deniedFolded = Set(userDeniedCommands.map { $0.lowercased() })
        if deniedFolded.contains(executable.lowercased()) { return executable }
        // 解析不出被包装的真实可执行文件，或可执行文件本身是透传包装（nohup、time…，
        // TerminalGuard 不当作包装展开），被包装的命令在后面的词里：后面任一词命中都算。
        if resolved == nil || Self.passthroughWrapperNames.contains(executable.lowercased()) {
            return normalizedWords.dropFirst().first(where: { deniedFolded.contains($0.lowercased()) })
        }
        return nil
    }

    /// 只透传给后一个命令、但 `TerminalGuard` 不展开的常见包装。
    private static let passthroughWrapperNames: Set<String> = [
        "nohup", "time", "builtin", "command", "exec", "sudo", "nice", "env", "xargs",
        "caffeinate", "stdbuf", "timeout", "setsid", "arch",
    ]

    public func classify(words: [String], syntaxAllowed: Bool = true) -> TerminalCommandDisposition {
        let normalizedWords = words.compactMap(Self.normalizeCommandName)
        guard let first = normalizedWords.first else { return .unknown }
        // A structurally valid env/nice command runs its nested executable,
        // not the wrapper's own allow-list entry. Resolve it with the same
        // grammar that admitted the command before applying editable rules.
        let resolved = syntaxAllowed
            ? TerminalGuard.effectiveExecutable(in: words).flatMap(Self.normalizeCommandName)
            : nil
        let executable = resolved ?? first
        if productHardDeniedCommands.contains(executable) || userDeniedCommands.contains(executable) {
            return .denied
        }
        // `find` is generally read-only, but its expression can launch a
        // second command or write files without changing the executable.
        // Resolve validated env/nice wrappers from the token sequence even
        // when shell syntax was rejected, so approval cannot turn -exec into
        // an alternate command-dispatch path at the native boundary.
        let findAction = Self.findExpressionAction(in: words)
        if findAction == .dispatch { return .denied }
        guard syntaxAllowed, resolved != nil else {
            // Preserve the original visible-terminal distinction: a hard
            // denied wrapper nested in rejected syntax stays denied, while a
            // merely unsafe/compound command still requires approval.
            if normalizedWords.dropFirst().contains(where: {
                productHardDeniedCommands.contains($0) || userDeniedCommands.contains($0)
            }) {
                return .denied
            }
            return .confirmation
        }
        if first == "env" || executable == "printenv" { return .confirmation }
        if findAction == .write { return .confirmation }
        if explicitConfirmationCommands.contains(executable) { return .confirmation }
        if GitWorkflowPolicy.automaticallyAllows(words: words) { return .allowed }
        if confirmationCommands.contains(executable) { return .confirmation }
        if automaticAllowCommands.contains(executable) { return .allowed }
        return .unknown
    }

    private enum FindExpressionAction {
        case none, write, dispatch
    }

    private static func findExpressionAction(in words: [String]) -> FindExpressionAction {
        let resolvedFind = TerminalGuard.effectiveExecutable(in: words).flatMap(normalizeCommandName) == "find"
        // `env -S` is rejected by the lexical guard, but an exact approval
        // can otherwise carry that command through the native boundary. The
        // split string can hide `find` from effectiveExecutable; recognize
        // only this rejected wrapper form before applying the same expression
        // action rules. Do not infer a generic shell's behavior here.
        let first = words.first.flatMap(normalizeCommandName)
        let splitWords = words.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        let splitEnvFind = (first == "env" || first == "nice")
            && splitWords.contains(where: { $0 == "-S" || $0 == "--split-string" || $0.hasPrefix("--split-string=") })
            && splitWords.contains(where: { word in
                normalizeCommandName(word) == "find"
                    || (word.hasPrefix("--split-string=")
                        && normalizeCommandName(String(word.dropFirst("--split-string=".count))) == "find")
            })
        guard resolvedFind || splitEnvFind else {
            return .none
        }
        let dispatch: Set<String> = ["-exec", "-execdir", "-ok", "-okdir"]
        let write: Set<String> = ["-delete", "-fprint", "-fprintf", "-fls"]
        if splitWords.contains(where: dispatch.contains) { return .dispatch }
        if splitWords.contains(where: write.contains) { return .write }
        return .none
    }

    private static func makeRevision(
        allowed: Set<String>,
        confirmation: Set<String>,
        denied: Set<String>,
        hard: Set<String>,
        explicit: Set<String>,
        provenanceVersion: Int?
    ) -> String {
        let canonical = [
            allowed.sorted().joined(separator: ","),
            confirmation.sorted().joined(separator: ","),
            denied.sorted().joined(separator: ","),
            hard.sorted().joined(separator: ","),
            explicit.sorted().joined(separator: ","),
            provenanceVersion.map(String.init) ?? "unknown",
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Retain executable-looking tokens after the Core syntax guard stops at
    /// an operator. This keeps `ls && sudo …` denied in both consumers while
    /// leaving quoted arguments such as `echo "sudo"` ordinary arguments.
    fileprivate static func policyWords(_ command: String, fallback: [String]) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        func finish() {
            guard !current.isEmpty else { return }
            words.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for character in command {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace || ";|&><(){}".contains(character) {
                finish()
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        finish()
        return words.isEmpty ? fallback : words
    }
}

public struct TerminalExecutionContext: Equatable, Sendable {
    public let sessionID: String
    public let turnID: String
    public let taskID: String
    public let projectID: String
    public let workdir: String

    public init(sessionID: String, turnID: String, taskID: String, projectID: String, workdir: String) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.taskID = taskID
        self.projectID = projectID
        self.workdir = workdir
    }
}

public struct TerminalApproval: Equatable, Sendable {
    public let scopeID: String
    public let requestFingerprint: String
    public let expiresAt: Date
    public let cancelled: Bool

    public init(scopeID: String, requestFingerprint: String, expiresAt: Date, cancelled: Bool = false) {
        self.scopeID = scopeID
        self.requestFingerprint = requestFingerprint
        self.expiresAt = expiresAt
        self.cancelled = cancelled
    }

    public static let cancelled = TerminalApproval(scopeID: "", requestFingerprint: "", expiresAt: .distantPast, cancelled: true)
}

public struct TerminalExecutionRequest: Sendable {
    public let capabilityID: String
    public let command: String
    public let context: TerminalExecutionContext
    public let approval: TerminalApproval?
    public let timeout: Duration

    public init(
        capabilityID: String,
        command: String,
        context: TerminalExecutionContext,
        approval: TerminalApproval? = nil,
        timeout: Duration = .seconds(120)
    ) {
        self.capabilityID = capabilityID
        self.command = command
        self.context = context
        self.approval = approval
        self.timeout = min(.seconds(600), max(.milliseconds(1), timeout))
    }

    public var requestFingerprint: String {
        let canonical = [
            capabilityID, command, context.sessionID, context.turnID,
            context.taskID, context.projectID, context.workdir,
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct TerminalProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    /// The bounded process capture discarded bytes before receipt projection.
    public let outputWasTruncated: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, outputWasTruncated: Bool = false) {
        self.exitCode = exitCode
        let credentials = ModelShellEnvironment.knownCredentialValues()
        // Preserve escape information before the complete-value redactor can
        // replace an escaped quote's prefix and lose its original boundary.
        let capturedStdout = TerminalReceipt.redactQuotedCapturedAssignments(stdout, wasTruncated: outputWasTruncated)
        let capturedStderr = TerminalReceipt.redactQuotedCapturedAssignments(stderr, wasTruncated: outputWasTruncated)
        self.stdout = ContentSecretRedactor.redact(capturedStdout, knownSecrets: credentials)
        self.stderr = ContentSecretRedactor.redact(capturedStderr, knownSecrets: credentials)
        self.outputWasTruncated = outputWasTruncated
    }
}

public protocol TerminalProcessRunner: Sendable {
    /// Settle cancellation only after owned process/pipe cleanup has completed.
    func run(command: String, workdir: URL, timeout: Duration) async throws -> TerminalProcessResult
}

public enum TerminalBoundaryError: String, Error, Sendable {
    case unknown
    case contextUnavailable
    case permissionDenied
    case denied
    case approvalRequired
    case approvalDenied
    case scopeMismatch
    case approvalExpired
    case cancelled
    case pathViolation
    case timeout
    case spawnFailed
    case executionFailed

    /// User-facing guidance for a receipt that crossed the production
    /// terminal boundary. The raw value remains the typed, machine-readable
    /// outcome used by callers and evidence.
    public var actionableMessage: String {
        switch self {
        case .unknown:
            return "未知命令或终端能力；请检查命令拼写和当前会话权限。"
        case .contextUnavailable:
            return "终端不可用：当前会话未绑定项目和工作目录；请先选择有项目工作目录的会话。"
        case .permissionDenied:
            return "终端已被安全设置关闭；请在设置中启用“浏览器与终端副作用”后重试。"
        case .denied:
            return "命令被安全策略拒绝；请使用允许的项目内命令。"
        case .approvalRequired:
            return "此命令需要一次性确认后才能执行。"
        case .approvalDenied:
            return "确认与当前命令不匹配；请重新提交并确认。"
        case .scopeMismatch:
            return "终端请求与当前项目范围不一致；请重新打开当前会话的终端。"
        case .approvalExpired:
            return "确认已过期；请重新提交命令并确认。"
        case .cancelled:
            return "命令已取消，未继续执行。"
        case .pathViolation:
            return "路径超出当前项目工作目录；请改用项目范围内的路径。"
        case .timeout:
            return "命令超时，已终止；请缩小命令范围或增加必要的超时设置。"
        case .spawnFailed:
            return "终端进程启动失败；请检查项目工作目录和系统权限。"
        case .executionFailed:
            return "终端命令执行失败；请查看命令输出后重试。"
        }
    }
}

public struct TerminalReceipt: Codable, Equatable, Sendable {
    public static let maximumOutputCharacters = 4_096
    public let sessionID: String
    public let turnID: String
    public let taskID: String
    public let projectID: String
    public let workdir: String
    /// Exact safe read command only. Arbitrary terminal input may contain
    /// credentials and must never be copied into an exportable receipt.
    public let command: String?
    public let requestFingerprint: String
    public let exitCode: Int32?
    public let output: String
    public let error: String?

    fileprivate init(request: TerminalExecutionRequest, result: TerminalProcessResult? = nil, error: TerminalBoundaryError? = nil) {
        sessionID = request.context.sessionID
        turnID = request.context.turnID
        taskID = request.context.taskID
        projectID = request.context.projectID
        workdir = request.context.workdir
        command = request.command == "pwd" ? "pwd" : nil
        requestFingerprint = request.requestFingerprint
        exitCode = error == nil ? result?.exitCode : nil
        let rawOutput = [result?.stdout, result?.stderr].compactMap { $0 }.filter { !$0.isEmpty }
            .map { Self.redactQuotedCapturedAssignments($0, wasTruncated: result?.outputWasTruncated == true) }
            .joined(separator: "\n")
        let redacted = ContentSecretRedactor.redact(rawOutput)
        let projected = String(redacted.prefix(Self.maximumOutputCharacters))
        output = redacted.count > Self.maximumOutputCharacters || result?.outputWasTruncated == true
            ? projected + "\n[truncated]"
            : projected
        self.error = error?.rawValue
    }

    /// A byte cap can discard the closing quote required by the ordinary
    /// complete-value redactor. Only truncated captures need this conservative
    /// quote handling; process each pipe before joining so the other pipe cannot
    /// supply a misleading closing quote. Keep the existing value masking rule.
    fileprivate static func redactQuotedCapturedAssignments(_ text: String, wasTruncated: Bool) -> String {
        guard wasTruncated else { return text }
        let sensitiveName = "(?:api[_-]?key|apikey|key|token|access[_-]?token|auth|password|secret|cookie|session[_-]?id)"
        let assignment = "(?i)(\\b[A-Za-z0-9_\\-]*" + sensitiveName + "(?![A-Za-z0-9_\\-])[A-Za-z0-9_\\-]*=)([\"'])"
        guard let regex = try? NSRegularExpression(pattern: assignment) else {
            return "[truncated output withheld]"
        }
        let source = text as NSString
        var values: [NSRange] = []
        var consumedThrough = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard match.range.location >= consumedThrough else { continue }
            let quote = source.character(at: match.range(at: 2).location)
            let start = NSMaxRange(match.range)
            var cursor = start
            var escaped = false
            // Double quotes support backslash escapes. Within single quotes
            // backslashes are literal, so they must not swallow the closing
            // quote or the identity of an adjacent sensitive assignment.
            while cursor < source.length {
                let unit = source.character(at: cursor)
                if escaped { escaped = false }
                else if quote == 34 && unit == 92 { escaped = true }
                else if unit == quote { break }
                cursor += 1
            }
            if cursor > start { values.append(NSRange(location: start, length: cursor - start)) }
            consumedThrough = cursor < source.length ? cursor + 1 : source.length
        }
        var result = text
        for value in values.reversed() {
            guard let range = Range(value, in: result) else {
                return "[truncated output withheld]"
            }
            result.replaceSubrange(range, with: ContentSecretRedactor.mask(source.substring(with: value)))
        }
        return result
    }
}

public struct TerminalPolicy: Sendable {
    public let scopeID: String
    public let allowedRoot: URL
    public let additionalAllowedRoots: [String]
    public let deniedRoots: [String]
    public let snapshot: TerminalPolicySnapshot
    private let clock: @Sendable () -> Date

    public init(
        scopeID: String,
        allowedRoot: URL,
        additionalAllowedRoots: [String] = [],
        deniedRoots: [String] = [],
        now: @escaping @Sendable () -> Date = Date.init,
        snapshot: TerminalPolicySnapshot = .default
    ) {
        self.scopeID = scopeID
        self.allowedRoot = allowedRoot
        self.additionalAllowedRoots = additionalAllowedRoots
        self.deniedRoots = deniedRoots
        self.snapshot = snapshot
        clock = now
    }

    fileprivate func decision(for request: TerminalExecutionRequest) -> TerminalBoundaryError? {
        guard !request.context.sessionID.isEmpty,
              !request.context.turnID.isEmpty,
              !request.context.taskID.isEmpty,
              !request.context.projectID.isEmpty,
              !request.context.workdir.isEmpty else {
            return .contextUnavailable
        }
        guard request.capabilityID == "shell_execute" else { return .permissionDenied }
        guard request.context.projectID == scopeID else { return .scopeMismatch }
        guard let roots = canonicalRoots(),
              Self.pathIsAllowed(request.context.workdir, roots: roots) else {
            return .pathViolation
        }

        let trimmed = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unknown
        }
        let inspected = TerminalGuard.inspect(request.command)
        let disposition = snapshot.classify(command: request.command)
        if disposition == .denied { return .denied }
        // Expanding a variable in the executable position bypasses the
        // argument-only path check below. Refuse active expansion before an
        // approval can turn an unknown runtime value into a new command.
        if TerminalGuard.containsActiveDollar(request.command) { return .pathViolation }
        guard Self.argumentsStayWithinRoots(
            words: TerminalPolicySnapshot.policyWords(request.command, fallback: inspected.words),
            workdir: request.context.workdir,
            roots: roots,
            simpleSyntaxValidated: inspected.isAllowed
        ) else {
            return .pathViolation
        }
        if !inspected.isAllowed {
            return .approvalRequired
        }
        switch disposition {
        case .allowed: return nil
        case .confirmation: return .approvalRequired
        case .denied: return .denied
        case .unknown: return .approvalRequired
        }
    }

    fileprivate func approvalError(for request: TerminalExecutionRequest) -> TerminalBoundaryError? {
        guard let approval = request.approval else { return nil }
        if approval.cancelled { return .cancelled }
        guard approval.scopeID == scopeID else { return .scopeMismatch }
        guard clock() < approval.expiresAt else { return .approvalExpired }
        guard approval.requestFingerprint == request.requestFingerprint else { return .approvalDenied }
        return nil
    }

    private typealias CanonicalRoots = (allowed: [String], denied: [String])

    private func canonicalRoots() -> CanonicalRoots? {
        let allowed = [allowedRoot.path] + additionalAllowedRoots
        let canonicalAllowed = allowed.compactMap(Self.canonicalPath)
        let canonicalDenied = deniedRoots.compactMap(Self.canonicalPath)
        guard canonicalAllowed.count == allowed.count,
              canonicalDenied.count == deniedRoots.count,
              canonicalAllowed.allSatisfy({ $0 != "/" }) else {
            return nil
        }
        return (canonicalAllowed, canonicalDenied)
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return PolicyRuntimePathBoundary.canonicalPath(path)
    }

    private static func pathIsAllowed(_ path: String, roots: CanonicalRoots) -> Bool {
        guard let candidate = canonicalPath(path),
              roots.allowed.contains(where: { candidate == $0 || candidate.hasPrefix($0 + "/") }) else {
            return false
        }
        return !roots.denied.contains {
            PolicyRuntimePathBoundary.foldedCandidate(candidate, isWithin: $0)
        }
    }

    /// The visible terminal's local `cd` uses the same root and deny decision
    /// as a request that reaches the process boundary.
    public func allowsWorkingDirectory(_ path: String) -> Bool {
        guard let roots = canonicalRoots() else { return false }
        return Self.pathIsAllowed(path, roots: roots)
    }

    private static func argumentsStayWithinRoots(
        words: [String], workdir: String, roots: CanonicalRoots,
        simpleSyntaxValidated: Bool
    ) -> Bool {
        for word in words.dropFirst() {
            let value = word.firstIndex(of: "=").map { String(word[word.index(after: $0)...]) } ?? word
            // The shell can expand these into paths that the lexical guard
            // cannot prove safe, even when the visible token looks in scope.
            // In a validated simple command, a remaining dollar was quoted
            // or escaped; the original input was checked for active dollars
            // above. Only its literal-brace form needs the brace exception.
            // Keep unrelated brace/glob/path rules and compound syntax strict.
            let unsafeCharacters: String
            if simpleSyntaxValidated, word.contains("$") {
                unsafeCharacters = "`*?[]"
            } else if simpleSyntaxValidated {
                unsafeCharacters = "`*?[]{}"
            } else {
                unsafeCharacters = "$`*?[]{}"
            }
            guard !value.hasPrefix("~"),
                  !word.contains(where: { unsafeCharacters.contains($0) }) else { return false }
            if word.hasPrefix("-"), !word.contains("=") {
                guard !word.contains("/") else { return false }
                continue
            }
            let candidate = value.hasPrefix("/") ? value : workdir + "/" + value
            guard pathIsAllowed(candidate, roots: roots) else {
                return false
            }
        }
        return true
    }
}

private final class TerminalInvocationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var requestedError: TerminalBoundaryError?
    private var requestHandler: (@Sendable (TerminalBoundaryError) -> Void)?
    private var resolved = false

    func setRequestHandler(_ handler: @escaping @Sendable (TerminalBoundaryError) -> Void) {
        let pendingError: TerminalBoundaryError?
        lock.lock()
        requestHandler = handler
        pendingError = requestedError
        lock.unlock()
        if let pendingError {
            handler(pendingError)
        }
    }

    func install(_ task: Task<Void, Never>) {
        let cancelImmediately: Bool
        lock.lock()
        self.task = task
        cancelImmediately = resolved || requestedError != nil
        lock.unlock()
        if cancelImmediately {
            task.cancel()
        }
    }

    func request(_ error: TerminalBoundaryError) {
        let task: Task<Void, Never>?
        let handler: (@Sendable (TerminalBoundaryError) -> Void)?
        let shouldNotify: Bool
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        // A deadline cancels execution immediately, but its owned runner may
        // still return buffered output after bounded cleanup. Do not publish
        // a generic timeout before that result is available.
        shouldNotify = requestedError == nil && error != .timeout
        requestedError = requestedError ?? error
        task = self.task
        handler = shouldNotify ? requestHandler : nil
        lock.unlock()
        task?.cancel()
        if let handler {
            handler(error)
        }
    }

    var timeoutRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestedError == .timeout
    }

    func resolve() -> TerminalBoundaryError? {
        lock.lock()
        defer { lock.unlock() }
        resolved = true
        return requestedError
    }
}

private enum TerminalInvocationOutcome: @unchecked Sendable {
    case result(TerminalProcessResult)
    case timedOut(TerminalProcessResult)
    case failure(TerminalBoundaryError)
}

private final class TerminalOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TerminalInvocationOutcome, Never>?
    private var pendingOutcome: TerminalInvocationOutcome?

    func wait() async -> TerminalInvocationOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pendingOutcome {
                self.pendingOutcome = nil
                lock.unlock()
                continuation.resume(returning: pendingOutcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ outcome: TerminalInvocationOutcome) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: outcome)
        } else if pendingOutcome == nil {
            pendingOutcome = outcome
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}

public final class TerminalBoundary: @unchecked Sendable {
    private let policy: TerminalPolicy
    private let runner: any TerminalProcessRunner
    private let activeLock = NSLock()
    private var activeInvocation: TerminalInvocationControl?

    public init(policy: TerminalPolicy) {
        self.policy = policy
        runner = ProcessTerminalRunner()
    }

    public init(policy: TerminalPolicy, runner: any TerminalProcessRunner) {
        self.policy = policy
        self.runner = runner
    }

    /// Stops only the currently owned invocation. Repeated calls are idempotent;
    /// a later invocation gets a different control token and cannot be cancelled
    /// by a stale stop request.
    public func stop() {
        activeLock.lock()
        let invocation = activeInvocation
        activeLock.unlock()
        invocation?.request(.cancelled)
    }

    public func execute(_ request: TerminalExecutionRequest) async -> TerminalReceipt {
        if let error = policy.decision(for: request) {
            if error == .approvalRequired {
                guard request.approval != nil else {
                    return TerminalReceipt(request: request, error: error)
                }
            } else {
                return TerminalReceipt(request: request, error: error)
            }
        }
        if let error = policy.approvalError(for: request) {
            return TerminalReceipt(request: request, error: error)
        }
        if Task.isCancelled {
            return TerminalReceipt(request: request, error: .cancelled)
        }

        let invocation = TerminalInvocationControl()
        let previous = installActiveInvocation(invocation)
        previous?.request(.cancelled)
        defer {
            clearActiveInvocation(invocation)
        }

        return await withTaskCancellationHandler(operation: {
            await self.executeOwned(request, invocation: invocation)
        }, onCancel: {
            invocation.request(.cancelled)
        })
    }

    /// Install the new invocation through one synchronous lock scope.
    ///
    /// Returning after the unlock preserves the ordering contract at the
    /// async boundary: the new owner is visible before the previous owner is
    /// asked to cancel.
    private func installActiveInvocation(
        _ invocation: TerminalInvocationControl
    ) -> TerminalInvocationControl? {
        activeLock.lock()
        let previous = activeInvocation
        activeInvocation = invocation
        activeLock.unlock()
        return previous
    }

    private func executeOwned(
        _ request: TerminalExecutionRequest,
        invocation: TerminalInvocationControl
    ) async -> TerminalReceipt {
        let outcomeBox = TerminalOutcomeBox()
        invocation.setRequestHandler { error in
            outcomeBox.finish(.failure(error))
        }
        let runnerTask = Task {
            do {
                let result = try await TerminalRunnerCancellation.$isDeadline.withValue({ invocation.timeoutRequested }) {
                    try await self.runner.run(command: request.command,
                        workdir: URL(fileURLWithPath: request.context.workdir), timeout: request.timeout)
                }
                outcomeBox.finish(.result(result))
            } catch let error as TerminalProcessTimeout {
                outcomeBox.finish(.timedOut(error.result))
            } catch let error as TerminalBoundaryError {
                outcomeBox.finish(.failure(error))
            } catch is CancellationError {
                outcomeBox.finish(.failure(.cancelled))
            } catch {
                outcomeBox.finish(.failure(.executionFailed))
            }
        }
        invocation.install(runnerTask)

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: request.timeout)
                invocation.request(.timeout) // Stop execution now; retain its buffered output.
                try await Task.sleep(for: .seconds(ShellCommandTimeoutPolicy.cleanupSeconds))
                outcomeBox.finish(.failure(.timeout))
            } catch is CancellationError {
                // The runner completed first, so the deadline is no longer
                // relevant to this invocation.
            } catch {
                outcomeBox.finish(.failure(.timeout))
            }
        }
        let outcome = await withTaskCancellationHandler(operation: {
            await outcomeBox.wait()
        }, onCancel: {
            invocation.request(.cancelled)
            outcomeBox.finish(.failure(.cancelled))
        })
        timeoutTask.cancel()

        switch outcome {
        case .result(let result):
            if let error = invocation.resolve() {
                return TerminalReceipt(request: request, error: error)
            }
            return TerminalReceipt(request: request, result: result)
        case .timedOut(let result):
            if let error = invocation.resolve(), error != .timeout {
                return TerminalReceipt(request: request, error: error)
            }
            return TerminalReceipt(request: request, result: result, error: .timeout)
        case .failure(let error):
            // A cancel/timeout signal wins the receipt, but not the cleanup race.
            // Keep ownership until this runner has terminated/reaped its group
            // and drained its pipes; a later invocation retains its own fence.
            runnerTask.cancel()
            await runnerTask.value
            return TerminalReceipt(request: request, error: invocation.resolve() ?? error)
        }
    }

    /// Clear the owned invocation through a synchronous lock scope.
    ///
    /// `execute` is async, and Swift 6 rejects a direct `NSLock.unlock()` in
    /// its defer body. Keeping the complete lock/unlock pair in this
    /// synchronous helper preserves the existing identity fence and avoids
    /// holding the lock across any suspension point.
    private func clearActiveInvocation(_ invocation: TerminalInvocationControl) {
        activeLock.lock()
        defer { activeLock.unlock() }
        if activeInvocation === invocation {
            activeInvocation = nil
        }
    }
}

private enum TerminalRunnerCancellation {
    @TaskLocal static var isDeadline: (@Sendable () -> Bool)?
}

private struct TerminalProcessTimeout: Error {
    let result: TerminalProcessResult
}

private struct TerminalPOSIXSpawnError: Error {
    let errno: Int32
}

private struct ProcessTerminalRunner: TerminalProcessRunner {
    private struct SpawnedShell {
        let owner: TerminalOwnedSession
        let stdout: FileHandle
        let stderr: FileHandle
    }

    private enum WatchdogResult: Sendable {
        case exited(Int32)
        case timedOut
    }

    private static let maximumCapturedBytes = 64 * 1024
    private static let processTerminationGrace: TimeInterval = 2
    private static let pipeDrainGrace: TimeInterval = 3

    func run(command: String, workdir: URL, timeout: Duration) async throws -> TerminalProcessResult {
        try Task.checkCancellation()
        let shell: SpawnedShell
        do { shell = try Self.spawnShell(command: command, currentDirectory: workdir) }
        catch { throw TerminalBoundaryError.spawnFailed }
        let owner = shell.owner
        let timeoutInterval = Self.timeInterval(timeout)
        let captureInterval = timeoutInterval + 2 * Self.processTerminationGrace + Self.pipeDrainGrace
        let stdoutTask = Self.makePipeReader(shell.stdout, timeout: captureInterval,
                                            owner: owner, pipe: .stdout)
        let stderrTask = Self.makePipeReader(shell.stderr, timeout: captureInterval,
                                            owner: owner, pipe: .stderr)
        // Transfer the actual owned read handles to the readers; no dup failure can
        // strand an unarmed pipe after creating a suspended child.
        let deadline = Date().addingTimeInterval(timeoutInterval)
        let watchdog = Task.detached(priority: .userInitiated) {
            while true {
                if let status = owner.observeExitWithoutReaping() { return WatchdogResult.exited(status) }
                if Date() >= deadline { return WatchdogResult.timedOut }
                _ = owner.resumeIfVerified()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let watchdogResult = await withTaskCancellationHandler(operation: {
            await watchdog.value
        }, onCancel: {
            // The reader closes its own handle after leaving its poll/read;
            // cancellation never closes a different thread's FileHandle.
            owner.requestReaderStopForControl()
            owner.requestTermination(force: true)
        })
        let cancelled = Task.isCancelled
        let deadlineCancellation = cancelled && (TerminalRunnerCancellation.isDeadline?() == true)
        // Every cleanup route uses this same owner; coalescing happens under its lock.
        if cancelled {
            owner.requestReaderStopForControl()
            owner.requestTermination(force: true)
        } else if case .timedOut = watchdogResult {
            owner.requestReaderStopForControl()
            owner.requestTermination(force: false)
        } else {
            owner.requestTermination(force: true)
        }
        // A detached cleanup task is actually joined. Cancellation cannot turn its
        // sleeps into a busy loop or abandon the child/pipes. No signal after final reap.
        let cleanup = Task.detached {
            let escalation = Date().addingTimeInterval(Self.processTerminationGrace)
            while owner.reapAfterEOFAndGroupQuiescence() == nil {
                // Keep pumping guarded delivery while both detached readers continue.
                // Awaiting a reader before a failed first signal could otherwise deadlock.
                if case .timedOut = watchdogResult, !cancelled, Date() < escalation {
                    owner.requestTermination(force: false)
                } else {
                    owner.requestTermination(force: true)
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return (await stdoutTask.value, await stderrTask.value)
        }
        let (stdout, stderr) = await cleanup.value
        if cancelled && !deadlineCancellation { throw CancellationError() }
        let timedOut: Bool
        if case .timedOut = watchdogResult { timedOut = true } else { timedOut = deadlineCancellation }
        if timedOut {
            throw TerminalProcessTimeout(result: TerminalProcessResult(exitCode: -1,
                stdout: Self.capturedText(stdout), stderr: Self.capturedText(stderr),
                outputWasTruncated: stdout.wasTruncated || stderr.wasTruncated))
        }
        guard !owner.wasAbortedBeforeResume(), stdout.reachedEOF, stderr.reachedEOF,
              stdout.ioFailure == nil, stderr.ioFailure == nil,
              !stdout.drainDeadlineExceeded, !stderr.drainDeadlineExceeded else {
            throw TerminalBoundaryError.executionFailed
        }
        guard case .exited(let status) = watchdogResult else {
            throw TerminalBoundaryError.executionFailed
        }
        return TerminalProcessResult(exitCode: Self.shellExitCode(status),
            stdout: Self.capturedText(stdout), stderr: Self.capturedText(stderr),
            outputWasTruncated: stdout.wasTruncated || stderr.wasTruncated)
    }

    private static func capturedText(_ capture: TerminalPipeCapture) -> String {
        let binaryMarker = "[binary output omitted]"
        if let text = String(data: capture.data, encoding: .utf8) {
            return text.contains("\0") ? binaryMarker : text
        }
        guard capture.wasTruncated,
              let prefix = completeUTF8Prefix(capture.data),
              let text = String(data: prefix, encoding: .utf8),
              !text.contains("\0") else {
            return binaryMarker
        }
        return text
    }

    /// A byte cap may stop after one to three bytes of a valid UTF-8 scalar.
    /// Only remove that incomplete suffix; malformed bytes elsewhere remain
    /// binary and are never sent to the text redactor or visible receipt.
    private static func completeUTF8Prefix(_ data: Data) -> Data? {
        for count in 1...min(3, data.count) {
            let suffix = Array(data.suffix(count))
            let lead = suffix[0]
            let width: Int
            switch lead {
            case 0xC2...0xDF: width = 2
            case 0xE0...0xEF: width = 3
            case 0xF0...0xF4: width = 4
            default: continue
            }
            guard count < width,
                  suffix.dropFirst().allSatisfy({ ($0 & 0xC0) == 0x80 }) else { continue }
            if count > 1 {
                let second = suffix[1]
                if (lead == 0xE0 && second < 0xA0)
                    || (lead == 0xED && second >= 0xA0)
                    || (lead == 0xF0 && second < 0x90)
                    || (lead == 0xF4 && second > 0x8F) { continue }
            }
            let prefix = Data(data.dropLast(count))
            if String(data: prefix, encoding: .utf8) != nil { return prefix }
        }
        return nil
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        let seconds = Double(components.seconds)
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return max(0.001, seconds + attoseconds)
    }

    private static func spawnShell(command: String, currentDirectory: URL) throws -> SpawnedShell {
        // Check the actual lifetime policy before creating a child; no global signal mutation.
        try DarwinTerminalOwnershipKernel().assertWaitableChildPolicy()
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            closePipes(stdoutPipe, stderrPipe)
            throw TerminalPOSIXSpawnError(errno: errno)
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closePipes(stdoutPipe, stderrPipe)
            throw TerminalPOSIXSpawnError(errno: errno)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let actionResult = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]),
            posix_spawn_file_actions_addclose(&actions, stderrPipe[0]),
            posix_spawn_file_actions_addclose(&actions, stderrPipe[1]),
        ].first { $0 != 0 }
        guard actionResult == nil else {
            closePipes(stdoutPipe, stderrPipe)
            throw TerminalPOSIXSpawnError(errno: actionResult ?? EINVAL)
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            closePipes(stdoutPipe, stderrPipe)
            throw TerminalPOSIXSpawnError(errno: errno)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session itself creates PGID=SID=PID. Do not combine with SETPGROUP.
        // Start suspended so generation/session/image admission precedes command execution.
        let flagsResult = posix_spawnattr_setflags(&attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_START_SUSPENDED))
        guard flagsResult == 0 else {
            closePipes(stdoutPipe, stderrPipe)
            throw TerminalPOSIXSpawnError(errno: flagsResult)
        }

        let chdirResult = currentDirectory.path.withCString {
            posix_spawn_file_actions_addchdir_np(&actions, $0)
        }
        guard chdirResult == 0 else {
            closePipes(stdoutPipe, stderrPipe)
            throw TerminalPOSIXSpawnError(errno: chdirResult)
        }

        var pid: pid_t = 0
        let spawnResult: Int32 = "/bin/zsh".withCString { executable in
            "-c".withCString { flag in
                command.withCString { commandCString in
                    var argv: [UnsafeMutablePointer<CChar>?] = [
                        UnsafeMutablePointer(mutating: executable),
                        UnsafeMutablePointer(mutating: flag),
                        UnsafeMutablePointer(mutating: commandCString),
                        nil,
                    ]
                    return argv.withUnsafeMutableBufferPointer { buffer in
                        ModelShellEnvironment.withCStringVector { environment in
                            posix_spawn(
                                &pid,
                                executable,
                                &actions,
                                &attributes,
                                buffer.baseAddress,
                                environment
                            )
                        }
                    }
                }
            }
        }
        guard spawnResult == 0 else {
            closePipes(stdoutPipe, stderrPipe)
            throw TerminalPOSIXSpawnError(errno: spawnResult)
        }
        close(stdoutPipe[1])
        close(stderrPipe[1])
        return SpawnedShell(
            owner: TerminalOwnedSession(pid: pid),
            stdout: FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true),
            stderr: FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
        )
    }

    private static func closePipes(_ stdout: [Int32], _ stderr: [Int32]) {
        for descriptor in stdout + stderr where descriptor >= 0 {
            close(descriptor)
        }
    }

    private static func makePipeReader(_ handle: FileHandle, timeout: TimeInterval,
                                       owner: TerminalOwnedSession,
                                       pipe: TerminalOwnedPipe) -> Task<TerminalPipeCapture, Never> {
        let io = TerminalFileHandlePipeIO(handle)
        // Owner strongly retains the original handle until a confirmed close.
        owner.recordReaderArmed(pipe, io: io)
        return Task.detached(priority: .userInitiated) {
            await withCheckedContinuation { continuation in
                // Blocking poll/read belongs to a dedicated thread, leaving
                // cooperative workers available for resume/watchdog/cleanup.
                // Cancellation still uses the same owner's stop request;
                // capture owns the only handle-close attempt and completion.
                let thread = Thread {
                    let captured = TerminalOwnedPipeReader.capture(io, owner: owner, pipe: pipe,
                        maxBytes: maximumCapturedBytes, timeout: timeout)
                    continuation.resume(returning: captured)
                }
                thread.name = "com.miniscanvas.terminal.pipe-reader"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        }
    }

    private static func shellExitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        if signal != 0x7f {
            return 128 + signal
        }
        return status
    }

}

struct TerminalPipeCapture: Sendable {
    var data = Data()
    var wasTruncated = false
    var reachedEOF = false
    var stoppedByControl = false // Actual owned read close, never an EOF claim.
    var ioFailure: Int32?
    var drainDeadlineExceeded = false
}

enum TerminalPipePoll: Sendable { case ready, idle, interrupted, failed(Int32) }

// Thin I/O seam for the existing reader; a scripted fake never owns an OS FD.
// An integer descriptor is diagnostic metadata only, never a close capability.
protocol TerminalPipeIO: AnyObject, Sendable {
    var diagnosticDescriptor: Int32 { get }
    func pollNext() -> TerminalPipePoll
    func readChunk(maxBytes: Int) throws -> Data?
    func closeOwnedHandle() throws
}

private final class TerminalFileHandlePipeIO: TerminalPipeIO, @unchecked Sendable {
    private let handle: FileHandle
    let diagnosticDescriptor: Int32
    init(_ handle: FileHandle) {
        self.handle = handle
        diagnosticDescriptor = handle.fileDescriptor
    }
    func pollNext() -> TerminalPipePoll {
        var descriptor = pollfd(fd: diagnosticDescriptor,
            events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = poll(&descriptor, 1, 50)
        if ready < 0 { return errno == EINTR ? .interrupted : .failed(errno) }
        if ready == 0 { return .idle }
        if descriptor.revents & Int16(POLLNVAL) != 0 { return .failed(EBADF) }
        if descriptor.revents & Int16(POLLERR) != 0 { return .failed(EIO) }
        return .ready
    }
    func readChunk(maxBytes: Int) throws -> Data? { try handle.read(upToCount: maxBytes) }
    func closeOwnedHandle() throws { try handle.close() }
}

enum TerminalOwnedPipeReader {
    static func capture(_ io: any TerminalPipeIO, owner: TerminalOwnedSession,
                        pipe: TerminalOwnedPipe, maxBytes: Int, timeout: TimeInterval,
                        now: () -> Date = Date.init,
                        pauseAfterFailure: () -> Void = { usleep(50_000) }) -> TerminalPipeCapture {
        var captured = TerminalPipeCapture()
        let deadline = now().addingTimeInterval(timeout)
        while true {
            if owner.shouldStopReadersForControl() {
                captured.stoppedByControl = true
                owner.recordReaderStoppedByControl(pipe)
                break
            }
            // Neither cancellation nor a deadline is EOF. Record the first
            // deadline transition while the retained owner/reader keeps draining.
            if now() >= deadline, !captured.drainDeadlineExceeded {
                captured.drainDeadlineExceeded = true
                owner.recordPipeFault(pipe, phase: .drainDeadline,
                                      domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
            }
            switch io.pollNext() {
            case .idle, .interrupted: continue
            case .failed(let code):
                captured.ioFailure = code
                owner.recordPipeFault(pipe, phase: .poll,
                                      domain: NSPOSIXErrorDomain, code: Int(code))
                pauseAfterFailure()
                continue
            case .ready: break
            }
            do {
                guard let chunk = try io.readChunk(maxBytes: 64 * 1024), !chunk.isEmpty else {
                    captured.reachedEOF = true
                    owner.recordEOFObserved(pipe)
                    break
                }
                let remaining = max(0, maxBytes - captured.data.count)
                if chunk.count > remaining { captured.wasTruncated = true }
                captured.data.append(chunk.prefix(remaining))
            } catch {
                captured.ioFailure = EIO
                let failure = error as NSError
                owner.recordPipeFault(pipe, phase: .read,
                                      domain: failure.domain, code: failure.code)
                pauseAfterFailure()
            }
        }
        do {
            try io.closeOwnedHandle() // Exactly one attempt; never close a bare FD.
            owner.recordReaderClosed(pipe)
        } catch {
            captured.ioFailure = EIO
            let failure = error as NSError
            owner.recordPipeFault(pipe, phase: .close,
                                  domain: failure.domain, code: failure.code)
            // close throwing proves neither open nor closed. Owner retains io;
            // no numeric-FD retry and no ARC/deinit assumed to be close evidence.
        }
        owner.recordReaderFinished(pipe)
        return captured
    }
}

// DRAFT ONLY: not compiled, not runtime-qualified. See design/OWNER_PROOF.md.
// All real wait/reap/signal operations for one spawned shell live behind one lock.
// Internal contract: no code outside this owner consumes this private child. The exact
// compiled product/fixture scan finds no global reaper; hypothetical hostile same-process
// code is not a new cross-process threat model. An observed custom SIGCHLD policy is
// rejected without mutating it. No independent guardian/runtime is introduced.
// A snapshot is NOT the authority: a private session plus an unreaped direct-child
// leader pins the numeric group until the final reap, after which signaling is sealed.
struct TerminalProcessIdentity: Sendable, Equatable {
    let pid: pid_t
    let parent: pid_t
    let uid: uid_t
    let group: pid_t
    let session: pid_t
    let birthSeconds: UInt64
    let birthMicroseconds: UInt64
    let zombie: Bool
}

enum TerminalOwnershipError: Error {
    case syscall(String, Int32)
    case invalid(String)
    case childPinLost
}

protocol TerminalOwnershipKernel: Sendable {
    func assertWaitableChildPolicy() throws
    func identity(_ pid: pid_t) throws -> TerminalProcessIdentity?
    func executable(_ pid: pid_t) throws -> String
    // nil means a still-waitable direct child has no exit event, NOT ECHILD.
    func peekExitWithoutReaping(_ pid: pid_t) throws -> Int32?
    func members(_ group: pid_t) throws -> [pid_t]
    func signal(_ target: pid_t, _ value: Int32) throws
    func reapOnlyThisChild(_ pid: pid_t) throws -> Int32?
}

private struct DarwinTerminalOwnershipKernel: TerminalOwnershipKernel {
    func assertWaitableChildPolicy() throws {
        var disposition = sigaction()
        guard sigaction(SIGCHLD, nil, &disposition) == 0 else {
            throw TerminalOwnershipError.syscall("query SIGCHLD", errno)
        }
        guard disposition.sa_flags & SA_NOCLDWAIT == 0 else {
            throw TerminalOwnershipError.invalid("SIGCHLD auto-reap invalidates child pin")
        }
        // Only default is qualified here; do not rewrite another subsystem's disposition.
        // A real custom handler would need evidence that it cannot consume this child.
        if case .some = disposition.__sigaction_u.__sa_handler {
            throw TerminalOwnershipError.invalid("nondefault SIGCHLD waiter not qualified")
        }
    }
    func identity(_ pid: pid_t) throws -> TerminalProcessIdentity? {
        var info = proc_bsdinfo()
        errno = 0
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                               Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            if errno == ESRCH { return nil }
            throw TerminalOwnershipError.syscall("proc_pidinfo", errno)
        }
        let session = getsid(pid)
        guard session >= 0 else {
            if errno == ESRCH { return nil }
            throw TerminalOwnershipError.syscall("getsid", errno)
        }
        return TerminalProcessIdentity(pid: pid_t(info.pbi_pid), parent: pid_t(info.pbi_ppid),
            uid: info.pbi_uid, group: pid_t(info.pbi_pgid), session: session,
            birthSeconds: info.pbi_start_tvsec, birthMicroseconds: info.pbi_start_tvusec,
            zombie: info.pbi_status == UInt32(SZOMB))
    }
    func executable(_ pid: pid_t) throws -> String {
        var bytes = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        let count = bytes.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard count > 0 else { throw TerminalOwnershipError.syscall("proc_pidpath", errno) }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func peekExitWithoutReaping(_ pid: pid_t) throws -> Int32? {
        var info = siginfo_t() // si_pid must start at zero for WNOHANG.
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
            if errno == ECHILD { throw TerminalOwnershipError.childPinLost }
            throw TerminalOwnershipError.syscall("waitid WNOWAIT", errno)
        }
        guard info.si_pid != 0 else { return nil }
        guard info.si_pid == pid else { throw TerminalOwnershipError.invalid("wrong wait child") }
        switch info.si_code {
        case CLD_EXITED: return info.si_status << 8
        case CLD_KILLED, CLD_DUMPED: return info.si_status & 0x7f
        case CLD_STOPPED:
            // Darwin reports the new START_SUSPENDED child's non-exit stop
            // even for WEXITED|WNOHANG|WNOWAIT. Keep its waitable pin; only an
            // actual terminal event may become an exit status or final reap.
            return nil
        default:
            throw TerminalOwnershipError.invalid("unexpected wait event pid=\(info.si_pid) code=\(info.si_code) status=\(info.si_status) signo=\(info.si_signo)")
        }
    }
    func members(_ group: pid_t) throws -> [pid_t] {
        // Use proc_listpids byte-count API, not proc_listpgrppids' PID-count API.
        var capacity = 32
        while capacity <= 65_536 {
            var pids = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let bytes = pids.withUnsafeMutableBytes { buffer in
                proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group),
                              buffer.baseAddress, Int32(buffer.count))
            }
            guard bytes >= 0, !(bytes == 0 && errno != 0),
                  Int(bytes) % MemoryLayout<pid_t>.stride == 0 else {
                throw TerminalOwnershipError.syscall("proc_listpids group", errno)
            }
            let count = Int(bytes) / MemoryLayout<pid_t>.stride
            if count < capacity { return Array(pids.prefix(count)).filter { $0 > 0 } }
            capacity *= 2 // Full buffer is not evidence of a complete membership set.
        }
        throw TerminalOwnershipError.invalid("membership buffer truncated")
    }
    func signal(_ target: pid_t, _ value: Int32) throws {
        // The only actual kill syscall in the runner; caller is the locked owner.
        guard Darwin.kill(target, value) == 0 else {
            if errno == ESRCH { return } // The pinned group may have become empty.
            throw TerminalOwnershipError.syscall("owned signal", errno)
        }
    }
    func reapOnlyThisChild(_ pid: pid_t) throws -> Int32? {
        var status: Int32 = 0
        let observed = waitpid(pid, &status, WNOHANG)
        if observed == pid { return status }
        if observed == 0 { return nil }
        if errno == ECHILD { throw TerminalOwnershipError.childPinLost }
        throw TerminalOwnershipError.syscall("final waitpid", errno)
    }
}

enum TerminalOwnedPipe: String, Hashable, Sendable { case stdout, stderr }
enum TerminalPipeFailurePhase: String, Sendable, Equatable { case poll, read, close, drainDeadline }
struct TerminalPipeFault: Sendable, Equatable {
    let phase: TerminalPipeFailurePhase
    let domain: String
    let code: Int
}
struct TerminalPipeState: Sendable, Equatable {
    let descriptor: Int32
    var reachedEOF = false
    var stoppedByControl = false
    var closeConfirmed = false
    var readerFinished = false
    var leaseRetained = true
    var faults: [TerminalPipeFault] = []
    var observedFailureCount = 0
    var faultListTruncated = false
}
struct TerminalOwnershipSnapshot: Sendable {
    let invocation: UUID
    let pid: pid_t
    let resumed: Bool
    let requestedStrength: Int
    let sentStrength: Int
    let finalReapStarted: Bool
    let finalStatus: Int32?
    let holdReason: String?
    let members: [TerminalProcessIdentity]
    let pipes: [TerminalOwnedPipe: TerminalPipeState]
}
struct TerminalOwnershipDiagnostic: Sendable {
    let snapshot: TerminalOwnershipSnapshot
    let changedPipe: TerminalOwnedPipe?
    // Only fixed lifecycle labels, UUID, numeric identity and structured error
    // domain/code; never command, output, workdir, or NSError userInfo.
    var message: String {
        let state = snapshot
        let lifecycle = state.finalStatus == nil ? "HOLD" : "FAILED_RETIRED"
        var text = "\(lifecycle) invocation=\(state.invocation) pid=\(state.pid) sealed=\(state.finalReapStarted) reason=\(state.holdReason ?? "unknown")"
        if let pipe = changedPipe, let io = state.pipes[pipe] {
            let fault = io.faults.last
            text += " pipe=\(pipe.rawValue) fd=\(io.descriptor) eof=\(io.reachedEOF) stoppedByControl=\(io.stoppedByControl) closeConfirmed=\(io.closeConfirmed) readerFinished=\(io.readerFinished) leaseRetained=\(io.leaseRetained) phase=\(fault?.phase.rawValue ?? "none") domain=\(fault?.domain ?? "none") code=\(fault?.code ?? 0) faultCount=\(io.observedFailureCount) faultListTruncated=\(io.faultListTruncated)"
        }
        return text
    }
}

final class TerminalOwnedSession: @unchecked Sendable {
    private let lock = NSLock()
    private let kernel: any TerminalOwnershipKernel
    let pid: pid_t
    let invocation = UUID()
    private let parent: pid_t
    private let uid: uid_t
    private var admitted: TerminalProcessIdentity?
    private var membersSeen: [String: TerminalProcessIdentity] = [:]
    private var pipeLeases: [TerminalOwnedPipe: any TerminalPipeIO] = [:]
    private var pipeStates: [TerminalOwnedPipe: TerminalPipeState] = [:]
    private let diagnosticSink: @Sendable (TerminalOwnershipDiagnostic) -> Void
    private var pendingDiagnostics: [TerminalOwnershipDiagnostic] = []
    private var resumed = false
    private var abortedBeforeResume = false
    private var requestedStrength = 0
    private var sentStrength = 0
    private var pinLost = false
    private var readerStopRequested = false
    private var finalReapStarted = false
    private var finalStatus: Int32?
    private var lastHoldReason: String?

    init(pid: pid_t, parent: pid_t = getpid(), uid: uid_t = geteuid(),
         kernel: any TerminalOwnershipKernel,
         diagnosticSink: @escaping @Sendable (TerminalOwnershipDiagnostic) -> Void = {
             LogManager.shared.log(level: .error, category: "TerminalOwnership",
                 message: $0.message, eventID: "terminal-ownership-\($0.snapshot.invocation)")
         }) {
        self.pid = pid; self.parent = parent; self.uid = uid; self.kernel = kernel
        self.diagnosticSink = diagnosticSink
    }
    convenience init(pid: pid_t) {
        self.init(pid: pid, kernel: DarwinTerminalOwnershipKernel())
    }
    private func locked<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock()
        defer {
            let reports = pendingDiagnostics
            pendingDiagnostics.removeAll(keepingCapacity: true)
            lock.unlock()
            // Existing LogManager or an injected pure observer runs outside the
            // ownership lock; diagnostic callbacks cannot deadlock signal/reap.
            for report in reports { diagnosticSink(report) }
        }
        return try action()
    }
    private func recordHold(_ error: Error) {
        if let typed = error as? TerminalOwnershipError, case .childPinLost = typed { pinLost = true }
        let reason = String(describing: error)
        if lastHoldReason != reason {
            lastHoldReason = reason
            pendingDiagnostics.append(TerminalOwnershipDiagnostic(snapshot: snapshotLocked(), changedPipe: nil))
        }
    }
    private func admitLocked() throws {
        guard !pinLost, !finalReapStarted else { throw TerminalOwnershipError.childPinLost }
        try kernel.assertWaitableChildPolicy()
        _ = try kernel.peekExitWithoutReaping(pid) // Own direct child; never consumes its pin.
        if admitted != nil { return }
        guard let born = try kernel.identity(pid), born.pid == pid, born.parent == parent,
              born.uid == uid, born.session == pid, born.group == pid,
              born.birthSeconds > 0, !born.zombie,
              try kernel.executable(pid) == "/bin/zsh",
              try Set(kernel.members(pid)) == Set([pid]) else {
            throw TerminalOwnershipError.invalid("suspended private-session admission")
        }
        admitted = born; rememberLocked(born)
    }
    private func validatePinnedGroupLocked() throws -> [TerminalProcessIdentity] {
        try admitLocked()
        let exit = try kernel.peekExitWithoutReaping(pid)
        guard let born = admitted else { throw TerminalOwnershipError.invalid("missing born identity") }
        if let now = try kernel.identity(pid) {
            guard now.pid == born.pid, now.uid == born.uid,
                  now.birthSeconds == born.birthSeconds,
                  now.birthMicroseconds == born.birthMicroseconds,
                  now.group == pid, now.session == pid else {
                throw TerminalOwnershipError.invalid("leader generation/session changed")
            }
        } else if exit == nil {
            throw TerminalOwnershipError.invalid("leader vanished without a pinned exit event")
        }
        var observed: [TerminalProcessIdentity] = []
        for member in try kernel.members(pid) {
            if member == pid { continue } // Already checked or held by its waitable exit pin.
            guard let info = try kernel.identity(member), info.group == pid,
                  info.session == pid, info.uid == uid else {
                throw TerminalOwnershipError.invalid("member identity/session unavailable")
            }
            // New members within this private session are descendants, not external joiners.
            // Their generation is recorded, but a snapshot is not used as the group capability.
            rememberLocked(info); observed.append(info)
        }
        return observed
    }
    private func rememberLocked(_ identity: TerminalProcessIdentity) {
        let key = "\(identity.pid):\(identity.birthSeconds):\(identity.birthMicroseconds)"
        membersSeen[key] = identity
    }
    func recordReaderArmed(_ pipe: TerminalOwnedPipe, io: any TerminalPipeIO) {
        locked {
            guard pipeStates[pipe] == nil else {
                recordHold(TerminalOwnershipError.invalid("duplicate pipe owner")); return
            }
            pipeLeases[pipe] = io
            pipeStates[pipe] = TerminalPipeState(descriptor: io.diagnosticDescriptor)
        }
    }
    func requestReaderStopForControl() {
        locked { readerStopRequested = true }
    }
    func shouldStopReadersForControl() -> Bool {
        locked { readerStopRequested }
    }
    func recordReaderStoppedByControl(_ pipe: TerminalOwnedPipe) {
        locked {
            guard readerStopRequested else {
                recordHold(TerminalOwnershipError.invalid("reader stop without cancellation/timeout")); return
            }
            pipeStates[pipe]?.stoppedByControl = true
        }
    }
    func recordEOFObserved(_ pipe: TerminalOwnedPipe) {
        locked { pipeStates[pipe]?.reachedEOF = true }
    }
    func recordReaderClosed(_ pipe: TerminalOwnedPipe) {
        locked {
            pipeStates[pipe]?.closeConfirmed = true
            pipeStates[pipe]?.leaseRetained = false
            pipeLeases[pipe] = nil // Release only after actual close succeeded.
        }
    }
    func recordPipeFault(_ pipe: TerminalOwnedPipe, phase: TerminalPipeFailurePhase,
                         domain: String, code: Int) {
        locked {
            guard var state = pipeStates[pipe] else {
                recordHold(TerminalOwnershipError.invalid("pipe fault without owner")); return
            }
            let fault = TerminalPipeFault(phase: phase, domain: domain, code: code)
            state.observedFailureCount += 1
            let changed = !state.faults.contains(fault)
            let publish = changed && (state.faults.count < 32 || !state.faultListTruncated)
            if changed {
                if state.faults.count < 32 { state.faults.append(fault) }
                else { state.faultListTruncated = true }
            }
            pipeStates[pipe] = state
            lastHoldReason = "pipe.\(phase.rawValue) domain=\(domain) code=\(code)"
            if publish { pendingDiagnostics.append(TerminalOwnershipDiagnostic(
                snapshot: snapshotLocked(), changedPipe: pipe)) }
        }
    }
    func recordReaderFinished(_ pipe: TerminalOwnedPipe) {
        locked {
            pipeStates[pipe]?.readerFinished = true
            if pipeStates[pipe]?.faults.isEmpty == false {
                pendingDiagnostics.append(TerminalOwnershipDiagnostic(
                    snapshot: snapshotLocked(), changedPipe: pipe))
            }
        }
    }
    func resumeIfVerified() -> Bool {
        locked {
            if resumed { return true }
            guard !abortedBeforeResume, requestedStrength == 0, pipeLeases.count == 2 else { return false }
            do {
                try admitLocked()
                try kernel.signal(pid, SIGCONT)
                resumed = true; return true
            } catch {
                recordHold(error)
                // The command has never run. Admission failure grants no group
                // authority; retain and retire only the waitable direct child.
                abortBeforeResumeLocked()
                return false
            }
        }
    }
    func requestTermination(force: Bool) {
        locked {
            requestedStrength = max(requestedStrength, force ? 2 : 1)
            guard !pinLost, !finalReapStarted else { return }
            if !resumed { abortBeforeResumeLocked(); return }
            guard sentStrength < requestedStrength else { return }
            do {
                _ = try validatePinnedGroupLocked()
                try kernel.signal(-pid, requestedStrength == 2 ? SIGKILL : SIGTERM)
                sentStrength = requestedStrength
            } catch { recordHold(error) }
        }
    }
    // Caller holds the same owner lock. Before SIGCONT the executable cannot
    // create descendants. Successful spawn plus the nonconsumed P_PID wait is
    // the direct-child capability even when optional proc/session admission fails.
    private func abortBeforeResumeLocked() {
        guard !resumed, !pinLost, !finalReapStarted else { return }
        abortedBeforeResume = true
        requestedStrength = 2
        guard sentStrength < 2 else { return }
        do {
            if try kernel.peekExitWithoutReaping(pid) == nil {
                try kernel.signal(pid, SIGKILL) // Positive, pinned direct child only.
            }
            sentStrength = 2
        } catch { recordHold(error) }
    }
    func wasAbortedBeforeResume() -> Bool { locked { abortedBeforeResume } }
    func observeExitWithoutReaping() -> Int32? {
        locked {
            if let finalStatus { return finalStatus }
            guard !pinLost, !finalReapStarted else { return nil }
            do { return try kernel.peekExitWithoutReaping(pid) }
            catch { recordHold(error); return nil }
        }
    }
    func reapAfterEOFAndGroupQuiescence() -> Int32? {
        locked {
            if let finalStatus { return finalStatus }
            guard !pinLost, pipeStates.count == 2,
                  // Control-stop is a distinct terminal read state, not EOF.
                  // Both paths still require real same-reader close + finish.
                  pipeStates.values.allSatisfy({ ($0.reachedEOF || $0.stoppedByControl)
                      && $0.closeConfirmed && $0.readerFinished })
            else { return nil }
            do {
                if !finalReapStarted {
                    guard try kernel.peekExitWithoutReaping(pid) != nil else { return nil }
                    if resumed {
                        let members = try validatePinnedGroupLocked()
                        // Original child-gone contract requires disappearance, not merely SZOMB.
                        guard members.isEmpty else { return nil }
                        for known in membersSeen.values where known.pid != pid {
                            if let now = try kernel.identity(known.pid),
                               now.birthSeconds == known.birthSeconds,
                               now.birthMicroseconds == known.birthMicroseconds {
                                // A previously observed child may have escaped the original group
                                // or still await its own parent/reparent reaper, even as SZOMB.
                                // No PID-only fallback, no falsely completed cleanup.
                                return nil
                            }
                        }
                    } else {
                        // Never resumed: no command-created member exists; do not
                        // pretend failed group admission succeeded merely to reap.
                        guard abortedBeforeResume else { return nil }
                    }
                    // Seal every later signal BEFORE releasing the numeric PID pin.
                    finalReapStarted = true
                }
                finalStatus = try kernel.reapOnlyThisChild(pid)
                if finalStatus != nil, pipeStates.values.contains(where: { !$0.faults.isEmpty }) {
                    pendingDiagnostics.append(TerminalOwnershipDiagnostic(
                        snapshot: snapshotLocked(), changedPipe: nil))
                }
                return finalStatus
            } catch { recordHold(error); return nil }
        }
    }
    private func snapshotLocked() -> TerminalOwnershipSnapshot {
        TerminalOwnershipSnapshot(invocation: invocation, pid: pid, resumed: resumed,
            requestedStrength: requestedStrength, sentStrength: sentStrength,
            finalReapStarted: finalReapStarted, finalStatus: finalStatus, holdReason: lastHoldReason,
            members: Array(membersSeen.values), pipes: pipeStates)
    }
    func auditState() -> TerminalOwnershipSnapshot { locked { snapshotLocked() } }
}
