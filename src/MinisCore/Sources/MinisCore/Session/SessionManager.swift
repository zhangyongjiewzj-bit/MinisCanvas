import Foundation
import Darwin

// MARK: - SessionManagerFact

/// Immutable identity for a session projection handed to an asynchronous
/// manager consumer. The lineage identity is part of the fact so a reused
/// session ID cannot silently accept a result from another branch.
public struct SessionManagerFact: Equatable, Hashable, Sendable {
    public let sessionID: String
    public let transcriptRevision: UInt64
    public let lineageIdentity: SessionLineageIdentity

    public var lineageOwner: String { lineageIdentity.rootSessionID }

    public var stableID: String {
        let lineage = lineageIdentity
        return [
            "\(sessionID.utf8.count):\(sessionID)",
            "\(transcriptRevision)",
            "\(lineage.lineageVersion)",
            "\(lineage.rootSessionID)",
            lineage.parentSessionID ?? "-",
            lineage.forkedFromSessionID ?? "-",
            lineage.forkedThroughTranscriptRevision.map { String($0) } ?? "-",
            lineage.forkedThroughMessageID ?? "-"
        ].joined(separator: "#")
    }

    public init(
        sessionID: String,
        transcriptRevision: UInt64,
        lineageIdentity: SessionLineageIdentity
    ) {
        self.sessionID = sessionID
        self.transcriptRevision = transcriptRevision
        self.lineageIdentity = lineageIdentity
    }

    public init(session: ChatSession) {
        self.init(
            sessionID: session.id,
            transcriptRevision: session.transcriptRevision,
            lineageIdentity: session.lineageIdentity
        )
    }
}

// MARK: - SessionStats

/// Per-session statistics for the session list UI.
public struct SessionStats: Identifiable, Sendable {
    public let session: ChatSession
    /// Number of messages in the session.
    public let messageCount: Int
    /// Last activity time (`updatedAt`).
    public let lastActivityAt: Date
    /// Unread badge count from `SessionBadgeStore`.
    public let unreadCount: Int
    /// Identity captured with this projection for stale-result rejection.
    public let managerFact: SessionManagerFact

    public var id: String { session.id }
}

// MARK: - SessionManager

/// High-level session management built on `SessionStore` + `SessionBadgeStore`:
/// list with stats, archive (move away without deleting), restore, and
/// retention-based cleanup.
///
/// Archived sessions are moved to `<sessions>/_archive/<id>.json`, so they
/// disappear from `SessionStore.listSessions()` (non-recursive directory scan)
/// but are never deleted until `purgeOld` or the app removes them.
public final class SessionManager: @unchecked Sendable {

    private enum SessionMoveLocation: String, Codable {
        case active
        case archive
    }

    private enum SessionMovePhase: String, Codable {
        case prepared
        case moved
        case committed
    }

    /// Identity-only marker for an active/archive move. Session bytes remain
    /// in the moved file; the marker proves which layout and digest survived
    /// a crash without copying the payload into the recovery metadata.
    private struct PendingSessionMove: Codable, Equatable {
        let operationID: UUID
        let targetID: String
        let scopeID: String
        let sourceLocation: SessionMoveLocation
        let destinationLocation: SessionMoveLocation
        let payloadDigest: String
        let phase: SessionMovePhase

        func withPhase(_ phase: SessionMovePhase) -> PendingSessionMove {
            PendingSessionMove(
                operationID: operationID,
                targetID: targetID,
                scopeID: scopeID,
                sourceLocation: sourceLocation,
                destinationLocation: destinationLocation,
                payloadDigest: payloadDigest,
                phase: phase
            )
        }
    }

    private static let pendingMovePrefix = ".session-move-"
    private static let pendingMoveSuffix = ".pending.json"

    public let store: SessionStore
    public let badgeStore: SessionBadgeStore

    private var lock: SessionPersistenceLock { store.persistenceLock }

    /// Directory holding archived `<id>.json` files.
    public var archiveDirectory: URL {
        store.sessionsDirectory.appendingPathComponent("_archive", isDirectory: true)
    }

    public init(store: SessionStore, badgeStore: SessionBadgeStore = .shared) {
        self.store = store
        self.badgeStore = badgeStore
    }

    // MARK: - Listing

