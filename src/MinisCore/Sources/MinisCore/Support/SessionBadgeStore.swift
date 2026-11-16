import Foundation

/// Persistent per-session unread counts and execution-state projections.
///
/// Execution state is keyed by the complete session/task identity. A late
/// write from an older turn cannot replace the state currently shown for a
/// newer turn, even when both writes arrive after a relaunch.
public final class SessionBadgeStore: @unchecked Sendable {
    public static let shared = SessionBadgeStore()
    private static let maxRetirementEntries = 512

    /// Canonical execution source. `unread` remains separate until projection.
    public enum SourceStatus: String, Codable, Equatable, Sendable {
        case idle
        case running
        case failed
    }

    /// Stable four-state projection consumed by the session list.
    public enum Status: String, Codable, Equatable, Sendable {
        case idle
        case unread
        case running
        case failed
    }

    /// Identity attached to every execution projection.
    public struct SessionIdentity: Codable, Equatable, Hashable, Sendable {
        public let sessionID: String
        public let turnID: Int?
        public let taskID: String?
        /// Optional provider/lineage ownership prevents a reused session ID
        /// from accepting a badge projection from another runtime owner.
        public let providerID: String?
        public let lineageOwner: String?
        /// Monotonic transcript revision for stale terminal-event rejection.
        public let transcriptRevision: UInt64?

        public init(
            sessionID: String,
            turnID: Int? = nil,
            taskID: String? = nil,
            providerID: String? = nil,
            lineageOwner: String? = nil,
            transcriptRevision: UInt64? = nil
        ) {
            self.sessionID = sessionID
            self.turnID = turnID
            self.taskID = taskID
            self.providerID = providerID
            self.lineageOwner = lineageOwner
            self.transcriptRevision = transcriptRevision
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public let identity: SessionIdentity
        public let status: Status
        public let failureReason: String?
        public let updatedAt: Date

        public var sessionID: String { identity.sessionID }
        public var turnID: Int? { identity.turnID }
        public var taskID: String? { identity.taskID }

        public init(
            sessionID: String,
            turnID: Int? = nil,
            taskID: String? = nil,
            status: Status,
            failureReason: String? = nil,
            updatedAt: Date = Date(),
            providerID: String? = nil,
            lineageOwner: String? = nil,
            transcriptRevision: UInt64? = nil
        ) {
            self.init(
                identity: SessionIdentity(
                    sessionID: sessionID,
                    turnID: turnID,
                    taskID: taskID,
                    providerID: providerID,
                    lineageOwner: lineageOwner,
                    transcriptRevision: transcriptRevision
                ),
                status: status,
                failureReason: failureReason,
                updatedAt: updatedAt
            )
        }

        public init(
            identity: SessionIdentity,
            status: Status,
            failureReason: String? = nil,
            updatedAt: Date = Date()
        ) {
            self.identity = identity
            self.status = status
            self.failureReason = status == .failed ? failureReason : nil
            self.updatedAt = updatedAt
        }

        /// Preserve a separate unread bit for callers that have not yet
        /// projected it into the four-state status.
        public func presentation(unread: Bool = false) -> Presentation {
            let projectedStatus = status == .idle && unread ? .unread : status
            return Presentation(status: projectedStatus, failureReason: failureReason, identity: identity)
        }
    }

    /// Semantic rendering data. Symbols and labels carry state without color.
    public struct Presentation: Equatable, Sendable {
        public let status: Status
        public let failureReason: String?
        public let identity: SessionIdentity

        public init(
            status: Status,
            failureReason: String? = nil,
            identity: SessionIdentity = SessionIdentity(sessionID: "unknown")
        ) {
            self.status = status
            self.failureReason = failureReason
            self.identity = identity
        }

        public var systemImageName: String {
            switch status {
            case .failed: return "exclamationmark.triangle.fill"
            case .running: return "circle.dotted"
            case .unread: return "circle.fill"
            case .idle: return "circle"
            }
        }

