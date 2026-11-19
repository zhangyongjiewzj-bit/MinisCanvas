import Foundation
import CryptoKit
import Darwin

// MARK: - P3-OUTPUT-01 逐文件变更台账（生产者半）
//
// 本文件只提供 MinisCore 侧的「改动登记 + 逐文件差异载荷」生产者，
// 不 import 任何 App 模块类型，也不声明与 244B
// `AgentOutputDiffReference` / `AgentOutputDiffResolver` 同名的类型。
//
// 与 244B 消费端四字段（`diffID`、`changedFileCount`、`insertions`、
// `deletions`）的投影映射见 `FileChangeLedger.diffReference(for:sessionID:)`：
// App 侧适配器（下一条线，随 BATCH1 入头后接线）把一次工具调用产生的
// 台账记录按同一 `diffID` 聚合成那四个字段即可，本线不落地 App 类型。

/// Captured at the verified target-workspace dispatch, independently of the
/// tool attempt identity. A source session is not the file-producing session.
public struct TaskFileArtifactBinding: Codable, Sendable, Equatable, Hashable {
    public let taskID: String
    public let parentID: String
    public let runID: String
    public let attemptID: String
    public let sourceSessionID: String
    public let producerSessionID: String
    public let workingDirectory: String
    /// Native grant captured by the App at mint, never session/model metadata.
    /// Historical creation records retain their original creation authority.
    public let projectID: String?

    public init(taskID: String, parentID: String, runID: String, attemptID: String,
                sourceSessionID: String, producerSessionID: String, workingDirectory: String,
                projectID: String? = nil) {
        self.taskID = taskID; self.parentID = parentID
        self.runID = runID; self.attemptID = attemptID
        self.sourceSessionID = sourceSessionID; self.producerSessionID = producerSessionID
        self.workingDirectory = workingDirectory
        self.projectID = projectID
    }

    public var isValid: Bool {
        ![taskID, parentID, runID, attemptID, sourceSessionID, producerSessionID]
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && workingDirectory.hasPrefix("/")
            && URL(fileURLWithPath: workingDirectory).standardizedFileURL.path == workingDirectory
    }
}

/// 一次文件改动的台账记录：`file_write`、`file_edit`、`file_delete`
/// 成功后登记的逐文件条目。
public struct FileChangeRecord: Codable, Sendable, Equatable {
    /// `deleted` 既可由旧的内容清空写入产生，也可由物理 file_delete 产生。
    public enum Kind: String, Codable, Sendable, Equatable {
        case created
        case modified
        case deleted
    }

    /// 稳定变更标识：由路径与写后内容确定性派生，不含随机量。
    public let changeID: String
    /// 相对工作区根的路径（standardize 后仍落在根内，越界已被拒绝）。
    public let path: String
    /// Physical root captured when this record was produced. Nil is the old
    /// schema, interpreted against its ledger's original workspaceRoot.
    public let workspaceRoot: String?
    public let kind: Kind
    /// 差异台账键。同一 session + 同一 changeID 必得同一 diffID。
    public let diffID: String
    public let insertions: Int
    public let deletions: Int
    public let timestamp: Date
    /// 台账的会话隔离键：跨 sessionID 查询不得命中彼此记录。
    public let sessionID: String
    public let childTaskID: String?
    /// Absent for old records and writes outside a canonical tool attempt.
    /// The terminal fact is checked separately before showing an artifact.
    public let producerReceiptID: String?
    public let producerCompositeKey: ToolExecutionCompositeKey?
    /// SHA-256 of the complete UTF-8 bytes supplied to the successful write
    /// seam. It is absent for appends, whose full output can race another writer.
    public let outputSHA256: String?
    /// SHA-256 of the exact old bytes read from the fd before physical deletion.
    /// Nil for writes/edits and legacy records; it does not describe an output artifact.
    public let deletedContentSHA256: String?
    public let taskArtifactBinding: TaskFileArtifactBinding?

    public init(
        changeID: String,
        path: String,
        kind: Kind,
        diffID: String,
        insertions: Int,
        deletions: Int,
        timestamp: Date,
        sessionID: String,
        producerReceiptID: String? = nil,
        producerCompositeKey: ToolExecutionCompositeKey? = nil,
        outputSHA256: String? = nil,
        deletedContentSHA256: String? = nil,
        taskArtifactBinding: TaskFileArtifactBinding? = nil,
        workspaceRoot: String? = nil,
        childTaskID: String? = nil
    ) {
        self.childTaskID = childTaskID
        self.workspaceRoot = workspaceRoot
        self.changeID = changeID
        self.path = path
        self.kind = kind
        self.diffID = diffID
        self.insertions = insertions
        self.deletions = deletions
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.producerReceiptID = producerReceiptID
        self.producerCompositeKey = producerCompositeKey
        self.outputSHA256 = outputSHA256
        self.deletedContentSHA256 = deletedContentSHA256
        self.taskArtifactBinding = taskArtifactBinding
    }
}

