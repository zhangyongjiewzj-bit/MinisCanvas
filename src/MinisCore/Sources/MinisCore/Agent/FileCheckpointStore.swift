import Foundation
import CryptoKit
import Darwin

/// Durable before-images, separate from the bounded in-memory diff ledger.
/// Callers own the shared file mutation lease across begin/effect/commit and
/// across restore. Commands are deliberately absent from Operation.
public final class FileCheckpointStore: @unchecked Sendable {
    public enum Operation: String, Codable, Sendable { case write, edit, delete }
    public enum Failure: Error, LocalizedError {
        case outsideRoot, sensitiveFile, unsafeFile, changed, expired, oversized, invalidRecord
        public var errorDescription: String? {
            switch self {
            case .outsideRoot: return "检查点路径不在当前授权目录中，请检查当前文件。"
            case .sensitiveFile: return "敏感文件不能保存检查点；本次文件改动未执行。"
            case .unsafeFile: return "检查点仅支持授权目录中的普通文件，本次未改动文件。"
            case .changed: return "文件已变化，旧检查点未覆盖当前文件，请重新检查。"
            case .expired: return "检查点已超过30天，未恢复。"
            case .oversized: return "检查点单文件或对话快照上限为16 MiB，请检查当前文件与操作结果。"
            case .invalidRecord: return "检查点无效或属于其他会话，未恢复。"
            }
        }
    }
    public struct Record: Codable, Sendable, Identifiable {
        public let id: UUID
        public let createdAt: Date
        public let sessionID: String
        /// A verified runtime backlink, never substituted for producer identity.
        public let parentSessionID: String?
        public var childTaskID: String? = nil
        public let path: String
        public let operation: Operation
        public let before: Data?
        public let expectedAfterHash: String?
        public fileprivate(set) var conversation: Data?
        public var committed: Bool
        public var deletionReview: ChildDeletionReviewRecord?
    }
    public struct DeletionBackupMetadata: Equatable, Sendable {
        public let checkpointID: UUID
        public let byteCount: Int
        public let beforeHash: String
        fileprivate init(checkpointID: UUID, byteCount: Int, beforeHash: String) {
            self.checkpointID = checkpointID; self.byteCount = byteCount; self.beforeHash = beforeHash
        }
    }
    /// This is called under the shared mutation lease before classification
    /// and again after it returns. The result proves a readable durable before
    /// image of this exact current file, without exposing content to the model.
    public func verifiedDeletionBackup(_ id: UUID, path: URL, sessionID: String,
        now: Date = Date()) throws -> DeletionBackupMetadata {
        try synchronized {
            let record = try load(id, now: now)
            let url = try checkedURL(path)
            guard record.operation == .delete, !record.committed,
                  record.path == url.path, record.sessionID == sessionID,
                  let before = record.before, try bytes(at: url) == before else { throw Failure.changed }
            return DeletionBackupMetadata(checkpointID: id, byteCount: before.count, beforeHash: Self.hash(before))
        }
    }