        public var accessibilityLabel: String {
            switch status {
            case .failed: return "会话失败"
            case .running: return "会话生成中"
            case .unread: return "会话有未读消息"
            case .idle: return "会话空闲"
            }
        }

        public var helpText: String {
            switch status {
            case .failed:
                return failureReason.map { "生成失败：\($0)，点击重试" } ?? "生成失败，点击重试"
            case .running: return "生成中"
            case .unread: return "有未读消息"
            case .idle: return "空闲"
            }
        }

        public var isRetryable: Bool { status == .failed }
    }

    private let lock = NSLock()
    /// Orders same-instance snapshots through their completed file replacement.
    private let persistenceLock = NSLock()
    private let fileURL: URL
    private let beforePersistenceWrite: (@Sendable () -> Void)?
    private var counts: [String: Int] = [:]
    private var snapshots: [String: Snapshot] = [:]
    /// Exact interrupted source already recovered by the persistence producer.
    /// Kept with the badge so a late equal-time running render cannot revive it.
    private var recoveredRunning: [String: Snapshot] = [:]
    /// Reset fences survive relaunch so a late terminal event cannot recreate
    /// a removed child badge from an older timestamp.
    private var retiredAt: [String: Date] = [:]
    /// Preserve the removed owner so that a stale owner cannot reintroduce a
    /// badge with a newer wall-clock timestamp after the session is reset.
    private var retiredIdentity: [String: SessionIdentity] = [:]
    /// Timestamp floor retained when old per-session tombstones are compacted.
    /// It keeps older late events fail-closed without an unbounded map.
    private var retirementFloor: Date?

    /// - Parameter directory: Directory holding `badges.json`. A formal test
    ///   host defaults to the same verified Canvas root as AppMain's injected
    ///   badge store; an ordinary App process keeps
    ///   `~/Library/Application Support/MinisCanvas`.
    public convenience init(directory: URL? = nil) {
        self.init(directory: directory, beforePersistenceWrite: nil)
    }

    /// A controlled same-instance interleaving seam for the persistence test.
    init(directory: URL?, beforePersistenceWrite: (@Sendable () -> Void)?) {
        let dir = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("badges.json", isDirectory: false)
        self.beforePersistenceWrite = beforePersistenceWrite
        load()
    }

    private static func defaultDirectory() -> URL {
        if let formal = FormalTestIsolationPaths.currentOrFail() {
            return formal.minisCanvasDirectory
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MinisCanvas", isDirectory: true)
    }

    public func unreadCount(for sessionID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[sessionID] ?? 0
    }

    public func totalUnreadCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }

    public func unreadSessionIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(counts.filter { $0.value > 0 }.keys)
    }

    /// Return state for exactly this session; unknown IDs never fall back.
    public func snapshot(for sessionID: String) -> Snapshot? {
        guard Self.isValidSessionID(sessionID) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return snapshots[sessionID]
    }

    public func status(for sessionID: String) -> Status? {
        snapshot(for: sessionID)?.status
    }

    /// Project an execution source. Failed/running outrank unread; idle
    /// becomes unread only when the row has an unread message.
    @discardableResult
    public func project(
        identity: SessionIdentity,
        source: SourceStatus,
        unread: Bool = false,
        failureReason: String? = nil,
        updatedAt: Date = Date()
    ) -> Snapshot? {
        let status: Status
        switch source {
        case .failed: status = .failed
        case .running: status = .running
        case .idle: status = unread ? .unread : .idle
        }
        return project(identity: identity, status: status, failureReason: failureReason, updatedAt: updatedAt)
    }

