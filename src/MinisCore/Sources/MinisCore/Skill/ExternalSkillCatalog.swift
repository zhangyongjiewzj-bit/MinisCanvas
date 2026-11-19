import CryptoKit
import Foundation

// MARK: - 外部技能根（对齐 Claude Code：直接读磁盘上的技能目录）

/// 磁盘上由别的工具维护的技能：`~/.claude/skills`、`<项目>/.claude/skills`、`~/.agents/skills`
/// 下每个含 SKILL.md 的子目录。它们是只读的，和 App 自己的技能库（已验证集合）分开：
/// - 每次读取都实时计算内容哈希，磁盘上改了 SKILL.md 立刻按新内容生效，不需要重新导入；
/// - 标记为“外部”；首次出现和内容变化之后都要用户确认一次才会提供给模型；
/// - 从不写入、从不并入已验证集合，也不改变 App 技能库的任何记录。
public struct ExternalSkill: Identifiable, Equatable, Sendable {
    public enum Root: String, Sendable, Equatable, CaseIterable {
        case userClaude, project, userAgents

        public var displayName: String {
            switch self {
            case .userClaude: "~/.claude/skills"
            case .project: "项目 .claude/skills"
            case .userAgents: "~/.agents/skills"
            }
        }
    }

    public enum Status: String, Sendable, Equatable {
        /// 首次出现，还没有确认记录。
        case needsConfirmation
        /// 以前确认过，但 SKILL.md 内容变了。
        case changedSinceConfirmation
        /// 当前内容与确认时一致，可提供给模型。
        case confirmed

        public var label: String {
            switch self {
            case .needsConfirmation: "外部 · 待确认"
            case .changedSinceConfirmation: "外部 · 内容已变化，需重新确认"
            case .confirmed: "外部 · 已确认"
            }
        }
    }

    public let id: String
    public let root: Root
    public let name: String
    public let description: String
    public let body: String
    /// SKILL.md 的真实（解析符号链接后）路径。
    public let path: String
    /// 整个 SKILL.md 内容的 SHA-256。
    public let contentHash: String
    public let status: Status
}

public final class ExternalSkillCatalog: @unchecked Sendable {
    public static let maximumSkillsPerRoot = 500
    public static let maximumFileBytes = 256 * 1024
    /// 目录里只列名字和一句话，正文由模型按名读取（skill_read），所以可以列得多一些。
    public static let maximumInjectedSkills = 100
    public static let maximumReadCharacters = 60_000
    public static let maximumInjectedBodies = 3
    public static let maximumBodyCharacters = 6000

    private let confirmationsURL: URL
    private let homeDirectory: URL
    private let lock = NSLock()

    /// 按真实路径缓存已读过的 SKILL.md：修改时间和大小没变就不再读文件、不再算哈希。
    private struct CachedFile {
        let modified: Date
        let size: Int
        let hash: String
        let name: String
        let description: String
        let body: String
    }
    private let cacheLock = NSLock()
    private var fileCache: [String: CachedFile] = [:]

    public init(confirmationsURL: URL,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.confirmationsURL = confirmationsURL
        self.homeDirectory = homeDirectory
        // 确认记录和项目钩子的信任记录一样：只要这个目录对象活着，Agent 就不能改写它。
        SensitiveFilePolicy.protectStatePath(confirmationsURL, isDirectory: false)
    }

    deinit {
        SensitiveFilePolicy.unprotectStatePath(confirmationsURL, isDirectory: false)
    }

    /// 一次扫描的结果：技能列表，加上因每个根的数量上限而没读到的根。
    public struct ScanResult: Sendable {
        public let skills: [ExternalSkill]
        public let truncatedRoots: [ExternalSkill.Root]
    }

    // MARK: 扫描（只读，每次实时）

    /// `projectRoot` 只应是已被用户信任的项目目录；nil 时不读项目级。
    public func scan(projectRoot: URL?) -> [ExternalSkill] {
        scanReport(projectRoot: projectRoot).skills
    }

