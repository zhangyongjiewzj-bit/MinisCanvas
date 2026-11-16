import CryptoKit
import Darwin
import Foundation

// MARK: - 会话内文档 Tab 纯逻辑
//
// 文档属于 session，而不是独立 workspace。Store 的内存索引和每个 session 的
// 恢复文件都以 sessionID 为边界；UI/ChatStore 只需把当前会话 ID 传入即可。
// 编辑时先原子写入恢复快照，显式 save/saveAs 再更新 savedText，因此崩溃恢复
// 能保留未保存修改，同时 dirty 仍然有明确的用户语义。

/// 会话内文档 Tab 的可持久化状态。
struct SessionDocumentFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct SessionDocumentRecoveryCheckpoint: Codable, Equatable, Sendable {
    let epoch: UInt64
    let receiptDigest: String
    let manifestRoot: String
    let artifactIDs: [String]
    let previousReceiptDigest: String
    let previousManifestRoot: String
}

struct SessionDocumentTab: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    var title: String
    var text: String
    /// 用户最近一次显式保存的内容；dirty 由 text 与 savedText 比较得出。
    var savedText: String
    /// nil = 仅存在于会话内；非 nil = 从外部文件打开或已另存为。
    var fileURL: URL?
    /// 外部文档的路径身份与内容版本；同路径替换不得静默恢复为当前文档。
    var fileIdentity: SessionDocumentFileIdentity?
    var fileContentHash: String?
    var createdAt: Date
    var updatedAt: Date
    // Stage metadata lives in a separate versioned checkpoint. Keep the original
    // document envelope readable by previous packages' strict tab scanner.
    var documentPipeline: DocumentPipeline? = nil
    private enum CodingKeys: String, CodingKey {
        case id, sessionID, title, text, savedText, fileURL, fileIdentity, fileContentHash, createdAt, updatedAt
    }

    var isDirty: Bool { text != savedText }
    /// `content` 是给会话/聊天接线层的语义别名，不改变持久化字段。
    var content: String {
        get { text }
        set { text = newValue }
    }

    /// Stable identity for the exact document content used by a consumer.
    /// Session and tab IDs keep equal text in separate documents distinct.
    var documentRevision: String {
        SessionDocumentRevision.make(
            sessionID: sessionID, tabID: id, text: text, updatedAt: updatedAt
        )
    }

    var revision: String { documentRevision }

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        title: String,
        text: String = "",
        savedText: String? = nil,
        fileURL: URL? = nil,
        fileIdentity: SessionDocumentFileIdentity? = nil,
        fileContentHash: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        documentPipeline: DocumentPipeline? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.text = text
        self.savedText = savedText ?? text
        self.fileURL = fileURL
        self.fileIdentity = fileIdentity
        self.fileContentHash = fileContentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.documentPipeline = documentPipeline
    }
}

/// 一个 session 的 Tab 列表与选中指针。这里没有 workspace ID 或全局当前文档。
struct SessionDocumentSessionState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let sessionID: UUID
    var tabs: [SessionDocumentTab]
    var selectedTabID: UUID?
    /// Highest committed cleanup-journal generation for this session. It is
    /// persisted with the document so a stale journal cannot be replayed after
    /// the diagnostic file itself has been retired.
    var recoveryGeneration: UInt64?
    var recoveryDiagnosticDigest: String?
    /// Checkpoint compaction handoff fence. These values describe the last
    /// committed receipt set, independently of the active journal file.
    var recoveryCheckpointEpoch: UInt64?
    var recoveryCheckpointReceiptDigest: String?
    var recoveryCheckpointManifestRoot: String?
    var recoveryCheckpointArtifactIDs: [String]?
    var recoveryCheckpointHistory: [SessionDocumentRecoveryCheckpoint]?
    var recoveryCheckpointHistoryDigest: String?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionID: UUID,
        tabs: [SessionDocumentTab] = [],
        selectedTabID: UUID? = nil,
        recoveryGeneration: UInt64? = nil,
        recoveryDiagnosticDigest: String? = nil,
        recoveryCheckpointEpoch: UInt64? = nil,
        recoveryCheckpointReceiptDigest: String? = nil,
        recoveryCheckpointManifestRoot: String? = nil,
        recoveryCheckpointArtifactIDs: [String]? = nil,
        recoveryCheckpointHistory: [SessionDocumentRecoveryCheckpoint]? = nil,
        recoveryCheckpointHistoryDigest: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.recoveryGeneration = recoveryGeneration
        self.recoveryDiagnosticDigest = recoveryDiagnosticDigest
        self.recoveryCheckpointEpoch = recoveryCheckpointEpoch
        self.recoveryCheckpointReceiptDigest = recoveryCheckpointReceiptDigest
        self.recoveryCheckpointManifestRoot = recoveryCheckpointManifestRoot
        self.recoveryCheckpointArtifactIDs = recoveryCheckpointArtifactIDs
        self.recoveryCheckpointHistory = recoveryCheckpointHistory
        self.recoveryCheckpointHistoryDigest = recoveryCheckpointHistoryDigest
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionID
        case tabs
        case selectedTabID
        case recoveryGeneration
        case recoveryDiagnosticDigest
        case recoveryCheckpointEpoch
        case recoveryCheckpointReceiptDigest
        case recoveryCheckpointManifestRoot
        case recoveryCheckpointArtifactIDs
        case recoveryCheckpointHistory
        case recoveryCheckpointHistoryDigest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(
            Int.self, forKey: .schemaVersion
        ) ?? Self.currentSchemaVersion
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.tabs = try container.decode([SessionDocumentTab].self, forKey: .tabs)
        self.selectedTabID = try container.decodeIfPresent(
            UUID.self, forKey: .selectedTabID
        )
        self.recoveryGeneration = try container.decodeIfPresent(
            UInt64.self, forKey: .recoveryGeneration
        )
        self.recoveryDiagnosticDigest = try container.decodeIfPresent(
            String.self, forKey: .recoveryDiagnosticDigest
        )
        self.recoveryCheckpointEpoch = try container.decodeIfPresent(
            UInt64.self, forKey: .recoveryCheckpointEpoch
        )
        self.recoveryCheckpointReceiptDigest = try container.decodeIfPresent(
            String.self, forKey: .recoveryCheckpointReceiptDigest
        )
        self.recoveryCheckpointManifestRoot = try container.decodeIfPresent(
            String.self, forKey: .recoveryCheckpointManifestRoot
        )
        self.recoveryCheckpointArtifactIDs = try container.decodeIfPresent(
            [String].self, forKey: .recoveryCheckpointArtifactIDs
        )
        self.recoveryCheckpointHistory = try container.decodeIfPresent(
            [SessionDocumentRecoveryCheckpoint].self,
            forKey: .recoveryCheckpointHistory
        )
        self.recoveryCheckpointHistoryDigest = try container.decodeIfPresent(
            String.self, forKey: .recoveryCheckpointHistoryDigest
        )
    }
}

/// 发送到对话时生成的值快照；后续 Tab 编辑不会改变已返回的文本。
struct SessionDocumentTextSnapshot: Equatable, Sendable {
    let sessionID: UUID
    let tabID: UUID
    let title: String
    let text: String
    let revision: String

    init(
        sessionID: UUID,
        tabID: UUID,
        title: String,
        text: String,
        revision: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.tabID = tabID
        self.title = title
        self.text = text
        self.revision = revision ?? SessionDocumentRevision.make(
            sessionID: sessionID, tabID: tabID, text: text, updatedAt: updatedAt
        )
    }

    var content: String { text }
    var documentRevision: String { revision }
}

/// Hash-based revision for fencing asynchronous consumers against stale text.
enum SessionDocumentRevision {
    static func make(
        sessionID: UUID,
        tabID: UUID,
        text: String,
        updatedAt: Date? = nil
    ) -> String {
        let identity = [
            sessionID.uuidString.lowercased(),
            tabID.uuidString.lowercased(),
            text,
            updatedAt.map { $0.timeIntervalSince1970.bitPattern.description } ?? "",
        ].joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum SessionDocumentCloseDecision: Equatable, Sendable {
    case save
    case discard
    case cancel
}

enum SessionDocumentCloseResult: Equatable, Sendable {
    case closed
    case requiresConfirmation
    case canceled
}

enum SessionDocumentStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidTitle
    case tabNotFound
    case cannotRead(URL)
    case invalidUTF8(URL)
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .invalidTitle:
            return "文档标题不能为空。"
        case .tabNotFound:
            return "找不到指定的会话文档 Tab。"
        case let .cannotRead(url):
            return "无法读取文档：\(url.lastPathComponent)"
        case let .invalidUTF8(url):
            return "文档不是有效的 UTF-8 文本：\(url.lastPathComponent)"
        case let .cannotWrite(url):
            return "无法写入文档：\(url.lastPathComponent)"
        }
    }
}

/// 会话内文档存储。
///
/// - 每次编辑都会原子写入 session 恢复文件，确保崩溃/重启可恢复 dirty 内容。
/// - 显式 `save` 将当前内容标记为已保存；有外部 URL 时同时更新外部文本文件。
/// - 损坏的恢复文件移动到 quarantine，不会用一个独立 workspace 状态替代它。
final class SessionDocumentStore: @unchecked Sendable {
    static let documentsDirectoryName = "sessionDocuments"
    static let quarantineDirectoryName = "quarantine"
    private static let quarantineTombstonePrefix = "miniscanvas-recovery-tombstone-"
    private static let recoveryDiagnosticSuffix = ".cleanup-diagnostic.json"
    private static let recoveryDiagnosticCode = "quarantine-cleanup-pending"
    private static let recoveryDiagnosticMessage =
        "会话文档恢复清理未完成，隔离备份已保留；请检查隔离证据后再继续编辑。"
    private static let maxPersistedStateBytes = 8 * 1024 * 1024
    private static let maxQuarantineReceiptBytes = 8 * 1024 * 1024
    private static let maxQuarantineReceiptCount = 4_096
    private static let maxQuarantineReceiptSetBytes = 32 * 1024 * 1024
    private static let maxRecoveryCheckpointHistoryCount = 8
    // A cleanup journal is metadata, not a document payload. Keep malformed
    // or attacker-sized evidence bounded before JSON parsing or hashing it.
    private static let maxRecoveryDiagnosticBytes = 2 * 1024 * 1024
    private static let maxPersistedTabCount = 4_096

    let directory: URL
    let documentsDirectory: URL
    let quarantineDirectory: URL

    /// 永远为 false，用于让 composition root 的接线测试明确证明没有 workspace 状态。
    var hasWorkspaceState: Bool { false }

