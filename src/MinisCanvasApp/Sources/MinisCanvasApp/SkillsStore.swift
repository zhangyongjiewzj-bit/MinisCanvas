import Darwin
import Foundation
import MinisCore

/// One selected, canonical App-store proposal. The source path is shown to
/// the reviewing user only; the durable receipt binds the copied bytes by hash.
struct SkillImportReviewDraft: Identifiable, Equatable {
    let skillID: String
    let receiptID: String
    let name: String
    let version: String
    let sourcePath: String
    let contentHash: String
    let sourceIdentity: String
    let bodyPreview: String
    let bodyPreviewIsTruncated: Bool
    let scope: MemoryScope?
    let replacesExistingApproval: Bool

    var id: String { skillID }
}

/// A recovery index of the existing confirmed deletion intent, not approval.
/// The trash bytes must still match before the existing restore API is called.
private struct SkillTrashRecovery: Codable {
    let intent: OperationIntent
    let contentHash: String
    let receipt: DeletionReceipt
}

enum SkillImportReviewError: Error, Equatable {
    case invalidSource
    case invalidDocument
    case existingSkill
    case updateIdentityMismatch
    case updateReviewPending
    case staleState
    case proposalRejected
    case proposalChanged
    case approvalRejected

    var userMessage: String {
        switch self {
        case .invalidSource: return "无法读取所选技能目录。请选择包含 SKILL.md 的普通文件夹。"
        case .invalidDocument: return "SKILL.md 格式或技能标识无效，未导入。"
        case .updateReviewPending: return "该技能已有待审核更新，请先完成审核再更新。"
        case .updateIdentityMismatch: return "所选技能 id 与要更新的 App 技能不一致，未替换。"
        case .existingSkill: return "同名 App 技能已存在，请先检查现有版本。"
        case .staleState: return "该技能存在旧的启用状态，未进行批准；请检查当前技能状态。"
        case .proposalRejected: return "技能未能安全登记为待批准状态。"
        case .proposalChanged: return "待批准内容或来源证明已变化，请重新审核。"
        case .approvalRejected: return "技能批准或激活失败，未作为可用技能发布。"
        }
    }
}

/// Nonisolated lifetime holder for a detached catalog scan. `SkillsStore` is
/// MainActor-bound, so deinit must cancel through this lock-protected box
/// instead of reaching into an actor-isolated task field.
private final class SkillCatalogRefreshTaskCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>? = nil

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

// MARK: - 波4 技能（skill）管理：扫描 + 启用/禁用 + 详情
//
// 参照 OpenMinis：技能库可直接浏览、按分类列出、启用/禁用、查看详情。
// 数据来源：App 技能库与用户显式配置的本地目录（只读待导入）。
//
// 铁律：只读扫描（不改 SKILL.md 内容），启用/禁用状态单独持久化到独立
// JSON 文件（不写入技能文件本身）。

// MARK: - 技能来源

enum SkillSource: String, Sendable {
    case app      // App 技能库 SkillStore
    case localDirectory = "local" // 用户显式配置的只读来源

    var displayName: String {
        switch self {
        case .app: return "App"
        case .localDirectory: return "本地技能库"
        }
    }
}

/// Directory discovery configuration belongs to the same isolated settings
/// directory as skills-enabled.json. Discovery does not grant execution.
enum SkillDirectoryConfiguration {
    static func normalized(_ roots: [URL]) -> [URL]? {
        guard roots.count <= 32 else { return nil }
        var seen = Set<String>()
        var result: [URL] = []
        for root in roots {
            guard root.isFileURL, root.path.hasPrefix("/"), root.path.utf8.count <= 4096 else { return nil }
            let normalized = root.standardizedFileURL
            if seen.insert(normalized.path).inserted { result.append(normalized) }
        }
        return result
    }

    static func load(from file: URL, defaults: [URL]) -> [URL] {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 65_536,
              let data = try? Data(contentsOf: file),
              let paths = try? JSONDecoder().decode([String].self, from: data),
              paths.allSatisfy({ $0.hasPrefix("/") }),
              let roots = normalized(paths.map { URL(fileURLWithPath: $0, isDirectory: true) }) else { return defaults }
        return roots
    }
}

// MARK: - 技能条目

/// 一个扫描到的技能（元数据 + 启用状态 + 所属来源/分类）。
struct SkillEntry: Identifiable, Hashable, Sendable {
    /// App 技能 id 或显式目录条目 id（app:/local: 命名空间）。
    let id: String
    let name: String
    let description: String
    let version: String
    /// App 库为内置分类；显式目录沿用 SKILL.md 上一级分类。
    let category: String
    let source: SkillSource
    /// SKILL.md 文件路径（详情展示用）。
    let path: URL
    var isEnabled: Bool
    var requiresImport: Bool { id.hasPrefix("local:") }
}

// MARK: - 扫描器（纯函数，可单测）

enum SkillsScanner {

    /// 解析单个 SKILL.md 内容 → 技能条目（纯函数）。frontmatter 无 name 回退目录名。
    static func skillEntry(
        content: String,
        directoryName: String,
        category: String,
        source: SkillSource,
        path: URL
    ) -> SkillEntry? {
        guard let parsed = SkillCatalogDocumentPolicy.admit(content) else { return nil }
        return skillEntry(
            parsed: parsed,
            directoryName: directoryName,
            category: category,
            source: source,
            path: path
        )
    }

    private static func skillEntry(
        parsed: SkillCatalogParsedDocument,
        directoryName: String,
        category: String,
        source: SkillSource,
        path: URL
    ) -> SkillEntry? {
        guard parsed.documentByteCount > 0,
              SkillFilesystemBoundary.isSafePathComponent(directoryName) else { return nil }
        guard SkillFilesystemBoundary.isSafeDisplayName(parsed.name) else { return nil }
        let name = parsed.name == SkillStore.defaultSkillName ? directoryName : parsed.name
        let slug = SkillStore.slugify(directoryName)
        guard SkillManifestIdentity.isValidSkillID(slug),
              SkillManifestIdentity.isValidSkillVersion(parsed.version) else { return nil }
        return SkillEntry(
            id: "\(source.rawValue):\(slug)",
            name: name,
            description: parsed.description,
            version: parsed.version,
            category: category,
            source: source,
            path: path,
            isEnabled: true
        )
    }

    /// 只扫描调用方显式配置的目录（支持分类子目录）。
    /// 分类 = SKILL.md 的上一级目录名；根目录不存在 → 空列表。重复 id 整组拒绝并稳定排序。
    static func scanLocalDirectory(root: URL) -> [SkillEntry] {
        var diagnostics = SkillCatalogDiagnosticReport()
        return scanLocalDirectory(root: root, diagnostics: &diagnostics)
    }

    /// Explicit-directory projection with bounded, path-free rejection diagnostics.
    static func scanLocalDirectoryWithDiagnostics(
        root: URL
    ) -> (entries: [SkillEntry], diagnostics: SkillCatalogDiagnosticReport) {
        var diagnostics = SkillCatalogDiagnosticReport()
        let entries = scanLocalDirectory(root: root, diagnostics: &diagnostics)
        return (entries, diagnostics)
    }

