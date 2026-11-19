import Foundation

// MARK: - Goal18 Hooks: user config, project config and the project trust gate

/// What the project hooks file currently is, relative to the user's trust record.
public struct ProjectHooksSnapshot: Sendable, Equatable {
    public enum Trust: Sendable, Equatable {
        /// No `.miniscanvas/hooks.json` in this project.
        case noFile
        /// The project hooks cannot be used (symlink, too large, malformed,
        /// duplicate ids, or a hooks directory over its file-count/size limit).
        case invalid(String)
        /// Never trusted, or trusted at a different content hash (`changedSinceTrust`).
        case untrusted(changedSinceTrust: Bool)
        case trusted
    }

    public let projectRoot: String
    /// Hash over `hooks.json` and every file under `.miniscanvas/hooks/`.
    public let contentHash: String?
    /// Parsed definitions, shown for review even while untrusted. Never executed
    /// unless `trust == .trusted`.
    public let hooks: [HookDefinition]
    public let trust: Trust
    /// Files under `.miniscanvas/hooks/` that the hash covers (relative paths).
    public let protectedScriptFiles: [String]
    /// Hook id -> project paths its command references outside the protected
    /// directory. Such hooks never run: edits to those files would not change
    /// the trust hash.
    public let outsideReferences: [String: [String]]

    public init(
        projectRoot: String,
        contentHash: String?,
        hooks: [HookDefinition],
        trust: Trust,
        protectedScriptFiles: [String] = [],
        outsideReferences: [String: [String]] = [:]
    ) {
        self.projectRoot = projectRoot
        self.contentHash = contentHash
        self.hooks = hooks
        self.trust = trust
        self.protectedScriptFiles = protectedScriptFiles
        self.outsideReferences = outsideReferences
    }

    public var executableHooks: [HookDefinition] {
        guard trust == .trusted else { return [] }
        return hooks.filter { $0.enabled && $0.isRunnable && outsideReferences[$0.id] == nil }
    }

    public var needsTrustDecision: Bool {
        if case .untrusted = trust { return true }
        return false
    }
}

public enum HookConfigStoreError: Error, Equatable, Sendable {
    case invalidDefinition
    case duplicateID
    case notFound
    case invalidProjectRoot
    /// The file changed after the user reviewed it; re-open the review.
    case contentChangedSinceReview
    case noProjectFile
    case writeFailed
}

/// File-backed hook configuration.
///
/// The directory lives under the app's data directory. That directory is a
/// denied root for the model's file tools. Approved conversation settings
/// can add or remove disabled user definitions through this store.
/// Project hooks live in the project and therefore *can* be edited by file
/// tools, which is exactly why they are gated by a content-hash trust record
/// that only the Settings UI can create.
public final class HookConfigStore: @unchecked Sendable {
    public static let userFileName = "user-hooks.json"
    public static let trustFileName = "hook-trust.json"
    public static let projectRelativePath = ".miniscanvas/hooks.json"
    public static let maximumFileBytes = 64 * 1024
    /// Project script directory covered by the trust hash, relative to the root.
    public static let projectScriptsRelativePath = HookScriptReferenceAnalyzer.protectedDirectory
    public static let maximumScriptFiles = 64
    public static let maximumScriptBytes = 1024 * 1024
    private static let maximumScriptEntries = 512
    private static let maximumScriptDepth = 8
    private static let hashVersionLine = "miniscanvas-project-hooks-trust-v2\n"

    public let directory: URL
    private let lock = NSLock()
    private let protectedURLs: [URL]
    /// Loaded once for this runtime owner; disk edits cannot mint live consent.
    private var cachedTrustFile: TrustFile?

    public init(directory: URL) {
        self.directory = directory
        // App-owned state: the model's file tools may not read or change the user
        // hooks, the trust record or their directory (exact paths only; the
        // project's own `.miniscanvas/hooks` is not covered, the hash guards it).
        self.protectedURLs = [
            directory.appendingPathComponent(Self.userFileName),
            directory.appendingPathComponent(Self.trustFileName),
            directory,
        ]
        protectedURLs.forEach { SensitiveFilePolicy.protectStatePath($0, isDirectory: $0 == directory) }
        _ = loadTrustLocked()
    }

