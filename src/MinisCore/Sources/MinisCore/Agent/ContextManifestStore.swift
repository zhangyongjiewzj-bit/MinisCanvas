import Foundation
import Darwin

/// Versioned, durable context manifest and receipt journal owned by the application composition root.
/// A repeated write with the same run ID is idempotent only when its payload is identical.
public struct ContextManifest: Sendable, Equatable, Codable {
    public static let currentVersion = 1
    public let version: Int
    public let snapshot: ConversationContextSnapshotV1
    public let entries: [Entry]
    /// The execution scope that authorized this manifest. Legacy manifests
    /// may omit it, but production-bound writes must provide it explicitly.
    public let scopeIdentity: AgentExecutionScopeIdentity?

    public struct Entry: Sendable, Equatable, Codable {
        public let identifier: String
        public let tokenCost: Int
        public let level: ContextItem.Level
        public let scope: String
        public let provenance: String
        public let contentHash: String
        public let required: Bool
        public let version: Int

        public init(identifier: String, tokenCost: Int, level: ContextItem.Level = .l3,
                    scope: String = "conversation", provenance: String = "local", contentHash: String = "",
                    required: Bool = false, version: Int = ContextManifest.currentVersion) {
            self.identifier = identifier; self.tokenCost = tokenCost; self.level = level
            self.scope = scope; self.provenance = provenance; self.contentHash = contentHash
            self.required = required; self.version = version
        }
    }

    public init(
        snapshot: ConversationContextSnapshotV1,
        entries: [Entry],
        version: Int = ContextManifest.currentVersion,
        scopeIdentity: AgentExecutionScopeIdentity? = nil
    ) {
        self.version = version
        self.snapshot = snapshot
        self.entries = entries
        self.scopeIdentity = scopeIdentity
    }
}

public struct ContextManifestReceipt: Sendable, Equatable, Codable {
    public let runID: String
    public let requestedBudget: Int
    public let usedBudget: Int
    public let droppedEntryIDs: [String]

    public init(runID: String, requestedBudget: Int, usedBudget: Int, droppedEntryIDs: [String]) {
        self.runID = runID
        self.requestedBudget = requestedBudget
        self.usedBudget = usedBudget
        self.droppedEntryIDs = droppedEntryIDs
    }
}

public enum ContextManifestStoreError: Error, Equatable, Sendable {
    case invalidManifest
    case conflictingReceipt
    case persistenceFailed
    case deletionRequiresProvenance
    case deletionConflict
    case staleWrite
    case missingScopeIdentity
    case invalidScopeIdentity
    case scopeMismatch
    case scopeDrift
}

public struct ContextManifestDeletionReceipt: Sendable, Equatable, Codable {
    public let runID: String
    public let confirmationID: String
    public let actorID: String
    public let deletedAt: Date
    /// The exact non-content source identity that was confirmed for deletion.
    /// This is optional only for decoding pre-provenance tombstones; those
    /// legacy tombstones are intentionally not replayable.
    public let provenance: MemoryProvenance?

    public init(
        runID: String,
        confirmationID: String,
        actorID: String,
        deletedAt: Date,
        provenance: MemoryProvenance? = nil
    ) {
        self.runID = runID
        self.confirmationID = confirmationID
        self.actorID = actorID
        self.deletedAt = deletedAt
        self.provenance = provenance
    }
}

public struct ContextManifestPersistenceDiagnostic: Sendable, Equatable {
    public let operation: String
    public let reason: String
    public let message: String

    public init(operation: String, reason: String, message: String) {
        self.operation = operation
        self.reason = reason
        self.message = message
    }
}

public final class ContextManifestStore: @unchecked Sendable {
    private static let schemaVersion = 1
    private static let maxEntryCount = 1_024
    private static let maxDroppedEntryCount = 1_024
    private static let maxIdentityUTF8Bytes = 256
    private static let maxContentHashUTF8Bytes = 256

    private final class PersistenceLockRegistry: @unchecked Sendable {
        private let registryLock = NSLock()
        private var locks: [String: NSRecursiveLock] = [:]