    private static func scanLocalDirectory(
        root: URL,
        diagnostics: inout SkillCatalogDiagnosticReport
    ) -> [SkillEntry] {
        let fm = FileManager.default
        let rootLocator = SkillCatalogDiagnostic.safeLocator(root.lastPathComponent)
        // A configured directory may be absent. Absence is an empty source;
        // an existing but untrusted or unreadable root remains a rejection.
        var rootMetadata = stat()
        if Darwin.lstat(root.path, &rootMetadata) != 0 && errno == ENOENT {
            return []
        }
        guard let rootIdentity = SkillFilesystemBoundary.approvedRootIdentity(root),
              SkillFilesystemBoundary.isApprovedRoot(root, matching: rootIdentity) else {
            diagnostics.record(source: .localDirectory, locator: rootLocator, code: .untrustedEntry)
            return []
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            diagnostics.record(source: .localDirectory, locator: rootLocator, code: .snapshotRejected)
            return []
        }

        var seenIDs = Set<String>()
        var duplicateIDs = Set<String>()
        var firstLocators: [String: String] = [:]
        var items: [SkillEntry] = []
        var candidateDirectories: [URL] = []
        var directoriesWithSkillFile = Set<String>()
        let rootDepth = root.standardizedFileURL.pathComponents.count
        for case let url as URL in enumerator {
            if url.lastPathComponent != "SKILL.md",
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let depth = url.standardizedFileURL.pathComponents.count - rootDepth
                if depth == 1 || depth == 2 { candidateDirectories.append(url) }
                continue
            }
            guard url.lastPathComponent == "SKILL.md" else { continue }
            directoriesWithSkillFile.insert(url.deletingLastPathComponent().standardizedFileURL.path)
            guard SkillFilesystemBoundary.isApprovedRoot(root, matching: rootIdentity) else {
                diagnostics.record(source: .localDirectory, locator: rootLocator, code: .untrustedEntry)
                items.removeAll()
                break
            }
            let skillDir = url.deletingLastPathComponent()
            let locator = SkillCatalogDiagnostic.safeLocator(skillDir.lastPathComponent)
            guard let skillDirectoryIdentity = SkillFilesystemBoundary.trustedDirectoryIdentity(
                skillDir,
                within: root
            ),
            SkillFilesystemBoundary.isTrustedSkillDirectory(skillDir, within: root),
            SkillFilesystemBoundary.isTrustedDirectory(
                skillDir,
                within: root,
                matching: skillDirectoryIdentity
            ) else {
                diagnostics.record(source: .localDirectory, locator: locator, code: .untrustedEntry)
                continue
            }
            guard let skillFileIdentity = SkillFilesystemBoundary.trustedRegularFileIdentity(
                url,
                within: root,
                maximumBytes: SkillStore.maxSkillContentBytes
            ) else {
                diagnostics.record(source: .localDirectory, locator: locator, code: .snapshotRejected)
                continue
            }
            let dirName = skillDir.lastPathComponent
            let candidateID = SkillStore.slugify(dirName)
            guard SkillManifestIdentity.isValidSkillID(candidateID) else {
                diagnostics.record(source: .localDirectory, locator: locator, code: .invalidMetadata)
                continue
            }
            if !seenIDs.insert(candidateID).inserted {
                duplicateIDs.insert(candidateID)
                if let firstLocator = firstLocators[candidateID] {
                    diagnostics.record(source: .localDirectory, locator: firstLocator, code: .duplicateIdentity)
                }
                diagnostics.record(source: .localDirectory, locator: locator, code: .duplicateIdentity)
            } else {
                firstLocators[candidateID] = locator
            }
            // 分类 = 技能目录的上一级目录名（根下直接放技能时记为「未分类」）。
            let parent = skillDir.deletingLastPathComponent()
            let category = parent.standardizedFileURL.path == root.standardizedFileURL.path
                ? "未分类"
                : parent.lastPathComponent
            guard SkillFilesystemBoundary.isSafeDisplayName(category) else {
                diagnostics.record(source: .localDirectory, locator: locator, code: .invalidMetadata)
                continue
            }
            guard let snapshot = SkillCatalogFileSnapshot.read(
                skillDirectory: skillDir,
                within: root,
                maxSkillBytes: SkillStore.maxSkillContentBytes,
                expectedRootIdentity: rootIdentity,
                expectedSkillDirectoryIdentity: skillDirectoryIdentity,
                expectedSkillFileIdentity: skillFileIdentity
            ) else {
                diagnostics.record(source: .localDirectory, locator: locator, code: .snapshotRejected)
                continue
            }
            guard SkillFilesystemBoundary.isApprovedRoot(root, matching: rootIdentity) else {
                diagnostics.record(source: .localDirectory, locator: rootLocator, code: .untrustedEntry)
                items.removeAll()
                break
            }
            guard let parsed = SkillCatalogDocumentPolicy.admit(snapshot.content) else {
                diagnostics.record(source: .localDirectory, locator: locator, code: .documentRejected)
                continue
            }
            guard SkillManifestIdentity.resolve(
                skillID: candidateID,
                skillVersion: parsed.version,
                content: snapshot.content,
                manifestData: snapshot.manifestData
            ) != nil else {
                diagnostics.record(source: .localDirectory, locator: locator, code: .identityRejected)
                continue
            }
            guard let entry = skillEntry(
                parsed: parsed,
                directoryName: dirName,
                category: category,
                source: .localDirectory,
                path: url
            ) else {
                diagnostics.record(source: .localDirectory, locator: locator, code: .presentationRejected)
                continue
            }
            items.append(entry)
        }
        guard SkillFilesystemBoundary.isApprovedRoot(root, matching: rootIdentity) else {
            diagnostics.record(source: .localDirectory, locator: rootLocator, code: .untrustedEntry)
            return []
        }
        // A leaf skill folder with no SKILL.md is otherwise invisible to the
        // file-only scan. Inspect directory names only; never read its other
        // files or infer a usable skill from them. A direct child with child
        // directories may be a category, so leave that structural folder out.
        for directory in candidateDirectories.sorted(by: { $0.path < $1.path }) {
            guard SkillFilesystemBoundary.isApprovedRoot(root, matching: rootIdentity) else {
                diagnostics.record(source: .localDirectory, locator: rootLocator, code: .untrustedEntry)
                return []
            }
            let path = directory.standardizedFileURL.path
            guard !directoriesWithSkillFile.contains(path),
                  !directoriesWithSkillFile.contains(where: { $0.hasPrefix(path + "/") })
            else { continue }
            guard SkillFilesystemBoundary.isTrustedDirectory(directory, within: root) else {
                diagnostics.record(
                    source: .localDirectory,
                    locator: SkillCatalogDiagnostic.safeLocator(directory.lastPathComponent),
                    code: .untrustedEntry
                )
                continue
            }
            guard let children = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                diagnostics.record(
                    source: .localDirectory,
                    locator: SkillCatalogDiagnostic.safeLocator(directory.lastPathComponent),
                    code: .snapshotRejected
                )
                continue
            }
            let hasChildDirectory = children.contains {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            guard !hasChildDirectory,
                  (!children.isEmpty || directory.standardizedFileURL.pathComponents.count - rootDepth == 2)
            else { continue }
            diagnostics.record(
                source: .localDirectory,
                locator: SkillCatalogDiagnostic.safeLocator(directory.lastPathComponent),
                code: .missingDocument
            )
        }
        return items
            .filter { entry in
                guard entry.id.hasPrefix("local:") else { return false }
                let id = String(entry.id.dropFirst("local:".count))
                guard SkillManifestIdentity.isValidSkillID(id) else { return false }
                return !duplicateIDs.contains(id)
            }
            .sorted(by: stableSort)
    }

    /// Scan only the canonical App skill store.
    static func scanApp(store: SkillStore) -> [SkillEntry] {
        var diagnostics = SkillCatalogDiagnosticReport()
        return scanApp(store: store, diagnostics: &diagnostics)
    }

    /// App settings projection with bounded, path-free rejection diagnostics.
    static func scanAppWithDiagnostics(
        store: SkillStore
    ) -> (entries: [SkillEntry], diagnostics: SkillCatalogDiagnosticReport) {
        var diagnostics = SkillCatalogDiagnosticReport()
        let entries = scanApp(store: store, diagnostics: &diagnostics)
        return (entries, diagnostics)
    }

    private static func scanApp(
        store: SkillStore,
        diagnostics: inout SkillCatalogDiagnosticReport
    ) -> [SkillEntry] {
        let rootLocator = SkillCatalogDiagnostic.safeLocator(store.skillsRoot.lastPathComponent)
        guard let rootIdentity = SkillFilesystemBoundary.approvedRootIdentity(store.skillsRoot),
              SkillFilesystemBoundary.isApprovedRoot(store.skillsRoot, matching: rootIdentity) else {
            diagnostics.record(source: .app, locator: rootLocator, code: .untrustedEntry)
            return []
        }
        let candidates = store.allSkills().filter { skill in
            guard SkillManifestIdentity.isValidSkillID(skill.id),
                  SkillFilesystemBoundary.isSafeDisplayName(skill.name),
                  SkillManifestIdentity.isValidSkillVersion(skill.version) else {
                diagnostics.record(source: .app, locator: SkillCatalogDiagnostic.safeLocator(skill.id), code: .invalidMetadata)
                return false
            }
            return true
        }
        guard let snapshots = store.catalogFileSnapshots(for: candidates.map(\.id), expectedRootIdentity: rootIdentity) else {
            diagnostics.batchIncomplete = true
            diagnostics.record(source: .app, locator: rootLocator, code: .snapshotRejected)
            return []
        }
        let items = candidates.compactMap { skill in
            let locator = SkillCatalogDiagnostic.safeLocator(skill.id)
            let directory = store.skillDirectoryURL(for: skill.id)
            let skillFile = directory.appendingPathComponent("SKILL.md")
            guard let snapshot = snapshots[skill.id] else {
                diagnostics.record(source: .app, locator: locator, code: .snapshotRejected)
                return nil
            }
            guard let parsed = SkillCatalogDocumentPolicy.admit(snapshot.content) else {
                diagnostics.record(source: .app, locator: locator, code: .documentRejected)
                return nil
            }
            let content = snapshot.content
            guard SkillFilesystemBoundary.isSafeDisplayName(parsed.name),
                  parsed.version == skill.version else {
                diagnostics.record(source: .app, locator: locator, code: .invalidMetadata)
                return nil
            }
            guard SkillManifestIdentity.resolve(
                skillID: skill.id,
                skillVersion: parsed.version,
                content: content,
                manifestData: snapshot.manifestData
            ) != nil else {
                diagnostics.record(source: .app, locator: locator, code: .identityRejected)
                return nil
            }
            return SkillEntry(
                id: "app:\(skill.id)",
                name: parsed.name == SkillStore.defaultSkillName ? skill.name : parsed.name,
                description: parsed.description,
                version: parsed.version,
                category: "内置",
                source: .app,
                path: skillFile,
                isEnabled: skill.isEnabled
            )
        }
        .sorted(by: stableSort)
        guard SkillFilesystemBoundary.isApprovedRoot(store.skillsRoot, matching: rootIdentity) else {
            diagnostics.record(source: .app, locator: rootLocator, code: .untrustedEntry)
            return []
        }
        return items
    }

    /// 在调用方提供的后台线程读取 App 技能，并应用启用状态。
    /// 只接收 URL 与值类型；不会把 MainActor 上的 SkillsStore 或可变 SkillStore
    /// 实例跨线程传递。生产冷启动由此路径执行，避免扫描 SKILL.md 阻塞主线程。
    static func mergedEntries(

        appSnapshot: SkillStore.Snapshot,
        enabledStates: [String: Bool]
    ) -> [SkillEntry] {
        mergedEntriesWithDiagnostics(

            appSnapshot: appSnapshot,
            enabledStates: enabledStates
        ).entries
    }

    /// Settings projection plus bounded diagnostics from the canonical App store.
    static func mergedEntriesWithDiagnostics(

        appSnapshot: SkillStore.Snapshot,
        enabledStates: [String: Bool],
        localRoots: [URL] = []
    ) -> (entries: [SkillEntry], diagnostics: SkillCatalogDiagnosticReport) {
        let appSkillsRoot = appSnapshot.skillsRoot
        let domain = PersistenceTransactionFence.Domain.skills(appSkillsRoot)
        let admission = PersistenceTransactionFence.read([domain])
        defer { admission.release() }
        let enabledStates = PersistenceTransactionFence.requiresReopen(domain)
            ? SkillsStateStore.load(from: appSkillsRoot.deletingLastPathComponent().appendingPathComponent("skills-enabled.json"))
            : enabledStates
        let appStore = SkillStore.makeSnapshotStore(from: appSnapshot)
        var diagnostics = SkillCatalogDiagnosticReport()
        let appEntries = scanApp(store: appStore, diagnostics: &diagnostics)
        var merged = appEntries
        for index in merged.indices {
            merged[index].isEnabled = merged[index].isEnabled
                && (enabledStates[merged[index].id] ?? true)
        }
        // Additional roots are discovery rows, never runnable aliases. A
        // copied, reviewed App skill retains its canonical id independently
        // from the original source row and its current contents.
        var paths = Set(appEntries.map { $0.path.standardizedFileURL.path })
        for root in SkillDirectoryConfiguration.normalized(localRoots) ?? [] {
            for entry in scanLocalDirectory(root: root, diagnostics: &diagnostics) {
                guard paths.insert(entry.path.standardizedFileURL.path).inserted else { continue }
                let pathID = SkillManifest.hash(entry.path.standardizedFileURL.path)
                merged.append(SkillEntry(id: "local:" + pathID, name: entry.name,
                    description: entry.description, version: entry.version, category: entry.category,
                    source: .localDirectory, path: entry.path, isEnabled: false))
            }
        }
        return (merged.sorted(by: stableSort), diagnostics)
    }

    private static func stableSort(_ lhs: SkillEntry, _ rhs: SkillEntry) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.version != rhs.version { return lhs.version < rhs.version }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.source.rawValue < rhs.source.rawValue
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        SkillFilesystemBoundary.isCanonicallyContained(candidate, in: root)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}