    private let lock = NSLock()
    private var sessions: [UUID: SessionDocumentSessionState] = [:]
    private var activeDocumentStageAttempts: Set<UUID> = []
    private var documentStageBaselines: [UUID: FilesystemIdentity] = [:]
    private var documentStageCloseWarnings: [UUID: String] = [:]
    private var recoveryFailures: Set<UUID> = []
    private struct PersistedStateBaseline {
        let identity: SessionDocumentFileIdentity?
    }
    private struct FilesystemIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
        let mode: UInt32
        let hardLinkCount: UInt64
    }
    // On Darwin, a directory's link count changes with controlled member
    // creation/removal. Object continuity is the stable identity tuple; call
    // sites that need inventory stability retain their separate name/revision
    // snapshots. Regular-file comparisons continue to use full equality.
    private static func isSameDirectoryObject(
        _ current: FilesystemIdentity?,
        as expected: FilesystemIdentity
    ) -> Bool {
        guard let current else { return false }
        return current.device == expected.device
            && current.inode == expected.inode
            && current.owner == expected.owner
            && current.mode == expected.mode
    }
    private enum QuarantineArtifactKind {
        case original(UUID)
        case tombstone(QuarantineCleanupReceipt)
        case unownedTombstone
    }
    private struct QuarantineCleanupReceipt {
        let sessionID: UUID
        let identity: SessionDocumentFileIdentity
        let contentHash: String
        let artifactID: UUID
    }
    private struct RecoverySegmentPayloadIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: UInt64
        let contentHash: String
    }
    private struct RecoveryDiagnostic: Codable, Equatable {
        enum Phase: String, Codable {
            case prepared
            case committed
        }

        let sessionID: UUID
        let code: String
        let anomalyKey: String
        let canonicalPayload: String
        let generation: String
        let previousDigest: String
        let checkpointEpoch: String
        let receiptDigest: String
        let segmentManifestRoot: String
        let segmentPayloadIdentities: [String: RecoverySegmentPayloadIdentity]
        let targetFileIdentities: [String: SessionDocumentFileIdentity]
        let phase: Phase
        let message: String
    }
    private struct QuarantineDirectoryRevision: Equatable {
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }
    private struct QuarantineReceiptFingerprint: Equatable {
        let identity: SessionDocumentFileIdentity
        let byteCount: UInt64
        let contentHash: String
    }
    private struct QuarantineCapacitySnapshot: Equatable {
        let count: Int
        let totalBytes: UInt64
        let setDigest: String
    }
    private struct QuarantineCleanupSnapshot: Equatable {
        let directoryRevision: QuarantineDirectoryRevision
        let receiptNames: [String]
        let receiptFingerprints: [String: QuarantineReceiptFingerprint]
        let capacity: QuarantineCapacitySnapshot
    }
    private var persistedBaselines: [UUID: PersistedStateBaseline] = [:]
    private var recoveryGenerationFloors: [UUID: UInt64] = [:]
    private var recoveryDiagnosticDigestFloors: [UUID: String] = [:]
    private var recoveryCheckpointEpochFloors: [UUID: UInt64] = [:]
    private var recoveryCheckpointReceiptDigestFloors: [UUID: String] = [:]
    private var recoveryCheckpointManifestRootFloors: [UUID: String] = [:]
    private var recoveryCheckpointArtifactIDFloors: [UUID: Set<String>] = [:]
    private var recoveryCheckpointHistoryFloors: [UUID: [SessionDocumentRecoveryCheckpoint]] = [:]
    private var recoveryCheckpointHistoryDigestFloors: [UUID: String] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let recoveryDiagnosticEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let recoveryCheckpointEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func stableMappedURL(_ url: URL) -> URL? {
        guard case .resolved(let rawMapped) = DarwinSystemPathResolver.resolveOutcome(url),
              case .resolved(let standardizedMapped) = DarwinSystemPathResolver.resolveOutcome(
                  url.standardizedFileURL
              ),
              case .resolved(let resolvedMapped) = DarwinSystemPathResolver.resolveOutcome(
                  url.resolvingSymlinksInPath().standardizedFileURL
              ),
              rawMapped == standardizedMapped,
              rawMapped == resolvedMapped else {
            return nil
        }
        return URL(fileURLWithPath: rawMapped, isDirectory: url.hasDirectoryPath)
    }

    init(directory: URL) {
        let mappedDirectory = Self.stableMappedURL(directory) ?? directory
        self.directory = mappedDirectory
        self.documentsDirectory = mappedDirectory.appendingPathComponent(
            Self.documentsDirectoryName, isDirectory: true
        )
        self.quarantineDirectory = mappedDirectory
            .appendingPathComponent(Self.documentsDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.quarantineDirectoryName, isDirectory: true)
    }

    /// 返回某个 session 的恢复状态；不存在或损坏时返回空状态。
    func state(for sessionID: UUID) -> SessionDocumentSessionState {
        lock.lock(); defer { lock.unlock() }
        return loadStateLocked(for: sessionID)
    }

    func restoreSession(_ sessionID: UUID) -> SessionDocumentSessionState {
        state(for: sessionID)
    }

    /// Indicates that the persisted recovery file was quarantined for this session.
    /// An empty state after a recovery failure must not be presented as a normal empty session.
    func hasRecoveryFailure(for sessionID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let diagnostic = loadRecoveryDiagnosticLocked(for: sessionID) {
            if diagnostic.phase == .prepared
                    || hasQuarantinedArtifactLocked(for: sessionID) {
                recoveryFailures.insert(sessionID)
            } else {
                recoveryFailures.remove(sessionID)
            }
        } else if hasRecoveryDiagnosticArtifactLocked(for: sessionID)
                    || hasQuarantinedArtifactLocked(for: sessionID) {
            // A diagnostic that cannot be decoded is still recovery evidence;
            // do not present a blocked session as a normal empty workspace.
            recoveryFailures.insert(sessionID)
        }
        return recoveryFailures.contains(sessionID)
    }

    /// Stable user-facing detail for a persisted recovery-cleanup anomaly.
    /// The diagnostic is one reserved file per session, never an append-only
    /// log, so restarting does not multiply the same warning.
    func recoveryDiagnostic(for sessionID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let diagnostic = loadRecoveryDiagnosticLocked(for: sessionID) {
            if diagnostic.phase == .prepared
                    || hasQuarantinedArtifactLocked(for: sessionID) {
                recoveryFailures.insert(sessionID)
                return diagnostic.message
            }
            recoveryFailures.remove(sessionID)
            return nil
        }
        if hasRecoveryDiagnosticArtifactLocked(for: sessionID) {
            recoveryFailures.insert(sessionID)
            return Self.recoveryDiagnosticMessage
        }
        guard recoveryFailures.contains(sessionID) else { return nil }
        return Self.recoveryDiagnosticMessage
    }

    func sessionFileURL(for sessionID: UUID) -> URL {
        documentsDirectory.appendingPathComponent("\(sessionID.uuidString).json")
    }

    func tab(sessionID: UUID, tabID: UUID) -> SessionDocumentTab? {
        lock.lock(); defer { lock.unlock() }
        return loadStateLocked(for: sessionID).tabs.first { $0.id == tabID }
    }

    /// Returns whether a captured document snapshot still names current text.
    /// Missing or moved tabs fail closed instead of accepting a late result.
    func isCurrent(_ snapshot: SessionDocumentTextSnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let tab = loadStateLocked(for: snapshot.sessionID).tabs.first(where: {
            $0.id == snapshot.tabID
        }) else { return false }
        return tab.documentRevision == snapshot.revision
    }

    /// 新建一个会话内 Tab。
    @discardableResult
    func newTab(
        sessionID: UUID,
        title: String,
        content: String = ""
    ) throws -> SessionDocumentTab {
        let normalizedTitle = try Self.normalizedTitle(title)
        lock.lock(); defer { lock.unlock() }
        var state = loadStateLocked(for: sessionID)
        let tab = SessionDocumentTab(
            sessionID: sessionID, title: normalizedTitle, text: content
        )
        state.tabs.append(tab)
        state.selectedTabID = tab.id
        try persistLocked(state)
        sessions[sessionID] = state
        return tab
    }

    /// 从外部 UTF-8 文本文件打开一个 Tab；同一 session 已打开同一 URL 时只复用原 Tab。
    @discardableResult
    func openDocument(sessionID: UUID, fileURL: URL) throws -> SessionDocumentTab {
        guard let canonicalURL = Self.stableMappedURL(fileURL) else {
            throw SessionDocumentStoreError.cannotRead(fileURL)
        }
        lock.lock(); defer { lock.unlock() }
        var state = loadStateLocked(for: sessionID)
        if let existingIndex = state.tabs.firstIndex(where: {
            guard let existingURL = $0.fileURL else { return false }
            return Self.stableMappedURL(existingURL) == canonicalURL
        }) {
            guard isFileFenceCurrent(state.tabs[existingIndex]) else {
                throw SessionDocumentStoreError.cannotRead(canonicalURL)
            }
            state.selectedTabID = state.tabs[existingIndex].id
            try persistLocked(state)
            sessions[sessionID] = state
            return state.tabs[existingIndex]
        }

        let external = try readExternalDocument(at: canonicalURL)
        let text = external.text
        let title = canonicalURL.deletingPathExtension().lastPathComponent
        let tab = SessionDocumentTab(
            sessionID: sessionID,
            title: title.isEmpty ? "未命名文档" : title,
            text: text,
            fileURL: canonicalURL,
            fileIdentity: external.identity,
            fileContentHash: external.contentHash
        )
        state.tabs.append(tab)
        state.selectedTabID = tab.id
        try persistLocked(state)
        sessions[sessionID] = state
        return tab
    }

    @discardableResult
    func selectTab(sessionID: UUID, tabID: UUID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var state = loadStateLocked(for: sessionID)
        guard state.tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        guard state.selectedTabID != tabID else { return true }
        state.selectedTabID = tabID
        try persistLocked(state)
        sessions[sessionID] = state
        return true
    }

    /// 编辑内容。恢复快照立即原子落盘，显式保存状态由 `save`/`saveAs` 完成。
    @discardableResult
    func updateText(
        sessionID: UUID,
        tabID: UUID,
        text: String
    ) throws -> SessionDocumentTab {
        lock.lock(); defer { lock.unlock() }
        var state = loadStateLocked(for: sessionID)
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
            throw SessionDocumentStoreError.tabNotFound
        }
        state.tabs[index].text = text
        state.tabs[index].updatedAt = Self.nextUpdateDate(after: state.tabs[index].updatedAt)
        try persistLocked(state)
        sessions[sessionID] = state
        return state.tabs[index]
    }

    private struct DocumentStageCheckpoint: Codable {
        let version: Int
        let sessionID: UUID
        let pipelines: [String: DocumentPipeline]
        let revisions: [String: String]
    }

    private var documentStagesDirectory: URL { directory.appendingPathComponent("document-stages", isDirectory: true) }

    /// Uses the same pinned regular-file reader/atomic writer as document recovery,
    /// in a separate directory that old package document scanners never visit.
    private func loadDocumentStageStateLocked(sessionID: UUID) throws -> SessionDocumentSessionState {
        var state = loadStateLocked(for: sessionID)
        guard let baseline = persistedBaselines[sessionID],
              try persistedStateIdentity(at: sessionFileURL(for: sessionID)) == baseline.identity else {
            throw DocumentStageError(message: "文档恢复文件已变化，请重新打开文档后再执行阶段。")
        }
        let parent = documentStagesDirectory
        let url = parent.appendingPathComponent(sessionID.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            documentStageBaselines.removeValue(forKey: sessionID)
            return state
        }
        let parentIdentity = try filesystemIdentity(at: parent, requiringDirectory: true)
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SessionDocumentStoreError.cannotRead(url) }
        defer { _ = close(fd) }
        guard try filesystemIdentity(of: fd, requiringDirectory: true, errorURL: parent) == parentIdentity,
              let identity = try existingFilesystemIdentity(in: fd, name: url.lastPathComponent,
                  requiringDirectory: false, errorURL: url) else { throw SessionDocumentStoreError.cannotRead(url) }
        let input = openat(fd, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else { throw SessionDocumentStoreError.cannotRead(url) }
        defer { _ = close(input) }
        guard try filesystemIdentity(of: input, requiringDirectory: false, errorURL: url) == identity else {
            throw SessionDocumentStoreError.cannotRead(url)
        }
        guard identity.hardLinkCount == 1, identity.mode == 0o600 else {
            throw SessionDocumentStoreError.cannotRead(url)
        }
        let data = try readPersistedState(from: input, errorURL: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object, Set(object.keys) == Set(["version", "sessionID", "pipelines", "revisions"]),
              let pipelines = object["pipelines"] as? [String: [String: Any]], pipelines.count <= 4096 else {
            throw SessionDocumentStoreError.cannotRead(url)
        }
        guard let revisions = object["revisions"] as? [String: String],
              Set(pipelines.keys) == Set(revisions.keys),
              revisions.keys.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }),
              revisions.values.allSatisfy({ !$0.isEmpty }) else {
            throw SessionDocumentStoreError.cannotRead(url)
        }
        for value in pipelines.values {
            guard Set(value.keys) == Set(["stages", "currentIndex"]),
                  let stages = value["stages"] as? [[String: Any]], stages.count <= 64 else {
                throw SessionDocumentStoreError.cannotRead(url)
            }
            for stage in stages {
                guard Set(stage.keys).isSubset(of: Set(["id", "name", "providerID", "modelID",
                    "promptTemplate", "input", "output", "status", "outputLineage", "execution"])) else {
                    throw SessionDocumentStoreError.cannotRead(url)
                }
                if let lineage = stage["outputLineage"] as? [String: Any],
                   !Set(lineage.keys).isSubset(of: Set(["artifactID", "sourceArtifactID", "sourceRevision", "resultRevision", "recordedAt"])) {
                    throw SessionDocumentStoreError.cannotRead(url)
                }
                if let run = stage["execution"] as? [String: Any],
                   !Set(run.keys).isSubset(of: Set(["id", "sourceRevision", "state", "failureMessage"])) {
                    throw SessionDocumentStoreError.cannotRead(url)
                }
            }
        }
        let checkpoint = try JSONDecoder().decode(DocumentStageCheckpoint.self, from: data)
        guard checkpoint.version == 1, checkpoint.sessionID == sessionID else {
            throw SessionDocumentStoreError.cannotRead(url)
        }
        for pipeline in checkpoint.pipelines.values {
            guard pipeline.stages.count <= 64,
                  Set(pipeline.stages.map(\.id)).count == pipeline.stages.count,
                  pipeline.stages.isEmpty ? pipeline.currentIndex == 0 : pipeline.stages.indices.contains(pipeline.currentIndex)
            else { throw SessionDocumentStoreError.cannotRead(url) }
        }
        for i in state.tabs.indices {
            guard var pipeline = checkpoint.pipelines[state.tabs[i].id.uuidString] else { continue }
            if checkpoint.revisions[state.tabs[i].id.uuidString] != state.tabs[i].documentRevision {
                for j in pipeline.stages.indices {
                    pipeline.stages[j].status = .stale
                    if var run = pipeline.stages[j].execution, run.state == .running {
                        run.state = .failed
                        run.failureMessage = "文档内容已变化；旧请求的结果不会写回。"
                        pipeline.stages[j].execution = run
                    }
                }
            }
            state.tabs[i].documentPipeline = pipeline
        }
        documentStageBaselines[sessionID] = identity
        return state
    }

    private func persistDocumentStagesLocked(_ state: SessionDocumentSessionState) throws {
        let parent = documentStagesDirectory
        if mkdir(parent.path, mode_t(0o700)) != 0 && errno != EEXIST {
            throw SessionDocumentStoreError.cannotWrite(parent)
        }
        let parentIdentity = try filesystemIdentity(at: parent, requiringDirectory: true)
        guard parentIdentity.mode == 0o700 else {
            throw SessionDocumentStoreError.cannotWrite(parent)
        }
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SessionDocumentStoreError.cannotWrite(parent) }
        defer { _ = close(fd) }
        guard try filesystemIdentity(of: fd, requiringDirectory: true, errorURL: parent) == parentIdentity else {
            throw SessionDocumentStoreError.cannotWrite(parent)
        }
        let name = state.sessionID.uuidString + ".json"
        let url = parent.appendingPathComponent(name)
        let expected = try existingFilesystemIdentity(in: fd, name: name, requiringDirectory: false, errorURL: url)
        guard expected == documentStageBaselines[state.sessionID],
              expected.map({ $0.hardLinkCount == 1 && $0.mode == 0o600 }) ?? true else {
            throw DocumentStageError(message: "阶段恢复记录已被其它操作更新，请重新打开文档。")
        }
        let checkpoint = DocumentStageCheckpoint(version: 1, sessionID: state.sessionID,
            pipelines: Dictionary(uniqueKeysWithValues: state.tabs.compactMap { tab in
                tab.documentPipeline.map { (tab.id.uuidString, $0) }
            }), revisions: Dictionary(uniqueKeysWithValues: state.tabs.compactMap { tab in
                tab.documentPipeline == nil ? nil : (tab.id.uuidString, tab.documentRevision)
            }))
        let data = try JSONEncoder().encode(checkpoint)
        let written = try writeStateAtomically(data, fileName: name, in: fd, errorURL: url,
            expectedDestinationIdentity: expected, requireDestinationMissing: expected == nil)
        documentStageBaselines[state.sessionID] = written
    }

    func documentStageCloseWarning(sessionID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return documentStageCloseWarnings[sessionID]
    }

    func documentStageState(sessionID: UUID) throws -> SessionDocumentSessionState {
        lock.lock(); defer { lock.unlock() }
        _ = loadStateLocked(for: sessionID)
        let sessionLock = try acquireDocumentSessionLock(sessionID)
        defer { releaseDocumentSessionLock(sessionLock) }
        let state = try loadDocumentStageStateLocked(sessionID: sessionID)
        sessions[sessionID] = state
        return state
    }

    /// Pipeline metadata uses the existing atomic session recovery envelope.
    /// It deliberately does not change text/updatedAt (the input revision).
    @discardableResult
    func setDocumentPipeline(sessionID: UUID, tabID: UUID, pipeline: DocumentPipeline,
                             expectedRevision: String, expectedPipeline: DocumentPipeline?) throws -> SessionDocumentTab {
        lock.lock(); defer { lock.unlock() }
        _ = loadStateLocked(for: sessionID)
        let sessionLock = try acquireDocumentSessionLock(sessionID)
        defer { releaseDocumentSessionLock(sessionLock) }
        var state = try loadDocumentStageStateLocked(sessionID: sessionID)
        guard let i = state.tabs.firstIndex(where: { $0.id == tabID }),
              state.tabs[i].documentRevision == expectedRevision,
              state.tabs[i].documentPipeline == expectedPipeline,
              !(state.tabs[i].documentPipeline?.stages.contains {
                  $0.execution?.state == .running || ($0.execution.map { activeDocumentStageAttempts.contains($0.id) } ?? false)
              } ?? false)
        else { throw DocumentStageError(message: "文档或阶段已变化，请重新打开阶段面板。") }
        state.tabs[i].documentPipeline = pipeline
        try persistDocumentStagesLocked(state); sessions[sessionID] = state
        return state.tabs[i]
    }

    func beginDocumentStage(sessionID: UUID, tabID: UUID, index: Int,
                            expectedRevision: String, expectedStage: DocumentStage) throws -> (DocumentPipeline, DocumentStageRun, String) {
        lock.lock(); defer { lock.unlock() }
        _ = loadStateLocked(for: sessionID)
        let sessionLock = try acquireDocumentSessionLock(sessionID)
        defer { releaseDocumentSessionLock(sessionLock) }
        var state = try loadDocumentStageStateLocked(sessionID: sessionID)
        guard let i = state.tabs.firstIndex(where: { $0.id == tabID }),
              state.tabs[i].documentRevision == expectedRevision,
              var pipeline = state.tabs[i].documentPipeline,
              pipeline.stages.indices.contains(index),
              pipeline.stages[index] == expectedStage,
              !pipeline.stages.contains(where: {
                  $0.execution?.state == .running || ($0.execution.map { activeDocumentStageAttempts.contains($0.id) } ?? false)
              }),
              pipeline.stages[index].execution?.state != .succeeded,
              pipeline.stages[index].status != .done,
              index == 0 || pipeline.stages[index - 1].status == .done
        else { throw DocumentStageError(message: "请先完成并审核上一阶段；已完成的结果不会重复执行。") }
        pipeline.stages[index].input = index == 0 ? state.tabs[i].text : pipeline.stages[index - 1].output
        let run = DocumentStageRun(id: UUID(), sourceRevision: expectedRevision, state: .running)
        pipeline.stages[index].execution = run
        pipeline.stages[index].status = .running
        state.tabs[i].documentPipeline = pipeline
        try persistDocumentStagesLocked(state); sessions[sessionID] = state
        activeDocumentStageAttempts.insert(run.id)
        return (pipeline, run, state.tabs[i].text)
    }

    func documentStageIsCurrent(sessionID: UUID, tabID: UUID, stageID: UUID,
                                run: DocumentStageRun) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _ = loadStateLocked(for: sessionID)
        guard activeDocumentStageAttempts.contains(run.id),
              let sessionLock = try? acquireDocumentSessionLock(sessionID) else { return false }
        defer { releaseDocumentSessionLock(sessionLock) }
        guard let state = try? loadDocumentStageStateLocked(sessionID: sessionID) else { return false }
        guard let tab = state.tabs.first(where: { $0.id == tabID }),
              tab.documentRevision == run.sourceRevision,
              let stage = tab.documentPipeline?.stages.first(where: { $0.id == stageID }) else { return false }
        return stage.execution?.id == run.id && stage.execution?.state == .running
    }

    /// A newly opened Store has no live execution handles. Old running records
    /// become durable failures, without pretending a previous request succeeded.
    func recoverInterruptedDocumentStages(sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        _ = loadStateLocked(for: sessionID)
        let sessionLock = try acquireDocumentSessionLock(sessionID)
        defer { releaseDocumentSessionLock(sessionLock) }
        var state = try loadDocumentStageStateLocked(sessionID: sessionID)
        var changed = false
        for i in state.tabs.indices {
            guard var pipeline = state.tabs[i].documentPipeline else { continue }
            for j in pipeline.stages.indices {
                guard var run = pipeline.stages[j].execution, run.state == .running,
                      !activeDocumentStageAttempts.contains(run.id) else { continue }
                run.state = .failed
                run.failureMessage = "上次阶段执行已中断，请检查保留内容后重试。"
                pipeline.stages[j].execution = run
                pipeline.stages[j].status = .pending
                changed = true
            }
            state.tabs[i].documentPipeline = pipeline
        }
        if changed { try persistDocumentStagesLocked(state) }
        sessions[sessionID] = state
    }

    /// One terminal write per attempt. Failed execution preserves earlier output.
    @discardableResult
    func finishDocumentStage(sessionID: UUID, tabID: UUID, stageID: UUID,
                             run: DocumentStageRun, output: String?, failure: String?) throws -> Bool {
        lock.lock(); defer { activeDocumentStageAttempts.remove(run.id); lock.unlock() }
        _ = loadStateLocked(for: sessionID)
        let sessionLock = try acquireDocumentSessionLock(sessionID)
        defer { releaseDocumentSessionLock(sessionLock) }
        guard activeDocumentStageAttempts.contains(run.id) else { return false }
        var state = try loadDocumentStageStateLocked(sessionID: sessionID)
        guard let i = state.tabs.firstIndex(where: { $0.id == tabID }),
              state.tabs[i].documentRevision == run.sourceRevision,
              var pipeline = state.tabs[i].documentPipeline,
              let j = pipeline.stages.firstIndex(where: { $0.id == stageID }),
              pipeline.stages[j].execution?.id == run.id else { return false }
        guard pipeline.stages[j].execution?.state == .running else { return false }
        var terminal = run
        terminal.state = output == nil ? .failed : .succeeded
        terminal.failureMessage = failure
        pipeline.stages[j].execution = terminal
        if let output {
            pipeline.stages[j].output = output
            pipeline.stages[j].status = .awaitingReview
        } else { pipeline.stages[j].status = .pending }
        state.tabs[i].documentPipeline = pipeline
        try persistDocumentStagesLocked(state); sessions[sessionID] = state
        return true
    }

    /// 显式保存当前 Tab；外部打开/另存为的文档也同步写回原文件。
    @discardableResult
    func save(sessionID: UUID, tabID: UUID) throws -> SessionDocumentTab {
        lock.lock(); defer { lock.unlock() }
        var state = loadStateLocked(for: sessionID)
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
            throw SessionDocumentStoreError.tabNotFound
        }
        let tab = state.tabs[index]
        if let fileURL = tab.fileURL {
            try writeTextAtomically(tab.text, to: fileURL)
        }
        state.tabs[index].savedText = tab.text
        if let fileURL = state.tabs[index].fileURL {
            let fence = try fileFence(for: fileURL)
            state.tabs[index].fileIdentity = fence.identity
            state.tabs[index].fileContentHash = fence.contentHash
        }
        // Saving unchanged input metadata must not invalidate stage input identity.
        try persistLocked(state)
        sessions[sessionID] = state
        return state.tabs[index]
    }

    /// 另存为外部 UTF-8 文本文件，并将 Tab 的文件定位更新为目标 URL。
    @discardableResult
    func saveAs(
        sessionID: UUID,
        tabID: UUID,
        to fileURL: URL
    ) throws -> SessionDocumentTab {
        guard let targetURL = Self.stableMappedURL(fileURL) else {
            throw SessionDocumentStoreError.cannotWrite(fileURL)
        }
        lock.lock(); defer { lock.unlock() }
        var state = loadStateLocked(for: sessionID)
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
            throw SessionDocumentStoreError.tabNotFound
        }
        try writeTextAtomically(state.tabs[index].text, to: targetURL)
        let derivedTitle = targetURL.deletingPathExtension().lastPathComponent
        state.tabs[index].fileURL = targetURL
        state.tabs[index].title = derivedTitle.isEmpty ? "未命名文档" : derivedTitle
        state.tabs[index].savedText = state.tabs[index].text
        let fence = try fileFence(for: targetURL)
        state.tabs[index].fileIdentity = fence.identity
        state.tabs[index].fileContentHash = fence.contentHash
        state.tabs[index].updatedAt = Self.nextUpdateDate(after: state.tabs[index].updatedAt)
        try persistLocked(state)
        sessions[sessionID] = state
        return state.tabs[index]
    }

    /// 关闭 Tab。dirty 且没有决策时只返回需要确认，不会删除内容。
    @discardableResult
    func closeTab(
        sessionID: UUID,
        tabID: UUID,
        decision: SessionDocumentCloseDecision? = nil
    ) throws -> SessionDocumentCloseResult {
        lock.lock(); defer { lock.unlock() }
        _ = loadStateLocked(for: sessionID)
        let sessionLock = try acquireDocumentSessionLock(sessionID)
        defer { releaseDocumentSessionLock(sessionLock) }
        var state = loadStateLocked(for: sessionID)
        var stageReadable = true
        do { state = try loadDocumentStageStateLocked(sessionID: sessionID) }
        catch { stageReadable = false }
        documentStageCloseWarnings.removeValue(forKey: sessionID)
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
            throw SessionDocumentStoreError.tabNotFound
        }
        if state.tabs[index].isDirty {
            guard let decision else { return .requiresConfirmation }
            if decision == .cancel { return .canceled }
            if decision == .save {
                let tab = state.tabs[index]
                if let fileURL = tab.fileURL {
                    try writeTextAtomically(tab.text, to: fileURL)
                }
                state.tabs[index].savedText = tab.text
                if let fileURL = state.tabs[index].fileURL {
                    let fence = try fileFence(for: fileURL)
                    state.tabs[index].fileIdentity = fence.identity
                    state.tabs[index].fileContentHash = fence.contentHash
                }
            }
        }
        let retiredStageAttempts = state.tabs[index].documentPipeline?.stages.compactMap { $0.execution?.id } ?? []
        for id in retiredStageAttempts { activeDocumentStageAttempts.remove(id) }
        state.tabs.remove(at: index)
        if state.selectedTabID == tabID {
            state.selectedTabID = state.tabs.first?.id
        }
        try persistLocked(state, sessionLock: sessionLock)
        sessions[sessionID] = state
        // The original close removes this tab's content. Drop its stage records
        // too, only after the document removal committed; no late run can re-add it.
        if FileManager.default.fileExists(atPath: documentStagesDirectory.appendingPathComponent(sessionID.uuidString + ".json").path) {
            if stageReadable {
                do { try persistDocumentStagesLocked(state) }
                catch { documentStageCloseWarnings[sessionID] = "原文档已关闭；阶段记录清理未确认，请检查恢复文件。" }
            } else {
                documentStageCloseWarnings[sessionID] = "原文档已关闭；阶段恢复记录异常，原记录未改动，请检查恢复文件。"
            }
        }
        return .closed
    }

    /// 返回要发送到对话的不可变文本快照。
    func sendToConversation(
        sessionID: UUID,
        tabID: UUID
    ) throws -> SessionDocumentTextSnapshot {
        lock.lock(); defer { lock.unlock() }
        let state = loadStateLocked(for: sessionID)
        guard let tab = state.tabs.first(where: { $0.id == tabID }) else {
            throw SessionDocumentStoreError.tabNotFound
        }
        return SessionDocumentTextSnapshot(
            sessionID: sessionID,
            tabID: tab.id,
            title: tab.title,
            text: tab.text,
            revision: tab.documentRevision,
            updatedAt: tab.updatedAt
        )
    }

    // MARK: - 内部

    private struct FileFence: Equatable {
        let identity: SessionDocumentFileIdentity
        let contentHash: String
    }

    private struct ExternalDocument {
        let text: String
        let identity: SessionDocumentFileIdentity
        let contentHash: String
    }

    private static func normalizedTitle(_ title: String) throws -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SessionDocumentStoreError.invalidTitle }
        return value
    }

    private static func nextUpdateDate(after previous: Date) -> Date {
        let now = Date()
        guard now > previous else {
            return Date(timeIntervalSince1970: previous.timeIntervalSince1970 + 0.000001)
        }
        return now
    }

    private func readExternalDocument(at url: URL) throws -> ExternalDocument {
        guard let canonical = Self.stableMappedURL(url) else {
            throw SessionDocumentStoreError.cannotRead(url)
        }
        let before = try readExternalFile(at: canonical)
        let after = try readExternalFile(at: canonical)
        guard before.identity == after.identity,
              before.data == after.data else {
            throw SessionDocumentStoreError.cannotRead(canonical)
        }
        guard let text = String(data: before.data, encoding: .utf8) else {
            throw SessionDocumentStoreError.invalidUTF8(canonical)
        }
        return ExternalDocument(
            text: text,
            identity: before.identity,
            contentHash: Self.sha256Hex(before.data)
        )
    }

    private func fileFence(for url: URL) throws -> FileFence {
        let read = try readExternalFile(at: url)
        return FileFence(
            identity: read.identity,
            contentHash: Self.sha256Hex(read.data)
        )
    }

    private func readExternalFile(
        at url: URL
    ) throws -> (data: Data, identity: SessionDocumentFileIdentity) {
        guard let canonical = Self.stableMappedURL(url) else {
            throw SessionDocumentStoreError.cannotRead(url)
        }
        let parentURL = canonical.deletingLastPathComponent()
        let parentDescriptor = open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else {
            throw SessionDocumentStoreError.cannotRead(canonical)
        }
        defer { _ = close(parentDescriptor) }
        guard let parentIdentity = try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: parentURL
        ), let initialIdentity = try? existingFilesystemIdentity(
            in: parentDescriptor,
            name: canonical.lastPathComponent,
            requiringDirectory: false,
            errorURL: canonical
        ) else {
            throw SessionDocumentStoreError.cannotRead(canonical)
        }
        let data = try readPersistedState(
            in: parentDescriptor,
            name: canonical.lastPathComponent,
            errorURL: canonical,
            maxBytes: Self.maxPersistedStateBytes
        )
        guard let finalIdentity = try? existingFilesystemIdentity(
            in: parentDescriptor,
            name: canonical.lastPathComponent,
            requiringDirectory: false,
            errorURL: canonical
        ), finalIdentity == initialIdentity,
        (try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: parentURL
        )) == parentIdentity,
        (try? filesystemIdentity(
            at: parentURL,
            requiringDirectory: true
        )) == parentIdentity else {
            throw SessionDocumentStoreError.cannotRead(canonical)
        }
        return (
            data,
            SessionDocumentFileIdentity(
                device: initialIdentity.device,
                inode: initialIdentity.inode
            )
        )
    }

    /// Read only the durable recovery file identity without following a symlink.
    /// A missing file is a valid baseline for the first writer; every other
    /// non-regular entry fails closed so a replacement cannot be admitted.
    private func persistedStateIdentity(at url: URL) throws -> SessionDocumentFileIdentity? {
        try validateCanonicalPath(url)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else {
                throw SessionDocumentStoreError.cannotWrite(url)
            }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
        return SessionDocumentFileIdentity(
            device: UInt64(info.st_dev), inode: UInt64(info.st_ino)
        )
    }

    private func readPersistedState(
        in directoryDescriptor: Int32,
        name: String,
        errorURL: URL,
        maxBytes: Int = SessionDocumentStore.maxPersistedStateBytes
    ) throws -> Data {
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SessionDocumentStoreError.cannotRead(errorURL)
        }
        defer { _ = close(descriptor) }
        return try readPersistedState(
            from: descriptor, errorURL: errorURL, maxBytes: maxBytes
        )
    }

    private func readPersistedState(
        from descriptor: Int32,
        errorURL: URL,
        maxBytes: Int = SessionDocumentStore.maxPersistedStateBytes
    ) throws -> Data {

        var initialInfo = stat()
        guard fstat(descriptor, &initialInfo) == 0,
              (initialInfo.st_mode & S_IFMT) == S_IFREG,
              initialInfo.st_size >= 0,
              UInt64(initialInfo.st_size) <= UInt64(maxBytes),
              UInt32(initialInfo.st_uid) == UInt32(getuid()) else {
            throw SessionDocumentStoreError.cannotRead(errorURL)
        }
        var data = Data()
        data.reserveCapacity(Int(initialInfo.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return read(descriptor, baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                throw SessionDocumentStoreError.cannotRead(errorURL)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maxBytes else {
                throw SessionDocumentStoreError.cannotRead(errorURL)
            }
        }
        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              (finalInfo.st_mode & S_IFMT) == S_IFREG,
              finalInfo.st_size >= 0,
              UInt64(finalInfo.st_size) <= UInt64(maxBytes),
              UInt32(finalInfo.st_uid) == UInt32(getuid()),
              finalInfo.st_dev == initialInfo.st_dev,
              finalInfo.st_ino == initialInfo.st_ino,
              finalInfo.st_size == off_t(data.count),
              finalInfo.st_mtimespec.tv_sec == initialInfo.st_mtimespec.tv_sec,
              finalInfo.st_mtimespec.tv_nsec == initialInfo.st_mtimespec.tv_nsec,
              finalInfo.st_ctimespec.tv_sec == initialInfo.st_ctimespec.tv_sec,
              finalInfo.st_ctimespec.tv_nsec == initialInfo.st_ctimespec.tv_nsec else {
            throw SessionDocumentStoreError.cannotRead(errorURL)
        }
        return data
    }

    private func validateCanonicalPath(_ url: URL) throws {
        guard Self.stableMappedURL(url) != nil else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
    }

    private func filesystemIdentity(
        at url: URL,
        requiringDirectory: Bool
    ) throws -> FilesystemIdentity {
        guard let identity = try existingFilesystemIdentity(
            at: url, requiringDirectory: requiringDirectory
        ) else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
        return identity
    }

    private func existingFilesystemIdentity(
        at url: URL,
        requiringDirectory: Bool
    ) throws -> FilesystemIdentity? {
        try validateCanonicalPath(url)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else {
                throw SessionDocumentStoreError.cannotWrite(url)
            }
            return nil
        }
        let expectedType = requiringDirectory ? S_IFDIR : S_IFREG
        guard (info.st_mode & S_IFMT) == expectedType else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
        let identity = FilesystemIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            owner: UInt32(info.st_uid),
            mode: UInt32(info.st_mode & 0o777),
            hardLinkCount: UInt64(info.st_nlink)
        )
        guard identity.owner == UInt32(getuid()) else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
        return identity
    }

    private func existingFilesystemIdentity(
        in directoryDescriptor: Int32,
        name: String,
        requiringDirectory: Bool,
        errorURL: URL
    ) throws -> FilesystemIdentity? {
        var info = stat()
        guard fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard errno == ENOENT else {
                throw SessionDocumentStoreError.cannotWrite(errorURL)
            }
            return nil
        }
        let expectedType = requiringDirectory ? S_IFDIR : S_IFREG
        guard (info.st_mode & S_IFMT) == expectedType else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        let identity = FilesystemIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            owner: UInt32(info.st_uid),
            mode: UInt32(info.st_mode & 0o777),
            hardLinkCount: UInt64(info.st_nlink)
        )
        guard identity.owner == UInt32(getuid()) else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        return identity
    }

    private func filesystemIdentity(
        of descriptor: Int32,
        requiringDirectory: Bool,
        errorURL: URL
    ) throws -> FilesystemIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        let expectedType = requiringDirectory ? S_IFDIR : S_IFREG
        guard (info.st_mode & S_IFMT) == expectedType else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        let identity = FilesystemIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            owner: UInt32(info.st_uid),
            mode: UInt32(info.st_mode & 0o777),
            hardLinkCount: UInt64(info.st_nlink)
        )
        guard identity.owner == UInt32(getuid()) else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        return identity
    }

    private func persistedStateIdentity(
        in directoryDescriptor: Int32,
        name: String,
        errorURL: URL
    ) throws -> SessionDocumentFileIdentity? {
        guard let identity = try existingFilesystemIdentity(
            in: directoryDescriptor,
            name: name,
            requiringDirectory: false,
            errorURL: errorURL
        ) else {
            return nil
        }
        return SessionDocumentFileIdentity(device: identity.device, inode: identity.inode)
    }

    private func recoveryDiagnosticURL(for sessionID: UUID) -> URL {
        documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString)\(Self.recoveryDiagnosticSuffix)"
        )
    }

    private static let recoveryDiagnosticKeys: Set<String> = [
        "sessionID", "code", "anomalyKey", "canonicalPayload", "generation",
        "previousDigest", "checkpointEpoch", "receiptDigest",
        "segmentManifestRoot", "segmentPayloadIdentities",
        "targetFileIdentities", "phase", "message"
    ]

    /// Decode only the exact canonical journal representation. Foundation's
    /// JSON decoder otherwise accepts duplicate keys and silently keeps the
    /// last value, which is unsafe for a cleanup receipt that authorizes an
    /// unlink.
    private func decodeRecoveryDiagnostic(_ data: Data) -> RecoveryDiagnostic? {
        guard data.count <= Self.maxRecoveryDiagnosticBytes else { return nil }
        var scanner = SessionDocumentJSONIntegrityScanner(
            data: data,
            allowedRootKeys: Self.recoveryDiagnosticKeys,
            maxObjectKeyCount: Self.maxQuarantineReceiptCount + 1
        )
        guard (try? scanner.validate()) != nil,
              let root = try? JSONSerialization.jsonObject(with: data),
              let root = root as? [String: Any],
              Set(root.keys) == Self.recoveryDiagnosticKeys,
              let targets = root["targetFileIdentities"] as? [String: Any],
              !targets.isEmpty,
              let segments = root["segmentPayloadIdentities"] as? [String: Any],
              !segments.isEmpty,
              Set(segments.keys) == Set(targets.keys),
              segments.allSatisfy({ key, value in
                  guard !key.isEmpty,
                        let segment = value as? [String: Any],
                        Set(segment.keys) == Set([
                            "device", "inode", "byteCount", "contentHash"
                        ]),
                        let device = segment["device"] as? NSNumber,
                        let inode = segment["inode"] as? NSNumber,
                        let byteCount = segment["byteCount"] as? NSNumber,
                        let contentHash = segment["contentHash"] as? String else {
                      return false
                  }
                  return device.uint64Value > 0 && inode.uint64Value > 0
                      && byteCount.uint64Value <= UInt64(Self.maxQuarantineReceiptBytes)
                      && contentHash.count == 64
                      && contentHash.allSatisfy({ $0.isHexDigit })
                      && contentHash.lowercased() == contentHash
              }),
              targets.allSatisfy({ key, value in
                  guard !key.isEmpty,
                        !key.contains("/"),
                        !key.contains("\0"),
                        key == key.precomposedStringWithCanonicalMapping,
                        key.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }),
                        let identity = value as? [String: Any],
                        Set(identity.keys) == Set(["device", "inode"]) else {
                      return false
                  }
                  return true
              }),
              let diagnostic = try? decoder.decode(
                  RecoveryDiagnostic.self, from: data
              ),
              diagnostic.code == Self.recoveryDiagnosticCode,
              diagnostic.anomalyKey == Self.recoveryDiagnosticCode,
              diagnostic.canonicalPayload.count == 64,
              diagnostic.canonicalPayload.allSatisfy({ $0.isHexDigit }),
              diagnostic.canonicalPayload.lowercased() == diagnostic.canonicalPayload,
              !diagnostic.generation.isEmpty,
              UInt64(diagnostic.generation).map({
                  $0 > 0 && String($0) == diagnostic.generation
              }) == true,
              diagnostic.previousDigest.count == 64,
              diagnostic.previousDigest.allSatisfy({ $0.isHexDigit }),
              diagnostic.previousDigest.lowercased() == diagnostic.previousDigest,
              !diagnostic.checkpointEpoch.isEmpty,
              UInt64(diagnostic.checkpointEpoch).map({
                  $0 > 0 && String($0) == diagnostic.checkpointEpoch
              }) == true,
              diagnostic.checkpointEpoch == diagnostic.generation,
              diagnostic.receiptDigest.count == 64,
              diagnostic.receiptDigest.allSatisfy({ $0.isHexDigit }),
              diagnostic.receiptDigest.lowercased() == diagnostic.receiptDigest,
              diagnostic.receiptDigest == diagnostic.canonicalPayload,
              diagnostic.segmentManifestRoot.count == 64,
              diagnostic.segmentManifestRoot.allSatisfy({ $0.isHexDigit }),
              diagnostic.segmentManifestRoot.lowercased() == diagnostic.segmentManifestRoot,
              !diagnostic.segmentPayloadIdentities.isEmpty,
              diagnostic.segmentPayloadIdentities.count <= Self.maxQuarantineReceiptCount,
              Set(diagnostic.segmentPayloadIdentities.keys)
                  == Set(diagnostic.targetFileIdentities.keys),
              diagnostic.segmentPayloadIdentities.allSatisfy({ key, segment in
                  guard let target = diagnostic.targetFileIdentities[key] else {
                      return false
                  }
                  return target.device == segment.device
                      && target.inode == segment.inode
                      && segment.byteCount
                          <= UInt64(Self.maxQuarantineReceiptBytes)
                      && segment.contentHash.count == 64
                      && segment.contentHash.allSatisfy({ $0.isHexDigit })
                      && segment.contentHash.lowercased() == segment.contentHash
              }),
              recoverySegmentManifestRoot(
                  targetFileIdentities: diagnostic.targetFileIdentities,
                  segmentPayloadIdentities: diagnostic.segmentPayloadIdentities
              ) == diagnostic.segmentManifestRoot,
              !diagnostic.targetFileIdentities.isEmpty,
              diagnostic.targetFileIdentities.allSatisfy({
                  !$0.key.isEmpty && !$0.key.contains("/")
                      && !$0.key.contains("\0")
                      && $0.key == $0.key.precomposedStringWithCanonicalMapping
                      && $0.key.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E })
                      && $0.value.device > 0 && $0.value.inode > 0
              }),
              diagnostic.phase == .prepared || diagnostic.phase == .committed,
              diagnostic.message == Self.recoveryDiagnosticMessage,
              let canonicalData = try? recoveryDiagnosticEncoder.encode(diagnostic),
              canonicalData == data else {
            return nil
        }
        return diagnostic
    }

    private func loadRecoveryDiagnosticLocked(
        for sessionID: UUID
    ) -> RecoveryDiagnostic? {
        let parentDescriptor = open(
            documentsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else { return nil }
        defer { _ = close(parentDescriptor) }
        let url = recoveryDiagnosticURL(for: sessionID)
        guard let identity = try? existingFilesystemIdentity(
            in: parentDescriptor,
            name: url.lastPathComponent,
            requiringDirectory: false,
            errorURL: url
        ), identity.mode == 0o600, identity.hardLinkCount == 1,
              let data = try? readPersistedState(
                  in: parentDescriptor,
                  name: url.lastPathComponent,
                  errorURL: url,
                  maxBytes: Self.maxRecoveryDiagnosticBytes
              ),
              let diagnostic = decodeRecoveryDiagnostic(data),
              diagnostic.sessionID == sessionID,
              (try? existingFilesystemIdentity(
                  in: parentDescriptor,
                  name: url.lastPathComponent,
                  requiringDirectory: false,
                  errorURL: url
              )) == identity else {
            return nil
        }
        return diagnostic
    }

    private func makeRecoveryDiagnosticLocked(
        for sessionID: UUID,
        previous: RecoveryDiagnostic?,
        previousGenerationFloor: UInt64? = nil,
        previousDigestFloor: String? = nil,
        previousCheckpointEpochFloor: UInt64? = nil,
        previousCheckpointReceiptDigestFloor: String? = nil,
        previousCheckpointManifestRootFloor: String? = nil,
        previousCheckpointArtifactIDsFloor: [String]? = nil,
        previousCheckpointHistoryFloor:
            [SessionDocumentRecoveryCheckpoint]? = nil
    ) -> RecoveryDiagnostic? {
        let parentDescriptor = open(
            documentsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else { return nil }
        defer { _ = close(parentDescriptor) }
        guard let parentIdentity = try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: documentsDirectory
        ) else { return nil }
        let quarantineDescriptor = openat(
            parentDescriptor,
            quarantineDirectory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard quarantineDescriptor >= 0 else { return nil }
        defer { _ = close(quarantineDescriptor) }
        guard let quarantineIdentity = try? filesystemIdentity(
            of: quarantineDescriptor,
            requiringDirectory: true,
            errorURL: quarantineDirectory
        ), let snapshot = try? quarantineCleanupSnapshot(
            parentDescriptor: parentDescriptor,
            parentIdentity: parentIdentity,
            quarantineDescriptor: quarantineDescriptor,
            quarantineIdentity: quarantineIdentity
        ), !snapshot.receiptFingerprints.isEmpty,
        hasUniqueOwnedReceiptIDs(in: snapshot.receiptNames, sessionID: sessionID) else {
            return nil
        }
        let canonicalPayload = snapshot.capacity.setDigest
        let targetFileIdentities = snapshot.receiptFingerprints.mapValues(\.identity)
        let segmentPayloadIdentities = snapshot.receiptFingerprints.mapValues {
            RecoverySegmentPayloadIdentity(
                device: $0.identity.device,
                inode: $0.identity.inode,
                byteCount: $0.byteCount,
                contentHash: $0.contentHash
            )
        }
        let segmentManifestRoot = recoverySegmentManifestRoot(
            targetFileIdentities: targetFileIdentities,
            segmentPayloadIdentities: segmentPayloadIdentities
        )
        let currentArtifactIDs = ownedArtifactIDs(
            in: snapshot.receiptNames, sessionID: sessionID
        )
        var blockedArtifactIDs = Set(previousCheckpointHistoryFloor?.flatMap(\.artifactIDs) ?? [])
        blockedArtifactIDs.formUnion(previousCheckpointArtifactIDsFloor ?? [])
        if let previous, previous.phase == .committed {
            blockedArtifactIDs.formUnion(ownedArtifactIDs(
                in: Array(previous.targetFileIdentities.keys), sessionID: sessionID
            ))
        }
        if previous == nil || previous?.phase == .committed {
            guard currentArtifactIDs.isDisjoint(with: blockedArtifactIDs) else {
                return nil
            }
        }
        if let previous,
           previous.phase == .committed,
           previous.canonicalPayload == canonicalPayload,
           previous.receiptDigest == canonicalPayload,
           previous.segmentManifestRoot == segmentManifestRoot,
           previous.segmentPayloadIdentities == segmentPayloadIdentities,
           previous.targetFileIdentities == targetFileIdentities {
            // The same committed candidate may be retried after a transient
            // cleanup failure; do not manufacture a forked generation.
            return previous
        }
        let checkpointEpoch: String
        let generation: String
        let previousDigest: String
        if let previous {
            if previous.phase == .prepared {
                guard UInt64(previous.generation) != nil,
                      previous.checkpointEpoch == previous.generation else {
                    return nil
                }
                generation = previous.generation
                checkpointEpoch = previous.checkpointEpoch
                previousDigest = previous.previousDigest
            } else {
                guard let previousGeneration = UInt64(previous.generation),
                      previousGeneration < UInt64.max,
                      previous.checkpointEpoch == previous.generation else {
                    return nil
                }
                generation = String(previousGeneration + 1)
                checkpointEpoch = generation
                previousDigest = recoveryDiagnosticDigest(previous)
            }
        } else if let previousGeneration = previousGenerationFloor,
                  let floorDigest = previousDigestFloor,
                  previousGeneration < UInt64.max,
                  floorDigest.count == 64,
                  let floorEpoch = previousCheckpointEpochFloor,
                  floorEpoch == previousGeneration,
                  let floorReceiptDigest = previousCheckpointReceiptDigestFloor,
                  floorReceiptDigest.count == 64,
                  floorReceiptDigest.allSatisfy({ $0.isHexDigit }),
                  floorReceiptDigest.lowercased() == floorReceiptDigest,
                  previousCheckpointManifestRootFloor?.count == 64,
                  previousCheckpointManifestRootFloor?.allSatisfy({ $0.isHexDigit }) == true,
                  previousCheckpointManifestRootFloor?.lowercased()
                      == previousCheckpointManifestRootFloor {
            generation = String(previousGeneration + 1)
            checkpointEpoch = String(floorEpoch + 1)
            previousDigest = floorDigest
        } else if let previousGeneration = previousGenerationFloor,
                  let floorDigest = previousDigestFloor,
                  previousGeneration < UInt64.max,
                  previousCheckpointEpochFloor == nil,
                  previousCheckpointReceiptDigestFloor == nil,
                  previousCheckpointManifestRootFloor == nil {
            // Legacy state has a generation/replay floor but no checkpoint
            // handoff fields yet; derive the first checkpoint epoch without
            // weakening the existing previousDigest chain.
            generation = String(previousGeneration + 1)
            checkpointEpoch = generation
            previousDigest = floorDigest
        } else {
            generation = "1"
            checkpointEpoch = "1"
            previousDigest = String(repeating: "0", count: 64)
        }
        let diagnostic = RecoveryDiagnostic(
            sessionID: sessionID,
            code: Self.recoveryDiagnosticCode,
            anomalyKey: Self.recoveryDiagnosticCode,
            canonicalPayload: canonicalPayload,
            generation: generation,
            previousDigest: previousDigest,
            checkpointEpoch: checkpointEpoch,
            receiptDigest: canonicalPayload,
            segmentManifestRoot: segmentManifestRoot,
            segmentPayloadIdentities: segmentPayloadIdentities,
            targetFileIdentities: targetFileIdentities,
            phase: .prepared,
            message: Self.recoveryDiagnosticMessage
        )
        // Keep the complete canonical journal bounded before it can become a
        // durable authorization for cleanup.  Re-decode the exact bytes here
        // so a future schema change cannot accidentally bypass the canonical
        // payload and identity fences below.
        guard let encoded = try? recoveryDiagnosticEncoder.encode(diagnostic),
              encoded.count <= Self.maxRecoveryDiagnosticBytes,
              decodeRecoveryDiagnostic(encoded) == diagnostic else {
            return nil
        }
        return diagnostic
    }

    private func isQuarantineEmptyLocked() -> Bool {
        let parentDescriptor = open(
            documentsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else { return false }
        defer { _ = close(parentDescriptor) }
        guard let parentIdentity = try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: documentsDirectory
        ) else { return false }
        let quarantineDescriptor = openat(
            parentDescriptor,
            quarantineDirectory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard quarantineDescriptor >= 0 else { return errno == ENOENT }
        defer { _ = close(quarantineDescriptor) }
        guard let quarantineIdentity = try? filesystemIdentity(
            of: quarantineDescriptor,
            requiringDirectory: true,
            errorURL: quarantineDirectory
        ), let snapshot = try? quarantineCleanupSnapshot(
            parentDescriptor: parentDescriptor,
            parentIdentity: parentIdentity,
            quarantineDescriptor: quarantineDescriptor,
            quarantineIdentity: quarantineIdentity
        ) else {
            return false
        }
        return snapshot.receiptNames.isEmpty
    }

    private func loadStateLocked(for sessionID: UUID) -> SessionDocumentSessionState {
        if let cached = sessions[sessionID] { return cached }
        let url = sessionFileURL(for: sessionID)
        guard let parentIdentity = try? filesystemIdentity(
            at: documentsDirectory, requiringDirectory: true
        ) else {
            return cacheEmptyStateLocked(for: sessionID)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return cacheEmptyStateLocked(for: sessionID)
        }
        guard let initialPathIdentity = try? persistedStateIdentity(at: url) else {
            quarantine(url: url, sessionID: sessionID)
            return cacheEmptyStateLocked(for: sessionID)
        }
        let directoryDescriptor = open(
            documentsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            return cacheEmptyStateLocked(for: sessionID)
        }
        defer { _ = close(directoryDescriptor) }
        guard let openedParentIdentity = try? filesystemIdentity(
            of: directoryDescriptor,
            requiringDirectory: true,
            errorURL: documentsDirectory
        ),
              openedParentIdentity == parentIdentity,
              let initialIdentity = try? persistedStateIdentity(
                  in: directoryDescriptor,
                  name: url.lastPathComponent,
                  errorURL: url
              ),
              initialIdentity == initialPathIdentity,
              let data = try? readPersistedState(
                  in: directoryDescriptor,
                  name: url.lastPathComponent,
                  errorURL: url
              ),
              let finalIdentity = try? persistedStateIdentity(
                  in: directoryDescriptor,
                  name: url.lastPathComponent,
                  errorURL: url
              ),
              finalIdentity == initialIdentity,
              let finalParentIdentity = try? filesystemIdentity(
                  at: documentsDirectory, requiringDirectory: true
              ),
              finalParentIdentity == parentIdentity else {
            quarantine(url: url, sessionID: sessionID)
            return cacheEmptyStateLocked(for: sessionID)
        }
        var scanner = SessionDocumentJSONIntegrityScanner(data: data)
        guard (try? scanner.validate()) != nil,
              let decoded = try? decoder.decode(SessionDocumentSessionState.self, from: data),
              decoded.sessionID == sessionID,
              decoded.tabs.count <= Self.maxPersistedTabCount,
              Set(decoded.tabs.map(\.id)).count == decoded.tabs.count,
              Set(decoded.tabs.compactMap { tab in
                  tab.fileIdentity.map { "\($0.device):\($0.inode)" }
              }).count == decoded.tabs.compactMap(\.fileIdentity).count,
              decoded.schemaVersion >= 1,
              decoded.recoveryGeneration.map({ $0 > 0 }) ?? true,
              (decoded.recoveryGeneration == nil)
                  == (decoded.recoveryDiagnosticDigest == nil),
              decoded.recoveryDiagnosticDigest.map({ digest in
                  digest.count == 64
                      && digest.allSatisfy({ $0.isHexDigit })
                      && digest.lowercased() == digest
              }) ?? true,
              (decoded.recoveryCheckpointEpoch == nil)
                  == (decoded.recoveryCheckpointReceiptDigest == nil),
              (decoded.recoveryCheckpointEpoch == nil)
                  == (decoded.recoveryCheckpointManifestRoot == nil),
              decoded.recoveryCheckpointEpoch != nil
                  || decoded.recoveryCheckpointArtifactIDs == nil,
              decoded.recoveryCheckpointEpoch != nil
                  || decoded.recoveryCheckpointHistory == nil,
              decoded.recoveryCheckpointEpoch != nil
                  || decoded.recoveryCheckpointHistoryDigest == nil,
              decoded.recoveryCheckpointEpoch.map({ $0 > 0 }) ?? true,
              decoded.recoveryCheckpointReceiptDigest.map({ digest in
                  digest.count == 64
                      && digest.allSatisfy({ $0.isHexDigit })
                      && digest.lowercased() == digest
              }) ?? true,
              decoded.recoveryCheckpointManifestRoot.map({ digest in
                  digest.count == 64
                      && digest.allSatisfy({ $0.isHexDigit })
                      && digest.lowercased() == digest
              }) ?? true,
              decoded.recoveryCheckpointArtifactIDs.map({ ids in
                  !ids.isEmpty
                      && ids.count <= Self.maxQuarantineReceiptCount
                      && ids == ids.sorted()
                      && Set(ids).count == ids.count
                      && ids.allSatisfy({ id in
                          guard let uuid = UUID(uuidString: id) else { return false }
                          return uuid.uuidString == id
                      })
              }) ?? true,
              decoded.recoveryCheckpointHistory.map({ history in
                  !history.isEmpty
                      && history.count <= Self.maxRecoveryCheckpointHistoryCount
                      && zip(history, history.dropFirst()).allSatisfy({ current, next in
                          current.epoch < UInt64.max
                              && current.epoch < next.epoch
                              && next.epoch == current.epoch + 1
                              && next.previousReceiptDigest == current.receiptDigest
                              && next.previousManifestRoot == current.manifestRoot
                      })
                      && history.allSatisfy({ checkpoint in
                          checkpoint.epoch > 0
                              && checkpoint.receiptDigest.count == 64
                              && checkpoint.receiptDigest.allSatisfy({ $0.isHexDigit })
                              && checkpoint.receiptDigest.lowercased()
                                  == checkpoint.receiptDigest
                              && checkpoint.manifestRoot.count == 64
                              && checkpoint.manifestRoot.allSatisfy({ $0.isHexDigit })
                              && checkpoint.manifestRoot.lowercased()
                                  == checkpoint.manifestRoot
                              && checkpoint.previousReceiptDigest.count == 64
                              && checkpoint.previousReceiptDigest.allSatisfy({ $0.isHexDigit })
                              && checkpoint.previousReceiptDigest.lowercased()
                                  == checkpoint.previousReceiptDigest
                              && checkpoint.previousManifestRoot.count == 64
                              && checkpoint.previousManifestRoot.allSatisfy({ $0.isHexDigit })
                              && checkpoint.previousManifestRoot.lowercased()
                                  == checkpoint.previousManifestRoot
                              && !checkpoint.artifactIDs.isEmpty
                              && checkpoint.artifactIDs.count
                                  <= Self.maxQuarantineReceiptCount
                              && checkpoint.artifactIDs
                                  == checkpoint.artifactIDs.sorted()
                              && Set(checkpoint.artifactIDs).count
                                  == checkpoint.artifactIDs.count
                              && checkpoint.artifactIDs.allSatisfy({ id in
                                  guard let uuid = UUID(uuidString: id) else {
                                      return false
                                  }
                                  return uuid.uuidString == id
                              })
                      })
                      && history.last.map({ checkpoint in
                          decoded.recoveryCheckpointEpoch == checkpoint.epoch
                              && decoded.recoveryCheckpointReceiptDigest
                                  == checkpoint.receiptDigest
                              && decoded.recoveryCheckpointManifestRoot
                                  == checkpoint.manifestRoot
                              && decoded.recoveryCheckpointArtifactIDs
                                  == checkpoint.artifactIDs
                      }) == true
              }) ?? true,
              decoded.recoveryCheckpointHistoryDigest.map({ digest in
                  digest.count == 64
                      && digest.allSatisfy({ $0.isHexDigit })
                      && digest.lowercased() == digest
                      && decoded.recoveryCheckpointHistory.map({ history in
                          recoveryCheckpointHistoryDigest(history) == digest
                      }) == true
              }) ?? true,
              decoded.recoveryCheckpointEpoch.map({ epoch in
                  decoded.recoveryGeneration == epoch
              }) ?? true,
              decoded.tabs.allSatisfy({
                  $0.sessionID == sessionID && isValidRevision($0) && isFileFenceCurrent($0)
              }),
              decoded.selectedTabID.map({ selectedID in
                  decoded.tabs.contains(where: { $0.id == selectedID })
              }) ?? true,
              decoded.schemaVersion <= SessionDocumentSessionState.currentSchemaVersion else {
            quarantine(url: url, sessionID: sessionID)
            return cacheEmptyStateLocked(for: sessionID)
        }
        sessions[sessionID] = decoded
        if let generation = decoded.recoveryGeneration {
            recoveryGenerationFloors[sessionID] = max(
                recoveryGenerationFloors[sessionID] ?? 0, generation
            )
        }
        if let digest = decoded.recoveryDiagnosticDigest {
            recoveryDiagnosticDigestFloors[sessionID] = digest
        }
        if let epoch = decoded.recoveryCheckpointEpoch {
            recoveryCheckpointEpochFloors[sessionID] = max(
                recoveryCheckpointEpochFloors[sessionID] ?? 0, epoch
            )
        }
        if let receiptDigest = decoded.recoveryCheckpointReceiptDigest {
            recoveryCheckpointReceiptDigestFloors[sessionID] = receiptDigest
        }
        if let manifestRoot = decoded.recoveryCheckpointManifestRoot {
            recoveryCheckpointManifestRootFloors[sessionID] = manifestRoot
        }
        if let artifactIDs = decoded.recoveryCheckpointArtifactIDs {
            recoveryCheckpointArtifactIDFloors[sessionID] = Set(artifactIDs)
        }
        if let history = decoded.recoveryCheckpointHistory {
            recoveryCheckpointHistoryFloors[sessionID] = history
        }
        if let historyDigest = decoded.recoveryCheckpointHistoryDigest {
            recoveryCheckpointHistoryDigestFloors[sessionID] = historyDigest
        }
        persistedBaselines[sessionID] = PersistedStateBaseline(identity: initialIdentity)
        if !hasQuarantinedArtifactLocked(for: sessionID),
           !hasRecoveryDiagnosticArtifactLocked(for: sessionID),
           loadRecoveryDiagnosticLocked(for: sessionID)?.phase != .prepared {
            recoveryFailures.remove(sessionID)
        }
        return decoded
    }

    private func cacheEmptyStateLocked(for sessionID: UUID) -> SessionDocumentSessionState {
        let empty = SessionDocumentSessionState(sessionID: sessionID)
        sessions[sessionID] = empty
        persistedBaselines[sessionID] = PersistedStateBaseline(identity: nil)
        if hasQuarantinedArtifactLocked(for: sessionID)
                || hasRecoveryDiagnosticArtifactLocked(for: sessionID)
                || loadRecoveryDiagnosticLocked(for: sessionID)?.phase == .prepared {
            recoveryFailures.insert(sessionID)
        }
        return empty
    }

    /// Quarantine artifacts outlive a Store instance, so a restarted app must
    /// retain the recovery warning instead of presenting an empty session as
    /// if it had never contained a document.
    private func hasQuarantinedArtifactLocked(for sessionID: UUID) -> Bool {
        let parentDescriptor = open(
            documentsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else { return errno == ENOENT ? false : true }
        defer { _ = close(parentDescriptor) }
        guard let parentIdentity = try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: documentsDirectory
        ) else { return true }
        let quarantineName = quarantineDirectory.lastPathComponent
        var quarantineEntry = stat()
        guard fstatat(
            parentDescriptor, quarantineName, &quarantineEntry,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return errno == ENOENT ? false : true
        }
        guard (quarantineEntry.st_mode & S_IFMT) == S_IFDIR else { return true }
        let quarantineDescriptor = openat(
            parentDescriptor,
            quarantineName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard quarantineDescriptor >= 0 else { return true }
        defer { _ = close(quarantineDescriptor) }
        guard let quarantineIdentity = try? filesystemIdentity(
            of: quarantineDescriptor,
            requiringDirectory: true,
            errorURL: quarantineDirectory
        ), let entries = try? quarantineReceiptNames(),
        (try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: documentsDirectory
        )) == parentIdentity,
        (try? filesystemIdentity(
            of: quarantineDescriptor,
            requiringDirectory: true,
            errorURL: quarantineDirectory
        )) == quarantineIdentity,
        (try? filesystemIdentity(
            at: documentsDirectory,
            requiringDirectory: true
        )) == parentIdentity,
        (try? filesystemIdentity(
            at: quarantineDirectory,
            requiringDirectory: true
        )) == quarantineIdentity else {
            return true
        }
        return entries.contains {
            quarantineArtifactKind($0, sessionID: sessionID) != nil
        }
    }

    /// Distinguish a missing diagnostic from a present-but-corrupt one without
    /// following a replacement symlink. The latter must remain visible and
    /// block writes even when its quarantine set has already been emptied.
    private func hasRecoveryDiagnosticArtifactLocked(for sessionID: UUID) -> Bool {
        let parentDescriptor = open(
            documentsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else { return false }
        defer { _ = close(parentDescriptor) }
        var info = stat()
        guard fstatat(
            parentDescriptor,
            recoveryDiagnosticURL(for: sessionID).lastPathComponent,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return errno != ENOENT
        }
        return true
    }

    private func quarantineArtifactKind(
        _ name: String,
        sessionID: UUID
    ) -> QuarantineArtifactKind? {
        let originalPrefix = "\(sessionID.uuidString)-"
        if name.hasPrefix(originalPrefix), name.hasSuffix(".json") {
            let artifactID = String(
                name.dropFirst(originalPrefix.count).dropLast(".json".count)
            )
            if let artifactUUID = canonicalUUID(artifactID) {
                return .original(artifactUUID)
            }
        }

        // Accept the first tombstone spelling emitted before the reserved
        // namespace was introduced, but only when both UUID components are
        // structurally valid. This keeps an interrupted cleanup recoverable.
        if name.hasPrefix(originalPrefix), name.hasSuffix(".json") {
            let legacyBody = String(
                name.dropFirst(originalPrefix.count).dropLast(".json".count)
            )
            if let marker = legacyBody.range(of: "-cleanup-", options: .backwards) {
                let originalName = String(legacyBody[..<marker.lowerBound])
                let cleanupID = String(legacyBody[marker.upperBound...])
                let originalID = String(
                    originalName.dropLast(".json".count)
                )
                if originalName.hasSuffix(".json"),
                   canonicalUUID(originalID) != nil,
                   canonicalUUID(cleanupID) != nil {
                    return .unownedTombstone
                }
            }
        }

        let tombstonePrefix = Self.quarantineTombstonePrefix
        guard name.hasPrefix(tombstonePrefix), name.hasSuffix(".json") else {
            return nil
        }
        let receiptParts = String(
            name.dropFirst(tombstonePrefix.count).dropLast(".json".count)
        ).split(separator: "_", omittingEmptySubsequences: false)
        guard let ownerSessionID = receiptParts.first.flatMap({
            canonicalUUID(String($0))
        }) else {
            return nil
        }
        guard ownerSessionID == sessionID else { return nil }
        guard receiptParts.count == 6,
              let receiptSessionID = canonicalUUID(String(receiptParts[1])),
              receiptSessionID == sessionID,
              let device = canonicalUInt64(String(receiptParts[2])),
              let inode = canonicalUInt64(String(receiptParts[3])),
              receiptParts[4].count == 64,
              receiptParts[4].allSatisfy({ $0.isHexDigit }),
              String(receiptParts[4]) == String(receiptParts[4]).lowercased(),
              let artifactID = canonicalUUID(String(receiptParts[5])) else {
            return .unownedTombstone
        }
        return .tombstone(
            QuarantineCleanupReceipt(
                sessionID: sessionID,
                identity: SessionDocumentFileIdentity(device: device, inode: inode),
                contentHash: String(receiptParts[4]).lowercased(),
                artifactID: artifactID
            )
        )
    }

    private func canonicalUUID(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value), uuid.uuidString == value else {
            return nil
        }
        return uuid
    }

    private func canonicalUInt64(_ value: String) -> UInt64? {
        guard let number = UInt64(value), String(number) == value else {
            return nil
        }
        return number
    }

    private func hasUniqueOwnedReceiptIDs(
        in names: [String],
        sessionID: UUID
    ) -> Bool {
        var artifactIDs = Set<UUID>()
        for name in names {
            switch quarantineArtifactKind(name, sessionID: sessionID) {
            case .original(let artifactID):
                guard artifactIDs.insert(artifactID).inserted else {
                    return false
                }
            case .tombstone(let receipt):
                guard artifactIDs.insert(receipt.artifactID).inserted else {
                    return false
                }
            case .unownedTombstone, nil:
                continue
            }
        }
        return true
    }

    private func ownedArtifactIDs(
        in names: [String], sessionID: UUID
    ) -> Set<String> {
        Set(names.compactMap { name in
            switch quarantineArtifactKind(name, sessionID: sessionID) {
            case .original(let artifactID):
                return artifactID.uuidString
            case .tombstone(let receipt):
                return receipt.artifactID.uuidString
            case .unownedTombstone, nil:
                return nil
            }
        })
    }

    private func quarantineDirectoryRevision(
        of descriptor: Int32,
        errorURL: URL
    ) throws -> QuarantineDirectoryRevision {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        return QuarantineDirectoryRevision(
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private func quarantineReceiptNames() throws -> [String] {
        let parentDescriptor = open(
            documentsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else {
            throw SessionDocumentStoreError.cannotRead(documentsDirectory)
        }
        defer { _ = close(parentDescriptor) }
        guard let parentIdentity = try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: documentsDirectory
        ) else {
            throw SessionDocumentStoreError.cannotRead(documentsDirectory)
        }
        let quarantineDescriptor = openat(
            parentDescriptor,
            quarantineDirectory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard quarantineDescriptor >= 0 else {
            throw SessionDocumentStoreError.cannotRead(quarantineDirectory)
        }
        defer { _ = close(quarantineDescriptor) }
        guard let quarantineIdentity = try? filesystemIdentity(
            of: quarantineDescriptor,
            requiringDirectory: true,
            errorURL: quarantineDirectory
        ) else {
            throw SessionDocumentStoreError.cannotRead(quarantineDirectory)
        }
        let names = try quarantineReceiptNames(in: quarantineDescriptor)
        guard (try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: documentsDirectory
        )) == parentIdentity,
        (try? filesystemIdentity(
            of: quarantineDescriptor,
            requiringDirectory: true,
            errorURL: quarantineDirectory
        )) == quarantineIdentity,
        (try? filesystemIdentity(
            at: documentsDirectory,
            requiringDirectory: true
        )) == parentIdentity,
        (try? filesystemIdentity(
            at: quarantineDirectory,
            requiringDirectory: true
        )) == quarantineIdentity else {
            throw SessionDocumentStoreError.cannotWrite(quarantineDirectory)
        }
        return names
    }

    private func quarantineReceiptNames(in directoryDescriptor: Int32) throws -> [String] {
        // dup shares the pinned descriptor's directory offset. Each snapshot
        // needs its own cursor while staying anchored to the same directory.
        let cursor = openat(
            directoryDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard cursor >= 0, let stream = fdopendir(cursor) else {
            if cursor >= 0 { _ = Darwin.close(cursor) }
            throw SessionDocumentStoreError.cannotRead(quarantineDirectory)
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", !name.hasPrefix(".") else {
                continue
            }
            guard names.count < Self.maxQuarantineReceiptCount else {
                throw SessionDocumentStoreError.cannotRead(quarantineDirectory)
            }
            names.append(name)
        }
        guard errno == 0 else {
            throw SessionDocumentStoreError.cannotRead(quarantineDirectory)
        }
        return names.sorted()
    }

    private func quarantineReceiptSize(
        in directoryDescriptor: Int32,
        name: String,
        errorURL: URL
    ) throws -> UInt64 {
        var info = stat()
        guard fstatat(
            directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW
        ) == 0,
        (info.st_mode & S_IFMT) == S_IFREG,
        info.st_size >= 0,
        info.st_nlink == 1,
        UInt32(info.st_uid) == UInt32(getuid()) else {
            throw SessionDocumentStoreError.cannotRead(errorURL)
        }
        return UInt64(info.st_size)
    }

    private func quarantineCleanupSnapshot(
        parentDescriptor: Int32,
        parentIdentity: FilesystemIdentity,
        quarantineDescriptor: Int32,
        quarantineIdentity: FilesystemIdentity
    ) throws -> QuarantineCleanupSnapshot {
        guard (try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: documentsDirectory
        )) == parentIdentity,
        Self.isSameDirectoryObject(
            try? filesystemIdentity(
                of: quarantineDescriptor,
                requiringDirectory: true,
                errorURL: quarantineDirectory
            ),
            as: quarantineIdentity
        ) else {
            throw SessionDocumentStoreError.cannotWrite(quarantineDirectory)
        }
        let before = try quarantineDirectoryRevision(
            of: quarantineDescriptor, errorURL: quarantineDirectory
        )
        let names = try quarantineReceiptNames(in: quarantineDescriptor)
        guard Self.isSameDirectoryObject(
            try? filesystemIdentity(
                of: quarantineDescriptor,
                requiringDirectory: true,
                errorURL: quarantineDirectory
            ),
            as: quarantineIdentity
        ),
        (try? quarantineDirectoryRevision(
            of: quarantineDescriptor, errorURL: quarantineDirectory
        )) == before else {
            throw SessionDocumentStoreError.cannotWrite(quarantineDirectory)
        }
        guard names.count <= Self.maxQuarantineReceiptCount else {
            throw SessionDocumentStoreError.cannotRead(quarantineDirectory)
        }
        var totalBytes: UInt64 = 0
        var receiptSizes: [String: UInt64] = [:]
        receiptSizes.reserveCapacity(names.count)
        for name in names {
            let errorURL = quarantineDirectory.appendingPathComponent(name)
            let size = try quarantineReceiptSize(
                in: quarantineDescriptor, name: name, errorURL: errorURL
            )
            guard size <= UInt64(Self.maxQuarantineReceiptBytes),
                  size <= UInt64(Self.maxQuarantineReceiptSetBytes),
                  totalBytes <= UInt64(Self.maxQuarantineReceiptSetBytes) - size else {
                throw SessionDocumentStoreError.cannotRead(errorURL)
            }
            totalBytes += size
            receiptSizes[name] = size
        }
        guard Self.isSameDirectoryObject(
            try? filesystemIdentity(
                of: quarantineDescriptor,
                requiringDirectory: true,
                errorURL: quarantineDirectory
            ),
            as: quarantineIdentity
        ),
        (try? quarantineDirectoryRevision(
            of: quarantineDescriptor, errorURL: quarantineDirectory
        )) == before else {
            throw SessionDocumentStoreError.cannotWrite(quarantineDirectory)
        }
        var fingerprints: [String: QuarantineReceiptFingerprint] = [:]
        fingerprints.reserveCapacity(names.count)
        for name in names {
            let errorURL = quarantineDirectory.appendingPathComponent(name)
            guard let identity = try existingFilesystemIdentity(
                in: quarantineDescriptor,
                name: name,
                requiringDirectory: false,
                errorURL: errorURL
            ) else {
                throw SessionDocumentStoreError.cannotRead(errorURL)
            }
            let contentHash = try quarantineContentHash(
                in: quarantineDescriptor,
                name: name,
                errorURL: errorURL
            ).lowercased()
            guard let finalIdentity = try existingFilesystemIdentity(
                in: quarantineDescriptor,
                name: name,
                requiringDirectory: false,
                errorURL: errorURL
            ), SessionDocumentFileIdentity(
                device: finalIdentity.device, inode: finalIdentity.inode
            ) == SessionDocumentFileIdentity(
                device: identity.device, inode: identity.inode
            ) else {
                throw SessionDocumentStoreError.cannotRead(errorURL)
            }
            guard let byteCount = receiptSizes[name] else {
                throw SessionDocumentStoreError.cannotRead(errorURL)
            }
            fingerprints[name] = QuarantineReceiptFingerprint(
                identity: SessionDocumentFileIdentity(
                    device: identity.device, inode: identity.inode
                ),
                byteCount: byteCount,
                contentHash: contentHash
            )
        }
        guard Self.isSameDirectoryObject(
            try? filesystemIdentity(
                at: quarantineDirectory, requiringDirectory: true
            ),
            as: quarantineIdentity
        ), Self.isSameDirectoryObject(
            try? filesystemIdentity(
                of: quarantineDescriptor,
                requiringDirectory: true,
                errorURL: quarantineDirectory
            ),
            as: quarantineIdentity
        ) else {
            throw SessionDocumentStoreError.cannotWrite(quarantineDirectory)
        }
        let after = try quarantineDirectoryRevision(
            of: quarantineDescriptor, errorURL: quarantineDirectory
        )
        guard before == after,
              (try? filesystemIdentity(
                  of: parentDescriptor,
                  requiringDirectory: true,
                  errorURL: documentsDirectory
        )) == parentIdentity else {
            throw SessionDocumentStoreError.cannotWrite(quarantineDirectory)
        }
        let setMaterial = names.map { name in
            let fingerprint = fingerprints[name]!
            return [
                name,
                String(fingerprint.identity.device),
                String(fingerprint.identity.inode),
                String(fingerprint.byteCount),
                fingerprint.contentHash,
            ].joined(separator: "|")
        }.joined(separator: "\n")
        return QuarantineCleanupSnapshot(
            directoryRevision: after,
            receiptNames: names,
            receiptFingerprints: fingerprints,
            capacity: QuarantineCapacitySnapshot(
                count: names.count,
                totalBytes: totalBytes,
                setDigest: Self.sha256Hex(Data(setMaterial.utf8))
            )
        )
    }

    /// Remove only the quarantine artifacts belonging to this session after
    /// its replacement state has been durably written. Returning false keeps
    /// the warning sticky when cleanup is tampered with or interrupted.
    private func cleanupQuarantineLocked(for sessionID: UUID) -> Bool {
        let parentDescriptor = open(
            documentsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else { return errno == ENOENT }
        defer { _ = close(parentDescriptor) }
        guard let parentIdentity = try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: documentsDirectory
        ) else { return false }
        let quarantineDescriptor = openat(
            parentDescriptor,
            quarantineDirectory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard quarantineDescriptor >= 0 else { return errno == ENOENT }
        defer { _ = close(quarantineDescriptor) }
        guard let quarantineIdentity = try? filesystemIdentity(
            of: quarantineDescriptor,
            requiringDirectory: true,
            errorURL: quarantineDirectory
        ) else { return false }
        // Names are enumerated through the path, but the descriptor identity,
        // directory revision, and complete receipt-name set form a fence. A
        // concurrent writer that changes any of these after enumeration makes
        // this cleanup stale and therefore unable to delete anything.
        guard let initialSnapshot = try? quarantineCleanupSnapshot(
            parentDescriptor: parentDescriptor,
            parentIdentity: parentIdentity,
            quarantineDescriptor: quarantineDescriptor,
            quarantineIdentity: quarantineIdentity
        ), hasUniqueOwnedReceiptIDs(
            in: initialSnapshot.receiptNames, sessionID: sessionID
        ) else { return false }
        let entries = initialSnapshot.receiptNames.map {
            quarantineDirectory.appendingPathComponent($0)
        }
        var expectedSnapshot = initialSnapshot
        var succeeded = true
        for entry in entries {
            let name = entry.lastPathComponent
            guard let kind = quarantineArtifactKind(name, sessionID: sessionID) else { continue }
            guard let currentSnapshot = try? quarantineCleanupSnapshot(
                parentDescriptor: parentDescriptor,
                parentIdentity: parentIdentity,
                quarantineDescriptor: quarantineDescriptor,
                quarantineIdentity: quarantineIdentity
            ), currentSnapshot == expectedSnapshot else {
                return false
            }
            let receipt: QuarantineCleanupReceipt?
            let artifactID: UUID
            switch kind {
            case .original(let originalID):
                receipt = nil
                artifactID = originalID
            case .tombstone(let ownedReceipt):
                receipt = ownedReceipt
                artifactID = ownedReceipt.artifactID
            case .unownedTombstone:
                // A crash may have committed the rename before its receipt.
                // Without the bound identity and digest, never guess or
                // restore over a path that could now belong to the user.
                succeeded = false
                continue
            }
            do {
                guard let identity = try existingFilesystemIdentity(
                    in: quarantineDescriptor,
                    name: name,
                    requiringDirectory: false,
                    errorURL: entry
                ), identity.hardLinkCount == 1 else {
                    succeeded = false
                    continue
                }
                let contentHash = try quarantineContentHash(
                    in: quarantineDescriptor,
                    name: name,
                    errorURL: entry
                )
                if let receipt,
                   receipt.sessionID != sessionID
                        || receipt.identity != SessionDocumentFileIdentity(
                            device: identity.device, inode: identity.inode
                        )
                        || receipt.contentHash != contentHash.lowercased() {
                    succeeded = false
                    continue
                }
                guard (try? filesystemIdentity(
                    of: parentDescriptor,
                    requiringDirectory: true,
                    errorURL: documentsDirectory
                )) == parentIdentity,
                Self.isSameDirectoryObject(
                    try? filesystemIdentity(
                        of: quarantineDescriptor,
                        requiringDirectory: true,
                        errorURL: quarantineDirectory
                    ),
                    as: quarantineIdentity
                ) else {
                    return false
                }
                let tombstoneName = "\(Self.quarantineTombstonePrefix)\(sessionID.uuidString)_\(sessionID.uuidString)_\(identity.device)_\(identity.inode)_\(contentHash.lowercased())_\(artifactID.uuidString).json"
                if tombstoneName != name {
                    do {
                        guard try existingFilesystemIdentity(
                            in: quarantineDescriptor,
                            name: tombstoneName,
                            requiringDirectory: false,
                            errorURL: entry
                        ) == nil else {
                            succeeded = false
                            continue
                        }
                    } catch {
                        // A destination symlink, directory, or foreign owner
                        // is a collision, never an overwrite opportunity.
                        succeeded = false
                        continue
                    }
                }
                var expectedAfterRenameNames = expectedSnapshot.receiptNames
                guard let nameIndex = expectedAfterRenameNames.firstIndex(of: name) else {
                    return false
                }
                if tombstoneName != name {
                    guard !expectedAfterRenameNames.contains(tombstoneName) else {
                        return false
                    }
                    expectedAfterRenameNames[nameIndex] = tombstoneName
                    expectedAfterRenameNames.sort()
                }
                guard let currentSnapshot = try? quarantineCleanupSnapshot(
                    parentDescriptor: parentDescriptor,
                    parentIdentity: parentIdentity,
                    quarantineDescriptor: quarantineDescriptor,
                    quarantineIdentity: quarantineIdentity
                ), currentSnapshot == expectedSnapshot else {
                    return false
                }
                if tombstoneName != name {
                    guard renameat(
                        quarantineDescriptor,
                        name,
                        quarantineDescriptor,
                        tombstoneName
                    ) == 0 else {
                        succeeded = false
                        continue
                    }
                    guard let postRenameSnapshot = try? quarantineCleanupSnapshot(
                        parentDescriptor: parentDescriptor,
                        parentIdentity: parentIdentity,
                        quarantineDescriptor: quarantineDescriptor,
                        quarantineIdentity: quarantineIdentity
                    ), postRenameSnapshot.receiptNames == expectedAfterRenameNames else {
                        return false
                    }
                    expectedSnapshot = postRenameSnapshot
                }
                guard let tombstoneIdentity = try existingFilesystemIdentity(
                    in: quarantineDescriptor,
                    name: tombstoneName,
                    requiringDirectory: false,
                    errorURL: entry
                ), tombstoneIdentity == identity,
                try quarantineContentHash(
                    in: quarantineDescriptor,
                    name: tombstoneName,
                    errorURL: entry
                ).lowercased() == contentHash.lowercased() else {
                    succeeded = false
                    continue
                }
                guard let currentSnapshot = try? quarantineCleanupSnapshot(
                    parentDescriptor: parentDescriptor,
                    parentIdentity: parentIdentity,
                    quarantineDescriptor: quarantineDescriptor,
                    quarantineIdentity: quarantineIdentity
                ), currentSnapshot == expectedSnapshot else {
                    return false
                }
                guard unlinkat(quarantineDescriptor, tombstoneName, 0) == 0 else {
                    succeeded = false
                    continue
                }
                if try existingFilesystemIdentity(
                    in: quarantineDescriptor,
                    name: tombstoneName,
                    requiringDirectory: false,
                    errorURL: entry
                ) != nil {
                    succeeded = false
                    continue
                }
                let expectedAfterUnlinkNames = expectedSnapshot.receiptNames.filter {
                    $0 != tombstoneName
                }
                guard let postUnlinkSnapshot = try? quarantineCleanupSnapshot(
                    parentDescriptor: parentDescriptor,
                    parentIdentity: parentIdentity,
                    quarantineDescriptor: quarantineDescriptor,
                    quarantineIdentity: quarantineIdentity
                ), postUnlinkSnapshot.receiptNames == expectedAfterUnlinkNames else {
                    return false
                }
                expectedSnapshot = postUnlinkSnapshot
            } catch {
                succeeded = false
                continue
            }
        }
        guard let finalSnapshot = try? quarantineCleanupSnapshot(
            parentDescriptor: parentDescriptor,
            parentIdentity: parentIdentity,
            quarantineDescriptor: quarantineDescriptor,
            quarantineIdentity: quarantineIdentity
        ), finalSnapshot == expectedSnapshot else {
            return false
        }
        return succeeded
    }

    private func quarantineContentHash(
        in directoryDescriptor: Int32,
        name: String,
        errorURL: URL
    ) throws -> String {
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SessionDocumentStoreError.cannotRead(errorURL)
        }
        defer { _ = close(descriptor) }
        return Self.sha256Hex(try readPersistedState(
            from: descriptor,
            errorURL: errorURL,
            maxBytes: Self.maxQuarantineReceiptBytes
        ))
    }

    private func isFileFenceCurrent(_ tab: SessionDocumentTab) -> Bool {
        guard let fileURL = tab.fileURL else {
            return tab.fileIdentity == nil && tab.fileContentHash == nil
        }
        guard let expectedIdentity = tab.fileIdentity,
              let expectedHash = tab.fileContentHash,
              let current = try? fileFence(for: fileURL) else {
            return false
        }
        return current.identity == expectedIdentity && current.contentHash == expectedHash
    }

    private func isValidRevision(_ tab: SessionDocumentTab) -> Bool {
        let created = tab.createdAt.timeIntervalSinceReferenceDate
        let updated = tab.updatedAt.timeIntervalSinceReferenceDate
        return created.isFinite && updated.isFinite && updated >= created
    }

    @discardableResult
    private func writeStateAtomically(
        _ data: Data,
        fileName: String,
        in directoryDescriptor: Int32,
        errorURL: URL,
        expectedDestinationIdentity: FilesystemIdentity? = nil,
        requireDestinationMissing: Bool = false
    ) throws -> FilesystemIdentity {
        guard data.count <= Self.maxPersistedStateBytes else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        var temporaryName: String?
        var temporaryDescriptor: Int32 = -1
        for _ in 0..<16 {
            let candidate = ".\(fileName).tmp-\(UUID().uuidString)"
            let opened = openat(
                directoryDescriptor,
                candidate,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            if opened >= 0 {
                temporaryName = candidate
                temporaryDescriptor = opened
                break
            }
            if errno != EEXIST {
                throw SessionDocumentStoreError.cannotWrite(errorURL)
            }
        }
        guard let temporaryName else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        var renamed = false
        defer {
            if temporaryDescriptor >= 0 { _ = close(temporaryDescriptor) }
            if !renamed {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        let temporaryIdentity = try filesystemIdentity(
            of: temporaryDescriptor,
            requiringDirectory: false,
            errorURL: errorURL
        )
        guard temporaryIdentity.mode == 0o600,
              temporaryIdentity.hardLinkCount == 1 else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(
                    temporaryDescriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard written > 0 else {
                    throw SessionDocumentStoreError.cannotWrite(errorURL)
                }
                offset += written
            }
        }
        guard try filesystemIdentity(
            of: temporaryDescriptor,
            requiringDirectory: false,
            errorURL: errorURL
        ) == temporaryIdentity else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        guard fsync(temporaryDescriptor) == 0 else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        guard close(temporaryDescriptor) == 0 else {
            temporaryDescriptor = -1
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        temporaryDescriptor = -1
        let destinationIdentity = try existingFilesystemIdentity(
            in: directoryDescriptor,
            name: fileName,
            requiringDirectory: false,
            errorURL: errorURL
        )
        if requireDestinationMissing {
            guard destinationIdentity == nil else {
                throw SessionDocumentStoreError.cannotWrite(errorURL)
            }
        } else if let expectedDestinationIdentity {
            guard destinationIdentity == expectedDestinationIdentity else {
                throw SessionDocumentStoreError.cannotWrite(errorURL)
            }
        }
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, fileName) == 0 else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        renamed = true
        guard try existingFilesystemIdentity(
            in: directoryDescriptor,
            name: fileName,
            requiringDirectory: false,
            errorURL: errorURL
        ) == temporaryIdentity else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw SessionDocumentStoreError.cannotWrite(errorURL)
        }
        return temporaryIdentity
    }

    private func isRecoveryDiagnosticSuccessor(
        _ candidate: RecoveryDiagnostic,
        after previous: RecoveryDiagnostic
    ) -> Bool {
        guard candidate.phase == .prepared,
              previous.phase == .committed,
              let previousGeneration = UInt64(previous.generation),
              previousGeneration < UInt64.max,
              candidate.generation == String(previousGeneration + 1),
              candidate.checkpointEpoch == candidate.generation,
              previous.checkpointEpoch == previous.generation,
              candidate.receiptDigest == candidate.canonicalPayload,
              previous.receiptDigest == previous.canonicalPayload else {
            return false
        }
        return candidate.previousDigest == recoveryDiagnosticDigest(previous)
    }

    private func verifyRecoveryDiagnosticReadback(
        _ diagnostic: RecoveryDiagnostic,
        expectedData: Data,
        in directoryDescriptor: Int32,
        identity: FilesystemIdentity,
        url: URL
    ) throws {
        guard expectedData.count <= Self.maxRecoveryDiagnosticBytes,
              identity.mode == 0o600,
              identity.hardLinkCount == 1,
              let readback = try? readPersistedState(
                  in: directoryDescriptor,
                  name: url.lastPathComponent,
                  errorURL: url,
                  maxBytes: Self.maxRecoveryDiagnosticBytes
              ),
              readback == expectedData,
              decodeRecoveryDiagnostic(readback) == diagnostic,
              try existingFilesystemIdentity(
                  in: directoryDescriptor,
                  name: url.lastPathComponent,
                  requiringDirectory: false,
                  errorURL: url
              ) == identity else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
    }

    private func writeRecoveryDiagnosticAtomically(
        _ diagnostic: RecoveryDiagnostic,
        in directoryDescriptor: Int32,
        previous: RecoveryDiagnostic? = nil
    ) throws {
        let url = recoveryDiagnosticURL(for: diagnostic.sessionID)
        let name = url.lastPathComponent
        if let identity = try existingFilesystemIdentity(
            in: directoryDescriptor,
            name: name,
            requiringDirectory: false,
            errorURL: url
        ) {
            guard identity.mode == 0o600, identity.hardLinkCount == 1,
                  let existingData = try? readPersistedState(
                      in: directoryDescriptor,
                      name: name,
                      errorURL: url,
                      maxBytes: Self.maxRecoveryDiagnosticBytes
                  ),
                  let existing = decodeRecoveryDiagnostic(existingData),
                  (existing == diagnostic
                      || (previous.map {
                          existing == $0
                              && isRecoveryDiagnosticSuccessor(
                                  diagnostic, after: $0
                              )
                      } ?? false)),
                  try existingFilesystemIdentity(
                      in: directoryDescriptor,
                      name: name,
                      requiringDirectory: false,
                      errorURL: url
            ) == identity else {
                throw SessionDocumentStoreError.cannotWrite(url)
            }
            if existing == diagnostic {
                return
            }
            let data = try recoveryDiagnosticEncoder.encode(diagnostic)
            guard data.count <= Self.maxRecoveryDiagnosticBytes else {
                throw SessionDocumentStoreError.cannotWrite(url)
            }
            let readbackIdentity = try writeStateAtomically(
                data,
                fileName: name,
                in: directoryDescriptor,
                errorURL: url,
                expectedDestinationIdentity: identity
            )
            try verifyRecoveryDiagnosticReadback(
                diagnostic,
                expectedData: data,
                in: directoryDescriptor,
                identity: readbackIdentity,
                url: url
            )
            return
        }
        let data = try recoveryDiagnosticEncoder.encode(diagnostic)
        guard previous == nil,
              data.count <= Self.maxRecoveryDiagnosticBytes else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
        let readbackIdentity = try writeStateAtomically(
            data,
            fileName: name,
            in: directoryDescriptor,
            errorURL: url,
            requireDestinationMissing: true
        )
        try verifyRecoveryDiagnosticReadback(
            diagnostic,
            expectedData: data,
            in: directoryDescriptor,
            identity: readbackIdentity,
            url: url
        )
    }

    private func commitRecoveryDiagnosticAtomically(
        _ diagnostic: RecoveryDiagnostic,
        replacing prepared: RecoveryDiagnostic,
        in directoryDescriptor: Int32
    ) throws {
        let url = recoveryDiagnosticURL(for: diagnostic.sessionID)
        let name = url.lastPathComponent
        guard let identity = try existingFilesystemIdentity(
            in: directoryDescriptor,
            name: name,
            requiringDirectory: false,
            errorURL: url
        ), identity.mode == 0o600, identity.hardLinkCount == 1,
        let data = try? readPersistedState(
            in: directoryDescriptor,
            name: name,
            errorURL: url,
            maxBytes: Self.maxRecoveryDiagnosticBytes
        ), let existing = decodeRecoveryDiagnostic(data), existing == prepared,
        try existingFilesystemIdentity(
            in: directoryDescriptor,
            name: name,
            requiringDirectory: false,
            errorURL: url
        ) == identity,
        diagnostic.phase == .committed else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
        let committedData = try recoveryDiagnosticEncoder.encode(diagnostic)
        guard committedData.count <= Self.maxRecoveryDiagnosticBytes else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
        let readbackIdentity = try writeStateAtomically(
            committedData,
            fileName: name,
            in: directoryDescriptor,
            errorURL: url,
            expectedDestinationIdentity: identity
        )
        try verifyRecoveryDiagnosticReadback(
            diagnostic,
            expectedData: committedData,
            in: directoryDescriptor,
            identity: readbackIdentity,
            url: url
        )
    }

    private func clearRecoveryDiagnostic(
        for sessionID: UUID,
        in directoryDescriptor: Int32
    ) throws {
        let url = recoveryDiagnosticURL(for: sessionID)
        let name = url.lastPathComponent
        guard let identity = try existingFilesystemIdentity(
            in: directoryDescriptor,
            name: name,
            requiringDirectory: false,
            errorURL: url
        ) else { return }
        guard identity.mode == 0o600, identity.hardLinkCount == 1,
              let data = try? readPersistedState(
                  in: directoryDescriptor,
                  name: name,
                  errorURL: url,
                  maxBytes: Self.maxRecoveryDiagnosticBytes
              ),
              let diagnostic = decodeRecoveryDiagnostic(data),
              diagnostic.sessionID == sessionID,
              diagnostic.message == Self.recoveryDiagnosticMessage,
              try existingFilesystemIdentity(
                  in: directoryDescriptor,
                  name: name,
                  requiringDirectory: false,
                  errorURL: url
              ) == identity else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
        guard unlinkat(directoryDescriptor, name, 0) == 0,
              fsync(directoryDescriptor) == 0 else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
    }

    private struct DocumentSessionLock {
        let descriptor: Int32
        let identity: FilesystemIdentity
        let url: URL
    }

    /// The same session.json.lock used by ordinary document writes. Stage
    /// load/compare/write holds this lease for the whole transaction as well.
    private func acquireDocumentSessionLock(_ sessionID: UUID) throws -> DocumentSessionLock {
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        let fileURL = sessionFileURL(for: sessionID)
        let parentIdentity = try filesystemIdentity(at: documentsDirectory, requiringDirectory: true)
        let directoryDescriptor = open(documentsDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw SessionDocumentStoreError.cannotWrite(documentsDirectory) }
        defer { _ = close(directoryDescriptor) }
        guard try filesystemIdentity(of: directoryDescriptor, requiringDirectory: true,
            errorURL: documentsDirectory) == parentIdentity else { throw SessionDocumentStoreError.cannotWrite(documentsDirectory) }
        let lockURL = fileURL.appendingPathExtension("lock")
        try validateCanonicalPath(lockURL)
        let lockName = lockURL.lastPathComponent
        if let existingLockIdentity = try existingFilesystemIdentity(
            in: directoryDescriptor,
            name: lockName,
            requiringDirectory: false,
            errorURL: lockURL
        ) {
            guard existingLockIdentity.mode == 0o600,
                  existingLockIdentity.hardLinkCount == 1 else {
                throw SessionDocumentStoreError.cannotWrite(lockURL)
            }
        }
        let descriptor = openat(
            directoryDescriptor,
            lockName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SessionDocumentStoreError.cannotWrite(lockURL)
        }
        var handedOff = false
        defer {
            if !handedOff { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
        }
        let lockIdentity = try filesystemIdentity(
            of: descriptor, requiringDirectory: false, errorURL: lockURL
        )
        guard lockIdentity.mode == 0o600,
              lockIdentity.hardLinkCount == 1 else {
            throw SessionDocumentStoreError.cannotWrite(lockURL)
        }
        var descriptorIdentity = stat()
        guard fstat(descriptor, &descriptorIdentity) == 0,
              FilesystemIdentity(
                  device: UInt64(descriptorIdentity.st_dev),
                  inode: UInt64(descriptorIdentity.st_ino),
                  owner: UInt32(descriptorIdentity.st_uid),
                  mode: UInt32(descriptorIdentity.st_mode & 0o777),
                  hardLinkCount: UInt64(descriptorIdentity.st_nlink)
              ) == lockIdentity else {
            throw SessionDocumentStoreError.cannotWrite(lockURL)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SessionDocumentStoreError.cannotWrite(lockURL)
        }
        guard try filesystemIdentity(
            of: descriptor, requiringDirectory: false, errorURL: lockURL
        )
                == lockIdentity else {
            throw SessionDocumentStoreError.cannotWrite(lockURL)
        }
        handedOff = true
        return DocumentSessionLock(descriptor: descriptor, identity: lockIdentity, url: lockURL)
    }

    private func releaseDocumentSessionLock(_ handle: DocumentSessionLock) {
        _ = flock(handle.descriptor, LOCK_UN)
        _ = close(handle.descriptor)
    }

    private func persistLocked(_ state: SessionDocumentSessionState, sessionLock: DocumentSessionLock? = nil) throws {
        let fm = FileManager.default
        let fileURL = sessionFileURL(for: state.sessionID)
        do {
            try fm.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
            let parentIdentity = try filesystemIdentity(
                at: documentsDirectory, requiringDirectory: true
            )
            let directoryDescriptor = open(
                documentsDirectory.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard directoryDescriptor >= 0 else {
                throw SessionDocumentStoreError.cannotWrite(documentsDirectory)
            }
            defer { _ = close(directoryDescriptor) }
            guard try filesystemIdentity(
                of: directoryDescriptor,
                requiringDirectory: true,
                errorURL: documentsDirectory
            ) == parentIdentity else {
                throw SessionDocumentStoreError.cannotWrite(documentsDirectory)
            }
            guard let baseline = persistedBaselines[state.sessionID] else {
                throw SessionDocumentStoreError.cannotWrite(fileURL)
            }

            let handle: DocumentSessionLock
            let ownsHandle: Bool
            if let sessionLock { handle = sessionLock; ownsHandle = false }
            else { handle = try acquireDocumentSessionLock(state.sessionID); ownsHandle = true }
            defer { if ownsHandle { releaseDocumentSessionLock(handle) } }
            let descriptor = handle.descriptor
            let lockURL = handle.url
            let lockIdentity = handle.identity

            guard Self.isSameDirectoryObject(
                try filesystemIdentity(
                    of: directoryDescriptor,
                    requiringDirectory: true,
                    errorURL: documentsDirectory
                ),
                as: parentIdentity
            ) else {
                throw SessionDocumentStoreError.cannotWrite(documentsDirectory)
            }

            guard try persistedStateIdentity(
                in: directoryDescriptor,
                name: fileURL.lastPathComponent,
                errorURL: fileURL
            ) == baseline.identity else {
                throw SessionDocumentStoreError.cannotWrite(fileURL)
            }
            var stateToPersist = state
            if let floor = recoveryGenerationFloors[state.sessionID],
               stateToPersist.recoveryGeneration.map({ $0 < floor }) ?? true {
                stateToPersist.recoveryGeneration = floor
            }
            if let digest = recoveryDiagnosticDigestFloors[state.sessionID],
               stateToPersist.recoveryDiagnosticDigest != digest {
                stateToPersist.recoveryDiagnosticDigest = digest
            }
            if let epoch = recoveryCheckpointEpochFloors[state.sessionID],
               stateToPersist.recoveryCheckpointEpoch.map({ $0 < epoch }) ?? true {
                stateToPersist.recoveryCheckpointEpoch = epoch
            }
            if let receiptDigest = recoveryCheckpointReceiptDigestFloors[state.sessionID],
               stateToPersist.recoveryCheckpointReceiptDigest != receiptDigest {
                stateToPersist.recoveryCheckpointReceiptDigest = receiptDigest
            }
            if let manifestRoot = recoveryCheckpointManifestRootFloors[state.sessionID],
               stateToPersist.recoveryCheckpointManifestRoot != manifestRoot {
                stateToPersist.recoveryCheckpointManifestRoot = manifestRoot
            }
            if let artifactIDs = recoveryCheckpointArtifactIDFloors[state.sessionID] {
                let sortedArtifactIDs = artifactIDs.sorted()
                if stateToPersist.recoveryCheckpointArtifactIDs != sortedArtifactIDs {
                    stateToPersist.recoveryCheckpointArtifactIDs = sortedArtifactIDs
                }
            }
            if let history = recoveryCheckpointHistoryFloors[state.sessionID],
               stateToPersist.recoveryCheckpointHistory != history {
                stateToPersist.recoveryCheckpointHistory = history
            }
            if let historyDigest = recoveryCheckpointHistoryDigestFloors[state.sessionID],
               stateToPersist.recoveryCheckpointHistoryDigest != historyDigest {
                stateToPersist.recoveryCheckpointHistoryDigest = historyDigest
            } else if let history = stateToPersist.recoveryCheckpointHistory,
                      stateToPersist.recoveryCheckpointHistoryDigest == nil {
                stateToPersist.recoveryCheckpointHistoryDigest =
                    recoveryCheckpointHistoryDigest(history)
            }
            // Validate the replay ledger before writing the caller's new
            // state. A same-generation fork, stale candidate, or cross-
            // document receipt must leave the stable document bytes exactly
            // as they were when recovery was rejected.
            let hasQuarantineEvidence = hasQuarantinedArtifactLocked(
                for: state.sessionID
            )
            if hasQuarantineEvidence {
                guard let receiptNames = try? quarantineReceiptNames(),
                      hasUniqueOwnedReceiptIDs(
                          in: receiptNames, sessionID: state.sessionID
                      ) else {
                    throw SessionDocumentStoreError.cannotWrite(quarantineDirectory)
                }
            }
            let pendingDiagnostic = loadRecoveryDiagnosticLocked(
                for: state.sessionID
            )
            let diagnosticURL = recoveryDiagnosticURL(for: state.sessionID)
            let diagnosticIdentity = try existingFilesystemIdentity(
                in: directoryDescriptor,
                name: diagnosticURL.lastPathComponent,
                requiringDirectory: false,
                errorURL: diagnosticURL
            )
            guard (diagnosticIdentity != nil) == (pendingDiagnostic != nil) else {
                throw SessionDocumentStoreError.cannotWrite(diagnosticURL)
            }
            if let pendingDiagnostic {
                let floor = stateToPersist.recoveryGeneration
                let floorDigest = stateToPersist.recoveryDiagnosticDigest
                let pendingGeneration = UInt64(pendingDiagnostic.generation)
                let checkpointFloor = stateToPersist.recoveryCheckpointEpoch ?? floor
                let checkpointReceiptDigest =
                    stateToPersist.recoveryCheckpointReceiptDigest
                let checkpointManifestRoot =
                    stateToPersist.recoveryCheckpointManifestRoot
                let pendingPayloadIsBound =
                    pendingDiagnostic.checkpointEpoch == pendingDiagnostic.generation
                        && pendingDiagnostic.receiptDigest
                            == pendingDiagnostic.canonicalPayload
                        && !pendingDiagnostic.segmentManifestRoot.isEmpty
                let chainIsValid: Bool
                if let floor, let pendingGeneration, let checkpointFloor {
                    if pendingDiagnostic.phase == .committed {
                        chainIsValid = pendingPayloadIsBound
                            && checkpointFloor == floor
                            && ((pendingGeneration == floor
                                && (checkpointReceiptDigest == nil
                                    || checkpointReceiptDigest
                                        == pendingDiagnostic.receiptDigest)
                                && (checkpointManifestRoot == nil
                                    || checkpointManifestRoot
                                        == pendingDiagnostic.segmentManifestRoot)
                                && floorDigest == recoveryDiagnosticDigest(
                                    pendingDiagnostic
                                ))
                                || (floor < UInt64.max
                                    && pendingGeneration == floor + 1
                                    && pendingDiagnostic.checkpointEpoch
                                        == String(checkpointFloor + 1)
                                    && pendingDiagnostic.previousDigest == floorDigest))
                    } else {
                        chainIsValid = pendingPayloadIsBound
                            && checkpointFloor == floor
                            && pendingGeneration > floor
                            && pendingDiagnostic.checkpointEpoch
                                == pendingDiagnostic.generation
                            && pendingDiagnostic.previousDigest == floorDigest
                    }
                } else {
                    chainIsValid = pendingPayloadIsBound
                        && (pendingGeneration.map({ $0 == 1 }) ?? false)
                        && pendingDiagnostic.checkpointEpoch == "1"
                        && pendingDiagnostic.previousDigest
                            == String(repeating: "0", count: 64)
                }
                guard chainIsValid else {
                    throw SessionDocumentStoreError.cannotWrite(
                        diagnosticURL
                    )
                }
            }
            if hasQuarantineEvidence,
               pendingDiagnostic == nil || pendingDiagnostic?.phase == .committed {
                var blockedArtifactIDs = Set(
                    stateToPersist.recoveryCheckpointArtifactIDs ?? []
                )
                blockedArtifactIDs.formUnion(
                    stateToPersist.recoveryCheckpointHistory?.flatMap(\.artifactIDs) ?? []
                )
                if let pendingDiagnostic, pendingDiagnostic.phase == .committed {
                    blockedArtifactIDs.formUnion(ownedArtifactIDs(
                        in: Array(pendingDiagnostic.targetFileIdentities.keys),
                        sessionID: state.sessionID
                    ))
                }
                guard let receiptNames = try? quarantineReceiptNames(),
                      blockedArtifactIDs.isDisjoint(with: ownedArtifactIDs(
                          in: receiptNames, sessionID: state.sessionID
                      )) else {
                    throw SessionDocumentStoreError.cannotWrite(diagnosticURL)
                }
            }
            let data = try encoder.encode(stateToPersist)
            // Persist the prepared journal before mutating the caller's state.
            // An unsafe receipt set must leave existing document bytes (or
            // absence) untouched; unlink remains after the durable state write.
            let hasPendingDiagnostic = pendingDiagnostic != nil
            let needsCleanupDiagnostic = hasQuarantineEvidence || hasPendingDiagnostic
            var cleanupDiagnostic: RecoveryDiagnostic?
            if needsCleanupDiagnostic {
                if let pendingDiagnostic,
                   !hasQuarantineEvidence,
                   isQuarantineEmptyLocked() {
                    // All prepared targets disappeared before the commit
                    // marker could be written. There is nothing to unlink;
                    // finish the journal only after proving the set is empty.
                    cleanupDiagnostic = pendingDiagnostic
                } else {
                    guard let diagnostic = makeRecoveryDiagnosticLocked(
                        for: state.sessionID,
                        previous: pendingDiagnostic,
                        previousGenerationFloor: stateToPersist.recoveryGeneration,
                        previousDigestFloor: stateToPersist.recoveryDiagnosticDigest,
                        previousCheckpointEpochFloor:
                            stateToPersist.recoveryCheckpointEpoch,
                        previousCheckpointReceiptDigestFloor:
                            stateToPersist.recoveryCheckpointReceiptDigest,
                        previousCheckpointManifestRootFloor:
                            stateToPersist.recoveryCheckpointManifestRoot,
                        previousCheckpointArtifactIDsFloor:
                            stateToPersist.recoveryCheckpointArtifactIDs,
                        previousCheckpointHistoryFloor:
                            stateToPersist.recoveryCheckpointHistory
                    ) else {
                        throw SessionDocumentStoreError.cannotWrite(
                            recoveryDiagnosticURL(for: state.sessionID)
                        )
                    }
                    try writeRecoveryDiagnosticAtomically(
                        diagnostic,
                        in: directoryDescriptor,
                        previous: pendingDiagnostic
                    )
                    cleanupDiagnostic = diagnostic
                }
            }
            guard try persistedStateIdentity(
                in: directoryDescriptor,
                name: fileURL.lastPathComponent,
                errorURL: fileURL
            ) == baseline.identity,
            Self.isSameDirectoryObject(
                try filesystemIdentity(at: documentsDirectory, requiringDirectory: true),
                as: parentIdentity
            ), try filesystemIdentity(
                of: descriptor, requiringDirectory: false, errorURL: lockURL
            ) == lockIdentity else {
                throw SessionDocumentStoreError.cannotWrite(fileURL)
            }
            try writeStateAtomically(
                data,
                fileName: fileURL.lastPathComponent,
                in: directoryDescriptor,
                errorURL: fileURL
            )

            guard Self.isSameDirectoryObject(
                try filesystemIdentity(
                    of: directoryDescriptor,
                    requiringDirectory: true,
                    errorURL: documentsDirectory
                ),
                as: parentIdentity
            ) else {
                throw SessionDocumentStoreError.cannotWrite(documentsDirectory)
            }

            guard let nextIdentity = try persistedStateIdentity(
                in: directoryDescriptor,
                name: fileURL.lastPathComponent,
                errorURL: fileURL
            ) else {
                throw SessionDocumentStoreError.cannotWrite(fileURL)
            }
            guard let currentFilesystemIdentity = try existingFilesystemIdentity(
                in: directoryDescriptor,
                name: fileURL.lastPathComponent,
                requiringDirectory: false,
                errorURL: fileURL
            ), SessionDocumentFileIdentity(
                device: currentFilesystemIdentity.device,
                inode: currentFilesystemIdentity.inode
            ) == nextIdentity else {
                throw SessionDocumentStoreError.cannotWrite(fileURL)
            }
            var currentDocumentIdentity = nextIdentity
            guard Self.isSameDirectoryObject(
                try filesystemIdentity(
                    at: documentsDirectory, requiringDirectory: true
                ),
                as: parentIdentity
            ) else {
                throw SessionDocumentStoreError.cannotWrite(documentsDirectory)
            }

            guard try filesystemIdentity(
                of: descriptor, requiringDirectory: false, errorURL: lockURL
            ) == lockIdentity else {
                throw SessionDocumentStoreError.cannotWrite(lockURL)
            }

            guard Self.isSameDirectoryObject(
                try filesystemIdentity(
                    at: documentsDirectory, requiringDirectory: true
                ),
                as: parentIdentity
            ) else {
                throw SessionDocumentStoreError.cannotWrite(documentsDirectory)
            }
            // Treat the freshly persisted session document as a CAS target:
            // cleanup may only operate while this exact dev/inode remains
            // current, never a replacement from another document.
            guard try persistedStateIdentity(
                in: directoryDescriptor,
                name: fileURL.lastPathComponent,
                errorURL: fileURL
            ) == currentDocumentIdentity else {
                throw SessionDocumentStoreError.cannotWrite(fileURL)
            }

            persistedBaselines[state.sessionID] = PersistedStateBaseline(
                identity: currentDocumentIdentity
            )
            guard try persistedStateIdentity(
                in: directoryDescriptor,
                name: fileURL.lastPathComponent,
                errorURL: fileURL
            ) == currentDocumentIdentity else {
                throw SessionDocumentStoreError.cannotWrite(fileURL)
            }
            var committedGeneration: UInt64?
            var clearCommittedDiagnosticAfterHandoff = false
            if cleanupQuarantineLocked(for: state.sessionID) {
                if let cleanupDiagnostic {
                    if cleanupDiagnostic.phase == .prepared {
                        let committedDiagnostic = RecoveryDiagnostic(
                            sessionID: cleanupDiagnostic.sessionID,
                            code: cleanupDiagnostic.code,
                            anomalyKey: cleanupDiagnostic.anomalyKey,
                            canonicalPayload: cleanupDiagnostic.canonicalPayload,
                            generation: cleanupDiagnostic.generation,
                            previousDigest: cleanupDiagnostic.previousDigest,
                            checkpointEpoch: cleanupDiagnostic.checkpointEpoch,
                            receiptDigest: cleanupDiagnostic.receiptDigest,
                            segmentManifestRoot: cleanupDiagnostic.segmentManifestRoot,
                            segmentPayloadIdentities:
                                cleanupDiagnostic.segmentPayloadIdentities,
                            targetFileIdentities: cleanupDiagnostic.targetFileIdentities,
                            phase: .committed,
                            message: cleanupDiagnostic.message
                        )
                        try commitRecoveryDiagnosticAtomically(
                            committedDiagnostic,
                            replacing: cleanupDiagnostic,
                            in: directoryDescriptor
                        )
                        committedGeneration = UInt64(committedDiagnostic.generation)
                    } else if !hasQuarantineEvidence {
                        // A committed marker with an empty quarantine set is
                        // the only safe point at which the replay ledger may
                        // be retired. If the marker survived a crash before
                        // the state handoff, first carry its checkpoint into
                        // the durable state; an already handed-off marker is
                        // idempotent and must not append a duplicate epoch.
                        let committedDigest = recoveryDiagnosticDigest(
                            cleanupDiagnostic
                        )
                        let stateAlreadyHandedOff =
                            stateToPersist.recoveryGeneration
                                == UInt64(cleanupDiagnostic.generation)
                            && stateToPersist.recoveryDiagnosticDigest
                                == committedDigest
                            && stateToPersist.recoveryCheckpointEpoch
                                == UInt64(cleanupDiagnostic.generation)
                            && stateToPersist.recoveryCheckpointReceiptDigest
                                == cleanupDiagnostic.receiptDigest
                            && stateToPersist.recoveryCheckpointManifestRoot
                                == cleanupDiagnostic.segmentManifestRoot
                            && stateToPersist.recoveryCheckpointArtifactIDs
                                == ownedArtifactIDs(
                                    in: Array(cleanupDiagnostic.targetFileIdentities.keys),
                                    sessionID: state.sessionID
                                ).sorted()
                            && stateToPersist.recoveryCheckpointHistory?.last?.epoch
                                == UInt64(cleanupDiagnostic.generation)
                            && stateToPersist.recoveryCheckpointHistory?.last?.receiptDigest
                                == cleanupDiagnostic.receiptDigest
                            && stateToPersist.recoveryCheckpointHistory?.last?.manifestRoot
                                == cleanupDiagnostic.segmentManifestRoot
                            && stateToPersist.recoveryCheckpointHistoryDigest
                                == stateToPersist.recoveryCheckpointHistory.map({
                                    recoveryCheckpointHistoryDigest($0)
                                })
                        if !stateAlreadyHandedOff {
                            committedGeneration = UInt64(cleanupDiagnostic.generation)
                            clearCommittedDiagnosticAfterHandoff = true
                        } else {
                            try clearRecoveryDiagnostic(
                                for: state.sessionID,
                                in: directoryDescriptor
                            )
                        }
                    }
                }
                if let committedGeneration {
                    let previousCheckpointEpoch = stateToPersist.recoveryCheckpointEpoch
                    let previousCheckpointReceiptDigest =
                        stateToPersist.recoveryCheckpointReceiptDigest
                    let previousCheckpointManifestRoot =
                        stateToPersist.recoveryCheckpointManifestRoot
                    let previousCheckpointArtifactIDs =
                        stateToPersist.recoveryCheckpointArtifactIDs
                    let previousCheckpointHistory =
                        stateToPersist.recoveryCheckpointHistory
                    var durableState = stateToPersist
                    durableState.recoveryGeneration = committedGeneration
                    durableState.recoveryCheckpointEpoch = committedGeneration
                    if let cleanupDiagnostic {
                        let committedDiagnostic = RecoveryDiagnostic(
                            sessionID: cleanupDiagnostic.sessionID,
                            code: cleanupDiagnostic.code,
                            anomalyKey: cleanupDiagnostic.anomalyKey,
                            canonicalPayload: cleanupDiagnostic.canonicalPayload,
                            generation: cleanupDiagnostic.generation,
                            previousDigest: cleanupDiagnostic.previousDigest,
                            checkpointEpoch: cleanupDiagnostic.checkpointEpoch,
                            receiptDigest: cleanupDiagnostic.receiptDigest,
                            segmentManifestRoot: cleanupDiagnostic.segmentManifestRoot,
                            segmentPayloadIdentities:
                                cleanupDiagnostic.segmentPayloadIdentities,
                            targetFileIdentities: cleanupDiagnostic.targetFileIdentities,
                            phase: .committed,
                            message: cleanupDiagnostic.message
                        )
                        durableState.recoveryDiagnosticDigest =
                            recoveryDiagnosticDigest(committedDiagnostic)
                        durableState.recoveryCheckpointReceiptDigest =
                            committedDiagnostic.receiptDigest
                        durableState.recoveryCheckpointManifestRoot =
                            committedDiagnostic.segmentManifestRoot
                        let checkpointArtifactIDs = ownedArtifactIDs(
                            in: Array(committedDiagnostic.targetFileIdentities.keys),
                            sessionID: state.sessionID
                        ).sorted()
                        guard !checkpointArtifactIDs.isEmpty else {
                            throw SessionDocumentStoreError.cannotWrite(diagnosticURL)
                        }
                        durableState.recoveryCheckpointArtifactIDs = checkpointArtifactIDs
                        var checkpointHistory =
                            previousCheckpointHistory ?? []
                        if checkpointHistory.isEmpty,
                           let previousCheckpointEpoch,
                           let previousCheckpointReceiptDigest,
                           let previousCheckpointManifestRoot,
                           let previousCheckpointArtifactIDs,
                           !previousCheckpointArtifactIDs.isEmpty {
                            checkpointHistory.append(
                                SessionDocumentRecoveryCheckpoint(
                                    epoch: previousCheckpointEpoch,
                                    receiptDigest: previousCheckpointReceiptDigest,
                                    manifestRoot: previousCheckpointManifestRoot,
                                    artifactIDs: previousCheckpointArtifactIDs,
                                    previousReceiptDigest:
                                        String(repeating: "0", count: 64),
                                    previousManifestRoot:
                                        String(repeating: "0", count: 64)
                                )
                            )
                        }
                        guard checkpointHistory.last?.epoch ?? 0 < committedGeneration else {
                            throw SessionDocumentStoreError.cannotWrite(diagnosticURL)
                        }
                        checkpointHistory.append(
                            SessionDocumentRecoveryCheckpoint(
                                epoch: committedGeneration,
                                receiptDigest: committedDiagnostic.receiptDigest,
                                manifestRoot: committedDiagnostic.segmentManifestRoot,
                                artifactIDs: checkpointArtifactIDs,
                                previousReceiptDigest:
                                    previousCheckpointReceiptDigest
                                    ?? String(repeating: "0", count: 64),
                                previousManifestRoot:
                                    previousCheckpointManifestRoot
                                    ?? String(repeating: "0", count: 64)
                            )
                        )
                        if checkpointHistory.count
                                > Self.maxRecoveryCheckpointHistoryCount {
                            checkpointHistory.removeFirst(
                                checkpointHistory.count
                                    - Self.maxRecoveryCheckpointHistoryCount
                            )
                        }
                        durableState.recoveryCheckpointHistory = checkpointHistory
                        durableState.recoveryCheckpointHistoryDigest =
                            recoveryCheckpointHistoryDigest(checkpointHistory)
                    }
                    let durableData = try encoder.encode(durableState)
                    try writeStateAtomically(
                        durableData,
                        fileName: fileURL.lastPathComponent,
                        in: directoryDescriptor,
                        errorURL: fileURL,
                        expectedDestinationIdentity: currentFilesystemIdentity
                    )
                    guard let durableIdentity = try persistedStateIdentity(
                        in: directoryDescriptor,
                        name: fileURL.lastPathComponent,
                        errorURL: fileURL
                    ) else {
                        throw SessionDocumentStoreError.cannotWrite(fileURL)
                    }
                    currentDocumentIdentity = durableIdentity
                    recoveryGenerationFloors[state.sessionID] = max(
                        recoveryGenerationFloors[state.sessionID] ?? 0,
                        committedGeneration
                    )
                    recoveryCheckpointEpochFloors[state.sessionID] = max(
                        recoveryCheckpointEpochFloors[state.sessionID] ?? 0,
                        committedGeneration
                    )
                    if let digest = durableState.recoveryDiagnosticDigest {
                        recoveryDiagnosticDigestFloors[state.sessionID] = digest
                    }
                    if let receiptDigest = durableState.recoveryCheckpointReceiptDigest {
                        recoveryCheckpointReceiptDigestFloors[state.sessionID] = receiptDigest
                    }
                    if let manifestRoot = durableState.recoveryCheckpointManifestRoot {
                        recoveryCheckpointManifestRootFloors[state.sessionID] = manifestRoot
                    }
                    if let artifactIDs = durableState.recoveryCheckpointArtifactIDs {
                        recoveryCheckpointArtifactIDFloors[state.sessionID] = Set(artifactIDs)
                    }
                    if let history = durableState.recoveryCheckpointHistory {
                        recoveryCheckpointHistoryFloors[state.sessionID] = history
                    }
                    if let historyDigest = durableState.recoveryCheckpointHistoryDigest {
                        recoveryCheckpointHistoryDigestFloors[state.sessionID] = historyDigest
                    }
                    persistedBaselines[state.sessionID] = PersistedStateBaseline(
                        identity: durableIdentity
                    )
                    if clearCommittedDiagnosticAfterHandoff {
                        try clearRecoveryDiagnostic(
                            for: state.sessionID,
                            in: directoryDescriptor
                        )
                    }
                }
                recoveryFailures.remove(state.sessionID)
            } else {
                recoveryFailures.insert(state.sessionID)
            }
            guard try persistedStateIdentity(
                in: directoryDescriptor,
                name: fileURL.lastPathComponent,
                errorURL: fileURL
            ) == currentDocumentIdentity else {
                throw SessionDocumentStoreError.cannotWrite(fileURL)
            }
        } catch let error as SessionDocumentStoreError {
            // Preserve the exact guarded path so callers can explain which
            // recovery boundary rejected the write (for example, a tampered
            // lock path) instead of collapsing every failure to the state URL.
            throw error
        } catch {
            throw SessionDocumentStoreError.cannotWrite(fileURL)
        }
    }

    private func writeTextAtomically(_ text: String, to url: URL) throws {
        guard let canonical = Self.stableMappedURL(url) else {
            throw SessionDocumentStoreError.cannotWrite(url)
        }
        let parentURL = canonical.deletingLastPathComponent()
        let parentDescriptor = open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else {
            throw SessionDocumentStoreError.cannotWrite(canonical)
        }
        defer { _ = close(parentDescriptor) }
        guard let parentIdentity = try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: parentURL
        ) else {
            throw SessionDocumentStoreError.cannotWrite(canonical)
        }
        let destinationName = canonical.lastPathComponent
        let destinationIdentity: FilesystemIdentity?
        do {
            destinationIdentity = try existingFilesystemIdentity(
                in: parentDescriptor,
                name: destinationName,
                requiringDirectory: false,
                errorURL: canonical
            )
        } catch {
            // A symlink, directory, or foreign-owned target is not a valid
            // external document destination and must not be followed.
            throw SessionDocumentStoreError.cannotWrite(canonical)
        }
        guard text.utf8.count <= Self.maxPersistedStateBytes else {
            throw SessionDocumentStoreError.cannotWrite(canonical)
        }
        let data = Data(text.utf8)
        do {
            _ = try writeStateAtomically(
                data,
                fileName: destinationName,
                in: parentDescriptor,
                errorURL: canonical,
                expectedDestinationIdentity: destinationIdentity,
                requireDestinationMissing: destinationIdentity == nil
            )
        } catch {
            throw SessionDocumentStoreError.cannotWrite(canonical)
        }
        guard Self.isSameDirectoryObject(
            try? filesystemIdentity(
                of: parentDescriptor,
                requiringDirectory: true,
                errorURL: parentURL
            ),
            as: parentIdentity
        ), Self.isSameDirectoryObject(
            try? filesystemIdentity(
                at: parentURL,
                requiringDirectory: true
            ),
            as: parentIdentity
        ) else {
            throw SessionDocumentStoreError.cannotWrite(canonical)
        }
    }

    private func quarantine(url: URL, sessionID: UUID) {
        recoveryFailures.insert(sessionID)
        let parentDescriptor = open(
            documentsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else { return }
        defer { _ = close(parentDescriptor) }
        guard let parentIdentity = try? filesystemIdentity(
            of: parentDescriptor,
            requiringDirectory: true,
            errorURL: documentsDirectory
        ), let sourceIdentity = try? existingFilesystemIdentity(
            in: parentDescriptor,
            name: url.lastPathComponent,
            requiringDirectory: false,
            errorURL: url
        ), sourceIdentity.hardLinkCount == 1 else {
            return
        }

        let quarantineName = quarantineDirectory.lastPathComponent
        var quarantineDescriptor = openat(
            parentDescriptor,
            quarantineName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if quarantineDescriptor < 0, errno == ENOENT {
            guard mkdirat(parentDescriptor, quarantineName, mode_t(0o700)) == 0
                    || errno == EEXIST else { return }
            quarantineDescriptor = openat(
                parentDescriptor,
                quarantineName,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard quarantineDescriptor >= 0 else { return }
        defer { _ = close(quarantineDescriptor) }
        guard let quarantineIdentity = try? filesystemIdentity(
            of: quarantineDescriptor,
            requiringDirectory: true,
            errorURL: quarantineDirectory
        ) else {
            return
        }

        for _ in 0..<16 {
            let destinationName = "\(sessionID.uuidString)-\(UUID().uuidString).json"
            let destinationURL = quarantineDirectory.appendingPathComponent(
                destinationName
            )
            let destinationIdentity: FilesystemIdentity?
            do {
                destinationIdentity = try existingFilesystemIdentity(
                    in: quarantineDescriptor,
                    name: destinationName,
                    requiringDirectory: false,
                    errorURL: destinationURL
                )
            } catch {
                // A collision of any kind, including a symlink, is not a
                // missing destination and must never be overwritten.
                return
            }
            guard destinationIdentity == nil else {
                continue
            }
            guard Self.isSameDirectoryObject(
                try? filesystemIdentity(
                    of: parentDescriptor,
                    requiringDirectory: true,
                    errorURL: documentsDirectory
                ),
                as: parentIdentity
            ),
            (try? filesystemIdentity(
                of: quarantineDescriptor,
                requiringDirectory: true,
                errorURL: quarantineDirectory
            )) == quarantineIdentity,
            (try? existingFilesystemIdentity(
                in: parentDescriptor,
                name: url.lastPathComponent,
                requiringDirectory: false,
                errorURL: url
            )) == sourceIdentity else {
                return
            }
            guard renameat(
                parentDescriptor,
                url.lastPathComponent,
                quarantineDescriptor,
                destinationName
            ) == 0 else {
                return
            }
            guard let destinationIdentity = try? existingFilesystemIdentity(
                in: quarantineDescriptor,
                name: destinationName,
                requiringDirectory: false,
                errorURL: quarantineDirectory.appendingPathComponent(destinationName)
            ), destinationIdentity == sourceIdentity,
            (try? existingFilesystemIdentity(
                in: parentDescriptor,
                name: url.lastPathComponent,
                requiringDirectory: false,
                errorURL: url
            )) == nil,
            fsync(quarantineDescriptor) == 0,
            fsync(parentDescriptor) == 0 else {
                return
            }
            return
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func recoverySegmentManifestRoot(
        targetFileIdentities: [String: SessionDocumentFileIdentity],
        segmentPayloadIdentities: [String: RecoverySegmentPayloadIdentity]
    ) -> String {
        let material = targetFileIdentities.keys.sorted().map { name in
            let target = targetFileIdentities[name]!
            let segment = segmentPayloadIdentities[name]!
            return [
                name,
                String(target.device),
                String(target.inode),
                String(segment.byteCount),
                segment.contentHash,
            ].joined(separator: "|")
        }.joined(separator: "\n")
        return Self.sha256Hex(
            Data("miniscanvas-segment-manifest-v1\n\(material)".utf8)
        )
    }

    private func recoveryCheckpointHistoryDigest(
        _ history: [SessionDocumentRecoveryCheckpoint]
    ) -> String {
        guard let data = try? recoveryCheckpointEncoder.encode(history) else {
            return String(repeating: "0", count: 64)
        }
        return Self.sha256Hex(data)
    }

    private func recoveryDiagnosticDigest(_ diagnostic: RecoveryDiagnostic) -> String {
        Self.sha256Hex((try? recoveryDiagnosticEncoder.encode(diagnostic)) ?? Data())
    }
}

/// JSONDecoder accepts duplicate object keys by keeping the last value. A
/// recovery snapshot cannot use that behavior because a partial write could
/// silently replace a document or selected pointer. This bounded preflight
/// rejects duplicate keys and trailing bytes before semantic decoding.
private struct SessionDocumentJSONIntegrityScanner {
    private static let maxTabCount = 4_096
    private static let maxNestingDepth = 64
    private static let maxObjectKeyCount = 64
    private static let maxAggregateTokenCount = 262_144
    private static let maxAggregateKeyCount = 65_536
    private static let maxAggregateStringBytes = 4 * 1024 * 1024
    private static let maxRawStringTokenBytes = 1 * 1024 * 1024

    private enum ScanError: Error {
        case malformed
        case duplicateKey
    }

    private let data: Data
    private let bytes: [UInt8]
    private var index = 0
    private var nestingDepth = 0
    private var aggregateTokenCount = 0
    private var aggregateKeyCount = 0
    private var aggregateStringBytes = 0
    private let allowedRootKeys: Set<String>?
    private let objectKeyLimit: Int

    init(
        data: Data,
        allowedRootKeys: Set<String>? = nil,
        maxObjectKeyCount: Int = Self.maxObjectKeyCount
    ) {
        self.data = data
        self.bytes = Array(data)
        self.allowedRootKeys = allowedRootKeys
        self.objectKeyLimit = maxObjectKeyCount
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw ScanError.malformed }
        try validateSchema()
    }

    private func validateSchema() throws {
        if let allowedRootKeys {
            guard let root = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  Set(root.keys) == allowedRootKeys else {
                throw ScanError.malformed
            }
            return
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: Set([
                  "schemaVersion", "sessionID", "tabs", "selectedTabID",
                  "recoveryGeneration", "recoveryDiagnosticDigest",
                  "recoveryCheckpointEpoch", "recoveryCheckpointReceiptDigest",
                  "recoveryCheckpointManifestRoot", "recoveryCheckpointArtifactIDs",
                  "recoveryCheckpointHistory", "recoveryCheckpointHistoryDigest"
              ])),
              root["sessionID"] != nil,
              root["tabs"] != nil,
              let tabs = root["tabs"] as? [Any],
              tabs.count <= Self.maxTabCount else {
            throw ScanError.malformed
        }
        if let historyValue = root["recoveryCheckpointHistory"] {
            guard let history = historyValue as? [[String: Any]],
                  history.count <= 8,
                  history.allSatisfy({ checkpoint in
                      Set(checkpoint.keys) == Set([
                          "epoch", "receiptDigest", "manifestRoot", "artifactIDs",
                          "previousReceiptDigest", "previousManifestRoot"
                      ])
                  }) else {
                throw ScanError.malformed
            }
        }
        for tabValue in tabs {
            guard let tab = tabValue as? [String: Any],
                  Set(tab.keys).isSubset(of: Set([
                      "id", "sessionID", "title", "text", "savedText", "fileURL",
                      "fileIdentity", "fileContentHash", "createdAt", "updatedAt"
                  ])),
                  ["id", "sessionID", "title", "text", "savedText", "createdAt", "updatedAt"]
                      .allSatisfy({ tab[$0] != nil }) else {
                throw ScanError.malformed
            }
            if let identity = tab["fileIdentity"], !(identity is NSNull) {
                guard let identity = identity as? [String: Any],
                      Set(identity.keys) == Set(["device", "inode"]) else {
                    throw ScanError.malformed
                }
            }
        }
    }

    private mutating func parseValue() throws {
        guard aggregateTokenCount < Self.maxAggregateTokenCount else {
            throw ScanError.malformed
        }
        aggregateTokenCount += 1
        nestingDepth += 1
        defer { nestingDepth -= 1 }
        guard nestingDepth <= Self.maxNestingDepth else { throw ScanError.malformed }
        guard let byte = peek else { throw ScanError.malformed }
        switch byte {
        case 0x7B: try parseObject()
        case 0x5B: try parseArray()
        case 0x22: _ = try parseString()
        case 0x2D, 0x30...0x39: try parseNumber()
        case 0x74: try parseLiteral("true")
        case 0x66: try parseLiteral("false")
        case 0x6E: try parseLiteral("null")
        default: throw ScanError.malformed
        }
    }

    private mutating func parseObject() throws {
        try expect(0x7B)
        skipWhitespace()
        var keys = Set<String>()
        if consume(0x7D) { return }
        while true {
            guard peek == 0x22 else { throw ScanError.malformed }
            let key = try parseString()
            guard keys.count < objectKeyLimit else { throw ScanError.malformed }
            guard aggregateKeyCount < Self.maxAggregateKeyCount else {
                throw ScanError.malformed
            }
            aggregateKeyCount += 1
            guard keys.insert(key).inserted else { throw ScanError.duplicateKey }
            skipWhitespace()
            try expect(0x3A)
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            if consume(0x7D) { return }
            try expect(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws {
        try expect(0x5B)
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue()
            skipWhitespace()
            if consume(0x5D) { return }
            try expect(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        try expect(0x22)
        while let byte = peek {
            if byte == 0x22 {
                index += 1
                guard index - start <= Self.maxRawStringTokenBytes else {
                    throw ScanError.malformed
                }
                let string = try JSONDecoder().decode(
                    String.self, from: data.subdata(in: start..<index)
                )
                let stringByteCount = string.utf8.count
                guard stringByteCount <= Self.maxAggregateStringBytes,
                      aggregateStringBytes <= Self.maxAggregateStringBytes - stringByteCount else {
                    throw ScanError.malformed
                }
                aggregateStringBytes += stringByteCount
                return string
            }
            if byte == 0x5C {
                index += 1
                guard let escaped = peek else { throw ScanError.malformed }
                index += 1
                if escaped == 0x75 {
                    try parseUnicodeEscape()
                } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) {
                    throw ScanError.malformed
                }
            } else {
                guard byte >= 0x20 else { throw ScanError.malformed }
                index += 1
            }
            guard index - start <= Self.maxRawStringTokenBytes else {
                throw ScanError.malformed
            }
        }
        throw ScanError.malformed
    }

    private mutating func parseUnicodeEscape() throws {
        let high = try parseUnicodeCodeUnit()
        if (0xD800...0xDBFF).contains(high) {
            guard peek == 0x5C,
                  index + 1 < bytes.count,
                  bytes[index + 1] == 0x75 else {
                throw ScanError.malformed
            }
            index += 2
            let low = try parseUnicodeCodeUnit()
            guard (0xDC00...0xDFFF).contains(low) else {
                throw ScanError.malformed
            }
        } else if (0xDC00...0xDFFF).contains(high) {
            throw ScanError.malformed
        }
    }

    private mutating func parseUnicodeCodeUnit() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw ScanError.malformed }
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let hex = peek, isHex(hex) else { throw ScanError.malformed }
            value = value * 16 + UInt16(hexValue(hex))
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws {
        let start = index
        _ = consume(0x2D)
        switch peek {
        case 0x30:
            index += 1
            if let next = peek, (0x30...0x39).contains(next) {
                throw ScanError.malformed
            }
        case let digit? where (0x31...0x39).contains(digit):
            repeat { index += 1 } while peek.map({ (0x30...0x39).contains($0) }) == true
        default:
            throw ScanError.malformed
        }
        if consume(0x2E) {
            guard let digit = peek, (0x30...0x39).contains(digit) else {
                throw ScanError.malformed
            }
            repeat { index += 1 } while peek.map({ (0x30...0x39).contains($0) }) == true
        }
        if peek == 0x45 || peek == 0x65 {
            index += 1
            if peek == 0x2D || peek == 0x2B {
                index += 1
            }
            guard let digit = peek, (0x30...0x39).contains(digit) else {
                throw ScanError.malformed
            }
            repeat { index += 1 } while peek.map({ (0x30...0x39).contains($0) }) == true
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let number = Double(token), number.isFinite else {
            throw ScanError.malformed
        }
    }

    private mutating func parseLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw ScanError.malformed
        }
        index += expected.count
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard consume(byte) else { throw ScanError.malformed }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard peek == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private var peek: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }

    private func hexValue(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        default: return byte - 0x61 + 10
        }
    }
}