    /// Project a fully resolved state. Stale identity/timestamp writes fail
    /// closed and return nil, so late task completion cannot change a row.
    @discardableResult
    public func project(
        identity: SessionIdentity,
        status: Status,
        failureReason: String? = nil,
        updatedAt: Date = Date()
    ) -> Snapshot? {
        guard Self.isValidIdentity(identity) else { return nil }
        let next = Snapshot(identity: identity, status: status, failureReason: failureReason, updatedAt: updatedAt)
        lock.lock()
        if let floor = retirementFloor, updatedAt <= floor {
            lock.unlock()
            return nil
        }
        if let retirement = retiredAt[identity.sessionID], updatedAt <= retirement {
            lock.unlock()
            return nil
        }
        if let retired = retiredIdentity[identity.sessionID],
           identity.providerID == retired.providerID,
           identity.lineageOwner == retired.lineageOwner,
           identity.turnID == retired.turnID,
           identity.taskID == retired.taskID {
            lock.unlock()
            return nil
        }
        if status == .running,
           let recovered = recoveredRunning[identity.sessionID],
           recovered.identity == identity, updatedAt <= recovered.updatedAt {
            lock.unlock()
            return nil
        }
        let previous = snapshots[identity.sessionID]
        // Rendering the same source again must not rewrite the entire badge
        // ledger. Include the timestamp in this comparison: a later source
        // observation still advances the stale-event fence below.
        if let previous, previous == next {
            lock.unlock()
            return previous
        }
        guard Self.accept(next, replacing: previous) else {
            lock.unlock()
            return nil
        }
        snapshots[identity.sessionID] = next
        if let recovered = recoveredRunning[identity.sessionID],
           identity != recovered.identity || updatedAt > recovered.updatedAt {
            recoveredRunning.removeValue(forKey: identity.sessionID)
        }
        retiredAt.removeValue(forKey: identity.sessionID)
        retiredIdentity.removeValue(forKey: identity.sessionID)
        lock.unlock()
        persist()
        return next
    }

    /// The persistence producer confirms that this exact interrupted running
    /// source was restored as idle without redispatch. This is not a render
    /// downgrade: the ordinary same-time status ordering remains unchanged.
    @discardableResult
    public func recoverInterruptedRunning(
        identity: SessionIdentity, updatedAt: Date, unread: Bool
    ) -> Snapshot? {
        guard Self.isValidIdentity(identity) else { return nil }
        let interrupted = Snapshot(identity: identity, status: .running, updatedAt: updatedAt)
        lock.lock()
        if let floor = retirementFloor, updatedAt <= floor {
            lock.unlock()
            return nil
        }
        if let retirement = retiredAt[identity.sessionID], updatedAt <= retirement {
            lock.unlock()
            return nil
        }
        if let retired = retiredIdentity[identity.sessionID],
           identity.providerID == retired.providerID,
           identity.lineageOwner == retired.lineageOwner,
           identity.turnID == retired.turnID, identity.taskID == retired.taskID {
            lock.unlock()
            return nil
        }
        guard snapshots[identity.sessionID] == interrupted else {
            lock.unlock()
            return nil
        }
        let recovered = Snapshot(
            identity: identity, status: unread ? .unread : .idle, updatedAt: updatedAt
        )
        snapshots[identity.sessionID] = recovered
        recoveredRunning[identity.sessionID] = interrupted
        lock.unlock()
        persist()
        return recovered
    }

    /// Convenience overload for callers that only have a session identity.
    @discardableResult
    public func project(
        sessionID: String,
        source: SourceStatus,
        failureReason: String? = nil,
        updatedAt: Date = Date()
    ) -> Snapshot? {
        project(
            identity: SessionIdentity(sessionID: sessionID),
            source: source,
            failureReason: failureReason,
            updatedAt: updatedAt
        )
    }

    @discardableResult
    public func increment(for sessionID: String) -> Int {
        lock.lock()
        let next = (counts[sessionID] ?? 0) + 1
        counts[sessionID] = next
        lock.unlock()
        persist()
        return next
    }

    @discardableResult
    public func decrement(for sessionID: String) -> Int {
        lock.lock()
        let next = max(0, (counts[sessionID] ?? 0) - 1)
        if next == 0 { counts.removeValue(forKey: sessionID) } else { counts[sessionID] = next }
        lock.unlock()
        persist()
        return next
    }