// MARK: - 启用状态持久化

/// 把启用/禁用状态持久化到独立 JSON 文件（不写技能文件本身）。
/// 纯函数式读写，可单测。
enum SkillsStateStore {
    static let fileName = "skills-enabled.json"

    enum SaveError: Error, Equatable, Sendable {
        case encodingFailed
        case directoryCreationFailed
        case writeFailed
    }

    /// 默认状态文件：App 数据目录下。
    static func defaultFileURL() -> URL {
        SettingsStore.defaultDirectory().appendingPathComponent(fileName)
    }

    /// 读状态（id → 是否启用）。文件不存在/损坏 → 空字典。
    static func load(from url: URL) -> [String: Bool] {
        let domain = PersistenceTransactionFence.Domain.skills(url.deletingLastPathComponent().appendingPathComponent("skills"))
        let admission = PersistenceTransactionFence.read([domain])
        defer { admission.release() }
        guard let data = try? PersistenceTransactionFence.data(at: url, domain: domain),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return dict
    }

    /// 写状态（id → 是否启用）。失败返回可断言错误，不更新 UI 投影。
    @discardableResult
    static func save(_ states: [String: Bool], to url: URL) -> Result<Void, SaveError> {
        let domain = PersistenceTransactionFence.Domain.skills(url.deletingLastPathComponent().appendingPathComponent("skills"))
        let admission = PersistenceTransactionFence.read([domain])
        defer { admission.release() }
        guard (try? admission.requireWritable()) != nil else { return .failure(.writeFailed) }
        let data: Data
        do {
            data = try JSONEncoder().encode(states)
        } catch {
            return .failure(.encodingFailed)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failure(.directoryCreationFailed)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .failure(.writeFailed)
        }
        return .success(())
    }
}

enum SkillEnablementError: Error, Equatable, Sendable {
    case unknownSkill
    case runtimeRejected(SkillRuntimeEnablementError)
    case persistenceFailed(SkillsStateStore.SaveError)
    case runtimeRollbackFailed(SkillRuntimeEnablementError)
    case rollbackRejected
    case rollbackPersistenceFailed(SkillsStateStore.SaveError)
    case rollbackCompensationPersistenceFailed(SkillsStateStore.SaveError)
}

// MARK: - SkillsStore（@Observable 门面）