    deinit {
        protectedURLs.forEach { SensitiveFilePolicy.unprotectStatePath($0, isDirectory: $0 == directory) }
    }

    /// `<settings directory>/hooks`, honoring formal-test isolation.
    public static func defaultDirectory() -> URL {
        SettingsStore.defaultDirectory().appendingPathComponent("hooks", isDirectory: true)
    }

    public func userHooksSnapshot() -> ProjectHooksSnapshot {
        lock.withLock { userSnapshotLocked() }
    }

    private func userSnapshotLocked() -> ProjectHooksSnapshot {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard userFileURL.resolvingSymlinksInPath().path == userFileURL.standardizedFileURL.path,
              let values = try? userFileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: userFileURL), data.count <= Self.maximumFileBytes,
              let file = try? JSONDecoder().decode(HookConfigurationFile.self, from: data), !file.hasDuplicateIDs else {
            return ProjectHooksSnapshot(projectRoot: root, contentHash: nil, hooks: [],
                trust: FileManager.default.fileExists(atPath: userFileURL.path) ? .invalid("用户 Hook 配置无法读取") : .noFile)
        }
        let scripts: [ScriptEntry]
        switch Self.scanScriptDirectory(rootPath: root) {
        case .files(let files): scripts = files
        case .invalid(let reason):
            return ProjectHooksSnapshot(projectRoot: root, contentHash: nil, hooks: file.hooks, trust: .invalid(reason))
        }
        let hash = Self.trustHash(hooksFile: data, scripts: scripts)
        let saved = loadTrustLocked().projects[userFileURL.path]
        let trust: ProjectHooksSnapshot.Trust = saved?.sha256 == hash
            ? .trusted : .untrusted(changedSinceTrust: saved != nil)
        var outside: [String: [String]] = [:]
        for hook in file.hooks {
            let paths = HookScriptReferenceAnalyzer.outsideReferences(command: hook.command, projectRoot: root, allowsProjectDirectoryReferences: false)
            if !paths.isEmpty { outside[hook.id] = paths }
        }
        return ProjectHooksSnapshot(projectRoot: root, contentHash: hash, hooks: file.hooks, trust: trust,
            protectedScriptFiles: scripts.map(\.path), outsideReferences: outside)
    }

    /// Same reviewed-content hash contract and trust file as project hooks.
    public func trustUserHooks(expectedHash: String) throws {
        try lock.withLock {
            let snapshot = userSnapshotLocked()
            guard let hash = snapshot.contentHash, hash == expectedHash else {
                throw HookConfigStoreError.contentChangedSinceReview
            }
            var trust = loadTrustLocked()
            trust.projects[userFileURL.path] = TrustRecord(sha256: hash, trustedAt: Date())
            try writeTrustLocked(trust)
        }
    }

    public func revokeUserTrust() throws {
        try lock.withLock {
            var trust = loadTrustLocked()
            trust.projects.removeValue(forKey: userFileURL.path)
            try writeTrustLocked(trust)
        }
    }

    private var userFileURL: URL { directory.appendingPathComponent(Self.userFileName) }
    private var trustFileURL: URL { directory.appendingPathComponent(Self.trustFileName) }

    // MARK: User-level hooks

    public struct UserLoad: Sendable, Equatable {
        public let hooks: [HookDefinition]
        /// Non-nil when the file exists but could not be used. No hook runs then.
        public let error: String?
    }

    public func loadUserHooks() -> UserLoad {
        lock.lock()
        defer { lock.unlock() }
        return loadUserHooksLocked()
    }

    private func loadUserHooksLocked() -> UserLoad {
        guard FileManager.default.fileExists(atPath: userFileURL.path) else {
            return UserLoad(hooks: [], error: nil)
        }
        guard let data = try? Data(contentsOf: userFileURL),
              data.count <= Self.maximumFileBytes,
              let file = try? JSONDecoder().decode(HookConfigurationFile.self, from: data),
              !file.hasDuplicateIDs else {
            return UserLoad(hooks: [], error: "用户 Hook 配置无法读取，已全部停用")
        }
        return UserLoad(hooks: file.hooks, error: nil)
    }

    /// Revision for the typed user-only conversation settings operations.
    public func conversationUserHooksRevision() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard conversationUserPathIsValidLocked() else { return nil }
        let loaded = loadUserHooksLocked()
        guard loaded.error == nil else { return nil }
        return Self.conversationRevision(loaded.hooks)
    }

    public func addDisabledUserHook(_ hook: HookDefinition, expectedRevision: String) throws -> String {
        guard !hook.enabled, hook.isRunnable else { throw HookConfigStoreError.invalidDefinition }
        return try changeDisabledUserHooks(expectedRevision: expectedRevision) { hooks in
            guard !hooks.contains(where: { $0.id == hook.id }) else { throw HookConfigStoreError.duplicateID }
            hooks.append(hook)
        }
    }

    public func removeDisabledUserHook(id: String, expectedRevision: String) throws -> String {
        try changeDisabledUserHooks(expectedRevision: expectedRevision) { hooks in
            guard let index = hooks.firstIndex(where: { $0.id == id }) else { throw HookConfigStoreError.notFound }
            guard !hooks[index].enabled else { throw HookConfigStoreError.invalidDefinition }
            hooks.remove(at: index)
        }
    }

    private func changeDisabledUserHooks(
        expectedRevision: String,
        _ change: (inout [HookDefinition]) throws -> Void
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard conversationUserPathIsValidLocked() else { throw HookConfigStoreError.writeFailed }
        let loaded = loadUserHooksLocked()
        guard loaded.error == nil, Self.conversationRevision(loaded.hooks) == expectedRevision else {
            throw HookConfigStoreError.contentChangedSinceReview
        }
        var hooks = loaded.hooks
        try change(&hooks)
        guard let revision = Self.conversationRevision(hooks) else { throw HookConfigStoreError.writeFailed }
        let data = try Self.encodeUserHooks(hooks)
        guard data.count <= Self.maximumFileBytes else { throw HookConfigStoreError.writeFailed }
        if hooks.contains(where: { $0.enabled && $0.isRunnable }),
           let saved = loadTrustLocked().projects[userFileURL.path] {
            // Reusing previously reviewed bytes can make an enabled hook live
            // again. Only Settings may establish executable user trust.
            let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
            guard case .files(let scripts) = Self.scanScriptDirectory(rootPath: root),
                  Self.trustHash(hooksFile: data, scripts: scripts) != saved.sha256 else {
                throw HookConfigStoreError.invalidDefinition
            }
        }
        try writeUserHooksLocked(data)
        return revision
    }

    private func conversationUserPathIsValidLocked() -> Bool {
        let root = directory.standardizedFileURL
        let file = userFileURL.standardizedFileURL
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path,
              file.resolvingSymlinksInPath().standardizedFileURL.path == file.path else { return false }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) {
            return attributes[.type] as? FileAttributeType == .typeRegular
                && ((attributes[.size] as? NSNumber)?.int64Value ?? Int64.max) <= Int64(Self.maximumFileBytes)
        }
        return !FileManager.default.fileExists(atPath: file.path)
    }

    private static func conversationRevision(_ hooks: [HookDefinition]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(HookConfigurationFile(hooks: hooks))).map(HookDigest.sha256Hex)
    }

    public func addUserHook(_ hook: HookDefinition) throws {
        guard hook.isRunnable else { throw HookConfigStoreError.invalidDefinition }
        lock.lock()
        defer { lock.unlock() }
        var hooks = loadUserHooksLocked().hooks
        guard !hooks.contains(where: { $0.id == hook.id }) else { throw HookConfigStoreError.duplicateID }
        hooks.append(hook)
        try writeUserHooksLocked(hooks)
    }

    public func setUserHookEnabled(id: String, enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        var hooks = loadUserHooksLocked().hooks
        guard let index = hooks.firstIndex(where: { $0.id == id }) else { throw HookConfigStoreError.notFound }
        hooks[index].enabled = enabled
        try writeUserHooksLocked(hooks)
    }

    public func removeUserHook(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var hooks = loadUserHooksLocked().hooks
        guard hooks.contains(where: { $0.id == id }) else { throw HookConfigStoreError.notFound }
        hooks.removeAll { $0.id == id }
        try writeUserHooksLocked(hooks)
    }

    private static func encodeUserHooks(_ hooks: [HookDefinition]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(HookConfigurationFile(hooks: hooks))
    }

    private func writeUserHooksLocked(_ hooks: [HookDefinition]) throws {
        try writeUserHooksLocked(Self.encodeUserHooks(hooks))
    }

    private func writeUserHooksLocked(_ data: Data) throws {
        do {
            try ensureDirectoryLocked()
            try data.write(to: userFileURL, options: .atomic)
        } catch {
            throw HookConfigStoreError.writeFailed
        }
    }

    private func ensureDirectoryLocked() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: Project hooks and the trust gate

    private struct TrustRecord: Codable, Equatable {
        let sha256: String
        let trustedAt: Date
    }

    private struct TrustFile: Codable, Equatable {
        var projects: [String: TrustRecord] = [:]
    }

    private func loadTrustLocked() -> TrustFile {
        if let cachedTrustFile { return cachedTrustFile }
        let value: TrustFile
        if let data = try? Data(contentsOf: trustFileURL),
           let decoded = try? JSONDecoder().decode(TrustFile.self, from: data) { value = decoded }
        else { value = TrustFile() }
        cachedTrustFile = value
        return value
    }

    private func writeTrustLocked(_ file: TrustFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try ensureDirectoryLocked()
            try encoder.encode(file).write(to: trustFileURL, options: .atomic)
            cachedTrustFile = file
        } catch {
            throw HookConfigStoreError.writeFailed
        }
    }

    static func canonicalRootPath(_ root: URL) -> String? {
        guard root.isFileURL, root.path.hasPrefix("/") else { return nil }
        return root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Reads the project's hooks file ONCE and derives hash, parsed hooks and
    /// trust from those same bytes, so a swap between check and use cannot
    /// execute content that was never reviewed.
    public func projectSnapshot(projectRoot: URL) -> ProjectHooksSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return projectSnapshotLocked(projectRoot: projectRoot)
    }

    private struct ScriptEntry {
        let path: String
        let size: Int
        let isExecutable: Bool
        let digest: String
    }

    private enum ScriptScan {
        case files([ScriptEntry])
        case invalid(String)
    }

    /// Reads every regular file under `<root>/.miniscanvas/hooks/` once. Symlinks,
    /// odd file types, too many files/bytes or too deep a tree make the project
    /// hooks unusable rather than partially covered. `.DS_Store` is ignored.
    private static func scanScriptDirectory(rootPath: String) -> ScriptScan {
        let directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(projectScriptsRelativePath, isDirectory: true)
        let manager = FileManager.default
        // lstat semantics: a dangling or replaced symlink still counts as "present".
        guard let directoryAttributes = try? manager.attributesOfItem(atPath: directoryURL.path) else {
            return .files([])
        }
        let tooBig = "hooks 目录超过上限（最多 \(maximumScriptFiles) 个文件、\(maximumScriptBytes / 1024) KiB），未信任"
        guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory,
              directoryURL.resolvingSymlinksInPath().path == directoryURL.path else {
            return .invalid("hooks 目录不是普通目录（含符号链接）")
        }
        var entries: [ScriptEntry] = []
        var totalBytes = 0
        var visited = 0
        var pending: [(url: URL, relative: String, depth: Int)] = [(url: directoryURL, relative: "", depth: 0)]
        while let item = pending.popLast() {
            guard item.depth <= maximumScriptDepth,
                  let names = try? manager.contentsOfDirectory(atPath: item.url.path) else {
                return .invalid("hooks 目录无法读取或层级过深")
            }
            for name in names.sorted() where name != ".DS_Store" {
                visited += 1
                guard visited <= maximumScriptEntries else { return .invalid(tooBig) }
                let url = item.url.appendingPathComponent(name)
                let relative = item.relative.isEmpty ? name : item.relative + "/" + name
                guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                      let type = attributes[.type] as? FileAttributeType else {
                    return .invalid("hooks 目录无法读取")
                }
                switch type {
                case .typeDirectory:
                    pending.append((url: url, relative: relative, depth: item.depth + 1))
                case .typeRegular:
                    guard entries.count < maximumScriptFiles,
                          let size = (attributes[.size] as? NSNumber)?.intValue,
                          totalBytes + size <= maximumScriptBytes,
                          let data = try? Data(contentsOf: url),
                          totalBytes + data.count <= maximumScriptBytes else {
                        return .invalid(tooBig)
                    }
                    totalBytes += data.count
                    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    entries.append(ScriptEntry(
                        path: relative, size: data.count, isExecutable: mode & 0o111 != 0,
                        digest: HookDigest.sha256Hex(data)))
                default:
                    return .invalid("hooks 目录含符号链接或特殊文件")
                }
            }
        }
        return .files(entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) })
    }

    /// The trust hash: hooks.json bytes plus path, size, executable bit and
    /// content digest of every script, in a length-prefixed manifest.
    private static func trustHash(hooksFile: Data, scripts: [ScriptEntry]) -> String {
        var manifest = hashVersionLine
        manifest += "hooks.json \(HookDigest.sha256Hex(hooksFile))\n"
        for script in scripts {
            manifest += "script \(script.path.utf8.count):\(script.path) \(script.size) "
                + (script.isExecutable ? "x " : "- ") + script.digest + "\n"
        }
        return HookDigest.sha256Hex(Data(manifest.utf8))
    }

    private func projectSnapshotLocked(projectRoot: URL) -> ProjectHooksSnapshot {
        guard let rootPath = Self.canonicalRootPath(projectRoot) else {
            return ProjectHooksSnapshot(projectRoot: projectRoot.path, contentHash: nil, hooks: [],
                                        trust: .invalid("项目目录无效"))
        }
        let fileURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(Self.projectRelativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ProjectHooksSnapshot(projectRoot: rootPath, contentHash: nil, hooks: [], trust: .noFile)
        }
        // No symlink anywhere between the canonical root and the file.
        guard fileURL.resolvingSymlinksInPath().path == fileURL.path,
              let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: fileURL), data.count <= Self.maximumFileBytes else {
            return ProjectHooksSnapshot(projectRoot: rootPath, contentHash: nil, hooks: [],
                                        trust: .invalid("项目 Hook 文件不是普通文件或过大"))
        }
        let scripts: [ScriptEntry]
        switch Self.scanScriptDirectory(rootPath: rootPath) {
        case .invalid(let reason):
            return ProjectHooksSnapshot(projectRoot: rootPath, contentHash: nil, hooks: [], trust: .invalid(reason))
        case .files(let entries):
            scripts = entries
        }
        let hash = Self.trustHash(hooksFile: data, scripts: scripts)
        guard let file = try? JSONDecoder().decode(HookConfigurationFile.self, from: data),
              !file.hasDuplicateIDs else {
            return ProjectHooksSnapshot(projectRoot: rootPath, contentHash: hash, hooks: [],
                                        trust: .invalid("项目 Hook 文件格式错误或 id 重复"),
                                        protectedScriptFiles: scripts.map(\.path))
        }
        var outside: [String: [String]] = [:]
        for hook in file.hooks {
            let references = HookScriptReferenceAnalyzer.outsideReferences(
                command: hook.command, projectRoot: rootPath)
            if !references.isEmpty { outside[hook.id] = references }
        }
        let trusted = loadTrustLocked().projects[rootPath]
        let trust: ProjectHooksSnapshot.Trust
        if let trusted, trusted.sha256 == hash {
            trust = .trusted
        } else {
            trust = .untrusted(changedSinceTrust: trusted != nil)
        }
        return ProjectHooksSnapshot(projectRoot: rootPath, contentHash: hash, hooks: file.hooks, trust: trust,
                                    protectedScriptFiles: scripts.map(\.path), outsideReferences: outside)
    }

    /// Settings-UI only. `expectedHash` is the hash the user reviewed; if the file
    /// has changed since, nothing is trusted and the user must review again.
    public func trustProjectHooks(projectRoot: URL, expectedHash: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let rootPath = Self.canonicalRootPath(projectRoot) else {
            throw HookConfigStoreError.invalidProjectRoot
        }
        let snapshot = projectSnapshotLocked(projectRoot: projectRoot)
        switch snapshot.trust {
        case .noFile, .invalid:
            throw HookConfigStoreError.noProjectFile
        case .trusted:
            return
        case .untrusted:
            break
        }
        guard let hash = snapshot.contentHash else { throw HookConfigStoreError.noProjectFile }
        guard hash == expectedHash else { throw HookConfigStoreError.contentChangedSinceReview }
        var file = loadTrustLocked()
        file.projects[rootPath] = TrustRecord(sha256: hash, trustedAt: Date())
        try writeTrustLocked(file)
    }

    public func revokeProjectTrust(projectRoot: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let rootPath = Self.canonicalRootPath(projectRoot) else {
            throw HookConfigStoreError.invalidProjectRoot
        }
        var file = loadTrustLocked()
        guard file.projects.removeValue(forKey: rootPath) != nil else { return }
        try writeTrustLocked(file)
    }

    /// Roots that carry a trust record, so Settings can list them after restart.
    public func trustedProjectRoots() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadTrustLocked().projects.keys
            .filter { $0 != userFileURL.path && !$0.hasPrefix(Self.claudeSettingsTrustPrefix) }.sorted()
    }

    // MARK: Claude Code 格式的 settings.json 钩子

    // MARK: Claude settings 钩子引用的脚本

    private static let maximumClaudeScriptFileBytes = 256 * 1024
    private static let maximumClaudeScriptFiles = 20
    private static let maximumClaudeScriptTotalBytes = 1024 * 1024

    private struct ClaudeScriptScan {
        var entries: [String: ScriptEntry] = [:]
        var totalBytes = 0
    }

    /// 没有脚本入哈希时沿用只含命令的旧哈希（已有信任记录不失效）；有脚本时再叠加
    /// 每个脚本的路径、大小、可执行位和内容摘要。
    private static func claudeSettingsTrustHash(commandsHash: String, scripts: [ScriptEntry]) -> String {
        var manifest = "miniscanvas-claude-settings-hooks-v2\n"
        manifest += "commands \(commandsHash)\n"
        for script in scripts {
            manifest += "script \(script.path.utf8.count):\(script.path) \(script.size) "
                + (script.isExecutable ? "x " : "- ") + script.digest + "\n"
        }
        return HookDigest.sha256Hex(Data(manifest.utf8))
    }

    /// 把 `<root>/<relative>` 这一个普通文件记入 `scan`；放不下（不存在、不是普通文件、
    /// 项目级的符号链接、超过单文件/数量/总量上限、路径越出 root）返回 false。
    private static func addClaudeScript(
        relative: String, root: String, allowsSymlinks: Bool, scan: inout ClaudeScriptScan
    ) -> Bool {
        if scan.entries[relative] != nil { return true }
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return false }
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relative)
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        var readURL = url
        var mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if type == .typeSymbolicLink {
            guard allowsSymlinks else { return false }
            readURL = url.resolvingSymlinksInPath()
            guard let resolved = try? manager.attributesOfItem(atPath: readURL.path),
                  resolved[.type] as? FileAttributeType == .typeRegular else { return false }
            mode = (resolved[.posixPermissions] as? NSNumber)?.intValue ?? 0
        } else {
            guard type == .typeRegular else { return false }
            if !allowsSymlinks, url.resolvingSymlinksInPath().path != url.standardizedFileURL.path { return false }
        }
        guard scan.entries.count < maximumClaudeScriptFiles,
              let data = try? Data(contentsOf: readURL),
              data.count <= maximumClaudeScriptFileBytes,
              scan.totalBytes + data.count <= maximumClaudeScriptTotalBytes else { return false }
        scan.totalBytes += data.count
        scan.entries[relative] = ScriptEntry(
            path: relative, size: data.count, isExecutable: mode & 0o111 != 0,
            digest: HookDigest.sha256Hex(data))
        return true
    }

    /// 脚本放在 `.claude/hooks/`（用户级 `~/.claude/hooks/`）时整个目录入哈希，
    /// 因为脚本常 source 同目录里的库。
    private static func addClaudeScriptDirectory(
        relative: String, root: String, allowsSymlinks: Bool, scan: inout ClaudeScriptScan
    ) -> Bool {
        let directory = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relative, isDirectory: true)
        let manager = FileManager.default
        let resolved = directory.resolvingSymlinksInPath()
        // 项目级目录本身不能是符号链接；用户级允许（与 settings.json 的处理一致）。
        guard allowsSymlinks || resolved.path == directory.standardizedFileURL.path,
              (try? manager.attributesOfItem(atPath: resolved.path))?[.type] as? FileAttributeType == .typeDirectory,
              let subpaths = try? manager.subpathsOfDirectory(atPath: resolved.path),
              subpaths.count <= 200 else { return false }
        for subpath in subpaths.sorted() where !subpath.hasSuffix(".DS_Store") {
            let entryRelative = relative + "/" + subpath
            guard let entryAttributes = try? manager.attributesOfItem(
                atPath: resolved.appendingPathComponent(subpath).path),
                  let type = entryAttributes[.type] as? FileAttributeType else { return false }
            if type == .typeDirectory { continue }
            guard addClaudeScript(relative: entryRelative, root: root,
                                  allowsSymlinks: allowsSymlinks, scan: &scan) else { return false }
        }
        return true
    }

    /// 信任记录里 Claude 设置文件的键前缀，避免和项目根路径混在一起。
    static let claudeSettingsTrustPrefix = "claude-settings:"
    public static let maximumClaudeSettingsBytes = 256 * 1024

    /// 读取 ~/.claude/settings.json、<项目>/.claude/settings.json 与 settings.local.json
    /// 里的 hooks 段。只返回存在且含钩子的文件。每份文件只读一次，哈希、钩子定义和信任
    /// 都来自同一份字节；没有信任记录（或内容变了）的文件不会被执行，只供设置页审阅。
    /// 只有 `.claude/hooks/`（用户级 `~/.claude/hooks/`）里的脚本会整个目录并入信任哈希；
    /// 引用了该目录以外脚本的钩子，以及哈希放不下的引用（目录、过大、符号链接、不存在、
    /// 数量或体积超限）所在的钩子，一律标记为不可执行，因为脚本再引用的文件无法覆盖。
    public func claudeSettingsSnapshots(
        projectRoot: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ClaudeSettingsHooksSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return claudeSettingsSnapshotsLocked(projectRoot: projectRoot, homeDirectory: homeDirectory)
    }

    private func claudeSettingsSnapshotsLocked(
        projectRoot: URL?, homeDirectory: URL
    ) -> [ClaudeSettingsHooksSnapshot] {
        var sources: [(scope: ClaudeSettingsHooksSnapshot.Scope, url: URL, base: String, prefix: String)] = []
        let userBase = homeDirectory.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL
        sources.append((.user, userBase.appendingPathComponent("settings.json"), userBase.path, "cc-user"))
        if let projectRoot, let rootPath = Self.canonicalRootPath(projectRoot) {
            let base = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
            if base.standardizedFileURL.path != userBase.path {
                sources.append((.project, base.appendingPathComponent("settings.json"), rootPath, "cc-project"))
                sources.append((.projectLocal, base.appendingPathComponent("settings.local.json"), rootPath, "cc-local"))
            }
        }
        var result: [ClaudeSettingsHooksSnapshot] = []
        let trustRecords = loadTrustLocked().projects
        for source in sources {
            let path = source.url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let root = source.base
            func snapshot(_ hooks: [HookDefinition], _ hash: String?, _ trust: ProjectHooksSnapshot.Trust,
                          outside: [String: [String]] = [:], scripts: [String] = []) -> ClaudeSettingsHooksSnapshot {
                ClaudeSettingsHooksSnapshot(scope: source.scope, path: path, snapshot: ProjectHooksSnapshot(
                    projectRoot: root, contentHash: hash, hooks: hooks, trust: trust,
                    protectedScriptFiles: scripts, outsideReferences: outside))
            }
            // 点文件常被符号链接到别处；信任绑定的是读到的内容哈希，所以允许链接。
            let readURL = source.url.resolvingSymlinksInPath()
            guard let values = try? readURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize,
                  size <= Self.maximumClaudeSettingsBytes,
                  let data = try? Data(contentsOf: readURL),
                  data.count <= Self.maximumClaudeSettingsBytes else {
                result.append(snapshot([], nil, .invalid("设置文件不是普通文件或过大")))
                continue
            }
            guard let hooks = ClaudeSettingsHooksParser.parse(data, idPrefix: source.prefix) else {
                result.append(snapshot([], nil, .invalid("设置文件不是有效的 JSON")))
                continue
            }
            guard !hooks.isEmpty else {
                // 文件里只有本 App 不支持的事件或钩子类型：仍列出一行，让设置页说明被忽略了什么。
                if !ClaudeSettingsHooksParser.ignoredEventNames(in: data).isEmpty
                    || !ClaudeSettingsHooksParser.ignoredHookTypes(in: data).isEmpty {
                    result.append(snapshot([], nil, .noFile))
                }
                continue
            }
            let commandsHash = ClaudeSettingsHooksParser.contentHash(of: hooks)
            // 钩子直接引用的脚本（项目内、~/.claude 内的普通文件）并入信任哈希：脚本改了，
            // 哈希就变，需要重新信任。引用了哈希放不下的东西（目录、过大、符号链接、
            // 不存在、数量或体积超限、项目外）的钩子仍不执行。
            let isUserScope = source.scope == .user
            let hooksDirectory = isUserScope ? "hooks" : ".claude/hooks"
            var outside: [String: [String]] = [:]
            var scan = ClaudeScriptScan()
            for hook in hooks {
                let references = HookScriptReferenceAnalyzer.outsideReferences(
                    command: hook.command, projectRoot: root,
                    allowsProjectDirectoryReferences: !isUserScope,
                    protectsHooksDirectory: false, homeDirectory: homeDirectory.standardizedFileURL.path)
                guard !references.isEmpty else { continue }
                // 用户级钩子在项目目录（没有项目时在家目录）里执行，写成相对路径的引用
                // 指向的不是 ~/.claude，不能按 ~/.claude 内的文件入哈希。
                let relativeWritten: Set<String> = isUserScope
                    ? Set(HookScriptReferenceAnalyzer.outsideReferences(
                        command: hook.command, projectRoot: "/nonexistent-miniscanvas-hook-root",
                        allowsProjectDirectoryReferences: false, protectsHooksDirectory: false,
                        homeDirectory: homeDirectory.standardizedFileURL.path))
                    : []
                var unhashable: [String] = []
                for reference in references {
                    if relativeWritten.contains(reference) {
                        unhashable.append(reference)
                    } else if reference == hooksDirectory || reference.hasPrefix(hooksDirectory + "/") {
                        let ok = Self.addClaudeScriptDirectory(
                            relative: hooksDirectory, root: root, allowsSymlinks: isUserScope, scan: &scan)
                            && (reference == hooksDirectory || scan.entries[reference] != nil)
                        if !ok { unhashable.append(reference) }
                    } else {
                        // 不在 hooks 目录里的脚本，其引用的其它文件不在哈希里，不能执行。
                        unhashable.append(reference)
                    }
                }
                if !unhashable.isEmpty { outside[hook.id] = unhashable }
            }
            let scripts = scan.entries.values.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            let hash = scripts.isEmpty ? commandsHash : Self.claudeSettingsTrustHash(commandsHash: commandsHash, scripts: scripts)
            let saved = trustRecords[Self.claudeSettingsTrustPrefix + path]
            let trust: ProjectHooksSnapshot.Trust = saved?.sha256 == hash
                ? .trusted : .untrusted(changedSinceTrust: saved != nil)
            result.append(snapshot(hooks, hash, trust, outside: outside, scripts: scripts.map(\.path)))
        }
        return result
    }

    /// Settings-UI only：`expectedHash` 是用户审阅过的钩子哈希；文件在审阅后变了就什么都不信任。
    public func trustClaudeSettingsHooks(
        path: String,
        expectedHash: String,
        projectRoot: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = claudeSettingsSnapshotsLocked(projectRoot: projectRoot, homeDirectory: homeDirectory)
            .first(where: { $0.path == path }),
              let hash = entry.snapshot.contentHash else { throw HookConfigStoreError.noProjectFile }
        guard hash == expectedHash else { throw HookConfigStoreError.contentChangedSinceReview }
        var file = loadTrustLocked()
        file.projects[Self.claudeSettingsTrustPrefix + path] = TrustRecord(sha256: hash, trustedAt: Date())
        try writeTrustLocked(file)
    }

    public func revokeClaudeSettingsTrust(path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var file = loadTrustLocked()
        guard file.projects.removeValue(forKey: Self.claudeSettingsTrustPrefix + path) != nil else { return }
        try writeTrustLocked(file)
    }
}