    public struct Summary: Identifiable, Sendable {
        public let id: UUID
        public let path: String
        public let createdAt: Date
        public let hasConversation: Bool
        public let producerSessionID: String
        public var childTaskID: String? = nil
    }
    public func summaries(sessionID: String, now: Date = Date()) throws -> [Summary] {
        try synchronized {
            try prune(now: now)
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .compactMap { url -> Summary? in
                    guard url.pathExtension == "json",
                          let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                          let record = try? load(id, now: now),
                          (record.sessionID == sessionID || record.parentSessionID == sessionID),
                          record.committed else { return nil }
                    return Summary(id: id, path: record.path, createdAt: record.createdAt,
                        hasConversation: record.conversation != nil && (record.parentSessionID == nil || record.parentSessionID == sessionID),
                        producerSessionID: record.sessionID, childTaskID: record.childTaskID)
                }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    /// Review a child independently while retaining the existing verified
    /// producer/parent session check in summaries and restore.
    public func summaries(sessionID: String, childTaskID: String, now: Date = Date()) throws -> [Summary] {
        try summaries(sessionID: sessionID, now: now).filter { $0.childTaskID == childTaskID }
    }

    /// Caller owns the shared mutation lease and human authorization for each
    /// target. Stop at the first conflict; never overwrite a newer file.
    @discardableResult
    public func restoreChildTask(_ childTaskID: String, sessionID: String, now: Date = Date()) throws -> [UUID] {
        var restored: [UUID] = []
        for summary in try summaries(sessionID: sessionID, childTaskID: childTaskID, now: now) {
            _ = try restore(summary.id, sessionID: sessionID, now: now, expectedPath: summary.path)
            restored.append(summary.id)
        }
        return restored
    }

    public static let retentionDays = 30
    public static let scopeDisclosure = "仅包含写入、编辑、删除文件工具的改动；命令行改动不在恢复范围。"
    private let directory: URL
    private let allowedRoots: @Sendable () -> [URL]
    private let deniedRoots: [URL]
    private let lock = NSRecursiveLock()
    private let maxFileBytes = 16 * 1024 * 1024

    public init(directory: URL, allowedRoots: [URL], deniedRoots: [URL] = [],
                allowedRootsProvider: (@Sendable () -> [URL])? = nil) throws {
        guard directory.isFileURL else { throw Failure.unsafeFile }
        // Guard the nearest existing ancestor before creating anything, so a
        // linked parent never gets a directory created through it.
        var ancestor = directory.standardizedFileURL
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw Failure.unsafeFile }
            ancestor = parent
        }
        let existingAncestor = ancestor.standardizedFileURL
        guard existingAncestor.path == existingAncestor.resolvingSymlinksInPath().path else {
            throw Failure.unsafeFile
        }
        // Then create before standardizing the store itself: Foundation folds
        // `/private/{var,tmp,etc}` to the `/var…` spelling only for paths that
        // exist, so a missing store kept `/private/var…` and every later load()
        // failed the symlink check after the file side effect had happened.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        self.directory = directory.standardizedFileURL
        let initialRoots = allowedRoots.map { $0.standardizedFileURL }
        self.allowedRoots = allowedRootsProvider ?? { initialRoots }
        self.deniedRoots = deniedRoots.map { $0.standardizedFileURL }
        guard self.directory.path == self.directory.resolvingSymlinksInPath().path else { throw Failure.unsafeFile }
    }
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func checkedURL(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL
        guard path.isFileURL, path == path.resolvingSymlinksInPath(),
              (BypassOpenScope.isActive || allowedRoots().contains(where: { root in
                  root == root.resolvingSymlinksInPath()
                    && path.path.hasPrefix(root.path + "/")
              })), !path.path.hasPrefix(directory.path + "/"), path != directory else { throw Failure.outsideRoot }
        guard !deniedRoots.contains(where: {
            if BypassOpenScope.isActive, BypassAppDataFloor.isGenericApplicationSupportRoot($0.path) { return false }
            return path == $0 || path.path.hasPrefix($0.path + "/")
        }) else {
            throw Failure.outsideRoot
        }
        if BypassOpenScope.isActive {
            guard BypassSystemFloor.violation(path: path.path, operation: .modify) == nil,
                  BypassAppDataFloor.violation(path: path.path, access: .modify) == nil,
                  SensitiveFilePolicy.credentialDenial(for: path.path, forWrite: true) == nil
            else { throw Failure.outsideRoot }
        }
        guard !SensitiveFilePolicy.isSensitive(path) else { throw Failure.sensitiveFile }
        if FileManager.default.fileExists(atPath: path.path) {
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.unsafeFile }
            guard (values.fileSize ?? Int.max) <= maxFileBytes else { throw Failure.oversized }
        }
        return path
    }
    private func bytes(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileBytes else { throw Failure.oversized }
        return data
    }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func save(_ record: Record) throws {
        try JSONEncoder().encode(record).write(to: file(record.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(record.id).path)
    }
    private func load(_ id: UUID, now: Date) throws -> Record {
        let url = file(id)
        guard url == url.resolvingSymlinksInPath() else { throw Failure.unsafeFile }
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileBytes * 3 else { throw Failure.oversized }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.id == id, !record.sessionID.isEmpty else { throw Failure.invalidRecord }
        guard now.timeIntervalSince(record.createdAt) >= 0,
              now.timeIntervalSince(record.createdAt) < Double(Self.retentionDays * 86400) else { throw Failure.expired }
        return record
    }
    /// `expectedAfter` is the exact full bytes, nil only for deletion. Before
    /// images become durable BEFORE the file tool's first mutation.
    @discardableResult public func begin(path: URL, sessionID: String, operation: Operation,
        expectedAfter: Data?, conversation: Data? = nil, parentSessionID: String? = nil, now: Date = Date()) throws -> UUID {
        try synchronized {
            guard !sessionID.isEmpty, parentSessionID != sessionID,
                  parentSessionID?.isEmpty != true, (operation == .delete) == (expectedAfter == nil) else { throw Failure.invalidRecord }
            guard (expectedAfter?.count ?? 0) <= maxFileBytes,
                  (conversation?.count ?? 0) <= maxFileBytes else { throw Failure.oversized }
            let url = try checkedURL(path)
            let before = try bytes(at: url)
            if operation != .write && before == nil { throw Failure.unsafeFile }
            let record = Record(id: UUID(), createdAt: now, sessionID: sessionID, parentSessionID: parentSessionID,
                childTaskID: ChildFileChangeOwnership.taskID(sessionID: sessionID, parentSessionID: parentSessionID), path: url.path,
                operation: operation, before: before, expectedAfterHash: expectedAfter.map(Self.hash),
                conversation: conversation, committed: false, deletionReview: nil)
            try save(record)
            // Fail closed before the caller mutates the file: a record that
            // cannot be read back could never be committed or restored.
            _ = try load(record.id, now: now)
            return record.id
        }
    }
    /// Metadata on the same durable before-image, never a deletion grant.
    public func recordDeletionReview(_ review: ChildDeletionReviewRecord, now: Date = Date()) throws {
        try synchronized {
            guard let id = review.checkpointID else { throw Failure.invalidRecord }
            var record = try load(id, now: now)
            _ = try verifiedDeletionBackup(id, path: URL(fileURLWithPath: record.path),
                sessionID: record.sessionID, now: now)
            record.deletionReview = review
            try save(record)
        }
    }

    public func commit(_ id: UUID, now: Date = Date()) throws {
        try synchronized {
            var record = try load(id, now: now)
            let url = try checkedURL(URL(fileURLWithPath: record.path))
            guard try bytes(at: url).map(Self.hash) == record.expectedAfterHash else { throw Failure.changed }
            record.committed = true
            try save(record)
        }
    }
    /// The caller reauthorizes and acquires the same file mutation lock before
    /// invoking this method. Hash mismatch refuses without touching the file.
    /// `sessionID` is the requesting conversation. A producer or its persisted
    /// verified parent may restore; unrelated siblings never inherit access.
    /// Conversation bytes are returned only after file restore succeeds.
    public func restore(_ id: UUID, sessionID: String, now: Date = Date(), expectedPath: String? = nil) throws -> Data? {
        try synchronized {
            let record = try load(id, now: now)
            guard record.committed, record.sessionID == sessionID || record.parentSessionID == sessionID else { throw Failure.invalidRecord }
            if let expectedPath, record.path != expectedPath { throw Failure.invalidRecord }
            let url = try checkedURL(URL(fileURLWithPath: record.path))
            guard try bytes(at: url).map(Self.hash) == record.expectedAfterHash else { throw Failure.changed }
            if let before = record.before {
                try before.write(to: url, options: .atomic)
            } else {
                guard record.operation == .write else { throw Failure.invalidRecord }
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            // File restoration has succeeded. A failed cleanup must not be
            // misreported as an unchanged file; a later retry rechecks hashes.
            try? FileManager.default.removeItem(at: file(id))
            return record.conversation
        }
    }
    /// Remove conversation snapshots while retaining the independent file
    /// before-images. Never resolves or opens the user workspace paths.
    func ownsDirectory(_ url: URL) -> Bool {
        directory == url.standardizedFileURL
    }

    func clearConversationSnapshots(sessionIDs: Set<String>) throws {
        try synchronized {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            for entry in files where entry.pathExtension == "json" {
                let url = directory.appendingPathComponent(entry.lastPathComponent)
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      url == file(id), url == url.resolvingSymlinksInPath() else { continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink == false,
                      let size = values.fileSize, size <= maxFileBytes * 3 else { continue }
                let data = try Data(contentsOf: url)
                // Parent linkage grants recovery visibility, but the record's
                // conversation belongs to the exact session that created it.
                guard var record = try? JSONDecoder().decode(Record.self, from: data),
                      record.id == id, sessionIDs.contains(record.sessionID) else { continue }
                if record.conversation != nil {
                    record.conversation = nil
                    try save(record)
                }
                // A retry may see the rewrite before it has reached disk.
                try syncScrub(at: url, flags: O_RDONLY)
            }
            try syncScrub(at: directory, flags: O_RDONLY | O_DIRECTORY)
        }
    }

    private func syncScrub(at url: URL, flags: Int32) throws {
        let descriptor = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Prune only our UUID JSON records. Unrelated files are never removed.
    public func prune(now: Date = Date()) throws {
        try synchronized {
            for entry in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                let url = directory.appendingPathComponent(entry.lastPathComponent)
                guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      url == url.resolvingSymlinksInPath(),
                      let bytes = try? Data(contentsOf: url), bytes.count <= maxFileBytes * 3,
                      let record = try? JSONDecoder().decode(Record.self, from: bytes),
                      now.timeIntervalSince(record.createdAt) >= Double(Self.retentionDays * 86400) else { continue }
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// Captured by the App before the turn. Child tasks inherit the same parent
/// snapshot; no store rereads unrelated conversations or keys.
public enum FileCheckpointConversationContext {
    @TaskLocal public static var current: Data?
}