@MainActor
@Observable
final class SkillsStore {
    /// 当前技能列表（含启用状态）。
    private(set) var entries: [SkillEntry] = []
    /// The bounded report belonging to `entries`, exposed to the settings
    /// consumer as one replacement-safe value instead of stale scan facts.
    private(set) var catalogDiagnostics = SkillCatalogDiagnosticReport()
    /// Monotonic settings projection generation. Background results must match
    /// this generation before they can replace the visible catalog/report.
    private(set) var catalogRefreshGeneration: UInt64 = 0
    /// Lifecycle state distinguishes an unscanned/refreshing projection from a
    /// partial scan with safely retained valid siblings.
    private(set) var catalogRefreshStatus: SkillCatalogRefreshStatus = .unscanned
    /// Bounded degraded-scan retry state for the existing Settings consumer.
    private(set) var catalogRefreshRetryState: SkillCatalogRefreshRetryState = .notNeeded
    /// Fixed-label/count-only status text for a settings summary row.
    var catalogDiagnosticSummary: String { catalogDiagnostics.stableSummary }
    var catalogStatusSummary: String { catalogRefreshStatus.stableSummary }
    var catalogRetrySummary: String { catalogRefreshRetryState.stableSummary }
    /// 最近一次错误的内部诊断文本；不直接展示给用户。
    private(set) var lastError: String?
    /// 最近一次启用状态失败的安全用户提示；不含 enum/path/secret。
    private(set) var lastErrorMessage: String?
    /// 当前会话最后一次技能注入的值对象事实。
    private(set) var injectionReceipts: [SkillInjectionReceipt] = []
    private(set) var injectionSessionID: String?
    private(set) var injectionGeneration: Int?

    /// Called after a durable enablement commit so the request/picker consumer
    /// can refresh its next-turn catalog. A fail-closed disablement projection
    /// is also published when rollback compensation persistence fails.
    var onEnablementChanged: (() -> Void)?

    private(set) var localSkillRoots: [URL]
    private let directoryConfigurationURL: URL
    private let appStore: SkillStore
    private let runtimeEnablementBridge: SkillRuntimeEnablementBridge
    private let stateFileURL: URL
    private let rollbackStateSaver: (
        [String: Bool],
        URL
    ) -> Result<Void, SkillsStateStore.SaveError>
    private let enablementStateSaver: (
        [String: Bool],
        URL
    ) -> Result<Void, SkillsStateStore.SaveError>
    /// id → 是否启用（覆盖扫描默认值 true）。
    private var enabledStates: [String: Bool]
    private var catalogRefreshGate = SkillCatalogRefreshGate()
    private var catalogRefreshRetryBudget = SkillCatalogRefreshRetryBudget()
    nonisolated private let catalogRefreshTaskCleanup = SkillCatalogRefreshTaskCleanup()

    init(

        appStore: SkillStore = SkillStore(),
        stateFileURL: URL? = nil,
        loadImmediately: Bool = true,
        rollbackStateSaver: @escaping (
            [String: Bool],
            URL
        ) -> Result<Void, SkillsStateStore.SaveError> = SkillsStateStore.save,
        enablementStateSaver: @escaping (
            [String: Bool],
            URL
        ) -> Result<Void, SkillsStateStore.SaveError> = SkillsStateStore.save
    ) {
        self.appStore = appStore
        self.runtimeEnablementBridge = SkillRuntimeEnablementBridge(store: appStore)
        self.stateFileURL = stateFileURL ?? SkillsStateStore.defaultFileURL()
        let configurationURL = (stateFileURL ?? SkillsStateStore.defaultFileURL())
            .deletingLastPathComponent().appendingPathComponent("skill-directories.json")
        self.directoryConfigurationURL = configurationURL
        self.localSkillRoots = SkillDirectoryConfiguration.load(from: configurationURL,
            defaults: [])
        self.rollbackStateSaver = rollbackStateSaver
        self.enablementStateSaver = enablementStateSaver
        self.enabledStates = SkillsStateStore.load(from: self.stateFileURL)
        if loadImmediately {
            reload()
        }
    }

    deinit {
        catalogRefreshTaskCleanup.cancel()
    }

    /// Save a user-selected discovery root. Choosing a project adds its
    /// conventional .claude/skills folder; it does not approve any skill.
    @discardableResult
    func addSkillDirectory(_ directory: URL, isProject: Bool = false) -> Bool {
        let root = isProject ? directory.appendingPathComponent(".claude/skills", isDirectory: true) : directory
        return setSkillDirectories(localSkillRoots + [root])
    }

    @discardableResult
    func removeSkillDirectory(_ directory: URL) -> Bool {
        setSkillDirectories(localSkillRoots.filter { $0.standardizedFileURL.path != directory.standardizedFileURL.path })
    }

    private func setSkillDirectories(_ roots: [URL]) -> Bool {
        guard let roots = SkillDirectoryConfiguration.normalized(roots),
              !roots.contains(where: { $0.standardizedFileURL.path == appStore.skillsRoot.standardizedFileURL.path }) else {
            lastErrorMessage = "技能目录无效或超过 32 个；App 技能库由应用单独管理。"
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directoryConfigurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(roots.map(\.path)).write(to: directoryConfigurationURL, options: .atomic)
            localSkillRoots = roots
            lastErrorMessage = nil
            reloadInBackground()
            return true
        } catch {
            lastErrorMessage = "技能目录保存失败，原目录配置仍保留。"
            return false
        }
    }

    func proposeDiscoveredSkill(_ entry: SkillEntry) -> Result<SkillImportReviewDraft, SkillImportReviewError> {
        guard entry.requiresImport, entries.contains(entry),
              localSkillRoots.contains(where: { SkillFilesystemBoundary.isCanonicallyContained(entry.path, in: $0) })
        else { return .failure(.invalidSource) }
        return proposeLocalSkill(from: entry.path.deletingLastPathComponent())
    }

    /// Import only a user-selected folder containing SKILL.md. The existing
    /// descriptor-backed catalog reader supplies one bounded, stable UTF-8
    /// snapshot. No approval is passed to Core: this first step must leave a
    /// durable proposed receipt and a disabled skill.
    func proposeLocalSkill(from selectedDirectory: URL, replacing settingsID: String? = nil) -> Result<SkillImportReviewDraft, SkillImportReviewError> {
        guard selectedDirectory.isFileURL,
              let snapshot = SkillCatalogFileSnapshot.read(
                  skillDirectory: selectedDirectory,
                  within: selectedDirectory
              ) else { return .failure(.invalidSource) }
        return proposeSkillContent(snapshot.content, manifestData: snapshot.manifestData,
                                   sourcePath: selectedDirectory.path, replacing: settingsID)
    }

    static let builtinSkillsInstalledVersionKey = "MinisCanvas.builtinSkills.installedVersion"
    static let builtinSkillsInstalledHashesKey = "MinisCanvas.builtinSkills.installedHashes"

    /// 2026-11-15 第七版（用户同意）：内置技能默认启用，并能随内置库升级。
    /// 走与手动导入相同的提议与批准流程。每个内置库版本只处理一次：
    /// - 没有同名技能：安装；
    /// - 有同名技能且内容仍是上次自动安装的版本（用户没改过）：换成新版；
    /// - 用户改过、关闭过，或是用户自己的同名技能：保持不动；
    /// - 用户删掉的内置技能不会被装回（删掉后不再有记录的哈希可比对，且版本已处理过）。
    @discardableResult
    func installBuiltinSkillsIfNeeded(markerStore: UserDefaults) -> Int {
        guard appStore.isInitialLoadComplete,
              markerStore.integer(forKey: Self.builtinSkillsInstalledVersionKey) < DefaultPromptSkills.version
        else { return 0 }
        var installedHashes = markerStore.dictionary(forKey: Self.builtinSkillsInstalledHashesKey) as? [String: String] ?? [:]
        let firstRun = markerStore.integer(forKey: Self.builtinSkillsInstalledVersionKey) == 0
        var changed = 0
        for entry in DefaultPromptSkills.entries {
            let skillID = SkillStore.slugify(entry.name)
            let newHash = SkillManifest.hash(entry.document)
            if let existing = appStore.allSkills().first(where: { $0.id == skillID }) {
                guard let recorded = installedHashes[skillID],
                      let current = appStore.rawContent(skillID).map(SkillManifest.hash),
                      current == recorded, current != newHash,
                      existing.isEnabled, enabledStates["app:\(skillID)"] != false,
                      case .success(let draft) = proposeLocalSkillUpdate(skillID: skillID, content: entry.document),
                      case .success = approveLocalSkill(draft, currentScope: nil)
                else { continue }
                installedHashes[skillID] = newHash
                changed += 1
                continue
            }
            // 已删除的内置技能：只在第一次运行时安装，之后不装回。
            guard firstRun || installedHashes[skillID] == nil,
                  enabledStates["app:\(skillID)"] == nil,
                  case .success(let draft) = proposeBuiltinSkill(named: entry.name),
                  case .success = approveLocalSkill(draft, currentScope: nil)
            else { continue }
            installedHashes[skillID] = newHash
            changed += 1
        }
        markerStore.set(installedHashes, forKey: Self.builtinSkillsInstalledHashesKey)
        markerStore.set(DefaultPromptSkills.version, forKey: Self.builtinSkillsInstalledVersionKey)
        return changed
    }

