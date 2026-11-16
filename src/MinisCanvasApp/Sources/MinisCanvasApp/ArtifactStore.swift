import CryptoKit
import Darwin
import Foundation
import CanvasCore

enum ArtifactStoreError: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case invalidContext
    case identityMismatch
    case invalidPayload
    case missingFile
    case notRegularFile
    case pathOutsideDirectory
    case symlinkRejected
    case invalidTarget
    case versionMismatch
    case deleted
    case persistenceFailed
    case recoveryRequired

    var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消的媒体任务不得生成 artifact"
        case .invalidContext: return "artifact 缺少有效的 Canvas 执行身份"
        case .identityMismatch: return "相同任务 ID 不能跨 Canvas 执行身份复用 artifact"
        case .invalidPayload: return "媒体完成结果与任务上下文不一致"
        case .missingFile: return "媒体文件不存在或不是普通文件"
        case .notRegularFile: return "媒体路径不是普通文件"
        case .pathOutsideDirectory: return "媒体路径不在允许的 artifact 根目录内"
        case .symlinkRejected: return "不接受符号链接媒体路径"
        case .invalidTarget: return "artifact 目标无效，已阻止打开或定位"
        case .versionMismatch: return "artifact receipt 版本不匹配，已隔离等待恢复"
        case .deleted: return "artifact 已删除，拒绝迟到写回"
        case .persistenceFailed: return "artifact receipt 无法原子持久化"
        case .recoveryRequired: return "artifact receipt 快照需要恢复，已拒绝继续写入"
        }
    }
}

struct ArtifactOrigin: Codable, Equatable, Sendable {
    let providerID: String
    let modelID: String
    let configurationFingerprint: String
    let promptFingerprint: String
    let idempotencyKey: String
}

enum ArtifactTerminalState: String, Codable, Sendable, Equatable {
    case succeeded
    case unknown

    var isDurableSuccess: Bool { self == .succeeded }
}

enum ArtifactRecoveryState: String, Codable, Sendable, Equatable {
    case ready
    case recoveryRequired
}

/// 用户可理解的 artifact/result 目标状态。状态只描述引用和文件事实，
/// 永远不包含媒体内容、凭据或 provider secret。
enum ArtifactUserStatus: String, Codable, Sendable, Equatable {
    case ready
    case missing
    /// The target still exists but its bytes no longer match the durable
    /// receipt. It must not be opened as if it were the original result.
    case stale
    case invalidTarget
    case quarantined
    case versionMismatch
    case deleted
    case rollbackAvailable
    case recoveryRequired
}

enum ArtifactTargetAction: String, Codable, Sendable, Equatable {
    case open
    case reveal
}

struct ArtifactRollbackMetadata: Codable, Equatable, Sendable {
    let previousArtifactID: String?
    let previousChecksum: String?
    let previousTargetPath: String?
    let reason: String
    let recordedAt: Date
}

/// Source -> result 的稳定、secret-free lineage。sourceArtifactID 可为空，
/// 代表该结果是文档/任务链的首个产物。
struct ArtifactResultLineage: Codable, Equatable, Sendable {
    let sourceArtifactID: String?
    let sourceRevision: String
    let producerRevision: String
    let resultRevision: String
}

struct ArtifactFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct ArtifactTargetValidation: Codable, Equatable, Sendable {
    let artifactID: String
    let action: ArtifactTargetAction
    let status: ArtifactUserStatus
    let targetPath: String?
    let message: String
}

struct ArtifactStoreDiagnostics: Codable, Equatable, Sendable {
    let state: ArtifactRecoveryState
    let reason: String?

    var isHealthy: Bool { state == .ready }
}

