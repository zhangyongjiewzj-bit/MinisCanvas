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
        /// 目标之后的部分检查点因总量上限已被清理，无法完整回退。
        case historyEvicted
        /// 文件被删除或移走（与内容已变化分开说明）。
        case fileMissing
        /// 当前权限或授权目录不允许恢复这个路径。
        case notAuthorized
        public var errorDescription: String? {
            switch self {
            case .outsideRoot: return "检查点路径不在当前授权目录中，请检查当前文件。"
            case .sensitiveFile: return "敏感文件不能保存检查点；本次文件改动未执行。"
            case .unsafeFile: return "检查点仅支持授权目录中的普通文件，本次未改动文件。"
            case .changed: return "文件已变化，旧检查点未覆盖当前文件，请重新检查。"
            case .expired: return "检查点已超过30天，未恢复。"
            case .oversized: return "文件超过 16 MiB，无法保存检查点，本次未改动文件。可改用命令行处理该文件，或先拆分后再编辑。"
            case .invalidRecord: return "检查点无效或属于其他会话，未恢复。"
            case .historyEvicted: return "检查点占用超过总量上限，部分较新的记录已被清理，无法完整回退到这里；未改动任何文件。可逐个恢复仍保留的检查点。"
            case .fileMissing: return "文件已被删除或移走，无法恢复到旧版本；未改动任何文件。"
            case .notAuthorized: return "当前权限或授权目录不包含该文件，未恢复；请在授权范围内重试。"
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
        /// 这次改动是写入、编辑还是删除，供恢复列表区分同一文件的多条记录。
        public var operation: Operation? = nil
    }
    /// 列表要解码目录里每个记录（含整份旧文件内容与对话快照），界面会反复读取；
    /// 目录没有任何增删改（修改时间不变）且结果不超过一分钟时直接复用。
    private var summaryCache: [String: (stamp: Date, computedAt: Date, items: [Summary])] = [:]
    private func directoryStamp() -> Date? {
        // 不用 URL.resourceValues：URL 对象会缓存读过的值，读到的可能是旧时间。
        (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
    }

    public func summaries(sessionID: String, now: Date = Date()) throws -> [Summary] {
        try synchronized {
            let stamp = directoryStamp()
            if let stamp, let cached = summaryCache[sessionID], cached.stamp == stamp,
               abs(now.timeIntervalSince(cached.computedAt)) < 60 {
                return cached.items
            }
            let items = try computeSummaries(sessionID: sessionID, now: now)
            // prune 可能改了目录，缓存取计算之后的修改时间。
            if let after = directoryStamp() {
                summaryCache[sessionID] = (after, now, items)
            }
            return items
        }
    }

    private func computeSummaries(sessionID: String, now: Date) throws -> [Summary] {
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
                        producerSessionID: record.sessionID, childTaskID: record.childTaskID,
                        operation: record.operation)
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

    /// 检查点目录总量上限；超出时先清理遗留的未提交记录，再清对话快照（文件旧内容保留），
    /// 仍不够才按时间删最旧的已提交文件检查点（并留下清理标记，回退时据此拒绝）。
    public static let totalQuotaBytes = 512 * 1024 * 1024
    /// 未提交记录超过这个时长视为遗留（正常一次改动在几秒内提交）。
    private static let staleUncommittedSeconds: TimeInterval = 3600
    private let quotaBytes: Int

    /// 被总量清理删掉的已提交记录的标记；只记录归属和时间，不含文件内容。
    private struct EvictionMark: Codable {
        let sessionID: String
        let parentSessionID: String?
        let createdAt: Date
    }
    private var evictionMarksURL: URL { directory.appendingPathComponent("evictions.dat") }
    private func loadEvictionMarks(now: Date) -> [EvictionMark] {
        guard let data = try? Data(contentsOf: evictionMarksURL),
              let marks = try? JSONDecoder().decode([EvictionMark].self, from: data) else { return [] }
        return marks.filter { now.timeIntervalSince($0.createdAt) < Double(Self.retentionDays * 86400) }
    }
    private func appendEvictionMarks(_ added: [EvictionMark], now: Date) {
        guard !added.isEmpty else { return }
        let marks = loadEvictionMarks(now: now) + added
        guard let data = try? JSONEncoder().encode(marks) else { return }
        try? data.write(to: evictionMarksURL, options: .atomic)
    }

    /// 尽力而为，不抛错；新记录始终保留。
    private func enforceTotalQuota(keeping keptID: UUID, now: Date) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var items: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for entry in entries where entry.pathExtension == "json" {
            guard UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { continue }
            let size = values.fileSize ?? 0
            total += size
            items.append((entry, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > quotaBytes else { return }
        let ordered = items.sorted(by: { $0.date < $1.date })
        func decoded(_ item: (url: URL, size: Int, date: Date)) -> Record? {
            guard UUID(uuidString: item.url.deletingPathExtension().lastPathComponent) != keptID,
                  // 不能拿 URL 与 resolvingSymlinksInPath 直接比：/var 与 /private/var 的写法差异会让所有记录都被误判成符号链接。
                  (try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
                  let data = try? Data(contentsOf: item.url) else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }
        // 1) 遗留的未提交记录。
        var removed = Set<URL>()
        for item in ordered {
            if total <= quotaBytes { return }
            guard let record = decoded(item), !record.committed,
                  now.timeIntervalSince(record.createdAt) > Self.staleUncommittedSeconds else { continue }
            if (try? FileManager.default.removeItem(at: item.url)) != nil { total -= item.size; removed.insert(item.url) }
        }
        // 2) 对话快照：文件旧内容保留，只去掉对话部分。
        var sizes: [URL: Int] = [:]
        for item in ordered where !removed.contains(item.url) {
            if total <= quotaBytes { return }
            guard var record = decoded(item), record.conversation != nil else { continue }
            record.conversation = nil
            guard (try? save(record)) != nil,
                  // 不用 URL.resourceValues：前面读过的文件大小会被 URL 对象缓存，读到的还是改写前的旧值。
                  let newSize = (try? FileManager.default.attributesOfItem(atPath: item.url.path))?[.size] as? Int
            else { continue }
            total -= max(0, item.size - newSize)
            sizes[item.url] = newSize
        }
        // 3) 仍不够：从最旧的已提交文件检查点删起，并留标记。
        var marks: [EvictionMark] = []
        for item in ordered where !removed.contains(item.url) {
            if total <= quotaBytes { break }
            guard let record = decoded(item), record.committed else { continue }
            if (try? FileManager.default.removeItem(at: item.url)) != nil {
                total -= sizes[item.url] ?? item.size
                marks.append(EvictionMark(sessionID: record.sessionID, parentSessionID: record.parentSessionID,
                                          createdAt: record.createdAt))
            }
        }
        appendEvictionMarks(marks, now: now)
    }

    /// 恢复到某个检查点之前的计划：目标及其之后（同一会话可见范围内）的所有已提交
    /// 记录，按时间从新到旧排列；`paths` 为去重后按路径排序的加锁顺序。
    public struct RewindPlan: Sendable {
        public let summaries: [Summary]
        public let lockOrder: [String]
    }

    public func rewindPlan(before id: UUID, sessionID: String, now: Date = Date()) throws -> RewindPlan {
        let all = try summaries(sessionID: sessionID, now: now)
        guard let target = all.first(where: { $0.id == id }) else { throw Failure.invalidRecord }
        // 目标之后若有记录已被总量清理删掉，回退会漏掉这些改动，直接拒绝。
        if synchronized({ loadEvictionMarks(now: now) }).contains(where: {
            ($0.sessionID == sessionID || $0.parentSessionID == sessionID) && $0.createdAt >= target.createdAt
        }) { throw Failure.historyEvicted }
        let selected = all.filter { $0.createdAt >= target.createdAt }
            .sorted { $0.createdAt > $1.createdAt }
        let paths = Array(Set(selected.map(\.path))).sorted()
        return RewindPlan(summaries: selected, lockOrder: paths)
    }

    /// 回退时发现“检查点之后又被改动或删除”的文件。默认整批不动，错误里列出具体文件。
    public struct RewindConflictError: Error, LocalizedError {
        public enum Reason: Sendable { case changed, missing }
        public struct Item: Sendable {
            public let path: String
            public let reason: Reason
        }
        public let items: [Item]
        public var errorDescription: String? {
            let lines = items.prefix(8).map { item -> String in
                "\(item.path)（\(item.reason == .missing ? "已被删除或移走" : "已被改动")）"
            }.joined(separator: "；")
            let more = items.count > 8 ? "等 \(items.count) 个文件" : ""
            return "有文件在检查点之后又变了，所以一个文件都没有改：\(lines)\(more)。可以先恢复更新的检查点，或选择“先把当前版本存为检查点再覆盖”（覆盖前会保存当前版本，之后还能恢复回来）。"
        }
    }

    /// “先存当前版本再覆盖”写入阶段失败：已覆盖的文件已用备份还原；还原不了的列在这里
    /// （它们的当前版本仍在新存的检查点里，可从检查点恢复）。
    public struct RewindOverwriteFailure: Error, LocalizedError {
        public let failedPath: String
        public let unrestoredPaths: [String]
        public var errorDescription: String? {
            if unrestoredPaths.isEmpty {
                return "覆盖 \(failedPath) 时失败，已把此前覆盖的文件全部还原，没有文件被改动。请检查磁盘空间和文件权限后重试。"
            }
            return "覆盖 \(failedPath) 时失败，且这些文件没能还原：\(unrestoredPaths.prefix(8).joined(separator: "；"))。它们覆盖前的版本已存为新的检查点，可在检查点列表里恢复。"
        }
    }

    /// 普通恢复中途失败，且已恢复的文件没能全部还原：列出仍停在恢复后状态的文件。
    /// 所有检查点都还在，可以再次恢复。
    public struct RewindPartialRestoreFailure: Error, LocalizedError {
        public let failedPath: String
        public let restoredPaths: [String]
        public var errorDescription: String? {
            "恢复 \(failedPath) 时失败，且已恢复的这些文件没能改回去：\(restoredPaths.prefix(8).joined(separator: "；"))。检查点都还保留着，可以再恢复一次。"
        }
    }

    /// 调用方已按 `lockOrder` 加锁并逐路径授权。先整体预检（模拟每个路径上从新到旧的
    /// 哈希链），任一失败就一条都不动（并列出冲突文件）；预检通过后按序恢复。
    /// `authorize` 对每个路径单独校验授权，返回 false 即整体拒绝。
    /// `overwriteConflicts` 为 true 时（需用户主动选择）：对已变化或已删除的文件，先把当前版本
    /// 存成一个新的检查点（可再恢复），再恢复到这批检查点中最早的旧版本。
    @discardableResult
    public func restoreBefore(_ plan: RewindPlan, sessionID: String, now: Date = Date(),
                              overwriteConflicts: Bool = false,
                              authorize: (String) -> Bool) throws -> [UUID] {
        try synchronized {
            var simulated: [String: String?] = [:]
            var conflicts: [RewindConflictError.Item] = []
            var conflictedPaths = Set<String>()
            // 每个路径回退后的最终内容（最早一条记录的 before）。
            var finalBefore: [String: Data?] = [:]
            for summary in plan.summaries {
                guard authorize(summary.path) else { throw Failure.notAuthorized }
                let record = try load(summary.id, now: now)
                guard record.committed,
                      record.sessionID == sessionID || record.parentSessionID == sessionID,
                      record.path == summary.path else { throw Failure.invalidRecord }
                let url = try checkedURL(URL(fileURLWithPath: record.path))
                if record.before == nil, record.operation != .write { throw Failure.invalidRecord }
                finalBefore[record.path] = .some(record.before)
                if conflictedPaths.contains(record.path) { continue }
                let state: String?
                if let known = simulated[record.path] { state = known } else {
                    let current = try bytes(at: url)
                    if current == nil, record.expectedAfterHash != nil {
                        conflictedPaths.insert(record.path)
                        conflicts.append(.init(path: record.path, reason: .missing))
                        continue
                    }
                    state = current.map(Self.hash)
                }
                if state != record.expectedAfterHash {
                    conflictedPaths.insert(record.path)
                    conflicts.append(.init(path: record.path, reason: .changed))
                    continue
                }
                simulated[record.path] = .some(record.before.map(Self.hash))
            }
            if !conflicts.isEmpty {
                guard overwriteConflicts else { throw RewindConflictError(items: conflicts) }
                // 先为每个冲突文件存好“当前版本”检查点，全部成功后才动文件。
                var backups: [(path: String, url: URL, current: Data?)] = []
                var lastBackupID: UUID?
                for item in conflicts {
                    let url = try checkedURL(URL(fileURLWithPath: item.path))
                    let current = try bytes(at: url)
                    let final = finalBefore[item.path] ?? nil
                    let backup = Record(id: UUID(), createdAt: now, sessionID: sessionID, parentSessionID: nil,
                        childTaskID: nil, path: url.path,
                        operation: current == nil ? .write : .edit, before: current,
                        expectedAfterHash: final.map(Self.hash),
                        conversation: nil, committed: true, deletionReview: nil)
                    try save(backup)
                    _ = try load(backup.id, now: now)
                    backups.append((item.path, url, current))
                    lastBackupID = backup.id
                }
                var written: [(url: URL, current: Data?)] = []
                for (path, url, current) in backups {
                    do {
                        if let final = finalBefore[path] ?? nil {
                            try final.write(to: url, options: .atomic)
                        } else if FileManager.default.fileExists(atPath: url.path) {
                            try FileManager.default.removeItem(at: url)
                        }
                        written.append((url, current))
                    } catch {
                        // 中途失败：把已覆盖的文件用刚才存的当前版本还原，不留下“部分应用”。
                        var unrestored: [String] = []
                        for item in written.reversed() {
                            do {
                                if let data = item.current {
                                    try data.write(to: item.url, options: .atomic)
                                } else if FileManager.default.fileExists(atPath: item.url.path) {
                                    try FileManager.default.removeItem(at: item.url)
                                }
                            } catch {
                                unrestored.append(item.url.path)
                            }
                        }
                        throw RewindOverwriteFailure(failedPath: path, unrestoredPaths: unrestored)
                    }
                }
                if let lastBackupID { enforceTotalQuota(keeping: lastBackupID, now: now) }
            }
            var restored: [UUID] = []
            // 普通恢复：先逐个改文件，任一失败就把本批已恢复的文件还原，全部检查点原样保留；
            // 全部成功后才一起删除检查点记录。
            var applied: [(url: URL, previous: Data?)] = []
            var cleanup: [UUID] = []
            for summary in plan.summaries {
                if conflictedPaths.contains(summary.path) {
                    // 已按冲突方式处理；这批旧记录不再有效。
                    cleanup.append(summary.id)
                    restored.append(summary.id)
                    continue
                }
                do {
                    let item = try applyRestore(summary.id, sessionID: sessionID, now: now, expectedPath: summary.path)
                    applied.append((item.url, item.previous))
                    cleanup.append(summary.id)
                    restored.append(summary.id)
                } catch {
                    var unrestored: [String] = []
                    for item in applied.reversed() {
                        do {
                            if let data = item.previous {
                                try data.write(to: item.url, options: .atomic)
                            } else if FileManager.default.fileExists(atPath: item.url.path) {
                                try FileManager.default.removeItem(at: item.url)
                            }
                        } catch {
                            unrestored.append(item.url.path)
                        }
                    }
                    if unrestored.isEmpty { throw error }
                    throw RewindPartialRestoreFailure(failedPath: summary.path, restoredPaths: unrestored)
                }
            }
            for id in cleanup { try? FileManager.default.removeItem(at: file(id)) }
            return restored
        }
    }

    public static let retentionDays = 30
    public static let scopeDisclosure = "仅包含写入、编辑、删除文件工具的改动；命令行改动不在恢复范围。"
    private let directory: URL
    private let allowedRoots: @Sendable () -> [URL]
    private let deniedRoots: [URL]
    private let lock = NSRecursiveLock()
    private let maxFileBytes = 16 * 1024 * 1024

    public init(directory: URL, allowedRoots: [URL], deniedRoots: [URL] = [],
                allowedRootsProvider: (@Sendable () -> [URL])? = nil,
                totalQuotaBytes: Int = FileCheckpointStore.totalQuotaBytes) throws {
        self.quotaBytes = totalQuotaBytes
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
            guard (expectedAfter?.count ?? 0) <= maxFileBytes else { throw Failure.oversized }
            // 对话快照超限时降级为只存文件检查点（"恢复对话"置灰），不阻断文件改动。
            let conversation = (conversation?.count ?? 0) <= maxFileBytes ? conversation : nil
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
            enforceTotalQuota(keeping: record.id, now: now)
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
            let applied = try applyRestore(id, sessionID: sessionID, now: now, expectedPath: expectedPath)
            // File restoration has succeeded. A failed cleanup must not be
            // misreported as an unchanged file; a later retry rechecks hashes.
            try? FileManager.default.removeItem(at: file(id))
            return applied.conversation
        }
    }

    /// 只改文件、不删检查点记录；返回恢复前的文件内容，供批量恢复失败时回滚。
    private func applyRestore(_ id: UUID, sessionID: String, now: Date, expectedPath: String? = nil)
        throws -> (url: URL, previous: Data?, conversation: Data?) {
        let record = try load(id, now: now)
        guard record.committed, record.sessionID == sessionID || record.parentSessionID == sessionID else { throw Failure.invalidRecord }
        if let expectedPath, record.path != expectedPath { throw Failure.invalidRecord }
        let url = try checkedURL(URL(fileURLWithPath: record.path))
        let currentBytes = try bytes(at: url)
        if currentBytes == nil, record.expectedAfterHash != nil { throw Failure.fileMissing }
        guard currentBytes.map(Self.hash) == record.expectedAfterHash else { throw Failure.changed }
        if let before = record.before {
            try before.write(to: url, options: .atomic)
        } else {
            guard record.operation == .write else { throw Failure.invalidRecord }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        return (url, currentBytes, record.conversation)
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