    /// 内置技能升级：用同一条"更新本地技能"提议路径，不绕过审核流程。
    private func proposeLocalSkillUpdate(skillID: String, content: String) -> Result<SkillImportReviewDraft, SkillImportReviewError> {
        proposeSkillContent(content, manifestData: nil,
                            sourcePath: "内置技能库 v\(DefaultPromptSkills.version) · \(skillID)",
                            replacing: "app:\(skillID)")
    }

    /// 2026-11-15 提示词方案 v2：把一份内置技能交给与本地导入完全相同的审核流程。
    /// 只生成待审提议，不自动启用；批准仍走"明确批准并启用"。
    func proposeBuiltinSkill(named name: String) -> Result<SkillImportReviewDraft, SkillImportReviewError> {
        guard let entry = DefaultPromptSkills.entries.first(where: { $0.name == name }) else {
            return .failure(.invalidSource)
        }
        return proposeSkillContent(entry.document, manifestData: nil,
                                   sourcePath: "内置技能库 v\(DefaultPromptSkills.version) · \(entry.name)",
                                   replacing: nil)
    }

    private func proposeSkillContent(
        _ content: String, manifestData: Data?, sourcePath: String, replacing settingsID: String?
    ) -> Result<SkillImportReviewDraft, SkillImportReviewError> {
        struct Snapshot { let content: String; let manifestData: Data? }
        let snapshot = Snapshot(content: content, manifestData: manifestData)
        guard let parsed = SkillCatalogDocumentPolicy.admit(snapshot.content),
              parsed.name != SkillStore.defaultSkillName,
              SkillFilesystemBoundary.isSafeDisplayName(parsed.name),
              SkillManifestIdentity.isValidSkillVersion(parsed.version)
        else { return .failure(.invalidDocument) }
        let skillID = SkillStore.slugify(parsed.name)
        guard let sourceIdentity = SkillManifestIdentity.resolve(
            skillID: skillID,
            skillVersion: parsed.version,
            content: snapshot.content,
            manifestData: snapshot.manifestData
        ),
        // A selected local folder may have no sidecar. When it has one, that
        // sidecar is authoritative; only an exact local-file identity may be
        // copied into the App store as `.file`.
        sourceIdentity.isLegacy || sourceIdentity.source == .file else {
            return .failure(.invalidDocument)
        }
        let existing = appStore.allSkills().first { $0.id == skillID }
        if let settingsID {
            guard SkillRuntimeEnablementBridge.appSkillID(from: settingsID) == skillID,
                  existing != nil
            else { return .failure(.updateIdentityMismatch) }
            guard !hasPendingLocalSkillReview(for: settingsID) else { return .failure(.updateReviewPending) }
        } else {
            guard existing == nil else { return .failure(.existingSkill) }
        }
        // A new import still rejects an unrelated stale override. An update
        // keeps the user's existing enable/disable projection unchanged.
        if settingsID == nil, enabledStates["app:\(skillID)"] != nil {
            return .failure(.staleState)
        }
        do {
            let result = try appStore.importSkillThroughLifecycle(
                content: snapshot.content,
                source: .file,
                reason: "Settings user-selected local skill proposal",
                scope: nil,
                approval: nil
            )
            guard result.skill.id == skillID,
                  result.receipt.action == .propose,
                  result.receipt.state == .proposed,
                  result.receipt.scope == nil,
                  result.receipt.contentHash == SkillManifest.hash(snapshot.content),
                  !result.skill.isEnabled
            else { return .failure(.proposalRejected) }
            reload()
            publishEnablementChanged()
            return .success(reviewDraft(
                skillID: skillID,
                receipt: result.receipt,
                name: result.skill.name,
                version: result.skill.version,
                sourcePath: sourcePath,
                body: parsed.body
            ))
        } catch {
            return .failure(.proposalRejected)
        }
    }

    /// Recover a still-pending local-file proposal after closing Settings or
    /// restarting the App. This reads the same canonical App store; it never
    /// treats a scoped proposal as global approval.
    func hasPendingLocalSkillReview(for settingsID: String) -> Bool {
        guard let skillID = SkillRuntimeEnablementBridge.appSkillID(from: settingsID),
              let skill = appStore.allSkills().first(where: { $0.id == skillID }),
              skill.importSource == .file,
              skill.integrity.state == .verified,
              !skill.isEnabled,
              let receipt = appStore.lifecycleReceipt(for: skillID)
        else { return false }
        return receipt.action == .propose && receipt.state == .proposed && receipt.scope == nil
    }

    func pendingLocalSkillReview(for settingsID: String) -> SkillImportReviewDraft? {
        guard let skillID = SkillRuntimeEnablementBridge.appSkillID(from: settingsID),
              let skill = appStore.allSkills().first(where: { $0.id == skillID }),
              skill.importSource == .file,
              skill.integrity.state == .verified,
              !skill.isEnabled,
              let receipt = appStore.lifecycleReceipt(for: skillID),
              receipt.action == .propose,
              receipt.state == .proposed,
              receipt.scope == nil,
              receipt.sourceIdentity == "skill:\(skillID)@\(receipt.contentHash)",
              skill.integrity.manifest?.contentHash == receipt.contentHash,
              let content = stableCanonicalContent(for: skillID),
              SkillManifest.hash(content) == receipt.contentHash
        else { return nil }
        return reviewDraft(
            skillID: skillID,
            receipt: receipt,
            name: skill.name,
            version: skill.version,
            sourcePath: appStore.skillDirectoryURL(for: skillID).path,
            body: SkillStore.parse(skillMD: content).body
        )
    }

    /// Review the installed copy without reimporting a same-named source.
    /// The current receipt and bytes remain authoritative until confirmation.
    func reviewAppSkill(
        for settingsID: String, in scope: MemoryScope
    ) -> Result<SkillImportReviewDraft, SkillImportReviewError> {
        guard scope.isValid,
              let id = SkillRuntimeEnablementBridge.appSkillID(from: settingsID),
              let skill = appStore.allSkills().first(where: { $0.id == id }),
              skill.importSource == .file, skill.integrity.state == .verified,
              let receipt = appStore.lifecycleReceipt(for: id),
              receipt.action == .activate, receipt.state == .active,
              let content = stableCanonicalContent(for: id),
              receipt.contentHash == SkillManifest.hash(content),
              receipt.sourceIdentity == "skill:\(id)@\(receipt.contentHash)"
        else { return .failure(.proposalChanged) }
        return .success(reviewDraft(
            skillID: id, receipt: receipt, name: skill.name, version: skill.version,
            sourcePath: appStore.skillDirectoryURL(for: id).path,
            body: SkillStore.parse(skillMD: content).body,
            scope: scope, replacesExistingApproval: true))
    }