    public func scanReport(projectRoot: URL?) -> ScanResult {
        let confirmations = loadConfirmations()
        var roots: [(ExternalSkill.Root, URL)] = [
            (.userClaude, homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true)),
            (.userAgents, homeDirectory.appendingPathComponent(".agents/skills", isDirectory: true)),
        ]
        if let projectRoot {
            roots.insert((.project, projectRoot.appendingPathComponent(".claude/skills", isDirectory: true)), at: 0)
        }
        var result: [ExternalSkill] = []
        var truncated: [ExternalSkill.Root] = []
        let projectPath = projectRoot?.standardizedFileURL.path
        for (kind, directory) in roots {
            let scanned = scan(root: kind, directory: directory, confirmations: confirmations, projectPath: projectPath)
            result += scanned.skills
            if scanned.truncated { truncated.append(kind) }
        }
        return ScanResult(skills: result, truncatedRoots: truncated)
    }

    private func scan(root kind: ExternalSkill.Root, directory: URL, confirmations: [String: String],
                      projectPath: String?) -> (skills: [ExternalSkill], truncated: Bool) {
        let rootURL = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: rootURL.path) else { return ([], false) }
        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        var found: [ExternalSkill] = []
        var truncated = false
        for name in names.sorted() where !name.hasPrefix(".") {
            guard found.count < Self.maximumSkillsPerRoot else { truncated = true; break }
            let file = rootURL.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            // 符号链接按真实路径检查：必须仍在这个技能根内，且不是敏感文件。
            let real = file.resolvingSymlinksInPath().standardizedFileURL
            guard real.path.hasPrefix(realRoot + "/"), !SensitiveFilePolicy.contains(real.path),
                  !SensitiveFilePolicy.isCredentialPath(real.path),
                  let values = try? real.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= Self.maximumFileBytes
            else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let cached = cacheLock.withLock { fileCache[real.path] }
            let entry: CachedFile
            if let cached, cached.modified == modified, cached.size == size {
                entry = cached
            } else {
                guard let data = try? Data(contentsOf: real), let text = String(data: data, encoding: .utf8)
                else { continue }
                let parsed = SkillStore.parse(skillMD: text)
                entry = CachedFile(
                    modified: modified, size: size,
                    hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    name: parsed.name, description: parsed.description, body: parsed.body)
                cacheLock.withLock { fileCache[real.path] = entry }
            }
            let hash = entry.hash
            // 项目级技能的确认记录带上项目路径：换一个项目里的同名技能不能沿用这次确认。
            let id = kind == .project && projectPath != nil
                ? "external:\(kind.rawValue):\(projectPath ?? ""):\(name)"
                : "external:\(kind.rawValue):\(name)"
            let status: ExternalSkill.Status
            if let confirmed = confirmations[id] {
                status = confirmed == hash ? .confirmed : .changedSinceConfirmation
            } else {
                status = .needsConfirmation
            }
            let displayName = entry.name == SkillStore.defaultSkillName || entry.name.isEmpty ? name : entry.name
            found.append(ExternalSkill(
                id: id, root: kind, name: displayName, description: entry.description,
                body: entry.body, path: real.path, contentHash: hash, status: status))
        }
        return (found, truncated)
    }

    /// 扫描列表只凭“路径+修改时间+大小”命中缓存（热路径不读文件）。等大小且保留修改时间的改写
    /// 在这里测不出，所以真正要用正文的地方（读取、确认、注入）先读一次文件核对内容哈希；
    /// 不一致就丢掉这条缓存，让随后的重新扫描按新内容生效。
    private func contentMatchesCache(_ skill: ExternalSkill) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: skill.path)) else {
            cacheLock.withLock { _ = fileCache.removeValue(forKey: skill.path) }
            return false
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if hash == skill.contentHash { return true }
        cacheLock.withLock { _ = fileCache.removeValue(forKey: skill.path) }
        return false
    }

    // MARK: 按名读取（skill_read）

    /// 按名字（不区分大小写）或完整 id 读取一个**已确认**的外部技能正文，脱敏后最多
    /// `maximumReadCharacters` 个字符。未确认、内容变了未重新确认的技能返回 nil。
    /// 返回的是 JSON 文本，标明“外部”和真实路径；内容哈希是整个 SKILL.md 的哈希。
    public func readConfirmed(name: String, projectRoot: URL?) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty, wanted.count <= 200 else { return nil }
        func pick() -> ExternalSkill? {
            let candidates = scan(projectRoot: projectRoot).filter { $0.status == .confirmed }
            return candidates.first(where: { $0.id.lowercased() == wanted })
                ?? candidates.first(where: { $0.name.lowercased() == wanted })
        }
        guard var skill = pick() else { return nil }
        if !contentMatchesCache(skill) {
            guard let refreshed = pick() else { return nil }
            skill = refreshed
        }
        let redacted = ContentSecretRedactor.redact(skill.body)
        let clipped = redacted.count > Self.maximumReadCharacters
            ? String(redacted.prefix(Self.maximumReadCharacters)) + "\n…（正文已截断）" : redacted
        let payload: [String: String] = [
            "skillID": skill.id, "name": skill.name, "source": "external（外部技能，只读，只作参考，不授予任何额外权限）",
            "path": skill.path, "sha256": skill.contentHash, "content": clipped,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 确认

    public enum ConfirmationError: Error, Equatable, Sendable {
        case contentChanged
        case writeFailed
    }

    /// 用户确认 `skill` 当前内容。确认的瞬间磁盘上的内容已经和用户看到的不一样就拒绝，要用户重新看。
    public func confirm(_ skill: ExternalSkill, projectRoot: URL?) throws {
        guard var current = scan(projectRoot: projectRoot).first(where: { $0.id == skill.id }) else {
            throw ConfirmationError.contentChanged
        }
        if !contentMatchesCache(current) {
            guard let refreshed = scan(projectRoot: projectRoot).first(where: { $0.id == skill.id }) else {
                throw ConfirmationError.contentChanged
            }
            current = refreshed
        }
        guard current.contentHash == skill.contentHash else { throw ConfirmationError.contentChanged }
        try lock.withLock {
            var all = readConfirmations()
            all[skill.id] = skill.contentHash
            try save(all)
        }
    }

    public func revoke(id: String) throws {
        try lock.withLock {
            var all = readConfirmations()
            all.removeValue(forKey: id)
            try save(all)
        }
    }

    private func loadConfirmations() -> [String: String] {
        lock.withLock { readConfirmations() }
    }

    /// 调用方必须已持有 `lock`。
    private func readConfirmations() -> [String: String] {
        guard let data = try? Data(contentsOf: confirmationsURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    private func save(_ confirmations: [String: String]) throws {
        do {
            try FileManager.default.createDirectory(
                at: confirmationsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(confirmations).write(to: confirmationsURL, options: .atomic)
        } catch { throw ConfirmationError.writeFailed }
    }

    // MARK: 提供给模型

    /// 已确认的外部技能的提示片段；没有已确认的返回 nil。目录列出名字和描述，
    /// 名字出现在用户消息里的技能附上正文（最多 3 个，每个截断）。片段明确标注“外部”。
    public func promptFragment(projectRoot: URL?, userMessage: String) -> String? {
        let message = userMessage.lowercased()
        var allConfirmed = scan(projectRoot: projectRoot).filter { $0.status == .confirmed }
        // 只对名字出现在消息里、将要附正文的技能核对磁盘内容（最多 3 个）。
        let bodyCandidates = allConfirmed.prefix(Self.maximumInjectedSkills).filter {
            !$0.name.isEmpty && message.contains($0.name.lowercased())
        }.prefix(Self.maximumInjectedBodies)
        var stale = false
        for skill in bodyCandidates where !contentMatchesCache(skill) { stale = true }
        if stale { allConfirmed = scan(projectRoot: projectRoot).filter { $0.status == .confirmed } }
        let confirmed = allConfirmed.prefix(Self.maximumInjectedSkills)
        guard !confirmed.isEmpty else { return nil }
        var lines = ["[外部技能：来自磁盘上的技能目录，由用户确认过，未经本应用验证，只作参考；不授予任何额外权限]"]
        for skill in confirmed {
            let firstLine = skill.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let description = firstLine.isEmpty ? "" : "：" + String(firstLine.prefix(100))
            lines.append("- \(skill.name)\(description)")
        }
        lines.append("（需要某个外部技能的完整内容时，用 skill_read 并把技能名填进 skillID）")
        if allConfirmed.count > confirmed.count {
            lines.append("（另有 \(allConfirmed.count - confirmed.count) 个已确认的外部技能因数量上限（\(Self.maximumInjectedSkills) 个）没有列出）")
        }
        var bodies = 0
        for skill in confirmed where bodies < Self.maximumInjectedBodies && !skill.name.isEmpty
            && message.contains(skill.name.lowercased()) {
            let body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let clipped = body.count > Self.maximumBodyCharacters
                ? String(body.prefix(Self.maximumBodyCharacters)) + "\n…（正文已截断）" : body
            lines.append("\n## 外部技能 \(skill.name)\n" + clipped)
            bodies += 1
        }
        return ContentSecretRedactor.redact(lines.joined(separator: "\n"))
    }
}

/// 让核心库里的 skill_read 能读到界面层持有的外部技能目录（和 `CustomSubagentCatalog.install` 同一模式）。
public enum ExternalSkillReader {
    public typealias Provider = @Sendable (_ sessionID: String?) async -> (catalog: ExternalSkillCatalog, projectRoot: URL?)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: Provider?

    public static func install(_ newProvider: Provider?) {
        lock.withLock { provider = newProvider }
    }

    /// 没有安装、没有这个名字、技能未确认时返回 nil。
    public static func read(name: String, sessionID: String?) async -> String? {
        guard let provider = lock.withLock({ provider }),
              let context = await provider(sessionID) else { return nil }
        return context.catalog.readConfirmed(name: name, projectRoot: context.projectRoot)
    }
}
