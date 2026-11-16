import Foundation
import Darwin

/// Gate-protected session deletion. Deletion moves the persisted file into a
/// private trash directory so the existing SessionManager restore model stays
/// available without changing the shared composition root.
public final class SessionDeletionService: @unchecked Sendable {
    public let manager: SessionManager
    public static let trashRetentionDays = 30
    public struct TrashEntry: Codable, Sendable, Identifiable {
        public let receipt: DeletionReceipt
        public let title: String
        public let payloadDigest: String
        fileprivate var taskMembers: [TaskMember]? = nil
        public var id: UUID { receipt.operationID }
        public var deletedAt: Date { receipt.createdAt }
    }
    private let fileManager = FileManager.default
    private let checkpoints: FileCheckpointStore?
    private let retireSessionMetadata: (@Sendable (Set<String>) throws -> Void)?
    private let isCompletedTask: (@Sendable (ChatSession) -> Bool)?

    fileprivate enum StorageLocation: String, Codable, Equatable, Sendable {
        case active
        case archive
        case trash
    }

    fileprivate struct TaskMember: Codable, Equatable, Sendable {
        let targetID: String
        let sourceLocation: StorageLocation
        let payloadDigest: String
    }

    private enum TransactionPhase: String, Codable {
        case prepared
        case moved
        case committed
    }

    /// Identity-only marker binding the transcript paths and their digests
    /// across a crash boundary. The original payloads move without copying.
    private struct PendingTransaction: Codable, Equatable {
        let operationID: UUID
        let targetID: String
        let scopeID: String
        let sourceLocation: StorageLocation
        let destinationLocation: StorageLocation
        let payloadDigest: String
        let phase: TransactionPhase
        var taskMembers: [TaskMember]? = nil
        var permanent: Bool? = nil

        func withPhase(_ phase: TransactionPhase) -> PendingTransaction {
            PendingTransaction(
                operationID: operationID,
                targetID: targetID,
                scopeID: scopeID,
                sourceLocation: sourceLocation,
                destinationLocation: destinationLocation,
                payloadDigest: payloadDigest,
                phase: phase,
                taskMembers: taskMembers,
                permanent: permanent
            )
        }
    }

    private static let pendingPrefix = ".session-delete-"
    private static let pendingSuffix = ".pending.json"

    public init(
        manager: SessionManager,
        checkpoints: FileCheckpointStore? = nil,
        retireSessionMetadata: (@Sendable (Set<String>) throws -> Void)? = nil,
        isCompletedTask: (@Sendable (ChatSession) -> Bool)? = nil
    ) {
        self.manager = manager
        self.checkpoints = checkpoints
        self.retireSessionMetadata = retireSessionMetadata
        self.isCompletedTask = isCompletedTask
    }