struct ArtifactReceipt: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let canvasID: UUID
    let runID: UUID
    let graphRevision: Int
    let nodeID: UUID
    let nodeRevision: Int
    let taskID: String
    let version: Int
    let localPath: String
    let checksum: String
    let fileIdentity: ArtifactFileIdentity?
    let createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
    /// Legacy snapshots may not carry origin/terminal/file identity fields.
    /// They remain inspectable but are never trusted for a production result.
    let origin: ArtifactOrigin?
    let terminalState: ArtifactTerminalState
    let targetPath: String?
    let lineage: ArtifactResultLineage?
    let rollback: ArtifactRollbackMetadata?

    init(
        id: String,
        canvasID: UUID,
        runID: UUID,
        graphRevision: Int,
        nodeID: UUID,
        nodeRevision: Int,
        taskID: String,
        version: Int,
        localPath: String,
        checksum: String,
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool,
        fileIdentity: ArtifactFileIdentity? = nil,
        origin: ArtifactOrigin? = nil,
        terminalState: ArtifactTerminalState = .unknown,
        targetPath: String? = nil,
        lineage: ArtifactResultLineage? = nil,
        rollback: ArtifactRollbackMetadata? = nil
    ) {
        self.id = id
        self.canvasID = canvasID
        self.runID = runID
        self.graphRevision = graphRevision
        self.nodeID = nodeID
        self.nodeRevision = nodeRevision
        self.taskID = taskID
        self.version = version
        self.localPath = localPath
        self.checksum = checksum
        self.fileIdentity = fileIdentity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.origin = origin
        self.terminalState = terminalState
        self.targetPath = targetPath
        self.lineage = lineage
        self.rollback = rollback
    }

    private enum CodingKeys: String, CodingKey {
        case id, canvasID, runID, graphRevision, nodeID, nodeRevision
        case taskID, version, localPath, checksum, fileIdentity, createdAt, updatedAt, isDeleted
        case origin, terminalState, targetPath, lineage, rollback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            canvasID: try container.decode(UUID.self, forKey: .canvasID),
            runID: try container.decode(UUID.self, forKey: .runID),
            graphRevision: try container.decode(Int.self, forKey: .graphRevision),
            nodeID: try container.decode(UUID.self, forKey: .nodeID),
            nodeRevision: try container.decode(Int.self, forKey: .nodeRevision),
            taskID: try container.decode(String.self, forKey: .taskID),
            version: try container.decode(Int.self, forKey: .version),
            localPath: try container.decode(String.self, forKey: .localPath),
            checksum: try container.decode(String.self, forKey: .checksum),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            isDeleted: try container.decode(Bool.self, forKey: .isDeleted),
            fileIdentity: try container.decodeIfPresent(ArtifactFileIdentity.self, forKey: .fileIdentity),
            origin: try container.decodeIfPresent(ArtifactOrigin.self, forKey: .origin),
            terminalState: try container.decodeIfPresent(
                ArtifactTerminalState.self,
                forKey: .terminalState
            ) ?? .unknown,
            targetPath: try container.decodeIfPresent(String.self, forKey: .targetPath),
            lineage: try container.decodeIfPresent(ArtifactResultLineage.self, forKey: .lineage),
            rollback: try container.decodeIfPresent(ArtifactRollbackMetadata.self, forKey: .rollback)
        )
    }
}

struct ArtifactCompletion: Sendable, Equatable {
    let receipt: ArtifactReceipt
    let created: Bool
}