    /// The button in Settings is the explicit review event. Its approverID
    /// names that local UI event and the process UID, not an authenticated
    /// person's name. Scope nil is intentionally limited to non-project
    /// requests; project-bound injection continues to require exact scope.
    func approveLocalSkill(
        _ draft: SkillImportReviewDraft, currentScope: MemoryScope? = nil
    ) -> Result<SkillLifecycleReceipt, SkillImportReviewError> {
        let settingsID = "app:\(draft.skillID)"
        guard let skill = appStore.allSkills().first(where: { $0.id == draft.skillID }),
              skill.importSource == .file,
              skill.integrity.state == .verified,
              draft.scope == currentScope,
              let receipt = appStore.lifecycleReceipt(for: draft.skillID),
              receipt.receiptID == draft.receiptID,
              (draft.replacesExistingApproval
                ? receipt.action == .activate && receipt.state == .active && draft.scope?.isValid == true
                : !skill.isEnabled && receipt.action == .propose && receipt.state == .proposed && receipt.scope == nil),
              receipt.contentHash == draft.contentHash,
              receipt.sourceIdentity == draft.sourceIdentity,
              receipt.sourceIdentity == "skill:\(draft.skillID)@\(receipt.contentHash)",
              skill.integrity.manifest?.contentHash == receipt.contentHash,
              let content = stableCanonicalContent(for: draft.skillID),
              SkillManifest.hash(content) == draft.contentHash
        else { return .failure(.proposalChanged) }
        do {
            let approval = SkillApproval(
                approverID: "settings-explicit-review:local-uid-\(getuid())", scope: draft.scope)
            let active: SkillLifecycleReceipt
            if draft.replacesExistingApproval {
                active = try appStore.importSkillThroughLifecycle(
                    content: content, source: .file, reason: "Settings explicit session and project scope review",
                    scope: draft.scope, approval: approval,
                    contentExpectation: .hash(draft.contentHash)).receipt
            } else {
                active = try appStore.approveAndActivateSkill(
                    draft.skillID, approval: approval,
                    reason: "Settings explicit approval after source and hash review")
            }
            guard active.action == .activate,
                  active.state == .active,
                  active.scope == draft.scope,
                  active.contentHash == draft.contentHash,
                  active.sourceIdentity == draft.sourceIdentity
            else { return .failure(.approvalRejected) }
            if enabledStates[settingsID] == false {
                guard appStore.setEnabled(draft.skillID, enabled: false) else {
                    return .failure(.approvalRejected)
                }
            }
            reload()
            publishEnablementChanged()
            return .success(active)
        } catch {
            return .failure(.approvalRejected)
        }
    }

    private func reviewDraft(
        skillID: String,
        receipt: SkillLifecycleReceipt,
        name: String,
        version: String,
        sourcePath: String,
        body: String,
        scope: MemoryScope? = nil,
        replacesExistingApproval: Bool = false
    ) -> SkillImportReviewDraft {
        let previewLimit = 2_048
        return SkillImportReviewDraft(
            skillID: skillID,
            receiptID: receipt.receiptID,
            name: name,
            version: version,
            sourcePath: sourcePath,
            contentHash: receipt.contentHash,
            sourceIdentity: receipt.sourceIdentity,
            bodyPreview: String(body.prefix(previewLimit)),
            bodyPreviewIsTruncated: body.count > previewLimit,
            scope: scope, replacesExistingApproval: replacesExistingApproval
        )
    }

    private func stableCanonicalContent(for skillID: String) -> String? {
        SkillCatalogFileSnapshot.read(
            skillDirectory: appStore.skillDirectoryURL(for: skillID),
            within: appStore.skillsRoot
        )?.content
    }

    /// 重新扫描技能目录并应用持久化启用状态。
    func reload() {
        cancelActiveCatalogRefreshTask()
        let token = beginCatalogRefresh()
        catalogRefreshStatus = .refreshing
        guard appStore.isInitialLoadComplete else {
            catalogRefreshStatus = .invalidated
            return
        }
        let appSnapshot = appStore.snapshot()
        let result = SkillsScanner.mergedEntriesWithDiagnostics(

            appSnapshot: appSnapshot,
            enabledStates: enabledStates,
            localRoots: localSkillRoots
        )
        guard catalogRefreshGate.accepts(token) else { return }
        guard appStore.isInitialLoadComplete else {
            catalogRefreshStatus = .invalidated
            return
        }
        entries = result.entries
        catalogDiagnostics = result.diagnostics
        catalogRefreshStatus = result.diagnostics.rejectedCount == 0 ? .ready : .degraded
        catalogRefreshRetryState = catalogRefreshRetryBudget.record(status: catalogRefreshStatus)
    }

    /// Starts a new session projection and clears facts from the prior session.
    @discardableResult
    func beginInjectionSession(sessionID: String, generation: Int = 0) -> Bool {
        guard !sessionID.isEmpty, generation >= 0 else { return false }
        if injectionSessionID == sessionID,
           let currentGeneration = injectionGeneration,
           generation < currentGeneration {
            return false
        }
        injectionSessionID = sessionID
        injectionGeneration = generation
        injectionReceipts = []
        return true
    }

    /// Projects a completed injector result into the current session. The
    /// request text is immediately reduced to a stable hash and is not kept.
    @discardableResult
    func projectInjectionResult(
        _ result: SkillInjectionResult,
        request: String,
        budget: Int,
        sessionID: String,
        generation: Int
    ) -> Bool {
        guard !sessionID.isEmpty, generation >= 0, budget >= 0 else { return false }
        let fingerprint = SkillInjectionReceipt.stableRequestFingerprint(for: request)
        let bound = result.receipts.map {
            $0.bound(
                requestFingerprint: fingerprint,
                budget: budget,
                sessionID: sessionID,
                generation: generation
            )
        }
        return projectInjectionReceipts(bound, sessionID: sessionID, generation: generation)
    }

    /// Projects already-bound facts, rejecting cross-session and stale
    /// generation write-backs before they can reach the UI.
    @discardableResult
    func projectInjectionReceipts(
        _ receipts: [SkillInjectionReceipt],
        sessionID: String,
        generation: Int
    ) -> Bool {
        guard !sessionID.isEmpty, generation >= 0 else { return false }
        guard receipts.allSatisfy({ receipt in
            receipt.sessionID == sessionID
                && receipt.generation == generation
                && !receipt.requestFingerprint.isEmpty
                && !receipt.contentHash.isEmpty
                && receipt.budget >= receipt.injectedCharacters
        }) else { return false }
        if injectionSessionID == sessionID,
           let currentGeneration = injectionGeneration,
           generation < currentGeneration {
            return false
        }
        if injectionSessionID != nil, injectionSessionID != sessionID {
            return false
        }
        injectionSessionID = sessionID
        injectionGeneration = generation
        injectionReceipts = receipts
        return true
    }