        func lock(for path: String) -> NSRecursiveLock {
            registryLock.lock()
            defer { registryLock.unlock() }
            if let lock = locks[path] {
                return lock
            }
            let lock = NSRecursiveLock()
            locks[path] = lock
            return lock
        }
    }

    private static let persistenceLockRegistry = PersistenceLockRegistry()

    private struct Record: Codable, Equatable {
        let manifest: ContextManifest
        let receipt: ContextManifestReceipt
        let provenance: MemoryProvenance?
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let records: [String: Record]
        let deletions: [String: ContextManifestDeletionReceipt]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, records, deletions
        }

        init(schemaVersion: Int, records: [String: Record], deletions: [String: ContextManifestDeletionReceipt]) {
            self.schemaVersion = schemaVersion
            self.records = records
            self.deletions = deletions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            records = try container.decode([String: Record].self, forKey: .records)
            deletions = try container.decodeIfPresent(
                [String: ContextManifestDeletionReceipt].self,
                forKey: .deletions
            ) ?? [:]
        }
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var records: [String: Record]
    /// Historical delimiter-based snapshots remain on disk as inert run IDs.
    private var legacyRunIDs: Set<String>
    private var deletions: [String: ContextManifestDeletionReceipt]
    private var acceptingWrites: Bool
    private var persistenceDiagnostic: ContextManifestPersistenceDiagnostic?
    private var persistenceBaseline: Data?

    public init() {
        fileURL = nil
        records = [:]
        legacyRunIDs = []
        deletions = [:]
        acceptingWrites = true
        persistenceDiagnostic = nil
        persistenceBaseline = nil
    }

    public init(persistenceURL: URL) throws {
        let standardizedURL = persistenceURL.standardizedFileURL
        fileURL = standardizedURL
        records = [:]
        legacyRunIDs = []
        deletions = [:]
        acceptingWrites = true
        persistenceDiagnostic = nil
        persistenceBaseline = nil
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
            return
        }