    /// Opt in only at explicit session deletion entry points. Batch and
    /// maintenance callers retain their exact-record preview and receipt.
    public func preview(sessionID: String, includingCompletedTasks: Bool = false) throws -> OperationIntent {
        return try PersistenceTransactionFence.withRead([manager.store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(manager.store.persistenceDomain)
            return try {
            manager.store.persistenceLock.lock()
            defer { manager.store.persistenceLock.unlock() }
            try rejectPendingTransactionsUnlocked()
            let snapshot = try snapshot(for: sessionID)
            let taskMembers = includingCompletedTasks ? try groupedTaskMembers(of: snapshot.session) : nil
            return DeletionGate.preview(
                targetID: sessionID,
                targetType: "session",
                targetName: snapshot.session.title.isEmpty ? "New Session" : snapshot.session.title,
                affectedCount: 1 + (taskMembers?.count ?? 0),
                impactSummary: taskMembers.flatMap { members in
                    members.isEmpty ? nil : "将此会话及 \(members.count) 个已完成子任务的对话移入回收站，保留30天，期间可一起恢复"
                } ?? "移入回收站，保留30天；期间可撤销删除并恢复会话及消息",
                reversible: true,
                scopeID: scope(for: sessionID, at: snapshot.location, grouped: taskMembers != nil),
                revision: snapshot.revision,
                fingerprint: fingerprint(root: snapshot.fingerprint, members: taskMembers)
            )

            }()
        }
    }

    public func delete(
        _ intent: OperationIntent, now: Date = Date(), includingCompletedTasks: Bool = false
    ) throws -> DeletionReceipt {
        return try PersistenceTransactionFence.withWrite([manager.store.persistenceDomain]) {
            manager.store.persistenceLock.lock()
            defer { manager.store.persistenceLock.unlock() }
            try rejectPendingTransactionsUnlocked()
            let snapshot = try snapshot(for: intent.targetID)
            let grouped = intent.scopeID == scope(for: intent.targetID, at: snapshot.location, grouped: true)
            guard intent.targetID == snapshot.session.id,
                  intent.targetType == "session",
                  intent.operationType == .delete,
                  intent.reversible,
                  intent.scopeID == scope(for: intent.targetID, at: snapshot.location, grouped: grouped) else {
                throw SessionDeletionError.deleteFailed("无效的会话删除意图")
            }
            let taskMembers = grouped || includingCompletedTasks
                ? try groupedTaskMembers(of: snapshot.session) : nil
            guard grouped == (taskMembers != nil) else { throw DeletionGateError.targetChanged }
            guard intent.affectedCount == 1 + (taskMembers?.count ?? 0) else {
                if grouped { throw DeletionGateError.targetChanged }
                throw SessionDeletionError.deleteFailed("无效的会话删除意图")
            }
            return try DeletionGate.execute(
                intent,
                currentRevision: snapshot.revision,
                currentFingerprint: fingerprint(root: snapshot.fingerprint, members: taskMembers),
                now: now
            ) { confirmed in
                let trash = trashURL(for: confirmed.operationID)
                let transaction = PendingTransaction(
                    operationID: confirmed.operationID,
                    targetID: confirmed.targetID,
                    scopeID: confirmed.scopeID,
                    sourceLocation: snapshot.location == "archive" ? .archive : .active,
                    destinationLocation: .trash,
                    payloadDigest: snapshot.fingerprint,
                    phase: .prepared,
                    taskMembers: taskMembers
                )
                var moved = false
                do {
                    try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
                    guard try matches(transaction.payloadDigest, at: snapshot.source) else {
                        throw SessionDeletionError.deleteFailed("会话内容在删除前已改变")
                    }
                    try persist(transaction)
                    // Persist only the native deletion receipt and its payload
                    // digest before moving the existing session file. Recovery
                    // still uses the R3 move transaction, never a second copy.
                    try persistTrashEntry(TrashEntry(receipt: DeletionGate.receipt(for: confirmed, now: now),
                        title: snapshot.session.title, payloadDigest: snapshot.fingerprint, taskMembers: taskMembers))
                    if taskMembers != nil {
                        let moves = moves(for: transaction)
                        try requireBeforeLayout(moves, transaction: transaction)
                        moved = true
                        try move(moves)
                    } else {
                        try fileManager.moveItem(at: snapshot.source, to: trash)
                        moved = true
                        try fsyncDirectory(snapshot.source.deletingLastPathComponent())
                        try fsyncDirectory(trashDirectory)
                    }
                    try persist(transaction.withPhase(.moved))
                    try persist(transaction.withPhase(.committed))
                    try removePending(transaction)
                    manager.badgeStore.reset(for: confirmed.targetID)
                } catch {
                    // A move without a durable phase is intentionally kept as
                    // evidence. Recovery can prove the before/after layout or
                    // fail closed without guessing which bytes won.
                    if !moved {
                        try? removePending(transaction)
                        try? fileManager.removeItem(at: trashEntryURL(for: confirmed.operationID))
                    }
                    throw SessionDeletionError.deleteFailed(error.localizedDescription)
                }
            }

        }
    }

    /// Explicit irreversible action, scoped to the active session and its
    /// completed task transcripts. Keeps legacy single-session CAS tickets.
    public func previewPermanentDeletion(
        sessionID: String, now: Date = Date(), ttl: TimeInterval = 300
    ) throws -> OperationIntent {
        try PersistenceTransactionFence.withRead([manager.store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(manager.store.persistenceDomain)
            return try manager.store.persistenceLock.withLock {
                try rejectPendingTransactionsUnlocked()
                let snapshot = try snapshot(for: sessionID)
                let base = try manager.store.previewDeletion(id: sessionID, now: now, ttl: ttl)
                let members = try groupedTaskMembers(of: snapshot.session)
                let count = members?.count ?? 0
                let transcripts = count == 0 ? "此会话的对话记录" : "此会话及 \(count) 个已完成子任务的对话记录"
                return OperationIntent(
                    operationType: .permanentDelete, targetID: sessionID, targetType: "session",
                    targetName: base.targetName, affectedCount: 1 + count,
                    impactSummary: "永久删除\(transcripts)和文件检查点中的相关对话快照，保留文件恢复数据。",
                    reversible: false, scopeID: scope(for: sessionID, at: "active", grouped: members != nil),
                    revision: base.revision, fingerprint: fingerprint(root: base.fingerprint, members: members),
                    expiresAt: base.expiresAt
                )
            }
        }
    }

    public func permanentlyDelete(
        _ intent: OperationIntent, now: Date = Date()
    ) throws -> DeletionReceipt {
        try PersistenceTransactionFence.withWrite([manager.store.persistenceDomain]) {
            try DeletionGate.checkLifecycle(intent)
            return try manager.store.persistenceLock.withLock {
                try rejectPendingTransactionsUnlocked()
                let snapshot = try snapshot(for: intent.targetID)
                guard snapshot.location == "active", intent.targetType == "session",
                      intent.operationType == .permanentDelete, !intent.reversible else {
                    throw DeletionGateError.invalidIntent
                }
                let base = try manager.store.previewDeletion(id: intent.targetID, now: now)
                let members = try groupedTaskMembers(of: snapshot.session)
                guard intent.scopeID == scope(for: intent.targetID, at: "active", grouped: members != nil),
                      intent.affectedCount == 1 + (members?.count ?? 0) else {
                    throw DeletionGateError.targetChanged
                }
                return try DeletionGate.execute(intent, currentRevision: base.revision,
                    currentFingerprint: fingerprint(root: base.fingerprint, members: members), now: now) { confirmed in
                    let transaction = PendingTransaction(
                        operationID: confirmed.operationID, targetID: confirmed.targetID,
                        scopeID: confirmed.scopeID, sourceLocation: .active, destinationLocation: .trash,
                        payloadDigest: snapshot.fingerprint, phase: .prepared, taskMembers: members,
                        permanent: true
                    )
                    let transfers = moves(for: transaction)
                    try requireBeforeLayout(transfers, transaction: transaction)
                    try persist(transaction)
                    for id in [transaction.targetID] + (members ?? []).map(\.targetID) {
                        manager.store.invalidateSessionRecoveryUnlocked(for: id)
                    }
                    try move(transfers)
                    let moved = transaction.withPhase(.moved)
                    try persist(moved)
                    try finishPermanentDeletion(moved)
                    manager.badgeStore.reset(for: confirmed.targetID)
                }
            }
        }
    }

    public func restore(_ receipt: DeletionReceipt, now: Date = Date()) throws {
        return try PersistenceTransactionFence.withWrite([manager.store.persistenceDomain]) {
            manager.store.persistenceLock.lock()
            defer { manager.store.persistenceLock.unlock() }
            try rejectPendingTransactionsUnlocked()
            let destinationLocation = try validatedRestoreLocation(receipt)
            guard now.timeIntervalSince(receipt.createdAt) >= 0,
                  now.timeIntervalSince(receipt.createdAt) < Double(Self.trashRetentionDays * 86400) else {
                throw SessionDeletionError.restoreFailed("回收站会话已超过30天，未恢复")
            }
            let trash = trashURL(for: receipt.operationID)
            guard fileManager.fileExists(atPath: trash.path) else {
                throw SessionDeletionError.restoreFailed("回收站中不存在操作 \(receipt.operationID.uuidString)")
            }
            guard let data = try? secureData(at: trash),
                  let session = try? JSONDecoder().decode(ChatSession.self, from: data),
                  session.id == receipt.targetID else {
                throw SessionDeletionError.restoreFailed("回收站内容与会话身份不匹配")
            }
            let entry = try loadTrashEntry(receipt.operationID)
            if let entry {
                guard entry.receipt == receipt, entry.payloadDigest == DeletionGate.fingerprint(data) else {
                    throw SessionDeletionError.restoreFailed("回收站内容与原删除回执不匹配")
                }
            }
            let grouped = receipt.scopeID == scope(for: receipt.targetID, at: destinationLocation.rawValue, grouped: true)
            guard !grouped || entry?.taskMembers != nil else {
                throw SessionDeletionError.restoreFailed("缺少子任务回收站清单")
            }
            guard try matches(DeletionGate.fingerprint(data), at: trash) else {
                throw SessionDeletionError.restoreFailed("回收站内容在恢复前已改变")
            }

            let destination = url(for: destinationLocation, targetID: receipt.targetID, operationID: receipt.operationID)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw SessionDeletionError.restoreTargetExists(receipt.targetID)
            }

            let transaction = PendingTransaction(
                operationID: receipt.operationID,
                targetID: receipt.targetID,
                scopeID: receipt.scopeID,
                sourceLocation: .trash,
                destinationLocation: destinationLocation,
                payloadDigest: DeletionGate.fingerprint(data),
                phase: .prepared,
                taskMembers: entry?.taskMembers
            )
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if grouped {
                    let moves = moves(for: transaction)
                    try requireBeforeLayout(moves, transaction: transaction)
                    try requireNoAlternateRestoreLocations(transaction)
                    try persist(transaction)
                    try move(moves)
                } else {
                    try persist(transaction)
                    try fileManager.moveItem(at: trash, to: destination)
                    try fsyncDirectory(trashDirectory)
                    try fsyncDirectory(destination.deletingLastPathComponent())
                }
                try persist(transaction.withPhase(.moved))
                try persist(transaction.withPhase(.committed))
                try removePending(transaction)
                try? fileManager.removeItem(at: trashEntryURL(for: receipt.operationID))
            } catch {
                throw SessionDeletionError.restoreFailed(error.localizedDescription)
            }

        }
    }