    public func reset(for sessionID: String) {
        guard Self.isValidSessionID(sessionID) else { return }
        lock.lock()
        recoveredRunning.removeValue(forKey: sessionID)
        retiredAt[sessionID] = max(retiredAt[sessionID] ?? .distantPast, Date())
        if let identity = snapshots[sessionID] {
            retiredIdentity[sessionID] = identity.identity
        }
        let didRetire = retiredAt[sessionID] != nil
        let removedCount = counts.removeValue(forKey: sessionID) != nil
        let removedSnapshot = snapshots.removeValue(forKey: sessionID) != nil
        let changed = removedCount || removedSnapshot
        compactRetirementsUnlocked()
        lock.unlock()
        if changed || didRetire { persist() }
    }

    public func resetAll() {
        lock.lock()
        let empty = counts.isEmpty && snapshots.isEmpty
        let now = Date()
        let sessionIDs = Set(counts.keys).union(snapshots.keys)
        for sessionID in sessionIDs {
            retiredAt[sessionID] = max(retiredAt[sessionID] ?? .distantPast, now)
            if let identity = snapshots[sessionID] {
                retiredIdentity[sessionID] = identity.identity
            }
        }
        let didRetire = !sessionIDs.isEmpty
        counts.removeAll()
        snapshots.removeAll()
        recoveredRunning.removeAll()
        compactRetirementsUnlocked()
        lock.unlock()
        if !empty || didRetire { persist() }
    }

    // MARK: - Ordering and persistence

