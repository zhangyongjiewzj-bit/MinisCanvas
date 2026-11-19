import CryptoKit
import Foundation

// MARK: - 项目级 .mcp.json（待批准）
//
// 与 Claude Code 一致：项目根的 `.mcp.json` 只能作为“待批准”的服务器配置读出。
// 批准按文件内容哈希记录（借用项目钩子的哈希信任模式）：内容一变就回到待批准；
// 批准之前不会启动任何进程、不会授权任何工具，也不会写入用户的服务器列表。
// 批准动作只由设置页的按钮触发；工具授权仍由用户在设置页逐个决定。

public struct MCPProjectConfigSnapshot: Sendable, Equatable {
    public enum Trust: Sendable, Equatable {
        case noFile
        case invalid(String)
        case untrusted(changedSinceTrust: Bool)
        case trusted
    }

    public let projectRoot: String
    public let contentHash: String?
    /// 解析出的服务器条目，仅供审阅；信任之前不会被使用。
    public let entries: [MCPServerImportPreview.Entry]
    public let trust: Trust
    /// 已存在、上次是从这份文件导入、但用户在本地改过的服务器 id。批准更新时默认不覆盖它们。
    public let locallyModifiedIDs: Set<String>

    public init(projectRoot: String, contentHash: String?, entries: [MCPServerImportPreview.Entry], trust: Trust,
                locallyModifiedIDs: Set<String> = []) {
        self.projectRoot = projectRoot
        self.contentHash = contentHash
        self.entries = entries
        self.trust = trust
        self.locallyModifiedIDs = locallyModifiedIDs
    }

    /// 批准时默认导入的服务器（不含用户在本地改过的）。
    public var servers: [MCPServer] { allServers.filter { !locallyModifiedIDs.contains($0.id) } }
    /// 文件里解析出的全部服务器，含用户改过的。
    public var allServers: [MCPServer] { entries.compactMap(\.server) }
    /// 用户改过、默认不覆盖的服务器；用户明确点“仍然覆盖”时才使用。
    public var locallyModifiedServers: [MCPServer] { allServers.filter { locallyModifiedIDs.contains($0.id) } }

    public var needsTrustDecision: Bool {
        if case .untrusted = trust { return true }
        return false
    }
}

public enum MCPProjectConfigError: Error, Equatable, Sendable, LocalizedError {
    case contentChangedSinceReview
    case notReviewable
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .contentChangedSinceReview: return "项目的 .mcp.json 在你查看之后变了：请重新查看内容后再批准。"
        case .notReviewable: return "项目的 .mcp.json 无法读取或没有可导入的服务器：请检查文件后重试。"
        case .writeFailed: return "保存批准记录失败：请检查磁盘空间或权限后重试。"
        }
    }
}

public final class MCPProjectConfigStore: @unchecked Sendable {
    public static let fileName = ".mcp.json"
    public static let trustFileName = "mcp-project-trust.json"
    public static let maximumFileBytes = 256 * 1024

    private struct TrustRecord: Codable, Equatable {
        var sha256: String
        var trustedAt: Date
        /// 上次批准时从这份文件导入的服务器 id。内容变了重新批准时，这些重名的服务器按“更新”处理；
        /// 用户自己添加的同名服务器不在其中，仍然跳过，不会被覆盖。
        var serverIDs: [String]?
        /// 每个导入服务器在导入时的配置指纹。更新时只覆盖“本地指纹仍等于它”的服务器（用户没动过）。
        /// 旧版本写的记录没有这一项，视为无法确认未改动，一律不自动覆盖。
        var serverFingerprints: [String: String]?
    }