        let data: Data
        do {
            data = try Self.withPersistenceLock(for: standardizedURL) {
                try Data(contentsOf: standardizedURL)
            }
        } catch {
            throw ContextManifestStoreError.persistenceFailed
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion else {
                persistenceDiagnostic = Self.recoveryDiagnostic(reason: "unsupported-schema")
                acceptingWrites = false
                return
            }
            var legacy: Set<String> = []
            var bindingsBySnapshotID: [String: Set<ConversationContextSnapshotV1>] = [:]
            var legacySnapshotIDs: Set<String> = []
            var rawRecords: [String: Any]?
            try envelope.records.forEach { key, record in
                guard key == record.receipt.runID else {
                    throw ContextManifestStoreError.invalidManifest
                }
                let snapshot = record.manifest.snapshot
                let isLegacy = snapshot.isRecognizedLegacyProductionSnapshot
                if isLegacy {
                    if rawRecords == nil {
                        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        rawRecords = root?["records"] as? [String: Any]
                    }
                    guard let originalJSON = rawRecords?[key],
                          LegacyContextJSON.roundTripsWithoutFieldLoss(
                            record, originalJSON: originalJSON
                          ) else {
                        throw ContextManifestStoreError.invalidManifest
                    }
                    try Self.validate(record, persistedLegacy: true)
                    legacy.insert(key)
                } else {
                    try Self.validate(record)
                }
                let priorBindings = bindingsBySnapshotID[snapshot.snapshotID] ?? []
                if (isLegacy || legacySnapshotIDs.contains(snapshot.snapshotID))
                    && priorBindings.contains(where: { $0 != snapshot }) {
                    throw ContextManifestStoreError.invalidManifest
                }
                bindingsBySnapshotID[snapshot.snapshotID, default: []].insert(snapshot)
                if isLegacy { legacySnapshotIDs.insert(snapshot.snapshotID) }
            }
            try envelope.deletions.forEach { key, deletion in
                guard key == deletion.runID,
                      Self.validIdentity(deletion.runID),
                      Self.validIdentity(deletion.confirmationID),
                      Self.validIdentity(deletion.actorID) else {
                    throw ContextManifestStoreError.invalidManifest
                }
                if let provenance = deletion.provenance, !provenance.isValid {
                    throw ContextManifestStoreError.invalidManifest
                }
            }
            if !legacy.isEmpty {
                let originalJSON = try JSONSerialization.jsonObject(with: data)
                guard LegacyContextJSON.roundTripsWithoutFieldLoss(
                    envelope, originalJSON: originalJSON
                ) else {
                    throw ContextManifestStoreError.invalidManifest
                }
            }
            records = envelope.records
            legacyRunIDs = legacy
            deletions = envelope.deletions
            persistenceBaseline = data
        } catch let error as ContextManifestStoreError {
            guard error == .invalidManifest else { throw error }
            persistenceDiagnostic = Self.recoveryDiagnostic(reason: "invalid-record")
            acceptingWrites = false
        } catch {
            persistenceDiagnostic = Self.recoveryDiagnostic(reason: "invalid-payload")
            acceptingWrites = false
        }
    }

    public func record(manifest: ContextManifest, receipt: ContextManifestReceipt) throws -> ContextManifestReceipt {
        try record(manifest: manifest, receipt: receipt, provenance: nil)
    }

    /// Production-bound write seam. The caller and manifest must carry one
    /// identical, complete scope identity; no partial or drifted context can
    /// enter the durable consumer lane.
    public func record(
        manifest: ContextManifest,
        receipt: ContextManifestReceipt,
        scopeIdentity: AgentExecutionScopeIdentity,
        provenance: MemoryProvenance? = nil
    ) throws -> ContextManifestReceipt {
        try Self.validate(scopeIdentity: scopeIdentity, manifest: manifest)
        return try record(manifest: manifest, receipt: receipt, provenance: provenance)
    }

    public func record(
        manifest: ContextManifest,
        receipt: ContextManifestReceipt,
        provenance: MemoryProvenance?
    ) throws -> ContextManifestReceipt {
        try Self.validate(Record(manifest: manifest, receipt: receipt, provenance: provenance))
        lock.lock(); defer { lock.unlock() }
        guard acceptingWrites else { throw ContextManifestStoreError.persistenceFailed }
        guard deletions[receipt.runID] == nil else { throw ContextManifestStoreError.staleWrite }
        guard !legacyRunIDs.contains(receipt.runID) else {
            throw ContextManifestStoreError.conflictingReceipt
        }
        if let existing = records[receipt.runID] {
            guard existing.manifest == manifest, existing.receipt == receipt,
                  existing.provenance == provenance else { throw ContextManifestStoreError.conflictingReceipt }
            return existing.receipt
        }
        let before = records
        records[receipt.runID] = Record(manifest: manifest, receipt: receipt, provenance: provenance)
        do {
            try persist()
            return receipt
        } catch {
            records = before
            throw error
        }
    }

    public func manifest(runID: String) -> ContextManifest? {
        lock.lock(); defer { lock.unlock() }
        guard !legacyRunIDs.contains(runID) else { return nil }
        return records[runID]?.manifest
    }

    /// Production-bound read seam. A missing, mismatched, or drifted scope is
    /// rejected before the manifest is handed to an execution consumer.
    public func manifest(
        runID: String,
        scopeIdentity: AgentExecutionScopeIdentity
    ) throws -> ContextManifest? {
        lock.lock()
        let manifest = legacyRunIDs.contains(runID) ? nil : records[runID]?.manifest
        lock.unlock()
        guard let manifest else { return nil }
        try Self.validate(scopeIdentity: scopeIdentity, manifest: manifest)
        return manifest
    }

    public func validate(
        manifest: ContextManifest,
        for scopeIdentity: AgentExecutionScopeIdentity
    ) throws {
        try Self.validate(scopeIdentity: scopeIdentity, manifest: manifest)
    }

    public func receipt(runID: String) -> ContextManifestReceipt? {
        lock.lock(); defer { lock.unlock() }
        guard !legacyRunIDs.contains(runID) else { return nil }
        return records[runID]?.receipt
    }

    public func provenance(runID: String) -> MemoryProvenance? {
        lock.lock(); defer { lock.unlock() }
        guard !legacyRunIDs.contains(runID) else { return nil }
        return records[runID]?.provenance
    }

    public func deletionReceipt(runID: String) -> ContextManifestDeletionReceipt? {
        lock.lock(); defer { lock.unlock() }
        return deletions[runID]
    }

    /// Deletes a persisted manifest only with a provenance-bound, explicit
    /// confirmation. A tombstone blocks stale replays after restart.
    @discardableResult
    public func delete(
        runID: String,
        confirmation: MemoryDeleteConfirmation,
        now: Date = Date()
    ) throws -> ContextManifestDeletionReceipt {
        lock.lock(); defer { lock.unlock() }
        guard !legacyRunIDs.contains(runID) else {
            throw ContextManifestStoreError.deletionConflict
        }
        guard Self.validIdentity(runID),
              Self.validIdentity(confirmation.confirmationID),
              Self.validIdentity(confirmation.actorID) else {
            throw ContextManifestStoreError.deletionConflict
        }
        if let existing = deletions[runID] {
            guard existing.confirmationID == confirmation.confirmationID,
                  existing.actorID == confirmation.actorID,
                  confirmation.targetID == runID,
                  let provenance = existing.provenance,
                  provenance == confirmation.provenance else {
                throw ContextManifestStoreError.deletionConflict
            }
            return existing
        }
        guard let existing = records[runID], let provenance = existing.provenance else {
            throw ContextManifestStoreError.deletionRequiresProvenance
        }
        do {
            try confirmation.validate(
                targetID: runID,
                provenance: provenance,
                now: now
            )
        } catch {
            throw ContextManifestStoreError.deletionConflict
        }
        let receipt = ContextManifestDeletionReceipt(
            runID: runID,
            confirmationID: confirmation.confirmationID,
            actorID: confirmation.actorID,
            deletedAt: now,
            provenance: provenance
        )
        let beforeRecords = records
        let beforeDeletions = deletions
        records.removeValue(forKey: runID)
        deletions[runID] = receipt
        do {
            try persist()
            return receipt
        } catch {
            records = beforeRecords
            deletions = beforeDeletions
            throw error
        }
    }

    public func persistenceDiagnostics() -> ContextManifestPersistenceDiagnostic? {
        lock.lock(); defer { lock.unlock() }
        return persistenceDiagnostic
    }

    private static func recoveryDiagnostic(reason: String) -> ContextManifestPersistenceDiagnostic {
        ContextManifestPersistenceDiagnostic(
            operation: "recover",
            reason: reason,
            message: "context manifest recovery started with an empty store"
        )
    }

    private static func containsUnsafeIdentityScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: { scalar in
            let scalarValue = scalar.value
            return CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format
                || (0x202A...0x202E).contains(scalarValue)
                || (0x2066...0x2069).contains(scalarValue)
        })
    }

    private static func validIdentity(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == value
            && value.utf8.count <= maxIdentityUTF8Bytes
            && !containsUnsafeIdentityScalar(value)
    }

    private static func validContentHash(_ value: String) -> Bool {
        value.isEmpty || (
            validIdentity(value)
                && value.utf8.count <= maxContentHashUTF8Bytes
        )
    }

    private static func validScopeIdentity(_ scope: AgentExecutionScopeIdentity) -> Bool {
        [
            scope.sessionID,
            scope.workspaceID,
            scope.memoryScopeID,
            scope.skillsScopeID,
            scope.permissionsScopeID,
            scope.taskID,
            scope.budgetScopeID
        ].allSatisfy(validIdentity)
    }

    private static func totalTokenCost(_ entries: [ContextManifest.Entry]) -> Int? {
        var total = 0
        for entry in entries {
            let (next, overflowed) = total.addingReportingOverflow(entry.tokenCost)
            guard !overflowed else { return nil }
            total = next
        }
        return total
    }

    private static func validate(_ record: Record) throws {
        try validate(record, persistedLegacy: false)
    }

    private static func validate(
        _ record: Record,
        persistedLegacy: Bool
    ) throws {
        let manifest = record.manifest
        let receipt = record.receipt
        guard manifest.entries.count <= maxEntryCount,
              receipt.droppedEntryIDs.count <= maxDroppedEntryCount else {
            throw ContextManifestStoreError.invalidManifest
        }
        guard let totalTokenCost = Self.totalTokenCost(manifest.entries) else {
            throw ContextManifestStoreError.invalidManifest
        }
        let entryIdentifiers = manifest.entries.map(\.identifier)
        let droppedEntryIDs = receipt.droppedEntryIDs
        guard manifest.version == ContextManifest.currentVersion,
              Self.validIdentity(receipt.runID),
              (persistedLegacy
                ? manifest.snapshot.isRecognizedLegacyProductionSnapshot
                : manifest.snapshot.snapshotID == manifest.snapshot.canonicalSnapshotID()),
              receipt.requestedBudget >= 0,
              receipt.usedBudget >= 0,
              receipt.usedBudget == totalTokenCost,
              receipt.usedBudget <= receipt.requestedBudget,
              Set(entryIdentifiers).count == entryIdentifiers.count,
              Set(droppedEntryIDs).count == droppedEntryIDs.count,
              droppedEntryIDs.allSatisfy(Self.validIdentity),
              manifest.entries.allSatisfy({ entry in
                  entry.tokenCost >= 0
                      && entry.version == ContextItem.currentVersion
                      && Self.validIdentity(entry.identifier)
                      && Self.validIdentity(entry.scope)
                      && Self.validIdentity(entry.provenance)
                      && Self.validContentHash(entry.contentHash)
              }) else {
            throw ContextManifestStoreError.invalidManifest
        }
        if let provenance = record.provenance, !provenance.isValid {
            throw ContextManifestStoreError.invalidManifest
        }
        if let scopeIdentity = manifest.scopeIdentity, !Self.validScopeIdentity(scopeIdentity) {
            throw ContextManifestStoreError.invalidManifest
        }
        if let provenance = record.provenance,
           provenance.scope.memoryScope.sessionID != manifest.snapshot.sessionID {
            throw ContextManifestStoreError.invalidManifest
        }
    }

    private static func validate(
        scopeIdentity: AgentExecutionScopeIdentity,
        manifest: ContextManifest
    ) throws {
        guard Self.validScopeIdentity(scopeIdentity) else {
            throw ContextManifestStoreError.invalidScopeIdentity
        }
        guard let declared = manifest.scopeIdentity else {
            throw ContextManifestStoreError.missingScopeIdentity
        }
        guard Self.validScopeIdentity(declared) else {
            throw ContextManifestStoreError.invalidScopeIdentity
        }
        guard declared == scopeIdentity else {
            throw ContextManifestStoreError.scopeMismatch
        }
        guard manifest.snapshot.sessionID == scopeIdentity.sessionID else {
            throw ContextManifestStoreError.scopeMismatch
        }
        guard declared.fingerprint == scopeIdentity.fingerprint else {
            throw ContextManifestStoreError.scopeDrift
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.withPersistenceLock(for: fileURL) {
                if fileManager.fileExists(atPath: fileURL.path) {
                    let current = try Data(contentsOf: fileURL)
                    guard persistenceBaseline == current else {
                        throw ContextManifestStoreError.persistenceFailed
                    }
                } else {
                    guard persistenceBaseline == nil else {
                        throw ContextManifestStoreError.persistenceFailed
                    }
                }
                let data = try JSONEncoder().encode(Envelope(
                    schemaVersion: Self.schemaVersion,
                    records: records,
                    deletions: deletions
                ))
                try data.write(to: fileURL, options: [.atomic])
                persistenceBaseline = data
            }
        } catch {
            if let error = error as? ContextManifestStoreError {
                throw error
            }
            throw ContextManifestStoreError.persistenceFailed
        }
    }

    private static func withPersistenceLock<Result>(
        for fileURL: URL,
        _ body: () throws -> Result
    ) throws -> Result {
        let processLock = persistenceLockRegistry.lock(for: fileURL.standardizedFileURL.path)
        processLock.lock()
        defer { processLock.unlock() }

        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ContextManifestStoreError.persistenceFailed
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ContextManifestStoreError.persistenceFailed
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}
