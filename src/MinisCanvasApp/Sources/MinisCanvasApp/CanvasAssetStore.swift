import Foundation
import CanvasCore

/// 画布媒体资产索引。资产按 canvasID 隔离，节点删除不会自动抹掉资产事实源。
/// 持久化和旧 result.* 迁移由上层协调；本类型不读取聊天或 UI 状态。
struct CanvasAssetStoreSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let assetsByCanvas: [UUID: [MediaAsset]]

    init(schemaVersion: Int = 1, assetsByCanvas: [UUID: [MediaAsset]]) {
        self.schemaVersion = schemaVersion
        self.assetsByCanvas = assetsByCanvas
    }
}

private final class CanvasAssetLifecycleGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var detachedCanvasIDs: Set<UUID> = []

    func detach(canvasID: UUID) {
        lock.lock()
        detachedCanvasIDs.insert(canvasID)
        lock.unlock()
    }

    func contains(canvasID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return detachedCanvasIDs.contains(canvasID)
    }
}

actor CanvasAssetStore {
    static let currentSchemaVersion = 1
    static let snapshotFileName = "canvas_assets.json"
    private var assetsByCanvas: [UUID: [UUID: MediaAsset]] = [:]
    private let lifecycleGuard = CanvasAssetLifecycleGuard()

    init(snapshot: CanvasAssetStoreSnapshot? = nil) {
        guard let snapshot, snapshot.schemaVersion == Self.currentSchemaVersion else { return }
        assetsByCanvas = Self.normalize(snapshot.assetsByCanvas)
    }

    func snapshot() -> CanvasAssetStoreSnapshot {
        CanvasAssetStoreSnapshot(
            schemaVersion: Self.currentSchemaVersion,
            assetsByCanvas: Dictionary(uniqueKeysWithValues: assetsByCanvas.map { ($0.key, Array($0.value.values)) })
        )
    }

    func encodedSnapshot() throws -> Data {
        try JSONEncoder().encode(snapshot())
    }

    /// Persist the asset fact source independently from graph drafts.
    func persist(to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encodedSnapshot().write(
                to: directory.appendingPathComponent(Self.snapshotFileName),
                options: .atomic
            )
        } catch {
            // Keep the in-memory index usable; a later registration retries persistence.
        }
    }

    func replace(with snapshot: CanvasAssetStoreSnapshot) {
        guard snapshot.schemaVersion == Self.currentSchemaVersion else { return }
        assetsByCanvas = Self.normalize(snapshot.assetsByCanvas)
    }

    /// Synchronously invalidate a deleted canvas so a detached task cannot race
    /// the actor hop and register a late result under the removed identity.
    nonisolated func detach(canvasID: UUID) {
        lifecycleGuard.detach(canvasID: canvasID)
    }

    static func loadSnapshot(from directory: URL) -> CanvasAssetStoreSnapshot? {
        let url = directory.appendingPathComponent(snapshotFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CanvasAssetStoreSnapshot.self, from: data)
    }

    @discardableResult
    func register(_ asset: MediaAsset, canvasID: UUID) -> Bool {
        guard asset.sourceCanvasID == nil || asset.sourceCanvasID == canvasID else { return false }
        let ownedByAnotherCanvas = assetsByCanvas.contains { otherCanvasID, assets in
            otherCanvasID != canvasID && assets[asset.id] != nil
        }
        guard !ownedByAnotherCanvas else { return false }
        var assets = assetsByCanvas[canvasID, default: [:]]
        if let existing = assets[asset.id], existing.version >= asset.version {
            return true
        }
        assets[asset.id] = asset
        assetsByCanvas[canvasID] = assets
        return true
    }

    /// Register an asset against the origin canvas carried by a DAG envelope.
    /// The current UI canvas is intentionally not an input to this adapter.
    @discardableResult
    func register(_ asset: MediaAsset, envelope: DAGExecutionEnvelope) -> Bool {
        let targetCanvasID = asset.sourceCanvasID ?? envelope.canvasID
        guard validateDAGAssetRegistration(
            envelope: envelope,
            targetCanvasID: targetCanvasID
        ) == .accepted else {
            return false
        }
        return register(asset, canvasID: envelope.canvasID)
    }

    @discardableResult
    func register(_ asset: MediaAsset, executionEnvelope: DAGExecutionEnvelope) -> Bool {
        register(asset, envelope: executionEnvelope)
    }

    func asset(id: UUID, canvasID: UUID) -> MediaAsset? {
        assetsByCanvas[canvasID]?[id]
    }

    /// Global canonical lookup for execution projections. A malformed snapshot
    /// can still contain an ID under more than one canvas; an unscoped lookup
    /// must fail closed instead of projecting one canvas into another.
    func asset(id: UUID) -> MediaAsset? {
        let matches = assetsByCanvas.values.compactMap { $0[id] }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    func migrateLegacyNodes(_ nodes: [CanvasNode], canvasID: UUID) -> [MediaAsset] {
        var migrated: [MediaAsset] = []
        for node in nodes {
            guard let asset = LegacyMediaMigration.asset(from: node, canvasID: canvasID),
                  !assetsByCanvas[canvasID, default: [:]].keys.contains(asset.id) else { continue }
            if register(asset, canvasID: canvasID) {
                migrated.append(asset)
            }
        }
        return migrated
    }

    func assets(canvasID: UUID, includingDeleted: Bool = false) -> [MediaAsset] {
        let assets = assetsByCanvas[canvasID, default: [:]].values
        return assets
            .filter { includingDeleted || $0.status != .deleted }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    @discardableResult
    func updateStatus(
        assetID: UUID,
        canvasID: UUID,
        status: MediaAssetStatus,
        failureCode: String? = nil
    ) -> Bool {
        guard var asset = assetsByCanvas[canvasID]?[assetID] else { return false }
        asset.status = status
        asset.failureCode = failureCode
        asset.updatedAt = Date()
        asset.version += 1
        assetsByCanvas[canvasID]?[assetID] = asset
        return true
    }

    @discardableResult
    func remove(assetID: UUID, canvasID: UUID) -> Bool {
        updateStatus(assetID: assetID, canvasID: canvasID, status: .deleted)
    }

    func clear(canvasID: UUID) {
        assetsByCanvas[canvasID] = nil
    }

    /// Independent task write-back. The asset fact source is scoped by the
    /// supplied canvas ID and never consults transcript/session state.
    @discardableResult
    func registerVideoTaskResult(
        _ record: VideoTaskRecord,
        context: MediaTaskContext,
        currentIdentity: CanvasExecutionIdentity,
        isCancelled: Bool = false,
        artifactID: String? = nil,
        persistenceDirectory: URL? = nil
    ) -> MediaTaskWritebackDecision {
        guard !lifecycleGuard.contains(canvasID: context.identity.canvasID) else {
            return .rejected(.identity(.rejected(.canvasMismatch)))
        }
        guard context.identity.isValid,
              currentIdentity.isValid,
              context.providerSnapshot.isValid,
              context.providerSnapshot.capabilities.contains(.video),
              !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.nodeID == context.identity.nodeID,
              record.providerID == context.providerSnapshot.providerID,
              record.promptFingerprint == context.promptFingerprint,
              record.idempotencyKey == context.idempotencyKey,
              record.status == .succeeded,
              let videoURL = record.videoURL,
              !videoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.invalidPayload)
        }
        let identityDecision = validateCanvasWriteback(
            expected: context.identity,
            actual: currentIdentity,
            isCancelled: isCancelled
        )
        guard identityDecision == .accepted else {
            return .rejected(.identity(identityDecision))
        }

        var assets = assetsByCanvas[context.identity.canvasID, default: [:]]
        // A successful record is a single writeback fact. A repeated callback
        // for the same remote job must not create a new version or overwrite
        // the already accepted asset.
        guard !assets.values.contains(where: {
            $0.jobID == record.id
                || $0.metadata["idempotencyKey"] == context.idempotencyKey
        }) else {
            return .rejected(.invalidPayload)
        }
        var metadata = [
            "attempt": String(context.attempt),
            "graphRevision": String(context.identity.graphRevision),
            "nodeRevision": String(context.identity.nodeRevision),
            "idempotencyKey": context.idempotencyKey,
            "providerConfigurationFingerprint": context.providerSnapshot.configurationFingerprint,
        ]
        if let artifactID,
           !artifactID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["artifactID"] = artifactID
        }
        let asset = MediaAsset(
            id: UUID(),
            kind: .video,
            source: .generated,
            status: .ready,
            localURL: record.assetPath,
            remoteURL: videoURL,
            sourceCanvasID: context.identity.canvasID,
            sourceNodeID: context.identity.nodeID,
            runID: context.identity.runID,
            jobID: record.id,
            providerID: context.providerSnapshot.providerID,
            version: 1,
            metadata: metadata
        )
        assets[asset.id] = asset
        if let persistenceDirectory {
            var nextAssetsByCanvas = assetsByCanvas
            nextAssetsByCanvas[context.identity.canvasID] = assets
            do {
                try Self.persist(
                    CanvasAssetStoreSnapshot(
                        assetsByCanvas: Dictionary(
                            uniqueKeysWithValues: nextAssetsByCanvas.map {
                                ($0.key, Array($0.value.values))
                            }
                        )
                    ),
                    to: persistenceDirectory
                )
            } catch {
                return .rejected(.persistenceFailed)
            }
        }
        assetsByCanvas[context.identity.canvasID] = assets
        return .accepted
    }

    /// Atomically resolves the current execution identity and performs the
    /// scoped asset write-back within this actor turn. Callers with a live
    /// scope provide the identity closure; recovery callers use the frozen
    /// fallback identity.
    @discardableResult
    func registerVideoTaskResultAtomically(
        _ record: VideoTaskRecord,
        context: MediaTaskContext,
        currentIdentity: CanvasExecutionIdentity,
        currentIdentityProvider: (@Sendable () -> CanvasExecutionIdentity?)? = nil,
        executionLease: CanvasExecutionScopeLease? = nil,
        isCancelled: Bool = false,
        artifactID: String? = nil,
        persistenceDirectory: URL? = nil
    ) -> MediaTaskWritebackDecision {
        if let executionLease {
            guard let writeback = executionLease.consume({ leaseIdentity in
                registerVideoTaskResult(
                    record,
                    context: context,
                    currentIdentity: leaseIdentity,
                    isCancelled: isCancelled,
                    artifactID: artifactID,
                    persistenceDirectory: persistenceDirectory
                )
            }) else {
                return .rejected(.identity(.rejected(.graphRevisionMismatch)))
            }
            return writeback
        }

        let actualIdentity: CanvasExecutionIdentity
        if let currentIdentityProvider {
            guard let providedIdentity = currentIdentityProvider() else {
                return .rejected(.identity(.rejected(.graphRevisionMismatch)))
            }
            actualIdentity = providedIdentity
        } else {
            actualIdentity = currentIdentity
        }
        return registerVideoTaskResult(
            record,
            context: context,
            currentIdentity: actualIdentity,
            isCancelled: isCancelled,
            artifactID: artifactID,
            persistenceDirectory: persistenceDirectory
        )
    }

    /// Envelope-compatible write-back adapter for DAG callers. It validates
    /// the run-level origin before delegating to the existing node identity
    /// and payload checks.
    @discardableResult
    func registerVideoTaskResult(
        _ record: VideoTaskRecord,
        context: MediaTaskContext,
        currentIdentity: CanvasExecutionIdentity,
        executionEnvelope: DAGExecutionEnvelope,
        isCancelled: Bool = false,
        artifactID: String? = nil,
        persistenceDirectory: URL? = nil
    ) -> MediaTaskWritebackDecision {
        guard executionEnvelope.isValid else {
            return .rejected(.invalidPayload)
        }
        let envelopeIdentity = executionEnvelope.identity(
            for: context.identity.nodeID,
            nodeRevision: context.identity.nodeRevision
        )
        let envelopeDecision = validateCanvasWriteback(
            expected: context.identity,
            actual: envelopeIdentity,
            isCancelled: false
        )
        guard envelopeDecision == .accepted else {
            return .rejected(.identity(envelopeDecision))
        }
        guard context.matches(executionEnvelope: executionEnvelope) else {
            return .rejected(.invalidPayload)
        }
        return registerVideoTaskResultAtomically(
            record,
            context: context,
            currentIdentity: currentIdentity,
            isCancelled: isCancelled,
            artifactID: artifactID,
            persistenceDirectory: persistenceDirectory
        )
    }

    @discardableResult
    func registerVideoTaskResultAtomically(
        _ record: VideoTaskRecord,
        context: MediaTaskContext,
        currentIdentity: CanvasExecutionIdentity,
        executionEnvelope: DAGExecutionEnvelope,
        currentIdentityProvider: (@Sendable () -> CanvasExecutionIdentity?)? = nil,
        executionLease: CanvasExecutionScopeLease? = nil,
        isCancelled: Bool = false,
        artifactID: String? = nil,
        persistenceDirectory: URL? = nil
    ) -> MediaTaskWritebackDecision {
        guard executionEnvelope.isValid else {
            return .rejected(.invalidPayload)
        }
        let envelopeIdentity = executionEnvelope.identity(
            for: context.identity.nodeID,
            nodeRevision: context.identity.nodeRevision
        )
        let envelopeDecision = validateCanvasWriteback(
            expected: context.identity,
            actual: envelopeIdentity,
            isCancelled: false
        )
        guard envelopeDecision == .accepted else {
            return .rejected(.identity(envelopeDecision))
        }
        guard context.matches(executionEnvelope: executionEnvelope) else {
            return .rejected(.invalidPayload)
        }
        return registerVideoTaskResultAtomically(
            record,
            context: context,
            currentIdentity: currentIdentity,
            currentIdentityProvider: currentIdentityProvider,
            executionLease: executionLease,
            isCancelled: isCancelled,
            artifactID: artifactID,
            persistenceDirectory: persistenceDirectory
        )
    }

    @discardableResult
    func registerVideoTaskResult(
        _ record: VideoTaskRecord,
        context: MediaTaskContext,
        currentIdentity: CanvasExecutionIdentity,
        envelope: DAGExecutionEnvelope,
        isCancelled: Bool = false,
        artifactID: String? = nil,
        persistenceDirectory: URL? = nil
    ) -> MediaTaskWritebackDecision {
        registerVideoTaskResult(
            record,
            context: context,
            currentIdentity: currentIdentity,
            executionEnvelope: envelope,
            isCancelled: isCancelled,
            artifactID: artifactID,
            persistenceDirectory: persistenceDirectory
        )
    }

    private static func persist(
        _ snapshot: CanvasAssetStoreSnapshot,
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(
            to: directory.appendingPathComponent(snapshotFileName),
            options: .atomic
        )
    }

    private static func normalize(_ source: [UUID: [MediaAsset]]) -> [UUID: [UUID: MediaAsset]] {
        source.reduce(into: [:]) { result, entry in
            let (canvasID, assets) = entry
            result[canvasID] = assets.reduce(into: [:]) { byID, asset in
                guard asset.sourceCanvasID == nil || asset.sourceCanvasID == canvasID else { return }
                if byID[asset.id]?.version ?? 0 <= asset.version {
                    byID[asset.id] = asset
                }
            }
        }
    }
}

extension CanvasAssetStore: MediaAssetResolving {}