/// Durable artifact fact source for completed Canvas media.
/// Receipt identity is derived from the persisted task ID, so restart and a
/// repeated provider callback cannot create duplicate artifact references.
actor ArtifactStore {
    static let snapshotFileName = "artifactReceipts.json"

    static let shared = ArtifactStore(
        directory: VideoTaskStore.defaultDirectory().appendingPathComponent("artifacts", isDirectory: true)
    )

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let receipts: [ArtifactReceipt]
    }

    private struct LoadedSnapshot {
        let receipts: [String: ArtifactReceipt]
        let diagnostics: ArtifactStoreDiagnostics
    }

    private static let schemaVersion = 1
    let directory: URL
    private let fileURL: URL
    private let allowedMediaRoot: URL
    private var receipts: [String: ArtifactReceipt] = [:]
    private var diagnosticsValue = ArtifactStoreDiagnostics(state: .ready, reason: nil)

    init(directory: URL, allowedMediaRoot: URL? = nil) {
        self.directory = directory.standardizedFileURL
        self.fileURL = directory.standardizedFileURL.appendingPathComponent(Self.snapshotFileName)
        self.allowedMediaRoot = (allowedMediaRoot ?? directory.deletingLastPathComponent()).standardizedFileURL
        let loaded = Self.load(fileURL: self.fileURL)
        self.receipts = loaded.receipts
        self.diagnosticsValue = loaded.diagnostics
    }

    func receipt(id: String) -> ArtifactReceipt? {
        receipts[id]
    }

    func allReceipts() -> [ArtifactReceipt] {
        receipts.values.sorted { $0.id < $1.id }
    }

    /// Validate the only target that the App may hand to an open/reveal action.
    /// Resolution is rooted at the configured media root and rejects traversal,
    /// symlinks, deleted receipts and stale/corrupt receipt state.
    func validateTarget(
        id: String,
        action: ArtifactTargetAction
    ) -> ArtifactTargetValidation {
        guard diagnosticsValue.isHealthy else {
            let status: ArtifactUserStatus
            switch diagnosticsValue.reason {
            case "version_mismatch": status = .versionMismatch
            case "corrupt_snapshot": status = .quarantined
            default: status = .recoveryRequired
            }
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: status,
                targetPath: nil, message: "artifact 收据需要恢复，暂不能打开或定位。"
            )
        }
        guard let receipt = receipts[id] else {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .missing,
                targetPath: nil, message: "找不到该 artifact 结果。"
            )
        }
        guard Self.isTrustedReceipt(receipt) else {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .recoveryRequired,
                targetPath: nil, message: "artifact 收据身份或版本需要恢复，暂不能打开或定位。"
            )
        }
        guard !receipt.isDeleted else {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: receipt.rollback == nil ? .deleted : .rollbackAvailable,
                targetPath: receipt.targetPath, message: receipt.rollback == nil
                    ? "该 artifact 已删除。"
                    : "该 artifact 已回滚，可从历史恢复。"
            )
        }
        // `version` is the receipt mutation generation (delete/restore), not
        // the snapshot schema version. A restored receipt must therefore be
        // reopenable; only non-positive generations are invalid.
        guard receipt.version > 0 else {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .versionMismatch,
                targetPath: receipt.targetPath, message: "artifact 版本不匹配，已阻止访问。"
            )
        }
        let target: URL
        do {
            target = try validatedTargetURL(for: receipt)
        } catch ArtifactStoreError.missingFile {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .missing,
                targetPath: receipt.targetPath, message: "artifact 文件已不存在，请重新生成。"
            )
        } catch ArtifactStoreError.identityMismatch {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .stale,
                targetPath: receipt.targetPath, message: "artifact 文件身份已变化，已隔离等待恢复。"
            )
        } catch {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .invalidTarget,
                targetPath: receipt.targetPath, message: "artifact 目标不在允许目录内，已阻止访问。"
            )
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .missing,
                targetPath: receipt.targetPath, message: "artifact 文件已不存在，请重新生成。"
            )
        }
        guard let currentData = try? readRegularFile(at: target) else {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .invalidTarget,
                targetPath: receipt.targetPath, message: "artifact 目标已失效，已阻止访问。"
            )
        }
        guard let expectedIdentity = receipt.fileIdentity,
              let currentIdentity = try? fileIdentity(for: target),
              currentIdentity == expectedIdentity else {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .stale,
                targetPath: receipt.targetPath, message: "artifact 文件身份已变化，已隔离等待恢复。"
            )
        }
        guard Self.sha256Hex(data: currentData) == receipt.checksum else {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .stale,
                targetPath: receipt.targetPath, message: "artifact 文件内容已变化，已隔离等待恢复。"
            )
        }
        return ArtifactTargetValidation(
            artifactID: id, action: action, status: .ready,
            targetPath: target.path, message: action == .open ? "artifact 可打开。" : "artifact 可在 Finder 中定位。"
        )
    }

    /// Returns a validated URL only for callers that have first received a
    /// `.ready` validation result. This avoids exposing arbitrary filesystem
    /// paths through the result consumer.
    func targetURL(id: String, action: ArtifactTargetAction) -> URL? {
        let validation = validateTarget(id: id, action: action)
        guard validation.status == .ready, let receipt = receipts[id] else { return nil }
        return try? validatedTargetURL(for: receipt)
    }

    /// Explicit user recovery action for a deleted result. Restore is only
    /// committed when the original target remains inside the trusted root and
    /// still matches the durable checksum; a missing or replaced file stays
    /// isolated and cannot be reopened by accident.
    func reopen(id: String, action: ArtifactTargetAction) -> ArtifactTargetValidation {
        let current = validateTarget(id: id, action: action)
        guard current.status == .rollbackAvailable else { return current }
        guard restore(id: id) else {
            return ArtifactTargetValidation(
                artifactID: id, action: action, status: .recoveryRequired,
                targetPath: current.targetPath, message: "artifact 无法安全恢复，仍保持隔离。"
            )
        }
        return validateTarget(id: id, action: action)
    }

    /// Typed recovery state for the production result consumer. Corrupt or
    /// legacy snapshots are never silently treated as a clean empty store.
    func diagnostics() -> ArtifactStoreDiagnostics {
        diagnosticsValue
    }

    func receipt(for record: VideoTaskRecord) -> ArtifactReceipt? {
        guard diagnosticsValue.isHealthy,
              let receipt = receipts[Self.artifactID(for: record)],
              !receipt.isDeleted,
              receipt.terminalState.isDurableSuccess,
              receipt.origin != nil else {
            return nil
        }
        return receipt
    }

    func recordMediaCompletion(
        _ record: VideoTaskRecord,
        context: MediaTaskContext,
        isCancelled: Bool = false
    ) throws -> ArtifactReceipt {
        try recordMediaCompletionResult(record, context: context, isCancelled: isCancelled).receipt
    }

    func recordMediaCompletion(
        _ record: VideoTaskRecord,
        context: MediaTaskContext,
        executionEnvelope: DAGExecutionEnvelope,
        isCancelled: Bool = false
    ) throws -> ArtifactReceipt {
        try recordMediaCompletionResult(
            record,
            context: context,
            executionEnvelope: executionEnvelope,
            isCancelled: isCancelled
        ).receipt
    }

    func recordMediaCompletionResult(
        _ record: VideoTaskRecord,
        context: MediaTaskContext,
        executionEnvelope: DAGExecutionEnvelope,
        isCancelled: Bool = false
    ) throws -> ArtifactCompletion {
        guard context.executionEnvelope == executionEnvelope,
              context.matches(executionEnvelope: executionEnvelope) else {
            throw ArtifactStoreError.invalidPayload
        }
        return try recordMediaCompletionResult(
            record,
            context: context,
            isCancelled: isCancelled
        )
    }

    func recordMediaCompletionResult(
        _ record: VideoTaskRecord,
        context: MediaTaskContext,
        isCancelled: Bool = false,
        lineage: ArtifactResultLineage? = nil
    ) throws -> ArtifactCompletion {
        guard !isCancelled else { throw ArtifactStoreError.cancelled }
        guard diagnosticsValue.isHealthy else { throw ArtifactStoreError.recoveryRequired }
        guard context.identity.isValid else { throw ArtifactStoreError.invalidContext }
        guard context.providerSnapshot.isValid else { throw ArtifactStoreError.invalidContext }
        guard record.status == .succeeded,
              !record.id.isEmpty,
              record.nodeID == context.identity.nodeID,
              record.providerID == context.providerSnapshot.providerID,
              record.promptFingerprint == context.promptFingerprint,
              record.idempotencyKey == context.idempotencyKey,
              let assetPath = record.assetPath,
              !assetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArtifactStoreError.invalidPayload
        }
        if let lineage,
           lineage.sourceRevision.isEmpty
            || lineage.producerRevision != Self.producerRevision(for: context)
            || lineage.resultRevision.isEmpty {
            throw ArtifactStoreError.invalidPayload
        }

        let id = Self.artifactID(for: record)
        if let existing = receipts[id] {
            guard !existing.isDeleted else { throw ArtifactStoreError.deleted }
            guard existing.terminalState.isDurableSuccess,
                  let existingOrigin = existing.origin else {
                throw ArtifactStoreError.recoveryRequired
            }
            guard Self.sameCanvasScope(existing, context.identity),
                  existingOrigin == Self.origin(for: context) else {
                throw ArtifactStoreError.identityMismatch
            }
            let replayURL = try validatedMediaURL(assetPath)
            let replayData = try readRegularFile(at: replayURL)
            guard let existingFileIdentity = existing.fileIdentity,
                  try fileIdentity(for: replayURL) == existingFileIdentity,
                  replayURL.path == existing.localPath,
                  Self.sha256Hex(data: replayData) == existing.checksum else {
                throw ArtifactStoreError.identityMismatch
            }
            if let lineage {
                guard let existingIdentity = Self.canonicalIdentity(for: existing),
                      Self.canonicalIdentity(
                          taskID: record.id,
                          identity: context.identity,
                          lineage: lineage
                      ) == existingIdentity else {
                    throw ArtifactStoreError.identityMismatch
                }
            }
            return ArtifactCompletion(receipt: existing, created: false)
        }

        let mediaURL = try validatedMediaURL(assetPath)
        let mediaIdentity = try fileIdentity(for: mediaURL)
        let mediaData = try readRegularFile(at: mediaURL)
        guard try fileIdentity(for: mediaURL) == mediaIdentity else {
            throw ArtifactStoreError.identityMismatch
        }
        let receipt = ArtifactReceipt(
            id: id,
            canvasID: context.identity.canvasID,
            runID: context.identity.runID,
            graphRevision: context.identity.graphRevision,
            nodeID: context.identity.nodeID,
            nodeRevision: context.identity.nodeRevision,
            taskID: record.id,
            version: 1,
            localPath: mediaURL.path,
            checksum: Self.sha256Hex(data: mediaData),
            createdAt: Date(),
            updatedAt: Date(),
            isDeleted: false,
            fileIdentity: mediaIdentity,
            origin: Self.origin(for: context),
            terminalState: .succeeded,
            targetPath: Self.relativePath(mediaURL, root: allowedMediaRoot),
            lineage: lineage ?? ArtifactResultLineage(
                sourceArtifactID: nil,
                sourceRevision: context.promptFingerprint,
                producerRevision: Self.producerRevision(for: context),
                resultRevision: Self.sha256Hex(data: mediaData)
            )
        )
        var nextReceipts = receipts
        nextReceipts[id] = receipt
        do {
            try persist(nextReceipts)
            receipts = nextReceipts
        } catch {
            throw ArtifactStoreError.persistenceFailed
        }
        return ArtifactCompletion(receipt: receipt, created: true)
    }

    @discardableResult
    func delete(id: String) -> Bool {
        guard diagnosticsValue.isHealthy else { return false }
        guard var receipt = receipts[id], !receipt.isDeleted else { return false }
        receipt.isDeleted = true
        receipt.updatedAt = Date()
        receipt = ArtifactReceipt(
            id: receipt.id,
            canvasID: receipt.canvasID,
            runID: receipt.runID,
            graphRevision: receipt.graphRevision,
            nodeID: receipt.nodeID,
            nodeRevision: receipt.nodeRevision,
            taskID: receipt.taskID,
            version: receipt.version + 1,
            localPath: receipt.localPath,
            checksum: receipt.checksum,
            createdAt: receipt.createdAt,
            updatedAt: receipt.updatedAt,
            isDeleted: true,
            fileIdentity: receipt.fileIdentity,
            origin: receipt.origin,
            terminalState: receipt.terminalState,
            targetPath: receipt.targetPath,
            lineage: receipt.lineage,
            rollback: receipt.rollback ?? ArtifactRollbackMetadata(
                previousArtifactID: receipt.id,
                previousChecksum: receipt.checksum,
                previousTargetPath: receipt.targetPath,
                reason: "用户删除 artifact 后保留可恢复元数据",
                recordedAt: Date()
            )
        )
        var nextReceipts = receipts
        nextReceipts[id] = receipt
        do {
            try persist(nextReceipts)
            receipts = nextReceipts
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func restore(id: String) -> Bool {
        guard diagnosticsValue.isHealthy else { return false }
        guard var receipt = receipts[id], receipt.isDeleted else { return false }
        guard let target = try? validatedTargetURL(for: receipt),
              let currentData = try? readRegularFile(at: target),
              Self.sha256Hex(data: currentData) == receipt.checksum else {
            return false
        }
        receipt.isDeleted = false
        receipt.updatedAt = Date()
        receipt = ArtifactReceipt(
            id: receipt.id,
            canvasID: receipt.canvasID,
            runID: receipt.runID,
            graphRevision: receipt.graphRevision,
            nodeID: receipt.nodeID,
            nodeRevision: receipt.nodeRevision,
            taskID: receipt.taskID,
            version: receipt.version + 1,
            localPath: receipt.localPath,
            checksum: receipt.checksum,
            createdAt: receipt.createdAt,
            updatedAt: receipt.updatedAt,
            isDeleted: false,
            fileIdentity: receipt.fileIdentity,
            origin: receipt.origin,
            terminalState: receipt.terminalState,
            targetPath: receipt.targetPath,
            lineage: receipt.lineage,
            rollback: receipt.rollback
        )
        var nextReceipts = receipts
        nextReceipts[id] = receipt
        do {
            try persist(nextReceipts)
            receipts = nextReceipts
            return true
        } catch {
            return false
        }
    }

    /// Roll back a receipt created by the current coordinator transaction.
    /// Existing/deleted receipts are never removed through this path.
    @discardableResult
    func discardNewReceipt(id: String) -> Bool {
        guard diagnosticsValue.isHealthy else { return false }
        guard let receipt = receipts[id], !receipt.isDeleted, receipt.version == 1 else { return false }
        var nextReceipts = receipts
        nextReceipts[id] = nil
        do {
            try persist(nextReceipts)
            receipts = nextReceipts
            return true
        } catch {
            return false
        }
    }

    private func validatedMediaURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard url == resolved else { throw ArtifactStoreError.symlinkRejected }
        guard Self.isWithin(url, root: allowedMediaRoot) else {
            throw ArtifactStoreError.pathOutsideDirectory
        }
        return url
    }

    private func fileIdentity(for url: URL) throws -> ArtifactFileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ArtifactStoreError.missingFile }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw ArtifactStoreError.symlinkRejected
            }
            throw ArtifactStoreError.notRegularFile
        }
        return ArtifactFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private func validatedTargetURL(for receipt: ArtifactReceipt) throws -> URL {
        let candidate: URL
        if let relative = receipt.targetPath {
            let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("/"),
                  !trimmed.contains("\\") else { throw ArtifactStoreError.invalidTarget }
            let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
                throw ArtifactStoreError.invalidTarget
            }
            candidate = allowedMediaRoot.appendingPathComponent(trimmed, isDirectory: false)
        } else {
            candidate = URL(fileURLWithPath: receipt.localPath)
        }
        let standardized = candidate.standardizedFileURL
        guard Self.isWithin(standardized, root: allowedMediaRoot) else {
            throw ArtifactStoreError.pathOutsideDirectory
        }
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard standardized == resolved else { throw ArtifactStoreError.symlinkRejected }
        let recorded = try validatedMediaURL(receipt.localPath)
        guard standardized == recorded else { throw ArtifactStoreError.invalidTarget }
        guard let expectedIdentity = receipt.fileIdentity,
              try fileIdentity(for: standardized) == expectedIdentity else {
            throw ArtifactStoreError.identityMismatch
        }
        var info = stat()
        guard lstat(standardized.path, &info) == 0 else { throw ArtifactStoreError.missingFile }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ArtifactStoreError.notRegularFile }
        return standardized
    }

    private func readRegularFile(at url: URL) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ArtifactStoreError.missingFile }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw ArtifactStoreError.symlinkRejected }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ArtifactStoreError.notRegularFile }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ArtifactStoreError.symlinkRejected }
            throw ArtifactStoreError.missingFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw ArtifactStoreError.missingFile
        }
    }

    private func persist(_ snapshotReceipts: [String: ArtifactReceipt]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(
            Snapshot(schemaVersion: Self.schemaVersion, receipts: snapshotReceipts.values.sorted { $0.id < $1.id })
        )
        try data.write(to: fileURL, options: .atomic)
        let readBack = try Data(contentsOf: fileURL)
        guard try Self.decodeSnapshot(readBack) == snapshotReceipts else {
            throw ArtifactStoreError.persistenceFailed
        }
    }

    private static func load(fileURL: URL) -> LoadedSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LoadedSnapshot(
                receipts: [:],
                diagnostics: ArtifactStoreDiagnostics(state: .ready, reason: nil)
            )
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let receipts = try decodeSnapshot(data, requireTrusted: false)
            let trusted = receipts.values.allSatisfy {
                !$0.id.isEmpty && $0.origin != nil && $0.terminalState.isDurableSuccess
            }
            return LoadedSnapshot(
                receipts: receipts,
                diagnostics: ArtifactStoreDiagnostics(
                    state: trusted ? .ready : .recoveryRequired,
                    reason: trusted ? nil : "legacy_or_untrusted_receipt"
                )
            )
        } catch {
            let reason: String
            if let data = try? Data(contentsOf: fileURL),
               let json = try? JSONSerialization.jsonObject(with: data),
               let object = json as? [String: Any],
               let version = object["schemaVersion"] as? NSNumber,
               version.intValue != schemaVersion {
                reason = "version_mismatch"
            } else if (error as? ArtifactStoreError) == .recoveryRequired {
                reason = "identity_or_integrity_mismatch"
            } else {
                reason = "corrupt_snapshot"
            }
            quarantine(fileURL: fileURL)
            return LoadedSnapshot(
                receipts: [:],
                diagnostics: ArtifactStoreDiagnostics(
                    state: .recoveryRequired,
                    reason: reason
                )
            )
        }
    }

    /// Preserve an unreadable/unsupported snapshot for support recovery. The
    /// original path is freed so a future repair can atomically materialize a
    /// new snapshot; the quarantined copy contains only receipt metadata.
    private static func quarantine(fileURL: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantineURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.deletingPathExtension().lastPathComponent).quarantine-\(stamp)-\(UUID().uuidString).json"
        )
        try? FileManager.default.moveItem(at: fileURL, to: quarantineURL)
    }

    private static func decodeSnapshot(
        _ data: Data,
        requireTrusted: Bool = true
    ) throws -> [String: ArtifactReceipt] {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == schemaVersion else {
            throw ArtifactStoreError.recoveryRequired
        }
        let ids = snapshot.receipts.map(\.id)
        guard Set(ids).count == ids.count else { throw ArtifactStoreError.recoveryRequired }
        let receipts = Dictionary(uniqueKeysWithValues: snapshot.receipts.map { ($0.id, $0) })
        guard receipts.allSatisfy({ key, value in
            key == value.id
                && !value.id.isEmpty
                && !value.taskID.isEmpty
                && value.id == artifactID(forTaskID: value.taskID)
                && value.version > 0
        }) else {
            throw ArtifactStoreError.recoveryRequired
        }
        if requireTrusted {
            guard receipts.values.allSatisfy(isTrustedReceipt) else {
                throw ArtifactStoreError.recoveryRequired
            }
        }
        return receipts
    }

    private static func artifactID(for record: VideoTaskRecord) -> String {
        artifactID(forTaskID: record.id)
    }

    private static func artifactID(forTaskID taskID: String) -> String {
        "artifact-\(taskID)"
    }

    private static func isTrustedReceipt(_ receipt: ArtifactReceipt) -> Bool {
        guard receipt.id == artifactID(forTaskID: receipt.taskID),
              receipt.version > 0,
              let origin = receipt.origin,
              receipt.terminalState.isDurableSuccess,
              receipt.fileIdentity != nil,
              let lineage = receipt.lineage else {
            return false
        }
        return !lineage.sourceRevision.isEmpty
            && lineage.producerRevision == producerRevision(
                canvasID: receipt.canvasID,
                runID: receipt.runID,
                graphRevision: receipt.graphRevision,
                nodeID: receipt.nodeID,
                nodeRevision: receipt.nodeRevision,
                providerID: origin.providerID,
                modelID: origin.modelID
            )
            && !lineage.resultRevision.isEmpty
    }

    private static func canonicalIdentity(for receipt: ArtifactReceipt) -> String? {
        guard let lineage = receipt.lineage else { return nil }
        return canonicalIdentity(
            taskID: receipt.taskID,
            identity: CanvasExecutionIdentity(
                canvasID: receipt.canvasID,
                runID: receipt.runID,
                graphRevision: receipt.graphRevision,
                nodeID: receipt.nodeID,
                nodeRevision: receipt.nodeRevision
            ),
            lineage: lineage
        )
    }

    private static func canonicalIdentity(
        taskID: String,
        identity: CanvasExecutionIdentity,
        lineage: ArtifactResultLineage
    ) -> String {
        [
            artifactID(forTaskID: taskID),
            taskID,
            identity.canvasID.uuidString.lowercased(),
            identity.runID.uuidString.lowercased(),
            identity.graphRevision.description,
            identity.nodeID.uuidString.lowercased(),
            identity.nodeRevision.description,
            lineage.sourceArtifactID ?? "",
            lineage.sourceRevision,
            lineage.producerRevision,
            lineage.resultRevision,
        ].joined(separator: "|")
    }

    private static func sameCanvasScope(
        _ receipt: ArtifactReceipt,
        _ identity: CanvasExecutionIdentity
    ) -> Bool {
        receipt.canvasID == identity.canvasID
            && receipt.runID == identity.runID
            && receipt.graphRevision == identity.graphRevision
            && receipt.nodeID == identity.nodeID
            && receipt.nodeRevision == identity.nodeRevision
    }

    private static func origin(for context: MediaTaskContext) -> ArtifactOrigin {
        ArtifactOrigin(
            providerID: context.providerSnapshot.providerID,
            modelID: context.providerSnapshot.modelID,
            configurationFingerprint: context.providerSnapshot.configurationFingerprint,
            promptFingerprint: context.promptFingerprint,
            idempotencyKey: context.idempotencyKey
        )
    }

    private static func producerRevision(for context: MediaTaskContext) -> String {
        producerRevision(
            canvasID: context.identity.canvasID,
            runID: context.identity.runID,
            graphRevision: context.identity.graphRevision,
            nodeID: context.identity.nodeID,
            nodeRevision: context.identity.nodeRevision,
            providerID: context.providerSnapshot.providerID,
            modelID: context.providerSnapshot.modelID
        )
    }

    private static func producerRevision(
        canvasID: UUID,
        runID: UUID,
        graphRevision: Int,
        nodeID: UUID,
        nodeRevision: Int,
        providerID: String,
        modelID: String
    ) -> String {
        [
            canvasID.uuidString.lowercased(),
            runID.uuidString.lowercased(),
            graphRevision.description,
            nodeID.uuidString.lowercased(),
            nodeRevision.description,
            providerID,
            modelID,
        ].joined(separator: "|")
    }

    private static func relativePath(_ url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }

    private static func isWithin(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path == root.standardizedFileURL.path
            || url.standardizedFileURL.path.hasPrefix(rootPath)
    }

    private static func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