    /// 后台重新扫描技能目录；返回的任务可供测试或调用方等待完成。
    /// 生产冷启动使用此入口，扫描与 SKILL.md 读取不占用主线程。
    @discardableResult
    func reloadInBackground() -> Task<Void, Never> {
        cancelActiveCatalogRefreshTask()
        let localSkillRoots = localSkillRoots
        let appStore = appStore
        let enabledStates = enabledStates
        let token = beginCatalogRefresh()
        catalogRefreshStatus = .refreshing
        let task = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled, appStore.isInitialLoadComplete else {
                await self?.normalizeCancelledCatalogRefresh(token)
                return
            }
            let appSnapshot = appStore.snapshot()
            let result = SkillsScanner.mergedEntriesWithDiagnostics(

                appSnapshot: appSnapshot,
                enabledStates: enabledStates,
                localRoots: localSkillRoots
            )
            guard !Task.isCancelled else {
                await self?.normalizeCancelledCatalogRefresh(token)
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled, appStore.isInitialLoadComplete else {
                    self.normalizeCancelledCatalogRefresh(token)
                    return
                }
                guard self.catalogRefreshGate.accepts(token) else { return }
                self.entries = result.entries
                self.catalogDiagnostics = result.diagnostics
                self.catalogRefreshStatus = result.diagnostics.rejectedCount == 0 ? .ready : .degraded
                self.catalogRefreshRetryState = self.catalogRefreshRetryBudget.record(
                    status: self.catalogRefreshStatus
                )
            }
        }
        catalogRefreshTaskCleanup.install(task)
        return task
    }

    private func normalizeCancelledCatalogRefresh(_ token: SkillCatalogRefreshToken) {
        guard catalogRefreshGate.cancel(token) else { return }
        catalogRefreshGeneration = catalogRefreshGate.generation
        catalogDiagnostics = SkillCatalogDiagnosticReport()
        catalogRefreshStatus = .invalidated
        catalogRefreshRetryBudget.resetAfterCancellation()
        catalogRefreshRetryState = .notNeeded
    }

    /// Start a replacement-bound settings projection. The input scope includes
    /// roots and enablement values, so a new root or committed toggle advances
    /// the generation before any detached scan is allowed to publish.
    private func beginCatalogRefresh() -> SkillCatalogRefreshToken {
        let scopeKey = SkillCatalogScopeKey.make(
            appSkillsRoot: appStore.skillsRoot,
            enabledStates: enabledStates,
            directoryRoots: localSkillRoots
        )
        if catalogRefreshRetryBudget.bind(scopeKey: scopeKey) {
            catalogRefreshRetryState = .notNeeded
        }
        let token = catalogRefreshGate.begin(scopeKey: scopeKey)
        catalogRefreshGeneration = token.generation
        return token
    }

    private func cancelActiveCatalogRefreshTask() {
        catalogRefreshTaskCleanup.cancel()
    }

    private func invalidateCatalogRefresh() {
        cancelActiveCatalogRefreshTask()
        let scopeKey = SkillCatalogScopeKey.make(
            appSkillsRoot: appStore.skillsRoot,
            enabledStates: enabledStates,
            directoryRoots: localSkillRoots
        )
        if catalogRefreshRetryBudget.bind(scopeKey: scopeKey) {
            catalogRefreshRetryState = .notNeeded
        }
        catalogRefreshGate.invalidate(scopeKey: scopeKey)
        catalogRefreshGeneration = catalogRefreshGate.generation
    }

    var maintenanceChanges: [SkillMaintenanceChangeRecord] {
        SkillMaintenanceTool.changeRecords(skillsRoot: appStore.skillsRoot)
    }

    private var trashReceiptURL: URL {
        appStore.skillsRoot.appendingPathComponent(".trash", isDirectory: true)
            .appendingPathComponent("settings-deletion-receipts.json")
    }

    private func storedTrashRecoveries() -> [SkillTrashRecovery] {
        guard SkillFilesystemBoundary.isTrustedRegularFile(trashReceiptURL,
                    within: appStore.skillsRoot, maximumBytes: 1_048_576),
              let data = try? Data(contentsOf: trashReceiptURL),
              let records = try? JSONDecoder().decode([SkillTrashRecovery].self, from: data)
        else { return [] }
        return records
    }

    private func saveTrashRecoveries(_ records: [SkillTrashRecovery]) throws {
        let trashRoot = trashReceiptURL.deletingLastPathComponent()
        guard SkillFilesystemBoundary.isApprovedRoot(appStore.skillsRoot) else {
            throw SkillError.invalidContent
        }
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        guard SkillFilesystemBoundary.isTrustedDirectory(trashRoot, within: appStore.skillsRoot),
              !FileManager.default.fileExists(atPath: trashReceiptURL.path) ||
                SkillFilesystemBoundary.isTrustedRegularFile(trashReceiptURL, within: appStore.skillsRoot)
        else { throw SkillError.invalidContent }
        if FileManager.default.fileExists(atPath: trashReceiptURL.path) {
            let existing = try Data(contentsOf: trashReceiptURL)
            _ = try JSONDecoder().decode([SkillTrashRecovery].self, from: existing)
        }
        let encoded = try JSONEncoder().encode(records)
        guard encoded.count <= 1_048_576 else { throw SkillError.contentTooLarge }
        try encoded.write(to: trashReceiptURL, options: .atomic)
    }

    private func validTrashRecovery(_ record: SkillTrashRecovery) -> Bool {
        let intent = record.intent
        let trash = trashReceiptURL.deletingLastPathComponent()
            .appendingPathComponent(intent.operationID.uuidString)
        guard record.receipt.operationID == intent.operationID,
              record.receipt.targetID == intent.targetID,
              record.receipt.scopeID == intent.scopeID,
              FileManager.default.fileExists(atPath: trash.path),
              let snapshot = SkillCatalogFileSnapshot.read(skillDirectory: trash, within: appStore.skillsRoot),
              SkillManifest.hash(snapshot.content) == record.contentHash
        else { return false }
        return true
    }

    var deletedSkillReceipts: [DeletionReceipt] {
        storedTrashRecoveries().filter(validTrashRecovery).map(\.receipt)
    }

    func previewSkillDeletion(_ settingsID: String) throws -> OperationIntent {
        guard let id = SkillRuntimeEnablementBridge.appSkillID(from: settingsID) else {
            throw SkillError.invalidContent
        }
        return try appStore.previewDeletion(skillID: id)
    }

    @discardableResult
    func deleteSkill(_ intent: OperationIntent) throws -> DeletionReceipt {
        guard let content = stableCanonicalContent(for: intent.targetID) else { throw SkillError.invalidContent }
        let receipt = try appStore.deleteSkill(intent.targetID, intent: intent)
        defer {
            reload()
            publishEnablementChanged()
        }
        var records = storedTrashRecoveries()
        records.append(SkillTrashRecovery(intent: intent,
            contentHash: SkillManifest.hash(content), receipt: receipt))
        try saveTrashRecoveries(records)
        return receipt
    }

    func restoreDeletedSkill(_ receipt: DeletionReceipt) throws {
        guard let record = storedTrashRecoveries().first(where: { $0.receipt == receipt }),
              validTrashRecovery(record)
        else { throw SkillError.invalidContent }
        try SkillDeletionService(store: appStore).restore(receipt)
        try? saveTrashRecoveries(storedTrashRecoveries().filter {
            $0.intent.operationID != receipt.operationID
        })
        reload()
        publishEnablementChanged()
    }

    /// 某技能是否启用。
    func isEnabled(_ id: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else {
            // A rejected or not-yet-scanned source is never a usable skill.
            // An old state-file override cannot admit an absent entry.
            return false
        }
        if entry.requiresImport { return false }
        if entry.source == .app {
            return entry.isEnabled && (enabledStates[id] ?? true)
        }
        return enabledStates[id] ?? entry.isEnabled
    }

    /// Whether the settings action has a verified, lifecycle-backed prior
    /// revision to restore. Only App entries cross this boundary.
    func canRollback(_ id: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }),
              entry.source == .app,
              let skillID = SkillRuntimeEnablementBridge.appSkillID(from: id)
        else { return false }
        return appStore.canRollbackSkill(skillID)
    }

    /// Restore one App skill revision. The settings projection is pre-written
    /// as disabled so a runtime failure cannot leave a stale enabled override.
    @discardableResult
    func rollback(
        _ id: String,
        reason: String = "settings explicit rollback"
    ) -> Result<SkillLifecycleReceipt, SkillEnablementError> {
        guard let entry = entries.first(where: { $0.id == id }),
              entry.source == .app,
              let skillID = SkillRuntimeEnablementBridge.appSkillID(from: id)
        else {
            let error = SkillEnablementError.unknownSkill
            recordError(error)
            return .failure(error)
        }

        let previousStates = enabledStates
        var nextStates = previousStates
        nextStates[id] = false
        switch rollbackStateSaver(nextStates, stateFileURL) {
        case .success:
            break
        case .failure(let error):
            let result = SkillEnablementError.rollbackPersistenceFailed(error)
            recordError(result)
            return .failure(result)
        }

        do {
            let receipt = try appStore.rollbackSkill(skillID, reason: reason)
            enabledStates = nextStates
            reload()
            publishEnablementChanged()
            lastError = nil
            lastErrorMessage = nil
            return .success(receipt)
        } catch {
            switch rollbackStateSaver(previousStates, stateFileURL) {
            case .success:
                enabledStates = previousStates
                reload()
                let result = SkillEnablementError.rollbackRejected
                recordError(result)
                return .failure(result)
            case .failure(let restoreError):
                // Keep the fail-closed disabled projection if compensating
                // persistence is unavailable; runtime rollback did not commit.
                enabledStates = nextStates
                reload()
                publishEnablementChanged()
                let result = SkillEnablementError.rollbackCompensationPersistenceFailed(restoreError)
                recordError(result)
                return .failure(result)
            }
        }
    }

    /// An approved conversation mutation can use only the exact root-owned
    /// facade and the shared state file already consumed by its Core runtime.
    /// Fixtures with an alternate state file remain a read-only directory.
    func hasCanonicalBL6EnablementOwner(_ owner: SkillStore) -> Bool {
        appStore === owner && stateFileURL.standardizedFileURL
            == appStore.skillsRoot.deletingLastPathComponent()
                .appendingPathComponent(SkillsStateStore.fileName).standardizedFileURL
    }

    func bl6EnablementSnapshot(
        visibleTo scope: MemoryScope, boundTo owner: SkillStore
    ) throws -> BL6SkillEnablementSnapshot {
        guard hasCanonicalBL6EnablementOwner(owner) else {
            throw SkillsStoreTypedCatalogAdapter.ProjectionError.untrustedOwner
        }
        return try runtimeEnablementBridge.bl6EnablementSnapshot(visibleTo: scope)
    }

    /// The original Core journal commits runtime enablement, shared state and
    /// replay metadata together. Publish only after that canonical writer has
    /// returned a durable terminal record; no second state saver is called.
    func commitApprovedBL6Enablement(
        skillID: String, enabled: Bool, visibleTo scope: MemoryScope,
        profileID: String, expectedRevision: String,
        undo: BL6SettingsReplayRecord? = nil,
        boundTo owner: SkillStore,
        makeReplayRecord: @Sendable (String, String) throws -> BL6SettingsReplayRecord
    ) throws -> BL6SettingsReplayRecord {
        let current = try SkillsStoreTypedCatalogAdapter.approvedSnapshot(
            from: self, boundTo: owner, visibleTo: scope)
        guard current.revision == expectedRevision,
              let index = entries.firstIndex(where: { $0.id == "app:" + skillID }) else {
            throw SkillsStoreTypedCatalogAdapter.ProjectionError.stalePreview
        }
        let record = try runtimeEnablementBridge.commitApprovedBL6Enablement(
            skillID: skillID, enabled: enabled, visibleTo: scope,
            profileID: profileID, expectedRevision: expectedRevision,
            undo: undo, makeReplayRecord: makeReplayRecord)
        enabledStates = SkillsStateStore.load(from: stateFileURL)
        entries[index].isEnabled = appStore.allSkills().first(where: { $0.id == skillID })?.isEnabled ?? false
        publishEnablementChanged()
        lastError = nil
        lastErrorMessage = nil
        return record
    }

    /// 设置某技能启用状态；只有 runtime 与持久化均成功才提交 UI 投影。
    @discardableResult
    func setEnabled(_ id: String, enabled: Bool) -> Result<Void, SkillEnablementError> {
        let admission = PersistenceTransactionFence.read([appStore.persistenceDomain])
        defer { admission.release() }
        guard (try? admission.requireWritable()) != nil else {
            let error = SkillEnablementError.persistenceFailed(.writeFailed)
            recordError(error)
            return .failure(error)
        }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            let error = SkillEnablementError.unknownSkill
            recordError(error)
            return .failure(error)
        }
        guard !entries[idx].requiresImport else {
            let error = SkillEnablementError.runtimeRejected(.rejected)
            recordError(error)
            return .failure(error)
        }
        let oldEnabled = entries[idx].isEnabled
        switch runtimeEnablementBridge.setEnabled(for: id, enabled: enabled) {
        case .failure(let error):
            let result = SkillEnablementError.runtimeRejected(error)
            recordError(result)
            return .failure(result)
        case .success:
            break
        }

        let previousStates = enabledStates
        var nextStates = previousStates
        nextStates[id] = enabled
        let failure: SkillEnablementError
        let sharedStateWasSaved: Bool
        switch enablementStateSaver(nextStates, stateFileURL) {
        case .success:
            sharedStateWasSaved = true
            appStore.reload()
            let skillID = SkillRuntimeEnablementBridge.appSkillID(from: id)
            var committed = skillID.flatMap { runtimeID in
                appStore.allSkills().first(where: { $0.id == runtimeID })?.isEnabled
            } == enabled
            if committed, enabled {
                if let skillID,
                   let receipt = appStore.lifecycleReceipt(for: skillID),
                   let content = appStore.rawContent(skillID) {
                    committed = SkillLifecycle.isActivationValid(receipt,
                        currentContentHash: SkillManifest.hash(content), scope: receipt.scope)
                } else {
                    committed = false
                }
            }
            if committed {
                enabledStates = nextStates
                entries[idx].isEnabled = enabled
                publishEnablementChanged()
                lastError = nil
                lastErrorMessage = nil
                return .success(())
            }
            failure = .runtimeRejected(.rejected)
        case .failure(let error):
            sharedStateWasSaved = false
            failure = .persistenceFailed(error)
        }

        // A failed final read is not a committed management operation. Restore
        // the prior shared projection before compensating the canonical write;
        // every compensation still crosses the original enablement gates.
        var sharedCompensationError: SkillsStateStore.SaveError?
        if sharedStateWasSaved {
            if case .failure(let error) = enablementStateSaver(previousStates, stateFileURL) {
                sharedCompensationError = error
            }
        }
        var runtimeCompensationError: SkillRuntimeEnablementError?
        if case .failure(let error) = runtimeEnablementBridge.setEnabled(for: id, enabled: oldEnabled) {
            runtimeCompensationError = error
        } else if sharedCompensationError == nil {
            appStore.reload()
            let skillID = SkillRuntimeEnablementBridge.appSkillID(from: id)
            var restored = skillID.flatMap { runtimeID in
                appStore.allSkills().first(where: { $0.id == runtimeID })?.isEnabled
            } == oldEnabled
            if restored, oldEnabled {
                if let skillID,
                   let receipt = appStore.lifecycleReceipt(for: skillID),
                   let content = appStore.rawContent(skillID) {
                    restored = SkillLifecycle.isActivationValid(receipt,
                        currentContentHash: SkillManifest.hash(content), scope: receipt.scope)
                } else {
                    restored = false
                }
            }
            if !restored { runtimeCompensationError = .rejected }
        }
        if let error = sharedCompensationError {
            reload()
            publishEnablementChanged()
            let result = SkillEnablementError.rollbackCompensationPersistenceFailed(error)
            recordError(result)
            return .failure(result)
        }
        if let error = runtimeCompensationError {
            reload()
            publishEnablementChanged()
            let result = SkillEnablementError.runtimeRollbackFailed(error)
            recordError(result)
            return .failure(result)
        }
        recordError(failure)
        return .failure(failure)
    }

    /// Invalidate every cached catalog projection before notifying its
    /// consumer. A new request can therefore obtain the committed state even
    /// if the consumer's asynchronous UI refresh has not completed yet.
    private func publishEnablementChanged() {
        SkillCatalogCache.invalidateDefaultCatalog()
        invalidateCatalogRefresh()
        onEnablementChanged?()
    }

    private func recordError(_ error: SkillEnablementError) {
        lastError = String(describing: error)
        lastErrorMessage = Self.userFacingMessage(for: error)
    }

    private static func userFacingMessage(for error: SkillEnablementError) -> String {
        switch error {
        case .unknownSkill:
            return "技能不存在，请刷新后重试。"
        case .runtimeRejected:
            return "运行时拒绝了这项更改，技能状态未改变。"
        case .persistenceFailed:
            return "技能状态保存失败，当前状态未改变；请检查磁盘权限后重试。"
        case .runtimeRollbackFailed:
            return "技能状态未能安全回滚，请重启应用后重试。"
        case .rollbackRejected:
            return "技能版本未能安全回滚，当前状态未改变。"
        case .rollbackPersistenceFailed:
            return "技能回滚状态保存失败，当前状态未改变；请检查磁盘权限后重试。"
        case .rollbackCompensationPersistenceFailed:
            return "技能回滚失败，技能保持禁用，原状态未恢复；请检查磁盘权限后重试。"
        }
    }

    /// 按分类分组（标题排序，便于分区展示）。
    var groupedByCategory: [(category: String, items: [SkillEntry])] {
        let groups = Dictionary(grouping: entries, by: { $0.category })
        return groups.keys.sorted().map { ($0, groups[$0] ?? []) }
    }
}