    private func compactRetirementsUnlocked() {
        let overflow = retiredAt.count - Self.maxRetirementEntries
        guard overflow > 0 else { return }
        let oldest = retiredAt.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.key < $1.key
        }.prefix(overflow)
        for (sessionID, timestamp) in oldest {
            retiredAt.removeValue(forKey: sessionID)
            retiredIdentity.removeValue(forKey: sessionID)
            retirementFloor = max(retirementFloor ?? .distantPast, timestamp)
        }
    }

    private static func accept(_ incoming: Snapshot, replacing current: Snapshot?) -> Bool {
        guard let current else { return true }
        guard incoming.identity.sessionID == current.identity.sessionID else { return false }
        guard incoming.identity.providerID == current.identity.providerID,
              incoming.identity.lineageOwner == current.identity.lineageOwner else {
            return false
        }
        if incoming.updatedAt < current.updatedAt { return false }

        if let incomingRevision = incoming.identity.transcriptRevision,
           let currentRevision = current.identity.transcriptRevision {
            if incomingRevision < currentRevision { return false }
            if incomingRevision > currentRevision { return true }
        } else if current.identity.transcriptRevision != nil {
            return incoming.updatedAt > current.updatedAt
        }

        if let incomingTurn = incoming.turnID, let currentTurn = current.turnID {
            if incomingTurn < currentTurn { return false }
            if incomingTurn > currentTurn { return true }
        } else if current.turnID != nil && incoming.turnID == nil {
            return incoming.updatedAt > current.updatedAt
        }

        if incoming.identity == current.identity {
            if incoming.updatedAt > current.updatedAt { return true }
            // D-SESSION-05 (DEV-333 option B): mark-read keeps the same identity
            // and the same updatedAt as the preceding unread projection, so the
            // clear-direction downgrade (unread -> idle) at an identical
            // timestamp must pass. Late events are still rejected above;
            // failed/running priorities and every other rule are unchanged.
            if incoming.updatedAt == current.updatedAt,
               current.status == .unread,
               incoming.status == .idle {
                return true
            }
            return priority(incoming.status) >= priority(current.status)
        }

        // Distinct tasks in one turn are ordered by source time. Equal times
        // are ambiguous and therefore fail closed.
        return incoming.updatedAt > current.updatedAt
    }

    private static func priority(_ status: Status) -> Int {
        switch status {
        case .failed: return 4
        case .running: return 3
        case .unread: return 2
        case .idle: return 1
        }
    }

    private struct PersistedState: Codable {
        let schemaVersion: Int
        let counts: [String: Int]
        let snapshots: [String: Snapshot]
        let recoveredRunning: [String: Snapshot]
        let retiredAt: [String: Date]
        let retiredIdentity: [String: SessionIdentity]
        let retirementFloor: Date?

        init(
            counts: [String: Int],
            snapshots: [String: Snapshot],
            recoveredRunning: [String: Snapshot],
            retiredAt: [String: Date],
            retiredIdentity: [String: SessionIdentity],
            retirementFloor: Date?
        ) {
            schemaVersion = 2
            self.counts = counts
            self.snapshots = snapshots
            self.recoveredRunning = recoveredRunning
            self.retiredAt = retiredAt
            self.retiredIdentity = retiredIdentity
            self.retirementFloor = retirementFloor
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, counts, snapshots, recoveredRunning, retiredAt, retiredIdentity, retirementFloor
        }

        private struct RecoveryRecord: Decodable {
            let snapshot: Snapshot?

            init(from decoder: Decoder) throws {
                snapshot = try? Snapshot(from: decoder)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            counts = try container.decode([String: Int].self, forKey: .counts)
            snapshots = try container.decode([String: Snapshot].self, forKey: .snapshots)
            // A corrupt optional recovery marker must not discard the valid
            // canonical badge ledger. Old archives have no marker key.
            let recoveryRecords = (try? container.decodeIfPresent(
                [String: RecoveryRecord].self, forKey: .recoveredRunning
            )) ?? [:]
            recoveredRunning = recoveryRecords.compactMapValues(\.snapshot)
            retiredAt = try container.decodeIfPresent([String: Date].self, forKey: .retiredAt) ?? [:]
            retiredIdentity = try container.decodeIfPresent(
                [String: SessionIdentity].self,
                forKey: .retiredIdentity
            ) ?? [:]
            retirementFloor = try container.decodeIfPresent(Date.self, forKey: .retirementFloor)
        }
    }

    private func persist() {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        lock.lock()
        let state = PersistedState(
            counts: counts,
            snapshots: snapshots,
            recoveredRunning: recoveredRunning,
            retiredAt: retiredAt,
            retiredIdentity: retiredIdentity,
            retirementFloor: retirementFloor
        )
        lock.unlock()
        beforePersistenceWrite?()
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        lock.lock()
        if let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            counts = decoded.counts.filter { Self.isValidSessionID($0.key) && $0.value > 0 }
            snapshots = decoded.snapshots.filter {
                Self.isValidSessionID($0.key) && $0.key == $0.value.identity.sessionID
            }
            recoveredRunning = decoded.recoveredRunning.filter { sessionID, interrupted in
                guard Self.isValidIdentity(interrupted.identity),
                      sessionID == interrupted.sessionID,
                      interrupted.status == .running, interrupted.failureReason == nil,
                      let current = snapshots[sessionID] else { return false }
                return current.identity == interrupted.identity
                    && current.updatedAt == interrupted.updatedAt && current.status != .running
            }
            retiredAt = decoded.retiredAt.filter { Self.isValidSessionID($0.key) }
            retiredIdentity = decoded.retiredIdentity.filter {
                Self.isValidSessionID($0.key) && $0.key == $0.value.sessionID
            }
            retirementFloor = decoded.retirementFloor
            compactRetirementsUnlocked()
        } else if let legacy = try? JSONDecoder().decode([String: Int].self, from: data) {
            // Compatibility with the original unread-only badges.json.
            counts = legacy.filter { Self.isValidSessionID($0.key) && $0.value > 0 }
        }
        lock.unlock()
    }

    private static func isValidSessionID(_ sessionID: String) -> Bool {
        !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isValidIdentity(_ identity: SessionIdentity) -> Bool {
        guard isValidSessionID(identity.sessionID) else { return false }
        if let providerID = identity.providerID, !isValidSessionID(providerID) {
            return false
        }
        if let lineageOwner = identity.lineageOwner, !isValidSessionID(lineageOwner) {
            return false
        }
        return true
    }
}