    /// Exact root identities whose confirmed permanent operation is awaiting
    /// recovery. App projections must hold their writes until it is resolved.
    public func pendingPermanentDeletionTargets() throws -> [String] {
        try PersistenceTransactionFence.withRead([manager.store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(manager.store.persistenceDomain)
            return try manager.store.persistenceLock.withLock {
                try pendingTransactionsUnlocked().filter { $0.permanent == true }.map(\.targetID)
            }
        }
    }

    /// Explicit startup/repair seam. Only a marker whose before/after layout
    /// and digest are provable is removed; every ambiguous marker remains on
    /// disk and fails closed for later mutations.
    @discardableResult
    public func recoverPendingTransactions() throws -> Int {
        return try PersistenceTransactionFence.withWrite([manager.store.persistenceDomain]) {
            manager.store.persistenceLock.lock()
            defer { manager.store.persistenceLock.unlock() }
            let pending = try pendingTransactionsUnlocked()
            guard !pending.isEmpty else { return 0 }

            var removable: [PendingTransaction] = []
            var finalizedPermanentCount = 0
            for transaction in pending {
                if transaction.permanent == true && transaction.phase != .prepared {
                    try finishPermanentDeletion(transaction)
                    manager.badgeStore.reset(for: transaction.targetID)
                    finalizedPermanentCount += 1
                    continue
                }
                if transaction.taskMembers != nil || transaction.permanent == true {
                    try recoverGroup(transaction)
                    removable.append(transaction)
                    continue
                }
                let source = url(
                    for: transaction.sourceLocation,
                    targetID: transaction.targetID,
                    operationID: transaction.operationID
                )
                let destination = url(
                    for: transaction.destinationLocation,
                    targetID: transaction.targetID,
                    operationID: transaction.operationID
                )
                let sourceMatches = try matches(transaction.payloadDigest, at: source)
                let destinationMatches = try matches(transaction.payloadDigest, at: destination)
                switch transaction.phase {
                case .prepared where sourceMatches && !fileManager.fileExists(atPath: destination.path):
                    removable.append(transaction)
                case .moved where !fileManager.fileExists(atPath: source.path) && destinationMatches:
                    removable.append(transaction)
                case .committed where !fileManager.fileExists(atPath: source.path) && destinationMatches:
                    removable.append(transaction)
                default:
                    throw SessionDeletionError.recoveryRequired(transaction.operationID.uuidString)
                }
            }
            for transaction in removable {
                try removePending(transaction)
                if !fileManager.fileExists(atPath: trashURL(for: transaction.operationID).path) {
                    try? fileManager.removeItem(at: trashEntryURL(for: transaction.operationID))
                }
            }
            return removable.count + finalizedPermanentCount
        }
    }

    /// Only indexed, unexpired, identity- and hash-matching R3 trash files are
    /// offered. Legacy files without a receipt index are not guessed or purged.
    public func trashEntries(now: Date = Date()) throws -> [TrashEntry] {
        try PersistenceTransactionFence.withRead([manager.store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(manager.store.persistenceDomain)
            manager.store.persistenceLock.lock(); defer { manager.store.persistenceLock.unlock() }
            try rejectPendingTransactionsUnlocked()
            return try allTrashEntriesUnlocked().filter { entry in
                let age = now.timeIntervalSince(entry.deletedAt)
                guard age >= 0, age < Double(Self.trashRetentionDays * 86400),
                      let data = try? secureData(at: trashURL(for: entry.id)),
                      DeletionGate.fingerprint(data) == entry.payloadDigest,
                      let session = try? JSONDecoder().decode(ChatSession.self, from: data),
                      session.id == entry.receipt.targetID,
                      try trashMembersMatch(entry) else { return false }
                return true
            }.sorted { $0.deletedAt > $1.deletedAt }
        }
    }
    @discardableResult public func purgeExpiredTrash(now: Date = Date()) throws -> Int {
        try PersistenceTransactionFence.withWrite([manager.store.persistenceDomain]) {
            manager.store.persistenceLock.lock(); defer { manager.store.persistenceLock.unlock() }
            try rejectPendingTransactionsUnlocked()
            var removed = 0
            let indexedTrash = try allTrashEntriesUnlocked()
            for entry in indexedTrash
                where now.timeIntervalSince(entry.deletedAt) >= Double(Self.trashRetentionDays * 86400) {
                let payload = trashURL(for: entry.id)
                guard let data = try? secureData(at: payload),
                      DeletionGate.fingerprint(data) == entry.payloadDigest,
                      let session = try? JSONDecoder().decode(ChatSession.self, from: data),
                      session.id == entry.receipt.targetID,
                      try trashMembersMatch(entry, allowMissing: true) else { continue }
                try retireOwnedSessionMetadata(
                    root: entry.receipt.targetID, members: entry.taskMembers ?? [], operationID: entry.id,
                    indexedTrash: indexedTrash
                )
                for index in (entry.taskMembers ?? []).indices {
                    let member = taskTrashURL(for: entry.id, index: index)
                    if fileManager.fileExists(atPath: member.path) {
                        try fileManager.removeItem(at: member)
                    }
                }
                try fileManager.removeItem(at: payload)
                try? fileManager.removeItem(at: trashEntryURL(for: entry.id))
                removed += 1
            }
            if removed > 0 { try fsyncDirectory(trashDirectory) }
            return removed
        }
    }
    private func trashEntryURL(for id: UUID) -> URL {
        trashDirectory.appendingPathComponent(".trash-receipt-" + id.uuidString + ".json")
    }
    private func persistTrashEntry(_ entry: TrashEntry) throws {
        let url = trashEntryURL(for: entry.id)
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        guard fsyncFile(url) else { throw SessionDeletionError.recoveryRequired(entry.id.uuidString) }
        try fsyncDirectory(trashDirectory)
    }
    private func loadTrashEntry(_ id: UUID) throws -> TrashEntry? {
        let url = trashEntryURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let entry = try JSONDecoder().decode(TrashEntry.self, from: secureData(at: url))
        guard entry.id == id, entry.payloadDigest.count == 64,
              let location = try? validatedRestoreLocation(entry.receipt),
              validMembers(entry.taskMembers, targetID: entry.receipt.targetID,
                           scopeID: entry.receipt.scopeID, location: location),
              entry.receipt.affectedCount == 1 + (entry.taskMembers?.count ?? 0) else {
            throw SessionDeletionError.restoreFailed("回收站索引无效")
        }
        return entry
    }
    private func allTrashEntriesUnlocked() throws -> [TrashEntry] {
        guard fileManager.fileExists(atPath: trashDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil)
            .compactMap { url in
                guard url.lastPathComponent.hasPrefix(".trash-receipt-"), url.pathExtension == "json",
                      let id = UUID(uuidString: String(url.lastPathComponent.dropFirst(".trash-receipt-".count).dropLast(".json".count))) else { return nil }
                return try loadTrashEntry(id)
            }
    }

    private var trashDirectory: URL {
        manager.store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
    }

    private func trashURL(for operationID: UUID) -> URL {
        trashDirectory.appendingPathComponent("\(operationID.uuidString).json")
    }

    private func url(
        for location: StorageLocation,
        targetID: String,
        operationID: UUID
    ) -> URL {
        switch location {
        case .active:
            return manager.store.sessionsDirectory.appendingPathComponent("\(targetID).json")
        case .archive:
            return manager.archiveDirectory.appendingPathComponent("\(targetID).json")
        case .trash:
            return trashURL(for: operationID)
        }
    }

    private func validatedRestoreLocation(_ receipt: DeletionReceipt) throws -> StorageLocation {
        guard receipt.outcome == "deleted",
              receipt.affectedCount >= 1,
              isSafePathComponent(receipt.targetID) else {
            throw SessionDeletionError.restoreFailed("无效的会话恢复回执")
        }
        for location in [StorageLocation.active, .archive] {
            if receipt.scopeID == scope(for: receipt.targetID, at: location.rawValue, grouped: false),
               receipt.affectedCount == 1 { return location }
            if receipt.scopeID == scope(for: receipt.targetID, at: location.rawValue, grouped: true) {
                return location
            }
        }
        throw SessionDeletionError.restoreFailed("无效的会话恢复范围")
    }

    private func scope(for id: String, at location: String, grouped: Bool) -> String {
        "session:\(id):\(location)" + (grouped ? ":task-group" : "")
    }

    private func fingerprint(root: String, members: [TaskMember]?) -> String {
        guard let members else { return root }
        let membership = members.map {
            "\($0.targetID.utf8.count):\($0.targetID):\($0.sourceLocation.rawValue):\($0.payloadDigest)"
        }.joined(separator: "\n")
        return DeletionGate.fingerprint(root + "\n" + membership)
    }

    private func groupedTaskMembers(of root: ChatSession) throws -> [TaskMember]? {
        if root.createdByTaskID?.isEmpty == false, root.createdByRunID?.isEmpty == false,
           let parent = root.parentSessionID, root.id.hasPrefix(parent + ":child:"),
           isCompletedTask?(root) != true {
            throw SessionDeletionError.deleteFailed("子任务尚未完成或无法确认其会话归属")
        }
        let members = try completedTaskMembers(of: root)
        return members.isEmpty ? nil : members
    }

    private func completedTaskMembers(of root: ChatSession) throws -> [TaskMember] {
        let locations: [(StorageLocation, URL)] = [
            (.active, manager.store.sessionsDirectory), (.archive, manager.archiveDirectory)
        ]
        let decoder = JSONDecoder()
        var byParent: [String: [(ChatSession, TaskMember)]] = [:]
        for (location, directory) in locations where fileManager.fileExists(atPath: directory.path) {
            let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                guard id.hasPrefix(root.id + ":child:") else { continue }
                guard let data = try? secureData(at: file),
                      let child = try? decoder.decode(ChatSession.self, from: data),
                      child.id == id else {
                    throw SessionDeletionError.deleteFailed("无法核对潜在子任务的会话内容")
                }
                guard let parent = child.parentSessionID,
                      id.hasPrefix(parent + ":child:"), child.forkedFromSessionID == parent,
                      child.rootSessionID == root.rootSessionID,
                      child.lineageVersion == root.lineageVersion,
                      child.createdByTaskID?.isEmpty == false,
                      child.createdByRunID?.isEmpty == false else { continue }
                let member = TaskMember(targetID: id, sourceLocation: location,
                                        payloadDigest: DeletionGate.fingerprint(data))
                byParent[parent, default: []].append((child, member))
            }
        }

        var result: [TaskMember] = []
        var parents = [root]
        var seen: Set<String> = [root.id]
        var index = 0
        while index < parents.count {
            let parent = parents[index]
            index += 1
            for (child, member) in (byParent[parent.id] ?? []).sorted(by: { $0.0.id < $1.0.id }) {
                guard seen.insert(child.id).inserted,
                      child.projectID == parent.projectID,
                      child.workingDirectory == parent.workingDirectory,
                      let revision = child.forkedThroughTranscriptRevision,
                      revision <= parent.transcriptRevision,
                      isCompletedTask?(child) == true else {
                    throw SessionDeletionError.deleteFailed("子任务尚未完成或无法确认其会话归属")
                }
                result.append(member)
                parents.append(child)
            }
        }
        return result
    }

    private func validMembers(
        _ members: [TaskMember]?, targetID: String, scopeID: String, location: StorageLocation
    ) -> Bool {
        guard scopeID == scope(for: targetID, at: location.rawValue, grouped: members != nil) else {
            return false
        }
        guard let members else { return true }
        return Set(members.map(\.targetID)).count == members.count
            && members.allSatisfy {
                $0.targetID.hasPrefix(targetID + ":child:") && isSafePathComponent($0.targetID)
                    && $0.sourceLocation != .trash && $0.payloadDigest.utf8.count == 64
                    && $0.payloadDigest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
    }

    private func taskTrashURL(for operationID: UUID, index: Int) -> URL {
        trashDirectory.appendingPathComponent(".trash-member-\(operationID.uuidString)-\(index).json")
    }

    private func trashMembersMatch(_ entry: TrashEntry, allowMissing: Bool = false) throws -> Bool {
        for (index, member) in (entry.taskMembers ?? []).enumerated() {
            let payload = taskTrashURL(for: entry.id, index: index)
            if allowMissing && !fileManager.fileExists(atPath: payload.path) { continue }
            guard try matches(member.payloadDigest, at: payload) else { return false }
        }
        return true
    }

    private struct TranscriptMove {
        let source: URL
        let destination: URL
        let digest: String

        var reversed: Self { Self(source: destination, destination: source, digest: digest) }
    }

    private func moves(for transaction: PendingTransaction) -> [TranscriptMove] {
        let restoring = transaction.sourceLocation == .trash
        let originalRoot = url(for: restoring ? transaction.destinationLocation : transaction.sourceLocation,
                               targetID: transaction.targetID, operationID: transaction.operationID)
        let root = TranscriptMove(source: originalRoot, destination: trashURL(for: transaction.operationID),
                                  digest: transaction.payloadDigest)
        let members = (transaction.taskMembers ?? []).enumerated().map { index, member in
            TranscriptMove(
                source: url(for: member.sourceLocation, targetID: member.targetID, operationID: transaction.operationID),
                destination: taskTrashURL(for: transaction.operationID, index: index),
                digest: member.payloadDigest
            )
        }
        let deletion = Array(members.reversed()) + [root]
        return restoring ? deletion.reversed().map(\.reversed) : deletion
    }

    private func requireBeforeLayout(_ moves: [TranscriptMove], transaction: PendingTransaction) throws {
        for move in moves {
            guard try matches(move.digest, at: move.source),
                  !fileManager.fileExists(atPath: move.destination.path) else {
                throw SessionDeletionError.recoveryRequired(transaction.operationID.uuidString)
            }
        }
    }

    private func clearConversationSnapshots(sessionIDs: Set<String>) throws {
        let directory = manager.store.directory.appendingPathComponent("file-checkpoints", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let store: FileCheckpointStore
        if let checkpoints, checkpoints.ownsDirectory(directory) {
            store = checkpoints
        } else {
            store = try FileCheckpointStore(directory: directory, allowedRoots: [])
        }
        try store.clearConversationSnapshots(sessionIDs: sessionIDs)
    }

    private func retireOwnedSessionMetadata(
        root: String, members: [TaskMember], operationID: UUID, indexedTrash: [TrashEntry]? = nil
    ) throws {
        let otherEntries = try indexedTrash ?? allTrashEntriesUnlocked()
        let terminalIDs = Set(([root] + members.map(\.targetID)).filter { id in
            // A reused identity can still belong to another live transcript
            // or indexed trash payload, so its metadata is not ours to clear.
            !fileManager.fileExists(atPath: url(for: .active, targetID: id, operationID: operationID).path)
                && !fileManager.fileExists(atPath: url(for: .archive, targetID: id, operationID: operationID).path)
                && !otherEntries.contains { entry in
                    entry.id != operationID
                        && (entry.receipt.targetID == id || entry.taskMembers?.contains { $0.targetID == id } == true)
                        && fileManager.fileExists(atPath: trashURL(for: entry.id).path)
                }
        })
        guard !terminalIDs.isEmpty else { return }
        try retireSessionMetadata?(terminalIDs)
        try clearConversationSnapshots(sessionIDs: terminalIDs)
    }

    private func finishPermanentDeletion(_ transaction: PendingTransaction) throws {
        let transfers = moves(for: transaction)
        for transfer in transfers {
            let alreadyRemoved = transaction.phase == .committed
                && !fileManager.fileExists(atPath: transfer.destination.path)
            guard !fileManager.fileExists(atPath: transfer.source.path),
                  try alreadyRemoved || matches(transfer.digest, at: transfer.destination) else {
                throw SessionDeletionError.recoveryRequired(transaction.operationID.uuidString)
            }
        }
        try retireOwnedSessionMetadata(
            root: transaction.targetID, members: transaction.taskMembers ?? [], operationID: transaction.operationID
        )
        if transaction.phase != .committed {
            try persist(transaction.withPhase(.committed))
        }
        for transfer in transfers where fileManager.fileExists(atPath: transfer.destination.path) {
            try fileManager.removeItem(at: transfer.destination)
        }
        try removePending(transaction)
    }

    private func requireNoAlternateRestoreLocations(_ transaction: PendingTransaction) throws {
        let recordedLocations = [(transaction.targetID, transaction.destinationLocation)]
            + (transaction.taskMembers ?? []).map { ($0.targetID, $0.sourceLocation) }
        for (id, recorded) in recordedLocations {
            let alternate: StorageLocation = recorded == .active ? .archive : .active
            let path = url(for: alternate, targetID: id, operationID: transaction.operationID)
            guard !fileManager.fileExists(atPath: path.path) else {
                throw SessionDeletionError.restoreTargetExists(id)
            }
        }
    }

    private func move(_ moves: [TranscriptMove]) throws {
        for move in moves {
            try fileManager.moveItem(at: move.source, to: move.destination)
            try fsyncDirectory(move.source.deletingLastPathComponent())
            try fsyncDirectory(move.destination.deletingLastPathComponent())
        }
    }

    private func recoverGroup(_ transaction: PendingTransaction) throws {
        var rollback: [TranscriptMove] = []
        for move in moves(for: transaction) {
            if try matches(move.digest, at: move.destination),
               !fileManager.fileExists(atPath: move.source.path) {
                rollback.append(move.reversed)
            } else if transaction.phase == .prepared,
                      try matches(move.digest, at: move.source),
                      !fileManager.fileExists(atPath: move.destination.path) {
                continue
            } else {
                throw SessionDeletionError.recoveryRequired(transaction.operationID.uuidString)
            }
        }
        if transaction.phase == .prepared {
            try move(Array(rollback.reversed()))
        }
    }

    private func rejectPendingTransactionsUnlocked() throws {
        let pending = try pendingTransactionsUnlocked()
        guard let first = pending.first else { return }
        throw SessionDeletionError.recoveryRequired(first.operationID.uuidString)
    }

    private func pendingTransactionsUnlocked() throws -> [PendingTransaction] {
        guard fileManager.fileExists(atPath: trashDirectory.path) else { return [] }
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: trashDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw SessionDeletionError.recoveryRequired("无法读取回收站事务")
        }
        var result: [PendingTransaction] = []
        for file in files where file.lastPathComponent.hasPrefix(Self.pendingPrefix) {
            guard file.lastPathComponent.hasSuffix(Self.pendingSuffix) else {
                throw SessionDeletionError.recoveryRequired(file.lastPathComponent)
            }
            guard let operationID = UUID(uuidString: String(file.lastPathComponent.dropFirst(Self.pendingPrefix.count).dropLast(Self.pendingSuffix.count))),
                  let data = try? secureData(at: file),
                  let transaction = try? JSONDecoder().decode(PendingTransaction.self, from: data),
                  markerKeysAreCanonical(data),
                  transaction.operationID == operationID,
                  transaction.targetID.isEmpty == false,
                  isSafePathComponent(transaction.targetID),
                  validMembers(transaction.taskMembers, targetID: transaction.targetID,
                      scopeID: transaction.scopeID, location: transaction.sourceLocation == .trash
                          ? transaction.destinationLocation : transaction.sourceLocation),
                  transaction.permanent == nil
                    || (transaction.permanent == true && transaction.sourceLocation == .active
                        && transaction.destinationLocation == .trash),
                  transaction.destinationLocation != transaction.sourceLocation,
                  (transaction.sourceLocation == .trash && transaction.destinationLocation != .trash)
                    || (transaction.sourceLocation != .trash && transaction.destinationLocation == .trash),
                  transaction.payloadDigest.count == 64,
                  transaction.payloadDigest.allSatisfy({ $0.isHexDigit && $0.isLowercase || $0.isNumber }) else {
                throw SessionDeletionError.recoveryRequired(file.lastPathComponent)
            }
            result.append(transaction)
        }
        return result.sorted { $0.operationID.uuidString < $1.operationID.uuidString }
    }

    private func persist(_ transaction: PendingTransaction) throws {
        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let url = pendingURL(for: transaction.operationID)
        let data = try JSONEncoder().encode(transaction)
        try data.write(to: url, options: .atomic)
        guard fsyncFile(url) else {
            throw SessionDeletionError.recoveryRequired(transaction.operationID.uuidString)
        }
        try fsyncDirectory(trashDirectory)
    }

    private func removePending(_ transaction: PendingTransaction) throws {
        let url = pendingURL(for: transaction.operationID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fsyncDirectory(trashDirectory)
    }

    private func pendingURL(for operationID: UUID) -> URL {
        trashDirectory.appendingPathComponent(
            "\(Self.pendingPrefix)\(operationID.uuidString)\(Self.pendingSuffix)"
        )
    }

    private func matches(_ digest: String, at url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? secureData(at: url) else { return false }
        return DeletionGate.fingerprint(data) == digest
    }

    private func markerKeysAreCanonical(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let baseKeys: Set<String> = [
            "operationID", "targetID", "scopeID", "sourceLocation",
            "destinationLocation", "payloadDigest", "phase"
        ]
        let keys = Set(object.keys)
        return baseKeys.isSubset(of: keys)
            && keys.subtracting(baseKeys).isSubset(of: ["taskMembers", "permanent"])
    }

    private func secureData(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & mode_t(0o022)) == 0,
              info.st_size >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        guard data.count == Int(info.st_size) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private func fsyncFile(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        return Darwin.fsync(descriptor) == 0
    }

    private func fsyncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SessionDeletionError.recoveryRequired(url.path) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw SessionDeletionError.recoveryRequired(url.path)
        }
    }

    private func snapshot(for sessionID: String) throws -> (session: ChatSession, source: URL, location: String, revision: Int, fingerprint: String) {
        guard isSafePathComponent(sessionID) else {
            throw SessionManagerError.sessionNotFound(sessionID)
        }
        let activeURL = manager.store.sessionsDirectory.appendingPathComponent("\(sessionID).json")
        let archiveURL = manager.archiveDirectory.appendingPathComponent("\(sessionID).json")
        let location: String
        let source: URL
        if fileManager.fileExists(atPath: activeURL.path) {
            location = "active"
            source = activeURL
        } else if fileManager.fileExists(atPath: archiveURL.path) {
            location = "archive"
            source = archiveURL
        } else {
            throw SessionManagerError.sessionNotFound(sessionID)
        }

        guard let session = manager.loadSessionIncludingArchived(id: sessionID),
              let data = try? secureData(at: source) else {
            throw SessionManagerError.sessionNotFound(sessionID)
        }
        let timestamp = Int64(session.updatedAt.timeIntervalSince1970.rounded(.down))
        return (session, source, location, Int(clamping: timestamp), DeletionGate.fingerprint(data))
    }
}

public enum SessionDeletionError: Error, Equatable, Sendable {
    case deleteFailed(String)
    case restoreFailed(String)
    case restoreTargetExists(String)
    case recoveryRequired(String)
}