/// Evidence for bytes produced by one ordinary Chat file tool attempt.
/// This describes the write at production time, not the file's current state.
public struct ProducedFileArtifactEvidence: Sendable, Equatable {
    public enum NextStep: Sendable, Equatable {
        case reviewDiff
    }

    public let diffID: String
    public let path: String
    public let outputSHA256: String
    public let producerReceiptID: String
    public let producerAttemptID: String
    public let producerToolCallID: String
    public let producerToolName: String
    public let status: ToolExecutionStatus
    public let nextStep: NextStep

    public init(diffID: String, path: String, outputSHA256: String, producerReceiptID: String,
                producerAttemptID: String, producerToolCallID: String, producerToolName: String,
                status: ToolExecutionStatus, nextStep: NextStep) {
        self.diffID = diffID
        self.path = path
        self.outputSHA256 = outputSHA256
        self.producerReceiptID = producerReceiptID
        self.producerAttemptID = producerAttemptID
        self.producerToolCallID = producerToolCallID
        self.producerToolName = producerToolName
        self.status = status
        self.nextStep = nextStep
    }
}

/// 同一 `diffID` 下的逐文件差异正文。正文复用现有 `DiffRenderer` 的
/// unified+hunk 视图产出，不复制新的 diff 算法。
public struct FileChangeDiffPayload: Codable, Sendable, Equatable {
    public let diffID: String
    /// 相对工作区根的路径，与记录一致。
    public let path: String
    /// `DiffRenderer.renderUnifiedWithHeaders` 的产出（含 `@@` hunk 头）。
    public let unifiedDiff: String
    public let insertions: Int
    public let deletions: Int

