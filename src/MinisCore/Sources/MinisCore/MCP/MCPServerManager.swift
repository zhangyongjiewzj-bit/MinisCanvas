import Foundation
import Darwin

public enum MCPServerDeletionError: Error, Codable, Equatable, Sendable {
    case legacyEntryDisabled
    case serverNotFound(String)
    case serverAlreadyExists(String)
}

/// S1: 安全引用写入失败（fail-closed —— 不把 secret 明文落盘）。
public enum MCPServerSecretStoreError: Error, Equatable, Sendable {
    case keychainWriteFailed(String)
    case ambiguousSecretIdentity(String)
}

public enum MCPDurableWriteError: Error, Equatable, Sendable {
    case openFailed(path: String, code: Int32)
    case writeFailed(path: String, code: Int32)
    case syncFailed(path: String, code: Int32)
    case closeFailed(path: String, code: Int32)
    case renameFailed(path: String, code: Int32)
    case directorySyncFailed(path: String, code: Int32)
}

enum MCPBoundedDocumentReadResult: Equatable {
    case unavailable
    case tooLarge
    case data(Data)
}

/// Reads a persisted document in bounded chunks. Reading maxBytes + 1 bytes
/// distinguishes an exact-limit document from an oversized one without ever
/// materializing the whole file first.
enum MCPBoundedDocumentReader {
    static func read(from url: URL, maxBytes: Int) -> MCPBoundedDocumentReadResult {
        guard maxBytes >= 0 else { return .tooLarge }
        let (sentinelLimit, overflow) = maxBytes.addingReportingOverflow(1)
        guard !overflow else { return .tooLarge }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .unavailable
        }
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(sentinelLimit, 64 * 1024))
        while data.count < sentinelLimit {
            let count = min(64 * 1024, sentinelLimit - data.count)
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: count)
            } catch {
                return .unavailable
            }
            guard let chunk, !chunk.isEmpty else { return .data(data) }
            data.append(chunk)
        }
        return .tooLarge
    }
}

private struct MCPDocumentSizeLimitError: LocalizedError {
    var errorDescription: String? {
        "MCP persisted document exceeds the configured byte limit"
    }
}

/// A manager-issued capability for removing one stale durable-write temp.
/// The receipt is bound to the target, transaction token, payload digest, and
/// the directory identity observed during startup recovery.
public struct MCPStaleTempCleanupReceipt: Codable, Equatable, Hashable, Sendable {
    public let targetPath: String
    public let temporaryPath: String
    public let transactionToken: String
    public let payloadDigest: String
    public let directoryPath: String
    public let directoryDevice: UInt64
    public let directoryInode: UInt64
    public let temporaryDevice: UInt64
    public let temporaryInode: UInt64
    public let generation: UInt64
    public let expiresAt: Date

    public init(
        targetPath: String,
        temporaryPath: String,
        transactionToken: String,
        payloadDigest: String,
        directoryPath: String,
        directoryDevice: UInt64,
        directoryInode: UInt64,
        temporaryDevice: UInt64 = 0,
        temporaryInode: UInt64 = 0,
        generation: UInt64 = 0,
        expiresAt: Date = .distantPast
    ) {
        self.targetPath = targetPath
        self.temporaryPath = temporaryPath
        self.transactionToken = transactionToken
        self.payloadDigest = payloadDigest
        self.directoryPath = directoryPath
        self.directoryDevice = directoryDevice
        self.directoryInode = directoryInode
        self.temporaryDevice = temporaryDevice
        self.temporaryInode = temporaryInode
        self.generation = generation
        self.expiresAt = expiresAt
    }
}

public enum MCPStaleTempCleanupResult: Equatable, Sendable {
    case removed
    case alreadyAbsent
    case rejected
}

/// A discovery result bound to the server configuration that produced it.
/// The manager persists this cache across turns, but binds every projection to
/// the server descriptor, transport generation, and schema digest. A config,
/// authorization, or manager reload boundary makes the cached projection
/// unavailable until a fresh discovery proves the current runtime owner.
public struct MCPDiscoverySnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// Unique publication identity for exact stale-failure retirement. The
    /// stable `id` deliberately survives same-schema rediscovery, so it cannot
    /// distinguish an older failed transport from a newer successful one.
    /// This is not an execution grant or a server identity.
    public let publicationID: UUID?
    public let serverID: String
    public let revision: Int
    public let descriptorFingerprint: String
    /// Lifecycle generation of the transport that produced this snapshot.
    /// A reloaded manager has no live transport for this generation and must
    /// therefore keep the durable record unavailable until a fresh discovery.
    public let transportGeneration: UInt64
    /// Digest of the canonical, sorted tool/schema payload.
    public let schemaDigest: String
    public let tools: [MCPTool]

    public init(
        serverID: String,
        revision: Int,
        descriptorFingerprint: String,
        tools: [MCPTool],
        transportGeneration: UInt64 = 0,
        schemaDigest: String? = nil,
        publicationID: UUID? = nil
    ) {
        self.serverID = serverID
        self.revision = revision
        self.descriptorFingerprint = descriptorFingerprint
        self.tools = tools.sorted(by: Self.stableToolOrder)
        self.transportGeneration = transportGeneration
        self.schemaDigest = schemaDigest ?? Self.schemaDigest(for: self.tools)
        self.id = "\(serverID):r\(revision):\(descriptorFingerprint)"
        self.publicationID = publicationID
    }

    public static func schemaDigest(for tools: [MCPTool]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonicalTools = tools.sorted(by: stableToolOrder)
        guard let data = try? encoder.encode(canonicalTools) else { return "invalid" }
        return DeletionGate.fingerprint(data)
    }

    static func stableToolOrder(_ lhs: MCPTool, _ rhs: MCPTool) -> Bool {
        let lhsFolded = lhs.name.lowercased()
        let rhsFolded = rhs.name.lowercased()
        if lhsFolded != rhsFolded { return lhsFolded < rhsFolded }
        return lhs.name < rhs.name
    }
}

public enum MCPDiscoveryError: Error, Equatable, Sendable {
    case serverNotFound(String)
    case serverDisabled(String)
    case unauthorized(String)
    case stale(String)
    case repeatedCursor(serverID: String, cursor: String)
    case pageLimitExceeded(String)
    case limitsExceeded(String)
    case toolConflict(serverID: String, toolName: String)
    case serverIdentityChanged(String)
    case transportEpochChanged(String)
}

/// Deterministic session identity derived from persisted server state. A
/// descriptor or revision change yields a replacement session instead of
/// allowing a late callback to attach to the previous configuration.
public struct MCPReplacementSessionState: Codable, Equatable, Sendable, Identifiable {
    public enum Phase: String, Codable, Equatable, Sendable {
        case active
        case disabled
        case missing
    }

    public let id: String
    public let serverID: String
    public let revision: Int
    public let descriptorFingerprint: String
    public let phase: Phase

    public init(
        serverID: String,
        revision: Int,
        descriptorFingerprint: String,
        phase: Phase
    ) {
        self.serverID = serverID
        self.revision = revision
        self.descriptorFingerprint = descriptorFingerprint
        self.phase = phase
        self.id = "\(serverID):r\(revision):\(descriptorFingerprint)"
    }
}

extension MCPServerSecretStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keychainWriteFailed(let ref):
            return "MCP 密钥安全存储写入失败: \(ref)"
        case .ambiguousSecretIdentity(let key):
            return "MCP 密钥身份冲突，拒绝持久化: \(key)"
        }
    }
}

// MARK: - Server Manager

/// Manages the configured MCP servers: CRUD + JSON file persistence
/// (`mcps.json`). Configuration-management concept reference: OpenMinis `MCPStore` (参考源码:
/// Agent/Session/MCPStore.swift), simplified: no SQLite session overrides,
/// no iCloud sync — MinisCore keeps a plain `{"servers": [...]}` file.
///
/// Thread-safe (NSLock); `save()` writes atomically so a concurrent reader
/// never sees a half-written file.
public final class MCPServerManager: @unchecked Sendable {
    public struct BL6NamePreparation: Sendable {
        public let previousRevision: String
        public let effectiveRevision: String
        public let changedKeys: [String]
        public let rollbackValues: [String: BL6SettingValue]
    }

    private struct BL6NameRevisionMaterial: Encodable {
        struct Server: Encodable {
            let id: String
            let name: String
            let enabled: Bool
            let descriptorFingerprint: String
        }
        let revision: Int
        let servers: [Server]
    }

    private struct BL6NameCompletion: Codable {
        let record: BL6SettingsReplayRecord
        let serverID: String
        let previousName: String
        let resultingName: String
        let descriptorFingerprint: String
    }

    private struct BL6EnablementCompletion: Codable {
        let record: BL6SettingsReplayRecord
        let serverID: String
        let previousEnabled: Bool
        let resultingEnabled: Bool
        let descriptorFingerprint: String
    }

    private struct InvalidBL6NameLedger: Error {}
    /// Shared only with turn snapshots. Once a live rediscovery observes a
    /// different schema, a frozen older turn can never regain its old epoch,
    /// even if the remote server later returns to the old schema bytes.
    private final class SchemaLineage: @unchecked Sendable {
        private let lock = NSLock()
        private var current: [String: (digest: String, epoch: UUID)] = [:]

        func observe(serverID: String, digest: String) -> UUID {
            lock.lock()
            defer { lock.unlock() }
            if let prior = current[serverID] {
                if prior.digest == digest { return prior.epoch }
                let next = UUID()
                current[serverID] = (digest, next)
                return next
            }
            let initial = UUID()
            current[serverID] = (digest, initial)
            return initial
        }

        func accepts(serverID: String, digest: String, epoch: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let observed = current[serverID] else { return false }
            return observed.digest == digest && observed.epoch == epoch
        }
    }

    private static let maxDiscoveryPages = 1_024
    private static let maxDiscoveryToolsPerPage = 2_048
    private static let maxDiscoveryPageSchemaBytes = 512 * 1024
    private static let maxDiscoveryTools = 10_000
    private static let maxDiscoveryJSONBytes = 4 * 1024 * 1024
    private static let maxDiscoverySchemaBytes = 4 * 1024 * 1024
    private static let maxStaleTempReceipts = 64
    private static let maxTempCleanupJournalBytes = 256 * 1024
    /// Allows several maximum-size discovery snapshots while keeping startup
    /// reads and JSON materialization finite.
    private static let maxPersistedMCPDocumentBytes = 32 * 1024 * 1024
    private static let maxTempCleanupJournalEntryBytes = 16 * 1024
    private static let maxTempCleanupPayloadBytes = 4 * 1024 * 1024
    private static let maxTempCleanupJournalDepth = 8
    private static let maxTempCleanupJournalHistory = 128
    private static let maxTempCleanupJournalSegments = 8
    private static let maxTempCleanupJournalManifestTombstones = 8
    private static let tempCleanupJournalSegmentRecordLimit = 32
    private static let maxTempCleanupRecoveryCandidates = 2
    private static let staleTempReceiptLifetime: TimeInterval = 5 * 60
    private static let emptyTempCleanupJournalDigest = String(repeating: "0", count: 64)

    private enum TempCleanupJournalState: String, Codable, Equatable {
        case prepared
        case committed
    }

    private struct TempCleanupJournalEntry: Codable, Equatable {
        let generation: UInt64
        let previousDigest: String
        let consumedAt: Date
        let state: TempCleanupJournalState
        let digest: String
        let scope: String
        let transactionUUID: String
        let preGeneration: UInt64
        let postGeneration: UInt64
        let payloadDigest: String
        let configFingerprint: String
        let readbackIdentity: String
    }

    private struct TempCleanupJournalRecord: Codable, Equatable {
        let entry: TempCleanupJournalEntry
        let receiptID: String
    }

    /// Durable identity of the last compacted journal predecessor. It is a
    /// handoff fence: a new tail is valid only when it names this exact
    /// epoch, receipt, generation, and digest.
    private struct TempCleanupJournalCheckpoint: Codable, Equatable {
        let epoch: UInt64
        let receiptID: String
        let transactionUUID: String
        let generation: UInt64
        let digest: String
        let checkpointDigest: String
    }

    /// A bounded, ordered readback of the retained journal history. Segment
    /// identity seals the range; readback seals every record and its receipt.
    private struct TempCleanupJournalSegment: Codable, Equatable {
        let ordinal: UInt64
        let previousDigest: String
        let startGeneration: UInt64
        let endGeneration: UInt64
        let startDigest: String
        let endDigest: String
        let recordCount: UInt64
        let identity: String
        let readbackIdentity: String
    }

    /// Durable tombstone for the retired manifest predecessor. Its successor
    /// and checkpoint seals make a replayed manifest an invalid recovery state.
    private struct TempCleanupJournalManifestTombstone: Codable, Equatable {
        let epoch: UInt64
        let root: String
        let successorEpoch: UInt64
        let successorRoot: String
        let checkpointEpoch: UInt64
        let checkpointDigest: String
        let tombstoneDigest: String
    }

    /// Bounded-history handoff anchor. It authenticates the first retained
    /// tombstone after older epochs are compacted away.
    private struct TempCleanupJournalManifestTombstoneBase: Codable, Equatable {
        let epoch: UInt64
        let root: String
        let compactionEpoch: UInt64
        let checkpointEpoch: UInt64
        let checkpointDigest: String
        let successorEpoch: UInt64
        let successorRoot: String
        let baseDigest: String
    }

    private struct DiscoveryContext {
        let server: MCPServer
        let generation: Int
        let descriptorFingerprint: String
        let authorization: MCPToolAuthorization
    }

    private enum TornTempRecoveryStage: String {
        case directoryEnumerationRejected
        case directoryOpenRejected
        case directoryMetadataRejected
        case ownedIdentityRejected
        case candidateMetadataRejected
        case candidateTypeRejected
        case candidateLinkCountRejected
        case candidateAccepted
    }

    private enum StaleTempCleanupDecisionStage: String {
        case issuedGenerationAndScope
        case currentFilesystemIdentity
        case journalBinding
        case appendOrHandoffPrepare
        case durablePrepareSave
        case unlink
        case postUnlink
        case committedBookkeeping
        case complete
    }

    private enum CleanupJournalLoadValidityStage: String {
        case notStarted
        case documentStrictJSON
        case rootDecode
        case journalCurrentDecode
        case historyDecode
        case checkpointDecode
        case manifestDecode
        case tombstoneDecode
        case chainValidation
        case manifestValidation
        case ready
    }

    private struct TornTempRecoveryResult {
        let receipts: [MCPStaleTempCleanupReceipt]
        let stages: [TornTempRecoveryStage]
        let counters: TornTempRecoveryCounters
    }

    private struct TornTempRecoveryCounters {
        var prefixed = 0
        var identityAccepted = 0
        var metadataAccepted = 0
        var receiptConstructed = 0
        var resultReceipts = 0

        mutating func notePrefixed() {
            prefixed = min(prefixed + 1, MCPServerManager.maxStaleTempReceipts)
        }

        mutating func noteIdentityAccepted() {
            identityAccepted = min(identityAccepted + 1, MCPServerManager.maxStaleTempReceipts)
        }

        mutating func noteMetadataAccepted() {
            metadataAccepted = min(metadataAccepted + 1, MCPServerManager.maxStaleTempReceipts)
        }

        mutating func noteReceiptConstructed() {
            receiptConstructed = min(receiptConstructed + 1, MCPServerManager.maxStaleTempReceipts)
        }

        func diagnostic(scope: String, publishedReceipts: Int) -> [String] {
            [
                "\(scope).prefixed=\(prefixed)",
                "\(scope).identityAccepted=\(identityAccepted)",
                "\(scope).metadataAccepted=\(metadataAccepted)",
                "\(scope).receiptConstructed=\(receiptConstructed)",
                "\(scope).resultReceipts=\(resultReceipts)",
                "\(scope).publishedReceipts=\(min(publishedReceipts, MCPServerManager.maxStaleTempReceipts))",
            ]
        }
    }

    /// Internal origin payload is deliberately absent from the public
    /// persisted schema. Data keeps Snapshot Sendable without widening the
    /// visibility of cleanup/approval journal implementation types.
    private struct PersistentSnapshotPayload: Codable {
        let pendingSchemaRevocations: Set<String>
        let staleTempCleanupJournal: [String: TempCleanupJournalEntry]
        let staleTempCleanupJournalHistory: [TempCleanupJournalRecord]
        let staleTempCleanupJournalGeneration: UInt64
        let staleTempCleanupJournalDigest: String
        let staleTempCleanupJournalBaseGeneration: UInt64
        let staleTempCleanupJournalBaseDigest: String
        let staleTempCleanupJournalCheckpoint: TempCleanupJournalCheckpoint?
        let staleTempCleanupJournalSegments: [TempCleanupJournalSegment]
        let staleTempCleanupJournalManifestRoot: String
        let staleTempCleanupJournalManifestEpoch: UInt64
        let staleTempCleanupJournalPreviousManifestRoot: String
        let staleTempCleanupJournalManifestTombstone: TempCleanupJournalManifestTombstone?
        let staleTempCleanupJournalManifestTombstoneHistory: [TempCleanupJournalManifestTombstone]
        let staleTempCleanupJournalManifestTombstoneBase: TempCleanupJournalManifestTombstoneBase?
        let recoveryCandidateReceiptIDs: Set<String>
        let staleTempCleanupJournalValid: Bool
        let bl6NameCompletions: [String: BL6NameCompletion]
        let bl6EnablementCompletions: [String: BL6EnablementCompletion]
        let bl6NameLedgerValid: Bool
    }

    private func persistentSnapshotPayloadLocked() -> Data? {
        let payload = PersistentSnapshotPayload(
            pendingSchemaRevocations: pendingSchemaRevocations,
            staleTempCleanupJournal: staleTempCleanupJournal,
            staleTempCleanupJournalHistory: staleTempCleanupJournalHistory,
            staleTempCleanupJournalGeneration: staleTempCleanupJournalGeneration,
            staleTempCleanupJournalDigest: staleTempCleanupJournalDigest,
            staleTempCleanupJournalBaseGeneration: staleTempCleanupJournalBaseGeneration,
            staleTempCleanupJournalBaseDigest: staleTempCleanupJournalBaseDigest,
            staleTempCleanupJournalCheckpoint: staleTempCleanupJournalCheckpoint,
            staleTempCleanupJournalSegments: staleTempCleanupJournalSegments,
            staleTempCleanupJournalManifestRoot: staleTempCleanupJournalManifestRoot,
            staleTempCleanupJournalManifestEpoch: staleTempCleanupJournalManifestEpoch,
            staleTempCleanupJournalPreviousManifestRoot: staleTempCleanupJournalPreviousManifestRoot,
            staleTempCleanupJournalManifestTombstone: staleTempCleanupJournalManifestTombstone,
            staleTempCleanupJournalManifestTombstoneHistory: staleTempCleanupJournalManifestTombstoneHistory,
            staleTempCleanupJournalManifestTombstoneBase: staleTempCleanupJournalManifestTombstoneBase,
            recoveryCandidateReceiptIDs: recoveryCandidateReceiptIDs,
            staleTempCleanupJournalValid: staleTempCleanupJournalValid,
            bl6NameCompletions: bl6NameCompletions,
            bl6EnablementCompletions: bl6EnablementCompletions,
            bl6NameLedgerValid: bl6NameLedgerValid
        )
        return try? JSONEncoder().encode(payload)
    }

    private func restorePersistentSnapshotPayload(_ data: Data?) -> Bool {
        guard let data,
              let payload = try? JSONDecoder().decode(PersistentSnapshotPayload.self, from: data) else {
            return false
        }
        pendingSchemaRevocations = payload.pendingSchemaRevocations
        staleTempCleanupJournal = payload.staleTempCleanupJournal
        staleTempCleanupJournalHistory = payload.staleTempCleanupJournalHistory
        staleTempCleanupJournalGeneration = payload.staleTempCleanupJournalGeneration
        staleTempCleanupJournalDigest = payload.staleTempCleanupJournalDigest
        staleTempCleanupJournalBaseGeneration = payload.staleTempCleanupJournalBaseGeneration
        staleTempCleanupJournalBaseDigest = payload.staleTempCleanupJournalBaseDigest
        staleTempCleanupJournalCheckpoint = payload.staleTempCleanupJournalCheckpoint
        staleTempCleanupJournalSegments = payload.staleTempCleanupJournalSegments
        staleTempCleanupJournalManifestRoot = payload.staleTempCleanupJournalManifestRoot
        staleTempCleanupJournalManifestEpoch = payload.staleTempCleanupJournalManifestEpoch
        staleTempCleanupJournalPreviousManifestRoot = payload.staleTempCleanupJournalPreviousManifestRoot
        staleTempCleanupJournalManifestTombstone = payload.staleTempCleanupJournalManifestTombstone
        staleTempCleanupJournalManifestTombstoneHistory = payload.staleTempCleanupJournalManifestTombstoneHistory
        staleTempCleanupJournalManifestTombstoneBase = payload.staleTempCleanupJournalManifestTombstoneBase
        recoveryCandidateReceiptIDs = payload.recoveryCandidateReceiptIDs
        staleTempCleanupJournalValid = payload.staleTempCleanupJournalValid
        bl6NameCompletions = payload.bl6NameCompletions
        bl6EnablementCompletions = payload.bl6EnablementCompletions
        bl6NameLedgerValid = payload.bl6NameLedgerValid
        // Startup-issued cleanup receipts are not copied: they are capabilities
        // tied to this constructor's generation, not persistent journal state.
        return true
    }

    /// Immutable configuration used to bind one agent turn to the settings
    /// that existed when that turn was created.
    public struct Snapshot: Sendable, Equatable {
        public let fileURL: URL
        public let authorizationFileURL: URL
        public let servers: [MCPServer]
        public let trashServers: [MCPServer]
        public let authorizations: [String: MCPToolAuthorization]
        public let discoverySnapshots: [String: MCPDiscoverySnapshot]
        public let transportGenerations: [String: UInt64]
        public let schemaEpochs: [String: UUID]
        public let revision: Int
        // Captured from this manager, never refreshed from disk for old RAM.
        fileprivate var persistentOrigin: Data?
        fileprivate var persistenceBaseline: MCPPersistentWriteFence.PairToken?
        fileprivate var persistenceConflict: MCPPersistenceConflict?

        public static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.fileURL == rhs.fileURL && lhs.authorizationFileURL == rhs.authorizationFileURL
                && lhs.servers == rhs.servers && lhs.trashServers == rhs.trashServers
                && lhs.authorizations == rhs.authorizations
                && lhs.discoverySnapshots == rhs.discoverySnapshots
                && lhs.transportGenerations == rhs.transportGenerations
                && lhs.schemaEpochs == rhs.schemaEpochs && lhs.revision == rhs.revision
        }