    /// Active (non-archived) sessions with message count, last activity and
    /// unread badge, most recently updated first.
    public func listWithStats() -> [SessionStats] {
        return PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            lock.lock()
            defer { lock.unlock() }
            return store.listSessions().map { session in
                SessionStats(
                    session: session,
                    messageCount: session.messages.count,
                    lastActivityAt: session.updatedAt,
                    unreadCount: badgeStore.unreadCount(for: session.id),
                    managerFact: SessionManagerFact(session: session)
                )
            }

        }
    }

    /// Return the current identity fact for an active or archived session.
    /// Duplicate active/archive identities fail closed and return nil.
    public func managerFact(for sessionID: String) -> SessionManagerFact? {
        return PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            lock.withLock {
                guard let session = loadSessionIncludingArchivedUnlocked(id: sessionID) else {
                    return nil
                }
                return SessionManagerFact(session: session)
            }

        }
    }

    /// Resolve a session only when its identity, transcript revision and
    /// lineage owner still match the captured manager fact.
    public func requireCurrent(_ expected: SessionManagerFact) throws -> ChatSession {
        return try PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            try lock.withLock {
                let active = store.loadSession(id: expected.sessionID)
                let archivedURL = archiveDirectory.appendingPathComponent(
                    "\(expected.sessionID).json"
                )
                if active != nil && PersistenceTransactionFence.exists(at: archivedURL, domain: store.persistenceDomain) {
                    throw SessionManagerError.duplicateSessionIdentity(expected.sessionID)
                }
                guard let current = active ?? loadArchivedSessionUnlocked(
                    id: expected.sessionID,
                    at: archivedURL
                ) else {
                    throw SessionManagerError.staleManagerFact(expected: expected, actual: nil)
                }
                let actual = SessionManagerFact(session: current)
                guard actual == expected else {
                    throw SessionManagerError.staleManagerFact(expected: expected, actual: actual)
                }
                return current
            }

        }
    }

    /// Archived sessions, most recently updated first.
    public func archivedSessions() -> [ChatSession] {
        return PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            lock.lock()
            defer { lock.unlock() }
            return archivedSessionsUnlocked()

        }
    }

    /// Read one session by ID from the active store or the archive.
    ///
    /// This is intentionally read-only and is used by the Agent's
    /// `session_read` tool. If an ID is present in both locations, resolution
    /// fails closed instead of allowing an arbitrary manager fact to win.
    public func loadSessionIncludingArchived(id: String) -> ChatSession? {
        return PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            lock.lock()
            defer { lock.unlock() }

            return loadSessionIncludingArchivedUnlocked(id: id)

        }
    }

    private func loadSessionIncludingArchivedUnlocked(id: String) -> ChatSession? {
        let archivedURL = archiveDirectory.appendingPathComponent("\(id).json")
        let active = store.loadSession(id: id)
        if active != nil && PersistenceTransactionFence.exists(at: archivedURL, domain: store.persistenceDomain) {
            return nil
        }
        if let active {
            return active
        }
        return loadArchivedSessionUnlocked(id: id, at: archivedURL)
    }

    private func loadArchivedSessionUnlocked(id: String, at archivedURL: URL) -> ChatSession? {
        guard PersistenceTransactionFence.exists(at: archivedURL, domain: store.persistenceDomain),
              let data = try? PersistenceTransactionFence.data(at: archivedURL, domain: store.persistenceDomain),
              let session = try? JSONDecoder().decode(ChatSession.self, from: data),
              session.id == id else {
            return nil
        }
        return session
    }

    // MARK: - Archive / Restore

    /// Move a session into the archive. The session file is preserved, not
    /// deleted. Throws `sessionNotFound` when the session doesn't exist and
    /// `alreadyArchived` when it is already archived.
    public func archive(sessionID: String) throws {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            try lock.withLock {
                try rejectPendingSessionMovesUnlocked()
                let fm = FileManager.default
                guard isSafePathComponent(sessionID) else {
                    throw SessionManagerError.sessionNotFound(sessionID)
                }
                let src = store.sessionsDirectory.appendingPathComponent("\(sessionID).json")
                let dst = archiveDirectory.appendingPathComponent("\(sessionID).json")
                // Check the archive target first so archiving an already-archived
                // session reports `.alreadyArchived` rather than `.sessionNotFound`
                // (its source file is already gone).
                if fm.fileExists(atPath: dst.path) {
                    throw SessionManagerError.alreadyArchived(sessionID)
                }
                guard fm.fileExists(atPath: src.path) else {
                    throw SessionManagerError.sessionNotFound(sessionID)
                }
                guard let data = try? PersistenceTransactionFence.data(
                    at: src,
                    domain: store.persistenceDomain
                ) else {
                    throw SessionManagerError.sessionNotFound(sessionID)
                }
                try fm.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
                let transaction = PendingSessionMove(
                    operationID: UUID(),
                    targetID: sessionID,
                    scopeID: "session:\(sessionID):active",
                    sourceLocation: .active,
                    destinationLocation: .archive,
                    payloadDigest: DeletionGate.fingerprint(data),
                    phase: .prepared
                )
                var moved = false
                do {
                    try persistPendingSessionMove(transaction)
                    try fm.moveItem(at: src, to: dst)
                    moved = true
                    try fsyncDirectory(src.deletingLastPathComponent())
                    try fsyncDirectory(dst.deletingLastPathComponent())
                    try persistPendingSessionMove(transaction.withPhase(.moved))
                    try persistPendingSessionMove(transaction.withPhase(.committed))
                    try removePendingSessionMove(transaction)
                } catch {
                    if !moved { try? removePendingSessionMove(transaction) }
                    throw error
                }
            }

        }
    }

    /// Move an archived session back to the active list.
    /// Throws `notArchived` when the session isn't in the archive.
    public func restore(sessionID: String) throws {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            try lock.withLock {
                try rejectPendingSessionMovesUnlocked()
                let fm = FileManager.default
                guard isSafePathComponent(sessionID) else {
                    throw SessionManagerError.notArchived(sessionID)
                }
                let src = archiveDirectory.appendingPathComponent("\(sessionID).json")
                guard fm.fileExists(atPath: src.path) else {
                    throw SessionManagerError.notArchived(sessionID)
                }
                let dst = store.sessionsDirectory.appendingPathComponent("\(sessionID).json")
                guard let data = try? PersistenceTransactionFence.data(
                    at: src,
                    domain: store.persistenceDomain
                ) else {
                    throw SessionManagerError.notArchived(sessionID)
                }
                let transaction = PendingSessionMove(
                    operationID: UUID(),
                    targetID: sessionID,
                    scopeID: "session:\(sessionID):archive",
                    sourceLocation: .archive,
                    destinationLocation: .active,
                    payloadDigest: DeletionGate.fingerprint(data),
                    phase: .prepared
                )
                var moved = false
                do {
                    try persistPendingSessionMove(transaction)
                    try fm.moveItem(at: src, to: dst)
                    moved = true
                    try fsyncDirectory(src.deletingLastPathComponent())
                    try fsyncDirectory(dst.deletingLastPathComponent())
                    try persistPendingSessionMove(transaction.withPhase(.moved))
                    try persistPendingSessionMove(transaction.withPhase(.committed))
                    try removePendingSessionMove(transaction)
                } catch {
                    if !moved { try? removePendingSessionMove(transaction) }
                    throw error
                }
            }

        }
    }

    // MARK: - Retention cleanup

    /// Delete every session (active or archived) whose `updatedAt` is older
    /// than `days` days. Unread badges for deleted sessions are cleared.
    ///
    /// - Parameter days: retention window in days; must be >= 1 and
    ///   resolvable by the current calendar.
    /// - Returns: the number of deleted sessions.
    /// - Throws: `invalidRetention` for windows < 1; `unresolvableRetentionWindow`
    ///   when the calendar cannot resolve the cutoff. In the latter case the
    ///   purge is fail-closed and deletes nothing (D-STORAGE-04).
    @discardableResult
    public func purgeOld(days: Int) throws -> Int {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            guard days >= 1 else {
                throw SessionManagerError.invalidRetention(days)
            }
            let calendar = Calendar.current
            let now = Date()
            // Fail closed: an unresolvable cutoff must never degrade to
            // `Date()` ("keep nothing"), which would delete every active and
            // archived session for an unusably large configured window. A
            // cutoff outside the real-world `Date` domain (before
            // `Date.distantPast`) counts as unresolvable even when the
            // calendar itself does not return nil (D-STORAGE-04).
            guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now),
                  cutoff >= Date.distantPast else {
                throw SessionManagerError.unresolvableRetentionWindow(days: days)
            }
            var staleIDs: [String] = []
            var seen = Set<String>()

            // Snapshot both locations before deleting. The deletion service takes
            // the manager lock while validating each target, so purge must not
            // hold that non-recursive lock across the service call.
            for session in store.listSessions() where session.updatedAt < cutoff {
                if seen.insert(session.id).inserted {
                    staleIDs.append(session.id)
                }
            }
            for session in archivedSessions() where session.updatedAt < cutoff {
                if seen.insert(session.id).inserted {
                    staleIDs.append(session.id)
                }
            }

            let deletionService = SessionDeletionService(manager: self)
            for id in staleIDs {
                let intent = try deletionService.preview(sessionID: id)
                let confirmed = intent
                    .withFirstConfirmation("保留策略已确认删除")
                    .withSecondConfirmation("保留策略已确认删除")
                _ = try deletionService.delete(confirmed)
            }
            return staleIDs.count

        }
    }

    /// Explicit startup/repair seam for active/archive move markers. A marker
    /// is removed only when the before/after layout and exact payload digest
    /// are provable; ambiguous bytes remain in place and keep later moves
    /// fenced by `recoveryRequired`.
    @discardableResult
    public func recoverPendingTransactions() throws -> Int {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            try lock.withLock {
                let pending = try pendingSessionMovesUnlocked()
                guard !pending.isEmpty else { return 0 }
                var removable: [PendingSessionMove] = []
                for transaction in pending {
                    let source = url(for: transaction.sourceLocation, targetID: transaction.targetID)
                    let destination = url(for: transaction.destinationLocation, targetID: transaction.targetID)
                    let sourceMatches = try matches(transaction.payloadDigest, at: source)
                    let destinationMatches = try matches(transaction.payloadDigest, at: destination)
                    switch transaction.phase {
                    case .prepared where sourceMatches && !FileManager.default.fileExists(atPath: destination.path):
                        removable.append(transaction)
                    case .moved where !FileManager.default.fileExists(atPath: source.path) && destinationMatches:
                        removable.append(transaction)
                    case .committed where !FileManager.default.fileExists(atPath: source.path) && destinationMatches:
                        removable.append(transaction)
                    default:
                        throw SessionManagerError.recoveryRequired(transaction.operationID.uuidString)
                    }
                }
                for transaction in removable {
                    try removePendingSessionMove(transaction)
                }
                return removable.count
            }
        }
    }

    // MARK: - Internals

    private var pendingSessionMoveDirectory: URL { store.sessionsDirectory }

    private func url(for location: SessionMoveLocation, targetID: String) -> URL {
        switch location {
        case .active:
            return store.sessionsDirectory.appendingPathComponent("\(targetID).json")
        case .archive:
            return archiveDirectory.appendingPathComponent("\(targetID).json")
        }
    }

    private func rejectPendingSessionMovesUnlocked() throws {
        let pending = try pendingSessionMovesUnlocked()
        guard let first = pending.first else { return }
        throw SessionManagerError.recoveryRequired(first.operationID.uuidString)
    }

    private func pendingSessionMovesUnlocked() throws -> [PendingSessionMove] {
        guard FileManager.default.fileExists(atPath: pendingSessionMoveDirectory.path) else {
            return []
        }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: pendingSessionMoveDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw SessionManagerError.recoveryRequired("无法读取会话移动事务")
        }
        var result: [PendingSessionMove] = []
        for file in files where file.lastPathComponent.hasPrefix(Self.pendingMovePrefix) {
            guard file.lastPathComponent.hasSuffix(Self.pendingMoveSuffix) else {
                throw SessionManagerError.recoveryRequired(file.lastPathComponent)
            }
            let idStart = file.lastPathComponent.index(
                file.lastPathComponent.startIndex,
                offsetBy: Self.pendingMovePrefix.count
            )
            let idEnd = file.lastPathComponent.index(
                file.lastPathComponent.endIndex,
                offsetBy: -Self.pendingMoveSuffix.count
            )
            guard let operationID = UUID(uuidString: String(file.lastPathComponent[idStart..<idEnd])),
                  let data = try? PersistenceTransactionFence.data(
                      at: file,
                      domain: store.persistenceDomain
                  ),
                  let transaction = try? JSONDecoder().decode(PendingSessionMove.self, from: data),
                  markerKeysAreCanonical(data),
                  transaction.operationID == operationID,
                  isSafePathComponent(transaction.targetID),
                  transaction.scopeID == "session:\(transaction.targetID):\(transaction.sourceLocation.rawValue)",
                  transaction.sourceLocation != transaction.destinationLocation,
                  transaction.payloadDigest.count == 64,
                  transaction.payloadDigest.allSatisfy({ $0.isHexDigit && $0.isLowercase || $0.isNumber }) else {
                throw SessionManagerError.recoveryRequired(file.lastPathComponent)
            }
            result.append(transaction)
        }
        return result.sorted { $0.operationID.uuidString < $1.operationID.uuidString }
    }

    private func persistPendingSessionMove(_ transaction: PendingSessionMove) throws {
        let file = pendingURL(for: transaction.operationID)
        let data = try JSONEncoder().encode(transaction)
        try data.write(to: file, options: .atomic)
        guard fsyncFile(file) else {
            throw SessionManagerError.recoveryRequired(transaction.operationID.uuidString)
        }
        try fsyncDirectory(pendingSessionMoveDirectory)
    }

    private func removePendingSessionMove(_ transaction: PendingSessionMove) throws {
        let file = pendingURL(for: transaction.operationID)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        try fsyncDirectory(pendingSessionMoveDirectory)
    }

    private func pendingURL(for operationID: UUID) -> URL {
        pendingSessionMoveDirectory.appendingPathComponent(
            "\(Self.pendingMovePrefix)\(operationID.uuidString)\(Self.pendingMoveSuffix)"
        )
    }

    private func matches(_ digest: String, at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? PersistenceTransactionFence.data(
                  at: url,
                  domain: store.persistenceDomain
              ) else { return false }
        return DeletionGate.fingerprint(data) == digest
    }

    private func markerKeysAreCanonical(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return Set(object.keys) == [
            "operationID", "targetID", "scopeID", "sourceLocation",
            "destinationLocation", "payloadDigest", "phase"
        ]
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
        guard descriptor >= 0 else {
            throw SessionManagerError.recoveryRequired(url.path)
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw SessionManagerError.recoveryRequired(url.path)
        }
    }

    private func archivedSessionsUnlocked() -> [ChatSession] {
        let decoder = JSONDecoder()
        guard let files = try? PersistenceTransactionFence.children(at: archiveDirectory, domain: store.persistenceDomain).filter({ !$0.lastPathComponent.hasPrefix(".") }) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? PersistenceTransactionFence.data(at: url, domain: store.persistenceDomain),
                      let session = try? decoder.decode(ChatSession.self, from: data)
                else { return nil }
                return session
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Errors

public enum SessionManagerError: LocalizedError, Equatable, Sendable {
    case sessionNotFound(String)
    case notArchived(String)
    case alreadyArchived(String)
    case invalidRetention(Int)
    case unresolvableRetentionWindow(days: Int)
    case duplicateSessionIdentity(String)
    case staleManagerFact(expected: SessionManagerFact, actual: SessionManagerFact?)
    case recoveryRequired(String)

    /// Public copy describes recovery without leaking storage paths, session
    /// identities or manager facts carried for the diagnostic/logging owner.
    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "目标会话已被移走或删除。请刷新会话列表后重试。"
        case .notArchived:
            return "会话当前不在归档中。请刷新归档列表后重试。"
        case .alreadyArchived:
            return "会话已经归档。请在归档列表中查看。"
        case .invalidRetention:
            return "保留天数无效。请设置大于零的保留天数。"
        case .unresolvableRetentionWindow:
            return "无法计算保留期限。请缩短保留天数后重试。"
        case .duplicateSessionIdentity:
            return "会话记录重复。请刷新列表，仍失败时到设置中的日志查看详情。"
        case .staleManagerFact:
            return "会话状态已变化，本次操作未执行。请刷新后重试。"
        case .recoveryRequired:
            return "会话存储需要恢复。请重新打开应用，仍失败时到设置中的日志查看详情。"
        }
    }
}