    public init(
        diffID: String,
        path: String,
        unifiedDiff: String,
        insertions: Int,
        deletions: Int
    ) {
        self.diffID = diffID
        self.path = path
        self.unifiedDiff = unifiedDiff
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// 按 diffID 汇总的引用统计——与 244B `AgentOutputDiffReference` 的
/// 四字段一一对应（该类型归 App 模块所有，此处仅声明投影载体，
/// 名称与字段布局不与其冲突）。
public struct FileChangeDiffReferenceView: Codable, Sendable, Equatable {
    public let diffID: String
    /// 同一 diffID（一次工具调用）下改动的文件数。
    public let changedFileCount: Int
    public let insertions: Int
    public let deletions: Int

    public init(diffID: String, changedFileCount: Int, insertions: Int, deletions: Int) {
        self.diffID = diffID
        self.changedFileCount = changedFileCount
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// 有界、按会话隔离的逐文件变更台账。
///
/// 并发模型：`NSLock` 保护的普通 final class，Swift 6 严格并发下以
/// `@unchecked Sendable` 声明——所有可变状态都在锁内访问，无逃逸引用。
/// 选择同步锁而非 actor：登记点在 `runFileWrite` / `runFileEdit` 的同步
/// 写入口，避免为登记把整条工具执行链改成 async 造成无关重构。
public final class FileChangeLedger: @unchecked Sendable {

    /// 登记被拒绝的原因。边界语义与 244B 消费端对齐：
    /// `.outOfBounds` = 路径逃逸工作区根；台账缺 ID 的查询返回 nil，
    /// 由消费端映射为其自身的 `.missing`。
    public enum RegistrationError: Error, Equatable, Sendable {
        case outOfBounds(String)
        case persistenceUnavailable
        case invalidPersistedMetadata
        case stalePersistenceGeneration
    }

    /// 工作区根（绝对、standardized）。
    public let workspaceRoot: String
    private let recordingRoots: @Sendable () -> [URL]
    /// 容量上界。why：diff 正文随 Agent 写盘量线性增长，无界台账会让长
    /// 会话内存不受控；淘汰采用明确 FIFO（按登记顺序丢最旧），保证行为
    /// 可测、可复现，不做隐式 LRU。
    public let capacity: Int

    fileprivate struct Slot {
        let record: FileChangeRecord
        // Restored metadata never manufactures a missing historical diff body.
        let payload: FileChangeDiffPayload?
    }

    /// A physical delete may be rolled back if the final unlink fails. Keep
    /// the exact displaced slot so an earlier diff for the same path survives.
    struct RegistrationUndo {
        fileprivate let registered: FileChangeRecord
        fileprivate let displaced: Slot?
        fileprivate let evicted: Slot?
    }

    private let lock = NSLock()
    private var slots: [Slot] = []
    private var indexByID: [String: Int] = [:]  // "sessionID\u{1}diffID" -> slots 下标（淘汰后整体重建）

    private struct MetadataState: Codable {
        let version: Int
        let generation: UInt64
        let records: [FileChangeRecord]
    }
    private struct DirectoryIdentity {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
        func matches(_ value: stat) -> Bool { device == value.st_dev && inode == value.st_ino }
    }
    private struct MetadataPersistence {
        let parent: URL
        let directoryName: String
        let parentIdentity: DirectoryIdentity
        let directoryIdentity: DirectoryIdentity
        var generation: UInt64
    }
    private var metadataPersistence: MetadataPersistence?
    private var metadataDomain: PersistenceTransactionFence.Domain?
    private var metadataUnavailable = false
    private var protectedMetadataDirectory: URL?

    deinit {
        if let protectedMetadataDirectory {
            SensitiveFilePolicy.unprotectStatePath(protectedMetadataDirectory, isDirectory: true)
        }
    }
    /// A failed opt-in attachment or write must not look like an empty artifact set.
    public var artifactPersistenceUnavailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return metadataUnavailable
    }
    private static let metadataByteLimit = 8 * 1024 * 1024

    /// Opt-in on the existing ledger, before it is given to any executor.
    /// Only App-authored metadata is stored; provider text and diff bodies are not.
    public func attachPersistence(directory: URL,
                                  resolveDirectory: (URL) throws -> URL = { $0 }) throws {
        do {
            let directory = try resolveDirectory(directory)
            // Preserve the caller's physical spelling: Foundation standardization
            // maps existing /private/var back to its /var symlink alias.
            let parent = directory.deletingLastPathComponent()
            guard directory.isFileURL, directory.relativePath.hasPrefix("/"),
                  !directory.relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  directory.lastPathComponent != ".", directory.lastPathComponent != ".." else {
                throw RegistrationError.persistenceUnavailable
            }
            // Foundation may render a resolved Darwin system alias using /var.
            // POSIX realpath supplies the physical spelling used by the fd anchors.
            guard let physicalParent = realpath(parent.path, nil) else {
                throw RegistrationError.persistenceUnavailable
            }
            defer { free(physicalParent) }
            guard parent.path == String(cString: physicalParent) else {
                throw RegistrationError.persistenceUnavailable
            }
            try PersistenceTransactionFence.withWrite([.sessions(parent)]) {
                lock.lock()
                defer { lock.unlock() }
                guard metadataPersistence == nil, protectedMetadataDirectory == nil, slots.isEmpty else {
                    throw RegistrationError.persistenceUnavailable
                }
                metadataUnavailable = true
                let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parentFD >= 0 else { throw RegistrationError.persistenceUnavailable }
                defer { close(parentFD) }
                let parentStat = try Self.directoryStat(parentFD, mode: nil)
                if mkdirat(parentFD, directory.lastPathComponent, 0o700) != 0, errno != EEXIST {
                    throw RegistrationError.persistenceUnavailable
                }
                let directoryFD = openat(parentFD, directory.lastPathComponent,
                                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directoryFD >= 0 else { throw RegistrationError.persistenceUnavailable }
                defer { close(directoryFD) }
                let directoryStat = try Self.directoryStat(directoryFD, mode: 0o700)
                SensitiveFilePolicy.protectStatePath(directory, isDirectory: true)
                protectedMetadataDirectory = directory
                var persistence = MetadataPersistence(parent: parent, directoryName: directory.lastPathComponent,
                    parentIdentity: DirectoryIdentity(parentStat), directoryIdentity: DirectoryIdentity(directoryStat),
                    generation: 0)
                let restored = try Self.withMetadataLock(persistence) { fd -> MetadataState? in
                    try Self.readMetadata(fd)
                }
                if let restored {
                    guard restored.records.count <= capacity else { throw RegistrationError.invalidPersistedMetadata }
                    persistence.generation = restored.generation
                    slots = restored.records.map { Slot(record: $0, payload: nil) }
                    rebuildIndexLocked()
                }
                metadataPersistence = persistence
                metadataDomain = .sessions(parent)
                metadataUnavailable = false
            }
        } catch {
            lock.lock()
            metadataUnavailable = true
            lock.unlock()
            throw error
        }
    }

    private func withMetadataAdmission<T>(_ operation: () throws -> T) throws -> T {
        if let metadataDomain { return try PersistenceTransactionFence.withWrite([metadataDomain], operation) }
        return try operation()
    }

    private static func directoryStat(_ fd: Int32, mode: mode_t?) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == geteuid(), mode.map({ value.st_mode & 0o7777 == $0 }) ?? true else {
            throw RegistrationError.persistenceUnavailable
        }
        return value
    }
    private static func regularStat(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == geteuid(), value.st_nlink == 1, value.st_mode & 0o7777 == 0o600 else {
            throw RegistrationError.persistenceUnavailable
        }
        return value
    }
    private static func withMetadataLock<T>(_ persistence: MetadataPersistence,
                                            _ operation: (Int32) throws -> T) throws -> T {
        let parentFD = open(persistence.parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw RegistrationError.persistenceUnavailable }
        defer { close(parentFD) }
        guard persistence.parentIdentity.matches(try directoryStat(parentFD, mode: nil)) else {
            throw RegistrationError.persistenceUnavailable
        }
        let fd = openat(parentFD, persistence.directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RegistrationError.persistenceUnavailable }
        defer { close(fd) }
        guard persistence.directoryIdentity.matches(try directoryStat(fd, mode: 0o700)) else {
            throw RegistrationError.persistenceUnavailable
        }
        let lockFD = openat(fd, "metadata.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw RegistrationError.persistenceUnavailable }
        defer { close(lockFD) }
        let lockIdentity = try regularStat(lockFD)
        guard flock(lockFD, LOCK_EX) == 0 else { throw RegistrationError.persistenceUnavailable }
        defer { _ = flock(lockFD, LOCK_UN) }
        func validateAnchors() throws {
            var current = stat()
            guard fstatat(fd, "metadata.lock", &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == lockIdentity.st_dev, current.st_ino == lockIdentity.st_ino,
                  current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                  current.st_uid == geteuid(), current.st_mode & 0o7777 == 0o600,
                  fstatat(parentFD, persistence.directoryName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  persistence.directoryIdentity.matches(current),
                  lstat(persistence.parent.path, &current) == 0,
                  persistence.parentIdentity.matches(current) else {
                throw RegistrationError.persistenceUnavailable
            }
        }
        try validateAnchors()
        let result = try operation(fd)
        try validateAnchors()
        return result
    }
    private static func canonicalJSON(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
    }
    private static func readMetadata(_ fd: Int32) throws -> MetadataState? {
        let input = openat(fd, "metadata.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if input < 0 {
            if errno == ENOENT { return nil }
            throw RegistrationError.persistenceUnavailable
        }
        defer { close(input) }
        let before = try regularStat(input)
        guard before.st_size >= 0, before.st_size <= metadataByteLimit else {
            throw RegistrationError.invalidPersistedMetadata
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= metadataByteLimit else {
                throw RegistrationError.persistenceUnavailable
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let after = try regularStat(input)
        var named = stat()
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, data.count == Int(after.st_size),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              fstatat(fd, "metadata.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino else {
            throw RegistrationError.persistenceUnavailable
        }
        let state = try JSONDecoder().decode(MetadataState.self, from: data)
        guard state.version == 1,
              Set(state.records.map { key(sessionID: $0.sessionID, diffID: $0.diffID) }).count == state.records.count,
              try canonicalJSON(data) == canonicalJSON(JSONEncoder().encode(state)),
              state.records.allSatisfy(validMetadataRecord) else {
            throw RegistrationError.invalidPersistedMetadata
        }
        return state
    }
    private static func validMetadataRecord(_ record: FileChangeRecord) -> Bool {
        guard let root = record.workspaceRoot, root.hasPrefix("/"),
              !record.path.isEmpty, !record.path.hasPrefix("/"),
              record.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              record.diffID == stableDiffID(sessionID: record.sessionID, changeID: record.changeID),
              record.insertions >= 0, record.deletions >= 0,
              record.timestamp.timeIntervalSinceReferenceDate.isFinite,
              let receipt = record.producerReceiptID, !receipt.isEmpty,
              let key = record.producerCompositeKey, key.isValid, key.sessionID == record.sessionID,
              record.taskArtifactBinding.map({ $0.isValid && $0.producerSessionID == record.sessionID }) ?? true else { return false }
        let hex = Set("0123456789abcdef")
        return [record.outputSHA256, record.deletedContentSHA256].allSatisfy { digest in
            digest.map { $0.count == 64 && $0.allSatisfy(hex.contains) } ?? true
        }
    }
    private func persistMetadataLocked() throws {
        guard !metadataUnavailable else { throw RegistrationError.persistenceUnavailable }
        guard var persistence = metadataPersistence else { return }
        try Self.withMetadataLock(persistence) { fd in
                let current = try Self.readMetadata(fd)
                guard (current?.generation ?? 0) == persistence.generation else {
                    throw RegistrationError.stalePersistenceGeneration
                }
                guard persistence.generation < UInt64.max else { throw RegistrationError.persistenceUnavailable }
                let records = slots.map(\.record).filter { $0.producerReceiptID != nil }
                guard records.allSatisfy(Self.validMetadataRecord) else { throw RegistrationError.invalidPersistedMetadata }
                let next = MetadataState(version: 1, generation: persistence.generation + 1, records: records)
                let data = try JSONEncoder().encode(next)
                guard data.count <= Self.metadataByteLimit else { throw RegistrationError.persistenceUnavailable }
                let temporary = "metadata-" + UUID().uuidString + ".tmp"
                let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard output >= 0 else { throw RegistrationError.persistenceUnavailable }
                defer { close(output); _ = unlinkat(fd, temporary, 0) }
                _ = try Self.regularStat(output)
                try data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let count = write(output, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw RegistrationError.persistenceUnavailable }
                        offset += count
                    }
                }
                guard fsync(output) == 0 else { throw RegistrationError.persistenceUnavailable }
                // Cooperative writers share this flock and compare the durable
                // generation. Recheck the name just before the atomic replace.
                let rechecked = try Self.readMetadata(fd)
                guard (rechecked?.generation ?? 0) == persistence.generation,
                      renameat(fd, temporary, fd, "metadata.json") == 0,
                      fsync(fd) == 0 else { throw RegistrationError.persistenceUnavailable }
                persistence.generation = next.generation
        }
        metadataPersistence = persistence
    }

    public init(workspaceRoot: String, capacity: Int = 512,
                rootsProvider: (@Sendable () -> [URL])? = nil) {
        self.workspaceRoot = URL(fileURLWithPath: workspaceRoot)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let initialRoot = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        self.recordingRoots = rootsProvider ?? { [initialRoot] }
        self.capacity = max(1, capacity)
    }

    // MARK: - 稳定 diffID

    /// 同一 sessionID + 同一 changeID 必得同一 diffID；不使用随机 UUID，
    /// 保证复跑与测试具备区分度。
    public static func stableDiffID(sessionID: String, changeID: String) -> String {
        "diff-" + fnv1a64Hex("\(sessionID)\u{1}\(changeID)")
    }

    /// changeID 的确定性派生：路径 + 写后内容摘要，不含时钟或随机量。
    public static func stableChangeID(path: String, newContent: String) -> String {
        "chg-" + fnv1a64Hex("\(path)\u{1}\(newContent)")
    }

    /// FNV-1a 64 位：确定性、跨进程可复现、无依赖，避免引入密码学 API。
    static func fnv1a64Hex(_ input: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016x", hash)
    }

    // MARK: - 路径边界

    /// 把 raw 路径解析为「相对工作区根」的路径；绝对路径、`..`、波浪号
    /// 在规范化后仍逃逸根外的都判越界。与 ToolExecutor 一样先拒绝
    /// 词法越界，再对根和目标使用同一物理路径解析。
    public static func confine(relativeToWorkspaceRoot raw: String, workspaceRoot: String) -> String? {
        guard !raw.isEmpty else { return nil }
        // 波浪号（家目录逃逸）与任何 `..` 词法分量先于文件系统访问拒绝。
        if raw.contains("~") || raw.contains("\u{1}") { return nil }
        let components = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.contains("..") { return nil }
        guard let root = PolicyRuntimePathBoundary.canonicalPath(workspaceRoot) else { return nil }
        let candidate: String
        if raw.hasPrefix("/") {
            candidate = raw
        } else {
            candidate = root + "/" + raw
        }
        guard let absolute = PolicyRuntimePathBoundary.canonicalPath(candidate) else { return nil }
        guard absolute == root || absolute.hasPrefix(root + "/") else { return nil }
        guard absolute != root else { return nil }  // 根本身不是一个文件改动路径
        return String(absolute.dropFirst(root.count + 1))
    }

    /// The caller has already admitted this tool effect. Capture one root
    /// from that scope now, so later UI/session selection cannot move it.
    public func recordingRoot(for path: String) -> String? {
        for root in recordingRoots() {
            guard let physical = PolicyRuntimePathBoundary.canonicalPath(root.path),
                  Self.confine(relativeToWorkspaceRoot: path, workspaceRoot: physical) != nil else { continue }
            return physical
        }
        // A confirmed bypass already admitted the effect outside project
        // roots. Recording its physical parent does not authorize another IO.
        if BypassOpenScope.isActive, path.hasPrefix("/"),
           let physical = PolicyRuntimePathBoundary.canonicalPath(path) {
            return URL(fileURLWithPath: physical).deletingLastPathComponent().path
        }
        return nil
    }

    // MARK: - 登记

    /// 登记一次文件改动并生成差异载荷。路径越界 → 拒绝登记（抛
    /// `.outOfBounds`）；内容 → 经现有 `TextDiff`/`DiffRenderer` 产出正文。
    ///
    /// 返回值即写入台账的记录（含稳定 diffID），调用方把 `diffID`
    /// 透传给工具结果。
    @discardableResult
    public func register(
        sessionID: String,
        path rawPath: String,
        kind: FileChangeRecord.Kind,
        oldContent: String?,
        newContent: String?,
        timestamp: Date = Date(),
        producerReceipt: ToolExecutionReceipt? = nil,
        verifiedOutputContent: String? = nil,
        verifiedDeletedContentSHA256: String? = nil,
        taskArtifactBinding: TaskFileArtifactBinding? = nil
    ) throws -> FileChangeRecord {
        try registerWithUndo(
            sessionID: sessionID, path: rawPath, kind: kind,
            oldContent: oldContent, newContent: newContent,
            timestamp: timestamp, producerReceipt: producerReceipt,
            verifiedOutputContent: verifiedOutputContent,
            verifiedDeletedContentSHA256: verifiedDeletedContentSHA256,
            taskArtifactBinding: taskArtifactBinding
        ).record
    }

    func registerWithUndo(
        sessionID: String,
        path rawPath: String,
        kind: FileChangeRecord.Kind,
        oldContent: String?,
        newContent: String?,
        timestamp: Date = Date(),
        producerReceipt: ToolExecutionReceipt? = nil,
        verifiedOutputContent: String? = nil,
        verifiedDeletedContentSHA256: String? = nil,
        taskArtifactBinding: TaskFileArtifactBinding? = nil
    ) throws -> (record: FileChangeRecord, undo: RegistrationUndo) {
        guard let recordRoot = recordingRoot(for: rawPath),
              let relativePath = Self.confine(
            relativeToWorkspaceRoot: rawPath,
            workspaceRoot: recordRoot
        ) else {
            throw RegistrationError.outOfBounds(rawPath)
        }
        let old = oldContent ?? ""
        let new = newContent ?? ""
        let hunks = TextDiff.diff(old: old, new: new)
        let stats = DiffRenderer.changeStats(hunks)
        let fullBody = DiffRenderer.renderUnifiedWithHeaders(hunks)
        let body: String
        if verifiedDeletedContentSHA256 != nil, fullBody.count > 6_000 {
            body = String(fullBody.prefix(6_000)) + "\n…[diff truncated]"
        } else {
            body = fullBody
        }
        let originalRoot = PolicyRuntimePathBoundary.canonicalPath(workspaceRoot) ?? workspaceRoot
        let identityPath = recordRoot == originalRoot ? relativePath : recordRoot + "/" + relativePath
        let childTaskID = ChildFileChangeOwnership.taskID(sessionID: sessionID)
        let ownershipPath = childTaskID.map { $0 + "\u{1}" + identityPath } ?? identityPath
        let changeID = Self.stableChangeID(path: ownershipPath, newContent: new)
        let diffID = Self.stableDiffID(sessionID: sessionID, changeID: changeID)
        let boundReceipt: ToolExecutionReceipt? = {
            guard let producerReceipt,
                  let key = producerReceipt.compositeKey,
                  key.isValid,
                  key.sessionID == sessionID,
                  key.toolCallID == producerReceipt.toolCallID,
                  key.attemptID == producerReceipt.attemptID,
                  key.attemptNumber == producerReceipt.attemptNumber,
                  producerReceipt.toolName == "file_write" || producerReceipt.toolName == "file_edit"
                    || producerReceipt.toolName == "file_delete"
            else { return nil }
            return producerReceipt
        }()
        let outputSHA256 = boundReceipt.flatMap { _ in
            verifiedOutputContent.map { content in
                SHA256.hash(data: Data(content.utf8))
                    .map { String(format: "%02x", $0) }.joined()
            }
        }
        let record = FileChangeRecord(
            changeID: changeID,
            path: relativePath,
            kind: kind,
            diffID: diffID,
            insertions: stats.additions,
            deletions: stats.deletions,
            timestamp: timestamp,
            sessionID: sessionID,
            producerReceiptID: boundReceipt?.receiptID,
            producerCompositeKey: boundReceipt?.compositeKey,
            outputSHA256: outputSHA256,
            deletedContentSHA256: kind == .deleted && verifiedDeletedContentSHA256?.count == 64
                ? verifiedDeletedContentSHA256 : nil,
            taskArtifactBinding: taskArtifactBinding.flatMap { binding in
                binding.isValid && binding.producerSessionID == boundReceipt?.compositeKey?.sessionID
                    ? binding : nil
            },
            workspaceRoot: recordRoot, childTaskID: childTaskID
        )
        let payload = FileChangeDiffPayload(
            diffID: diffID,
            path: relativePath,
            unifiedDiff: body,
            insertions: stats.additions,
            deletions: stats.deletions
        )
        return try withMetadataAdmission {
            lock.lock()
            defer { lock.unlock() }
            guard !metadataUnavailable else { throw RegistrationError.persistenceUnavailable }
            let previous = slots
            let key = Self.key(sessionID: sessionID, diffID: diffID)
            if let existing = indexByID[key] {
                // 同 session + 同 changeID 复登：确定性 ID 相同，覆盖旧条目、
                // 保留其登记顺序位（FIFO 语义不因重写而漂移）。
                let undo = RegistrationUndo(registered: record, displaced: slots[existing], evicted: nil)
                slots[existing] = Slot(record: record, payload: payload)
                do { try persistMetadataLocked() }
                catch { slots = previous; rebuildIndexLocked(); metadataUnavailable = true; throw error }
                return (record, undo)
            }
            let evicted = slots.count >= capacity ? slots.first : nil
            slots.append(Slot(record: record, payload: payload))
            if slots.count > capacity {
                // 明确淘汰规则：容量满 → 丢最旧（FIFO），并整体重建索引。
                let overflow = slots.count - capacity
                slots.removeFirst(overflow)
                rebuildIndexLocked()
            } else {
                indexByID[key] = slots.count - 1
            }
            do { try persistMetadataLocked() }
            catch { slots = previous; rebuildIndexLocked(); metadataUnavailable = true; throw error }
            return (record, RegistrationUndo(registered: record, displaced: nil, evicted: evicted))
        }
    }

    /// Undo only the exact registration produced by this delete. A later
    /// registration with the same diff ID must never be removed by an old IO
    /// failure. Called only when the quarantined file was restored.
    func rollbackRegistration(_ undo: RegistrationUndo) {
        do {
            try withMetadataAdmission {
                lock.lock()
                defer { lock.unlock() }
                let key = Self.key(sessionID: undo.registered.sessionID, diffID: undo.registered.diffID)
                guard let index = indexByID[key], slots[index].record == undo.registered else { return }
                if let displaced = undo.displaced {
                    slots[index] = displaced
                } else {
                    slots.remove(at: index)
                    if let evicted = undo.evicted, slots.count < capacity {
                        slots.insert(evicted, at: 0)
                    }
                }
                rebuildIndexLocked()
                do { try persistMetadataLocked() }
                catch { metadataUnavailable = true }
            }
        } catch {
            lock.lock(); metadataUnavailable = true; lock.unlock()
        }
    }

    // MARK: - 有界查询

    public func records(sessionID: String, childTaskID: String) -> [FileChangeRecord] {
        records(sessionID: sessionID).filter { $0.childTaskID == childTaskID }
    }

    /// 按 diffID + sessionID 查回记录；跨会话或台账无该 ID 返回 nil
    /// （消费端据此映射其 `.missing`）。
    public func record(diffID: String, sessionID: String) -> FileChangeRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard !metadataUnavailable,
              let idx = indexByID[Self.key(sessionID: sessionID, diffID: diffID)] else { return nil }
        let found = slots[idx]
        guard found.record.sessionID == sessionID, found.record.diffID == diffID else { return nil }
        return found.record
    }

    /// Only the exact successful durable fact can turn a write-side record
    /// into artifact evidence. A pending, failed, cancelled, old, or replaced
    /// record remains a diff at most; it is never presented as an artifact.
    public func artifactEvidence(
        diffID: String,
        sessionID: String,
        fact: ToolExecutionFact
    ) -> ProducedFileArtifactEvidence? {
        guard let record = record(diffID: diffID, sessionID: sessionID),
              fact.status == .succeeded,
              fact.toolName == "file_write" || fact.toolName == "file_edit",
              fact.compositeKey?.isValid == true,
              fact.compositeKey?.sessionID == sessionID,
              fact.compositeKey?.toolCallID == fact.toolCallID,
              fact.compositeKey?.attemptID == fact.attemptID,
              fact.compositeKey?.attemptNumber == fact.attemptNumber,
              record.producerReceiptID == fact.receiptID,
              record.producerCompositeKey == fact.compositeKey,
              let digest = record.outputSHA256,
              digest.count == 64 else { return nil }
        return ProducedFileArtifactEvidence(
            diffID: diffID,
            path: record.path,
            outputSHA256: digest,
            producerReceiptID: fact.receiptID,
            producerAttemptID: fact.attemptID,
            producerToolCallID: fact.toolCallID,
            producerToolName: fact.toolName,
            status: fact.status,
            nextStep: .reviewDiff
        )
    }

    /// 按 diffID + sessionID 查回逐文件差异正文；语义同上（nil ≙ missing）。
    public func diffPayload(diffID: String, sessionID: String) -> FileChangeDiffPayload? {
        lock.lock()
        defer { lock.unlock() }
        guard !metadataUnavailable,
              let idx = indexByID[Self.key(sessionID: sessionID, diffID: diffID)] else { return nil }
        let found = slots[idx]
        guard found.record.sessionID == sessionID, found.record.diffID == diffID else { return nil }
        return found.payload
    }

    /// 某会话的全部记录（按登记顺序，受容量上界约束）。
    public func records(sessionID: String) -> [FileChangeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return slots.filter { $0.record.sessionID == sessionID }.map(\.record)
    }

    /// Bounded by this ledger's existing FIFO capacity, with no session-only
    /// join and no filesystem or terminal-fact reconstruction.
    public func records(taskID: String, parentID: String, runID: String, attemptID: String) -> [FileChangeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return slots.compactMap { slot in
            guard let binding = slot.record.taskArtifactBinding,
                  binding.taskID == taskID, binding.parentID == parentID,
                  binding.runID == runID, binding.attemptID == attemptID else { return nil }
            return slot.record
        }
    }

    /// 当前保留条目数（用于容量/淘汰断言）。
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.count
    }

    // MARK: - 对 244B 的四字段投影

    /// 把一个 diffID（= 一次工具调用）下的记录聚合投影为 244B
    /// `AgentOutputDiffReference{diffID, changedFileCount, insertions, deletions}`
    /// 的四字段形态。App 侧适配器（下一条线）直接取用；本线不声明、
    /// 不 import App 类型。无该 ID → nil（消费端 `.missing`）。
    public func diffReference(for diffID: String, sessionID: String) -> FileChangeDiffReferenceView? {
        lock.lock()
        defer { lock.unlock() }
        let matching = slots.filter { $0.record.diffID == diffID && $0.record.sessionID == sessionID }
        guard !matching.isEmpty else { return nil }
        return FileChangeDiffReferenceView(
            diffID: diffID,
            changedFileCount: matching.count,
            insertions: matching.reduce(0) { $0 + $1.record.insertions },
            deletions: matching.reduce(0) { $0 + $1.record.deletions }
        )
    }

    // MARK: - 私有

    private static func key(sessionID: String, diffID: String) -> String {
        "\(sessionID)\u{1}\(diffID)"
    }

    private func rebuildIndexLocked() {
        indexByID.removeAll(keepingCapacity: true)
        for (idx, slot) in slots.enumerated() {
            indexByID[Self.key(sessionID: slot.record.sessionID, diffID: slot.record.diffID)] = idx
        }
    }
}

// MARK: - 命令生成的产物（未经写入验证）

/// shell 命令结束后，只检查命令文本里出现的、带常见产物扩展名的路径：文件存在且修改时间
/// 不早于命令开始时才算“命令生成”。它不是写入证明（命令可能只是读取或触碰了该文件），
/// 因此与台账里“已证实写入”的记录分开显示。除命令文本外，只有界扫描工作目录第一层。
public enum CommandGeneratedArtifacts {
    public static let statusLabel = "命令生成（未经写入验证）"
    public static let maximumCount = 20

    static let artifactExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "pdf", "html", "htm", "md", "txt",
        "csv", "tsv", "json", "xlsx", "xls", "docx", "doc", "pptx", "ppt", "zip", "tar", "gz",
        "mp4", "mov", "m4v", "mkv", "webm", "mp3", "wav", "m4a", "log", "xml", "yaml", "yml"
    ]

    private static let unquoted = try? NSRegularExpression(
        pattern: #"(?:^|[\s=<>(])([^\s"'`<>|;&()]+\.[A-Za-z0-9]{1,5})(?=$|[\s"'`<>|;&)])"#)
    private static let quoted = try? NSRegularExpression(
        pattern: #"["']([^"'\n]+\.[A-Za-z0-9]{1,5})["']"#)

    /// 返回命令文本中出现、存在且 mtime 不早于 `startedAt` 的路径（标准化的绝对路径，去重，最多 `maximumCount` 个）。
    public static func detect(command: String, workingDirectory: URL, startedAt: Date,
                              homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let ns = command as NSString
        let full = NSRange(location: 0, length: ns.length)
        var tokens: [String] = []
        for expression in [quoted, unquoted] {
            guard let expression else { continue }
            for match in expression.matches(in: command, range: full) where match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                if range.location != NSNotFound { tokens.append(ns.substring(with: range)) }
            }
        }
        var seen = Set<String>()
        var result: [String] = []
        // 文件系统时间戳可能只到秒级，留 1 秒容差。
        let threshold = startedAt.addingTimeInterval(-1)
        // `cd 子目录 && …` 之后命令里的相对路径按该目录解析。
        let baseDirectory = leadingCDTarget(command: command, workingDirectory: workingDirectory,
                                            homeDirectory: homeDirectory) ?? workingDirectory
        func admit(_ url: URL) {
            guard result.count < maximumCount,
                  !seen.contains(url.path), !SensitiveFilePolicy.contains(url.path) else { return }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            guard modified >= threshold else { return }
            seen.insert(url.path)
            result.append(url.path)
        }
        for token in tokens {
            guard result.count < maximumCount else { break }
            let ext = (token as NSString).pathExtension.lowercased()
            guard artifactExtensions.contains(ext), !token.contains("$"), !token.contains("*") else { continue }
            let path: String
            if token.hasPrefix("/") { path = token }
            else if token.hasPrefix("~/") { path = homeDirectory.appendingPathComponent(String(token.dropFirst(2))).path }
            else { path = baseDirectory.appendingPathComponent(token).path }
            admit(URL(fileURLWithPath: path).standardizedFileURL)
        }
        // 脚本（如 python3 plot.py）生成的文件不会出现在命令文本里：
        // 再有界扫描工作目录第一层（至多 200 项、跳过隐藏项、只认产物扩展名）。
        var scanned = 0
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: workingDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for entry in entries {
            scanned += 1
            if scanned > scanLimit || result.count >= maximumCount { break }
            let ext = entry.pathExtension.lowercased()
            guard ext != "log", artifactExtensions.contains(ext) else { continue }
            admit(entry.standardizedFileURL)
        }
        return result
    }

    static let scanLimit = 200

    private static let leadingCD = try? NSRegularExpression(
        pattern: #"^\s*cd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))\s*(?:&&|;)"#)

    /// 命令开头的 `cd 目录 &&`（或 `;`）的目标目录；含变量或通配时不解析。
    private static func leadingCDTarget(command: String, workingDirectory: URL, homeDirectory: URL) -> URL? {
        guard let expression = leadingCD else { return nil }
        let ns = command as NSString
        guard let match = expression.firstMatch(in: command, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var target: String?
        for index in 1...3 {
            let range = match.range(at: index)
            if range.location != NSNotFound { target = ns.substring(with: range); break }
        }
        guard let target, !target.contains("$"), !target.contains("*"), !target.contains("`") else { return nil }
        let path: String
        if target.hasPrefix("/") { path = target }
        else if target == "~" { path = homeDirectory.path }
        else if target.hasPrefix("~/") { path = homeDirectory.appendingPathComponent(String(target.dropFirst(2))).path }
        else { path = workingDirectory.appendingPathComponent(target).path }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

/// 按会话保存“命令生成”的产物路径，供界面与子任务汇总读取；只在内存里，不是授权依据。
public final class CommandGeneratedArtifactLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bySession: [String: [String]] = [:]
    public init() {}

    public func record(sessionID: String, paths: [String]) {
        guard !paths.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var list = bySession[sessionID, default: []]
        for path in paths where !list.contains(path) { list.append(path) }
        if list.count > 200 { list.removeFirst(list.count - 200) }
        bySession[sessionID] = list
    }

    public func paths(sessionID: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return bySession[sessionID] ?? []
    }
}