    /// 服务器可由用户编辑的配置指纹（含环境变量和请求头，不含启用开关与超时）。只存哈希。
    public static func importFingerprint(_ server: MCPServer) -> String {
        struct Material: Codable {
            var type: MCPTransportType
            var command: String?
            var args: [String]
            var env: [String: String]
            var url: String?
            var headers: [String: String]
            var workingDirectory: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let material = Material(type: server.type, command: server.command, args: server.args, env: server.env,
                                url: server.url, headers: server.headers, workingDirectory: server.workingDirectory)
        guard let data = try? encoder.encode(material) else { return "invalid" }
        return sha256Hex(data)
    }

    private struct TrustFile: Codable, Equatable {
        var projects: [String: TrustRecord] = [:]
    }

    private let directory: URL
    private let lock = NSLock()

    private static let residentLock = NSLock()
    nonisolated(unsafe) private static var residentStores: [String: MCPProjectConfigStore] = [:]

    /// 常驻实例：同一目录只建一次、整个进程期间不释放，信任文件因此一直受保护
    /// （受保护登记随实例释放而撤销，界面不能每次访问都新建一个临时实例）。
    public static func resident(directory: URL) -> MCPProjectConfigStore {
        let key = directory.standardizedFileURL.path
        residentLock.lock(); defer { residentLock.unlock() }
        if let existing = residentStores[key] { return existing }
        let store = MCPProjectConfigStore(directory: directory)
        residentStores[key] = store
        return store
    }

    public init(directory: URL) {
        self.directory = directory
        SensitiveFilePolicy.protectStatePath(trustFileURL, isDirectory: false)
    }

    deinit {
        SensitiveFilePolicy.unprotectStatePath(trustFileURL, isDirectory: false)
    }

    private var trustFileURL: URL { directory.appendingPathComponent(Self.trustFileName) }

    private func loadTrustLocked() -> TrustFile {
        guard let data = try? Data(contentsOf: trustFileURL),
              let file = try? JSONDecoder().decode(TrustFile.self, from: data) else { return TrustFile() }
        return file
    }

    private func writeTrustLocked(_ file: TrustFile) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: trustFileURL, options: .atomic)
        } catch {
            throw MCPProjectConfigError.writeFailed
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 读取项目根的 `.mcp.json`（拒绝符号链接、非普通文件、超过 256KB 的文件）。
    private func readFile(projectRoot: URL) -> (root: String, data: Data?, exists: Bool) {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return (root.path, nil, false) }
        guard file.resolvingSymlinksInPath().path == file.path,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: file), data.count <= Self.maximumFileBytes else {
            return (root.path, nil, true)
        }
        return (root.path, data, true)
    }

    /// 当前项目 `.mcp.json` 的状态。`existingIDs` 用来标出和已有服务器重名的条目。
    public func snapshot(projectRoot: URL, existingIDs: Set<String> = [],
                         existingServers: [MCPServer] = []) -> MCPProjectConfigSnapshot {
        let loaded = readFile(projectRoot: projectRoot)
        guard loaded.exists else {
            return MCPProjectConfigSnapshot(projectRoot: loaded.root, contentHash: nil, entries: [], trust: .noFile)
        }
        guard let data = loaded.data, let text = String(data: data, encoding: .utf8) else {
            return MCPProjectConfigSnapshot(
                projectRoot: loaded.root, contentHash: nil, entries: [],
                trust: .invalid("项目的 .mcp.json 无法读取（太大、不是普通文件或编码不对）"))
        }
        let saved = lock.withLock { loadTrustLocked().projects[loaded.root] }
        let updatable = Set(saved?.serverIDs ?? []).intersection(existingIDs)
        // 只有本地配置仍等于导入时的指纹（用户没改过）才允许自动更新。
        let modified = updatable.filter { id in
            guard let recorded = saved?.serverFingerprints?[id],
                  let local = existingServers.first(where: { $0.id == id }) else { return true }
            return Self.importFingerprint(local) != recorded
        }
        let preview = MCPServerJSONImport.preview(
            text, existingIDs: existingIDs, updatableIDs: updatable, projectRoot: loaded.root)
        if let error = preview.parseError {
            return MCPProjectConfigSnapshot(
                projectRoot: loaded.root, contentHash: nil, entries: [], trust: .invalid(error))
        }
        let hash = Self.sha256Hex(data)
        let trust: MCPProjectConfigSnapshot.Trust = saved?.sha256 == hash
            ? .trusted : .untrusted(changedSinceTrust: saved != nil)
        let entries = preview.entries.map { entry -> MCPServerImportPreview.Entry in
            guard let server = entry.server, updatable.contains(server.id),
                  let old = existingServers.first(where: { $0.id == server.id }) else { return entry }
            var changes: [String] = []
            if old.command != server.command { changes.append("命令") }
            if old.args != server.args { changes.append("参数") }
            if old.url != server.url { changes.append("地址") }
            if old.env != server.env { changes.append("环境变量") }
            if old.headers != server.headers { changes.append("请求头") }
            let diff = changes.isEmpty ? "配置没有实质变化" : "已变化：" + changes.joined(separator: "、")
            var baseNote = entry.note
            var extra: String?
            if modified.contains(server.id) {
                baseNote = entry.note?.replacingOccurrences(of: "更新已有服务器", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "；"))
                if baseNote?.isEmpty == true { baseNote = nil }
                extra = "你改过这个服务器，未自动更新（你的环境变量、请求头、启用开关和超时都会保留）；确需用文件内容覆盖，请点“仍然覆盖”"
            }
            return MCPServerImportPreview.Entry(
                sourceName: entry.sourceName, server: server, summary: entry.summary,
                note: [baseNote, extra, "新旧对比（" + diff + "）"].compactMap { $0 }.joined(separator: "；"))
        }
        return MCPProjectConfigSnapshot(projectRoot: loaded.root, contentHash: hash, entries: entries, trust: trust,
                                        locallyModifiedIDs: Set(modified))
    }

    /// 批准：只有当前文件内容的哈希等于用户查看时的哈希才记录。
    /// `serverIDs` 是这次从该文件导入的服务器 id，下次内容变化时用来判断哪些重名是“更新”。
    /// `servers` 是文件里解析出的全部服务器（含用户改过的），用来记录导入时的配置指纹。
    public func trust(projectRoot: URL, expectedHash: String, serverIDs: [String] = [],
                      servers: [MCPServer] = []) throws {
        let loaded = readFile(projectRoot: projectRoot)
        guard let data = loaded.data else { throw MCPProjectConfigError.notReviewable }
        guard Self.sha256Hex(data) == expectedHash else { throw MCPProjectConfigError.contentChangedSinceReview }
        try lock.withLock {
            var file = loadTrustLocked()
            // 指纹只记“当前本地真正等于文件内容”的服务器：用户改过而没覆盖的，保留原指纹（保持“改过”状态）。
            var fingerprints: [String: String] = file.projects[loaded.root]?.serverFingerprints ?? [:]
            for server in servers { fingerprints[server.id] = Self.importFingerprint(server) }
            let ids = Array(Set(serverIDs + servers.map(\.id))).sorted()
            file.projects[loaded.root] = TrustRecord(sha256: expectedHash, trustedAt: Date(), serverIDs: ids,
                                                     serverFingerprints: fingerprints)
            try writeTrustLocked(file)
        }
    }

    public func revokeTrust(projectRoot: URL) throws {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        try lock.withLock {
            var file = loadTrustLocked()
            guard file.projects.removeValue(forKey: root) != nil else { return }
            try writeTrustLocked(file)
        }
    }
}