        public init(
            fileURL: URL,
            authorizationFileURL: URL,
            servers: [MCPServer],
            trashServers: [MCPServer],
            authorizations: [String: MCPToolAuthorization],
            discoverySnapshots: [String: MCPDiscoverySnapshot] = [:],
            transportGenerations: [String: UInt64] = [:],
            schemaEpochs: [String: UUID] = [:],
            revision: Int
        ) {
            self.fileURL = fileURL
            self.authorizationFileURL = authorizationFileURL
            self.servers = servers
            self.trashServers = trashServers
            self.authorizations = authorizations
            self.discoverySnapshots = discoverySnapshots
            self.transportGenerations = transportGenerations
            self.schemaEpochs = schemaEpochs
            self.revision = revision
        }
    }

    public let fileURL: URL
    public let authorizationFileURL: URL
    private let lock = NSLock()
    private let schemaLineage: SchemaLineage
    private let keychain: KeychainStore
    public let oauth: MCPOAuthCoordinator
    private final class RuntimeClient: @unchecked Sendable {
        weak var value: MCPClient?
        init(_ value: MCPClient) { self.value = value }
    }
    private let runtimeLock = NSLock()
    private var runtimeClients: [String: [RuntimeClient]] = [:]
    private var managementClients: [String: MCPClient] = [:]
    private var runtimeMessages: [String: String] = [:]
    private var refreshPending: [String: MCPClient] = [:]
    private var refreshing: Set<String> = []
    public static let runtimeChanged = Notification.Name("MinisCanvas.MCP.runtimeChanged")

    /// Registers an actual transport owner; this projection never grants a tool.
    public func observeRuntime(_ client: MCPClient) {
        let id = client.server.id
        runtimeLock.withLock {
            var values = runtimeClients[id, default: []].filter { $0.value != nil }
            if !values.contains(where: { $0.value === client }) { values.append(RuntimeClient(client)) }
            runtimeClients[id] = values
        }
        client.setRuntimeChangedHandler { [weak self] in self?.publishRuntimeChange(serverID: id) }
        client.setToolsChangedHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.enqueueToolsChanged(client)
        }
        publishRuntimeChange(serverID: id)
    }
    private func publishRuntimeChange(serverID: String) {
        NotificationCenter.default.post(name: Self.runtimeChanged, object: self,
            userInfo: ["serverID": serverID])
    }
    public func runtimeState(serverID: String) -> MCPClientState {
        let clients = runtimeLock.withLock { runtimeClients[serverID, default: []].compactMap(\.value) }
        if clients.contains(where: \.isConnected) { return .connected }
        if clients.contains(where: { $0.connectionState == .connecting }) { return .connecting }
        for client in clients {
            if case .failed(let message) = client.connectionState { return .failed(message) }
            if case .failed? = client.lifecycleSnapshot.runtime?.state { return .failed("MCP 服务器已断开，请重连") }
        }
        return .disconnected
    }
    public func runtimeMessage(serverID: String) -> String? { runtimeLock.withLock { runtimeMessages[serverID] } }
    public func disconnectAllRuntimes() {
        let ids = runtimeLock.withLock { Array(Set(runtimeClients.keys).union(managementClients.keys)) }
        ids.forEach { disconnectRuntime(serverID: $0) }
    }
    public func disconnectRuntime(serverID: String) {
        let values: [MCPClient] = runtimeLock.withLock {
            managementClients.removeValue(forKey: serverID)
            refreshPending.removeValue(forKey: serverID)
            return runtimeClients.removeValue(forKey: serverID)?.compactMap(\.value) ?? []
        }
        values.forEach { $0.disconnect() }
        publishRuntimeChange(serverID: serverID)
    }
    private func ownsManagementClient(_ client: MCPClient) -> Bool {
        runtimeLock.withLock { managementClients[client.server.id] === client }
    }
    /// Uses this manager's credential scope; OAuth does not alter server/tool grants.
    public func makeClient(server: MCPServer) -> MCPClient {
        guard MCPOAuthCoordinator.isEligible(server), let raw = server.url, let url = URL(string: raw) else {
            return MCPClient(server: server)
        }
        return MCPClient(server: server, transport: MCPHTTPTransport(
            url: url, headers: server.headers, timeoutSeconds: server.timeoutSeconds,
            oauth: oauth, oauthServer: server
        ))
    }

    public func logoutOAuth(serverID: String) async throws {
        guard let server = server(id: serverID) else { return }
        disconnectRuntime(serverID: serverID)
        try await oauth.logout(server: server)
    }

    public func reconnect(serverID: String) async throws {
        guard let server = server(id: serverID), server.enabled, isServerAuthorized(server) else {
            throw MCPDiscoveryError.unauthorized(serverID)
        }
        disconnectRuntime(serverID: serverID)
        let client = makeClient(server: server)
        runtimeLock.withLock { managementClients[serverID] = client; runtimeMessages[serverID] = "正在重连…" }
        observeRuntime(client)
        do {
            guard ownsManagementClient(client) else { throw MCPDiscoveryError.stale(serverID) }
            try await client.connect()
            guard ownsManagementClient(client) else { throw MCPDiscoveryError.stale(serverID) }
            _ = try await discoverTools(serverID: serverID, clientFactory: { _ in client },
                beforeCommit: {}, disconnectAfterDiscovery: false)
            guard ownsManagementClient(client), self.server(id: serverID) == server, isServerAuthorized(server) else { throw MCPDiscoveryError.stale(serverID) }
            runtimeLock.withLock { runtimeMessages[serverID] = "已重连并刷新工具；工具仍需逐项授权。" }
            publishRuntimeChange(serverID: serverID)
        } catch {
            client.disconnect()
            if ownsManagementClient(client) {
                runtimeLock.withLock { runtimeMessages[serverID] = "重连失败；请检查配置后重试。" }
                publishRuntimeChange(serverID: serverID)
            }
            throw error
        }
    }
    private func enqueueToolsChanged(_ client: MCPClient) {
        let id = client.server.id
        let claimed = runtimeLock.withLock {
            refreshPending[id] = client
            return refreshing.insert(id).inserted
        }
        guard claimed else { return }
        Task { [weak self] in
            guard let self else { return }
            while let client = self.claimPendingRefresh(serverID: id) {
                let previous = self.discoverySnapshot(serverID: id)
                do {
                    guard client.isConnected, self.server(id: id) == client.server else { throw MCPDiscoveryError.stale(id) }
                    _ = try await self.discoverTools(serverID: id, clientFactory: { _ in client },
                        beforeCommit: {}, disconnectAfterDiscovery: false)
                    guard client.isConnected else { continue }
                    self.runtimeLock.withLock { self.runtimeMessages[id] = "服务器通知工具列表已变化，已刷新；新增或变更工具仍需授权。" }
                } catch {
                    _ = try? self.retireDiscoveryAfterFailedRefresh(serverID: id, expected: previous)
                    guard client.isConnected else { continue }
                    self.runtimeLock.withLock { self.runtimeMessages[id] = "服务器通知工具变化，但刷新失败；请手动重试。" }
                }
                self.publishRuntimeChange(serverID: id)
            }
        }
    }
    private func claimPendingRefresh(serverID: String) -> MCPClient? {
        runtimeLock.withLock {
            if let client = refreshPending.removeValue(forKey: serverID) { return client }
            refreshing.remove(serverID)
            return nil
        }
    }

    private var servers: [MCPServer] = []
    private var trashServers: [MCPServer] = []
    private var authorizations: [String: MCPToolAuthorization] = [:]
    /// A failed durable revocation remains denied in memory. Discovery may
    /// resume only after the revoked authorization document is written.
    private var pendingSchemaRevocations: Set<String> = []
    private var discoverySnapshots: [String: MCPDiscoverySnapshot] = [:]
    /// Runtime-only proof that a durable snapshot belongs to the currently
    /// live transport owner. Reload starts empty and cannot reuse old pages.
    private var transportGenerations: [String: UInt64] = [:]
    private var schemaEpochs: [String: UUID] = [:]
    private var staleTempReceipts: [MCPStaleTempCleanupReceipt] = []
    private var issuedTempReceipts: Set<MCPStaleTempCleanupReceipt> = []
    private var tornTempRecoveryStages: [TornTempRecoveryStage] = []
    private var tornTempRecoveryCounters: [String] = []
    private var lastStaleTempCleanupDecisionStage = StaleTempCleanupDecisionStage.issuedGenerationAndScope
    private let cleanupJournalLoadDiagnosticLock = NSLock()
    private var lastCleanupJournalLoadValidityStage = CleanupJournalLoadValidityStage.notStarted
    private var staleTempCleanupJournal: [String: TempCleanupJournalEntry] = [:]
    private var staleTempCleanupJournalHistory: [TempCleanupJournalRecord] = []
    private var staleTempCleanupJournalGeneration: UInt64 = 0
    private var staleTempCleanupJournalDigest = MCPServerManager.emptyTempCleanupJournalDigest
    private var staleTempCleanupJournalBaseGeneration: UInt64 = 0
    private var staleTempCleanupJournalBaseDigest = MCPServerManager.emptyTempCleanupJournalDigest
    private var staleTempCleanupJournalCheckpoint: TempCleanupJournalCheckpoint?
    private var staleTempCleanupJournalSegments: [TempCleanupJournalSegment] = []
    private var staleTempCleanupJournalManifestRoot = MCPServerManager.emptyTempCleanupJournalDigest
    private var staleTempCleanupJournalManifestEpoch: UInt64 = 0
    private var staleTempCleanupJournalPreviousManifestRoot = MCPServerManager.emptyTempCleanupJournalDigest
    private var staleTempCleanupJournalManifestTombstone: TempCleanupJournalManifestTombstone?
    private var staleTempCleanupJournalManifestTombstoneHistory: [TempCleanupJournalManifestTombstone] = []
    private var staleTempCleanupJournalManifestTombstoneBase: TempCleanupJournalManifestTombstoneBase?
    private var recoveryCandidateReceiptIDs: Set<String> = []
    private var staleTempCleanupJournalValid = true
    private let staleTempReceiptGeneration = UInt64.random(in: 1...UInt64.max)
    private var revision = 0
    private var bl6NameCompletions: [String: BL6NameCompletion] = [:]
    private var bl6EnablementCompletions: [String: BL6EnablementCompletion] = [:]
    private var bl6NameLedgerValid = true
    private var persistenceBaseline: MCPPersistentWriteFence.PairToken?
    private var persistenceConflict: MCPPersistenceConflict?
    private var persistenceFailureDescription: String?
    private var persistenceLease: MCPPersistentWriteFence.Lease?

    /// Nonthrowing initialization preserves API compatibility. A failed load,
    /// migration, or ambiguous write must be diagnosed and reopened, not saved
    /// again from potentially partial RAM. List/read diagnostics stay available.
    public func persistenceWriteConflict() -> MCPPersistenceConflict? {
        lock.lock()
        defer { lock.unlock() }
        return persistenceConflict
    }

    public func persistenceWriteFailureDescription() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return persistenceFailureDescription
    }

    private func beginPersistentMutationLocked() throws {
        if let persistenceConflict { throw persistenceConflict }
        guard bl6NameLedgerValid else {
            persistenceConflict = .needsReopen
            throw MCPPersistenceConflict.needsReopen
        }
        guard persistenceLease == nil, let baseline = persistenceBaseline else {
            throw MCPPersistenceConflict.needsReopen
        }
        let lease = try MCPPersistentWriteFence.acquire(
            configURL: fileURL, authorizationURL: authorizationFileURL
        )
        do {
            guard try lease.token(maxBytes: Self.maxPersistedMCPDocumentBytes) == baseline else {
                persistenceConflict = .staleSnapshot
                throw MCPPersistenceConflict.staleSnapshot
            }
            persistenceLease = lease
        } catch {
            lease.release()
            throw error
        }
    }

    private func endPersistentMutationLocked() {
        persistenceLease?.release()
        persistenceLease = nil
    }

    /// Called by both raw writers while the operation owns the pair lease.
    /// Nested config -> auth writes reuse it rather than reacquiring the gate.
    private func persistWithinLeaseLocked(_ body: () throws -> Void) throws {
        if let persistenceConflict { throw persistenceConflict }
        guard let lease = persistenceLease else { throw MCPPersistenceConflict.needsReopen }
        do {
            try body()
            persistenceBaseline = try lease.token(maxBytes: Self.maxPersistedMCPDocumentBytes)
        } catch {
            // Preserve the original error, including after Keychain/config
            // success followed by companion failure. This is not pair atomicity.
            persistenceConflict = .needsReopen
            persistenceFailureDescription = String(describing: error)
            throw error
        }
    }

    /// Create a manager backed by `fileURL` (e.g. `<dataDir>/mcps.json`).
    /// If the file exists it is loaded immediately.
    ///
    /// S1: secret env/header 值不落明文磁盘 —— 保存时写入 `keychain`（安全引用，
    /// 磁盘只存占位符），加载时从 Keychain 还原真实值，运行期行为不变；旧格式
    /// 明文 secret 首次加载自动迁入 Keychain 并重写文件剥离明文。测试可注入
    /// 内存 backing。
    public init(
        fileURL: URL,
        keychain: KeychainStore = KeychainStore(),
        authorizationFileURL: URL? = nil
    ) {
        self.schemaLineage = SchemaLineage()
        self.fileURL = fileURL
        self.authorizationFileURL = authorizationFileURL
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("mcp-authorizations.json")
        self.keychain = keychain
        self.oauth = MCPOAuthCoordinator(keychain: keychain)
        do {
            let lease = try MCPPersistentWriteFence.acquire(
                configURL: self.fileURL, authorizationURL: self.authorizationFileURL
            )
            persistenceLease = lease
            defer { endPersistentMutationLocked() }
            // Read-only temp receipt diagnostics remain available even when an
            // oversized document cannot establish a writable pair baseline.
            let receiptExpiry = Date().addingTimeInterval(Self.staleTempReceiptLifetime)
            let configRecovery = Self.recoverTornTempFiles(
                for: fileURL,
                generation: staleTempReceiptGeneration,
                expiresAt: receiptExpiry
            )
            let authorizationRecovery = Self.recoverTornTempFiles(
                for: self.authorizationFileURL,
                generation: staleTempReceiptGeneration,
                expiresAt: receiptExpiry
            )
            let recoveredReceipts = configRecovery.receipts + authorizationRecovery.receipts
            tornTempRecoveryStages = Array(
                Set(configRecovery.stages + authorizationRecovery.stages)
            ).sorted { $0.rawValue < $1.rawValue }
            staleTempReceipts = Array(
                recoveredReceipts
                    .sorted { $0.temporaryPath < $1.temporaryPath }
                    .prefix(Self.maxStaleTempReceipts)
            )
            tornTempRecoveryCounters = configRecovery.counters.diagnostic(
                scope: "config",
                publishedReceipts: staleTempReceipts.filter { $0.targetPath == fileURL.path }.count
            ) + authorizationRecovery.counters.diagnostic(
                scope: "authorization",
                publishedReceipts: staleTempReceipts.filter {
                    $0.targetPath == self.authorizationFileURL.path
                }.count
            )
            issuedTempReceipts = Set(staleTempReceipts)
            // The same strict token still gates normal startup and all writes.
            // Failed startup retains diagnostics, never usable write authority.
            persistenceBaseline = try lease.token(maxBytes: Self.maxPersistedMCPDocumentBytes)
            let migrated = try loadFromDisk()
            loadAuthorizationsFromDisk()
            // Load the companion before any migration rewrite so the complete
            // pair belongs to this same locked startup observation.
            if migrated { try saveLocked() }
            // A restarted manager cannot prove that a persisted page belongs to
            // the new transport owner. Remove the durable record before any
            // Snapshot can expose it to the MCP tool bridge.
            if discardReloadedDiscoverySnapshots() { try saveLocked() }
            if !bl6NameLedgerValid { persistenceConflict = .needsReopen }
            guard try lease.token(maxBytes: Self.maxPersistedMCPDocumentBytes) == persistenceBaseline else {
                throw MCPPersistenceConflict.staleSnapshot
            }
        } catch {
            // init cannot throw. Do not silently treat failed startup as fresh.
            persistenceConflict = .needsReopen
            // Retain bounded read diagnostics without retrying migration or
            // adopting a new baseline after startup could not own the pair.
            _ = try? loadFromDisk(allowSecretMigration: false)
            loadAuthorizationsFromDisk()
            persistenceConflict = .needsReopen
            persistenceFailureDescription = String(describing: error)
        }
    }

    /// Default location: `<Application Support>/MinisCore/mcps.json` — pass a
    /// different URL in tests.
    public static func defaultFileURL() -> URL {
        if let formal = FormalTestIsolationPaths.currentOrFail() {
            return formal.mcpFileURL
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MinisCore/mcps.json", isDirectory: false)
    }

    // MARK: - Read

    public func listServers() -> [MCPServer] {
        lock.lock()
        defer { lock.unlock() }
        return servers.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Capture the current settings without exposing the manager's mutable
    /// arrays or authorization map to an in-flight turn.
    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let validSnapshots = discoverySnapshots.filter { serverID, snapshot in
            isValidDiscoverySnapshotLocked(serverID: serverID, snapshot: snapshot)
        }
        let validTransportGenerations = validSnapshots.compactMapValues { snapshot in
            transportGenerations[snapshot.serverID]
        }
        var captured = Snapshot(
            fileURL: fileURL,
            authorizationFileURL: authorizationFileURL,
            servers: servers,
            trashServers: trashServers,
            authorizations: persistenceConflict == nil ? authorizations : [:],
            discoverySnapshots: validSnapshots,
            transportGenerations: validTransportGenerations,
            schemaEpochs: schemaEpochs,
            revision: revision
        )
        captured.persistentOrigin = persistentSnapshotPayloadLocked()
        captured.persistenceBaseline = persistenceBaseline
        captured.persistenceConflict = persistenceConflict
        return captured
    }

    /// Build an in-memory manager from a previously captured configuration.
    /// The clone shares the Keychain backing and its captured persistence
    /// baseline. Any explicit write must still prove this exact pair current.
    public func makeSnapshotManager() -> MCPServerManager {
        MCPServerManager(snapshot: snapshot(), keychain: keychain, schemaLineage: schemaLineage, oauth: oauth)
    }

    /// Internal reconstruction seam keeps origin validation on the same
    /// constructor used by production turn snapshots. Public Snapshot values
    /// reconstructed from visible fields alone are readable but cannot write.
    func makeSnapshotManager(from captured: Snapshot) -> MCPServerManager {
        MCPServerManager(snapshot: captured, keychain: keychain, schemaLineage: schemaLineage, oauth: oauth)
    }

    /// Freeze the turn's configuration and grants while the caller still owns
    /// its turn boundary. Discovery schema validation is deliberately delayed
    /// until the returned preparation runs away from the UI actor.
    public func captureSnapshotManagerPreparation() -> @Sendable () -> MCPServerManager {
        let raw = lock.withLock {
            var captured = Snapshot(
                fileURL: fileURL,
                authorizationFileURL: authorizationFileURL,
                servers: servers,
                trashServers: trashServers,
                authorizations: persistenceConflict == nil ? authorizations : [:],
                discoverySnapshots: discoverySnapshots,
                transportGenerations: transportGenerations,
                schemaEpochs: schemaEpochs,
                revision: revision
            )
            captured.persistentOrigin = persistentSnapshotPayloadLocked()
            captured.persistenceBaseline = persistenceBaseline
            captured.persistenceConflict = persistenceConflict
            return captured
        }
        return { [keychain, schemaLineage, oauth] in
            MCPServerManager(snapshot: raw, keychain: keychain, schemaLineage: schemaLineage, oauth: oauth)
                .makeSnapshotManager()
        }
    }

    public func server(id: String) -> MCPServer? {
        lock.lock()
        defer { lock.unlock() }
        return servers.first { $0.id == id }
    }

    /// A Store revision for the MCP conversation settings. It advances
    /// with every MCP configuration or authorization change, so a proposal
    /// cannot carry a stale configuration or grant epoch into the write path.
    public func bl6NameRevision() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return bl6NameLedgerValid ? bl6NameRevisionLocked() : nil
    }

    public func bl6NameReplayRecord(
        for requestID: String, profileID: String
    ) -> Result<BL6SettingsReplayRecord?, BL6SettingsReplayCommitError> {
        lock.lock()
        defer { lock.unlock() }
        guard bl6NameLedgerValid else { return .failure(.persistence(.transactionRecoveryRequired)) }
        guard let completion = bl6NameCompletions[requestID] else { return .success(nil) }
        return completion.record.profileID == profileID
            ? .success(completion.record) : .failure(.conflict)
    }

    public func bl6NameReplayRecord(
        receiptID: String, profileID: String
    ) -> Result<BL6SettingsReplayRecord?, BL6SettingsReplayCommitError> {
        lock.lock()
        defer { lock.unlock() }
        guard bl6NameLedgerValid else { return .failure(.persistence(.transactionRecoveryRequired)) }
        guard let completion = bl6NameCompletions.values.first(where: {
            $0.record.receipt.receiptID == receiptID
        }) else { return .success(nil) }
        return completion.record.profileID == profileID
            ? .success(completion.record) : .failure(.conflict)
    }

    public func prepareBL6NameReplay(
        _ input: BL6SettingsApprovedInput, profileID: String
    ) -> Result<BL6NamePreparation, BL6SettingsReplayCommitError> {
        lock.lock()
        defer { lock.unlock() }
        guard bl6NameLedgerValid, !profileID.isEmpty else {
            return .failure(.persistence(.transactionRecoveryRequired))
        }
        guard input.expectedRevision == bl6NameRevisionLocked() else {
            return .failure(.staleRevision)
        }
        guard let change = bl6NameChangeLocked(input, profileID: profileID) else {
            return .failure(.conflict)
        }
        guard revision < Int.max else { return .failure(.conflict) }
        var candidate = servers
        guard let index = candidate.firstIndex(where: { $0.id == change.serverID }) else {
            return .failure(.conflict)
        }
        candidate[index].name = change.next
        return .success(BL6NamePreparation(
            previousRevision: bl6NameRevisionLocked(),
            effectiveRevision: bl6NameRevisionLocked(servers: candidate, revision: revision + 1),
            changedKeys: change.previous == change.next ? [] : [change.key],
            rollbackValues: [change.key: .text(change.previous)]
        ))
    }

    /// Persist name and replay receipt in the same canonical mcps.json write.
    /// The manager never mints approval and never changes server/tool grants.
    public func commitBL6NameReplay(
        _ record: BL6SettingsReplayRecord, profileID: String
    ) -> Result<BL6SettingsReceipt, BL6SettingsReplayCommitError> {
        lock.lock()
        defer { lock.unlock() }
        guard bl6NameLedgerValid, !profileID.isEmpty, record.profileID == profileID,
              record.requestID == record.receipt.requestID,
              record.operation == record.frozenInput.operation else { return .failure(.conflict) }
        guard bl6EnablementCompletions[record.requestID] == nil,
              !bl6EnablementCompletions.values.contains(where: {
                  $0.record.receipt.receiptID == record.receipt.receiptID
                      || $0.record.receipt.effectiveRevision == record.receipt.effectiveRevision
              }) else { return .failure(.conflict) }
        if let completed = bl6NameCompletions[record.requestID] {
            return completed.record == record ? .success(record.receipt) : .failure(.conflict)
        }
        guard bl6NameCompletions.count < 1_024,
              !bl6NameCompletions.values.contains(where: {
            $0.record.receipt.receiptID == record.receipt.receiptID
                || $0.record.receipt.effectiveRevision == record.receipt.effectiveRevision
        }) else { return .failure(.conflict) }
        guard record.frozenInput.expectedRevision == bl6NameRevisionLocked() else {
            return .failure(.staleRevision)
        }
        guard revision < Int.max,
              let change = bl6NameChangeLocked(record.frozenInput, profileID: profileID),
              let index = servers.firstIndex(where: { $0.id == change.serverID }),
              record.receipt.previousRevision == bl6NameRevisionLocked(),
              record.receipt.changedKeys == (change.previous == change.next ? [] : [change.key]),
              record.rollbackValues == [change.key: .text(change.previous)],
              record.receipt.rollbackValues.isEmpty else { return .failure(.conflict) }
        var candidate = servers
        candidate[index].name = change.next
        guard record.receipt.effectiveRevision == bl6NameRevisionLocked(
            servers: candidate, revision: revision + 1
        ) else { return .failure(.conflict) }
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return .failure(.persistence(.writeFailed))
        }
        do { try beginPersistentMutationLocked() }
        catch MCPPersistenceConflict.staleSnapshot { return .failure(.staleRevision) }
        catch MCPPersistenceConflict.writerBusy { return .failure(.conflict) }
        catch { return .failure(.persistence(.transactionReopenRequired)) }
        defer { endPersistentMutationLocked() }
        let before = servers[index]
        servers[index].name = change.next
        revision += 1
        bl6NameCompletions[record.requestID] = BL6NameCompletion(
            record: record, serverID: change.serverID,
            previousName: change.previous, resultingName: change.next,
            descriptorFingerprint: before.descriptorFingerprint
        )
        do {
            try saveLocked(persistAuthorizations: false)
        } catch {
            // A durability failure after rename is ambiguous. Reopen is
            // required; never allow another approved write on this instance.
            bl6NameLedgerValid = false
            return .failure(.persistence(.transactionReopenRequired))
        }
        guard case .data(let data) = readDocumentLocked(.config), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawServers = root["servers"] as? [[String: Any]],
              rawServers.contains(where: {
                  $0["id"] as? String == change.serverID && $0["name"] as? String == change.next
              }),
              let rawLedger = root["bl6NameCompletions"] as? [String: Any],
              let rawRecord = rawLedger[record.requestID],
              let recordData = try? JSONSerialization.data(withJSONObject: rawRecord),
              let reopened = try? JSONDecoder().decode(BL6NameCompletion.self, from: recordData),
              reopened.record == record else {
            bl6NameLedgerValid = false
            return .failure(.persistence(.transactionReopenRequired))
        }
        return .success(record.receipt)
    }

    public typealias BL6EnablementPreparation = BL6NamePreparation

    public func bl6EnablementReplayRecord(
        for requestID: String, profileID: String
    ) -> Result<BL6SettingsReplayRecord?, BL6SettingsReplayCommitError> {
        lock.lock()
        defer { lock.unlock() }
        guard bl6NameLedgerValid else { return .failure(.persistence(.transactionRecoveryRequired)) }
        guard let completion = bl6EnablementCompletions[requestID] else { return .success(nil) }
        return completion.record.profileID == profileID
            ? .success(completion.record) : .failure(.conflict)
    }

    public func bl6EnablementReplayRecord(
        receiptID: String, profileID: String
    ) -> Result<BL6SettingsReplayRecord?, BL6SettingsReplayCommitError> {
        lock.lock()
        defer { lock.unlock() }
        guard bl6NameLedgerValid else { return .failure(.persistence(.transactionRecoveryRequired)) }
        guard let completion = bl6EnablementCompletions.values.first(where: {
            $0.record.receipt.receiptID == receiptID
        }) else { return .success(nil) }
        return completion.record.profileID == profileID
            ? .success(completion.record) : .failure(.conflict)
    }

    public func prepareBL6EnablementReplay(
        _ input: BL6SettingsApprovedInput, profileID: String
    ) -> Result<BL6EnablementPreparation, BL6SettingsReplayCommitError> {
        lock.lock()
        defer { lock.unlock() }
        guard bl6NameLedgerValid, !profileID.isEmpty else {
            return .failure(.persistence(.transactionRecoveryRequired))
        }
        guard input.expectedRevision == bl6NameRevisionLocked() else {
            return .failure(.staleRevision)
        }
        guard let change = bl6EnablementChangeLocked(input, profileID: profileID),
              revision < Int.max,
              let index = servers.firstIndex(where: { $0.id == change.serverID }) else {
            return .failure(.conflict)
        }
        var candidate = servers
        candidate[index].enabled = change.next
        return .success(BL6EnablementPreparation(
            previousRevision: bl6NameRevisionLocked(),
            effectiveRevision: bl6NameRevisionLocked(servers: candidate, revision: revision + 1),
            changedKeys: change.previous == change.next ? [] : [change.key],
            rollbackValues: [change.key: .toggle(change.previous)]
        ))
    }

    /// One approved enablement assignment records its receipt with the
    /// canonical server bit. A transition retires the old grant in the
    /// companion document first; rollback never restores that grant.
    public func commitBL6EnablementReplay(
        _ record: BL6SettingsReplayRecord, profileID: String
    ) -> Result<BL6SettingsReceipt, BL6SettingsReplayCommitError> {
        lock.lock()
        defer { lock.unlock() }
        guard bl6NameLedgerValid, !profileID.isEmpty, record.profileID == profileID,
              record.requestID == record.receipt.requestID,
              record.operation == record.frozenInput.operation else { return .failure(.conflict) }
        if let completed = bl6EnablementCompletions[record.requestID] {
            return completed.record == record ? .success(record.receipt) : .failure(.conflict)
        }
        guard bl6EnablementCompletions.count < 1_024,
              bl6NameCompletions[record.requestID] == nil,
              !bl6NameCompletions.values.contains(where: {
                  $0.record.receipt.receiptID == record.receipt.receiptID
                      || $0.record.receipt.effectiveRevision == record.receipt.effectiveRevision
              }),
              !bl6EnablementCompletions.values.contains(where: {
                  $0.record.receipt.receiptID == record.receipt.receiptID
                      || $0.record.receipt.effectiveRevision == record.receipt.effectiveRevision
              }),
              record.frozenInput.expectedRevision == bl6NameRevisionLocked() else {
            return .failure(.conflict)
        }
        guard revision < Int.max,
              let change = bl6EnablementChangeLocked(record.frozenInput, profileID: profileID),
              let index = servers.firstIndex(where: { $0.id == change.serverID }),
              record.receipt.previousRevision == bl6NameRevisionLocked(),
              record.receipt.changedKeys == (change.previous == change.next ? [] : [change.key]),
              record.rollbackValues == [change.key: .toggle(change.previous)],
              record.receipt.rollbackValues.isEmpty else { return .failure(.conflict) }
        var candidate = servers
        candidate[index].enabled = change.next
        guard record.receipt.effectiveRevision == bl6NameRevisionLocked(
            servers: candidate, revision: revision + 1
        ) else { return .failure(.conflict) }
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue { return .failure(.persistence(.writeFailed)) }
        do { try beginPersistentMutationLocked() }
        catch MCPPersistenceConflict.staleSnapshot { return .failure(.staleRevision) }
        catch MCPPersistenceConflict.writerBusy { return .failure(.conflict) }
        catch { return .failure(.persistence(.transactionReopenRequired)) }
        defer { endPersistentMutationLocked() }
        let before = servers[index]
        servers[index].enabled = change.next
        let changedState = change.previous != change.next
        if changedState {
            authorizations.removeValue(forKey: change.serverID)
            disconnectRuntime(serverID: change.serverID)
        }
        revision += 1
        bl6EnablementCompletions[record.requestID] = BL6EnablementCompletion(
            record: record, serverID: change.serverID,
            previousEnabled: change.previous, resultingEnabled: change.next,
            descriptorFingerprint: before.descriptorFingerprint
        )
        do {
            if changedState { try saveAuthorizationsLocked() }
            try saveLocked(persistAuthorizations: false)
        } catch {
            bl6NameLedgerValid = false
            return .failure(.persistence(.transactionReopenRequired))
        }
        guard case .data(let data) = readDocumentLocked(.config), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawServers = root["servers"] as? [[String: Any]],
              rawServers.contains(where: {
                  $0["id"] as? String == change.serverID && $0["enabled"] as? Bool == change.next
              }),
              let rawLedger = root["bl6EnablementCompletions"] as? [String: Any],
              let rawRecord = rawLedger[record.requestID],
              let recordData = try? JSONSerialization.data(withJSONObject: rawRecord),
              let reopened = try? JSONDecoder().decode(BL6EnablementCompletion.self, from: recordData),
              reopened.record == record else {
            bl6NameLedgerValid = false
            return .failure(.persistence(.transactionReopenRequired))
        }
        if changedState {
            guard case .data(let authorizationData) = readDocumentLocked(.authorization), let document = try? JSONDecoder().decode(AuthorizationFileShape.self, from: authorizationData),
                  !document.authorizations.contains(where: { $0.serverID == change.serverID }) else {
                bl6NameLedgerValid = false
                return .failure(.persistence(.transactionReopenRequired))
            }
        }
        return .success(record.receipt)
    }

    private func bl6EnablementChangeLocked(
        _ input: BL6SettingsApprovedInput, profileID: String
    ) -> (serverID: String, key: String, previous: Bool, next: Bool)? {
        guard (try? input.validateForApprovedEffect()) != nil else { return nil }
        let key: String
        let serverID: String
        let next: Bool
        switch input.operation {
        case .apply:
            guard input.changes.count == 1,
                  let (candidateKey, value) = input.changes.first,
                  case .toggle(let proposed) = value,
                  let decoded = Self.bl6ServerID(fromEnabledKey: candidateKey) else { return nil }
            key = candidateKey
            serverID = decoded
            next = proposed
        case .rollback:
            guard let receiptID = input.undoReceiptID,
                  let original = bl6EnablementCompletions.values.first(where: {
                      $0.record.receipt.receiptID == receiptID
                  }), original.record.operation == .apply,
                  original.record.profileID == profileID,
                  original.record.receipt.effectiveRevision == bl6NameRevisionLocked(),
                  input.changes.isEmpty else { return nil }
            key = Self.bl6EnabledKey(for: original.serverID)
            serverID = original.serverID
            next = original.previousEnabled
        default: return nil
        }
        guard let current = servers.first(where: { $0.id == serverID }) else { return nil }
        if input.operation == .rollback {
            guard let original = bl6EnablementCompletions.values.first(where: {
                $0.record.receipt.receiptID == input.undoReceiptID
            }), current.descriptorFingerprint == original.descriptorFingerprint,
               current.enabled == original.resultingEnabled else { return nil }
        }
        return (serverID, key, current.enabled, next)
    }

    private func bl6NameChangeLocked(
        _ input: BL6SettingsApprovedInput, profileID: String
    ) -> (serverID: String, key: String, previous: String, next: String)? {
        guard (try? input.validateForApprovedEffect()) != nil else { return nil }
        let key: String
        let serverID: String
        let next: String
        switch input.operation {
        case .apply:
            guard input.changes.count == 1,
                  let (candidateKey, value) = input.changes.first,
                  case .text(let proposed) = value,
                  !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  proposed == proposed.trimmingCharacters(in: .whitespacesAndNewlines),
                  proposed.utf8.count <= 256,
                  let decoded = Self.bl6ServerID(fromNameKey: candidateKey) else { return nil }
            key = candidateKey
            serverID = decoded
            next = proposed
        case .rollback:
            guard let receiptID = input.undoReceiptID,
                  let original = bl6NameCompletions.values.first(where: {
                      $0.record.receipt.receiptID == receiptID
                  }), original.record.operation == .apply,
                  original.record.profileID == profileID,
                  original.record.receipt.effectiveRevision == bl6NameRevisionLocked(),
                  input.changes.isEmpty else { return nil }
            key = Self.bl6NameKey(for: original.serverID)
            serverID = original.serverID
            next = original.previousName
        default: return nil
        }
        guard let current = servers.first(where: { $0.id == serverID }),
              current.descriptorFingerprint == (
                  input.operation == .rollback
                      ? bl6NameCompletions.values.first(where: {
                          $0.record.receipt.receiptID == input.undoReceiptID
                      })?.descriptorFingerprint ?? ""
                      : current.descriptorFingerprint
              ) else { return nil }
        if input.operation == .rollback,
           let original = bl6NameCompletions.values.first(where: {
               $0.record.receipt.receiptID == input.undoReceiptID
           }), current.name != original.resultingName { return nil }
        return (serverID, key, current.name, next)
    }

    private static func bl6NameKey(for serverID: String) -> String {
        "mcp." + serverID.utf8.map { String(format: "%02x", $0) }.joined() + ".name"
    }

    private static func bl6EnabledKey(for serverID: String) -> String {
        "mcp." + serverID.utf8.map { String(format: "%02x", $0) }.joined() + ".enabled"
    }

    private func bl6NameRevisionLocked(
        servers candidate: [MCPServer]? = nil, revision candidateRevision: Int? = nil
    ) -> String {
        let material = BL6NameRevisionMaterial(
            revision: candidateRevision ?? revision,
            servers: (candidate ?? servers).map {
                BL6NameRevisionMaterial.Server(
                    id: $0.id, name: $0.name, enabled: $0.enabled,
                    descriptorFingerprint: $0.descriptorFingerprint
                )
            }.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(material) else { return "invalid" }
        return "\(material.revision):\(DeletionGate.fingerprint(data))"
    }

    private static func bl6ServerID(fromNameKey key: String) -> String? {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "mcp", parts[2] == "name",
              parts[1].count.isMultiple(of: 2), !parts[1].isEmpty,
              parts[1].count <= 512 else { return nil }
        var bytes: [UInt8] = []
        let hex = Array(parts[1])
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let value = UInt8(String(hex[index...index + 1]), radix: 16) else { return nil }
            bytes.append(value)
        }
        guard let id = String(bytes: bytes, encoding: .utf8),
              bl6NameKey(for: id) == key else { return nil }
        return id
    }

    private static func bl6ServerID(fromEnabledKey key: String) -> String? {
        let nameKey = String(key.dropLast(".enabled".count)) + ".name"
        guard key.hasSuffix(".enabled"), let id = bl6ServerID(fromNameKey: nameKey),
              bl6EnabledKey(for: id) == key else { return nil }
        return id
    }

    /// Return the last accepted tools/list result when it still belongs to
    /// the current enabled and explicitly authorized server configuration.
    /// This is the cross-turn production discovery cache; callers still need
    /// a refresh action when they want to observe remote changes.
    public func discoverySnapshot(serverID: String) -> MCPDiscoverySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = discoverySnapshots[serverID],
              isValidDiscoverySnapshotLocked(serverID: serverID, snapshot: snapshot) else { return nil }
        return snapshot
    }

    public func cachedTools(serverID: String) -> [MCPTool] {
        discoverySnapshot(serverID: serverID)?.tools ?? []
    }

    /// A failed explicit rediscovery is an observed disconnect for this
    /// configuration. Retire only the snapshot that the failed attempt saw;
    /// a concurrent successful refresh must not lose its newer catalog.
    /// Keep server and tool grants intact so a later successful discovery can
    /// rebind the same authorized schema without silently widening authority.
    @discardableResult
    public func retireDiscoveryAfterFailedRefresh(
        serverID: String, expected: MCPDiscoverySnapshot?
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let expected,
              let current = discoverySnapshots[serverID],
              Self.isSamePublication(current, expected) else { return false }
        // This is an observed-dead runtime publication, not a configuration or
        // grant mutation. Retire it even if the persistent pair is busy. Keep
        // the publication guard so a newer successful publication survives.
        discoverySnapshots.removeValue(forKey: serverID)
        transportGenerations.removeValue(forKey: serverID)
        try beginPersistentMutationLocked()
        defer { endPersistentMutationLocked() }
        // Do not restore an observed-dead cache on write failure. The caller
        // will fail the whole refresh, so this process advertises no stale MCP
        // tool even when durable cache retirement cannot be confirmed.
        try saveLocked(persistAuthorizations: false)
        return true
    }

    /// The same tools/list publication, possibly re-stamped to a newer
    /// revision by a tool grant change (which alters only `revision`/`id`).
    /// A nil publication identity (reloaded record) needs exact equality.
    private static func isSamePublication(
        _ current: MCPDiscoverySnapshot, _ expected: MCPDiscoverySnapshot
    ) -> Bool {
        if current == expected { return true }
        guard let currentID = current.publicationID, currentID == expected.publicationID else { return false }
        return current.serverID == expected.serverID
            && current.descriptorFingerprint == expected.descriptorFingerprint
            && current.transportGeneration == expected.transportGeneration
            && current.schemaDigest == expected.schemaDigest
            && current.tools == expected.tools
    }

    /// Return a bounded, deterministic view of manager-issued stale-temp
    /// cleanup capabilities. Merely observing a temp never authorizes removal.
    public func staleTempCleanupReceipts(limit: Int = 64) -> [MCPStaleTempCleanupReceipt] {
        lock.lock()
        defer { lock.unlock() }
        let boundedLimit = min(max(limit, 0), Self.maxStaleTempReceipts)
        return Array(staleTempReceipts.prefix(boundedLimit))
    }

    /// Bounded, non-sensitive startup filter stages for test diagnostics.
    /// No path, identity, digest, or file content is exposed.
    func tornTempRecoveryDiagnosticStages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return tornTempRecoveryStages.map(\.rawValue)
    }

    func tornTempRecoveryDiagnosticCounters() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return tornTempRecoveryCounters
    }

    func staleTempCleanupDecisionDiagnosticStage() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastStaleTempCleanupDecisionStage.rawValue
    }

    func cleanupJournalLoadValidityDiagnosticStage() -> String {
        cleanupJournalLoadDiagnosticLock.lock()
        defer { cleanupJournalLoadDiagnosticLock.unlock() }
        return lastCleanupJournalLoadValidityStage.rawValue
    }

    private func setCleanupJournalLoadValidityDiagnosticStage(
        _ stage: CleanupJournalLoadValidityStage
    ) {
        cleanupJournalLoadDiagnosticLock.lock()
        defer { cleanupJournalLoadDiagnosticLock.unlock() }
        lastCleanupJournalLoadValidityStage = stage
    }

    /// Remove one stale temp only with an exact startup-issued receipt. The
    /// receipt is one-shot; absent or repeated requests are no-ops.
    public func cleanupStaleTemp(receipt: MCPStaleTempCleanupReceipt) -> MCPStaleTempCleanupResult {
        lock.lock()
        lastStaleTempCleanupDecisionStage = .issuedGenerationAndScope
        guard staleTempCleanupJournalValid,
              issuedTempReceipts.contains(receipt),
              receipt.generation == staleTempReceiptGeneration,
              receipt.expiresAt > Date(),
              receipt.targetPath == fileURL.path || receipt.targetPath == authorizationFileURL.path else {
            lock.unlock()
            return .rejected
        }
        defer { lock.unlock() }

        do { try beginPersistentMutationLocked() }
        catch { return .rejected }
        defer { endPersistentMutationLocked() }

        let receiptID = Self.receiptID(receipt)
        lastStaleTempCleanupDecisionStage = .currentFilesystemIdentity
        guard Self.receiptMatchesCurrentFile(receipt) else { return .rejected }
        lastStaleTempCleanupDecisionStage = .journalBinding
        if let journalEntry = staleTempCleanupJournal[receiptID] {
            guard journalEntry.state != .committed,
                  journalEntry.scope == receipt.targetPath,
                  journalEntry.transactionUUID == receipt.transactionToken,
                  journalEntry.postGeneration <= staleTempCleanupJournalGeneration,
                  journalEntry.readbackIdentity == Self.cleanupReadbackIdentity(
                    receiptID: receiptID,
                    scope: receipt.targetPath,
                    transactionUUID: receipt.transactionToken,
                    payloadDigest: receipt.payloadDigest.lowercased(),
                    directoryDevice: receipt.directoryDevice,
                    directoryInode: receipt.directoryInode,
                    temporaryDevice: receipt.temporaryDevice,
                    temporaryInode: receipt.temporaryInode,
                    present: true
                  ) else {
                return .rejected
            }
        }
        guard (staleTempCleanupJournalHistory.last?.entry.postGeneration ?? 0) ==
                staleTempCleanupJournalGeneration else { return .rejected }
        lastStaleTempCleanupDecisionStage = .currentFilesystemIdentity
        let temporary = URL(fileURLWithPath: receipt.temporaryPath)
        let directoryDescriptor: Int32
        do {
            guard let lease = persistenceLease else { return .rejected }
            directoryDescriptor = try lease.duplicateParent(
                receipt.targetPath == fileURL.path ? .config : .authorization
            )
        } catch { return .rejected }
        defer { _ = Darwin.close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard fstat(directoryDescriptor, &directoryMetadata) == 0,
              UInt64(directoryMetadata.st_dev) == receipt.directoryDevice,
              UInt64(directoryMetadata.st_ino) == receipt.directoryInode else {
            return .rejected
        }

        var metadata = stat()
        let name = temporary.lastPathComponent
        let statResult = name.withCString {
            fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else {
            issuedTempReceipts.remove(receipt)
            staleTempReceipts.removeAll { $0 == receipt }
            return .alreadyAbsent
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_nlink == 1 else {
            return .rejected
        }
        guard UInt64(metadata.st_dev) == receipt.temporaryDevice,
              UInt64(metadata.st_ino) == receipt.temporaryInode else {
            return .rejected
        }
        let temporaryDescriptor = name.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard temporaryDescriptor >= 0 else { return .rejected }
        defer { _ = Darwin.close(temporaryDescriptor) }
        var openedMetadata = stat()
        guard fstat(temporaryDescriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFREG,
              openedMetadata.st_nlink == 1,
              UInt64(openedMetadata.st_dev) == receipt.temporaryDevice,
              UInt64(openedMetadata.st_ino) == receipt.temporaryInode else {
            return .rejected
        }
        // Re-audit the name immediately before unlink. The open descriptor
        // pins the original inode; a replacement or hard-link change fences
        // this transaction before any directory mutation.
        var preUnlinkMetadata = stat()
        let preUnlinkResult = name.withCString {
            fstatat(directoryDescriptor, $0, &preUnlinkMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard preUnlinkResult == 0,
              (preUnlinkMetadata.st_mode & S_IFMT) == S_IFREG,
              preUnlinkMetadata.st_nlink == 1,
              UInt64(preUnlinkMetadata.st_dev) == UInt64(openedMetadata.st_dev),
              UInt64(preUnlinkMetadata.st_ino) == UInt64(openedMetadata.st_ino) else {
            return .rejected
        }
        guard openedMetadata.st_size >= 0,
              openedMetadata.st_size <= off_t(Self.maxTempCleanupPayloadBytes) else {
            return .rejected
        }
        let reader = FileHandle(fileDescriptor: temporaryDescriptor, closeOnDealloc: false)
        let payloadData: Data
        do {
            payloadData = try reader.readToEnd() ?? Data()
        } catch {
            return .rejected
        }
        guard payloadData.count <= Self.maxTempCleanupPayloadBytes,
              DeletionGate.fingerprint(payloadData) == receipt.payloadDigest.lowercased() else {
            return .rejected
        }
        lastStaleTempCleanupDecisionStage = .journalBinding
        if let journalEntry = staleTempCleanupJournal[receiptID] {
            guard journalEntry.payloadDigest == receipt.payloadDigest.lowercased(),
                  journalEntry.configFingerprint == cleanupConfigFingerprintLocked() else {
                return .rejected
            }
        }

        let previousJournal = staleTempCleanupJournal
        let previousJournalHistory = staleTempCleanupJournalHistory
        let previousJournalGeneration = staleTempCleanupJournalGeneration
        let previousJournalDigest = staleTempCleanupJournalDigest
        let previousJournalBaseGeneration = staleTempCleanupJournalBaseGeneration
        let previousJournalBaseDigest = staleTempCleanupJournalBaseDigest
        let previousJournalCheckpoint = staleTempCleanupJournalCheckpoint
        let previousJournalSegments = staleTempCleanupJournalSegments
        let previousJournalManifestRoot = staleTempCleanupJournalManifestRoot
        let previousJournalManifestEpoch = staleTempCleanupJournalManifestEpoch
        let previousJournalPreviousManifestRoot = staleTempCleanupJournalPreviousManifestRoot
        let previousJournalManifestTombstone = staleTempCleanupJournalManifestTombstone
        let previousJournalManifestTombstoneHistory = staleTempCleanupJournalManifestTombstoneHistory
        let previousJournalManifestTombstoneBase = staleTempCleanupJournalManifestTombstoneBase
        lastStaleTempCleanupDecisionStage = .appendOrHandoffPrepare
        guard appendCleanupJournalRecord(receipt: receipt, receiptID: receiptID, state: .prepared) != nil else {
            return .rejected
        }
        lastStaleTempCleanupDecisionStage = .durablePrepareSave
        do {
            // Persist the consumption decision atomically before unlinking.
            // If this fails, both the temp and its authorization remain.
            try saveLocked(persistAuthorizations: false)
        } catch {
            staleTempCleanupJournal = previousJournal
            staleTempCleanupJournalHistory = previousJournalHistory
            staleTempCleanupJournalGeneration = previousJournalGeneration
            staleTempCleanupJournalDigest = previousJournalDigest
            staleTempCleanupJournalBaseGeneration = previousJournalBaseGeneration
            staleTempCleanupJournalBaseDigest = previousJournalBaseDigest
            staleTempCleanupJournalCheckpoint = previousJournalCheckpoint
            staleTempCleanupJournalSegments = previousJournalSegments
            staleTempCleanupJournalManifestRoot = previousJournalManifestRoot
            staleTempCleanupJournalManifestEpoch = previousJournalManifestEpoch
            staleTempCleanupJournalPreviousManifestRoot = previousJournalPreviousManifestRoot
            staleTempCleanupJournalManifestTombstone = previousJournalManifestTombstone
            staleTempCleanupJournalManifestTombstoneHistory = previousJournalManifestTombstoneHistory
            staleTempCleanupJournalManifestTombstoneBase = previousJournalManifestTombstoneBase
            return .rejected
        }
        lastStaleTempCleanupDecisionStage = .unlink
        guard name.withCString({ unlinkat(directoryDescriptor, $0, 0) }) == 0 else {
            staleTempCleanupJournal = previousJournal
            staleTempCleanupJournalHistory = previousJournalHistory
            staleTempCleanupJournalGeneration = previousJournalGeneration
            staleTempCleanupJournalDigest = previousJournalDigest
            staleTempCleanupJournalBaseGeneration = previousJournalBaseGeneration
            staleTempCleanupJournalBaseDigest = previousJournalBaseDigest
            staleTempCleanupJournalCheckpoint = previousJournalCheckpoint
            staleTempCleanupJournalSegments = previousJournalSegments
            staleTempCleanupJournalManifestRoot = previousJournalManifestRoot
            staleTempCleanupJournalManifestEpoch = previousJournalManifestEpoch
            staleTempCleanupJournalPreviousManifestRoot = previousJournalPreviousManifestRoot
            staleTempCleanupJournalManifestTombstone = previousJournalManifestTombstone
            staleTempCleanupJournalManifestTombstoneHistory = previousJournalManifestTombstoneHistory
            staleTempCleanupJournalManifestTombstoneBase = previousJournalManifestTombstoneBase
            try? saveLocked(persistAuthorizations: false)
            return .rejected
        }
        var postUnlinkMetadata = stat()
        lastStaleTempCleanupDecisionStage = .postUnlink
        let postUnlinkResult = name.withCString {
            fstatat(directoryDescriptor, $0, &postUnlinkMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard postUnlinkResult != 0, errno == ENOENT else {
            // Keep the durable prepared fence. A replacement is never
            // acknowledged as committed and remains for a fresh receipt.
            return .rejected
        }
        // The prepared record is the crash fence. A committed successor is
        // best-effort bookkeeping, but remains chained to the durable prepare.
        lastStaleTempCleanupDecisionStage = .committedBookkeeping
        _ = appendCleanupJournalRecord(receipt: receipt, receiptID: receiptID, state: .committed)
        // A durable prepared record already fences replay if this final write
        // fails after unlink; committed is best-effort bookkeeping for reload.
        try? saveLocked(persistAuthorizations: false)
        issuedTempReceipts.remove(receipt)
        staleTempReceipts.removeAll { $0 == receipt }
        lastStaleTempCleanupDecisionStage = .complete
        return .removed
    }

    /// Perform tools/list and accept the result only if the server,
    /// configuration revision, and server-level authorization are unchanged.
    /// A stale completion is rejected instead of replacing the current cache.
    public func discoverTools(
        serverID: String,
        clientFactory: (@Sendable (MCPServer) -> MCPClient)? = nil
    ) async throws -> [MCPTool] {
        try await discoverTools(
            serverID: serverID,
            clientFactory: clientFactory,
            beforeCommit: {}
        )
    }

    /// Internal scheduling seam for the final discovery admission boundary.
    /// Production uses the empty callback above; focused consumers can make a
    /// configuration change after the last await but before cache commit.
    func discoverTools(
        serverID: String,
        clientFactory: (@Sendable (MCPServer) -> MCPClient)?,
        beforeCommit: @Sendable () throws -> Void,
        disconnectAfterDiscovery: Bool = true
    ) async throws -> [MCPTool] {
        try Task.checkCancellation()
        // Capture the authorization/configuration generation before any
        // await. A response from this discovery may publish only while this
        // exact generation remains current.
        let context: DiscoveryContext = try lock.withLock {
            guard let server = servers.first(where: { $0.id == serverID }) else {
                throw MCPDiscoveryError.serverNotFound(serverID)
            }
            guard server.enabled else {
                throw MCPDiscoveryError.serverDisabled(serverID)
            }
            guard let authorization = authorizations[serverID],
                  authorization.serverAuthorized,
                  authorization.serverID == serverID,
                  authorization.descriptorFingerprint == server.descriptorFingerprint else {
                throw MCPDiscoveryError.unauthorized(serverID)
            }
            return DiscoveryContext(
                server: server,
                generation: revision,
                descriptorFingerprint: server.descriptorFingerprint,
                authorization: authorization
            )
        }

        let client = clientFactory?(context.server) ?? makeClient(server: context.server)
        defer { if disconnectAfterDiscovery { client.disconnect() } }
        guard client.server.id == context.server.id,
              client.server.descriptorFingerprint == context.descriptorFingerprint else {
            throw MCPDiscoveryError.serverIdentityChanged(serverID)
        }
        try await client.connect()
        var tools: [MCPTool] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var transportGeneration: UInt64?
        var totalTools = 0
        var totalJSONBytes = 0
        var totalSerializedSchemaBytes = 0
        var finished = false
        for _ in 0..<Self.maxDiscoveryPages {
            try Task.checkCancellation()
            guard isCurrentDiscoveryContext(context) else {
                throw MCPDiscoveryError.stale(serverID)
            }
            let page = try await client.listToolsPage(cursor: cursor)
            // A changed context must never fetch another page. A complete
            // result can still match an already-published first binding.
            if page.nextCursor != nil, !isCurrentDiscoveryContext(context) {
                throw MCPDiscoveryError.stale(serverID)
            }
            guard page.serverIdentity == "\(context.server.id):\(context.descriptorFingerprint)" else {
                throw MCPDiscoveryError.serverIdentityChanged(serverID)
            }
            guard client.lifecycleSnapshot.generation == page.transportGeneration else {
                throw MCPDiscoveryError.transportEpochChanged(serverID)
            }
            if let transportGeneration {
                guard page.transportGeneration == transportGeneration else {
                    throw MCPDiscoveryError.transportEpochChanged(serverID)
                }
            } else {
                transportGeneration = page.transportGeneration
            }
            totalTools += page.tools.count
            totalJSONBytes += page.jsonBytes
            totalSerializedSchemaBytes += page.serializedSchemaBytes
            guard page.tools.count <= Self.maxDiscoveryToolsPerPage,
                  page.serializedSchemaBytes <= Self.maxDiscoveryPageSchemaBytes,
                  totalTools <= Self.maxDiscoveryTools,
                  totalJSONBytes <= Self.maxDiscoveryJSONBytes,
                  totalSerializedSchemaBytes <= Self.maxDiscoverySchemaBytes else {
                throw MCPDiscoveryError.limitsExceeded(serverID)
            }
            tools.append(contentsOf: page.tools)
            guard let nextCursor = page.nextCursor else {
                finished = true
                break
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw MCPDiscoveryError.repeatedCursor(serverID: serverID, cursor: nextCursor)
            }
            cursor = nextCursor
        }
        guard finished else {
            throw MCPDiscoveryError.pageLimitExceeded(serverID)
        }
        let normalizedTools = try Self.normalizedDiscoveryTools(tools, serverID: serverID)
        try Task.checkCancellation()

        guard let transportGeneration,
              client.lifecycleSnapshot.generation == transportGeneration else {
            throw MCPDiscoveryError.transportEpochChanged(serverID)
        }
        guard lock.withLock({
            isCurrentDiscoveryContextLocked(context)
                || acceptedDuplicateDiscoveryLocked(context, tools: normalizedTools) != nil
        }) else {
            throw MCPDiscoveryError.stale(serverID)
        }
        try beforeCommit()
        return try lock.withLock {
            // Revalidate the captured authority before a disk-fence failure can
            // retire anything. A late response must not revoke a newer grant.
            guard isCurrentDiscoveryContextLocked(context) else {
                guard let accepted = acceptedDuplicateDiscoveryLocked(context, tools: normalizedTools) else {
                    throw MCPDiscoveryError.stale(serverID)
                }
                try beginPersistentMutationLocked()
                defer { endPersistentMutationLocked() }
                try Task.checkCancellation()
                return accepted.tools
            }
            do {
                try beginPersistentMutationLocked()
            } catch {
                // A validated remote schema observation is a runtime denial
                // boundary even when the physical pair cannot admit a write.
                // Never publish the new cache or bypass the failed disk fence.
                let observedDigest = MCPDiscoverySnapshot.schemaDigest(for: normalizedTools)
                let snapshotChanged = discoverySnapshots[serverID].map {
                    $0.schemaDigest != observedDigest
                } ?? false
                let grantChanged: Bool
                if let boundDigest = authorizations[serverID]?.schemaBindingDigest {
                    grantChanged = !boundDigest.isEmpty && boundDigest != observedDigest
                } else {
                    grantChanged = false
                }
                if snapshotChanged || grantChanged {
                    schemaEpochs[serverID] = schemaLineage.observe(
                        serverID: serverID, digest: observedDigest
                    )
                    if grantChanged, var grant = authorizations[serverID] {
                        grant.authorizedToolNames.removeAll()
                        grant.schemaBindingDigest = nil
                        authorizations[serverID] = grant
                        pendingSchemaRevocations.insert(serverID)
                    }
                    discoverySnapshots.removeValue(forKey: serverID)
                    transportGenerations.removeValue(forKey: serverID)
                }
                throw error
            }
            defer { endPersistentMutationLocked() }
            // The prior check can race with disable/remove/re-enable and a
            // fresh explicit grant before this lock is acquired. Never stamp
            // an old tools/list result with the newer manager revision.
            guard isCurrentDiscoveryContextLocked(context) else {
                throw MCPDiscoveryError.stale(serverID)
            }
            // Record the observation even if a later persistence step fails:
            // a known changed remote schema must retire prior turn snapshots.
            let observedDigest = MCPDiscoverySnapshot.schemaDigest(for: normalizedTools)
            let schemaEpoch = schemaLineage.observe(serverID: serverID, digest: observedDigest)
            schemaEpochs[serverID] = schemaEpoch
            if pendingSchemaRevocations.contains(serverID) {
                try saveAuthorizationsLocked()
            }
            let snapshot = MCPDiscoverySnapshot(
                serverID: serverID,
                revision: revision,
                descriptorFingerprint: context.descriptorFingerprint,
                tools: normalizedTools,
                transportGeneration: transportGeneration,
                publicationID: UUID()
            )
            let previousSnapshot = discoverySnapshots[serverID]
            let previousTransportGeneration = transportGenerations[serverID]
            // A pre-discovery grant binds to the first observed schema. A
            // changed schema revokes the old names rather than merely making
            // their old digest mismatch: A -> B -> A cannot resurrect them.
            if var grant = authorizations[serverID],
               !grant.authorizedToolNames.isEmpty {
                if grant.schemaBindingDigest == "" {
                    let previousGrant = grant
                    grant.schemaBindingDigest = snapshot.schemaDigest
                    authorizations[serverID] = grant
                    do {
                        try saveAuthorizationsLocked()
                    } catch {
                        authorizations[serverID] = previousGrant
                        throw error
                    }
                } else if let boundDigest = grant.schemaBindingDigest,
                          boundDigest != snapshot.schemaDigest {
                    grant.authorizedToolNames.removeAll()
                    grant.schemaBindingDigest = nil
                    authorizations[serverID] = grant
                    do {
                        try saveAuthorizationsLocked()
                    } catch {
                        // Never restore the old grant after observing drift.
                        // The next discovery must durably save this denial
                        // before exposing any replacement cache.
                        pendingSchemaRevocations.insert(serverID)
                        throw error
                    }
                }
            }
            discoverySnapshots[serverID] = snapshot
            transportGenerations[serverID] = transportGeneration
            do {
                // Discovery only changes the server-file cache. Keep the
                // authorization file untouched so a cache write cannot create a
                // mixed two-file state when its independent write fails.
                try saveLocked(persistAuthorizations: false)
            } catch {
                if let previousSnapshot {
                    discoverySnapshots[serverID] = previousSnapshot
                } else {
                    discoverySnapshots.removeValue(forKey: serverID)
                }
                if let previousTransportGeneration {
                    transportGenerations[serverID] = previousTransportGeneration
                } else {
                    transportGenerations.removeValue(forKey: serverID)
                }
                throw error
            }
            return snapshot.tools
        }
    }

    private func isCurrentDiscoveryContext(_ context: DiscoveryContext) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentDiscoveryContextLocked(context)
    }

    /// Caller holds `lock`; used again at the commit seam to close the gap
    /// between a successful async discovery check and durable publication.
    private func isCurrentDiscoveryContextLocked(_ context: DiscoveryContext) -> Bool {
        guard persistenceConflict == nil, let latestServer = servers.first(where: { $0.id == context.server.id }),
              latestServer.enabled,
              latestServer.descriptorFingerprint == context.descriptorFingerprint,
              revision == context.generation,
              authorizations[context.server.id] == context.authorization else {
            return false
        }
        return true
    }

    /// A concurrent discovery may have bound the same explicit grant to this
    /// schema. Reuse that publication only if the binding was the sole change.
    private func acceptedDuplicateDiscoveryLocked(
        _ context: DiscoveryContext, tools: [MCPTool]
    ) -> MCPDiscoverySnapshot? {
        let serverID = context.server.id
        guard context.authorization.schemaBindingDigest == "",
              !context.authorization.authorizedToolNames.isEmpty,
              revision == context.generation,
              let accepted = discoverySnapshots[serverID],
              accepted.descriptorFingerprint == context.descriptorFingerprint,
              accepted.tools == tools,
              isValidDiscoverySnapshotLocked(serverID: serverID, snapshot: accepted) else {
            return nil
        }
        var expectedAuthorization = context.authorization
        expectedAuthorization.schemaBindingDigest = accepted.schemaDigest
        return authorizations[serverID] == expectedAuthorization ? accepted : nil
    }

    /// Validate a cache entry while the manager lock is held. The transport
    /// generation is intentionally runtime-bound, so a durable record cannot
    /// become executable merely because its server descriptor still matches.
    private func isValidDiscoverySnapshotLocked(
        serverID: String,
        snapshot: MCPDiscoverySnapshot
    ) -> Bool {
        guard persistenceConflict == nil, let server = servers.first(where: { $0.id == serverID }),
              server.enabled,
              let grant = authorizations[serverID],
              grant.serverAuthorized,
              grant.serverID == serverID,
              grant.descriptorFingerprint == server.descriptorFingerprint,
              snapshot.serverID == serverID,
              snapshot.revision == revision,
              snapshot.descriptorFingerprint == server.descriptorFingerprint,
              snapshot.id == "\(serverID):r\(snapshot.revision):\(snapshot.descriptorFingerprint)",
              snapshot.transportGeneration > 0,
              transportGenerations[serverID] == snapshot.transportGeneration,
              let schemaEpoch = schemaEpochs[serverID],
              schemaLineage.accepts(serverID: serverID, digest: snapshot.schemaDigest, epoch: schemaEpoch),
              snapshot.schemaDigest == MCPDiscoverySnapshot.schemaDigest(for: snapshot.tools) else {
            return false
        }
        return true
    }

    private static func normalizedDiscoveryTools(_ tools: [MCPTool], serverID: String) throws -> [MCPTool] {
        var normalizedByName: [String: MCPTool] = [:]
        for tool in tools {
            let normalizedName = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { continue }
            let normalized = MCPTool(
                name: normalizedName,
                description: tool.description,
                inputSchema: tool.inputSchema,
                _meta: tool._meta
            )
            if let existing = normalizedByName[normalizedName] {
                guard existing == normalized else {
                    throw MCPDiscoveryError.toolConflict(serverID: serverID, toolName: normalizedName)
                }
                continue // Exact duplicate: retain one canonical definition.
            }
            normalizedByName[normalizedName] = normalized
        }
        return normalizedByName.values.sorted(by: MCPDiscoverySnapshot.stableToolOrder)
    }

    /// Return the current replacement-session state without exposing secrets.
    /// The ID is stable for the same server revision and descriptor.
    public func replacementSessionState(serverID: String) -> MCPReplacementSessionState {
        lock.lock()
        defer { lock.unlock() }
        guard let server = servers.first(where: { $0.id == serverID }) else {
            return MCPReplacementSessionState(
                serverID: serverID,
                revision: revision,
                descriptorFingerprint: "missing",
                phase: .missing
            )
        }
        return MCPReplacementSessionState(
            serverID: server.id,
            revision: revision,
            descriptorFingerprint: server.descriptorFingerprint,
            phase: server.enabled ? .active : .disabled
        )
    }

    /// Servers currently enabled (used for tool discovery / prompt injection).
    public func enabledServers() -> [MCPServer] {
        listServers().filter { $0.enabled }
    }

    /// Missing or stale records are deny-all. This is the only persisted
    /// authorization state consulted by the production MCP registry.
    public func authorization(serverID: String) -> MCPToolAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        return persistenceConflict == nil ? authorizations[serverID] : nil
    }

    public func isServerAuthorized(_ server: MCPServer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard persistenceConflict == nil, server.enabled,
              let grant = authorizations[server.id],
              grant.serverAuthorized,
              grant.serverID == server.id,
              grant.descriptorFingerprint == server.descriptorFingerprint else {
            return false
        }
        return true
    }

    public func isToolAuthorized(serverID: String, toolName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard persistenceConflict == nil, let server = servers.first(where: { $0.id == serverID }),
              server.enabled,
              let grant = authorizations[serverID],
              grant.serverAuthorized,
              grant.serverID == serverID,
              grant.descriptorFingerprint == server.descriptorFingerprint,
              grant.authorizedToolNames.contains(toolName),
              let boundDigest = grant.schemaBindingDigest else {
            return false
        }
        // A name granted before the first discovery remains a persisted grant,
        // but the bridge cannot advertise or execute it without a valid cache.
        guard let discovery = discoverySnapshots[serverID] else { return true }
        guard isValidDiscoverySnapshotLocked(serverID: serverID, snapshot: discovery) else {
            return false
        }
        return boundDigest == discovery.schemaDigest
    }

    @discardableResult
    public func authorizeServer(id: String) throws -> MCPToolAuthorization {
        lock.lock()
        defer { lock.unlock() }
        try beginPersistentMutationLocked()
        defer { endPersistentMutationLocked() }
        guard let server = servers.first(where: { $0.id == id }) else {
            throw MCPClientError.invalidServer("unknown server '\(id)'")
        }
        let existing = authorizations[id]
        let grant = MCPToolAuthorization(
            serverID: id,
            descriptorFingerprint: server.descriptorFingerprint,
            serverAuthorized: true,
            authorizedToolNames: existing?.descriptorFingerprint == server.descriptorFingerprint
                ? (existing?.authorizedToolNames ?? [])
                : [],
            schemaBindingDigest: existing?.descriptorFingerprint == server.descriptorFingerprint
                ? existing?.schemaBindingDigest : nil
        )
        let oldAuthorizations = authorizations
        let oldRevision = revision
        authorizations[id] = grant
        revision += 1
        do {
            try saveAuthorizationsLocked()
        } catch {
            authorizations = oldAuthorizations
            revision = oldRevision
            throw error
        }
        return grant
    }

    @discardableResult
    public func authorizeTool(serverID: String, toolName: String) throws -> MCPToolAuthorization {
        lock.lock()
        defer { lock.unlock() }
        try beginPersistentMutationLocked()
        defer { endPersistentMutationLocked() }
        guard let server = servers.first(where: { $0.id == serverID }),
              let existing = authorizations[serverID],
              existing.serverAuthorized,
              existing.descriptorFingerprint == server.descriptorFingerprint else {
            throw MCPClientError.permissionDenied("mcp_\(serverID)_\(toolName)")
        }
        var updated = existing
        let currentDigest: String
        // Snapshots accepted right now; a tool grant changes no discovery
        // input, so they are re-stamped below instead of being retired.
        let acceptedSnapshots = validDiscoverySnapshotsLocked()
        if let discovery = acceptedSnapshots[serverID] {
            currentDigest = discovery.schemaDigest
        } else {
            // Preserve the existing authorize-before-first-discovery flow.
            // The empty marker is never executable; discovery binds it once.
            currentDigest = ""
        }
        if updated.schemaBindingDigest != currentDigest {
            // A changed schema cannot inherit grants for any other tool.
            updated.authorizedToolNames = [toolName]
        } else {
            updated.authorizedToolNames.insert(toolName)
        }
        updated.schemaBindingDigest = currentDigest
        let oldAuthorizations = authorizations
        let oldSnapshots = discoverySnapshots
        let oldRevision = revision
        authorizations[serverID] = updated
        revision += 1
        restampAcceptedDiscoverySnapshotsLocked(acceptedSnapshots)
        do {
            try saveAuthorizationsLocked()
        } catch {
            authorizations = oldAuthorizations
            discoverySnapshots = oldSnapshots
            revision = oldRevision
            throw error
        }
        return updated
    }

    /// Caller holds `lock`. Cache entries that are valid at this instant.
    private func validDiscoverySnapshotsLocked() -> [String: MCPDiscoverySnapshot] {
        discoverySnapshots.filter { isValidDiscoverySnapshotLocked(serverID: $0.key, snapshot: $0.value) }
    }

    /// Caller holds `lock` and has just advanced `revision` for a tool-level
    /// grant mutation. Only snapshots that were valid immediately before the
    /// mutation are carried to the new revision; every other field (server,
    /// descriptor, transport generation, schema digest, tools, publication) is
    /// unchanged, so descriptor/schema/transport/epoch checks still apply.
    /// The revision bump itself stays: in-flight discovery commits, deletion
    /// intents and turn routes bound to the old revision are still retired.
    private func restampAcceptedDiscoverySnapshotsLocked(
        _ accepted: [String: MCPDiscoverySnapshot]
    ) {
        // `accepted` was read under this same lock hold, so each entry is
        // still the current one.
        for (serverID, old) in accepted {
            discoverySnapshots[serverID] = MCPDiscoverySnapshot(
                serverID: old.serverID,
                revision: revision,
                descriptorFingerprint: old.descriptorFingerprint,
                tools: old.tools,
                transportGeneration: old.transportGeneration,
                schemaDigest: old.schemaDigest,
                publicationID: old.publicationID
            )
        }
    }

    @discardableResult
    public func revokeServer(id: String) throws -> MCPToolAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        try beginPersistentMutationLocked()
        defer { endPersistentMutationLocked() }
        let oldAuthorizations = authorizations
        let oldRevision = revision
        let removed = authorizations.removeValue(forKey: id)
        if removed != nil {
            revision += 1
        }
        do {
            try saveAuthorizationsLocked()
        } catch {
            authorizations = oldAuthorizations
            revision = oldRevision
            throw error
        }
        if removed != nil { disconnectRuntime(serverID: id) }
        return removed
    }

    @discardableResult
    public func revokeTool(serverID: String, toolName: String) throws -> MCPToolAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        try beginPersistentMutationLocked()
        defer { endPersistentMutationLocked() }
        guard var grant = authorizations[serverID] else { return nil }
        let oldAuthorizations = authorizations
        let oldSnapshots = discoverySnapshots
        let acceptedSnapshots = validDiscoverySnapshotsLocked()
        let oldRevision = revision
        grant.authorizedToolNames.remove(toolName)
        authorizations[serverID] = grant
        revision += 1
        restampAcceptedDiscoverySnapshotsLocked(acceptedSnapshots)
        do {
            try saveAuthorizationsLocked()
        } catch {
            authorizations = oldAuthorizations
            discoverySnapshots = oldSnapshots
            revision = oldRevision
            throw error
        }
        return grant
    }

    /// Servers moved by the gate-protected deletion path and retained for recovery.
    public func trashedServers() -> [MCPServer] {
        lock.lock()
        defer { lock.unlock() }
        return trashServers.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    // MARK: - Write (CRUD)

    /// Add or overwrite a server (LWW on id collision). Persists immediately.
    @discardableResult
    public func addServer(_ server: MCPServer) throws -> MCPServer {
        lock.lock()
        defer { lock.unlock() }
        try beginPersistentMutationLocked()
        defer { endPersistentMutationLocked() }
        let oldServers = servers
        let oldTrash = trashServers
        let oldAuthorizations = authorizations
        let oldRevision = revision
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            if servers[idx].descriptorFingerprint != server.descriptorFingerprint {
                authorizations.removeValue(forKey: server.id)
            }
            servers[idx] = server
        } else {
            servers.append(server)
        }
        trashServers.removeAll { $0.id == server.id }
        revision += 1
        do {
            try saveLocked()
        } catch {
            servers = oldServers
            trashServers = oldTrash
            authorizations = oldAuthorizations
            revision = oldRevision
            throw error
        }
        for retired in oldServers + oldTrash where retired.id == server.id
            && (retired.descriptorFingerprint != server.descriptorFingerprint || retired.headers != server.headers) {
            try oauth.retireCredential(server: retired)
        }
        return server
    }

    /// Alias for `addServer` — update = add with same id (follows OpenMinis's approach).
    @discardableResult
    public func updateServer(_ server: MCPServer) throws -> MCPServer {
        try addServer(server)
    }

    /// Legacy deletion is intentionally fail-closed. Callers must obtain an
    /// intent and pass both confirmations to `deleteServer(_:)`.
    @discardableResult
    public func removeServer(id: String) throws -> MCPServer? {
        throw MCPServerDeletionError.legacyEntryDisabled
    }

    /// Build the exact deletion preview that must be confirmed by the caller.
    public func deletionIntent(id: String) throws -> OperationIntent {
        lock.lock()
        defer { lock.unlock() }
        guard let server = servers.first(where: { $0.id == id }) else {
            throw MCPServerDeletionError.serverNotFound(id)
        }
        return DeletionGate.preview(
            operationType: .delete,
            targetID: server.id,
            targetType: "mcp-server",
            targetName: server.name,
            affectedCount: 1,
            impactSummary: "移入 MCP 回收站，可恢复服务器配置",
            reversible: true,
            scopeID: "mcp:\(server.id)",
            revision: revision,
            fingerprint: fingerprint(for: server),
            ttl: 300
        )
    }

    /// Execute a deletion only after DeletionGate validates both confirmations,
    /// lifecycle state, expiry, revision, and target fingerprint.
    public func deleteServer(_ intent: OperationIntent) throws -> DeletionReceipt {
        try DeletionGate.checkLifecycle(intent)

        lock.lock()
        guard let server = servers.first(where: { $0.id == intent.targetID }) else {
            lock.unlock()
            throw MCPServerDeletionError.serverNotFound(intent.targetID)
        }
        let currentRevision = revision
        let currentFingerprint = fingerprint(for: server)
        lock.unlock()

        return try DeletionGate.execute(
            intent,
            currentRevision: currentRevision,
            currentFingerprint: currentFingerprint
        ) { confirmed in
            try self.removeServerAfterValidation(confirmed)
        }
    }

    /// Restore a server from the recovery area. Restoration is separate from
    /// deletion approval and never re-enables the legacy delete bypass.
    @discardableResult
    public func restoreServer(id: String) throws -> MCPServer? {
        lock.lock()
        defer { lock.unlock() }
        try beginPersistentMutationLocked()
        defer { endPersistentMutationLocked() }
        guard let idx = trashServers.firstIndex(where: { $0.id == id }) else { return nil }
        guard !servers.contains(where: { $0.id == id }) else {
            throw MCPServerDeletionError.serverAlreadyExists(id)
        }
        let oldServers = servers
        let oldTrash = trashServers
        let oldRevision = revision
        let restored = trashServers.remove(at: idx)
        servers.append(restored)
        revision += 1
        do {
            try saveLocked()
        } catch {
            servers = oldServers
            trashServers = oldTrash
            revision = oldRevision
            throw error
        }
        return restored
    }

    /// Enable/disable a server. No-op if absent. Returns the updated server.
    @discardableResult
    public func enableServer(id: String, enabled: Bool) throws -> MCPServer? {
        lock.lock()
        defer { lock.unlock() }
        do {
            try beginPersistentMutationLocked()
        } catch {
            if let server = servers.first(where: { $0.id == id }), server.enabled != enabled {
                retireEnablementGrantAfterPreflightFailureLocked(id: id)
            }
            throw error
        }
        defer { endPersistentMutationLocked() }
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return nil }
        // A repeated assignment is not a new enablement transition and must
        // not silently revoke a grant that the user issued afterwards.
        guard servers[idx].enabled != enabled else { return servers[idx] }
        servers[idx].enabled = enabled
        // Both disabling and later re-enabling require a fresh explicit grant.
        // Retire the old grant durably before publishing the new enabled bit:
        // mcps.json and its authorization document are separate files.
        authorizations.removeValue(forKey: id)
        revision += 1
        do {
            try saveAuthorizationsLocked()
            try saveLocked(persistAuthorizations: false)
        } catch {
            // Either write may have reached disk. Keep the live grant absent
            // and require a fresh manager after the ambiguous failure; never
            // restore a grant that may already have been durably revoked.
            bl6NameLedgerValid = false
            disconnectRuntime(serverID: id)
            throw error
        }
        disconnectRuntime(serverID: id)
        return servers[idx]
    }

    /// Keep failed enablement transitions fail-closed even when the config
    /// cannot establish a writable pair. Never publish a new enabled bit here.
    private func retireEnablementGrantAfterPreflightFailureLocked(id: String) {
        let baseline = persistenceBaseline
        authorizations.removeValue(forKey: id)
        revision += 1
        bl6NameLedgerValid = false
        persistenceConflict = .needsReopen
        disconnectRuntime(serverID: id)
        guard let baseline else { return }
        do {
            let lease = try MCPPersistentWriteFence.acquire(
                configURL: fileURL, authorizationURL: authorizationFileURL)
            defer { lease.release() }
            let data = try authorizationDocumentData()
            try lease.replaceAuthorizationsRevokingOnly(
                data, matching: baseline.authorization, maxBytes: Self.maxPersistedMCPDocumentBytes
            ) { parent, name, url in
                try Self.writeDurably(data, parentDescriptor: parent, targetName: name, diagnosticURL: url)
            }
        } catch {
            // A failed auth read/write cannot regain live authority. Do not
            // adopt a new pair baseline or fall back to an unbound path write.
            persistenceFailureDescription = String(describing: error)
        }
    }

    private func removeServerAfterValidation(_ intent: OperationIntent) throws {
        lock.lock()
        defer { lock.unlock() }
        try beginPersistentMutationLocked()
        defer { endPersistentMutationLocked() }
        guard let idx = servers.firstIndex(where: { $0.id == intent.targetID }) else {
            throw DeletionGateError.targetChanged
        }
        guard revision == intent.revision,
              fingerprint(for: servers[idx]) == intent.fingerprint else {
            throw DeletionGateError.targetChanged
        }

        let oldServers = servers
        let oldTrash = trashServers
        let oldAuthorizations = authorizations
        let oldRevision = revision
        let removed = servers.remove(at: idx)
        authorizations.removeValue(forKey: removed.id)
        trashServers.removeAll { $0.id == removed.id }
        trashServers.append(removed)
        revision += 1
        do {
            try saveLocked()
        } catch {
            servers = oldServers
            trashServers = oldTrash
            authorizations = oldAuthorizations
            revision = oldRevision
            throw error
        }
        disconnectRuntime(serverID: removed.id)
        try oauth.retireCredential(server: removed)
    }

    // MARK: - Persistence

    private struct FileShape: Encodable {
        var servers: [MCPServer]
        var trashServers: [MCPServer]
        var revision: Int
        var discoverySnapshots: [String: MCPDiscoverySnapshot]
        var bl6NameCompletions: [String: BL6NameCompletion] = [:]
        var bl6EnablementCompletions: [String: BL6EnablementCompletion] = [:]
        var staleTempCleanupJournal: [String: TempCleanupJournalEntry] = [:]
        var staleTempCleanupJournalHistory: [TempCleanupJournalRecord] = []
        var staleTempCleanupJournalBaseGeneration: UInt64 = 0
        var staleTempCleanupJournalBaseDigest: String = String(repeating: "0", count: 64)
        var staleTempCleanupJournalCheckpoint: TempCleanupJournalCheckpoint? = nil
        var staleTempCleanupJournalSegments: [TempCleanupJournalSegment] = []
        var staleTempCleanupJournalManifestRoot: String = String(repeating: "0", count: 64)
        var staleTempCleanupJournalManifestEpoch: UInt64 = 0
        var staleTempCleanupJournalPreviousManifestRoot: String = String(repeating: "0", count: 64)
        var staleTempCleanupJournalManifestTombstone: TempCleanupJournalManifestTombstone? = nil
        var staleTempCleanupJournalManifestTombstoneHistory: [TempCleanupJournalManifestTombstone] = []
        var staleTempCleanupJournalManifestTombstoneBase: TempCleanupJournalManifestTombstoneBase? = nil
    }

    private struct AuthorizationFileShape: Codable {
        var authorizations: [MCPToolAuthorization]
        /// Authorization mutations advance the discovery generation. Optional
        /// decoding keeps pre-generation authorization files readable.
        var revision: Int?
    }

    private func writeDurablyLocked(
        _ data: Data, document: MCPPersistentWriteFence.Document
    ) throws {
        guard let lease = persistenceLease else { throw MCPPersistenceConflict.needsReopen }
        try lease.withTarget(document) { parentDescriptor, targetName, diagnosticURL in
            try Self.writeDurably(
                data, parentDescriptor: parentDescriptor,
                targetName: targetName, diagnosticURL: diagnosticURL
            )
        }
    }

    /// The lease pins the already locked physical parent. Every filesystem
    /// mutation is fd-relative, so retargeting a parent alias cannot write an
    /// unlocked second directory. URL is diagnostic-only, never an IO target.
    private static func writeDurably(
        _ data: Data, parentDescriptor: Int32, targetName: String, diagnosticURL: URL
    ) throws {
        let transactionToken = UUID().uuidString
        let payloadDigest = DeletionGate.fingerprint(data)
        let temporaryName = ".\(targetName).tmp-\(transactionToken)-\(payloadDigest)"
        let temporaryURL = diagnosticURL.deletingLastPathComponent().appendingPathComponent(temporaryName)
        var descriptor = temporaryName.withCString {
            Darwin.openat(parentDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                          S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw MCPDurableWriteError.openFailed(path: temporaryURL.path, code: errno)
        }
        var renamed = false
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if !renamed { temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) } }
        }

        var writeFailure: MCPDurableWriteError?
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    writeFailure = MCPDurableWriteError.writeFailed(
                        path: temporaryURL.path, code: result < 0 ? errno : EIO
                    )
                    break
                }
            }
        }
        if let writeFailure { throw writeFailure }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MCPDurableWriteError.syncFailed(path: temporaryURL.path, code: errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw MCPDurableWriteError.closeFailed(path: temporaryURL.path, code: errno)
        }
        descriptor = -1

        let renameResult = temporaryName.withCString { oldName in
            targetName.withCString { newName in
                Darwin.renameat(parentDescriptor, oldName, parentDescriptor, newName)
            }
        }
        guard renameResult == 0 else {
            throw MCPDurableWriteError.renameFailed(path: diagnosticURL.path, code: errno)
        }
        renamed = true
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw MCPDurableWriteError.directorySyncFailed(
                path: diagnosticURL.deletingLastPathComponent().path, code: errno
            )
        }
    }

    private static func recoverTornTempFiles(
        for url: URL,
        generation: UInt64,
        expiresAt: Date
    ) -> TornTempRecoveryResult {
        let directory = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent).tmp-"
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return TornTempRecoveryResult(
                receipts: [],
                stages: [.directoryEnumerationRejected],
                counters: TornTempRecoveryCounters()
            )
        }
        let directoryDescriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            return TornTempRecoveryResult(
                receipts: [],
                stages: [.directoryOpenRejected],
                counters: TornTempRecoveryCounters()
            )
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        var directoryMetadata = stat()
        guard fstat(directoryDescriptor, &directoryMetadata) == 0 else {
            return TornTempRecoveryResult(
                receipts: [],
                stages: [.directoryMetadataRejected],
                counters: TornTempRecoveryCounters()
            )
        }
        let directoryDevice = UInt64(directoryMetadata.st_dev)
        let directoryInode = UInt64(directoryMetadata.st_ino)
        var stages: Set<TornTempRecoveryStage> = []
        var counters = TornTempRecoveryCounters()
        let receipts = entries.compactMap { entry -> MCPStaleTempCleanupReceipt? in
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix) else { return nil }
            counters.notePrefixed()
            let suffix = String(name.dropFirst(prefix.count))
            guard let identity = ownedTempIdentity(suffix) else {
                stages.insert(.ownedIdentityRejected)
                return nil
            }
            counters.noteIdentityAccepted()
            var metadata = stat()
            let statResult = name.withCString {
                fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else {
                stages.insert(.candidateMetadataRejected)
                return nil
            }
            counters.noteMetadataAccepted()
            guard (metadata.st_mode & S_IFMT) == S_IFREG else {
                stages.insert(.candidateTypeRejected)
                return nil
            }
            guard metadata.st_nlink == 1 else {
                stages.insert(.candidateLinkCountRejected)
                return nil
            }
            stages.insert(.candidateAccepted)
            // A valid old transaction is deliberately retained for
            // diagnostics: startup has no proof that its token belongs to the
            // new transaction and must never delete it speculatively.
            counters.noteReceiptConstructed()
            return MCPStaleTempCleanupReceipt(
                targetPath: url.path,
                temporaryPath: entry.path,
                transactionToken: identity.transactionToken,
                payloadDigest: identity.payloadDigest,
                directoryPath: directory.path,
                directoryDevice: directoryDevice,
                directoryInode: directoryInode,
                temporaryDevice: UInt64(metadata.st_dev),
                temporaryInode: UInt64(metadata.st_ino),
                generation: generation,
                expiresAt: expiresAt
            )
        }
        .sorted { $0.temporaryPath < $1.temporaryPath }
        .prefix(maxStaleTempReceipts)
        .map { $0 }
        counters.resultReceipts = receipts.count
        return TornTempRecoveryResult(
            receipts: receipts,
            stages: stages.sorted { $0.rawValue < $1.rawValue },
            counters: counters
        )
    }

    private static func ownedTempIdentity(_ suffix: String) -> (transactionToken: String, payloadDigest: String)? {
        let parts = suffix.split(separator: "-").map(String.init)
        guard parts.count == 6,
              let token = UUID(uuidString: parts.dropLast().joined(separator: "-")),
              parts[5].count == 64 else { return nil }
        guard parts[5].allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { return nil }
        return (token.uuidString, parts[5].lowercased())
    }

    static func receiptMatchesCurrentFile(_ receipt: MCPStaleTempCleanupReceipt) -> Bool {
        let target = URL(fileURLWithPath: receipt.targetPath)
        let temporary = URL(fileURLWithPath: receipt.temporaryPath)
        let expectedDirectory = target.deletingLastPathComponent()
        let receiptDirectory = URL(fileURLWithPath: receipt.directoryPath)
        let temporaryDirectory = temporary.deletingLastPathComponent()
        let expectedPrefix = ".\(target.lastPathComponent).tmp-"

        let targetDirectoryDescriptor = expectedDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard targetDirectoryDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(targetDirectoryDescriptor) }
        let receiptDirectoryDescriptor = receiptDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard receiptDirectoryDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(receiptDirectoryDescriptor) }
        let temporaryDirectoryDescriptor = temporaryDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard temporaryDirectoryDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(temporaryDirectoryDescriptor) }

        func trustedDirectoryMetadata(_ descriptor: Int32) -> stat? {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  metadata.st_uid == getuid(),
                  (metadata.st_mode & mode_t(0o022)) == 0,
                  UInt64(metadata.st_dev) == receipt.directoryDevice,
                  UInt64(metadata.st_ino) == receipt.directoryInode else {
                return nil
            }
            return metadata
        }
        guard let targetDirectoryMetadata = trustedDirectoryMetadata(targetDirectoryDescriptor),
              let receiptDirectoryMetadata = trustedDirectoryMetadata(receiptDirectoryDescriptor),
              let temporaryDirectoryMetadata = trustedDirectoryMetadata(temporaryDirectoryDescriptor),
              targetDirectoryMetadata.st_mode == receiptDirectoryMetadata.st_mode,
              targetDirectoryMetadata.st_mode == temporaryDirectoryMetadata.st_mode,
              targetDirectoryMetadata.st_uid == receiptDirectoryMetadata.st_uid,
              targetDirectoryMetadata.st_uid == temporaryDirectoryMetadata.st_uid,
              temporary.lastPathComponent.hasPrefix(expectedPrefix),
              let identity = ownedTempIdentity(String(temporary.lastPathComponent.dropFirst(expectedPrefix.count))),
              identity.transactionToken == receipt.transactionToken,
              identity.payloadDigest == receipt.payloadDigest.lowercased() else { return false }
        return true
    }

    static func receiptID(_ receipt: MCPStaleTempCleanupReceipt) -> String {
        let identity = [
            receipt.targetPath,
            receipt.temporaryPath,
            receipt.transactionToken,
            receipt.payloadDigest,
            receipt.directoryPath,
            String(receipt.directoryDevice),
            String(receipt.directoryInode),
            String(receipt.temporaryDevice),
            String(receipt.temporaryInode)
        ].joined(separator: "\u{1f}")
        return DeletionGate.fingerprint(identity)
    }

    /// Stable digest for one journal link. The timestamp is deliberately not
    /// part of the link, so replaying the same logical transition cannot make
    /// a second valid chain.
    static func cleanupJournalRecordDigest(
        receiptID: String,
        generation: UInt64,
        previousDigest: String,
        state: String,
        scope: String,
        transactionUUID: String,
        preGeneration: UInt64,
        postGeneration: UInt64,
        payloadDigest: String,
        configFingerprint: String,
        readbackIdentity: String
    ) -> String {
        DeletionGate.fingerprint(
            [receiptID, String(generation), previousDigest, state, scope, transactionUUID,
             String(preGeneration), String(postGeneration)].joined(separator: "\u{1f}")
            + "\u{1f}" + payloadDigest + "\u{1f}" + configFingerprint
            + "\u{1f}" + readbackIdentity
        )
    }

    static func cleanupJournalCheckpointDigest(
        epoch: UInt64,
        receiptID: String,
        transactionUUID: String,
        generation: UInt64,
        digest: String
    ) -> String {
        DeletionGate.fingerprint([
            String(epoch), receiptID, transactionUUID, String(generation), digest
        ].joined(separator: "\u{1f}"))
    }

    private static func cleanupJournalManifest(
        history: [TempCleanupJournalRecord],
        baseGeneration: UInt64,
        baseDigest: String,
        checkpoint: TempCleanupJournalCheckpoint?,
        epoch: UInt64,
        previousRoot: String
    ) -> (segments: [TempCleanupJournalSegment], root: String) {
        guard !history.isEmpty else {
            return ([], emptyTempCleanupJournalDigest)
        }
        let chunks = stride(from: 0, to: history.count, by: tempCleanupJournalSegmentRecordLimit)
            .map { start in Array(history[start..<min(start + tempCleanupJournalSegmentRecordLimit, history.count)]) }
        let segments = chunks.enumerated().map { offset, records in
            let ordinal = UInt64(offset)
            let first = records[0].entry
            let last = records[records.count - 1].entry
            let previousDigest = first.previousDigest
            let readbackIdentity = DeletionGate.fingerprint(records.map { record in
                [record.receiptID, record.entry.digest, record.entry.readbackIdentity]
                    .joined(separator: "\u{1f}")
            }.joined(separator: "\u{1e}"))
            let identity = DeletionGate.fingerprint([
                String(ordinal), previousDigest, String(first.generation), String(last.generation),
                first.digest, last.digest, String(records.count)
            ].joined(separator: "\u{1f}"))
            return TempCleanupJournalSegment(
                ordinal: ordinal,
                previousDigest: previousDigest,
                startGeneration: first.generation,
                endGeneration: last.generation,
                startDigest: first.digest,
                endDigest: last.digest,
                recordCount: UInt64(records.count),
                identity: identity,
                readbackIdentity: readbackIdentity
            )
        }
        let checkpointDigest = checkpoint?.checkpointDigest ?? emptyTempCleanupJournalDigest
        let rootPayload = (["manifest", String(epoch), previousRoot, String(baseGeneration), baseDigest, checkpointDigest] + segments.flatMap { segment in
            [String(segment.ordinal), segment.previousDigest, String(segment.startGeneration), String(segment.endGeneration),
             segment.startDigest, segment.endDigest, String(segment.recordCount),
             segment.identity, segment.readbackIdentity]
        }).joined(separator: "\u{1d}")
        return (segments, DeletionGate.fingerprint(rootPayload))
    }

    private static func cleanupJournalManifestTombstoneDigest(
        epoch: UInt64,
        root: String,
        successorEpoch: UInt64,
        successorRoot: String,
        checkpointEpoch: UInt64,
        checkpointDigest: String
    ) -> String {
        DeletionGate.fingerprint([
            String(epoch), root, String(successorEpoch), successorRoot,
            String(checkpointEpoch), checkpointDigest
        ].joined(separator: "\u{1f}"))
    }

    private static func cleanupJournalManifestTombstone(
        epoch: UInt64,
        root: String,
        successorEpoch: UInt64,
        successorRoot: String,
        checkpoint: TempCleanupJournalCheckpoint?
    ) -> TempCleanupJournalManifestTombstone {
        let checkpointEpoch = checkpoint?.epoch ?? 0
        let checkpointDigest = checkpoint?.checkpointDigest ?? emptyTempCleanupJournalDigest
        return TempCleanupJournalManifestTombstone(
            epoch: epoch,
            root: root,
            successorEpoch: successorEpoch,
            successorRoot: successorRoot,
            checkpointEpoch: checkpointEpoch,
            checkpointDigest: checkpointDigest,
            tombstoneDigest: cleanupJournalManifestTombstoneDigest(
                epoch: epoch,
                root: root,
                successorEpoch: successorEpoch,
                successorRoot: successorRoot,
                checkpointEpoch: checkpointEpoch,
                checkpointDigest: checkpointDigest
            )
        )
    }

    private static func cleanupJournalManifestTombstoneBaseDigest(
        epoch: UInt64,
        root: String,
        compactionEpoch: UInt64,
        checkpointEpoch: UInt64,
        checkpointDigest: String,
        successorEpoch: UInt64,
        successorRoot: String
    ) -> String {
        DeletionGate.fingerprint([
            String(epoch), root, String(compactionEpoch), String(checkpointEpoch), checkpointDigest,
            String(successorEpoch), successorRoot
        ].joined(separator: "\u{1f}"))
    }

    private static func cleanupJournalManifestTombstoneBase(
        first: TempCleanupJournalManifestTombstone,
        checkpoint: TempCleanupJournalCheckpoint?,
        compactionEpoch: UInt64,
        successorEpoch: UInt64,
        successorRoot: String
    ) -> TempCleanupJournalManifestTombstoneBase {
        let checkpointEpoch = checkpoint?.epoch ?? 0
        let checkpointDigest = checkpoint?.checkpointDigest ?? emptyTempCleanupJournalDigest
        return TempCleanupJournalManifestTombstoneBase(
            epoch: first.epoch,
            root: first.root,
            compactionEpoch: compactionEpoch,
            checkpointEpoch: checkpointEpoch,
            checkpointDigest: checkpointDigest,
            successorEpoch: successorEpoch,
            successorRoot: successorRoot,
            baseDigest: cleanupJournalManifestTombstoneBaseDigest(
                epoch: first.epoch,
                root: first.root,
                compactionEpoch: compactionEpoch,
                checkpointEpoch: checkpointEpoch,
                checkpointDigest: checkpointDigest,
                successorEpoch: successorEpoch,
                successorRoot: successorRoot
            )
        )
    }

    private func rebuildCleanupJournalManifestLocked() {
        let epoch = staleTempCleanupJournalHistory.isEmpty ? 0 : staleTempCleanupJournalGeneration
        let previousRoot = epoch == 0
            ? Self.emptyTempCleanupJournalDigest
            : staleTempCleanupJournalManifestRoot
        let manifest = Self.cleanupJournalManifest(
            history: staleTempCleanupJournalHistory,
            baseGeneration: staleTempCleanupJournalBaseGeneration,
            baseDigest: staleTempCleanupJournalBaseDigest,
            checkpoint: staleTempCleanupJournalCheckpoint,
            epoch: epoch,
            previousRoot: previousRoot
        )
        staleTempCleanupJournalSegments = manifest.segments
        staleTempCleanupJournalManifestRoot = manifest.root
        staleTempCleanupJournalManifestEpoch = epoch
        staleTempCleanupJournalPreviousManifestRoot = previousRoot
        let tombstone: TempCleanupJournalManifestTombstone? = epoch == 0
            ? nil
            : Self.cleanupJournalManifestTombstone(
                epoch: epoch - 1,
                root: previousRoot,
                successorEpoch: epoch,
                successorRoot: manifest.root,
                checkpoint: staleTempCleanupJournalCheckpoint
            )
        if let tombstone {
            var compactionEpoch = staleTempCleanupJournalManifestTombstoneBase?.compactionEpoch ?? 0
            if staleTempCleanupJournalManifestTombstoneHistory.last != tombstone {
                staleTempCleanupJournalManifestTombstoneHistory.append(tombstone)
            }
            if staleTempCleanupJournalManifestTombstoneHistory.count > Self.maxTempCleanupJournalManifestTombstones {
                staleTempCleanupJournalManifestTombstoneHistory.removeFirst(
                    staleTempCleanupJournalManifestTombstoneHistory.count -
                        Self.maxTempCleanupJournalManifestTombstones
                )
                if compactionEpoch < UInt64.max { compactionEpoch += 1 }
            }
            staleTempCleanupJournalManifestTombstoneBase = Self.cleanupJournalManifestTombstoneBase(
                first: staleTempCleanupJournalManifestTombstoneHistory[0],
                checkpoint: staleTempCleanupJournalCheckpoint,
                compactionEpoch: compactionEpoch,
                successorEpoch: epoch,
                successorRoot: manifest.root
            )
        } else {
            staleTempCleanupJournalManifestTombstoneHistory.removeAll()
            staleTempCleanupJournalManifestTombstoneBase = nil
        }
        staleTempCleanupJournalManifestTombstone = tombstone
    }

    private static func validateCleanupJournalManifest(
        history: [TempCleanupJournalRecord],
        baseGeneration: UInt64,
        baseDigest: String,
        checkpoint: TempCleanupJournalCheckpoint?,
        generation: UInt64,
        manifestEpoch: UInt64?,
        previousRoot: String?,
        segments: [TempCleanupJournalSegment]?,
        root: String?,
        tombstone: TempCleanupJournalManifestTombstone?,
        tombstoneHistory: [TempCleanupJournalManifestTombstone]?,
        tombstoneBase: TempCleanupJournalManifestTombstoneBase?
    ) -> Bool {
        guard segments != nil || root != nil || manifestEpoch != nil || previousRoot != nil || tombstone != nil else {
            return true
        }
        guard let segments, let root,
              let manifestEpoch, let previousRoot,
              segments.count <= maxTempCleanupJournalSegments,
              root.count == 64,
              root.allSatisfy({ "0123456789abcdef".contains($0) }),
              previousRoot.count == 64,
              previousRoot.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        let expectedEpoch = history.isEmpty ? 0 : generation
        guard manifestEpoch == expectedEpoch,
              (manifestEpoch == 0 ? previousRoot == emptyTempCleanupJournalDigest : true) else {
            return false
        }
        let expected = cleanupJournalManifest(
            history: history,
            baseGeneration: baseGeneration,
            baseDigest: baseDigest,
            checkpoint: checkpoint,
            epoch: manifestEpoch,
            previousRoot: previousRoot
        )
        guard segments == expected.segments && root == expected.root else { return false }
        let expectedTombstone = manifestEpoch == 0
            ? nil
            : Self.cleanupJournalManifestTombstone(
                epoch: manifestEpoch - 1,
                root: previousRoot,
                successorEpoch: manifestEpoch,
                successorRoot: root,
                checkpoint: checkpoint
            )
        guard tombstone == expectedTombstone else { return false }
        guard manifestEpoch == 0
            ? tombstone == nil && (tombstoneHistory?.isEmpty ?? true) && tombstoneBase == nil
            : tombstone != nil && tombstoneHistory != nil && tombstoneBase != nil else {
            return false
        }
        guard let tombstone, let tombstoneHistory, let tombstoneBase,
              tombstoneHistory.count > 0,
              tombstoneHistory.count <= maxTempCleanupJournalManifestTombstones,
              tombstoneHistory.count == Int(min(
                manifestEpoch,
                UInt64(maxTempCleanupJournalManifestTombstones)
              )),
              tombstoneHistory.last == tombstone,
              tombstoneBase.epoch == (manifestEpoch > UInt64(maxTempCleanupJournalManifestTombstones)
                ? manifestEpoch - UInt64(maxTempCleanupJournalManifestTombstones)
                : 0),
              tombstoneBase.compactionEpoch == tombstoneBase.epoch,
              tombstoneBase.epoch == tombstoneHistory[0].epoch,
              tombstoneBase.root == tombstoneHistory[0].root,
              tombstoneBase.successorEpoch == manifestEpoch,
              tombstoneBase.successorRoot == root,
              tombstoneBase.checkpointEpoch == (checkpoint?.epoch ?? 0),
              tombstoneBase.checkpointDigest == (checkpoint?.checkpointDigest ?? emptyTempCleanupJournalDigest),
              tombstoneBase.baseDigest == cleanupJournalManifestTombstoneBaseDigest(
                epoch: tombstoneBase.epoch,
                root: tombstoneBase.root,
                compactionEpoch: tombstoneBase.compactionEpoch,
                checkpointEpoch: tombstoneBase.checkpointEpoch,
                checkpointDigest: tombstoneBase.checkpointDigest,
                successorEpoch: tombstoneBase.successorEpoch,
                successorRoot: tombstoneBase.successorRoot
              ) else {
            return manifestEpoch == 0
        }
        for (index, item) in tombstoneHistory.enumerated() {
            guard item.root.count == 64,
                  item.root.allSatisfy({ "0123456789abcdef".contains($0) }),
                  item.successorRoot.count == 64,
                  item.successorRoot.allSatisfy({ "0123456789abcdef".contains($0) }),
                  item.checkpointDigest.count == 64,
                  item.checkpointDigest.allSatisfy({ "0123456789abcdef".contains($0) }),
                  item.tombstoneDigest == cleanupJournalManifestTombstoneDigest(
                    epoch: item.epoch,
                    root: item.root,
                    successorEpoch: item.successorEpoch,
                    successorRoot: item.successorRoot,
                    checkpointEpoch: item.checkpointEpoch,
                    checkpointDigest: item.checkpointDigest
                  ),
                  item.epoch < UInt64.max,
                  item.successorEpoch == item.epoch + 1 else {
                return false
            }
            if index > 0 {
                let predecessor = tombstoneHistory[index - 1]
                guard predecessor.successorEpoch == item.epoch,
                      predecessor.successorRoot == item.root else { return false }
            }
        }
        return true
    }

    static func cleanupReadbackIdentity(
        receiptID: String,
        scope: String,
        transactionUUID: String,
        payloadDigest: String,
        directoryDevice: UInt64,
        directoryInode: UInt64,
        temporaryDevice: UInt64,
        temporaryInode: UInt64,
        present: Bool
    ) -> String {
        DeletionGate.fingerprint([
            receiptID, scope, transactionUUID, payloadDigest,
            String(directoryDevice), String(directoryInode),
            String(temporaryDevice), String(temporaryInode), present ? "present" : "absent"
        ].joined(separator: "\u{1f}"))
    }

    private func cleanupConfigFingerprintLocked() -> String {
        Self.cleanupConfigFingerprint(
            fileURL: fileURL,
            authorizationFileURL: authorizationFileURL,
            servers: servers,
            authorizations: authorizations,
            revision: revision
        )
    }

    static func cleanupConfigFingerprint(
        fileURL: URL,
        authorizationFileURL: URL,
        servers: [MCPServer],
        authorizations: [String: MCPToolAuthorization],
        revision: Int
    ) -> String {
        let serverParts = servers.sorted { $0.id < $1.id }.map {
            ["server", $0.id, $0.descriptorFingerprint, $0.enabled ? "1" : "0"].joined(separator: "\u{1f}")
        }
        let authorizationParts = authorizations.keys.sorted().map { key in
            let authorization = authorizations[key] ?? .denyAll
            let fullNames = authorization.allowedFullNames.sorted().joined(separator: "\u{1e}")
            let toolNames = authorization.authorizedToolNames.sorted().joined(separator: "\u{1e}")
            return ["authorization", key, authorization.serverID ?? "", authorization.descriptorFingerprint ?? "",
                    authorization.serverAuthorized ? "1" : "0", fullNames, toolNames,
                    authorization.schemaBindingDigest ?? "<unbound-legacy>"].joined(separator: "\u{1f}")
        }
        return DeletionGate.fingerprint(
            (["scope", fileURL.path, authorizationFileURL.path, String(revision)] + serverParts + authorizationParts)
                .joined(separator: "\u{1d}")
        )
    }

    private func handoffCleanupJournalCheckpointLocked(
        dropped: TempCleanupJournalRecord,
        expectedEpoch: UInt64,
        expectedGeneration: UInt64,
        expectedDigest: String
    ) -> Bool {
        guard expectedEpoch < UInt64.max,
              dropped.entry.generation % UInt64(Self.maxTempCleanupJournalHistory / 2) == 0,
              expectedEpoch + 1 == dropped.entry.generation / UInt64(Self.maxTempCleanupJournalHistory / 2),
              staleTempCleanupJournalGeneration == expectedGeneration,
              staleTempCleanupJournalDigest == expectedDigest else { return false }
        if expectedEpoch == 0 {
            guard staleTempCleanupJournalCheckpoint == nil,
                  staleTempCleanupJournalBaseGeneration == 0,
                  staleTempCleanupJournalBaseDigest == Self.emptyTempCleanupJournalDigest else {
                return false
            }
        } else {
            guard let checkpoint = staleTempCleanupJournalCheckpoint,
                  checkpoint.epoch == expectedEpoch,
                  checkpoint.generation == staleTempCleanupJournalBaseGeneration,
                  checkpoint.digest == staleTempCleanupJournalBaseDigest else {
                return false
            }
        }
        let checkpointEpoch = expectedEpoch + 1
        let checkpointDigest = Self.cleanupJournalCheckpointDigest(
            epoch: checkpointEpoch,
            receiptID: dropped.receiptID,
            transactionUUID: dropped.entry.transactionUUID,
            generation: dropped.entry.generation,
            digest: dropped.entry.digest
        )
        staleTempCleanupJournalCheckpoint = TempCleanupJournalCheckpoint(
            epoch: checkpointEpoch,
            receiptID: dropped.receiptID,
            transactionUUID: dropped.entry.transactionUUID,
            generation: dropped.entry.generation,
            digest: dropped.entry.digest,
            checkpointDigest: checkpointDigest
        )
        staleTempCleanupJournalBaseGeneration = dropped.entry.generation
        staleTempCleanupJournalBaseDigest = dropped.entry.digest
        return true
    }

    private func appendCleanupJournalRecord(
        receipt: MCPStaleTempCleanupReceipt,
        receiptID: String,
        state: TempCleanupJournalState
    ) -> TempCleanupJournalEntry? {
        guard staleTempCleanupJournalGeneration < UInt64.max else { return nil }
        if staleTempCleanupJournalHistory.count >= Self.maxTempCleanupJournalHistory {
            let keepFrom = Self.maxTempCleanupJournalHistory / 2
            let dropped = staleTempCleanupJournalHistory[..<keepFrom]
            guard let lastDropped = dropped.last else { return nil }
            let latestDroppedIDs = Set(dropped.map(\.receiptID)).subtracting(
                staleTempCleanupJournalHistory[keepFrom...].map(\.receiptID)
            )
            guard latestDroppedIDs.allSatisfy({ staleTempCleanupJournal[$0]?.state == .committed }) else {
                return nil
            }
            let expectedCheckpointEpoch = staleTempCleanupJournalCheckpoint?.epoch ?? 0
            guard handoffCleanupJournalCheckpointLocked(
                dropped: lastDropped,
                expectedEpoch: expectedCheckpointEpoch,
                expectedGeneration: staleTempCleanupJournalGeneration,
                expectedDigest: staleTempCleanupJournalDigest
            ) else { return nil }
            staleTempCleanupJournalHistory = Array(staleTempCleanupJournalHistory.dropFirst(keepFrom))
            for id in latestDroppedIDs { staleTempCleanupJournal.removeValue(forKey: id) }
        }
        let generation = staleTempCleanupJournalGeneration + 1
        let previousDigest = staleTempCleanupJournalDigest
        let digest = Self.cleanupJournalRecordDigest(
            receiptID: receiptID,
            generation: generation,
            previousDigest: previousDigest,
            state: state.rawValue,
            scope: receipt.targetPath,
            transactionUUID: receipt.transactionToken,
            preGeneration: generation - 1,
            postGeneration: generation,
            payloadDigest: receipt.payloadDigest.lowercased(),
            configFingerprint: cleanupConfigFingerprintLocked(),
            readbackIdentity: Self.cleanupReadbackIdentity(
                receiptID: receiptID,
                scope: receipt.targetPath,
                transactionUUID: receipt.transactionToken,
                payloadDigest: receipt.payloadDigest.lowercased(),
                directoryDevice: receipt.directoryDevice,
                directoryInode: receipt.directoryInode,
                temporaryDevice: receipt.temporaryDevice,
                temporaryInode: receipt.temporaryInode,
                present: state == .prepared
            )
        )
        let entry = TempCleanupJournalEntry(
            generation: generation,
            previousDigest: previousDigest,
            consumedAt: Date(),
            state: state,
            digest: digest,
            scope: receipt.targetPath,
            transactionUUID: receipt.transactionToken,
            preGeneration: generation - 1,
            postGeneration: generation,
            payloadDigest: receipt.payloadDigest.lowercased(),
            configFingerprint: cleanupConfigFingerprintLocked(),
            readbackIdentity: Self.cleanupReadbackIdentity(
                receiptID: receiptID,
                scope: receipt.targetPath,
                transactionUUID: receipt.transactionToken,
                payloadDigest: receipt.payloadDigest.lowercased(),
                directoryDevice: receipt.directoryDevice,
                directoryInode: receipt.directoryInode,
                temporaryDevice: receipt.temporaryDevice,
                temporaryInode: receipt.temporaryInode,
                present: state == .prepared
            )
        )
        staleTempCleanupJournalHistory.append(
            TempCleanupJournalRecord(entry: entry, receiptID: receiptID)
        )
        staleTempCleanupJournal[receiptID] = entry
        staleTempCleanupJournalGeneration = generation
        staleTempCleanupJournalDigest = digest
        rebuildCleanupJournalManifestLocked()
        return entry
    }

    private static func validateCleanupJournalChain(
        history: [TempCleanupJournalRecord],
        current: [String: TempCleanupJournalEntry],
        baseGeneration: UInt64,
        baseDigest: String,
        checkpoint: TempCleanupJournalCheckpoint?
    ) -> (valid: Bool, generation: UInt64, digest: String, recoveryIDs: Set<String>) {
        guard history.count <= maxTempCleanupJournalHistory else {
            return (false, 0, emptyTempCleanupJournalDigest, [])
        }
        guard baseDigest.count == 64,
              baseDigest.allSatisfy({ "0123456789abcdef".contains($0) }),
              baseGeneration < UInt64.max,
              (baseGeneration == 0 ? baseDigest == emptyTempCleanupJournalDigest : baseDigest != emptyTempCleanupJournalDigest) else {
            return (false, 0, emptyTempCleanupJournalDigest, [])
        }
        if history.isEmpty {
            return (baseGeneration == 0 && checkpoint == nil && current.isEmpty,
                    baseGeneration, baseDigest, [])
        }
        if baseGeneration == 0 {
            guard checkpoint == nil else { return (false, 0, emptyTempCleanupJournalDigest, []) }
        } else {
            guard let checkpoint,
                  checkpoint.epoch > 0,
                  checkpoint.generation % UInt64(maxTempCleanupJournalHistory / 2) == 0,
                  checkpoint.epoch == checkpoint.generation / UInt64(maxTempCleanupJournalHistory / 2),
                  checkpoint.receiptID.count == 64,
                  checkpoint.receiptID.allSatisfy({ "0123456789abcdef".contains($0) }),
                  checkpoint.transactionUUID.count == 36,
                  UUID(uuidString: checkpoint.transactionUUID) != nil,
                  checkpoint.generation == baseGeneration,
                  checkpoint.digest == baseDigest,
                  checkpoint.digest.count == 64,
                  checkpoint.digest.allSatisfy({ "0123456789abcdef".contains($0) }),
                  checkpoint.checkpointDigest == cleanupJournalCheckpointDigest(
                    epoch: checkpoint.epoch,
                    receiptID: checkpoint.receiptID,
                    transactionUUID: checkpoint.transactionUUID,
                    generation: checkpoint.generation,
                    digest: checkpoint.digest
                  ) else {
                return (false, 0, emptyTempCleanupJournalDigest, [])
            }
        }
        var expectedGeneration = baseGeneration + 1
        var previousDigest = baseDigest
        var latest: [String: TempCleanupJournalEntry] = [:]
        var transactions: [String: (receiptID: String, states: [TempCleanupJournalState])] = [:]
        for record in history {
            let entry = record.entry
            guard record.receiptID.count == 64,
                  record.receiptID.allSatisfy({ "0123456789abcdef".contains($0) }),
                  entry.generation == expectedGeneration,
                  entry.previousDigest == previousDigest,
                  entry.previousDigest.count == 64,
                  entry.previousDigest.allSatisfy({ "0123456789abcdef".contains($0) }),
                  entry.digest.count == 64,
                  entry.digest.allSatisfy({ "0123456789abcdef".contains($0) }),
                  entry.payloadDigest.count == 64,
                  entry.payloadDigest.allSatisfy({ "0123456789abcdef".contains($0) }),
                  entry.configFingerprint.count == 64,
                  entry.configFingerprint.allSatisfy({ "0123456789abcdef".contains($0) }),
                  entry.readbackIdentity.count == 64,
                  entry.readbackIdentity.allSatisfy({ "0123456789abcdef".contains($0) }),
                  entry.preGeneration < UInt64.max,
                  entry.preGeneration + 1 == entry.postGeneration,
                  entry.postGeneration == entry.generation,
                  entry.transactionUUID.count == 36,
                  UUID(uuidString: entry.transactionUUID) != nil,
                  !entry.scope.isEmpty,
                  entry.scope.count <= 4_096,
                  entry.digest == cleanupJournalRecordDigest(
                    receiptID: record.receiptID,
                    generation: entry.generation,
                    previousDigest: entry.previousDigest,
                    state: entry.state.rawValue,
                    scope: entry.scope,
                    transactionUUID: entry.transactionUUID,
                    preGeneration: entry.preGeneration,
                    postGeneration: entry.postGeneration,
                    payloadDigest: entry.payloadDigest,
                    configFingerprint: entry.configFingerprint,
                    readbackIdentity: entry.readbackIdentity
                  ),
                  checkpoint.map({
                    record.receiptID != $0.receiptID && entry.transactionUUID != $0.transactionUUID
                  }) ?? true else {
                return (false, 0, emptyTempCleanupJournalDigest, [])
            }
            if let transaction = transactions[entry.transactionUUID] {
                guard transaction.receiptID == record.receiptID,
                      transaction.states.count == 1,
                      transaction.states[0] == .prepared,
                      entry.state == .committed else {
                    return (false, 0, emptyTempCleanupJournalDigest, [])
                }
                transactions[entry.transactionUUID] = (transaction.receiptID, [.prepared, .committed])
            } else {
                transactions[entry.transactionUUID] = (record.receiptID, [entry.state])
            }
            latest[record.receiptID] = entry
            previousDigest = entry.digest
            guard expectedGeneration < UInt64.max else {
                return (false, 0, emptyTempCleanupJournalDigest, [])
            }
            expectedGeneration += 1
        }
        guard latest.count == current.count,
              latest.allSatisfy({ current[$0.key] == $0.value }) else {
            return (false, 0, emptyTempCleanupJournalDigest, [])
        }
        let recoveryIDs = history
            .filter { latest[$0.receiptID] == $0.entry && $0.entry.state == .prepared }
            .sorted { $0.entry.generation > $1.entry.generation }
            .prefix(maxTempCleanupRecoveryCandidates)
            .map(\.receiptID)
        return (true, expectedGeneration - 1, previousDigest, Set(recoveryIDs))
    }

    private static func validateCleanupJournalDocument(_ data: Data) -> Bool {
        var guarder = StrictJSONGuard(
            data: data,
            maxJournalBytes: maxTempCleanupJournalBytes,
            maxJournalEntryBytes: maxTempCleanupJournalEntryBytes,
            maxJournalEntries: maxStaleTempReceipts,
            maxJournalDepth: maxTempCleanupJournalDepth
        )
        return guarder.validate()
    }

    private struct StrictJSONGuard {
        enum Context: Equatable {
            case root
            case journal
            case journalHistory
            case journalRecord
            case journalEntry
            case journalCheckpoint
            case journalManifest
            case journalSegment
            case journalManifestTombstone
            case journalManifestTombstoneHistory
            case journalManifestTombstoneBase
            case journalNested
            case other
        }

        let bytes: [UInt8]
        let maxJournalBytes: Int
        let maxJournalEntryBytes: Int
        let maxJournalEntries: Int
        let maxJournalDepth: Int
        var index = 0

        init(data: Data, maxJournalBytes: Int, maxJournalEntryBytes: Int, maxJournalEntries: Int, maxJournalDepth: Int) {
            self.bytes = Array(data)
            self.maxJournalBytes = maxJournalBytes
            self.maxJournalEntryBytes = maxJournalEntryBytes
            self.maxJournalEntries = maxJournalEntries
            self.maxJournalDepth = maxJournalDepth
        }

        mutating func validate() -> Bool {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x7b else { return false }
            guard parseValue(depth: 0, context: .root) else { return false }
            skipWhitespace()
            return index == bytes.count
        }

        mutating func parseValue(depth: Int, context: Context) -> Bool {
            guard depth <= maxJournalDepth || context == .root || context == .other else { return false }
            skipWhitespace()
            guard index < bytes.count else { return false }
            if context == .journal || context == .journalRecord || context == .journalEntry ||
                context == .journalCheckpoint || context == .journalSegment ||
                context == .journalManifestTombstone || context == .journalManifestTombstoneBase,
               bytes[index] != 0x7b {
                return false
            }
            if context == .journalManifestTombstoneHistory, bytes[index] != 0x5b {
                return false
            }
            if context == .journalHistory, bytes[index] != 0x5b {
                return false
            }
            if context == .journalManifest, bytes[index] != 0x5b {
                return false
            }
            switch bytes[index] {
            case 0x7b:
                return parseObject(depth: depth, context: context)
            case 0x5b:
                return parseArray(depth: depth, context: context)
            case 0x22:
                return parseString() != nil
            default:
                return parseLiteral()
            }
        }

        mutating func parseObject(depth: Int, context: Context) -> Bool {
            let objectStart = index
            index += 1
            var exactKeys = Set<String>()
            var normalizedKeys = Set<String>()
            var previousKey: String?
            var count = 0
            skipWhitespace()
            if consume(0x7d) { return context != .journalEntry }

            while true {
                skipWhitespace()
                guard let key = parseString() else { return false }
                count += 1
                guard context != .journal || count <= maxJournalEntries else {
                    return false
                }
                let normalized = key.precomposedStringWithCanonicalMapping.lowercased()
                let checkNormalized = context == .root || context == .journal ||
                    context == .journalRecord || context == .journalEntry || context == .journalCheckpoint ||
                    context == .journalSegment || context == .journalManifestTombstone ||
                    context == .journalManifestTombstoneBase
                guard exactKeys.insert(key).inserted,
                      !checkNormalized || normalizedKeys.insert(normalized).inserted else {
                    return false
                }
                if context == .root,
                   ((normalized == "staletempcleanupjournal" && key != "staleTempCleanupJournal") ||
                    (normalized == "staletempcleanupjournalhistory" && key != "staleTempCleanupJournalHistory") ||
                    (normalized == "staletempcleanupjournalbasegeneration" && key != "staleTempCleanupJournalBaseGeneration") ||
                    (normalized == "staletempcleanupjournalbasedigest" && key != "staleTempCleanupJournalBaseDigest") ||
                    (normalized == "staletempcleanupjournalcheckpoint" && key != "staleTempCleanupJournalCheckpoint") ||
                    (normalized == "staletempcleanupjournalsegments" && key != "staleTempCleanupJournalSegments") ||
                    (normalized == "staletempcleanupjournalmanifestroot" && key != "staleTempCleanupJournalManifestRoot") ||
                    (normalized == "staletempcleanupjournalmanifestepoch" && key != "staleTempCleanupJournalManifestEpoch") ||
                    (normalized == "staletempcleanupjournalpreviousmanifestroot" && key != "staleTempCleanupJournalPreviousManifestRoot") ||
                    (normalized == "staletempcleanupjournalmanifesttombstone" && key != "staleTempCleanupJournalManifestTombstone") ||
                    (normalized == "staletempcleanupjournalmanifesttombstonehistory" && key != "staleTempCleanupJournalManifestTombstoneHistory") ||
                    (normalized == "staletempcleanupjournalmanifesttombstonebase" && key != "staleTempCleanupJournalManifestTombstoneBase")) {
                    return false
                }
                if context == .journal {
                    guard key.count == 64,
                          key.allSatisfy({ "0123456789abcdef".contains($0) }),
                          previousKey.map({ $0 < key }) ?? true else { return false }
                    previousKey = key
                } else if context == .journalRecord {
                    guard ["entry", "receiptID"].contains(key),
                          previousKey.map({ $0 < key }) ?? true else { return false }
                    previousKey = key
                } else if context == .journalEntry {
                    guard ["configFingerprint", "consumedAt", "digest", "generation", "payloadDigest",
                           "postGeneration", "preGeneration", "previousDigest", "scope", "state",
                           "transactionUUID", "readbackIdentity"].contains(key),
                          previousKey.map({ $0 < key }) ?? true else { return false }
                    previousKey = key
                } else if context == .journalCheckpoint {
                    guard ["checkpointDigest", "digest", "epoch", "generation", "receiptID", "transactionUUID"].contains(key),
                          previousKey.map({ $0 < key }) ?? true else { return false }
                    previousKey = key
                } else if context == .journalSegment {
                    guard ["endDigest", "endGeneration", "identity", "ordinal", "previousDigest", "readbackIdentity",
                           "recordCount", "startDigest", "startGeneration"].contains(key),
                          previousKey.map({ $0 < key }) ?? true else { return false }
                    previousKey = key
                } else if context == .journalManifestTombstone {
                    guard ["checkpointDigest", "checkpointEpoch", "epoch", "root", "successorEpoch",
                           "successorRoot", "tombstoneDigest"].contains(key),
                          previousKey.map({ $0 < key }) ?? true else { return false }
                    previousKey = key
                } else if context == .journalManifestTombstoneBase {
                    guard ["baseDigest", "checkpointDigest", "checkpointEpoch", "compactionEpoch", "epoch",
                           "root", "successorEpoch", "successorRoot"].contains(key),
                          previousKey.map({ $0 < key }) ?? true else { return false }
                    previousKey = key
                }
                skipWhitespace()
                guard consume(0x3a) else { return false }
                let childContext: Context
                if context == .root, key == "staleTempCleanupJournal" {
                    childContext = .journal
                } else if context == .root, key == "staleTempCleanupJournalHistory" {
                    childContext = .journalHistory
                } else if context == .root, key == "staleTempCleanupJournalCheckpoint" {
                    childContext = .journalCheckpoint
                } else if context == .root, key == "staleTempCleanupJournalSegments" {
                    childContext = .journalManifest
                } else if context == .root, key == "staleTempCleanupJournalManifestTombstone" {
                    childContext = .journalManifestTombstone
                } else if context == .root, key == "staleTempCleanupJournalManifestTombstoneHistory" {
                    childContext = .journalManifestTombstoneHistory
                } else if context == .root, key == "staleTempCleanupJournalManifestTombstoneBase" {
                    childContext = .journalManifestTombstoneBase
                } else if context == .journal {
                    childContext = .journalEntry
                } else if context == .journalHistory {
                    childContext = .journalRecord
                } else if context == .journalRecord, key == "entry" {
                    childContext = .journalEntry
                } else if context == .journalEntry {
                    childContext = .journalNested
                } else if context == .journalManifest {
                    childContext = .journalSegment
                } else if context == .journalSegment {
                    childContext = .journalNested
                } else if context == .journalNested {
                    childContext = .journalNested
                } else {
                    childContext = .other
                }
                guard parseValue(depth: depth + 1, context: childContext) else { return false }
                skipWhitespace()
                if consume(0x7d) { break }
                guard consume(0x2c) else { return false }
            }

            if context == .journal {
                return index - objectStart <= maxJournalBytes
            }
            if context == .journalEntry {
                return index - objectStart <= maxJournalEntryBytes && exactKeys == Set([
                    "configFingerprint", "consumedAt", "digest", "generation", "payloadDigest",
                    "postGeneration", "preGeneration", "previousDigest", "scope", "state", "transactionUUID",
                    "readbackIdentity"
                ])
            }
            if context == .journalRecord {
                return exactKeys == Set(["entry", "receiptID"])
            }
            if context == .journalCheckpoint {
                return index - objectStart <= maxJournalEntryBytes && exactKeys == Set([
                    "checkpointDigest", "digest", "epoch", "generation", "receiptID", "transactionUUID"
                ])
            }
            if context == .journalSegment {
                return index - objectStart <= maxJournalEntryBytes && exactKeys == Set([
                    "endDigest", "endGeneration", "identity", "ordinal", "previousDigest", "readbackIdentity",
                    "recordCount", "startDigest", "startGeneration"
                ])
            }
            if context == .journalManifestTombstone {
                return index - objectStart <= maxJournalEntryBytes && exactKeys == Set([
                    "checkpointDigest", "checkpointEpoch", "epoch", "root", "successorEpoch",
                    "successorRoot", "tombstoneDigest"
                ])
            }
            if context == .journalManifestTombstoneBase {
                return index - objectStart <= maxJournalEntryBytes && exactKeys == Set([
                    "baseDigest", "checkpointDigest", "checkpointEpoch", "compactionEpoch", "epoch",
                    "root", "successorEpoch", "successorRoot"
                ])
            }
            return true
        }

        mutating func parseArray(depth: Int, context: Context) -> Bool {
            let arrayStart = index
            index += 1
            skipWhitespace()
            if consume(0x5d) { return true }
            var count = 0
            while true {
                count += 1
                if context == .journalHistory, count > maxJournalEntries * 2 { return false }
                if context == .journalManifest, count > maxTempCleanupJournalSegments { return false }
                if context == .journalManifestTombstoneHistory,
                   count > maxTempCleanupJournalManifestTombstones { return false }
                let childContext: Context
                if context == .journalHistory {
                    childContext = .journalRecord
                } else if context == .journalManifest {
                    childContext = .journalSegment
                } else if context == .journalManifestTombstoneHistory {
                    childContext = .journalManifestTombstone
                } else {
                    childContext = context == .journalNested ? .journalNested : .other
                }
                guard parseValue(depth: depth + 1, context: childContext) else { return false }
                skipWhitespace()
                if consume(0x5d) {
                    if context == .journalHistory || context == .journalManifestTombstoneHistory {
                        return index - arrayStart <= maxJournalBytes
                    }
                    return true
                }
                guard consume(0x2c) else { return false }
            }
        }

        mutating func parseString() -> String? {
            guard consume(0x22) else { return nil }
            let start = index - 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte < 0x20, !escaped { return nil }
                if byte == 0x22, !escaped {
                    let raw = Data(bytes[start..<index])
                    return (try? JSONSerialization.jsonObject(
                        with: raw,
                        options: [.fragmentsAllowed]
                    )) as? String
                }
                if byte == 0x5c, !escaped {
                    escaped = true
                } else {
                    escaped = false
                }
            }
            return nil
        }

        mutating func parseLiteral() -> Bool {
            let start = index
            while index < bytes.count, ![0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d].contains(bytes[index]) {
                index += 1
            }
            guard index > start else { return false }
            let raw = Data(bytes[start..<index])
            return (try? JSONSerialization.jsonObject(
                with: raw,
                options: [.fragmentsAllowed]
            )) != nil
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func consume(_ expected: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == expected else { return false }
            index += 1
            return true
        }
    }

    /// Read from the same pinned physical parent used by this pair lease.
    private func readDocumentLocked(
        _ document: MCPPersistentWriteFence.Document
    ) -> MCPBoundedDocumentReadResult {
        if let lease = persistenceLease {
            do {
                guard let data = try lease.read(document, maxBytes: Self.maxPersistedMCPDocumentBytes) else {
                    return .unavailable
                }
                return .data(data)
            } catch {
                persistenceConflict = .needsReopen
                persistenceFailureDescription = String(describing: error)
                if case MCPPersistenceConflict.documentTooLarge = error { return .tooLarge }
                return .unavailable
            }
        }
        // Only failed-constructor read diagnostics may use path-based reads.
        // They cannot migrate or persist and never update the captured baseline.
        let url = document == .config ? fileURL : authorizationFileURL
        return MCPBoundedDocumentReader.read(from: url, maxBytes: Self.maxPersistedMCPDocumentBytes)
    }

    /// 从磁盘加载服务器列表；返回是否发生过旧格式明文 secret 迁移
    /// （true 时调用方应重写文件以剥离明文）。
    @discardableResult
    private func loadFromDisk(allowSecretMigration: Bool = true) throws -> Bool {
        let data: Data
        switch readDocumentLocked(.config) {
        case .unavailable:
            // A genuinely new profile has no document yet. An existing but
            // unreadable or wrong-type document cannot erase replay history.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                bl6NameLedgerValid = false
            }
            return false
        case .tooLarge:
            bl6NameLedgerValid = false
            setCleanupJournalLoadValidityDiagnosticStage(.documentStrictJSON)
            lock.lock()
            staleTempCleanupJournalValid = false
            issuedTempReceipts.removeAll()
            lock.unlock()
            return false
        case .data(let boundedData):
            data = boundedData
        }
        guard Self.validateCleanupJournalDocument(data) else {
            bl6NameLedgerValid = false
            setCleanupJournalLoadValidityDiagnosticStage(.documentStrictJSON)
            lock.lock()
            staleTempCleanupJournalValid = false
            issuedTempReceipts.removeAll()
            lock.unlock()
            return false
        }
        // Tolerant decode: one malformed entry must not blank the whole list.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawServers = root["servers"] as? [Any] else {
            bl6NameLedgerValid = false
            setCleanupJournalLoadValidityDiagnosticStage(.rootDecode)
            lock.lock()
            staleTempCleanupJournalValid = false
            issuedTempReceipts.removeAll()
            lock.unlock()
            return false
        }
        var firstInvalidLoadStage: CleanupJournalLoadValidityStage?
        func noteInvalidLoadStage(
            _ valid: Bool,
            _ stage: CleanupJournalLoadValidityStage
        ) {
            if !valid, firstInvalidLoadStage == nil {
                firstInvalidLoadStage = stage
            }
        }
        let decoder = JSONDecoder()
        var loaded: [MCPServer] = []
        var migrated = false
        for raw in rawServers {
            guard let entryData = try? JSONSerialization.data(withJSONObject: raw),
                  let entry = try? decoder.decode(MCPServer.self, from: entryData) else { continue }
            // S1: 先兼容旧格式 env/header marker，再还原带 owner/revision 的 refs。
            let (resolved, didMigrate) = allowSecretMigration
                ? try Self.resolveSecrets(entry, keychain: keychain) : (entry, false)
            let restored = MCPServerSecretPolicy.restoringServer(resolved, keychain: keychain)
            migrated = migrated || didMigrate
            loaded.append(restored.server)
        }
        var loadedTrash: [MCPServer] = []
        if let rawTrash = root["trashServers"] as? [Any] {
            for raw in rawTrash {
                guard let entryData = try? JSONSerialization.data(withJSONObject: raw),
                      let entry = try? decoder.decode(MCPServer.self, from: entryData) else { continue }
                let (resolved, didMigrate) = allowSecretMigration
                    ? try Self.resolveSecrets(entry, keychain: keychain) : (entry, false)
                let restored = MCPServerSecretPolicy.restoringServer(resolved, keychain: keychain)
                migrated = migrated || didMigrate
                loadedTrash.append(restored.server)
            }
        }
        let loadedRevision = (root["revision"] as? Int) ?? 0
        let loadedBL6Names: ([String: BL6NameCompletion], Bool) = {
            guard let raw = root["bl6NameCompletions"] else { return ([:], true) }
            guard let entries = raw as? [String: Any], entries.count <= 1_024 else {
                return ([:], false)
            }
            var decoded: [String: BL6NameCompletion] = [:]
            for (requestID, value) in entries {
                guard let entryData = try? JSONSerialization.data(withJSONObject: value),
                      let entry = try? decoder.decode(BL6NameCompletion.self, from: entryData),
                      entry.record.requestID == requestID,
                      entry.record.receipt.requestID == requestID,
                      entry.record.operation == entry.record.frozenInput.operation,
                      entry.record.operation == .apply || entry.record.operation == .rollback,
                      entry.record.receipt.rollbackValues.isEmpty,
                      entry.record.rollbackValues.keys.allSatisfy({ $0 == Self.bl6NameKey(for: entry.serverID) }),
                      entry.record.frozenInput.changes.keys.allSatisfy({ $0 == Self.bl6NameKey(for: entry.serverID) }),
                      !entry.record.profileID.isEmpty,
                      !entry.descriptorFingerprint.isEmpty else {
                    return ([:], false)
                }
                decoded[requestID] = entry
            }
            let receipts = decoded.values.map { $0.record.receipt.receiptID }
            let revisions = decoded.values.map { $0.record.receipt.effectiveRevision }
            guard Set(receipts).count == receipts.count,
                  Set(revisions).count == revisions.count else { return ([:], false) }
            return (decoded, true)
        }()
        let loadedBL6Enablement: ([String: BL6EnablementCompletion], Bool) = {
            guard let raw = root["bl6EnablementCompletions"] else { return ([:], true) }
            guard let entries = raw as? [String: Any], entries.count <= 1_024 else {
                return ([:], false)
            }
            var decoded: [String: BL6EnablementCompletion] = [:]
            for (requestID, value) in entries {
                guard let entryData = try? JSONSerialization.data(withJSONObject: value),
                      let entry = try? decoder.decode(BL6EnablementCompletion.self, from: entryData),
                      entry.record.requestID == requestID,
                      entry.record.receipt.requestID == requestID,
                      entry.record.operation == entry.record.frozenInput.operation,
                      entry.record.operation == .apply || entry.record.operation == .rollback,
                      entry.record.receipt.rollbackValues.isEmpty,
                      entry.record.rollbackValues == [
                          Self.bl6EnabledKey(for: entry.serverID): .toggle(entry.previousEnabled)
                      ],
                      entry.record.frozenInput.changes.keys.allSatisfy({ $0 == Self.bl6EnabledKey(for: entry.serverID) }),
                      !entry.record.profileID.isEmpty,
                      !entry.descriptorFingerprint.isEmpty else { return ([:], false) }
                decoded[requestID] = entry
            }
            let receipts = decoded.values.map { $0.record.receipt.receiptID }
            let revisions = decoded.values.map { $0.record.receipt.effectiveRevision }
            guard Set(receipts).count == receipts.count,
                  Set(revisions).count == revisions.count else { return ([:], false) }
            return (decoded, true)
        }()
        let bl6LedgersDistinct = Set(loadedBL6Names.0.keys).isDisjoint(with: loadedBL6Enablement.0.keys)
            && Set(loadedBL6Names.0.values.map { $0.record.receipt.receiptID })
                .isDisjoint(with: loadedBL6Enablement.0.values.map { $0.record.receipt.receiptID })
            && Set(loadedBL6Names.0.values.map { $0.record.receipt.effectiveRevision })
                .isDisjoint(with: loadedBL6Enablement.0.values.map { $0.record.receipt.effectiveRevision })
        let loadedCleanupJournal: ([String: TempCleanupJournalEntry], Bool) = {
            guard let rawValue = root["staleTempCleanupJournal"] else { return ([:], true) }
            guard let rawJournal = rawValue as? [String: Any] else { return ([:], false) }
            var decoded: [String: TempCleanupJournalEntry] = [:]
            var valid = true
            for entry in rawJournal {
                let (receiptID, raw) = entry
                guard let entryData = try? JSONSerialization.data(withJSONObject: raw),
                      entryData.count <= Self.maxTempCleanupJournalEntryBytes,
                      let journalEntry = try? decoder.decode(TempCleanupJournalEntry.self, from: entryData) else {
                    valid = false
                    continue
                }
                decoded[receiptID] = journalEntry
            }
            return (decoded, valid)
        }()
        noteInvalidLoadStage(loadedCleanupJournal.1, .journalCurrentDecode)
        let loadedCleanupJournalHistory: ([TempCleanupJournalRecord], Bool) = {
            guard let rawValue = root["staleTempCleanupJournalHistory"] else { return ([], true) }
            guard let rawHistory = rawValue as? [Any],
                  rawHistory.count <= Self.maxTempCleanupJournalHistory else { return ([], false) }
            var decoded: [TempCleanupJournalRecord] = []
            for raw in rawHistory {
                guard let entryData = try? JSONSerialization.data(withJSONObject: raw),
                      let record = try? decoder.decode(TempCleanupJournalRecord.self, from: entryData) else {
                    return ([], false)
                }
                decoded.append(record)
            }
            return (decoded, true)
        }()
        noteInvalidLoadStage(loadedCleanupJournalHistory.1, .historyDecode)
        let loadedCleanupJournalBaseGeneration = (root["staleTempCleanupJournalBaseGeneration"] as? NSNumber)?.uint64Value ?? 0
        let loadedCleanupJournalBaseDigest = (root["staleTempCleanupJournalBaseDigest"] as? String) ?? Self.emptyTempCleanupJournalDigest
        let loadedCleanupJournalCheckpoint: (TempCleanupJournalCheckpoint?, Bool) = {
            guard let rawValue = root["staleTempCleanupJournalCheckpoint"] else { return (nil, true) }
            guard let checkpointData = try? JSONSerialization.data(withJSONObject: rawValue),
                  checkpointData.count <= Self.maxTempCleanupJournalEntryBytes,
                  let checkpoint = try? decoder.decode(TempCleanupJournalCheckpoint.self, from: checkpointData) else {
                return (nil, false)
            }
            return (checkpoint, true)
        }()
        noteInvalidLoadStage(loadedCleanupJournalCheckpoint.1, .checkpointDecode)
        let loadedCleanupJournalManifest: ([TempCleanupJournalSegment]?, String?, UInt64?, String?, Bool) = {
            let rawSegments = root["staleTempCleanupJournalSegments"]
            let rawRoot = root["staleTempCleanupJournalManifestRoot"]
            let rawEpoch = root["staleTempCleanupJournalManifestEpoch"]
            let rawPreviousRoot = root["staleTempCleanupJournalPreviousManifestRoot"]
            guard rawSegments != nil || rawRoot != nil || rawEpoch != nil || rawPreviousRoot != nil else {
                return (nil, nil, nil, nil, true)
            }
            guard let rawSegments,
                  let segmentData = try? JSONSerialization.data(withJSONObject: rawSegments),
                  segmentData.count <= Self.maxTempCleanupJournalBytes,
                  let segments = try? decoder.decode([TempCleanupJournalSegment].self, from: segmentData),
                  let root = rawRoot as? String,
                  let epoch = (rawEpoch as? NSNumber)?.uint64Value,
                  let previousRoot = rawPreviousRoot as? String else {
                return (nil, nil, nil, nil, false)
            }
            return (segments, root, epoch, previousRoot, true)
        }()
        noteInvalidLoadStage(loadedCleanupJournalManifest.4, .manifestDecode)
        let loadedCleanupJournalManifestTombstone: (TempCleanupJournalManifestTombstone?, Bool) = {
            guard let rawValue = root["staleTempCleanupJournalManifestTombstone"] else {
                return (nil, true)
            }
            guard let tombstoneData = try? JSONSerialization.data(withJSONObject: rawValue),
                  tombstoneData.count <= Self.maxTempCleanupJournalEntryBytes,
                  let tombstone = try? decoder.decode(
                    TempCleanupJournalManifestTombstone.self,
                    from: tombstoneData
                  ) else {
                return (nil, false)
            }
            return (tombstone, true)
        }()
        noteInvalidLoadStage(loadedCleanupJournalManifestTombstone.1, .tombstoneDecode)
        let loadedCleanupJournalManifestTombstoneHistory: ([TempCleanupJournalManifestTombstone]?, Bool) = {
            guard let rawValue = root["staleTempCleanupJournalManifestTombstoneHistory"] else {
                return (nil, true)
            }
            guard let rawHistory = rawValue as? [Any],
                  let historyData = try? JSONSerialization.data(withJSONObject: rawHistory),
                  historyData.count <= Self.maxTempCleanupJournalBytes,
                  rawHistory.count <= Self.maxTempCleanupJournalManifestTombstones else {
                return (nil, false)
            }
            var decoded: [TempCleanupJournalManifestTombstone] = []
            for raw in rawHistory {
                guard let tombstoneData = try? JSONSerialization.data(withJSONObject: raw),
                      tombstoneData.count <= Self.maxTempCleanupJournalEntryBytes,
                      let tombstone = try? decoder.decode(
                        TempCleanupJournalManifestTombstone.self,
                        from: tombstoneData
                      ) else {
                    return (nil, false)
                }
                decoded.append(tombstone)
            }
            return (decoded, true)
        }()
        noteInvalidLoadStage(loadedCleanupJournalManifestTombstoneHistory.1, .tombstoneDecode)
        let loadedCleanupJournalManifestTombstoneBase: (TempCleanupJournalManifestTombstoneBase?, Bool) = {
            guard let rawValue = root["staleTempCleanupJournalManifestTombstoneBase"] else {
                return (nil, true)
            }
            guard let baseData = try? JSONSerialization.data(withJSONObject: rawValue),
                  baseData.count <= Self.maxTempCleanupJournalEntryBytes,
                  let base = try? decoder.decode(
                    TempCleanupJournalManifestTombstoneBase.self,
                    from: baseData
                  ) else {
                return (nil, false)
            }
            return (base, true)
        }()
        noteInvalidLoadStage(loadedCleanupJournalManifestTombstoneBase.1, .tombstoneDecode)
        let validatedCleanupJournal = Self.validateCleanupJournalChain(
            history: loadedCleanupJournalHistory.0,
            current: loadedCleanupJournal.0,
            baseGeneration: loadedCleanupJournalBaseGeneration,
            baseDigest: loadedCleanupJournalBaseDigest,
            checkpoint: loadedCleanupJournalCheckpoint.0
        )
        noteInvalidLoadStage(validatedCleanupJournal.valid, .chainValidation)
        let manifestValid = Self.validateCleanupJournalManifest(
            history: loadedCleanupJournalHistory.0,
            baseGeneration: loadedCleanupJournalBaseGeneration,
            baseDigest: loadedCleanupJournalBaseDigest,
            checkpoint: loadedCleanupJournalCheckpoint.0,
            generation: validatedCleanupJournal.generation,
            manifestEpoch: loadedCleanupJournalManifest.2,
            previousRoot: loadedCleanupJournalManifest.3,
            segments: loadedCleanupJournalManifest.0,
            root: loadedCleanupJournalManifest.1,
            tombstone: loadedCleanupJournalManifestTombstone.0,
            tombstoneHistory: loadedCleanupJournalManifestTombstoneHistory.0,
            tombstoneBase: loadedCleanupJournalManifestTombstoneBase.0
        )
        noteInvalidLoadStage(manifestValid, .manifestValidation)
        var derivedManifest = Self.cleanupJournalManifest(
            history: [],
            baseGeneration: loadedCleanupJournalBaseGeneration,
            baseDigest: loadedCleanupJournalBaseDigest,
            checkpoint: loadedCleanupJournalCheckpoint.0,
            epoch: 0,
            previousRoot: Self.emptyTempCleanupJournalDigest
        )
        var derivedManifestTombstones: [TempCleanupJournalManifestTombstone] = []
        var derivedPreviousManifestRoot = Self.emptyTempCleanupJournalDigest
        for index in loadedCleanupJournalHistory.0.indices {
            let prefix = Array(loadedCleanupJournalHistory.0[...index])
            let epoch = prefix[index].entry.generation
            guard epoch > 0 else {
                derivedManifestTombstones.removeAll()
                break
            }
            derivedManifest = Self.cleanupJournalManifest(
                history: prefix,
                baseGeneration: loadedCleanupJournalBaseGeneration,
                baseDigest: loadedCleanupJournalBaseDigest,
                checkpoint: loadedCleanupJournalCheckpoint.0,
                epoch: epoch,
                previousRoot: derivedPreviousManifestRoot
            )
            derivedManifestTombstones.append(Self.cleanupJournalManifestTombstone(
                epoch: epoch - 1,
                root: derivedPreviousManifestRoot,
                successorEpoch: epoch,
                successorRoot: derivedManifest.root,
                checkpoint: loadedCleanupJournalCheckpoint.0
            ))
            derivedPreviousManifestRoot = derivedManifest.root
        }
        let derivedManifestTombstoneHistory = Array(
            derivedManifestTombstones.suffix(Self.maxTempCleanupJournalManifestTombstones)
        )
        let derivedManifestTombstone = derivedManifestTombstoneHistory.last
        let derivedManifestTombstoneBase: TempCleanupJournalManifestTombstoneBase? = {
            guard let first = derivedManifestTombstoneHistory.first else { return nil }
            return Self.cleanupJournalManifestTombstoneBase(
                first: first,
                checkpoint: loadedCleanupJournalCheckpoint.0,
                compactionEpoch: first.epoch,
                successorEpoch: derivedManifestTombstone?.successorEpoch ?? 0,
                successorRoot: derivedManifest.root
            )
        }()
        let loadedSnapshots: [String: MCPDiscoverySnapshot] = {
            guard let rawSnapshots = root["discoverySnapshots"] as? [String: Any] else { return [:] }
            return rawSnapshots.reduce(into: [String: MCPDiscoverySnapshot]()) { result, entry in
                let (serverID, raw) = entry
                guard let snapshotData = try? JSONSerialization.data(withJSONObject: raw),
                      let snapshot = try? decoder.decode(MCPDiscoverySnapshot.self, from: snapshotData),
                      let server = loaded.first(where: { $0.id == serverID }),
                      snapshot.serverID == serverID,
                      snapshot.revision == loadedRevision,
                      snapshot.descriptorFingerprint == server.descriptorFingerprint,
                      snapshot.id == "\(serverID):r\(snapshot.revision):\(snapshot.descriptorFingerprint)",
                      snapshot.transportGeneration > 0,
                      snapshot.schemaDigest == MCPDiscoverySnapshot.schemaDigest(for: snapshot.tools) else {
                    return
                }
                result[serverID] = snapshot
            }
        }()
        lock.lock()
        let retiredOAuthServers = servers.filter { old in
            !loaded.contains { $0.id == old.id && $0.descriptorFingerprint == old.descriptorFingerprint && $0.headers == old.headers }
        }
        servers = loaded
        bl6NameCompletions = loadedBL6Names.0
        bl6EnablementCompletions = loadedBL6Enablement.0
        bl6NameLedgerValid = loadedBL6Names.1 && loadedBL6Enablement.1 && bl6LedgersDistinct
        trashServers = loadedTrash
        // Durable records are decoded and structurally checked, but their
        // transport owner is not alive after reload. Keep them fenced until a
        // fresh discovery establishes the current generation.
        discoverySnapshots = loadedSnapshots
        transportGenerations = [:]
        staleTempCleanupJournal = loadedCleanupJournal.0
        staleTempCleanupJournalHistory = loadedCleanupJournalHistory.0
        staleTempCleanupJournalBaseGeneration = loadedCleanupJournalBaseGeneration
        staleTempCleanupJournalBaseDigest = loadedCleanupJournalBaseDigest
        staleTempCleanupJournalCheckpoint = loadedCleanupJournalCheckpoint.0
        staleTempCleanupJournalSegments = loadedCleanupJournalManifest.0 ?? derivedManifest.segments
        staleTempCleanupJournalManifestRoot = loadedCleanupJournalManifest.1 ?? derivedManifest.root
        staleTempCleanupJournalManifestEpoch = loadedCleanupJournalManifest.2 ?? validatedCleanupJournal.generation
        staleTempCleanupJournalPreviousManifestRoot = loadedCleanupJournalManifest.3 ?? Self.emptyTempCleanupJournalDigest
        staleTempCleanupJournalManifestTombstone = loadedCleanupJournalManifestTombstone.0 ?? derivedManifestTombstone
        staleTempCleanupJournalManifestTombstoneHistory = loadedCleanupJournalManifestTombstoneHistory.0 ?? derivedManifestTombstoneHistory
        staleTempCleanupJournalManifestTombstoneBase = loadedCleanupJournalManifestTombstoneBase.0 ?? derivedManifestTombstoneBase
        staleTempCleanupJournalGeneration = validatedCleanupJournal.generation
        staleTempCleanupJournalDigest = validatedCleanupJournal.digest
        recoveryCandidateReceiptIDs = validatedCleanupJournal.recoveryIDs
        let cleanupJournalValid = loadedCleanupJournal.1 &&
            loadedCleanupJournalHistory.1 && loadedCleanupJournalCheckpoint.1 &&
            loadedCleanupJournalManifest.4 && loadedCleanupJournalManifestTombstone.1 &&
            loadedCleanupJournalManifestTombstoneHistory.1 && loadedCleanupJournalManifestTombstoneBase.1 &&
            manifestValid && validatedCleanupJournal.valid
        staleTempCleanupJournalValid = cleanupJournalValid
        setCleanupJournalLoadValidityDiagnosticStage(
            cleanupJournalValid ? .ready : (firstInvalidLoadStage ?? .chainValidation)
        )
        if staleTempCleanupJournalValid {
            staleTempReceipts = staleTempReceipts.filter {
                guard let entry = staleTempCleanupJournal[Self.receiptID($0)] else { return true }
                guard entry.state != .committed else { return false }
                return recoveryCandidateReceiptIDs.contains(Self.receiptID($0))
            }
            issuedTempReceipts = Set(staleTempReceipts)
        } else {
            issuedTempReceipts.removeAll()
        }
        revision = loadedRevision
        lock.unlock()
        for retired in retiredOAuthServers { try oauth.retireCredential(server: retired) }
        return migrated
    }

    /// 把磁盘读出的服务器还原为运行期形态：
    /// - secret 键的占位符（redactedMarker）从 Keychain 还原真实值；Keychain
    ///   缺失时保留占位符（明确降级，不猜测）。
    /// - secret 键的旧格式明文值迁入 Keychain（返回 migrated=true，触发文件
    ///   重写剥离明文）；运行期内存值保持不变。
    /// - 非 secret 键值原样通过。
    private static func resolveSecrets(_ server: MCPServer, keychain: KeychainStore) throws -> (MCPServer, Bool) {
        var resolved = server
        var migrated = false

        func resolve(_ entries: [String: String], scope: MCPServerSecretScope) throws -> ([String: String], Bool) {
            var out: [String: String] = [:]
            var didMigrate = false
            for (key, value) in entries {
                // S1 v2 refs are owner/revision fenced and must never be
                // interpreted as legacy plaintext or copied into a v1 key.
                if value.hasPrefix("<keychain-ref:") && value.hasSuffix(">") {
                    out[key] = value
                    continue
                }
                guard MCPServerSecretPolicy.isSecretKey(key) else {
                    out[key] = value
                    continue
                }
                let ref = MCPServerSecretPolicy.keychainKey(serverID: server.id, scope: scope, key: key)
                if value == MCPServerSecretPolicy.redactedMarker {
                    out[key] = keychain.get(ref) ?? value
                } else if value.isEmpty {
                    out[key] = value
                } else {
                    // S1 之前的旧格式：明文 secret → 迁入 Keychain，磁盘重写后剥离。
                    guard keychain.set(value, forKey: ref) else {
                        throw MCPServerSecretStoreError.keychainWriteFailed(ref)
                    }
                    didMigrate = true
                    out[key] = value
                }
            }
            return (out, didMigrate)
        }

        let (env, envMigrated) = try resolve(resolved.env, scope: .env)
        resolved.env = env
        migrated = migrated || envMigrated
        let (headers, headersMigrated) = try resolve(resolved.headers, scope: .header)
        resolved.headers = headers
        migrated = migrated || headersMigrated
        return (resolved, migrated)
    }

    private func saveLocked(persistAuthorizations: Bool = true) throws {
        try persistWithinLeaseLocked {
            guard bl6NameLedgerValid else { throw InvalidBL6NameLedger() }
            // S1: 真实 secret 值先写入 Keychain（安全引用），磁盘只落占位符。
            // Keychain 写入失败即抛错（fail-closed）—— 绝不把 secret 明文写进
            // mcps.json 作为降级路径。
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let persistedServers = try servers.map {
                try MCPServerSecretPolicy.persistingServer($0, keychain: keychain, revision: revision)
            }
            let persistedTrashServers = try trashServers.map {
                try MCPServerSecretPolicy.persistingServer($0, keychain: keychain, revision: revision)
            }
            let shape = FileShape(
                servers: persistedServers,
                trashServers: persistedTrashServers,
                revision: revision,
                discoverySnapshots: discoverySnapshots,
                bl6NameCompletions: bl6NameCompletions,
                bl6EnablementCompletions: bl6EnablementCompletions,
                staleTempCleanupJournal: staleTempCleanupJournal,
                staleTempCleanupJournalHistory: staleTempCleanupJournalHistory,
                staleTempCleanupJournalBaseGeneration: staleTempCleanupJournalBaseGeneration,
                staleTempCleanupJournalBaseDigest: staleTempCleanupJournalBaseDigest,
                staleTempCleanupJournalCheckpoint: staleTempCleanupJournalCheckpoint,
                staleTempCleanupJournalSegments: staleTempCleanupJournalSegments,
                staleTempCleanupJournalManifestRoot: staleTempCleanupJournalManifestRoot,
                staleTempCleanupJournalManifestEpoch: staleTempCleanupJournalManifestEpoch,
                staleTempCleanupJournalPreviousManifestRoot: staleTempCleanupJournalPreviousManifestRoot,
                staleTempCleanupJournalManifestTombstone: staleTempCleanupJournalManifestTombstone,
                staleTempCleanupJournalManifestTombstoneHistory: staleTempCleanupJournalManifestTombstoneHistory,
                staleTempCleanupJournalManifestTombstoneBase: staleTempCleanupJournalManifestTombstoneBase
            )
            let data = try encoder.encode(shape)
            guard data.count <= Self.maxPersistedMCPDocumentBytes else {
                throw MCPDocumentSizeLimitError()
            }
            if persistAuthorizations {
                // Reject an oversized companion document before replacing mcps.json.
                _ = try authorizationDocumentData()
            }
            try writeDurablyLocked(data, document: .config)
            if persistAuthorizations { try saveAuthorizationsLocked() }
        }
    }

    private func authorizationDocumentData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let shape = AuthorizationFileShape(
            authorizations: authorizations.values.sorted { ($0.serverID ?? "") < ($1.serverID ?? "") },
            revision: revision
        )
        let data = try encoder.encode(shape)
        guard data.count <= Self.maxPersistedMCPDocumentBytes else {
            throw MCPDocumentSizeLimitError()
        }
        return data
    }

    private func saveAuthorizationsLocked() throws {
        // Encoding/size rejection is known to precede authorization writes.
        // Let the caller roll back RAM without poisoning an unchanged baseline.
        let data = try authorizationDocumentData()
        try persistWithinLeaseLocked {
            guard bl6NameLedgerValid else { throw InvalidBL6NameLedger() }
            try writeDurablyLocked(data, document: .authorization)
            pendingSchemaRevocations.removeAll()
        }
    }

    private func loadAuthorizationsFromDisk() {
        guard case .data(let data) = readDocumentLocked(.authorization), let shape = try? JSONDecoder().decode(AuthorizationFileShape.self, from: data) else {
            if FileManager.default.fileExists(atPath: authorizationFileURL.path) {
                persistenceConflict = .needsReopen
                persistenceFailureDescription = "Invalid MCP authorization document"
            }
            return
        }
        lock.lock()
        authorizations = Dictionary(
            uniqueKeysWithValues: shape.authorizations.compactMap { grant in
                guard let id = grant.serverID,
                      let server = servers.first(where: { $0.id == id }),
                      server.enabled,
                      grant.descriptorFingerprint == server.descriptorFingerprint else {
                    return nil
                }
                return (id, grant)
            }
        )
        if let authorizationRevision = shape.revision {
            revision = max(revision, authorizationRevision)
        }
        lock.unlock()
    }

    private func discardReloadedDiscoverySnapshots() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !discoverySnapshots.isEmpty else { return false }
        discoverySnapshots.removeAll()
        transportGenerations.removeAll()
        return true
    }

    /// Explicit save (e.g. after external edits). Errors surface to the caller.
    public func save() throws {
        lock.lock()
        defer { lock.unlock() }
        try beginPersistentMutationLocked()
        defer { endPersistentMutationLocked() }
        try saveLocked()
    }

    private init(snapshot: Snapshot, keychain: KeychainStore, schemaLineage: SchemaLineage, oauth: MCPOAuthCoordinator) {
        self.fileURL = snapshot.fileURL
        self.authorizationFileURL = snapshot.authorizationFileURL
        self.keychain = keychain
        self.oauth = oauth
        self.schemaLineage = schemaLineage
        self.servers = snapshot.servers
        self.trashServers = snapshot.trashServers
        self.authorizations = snapshot.authorizations
        self.discoverySnapshots = snapshot.discoverySnapshots
        self.transportGenerations = snapshot.transportGenerations
        self.schemaEpochs = snapshot.schemaEpochs
        self.revision = snapshot.revision
        self.persistenceBaseline = snapshot.persistenceBaseline
        self.persistenceConflict = snapshot.persistenceConflict
        if !restorePersistentSnapshotPayload(snapshot.persistentOrigin)
            || snapshot.persistenceBaseline == nil {
            self.persistenceConflict = .incompleteSnapshot
        }
    }

    /// Standard `mcpServers`-object JSON export (Claude-Desktop compatible:
    /// `{"mcpServers": {"<id>": {...}}}`) — for sharing / import preview.
    /// S1: 导出的是 redaction 副本 —— secret env/header 值以占位符呈现，绝不
    /// 携带明文 secret。
    public func exportMCPJSON(server: MCPServer) -> String? {
        let redacted = server.redactingSecrets()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        let shape = ["mcpServers": [server.id: redacted]]
        guard let data = try? encoder.encode(shape) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func fingerprint(for server: MCPServer) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(server)) ?? Data(server.id.utf8)
        return DeletionGate.fingerprint(String(decoding: data, as: UTF8.self))
    }
}
