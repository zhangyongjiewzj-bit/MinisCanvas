import Foundation
import CanvasCore
import MinisCore

struct CanvasTaskRunResult: Sendable, Equatable {
    let record: VideoTaskRecord
    let writeback: MediaTaskWritebackDecision
    let artifactID: String?
}

/// Canvas-scoped adapter. It is the only new layer allowed to turn an
/// independent task result into an asset. The current identity is supplied by
/// the caller at write-back time, so a canvas switch or graph edit rejects a
/// late result instead of overwriting another node.
actor CanvasTaskCoordinator {
    let media: MediaTaskCoordinator
    let assetStore: CanvasAssetStore
    let artifactStore: ArtifactStore
    let assetPersistenceDirectory: URL?
    let requiresExecutionEnvelope: Bool
    private let currentIdentityProvider: (@Sendable () -> CanvasExecutionIdentity?)?
    private let executionLeaseProvider: (@Sendable () -> CanvasExecutionScopeLease?)?
    private let currentWorkerProjectionProvider: (@Sendable () -> CanvasWorkerProjection?)?

    init(
        media: MediaTaskCoordinator,
        assetStore: CanvasAssetStore,
        artifactStore: ArtifactStore,
        assetPersistenceDirectory: URL? = nil,
        requiresExecutionEnvelope: Bool = false,
        currentIdentityProvider: (@Sendable () -> CanvasExecutionIdentity?)? = nil,
        executionLeaseProvider: (@Sendable () -> CanvasExecutionScopeLease?)? = nil,
        currentWorkerProjectionProvider: (@Sendable () -> CanvasWorkerProjection?)? = nil
    ) {
        self.media = media
        self.assetStore = assetStore
        self.artifactStore = artifactStore
        self.assetPersistenceDirectory = assetPersistenceDirectory?.standardizedFileURL
        self.requiresExecutionEnvelope = requiresExecutionEnvelope
        self.currentIdentityProvider = currentIdentityProvider
        self.executionLeaseProvider = executionLeaseProvider
        self.currentWorkerProjectionProvider = currentWorkerProjectionProvider
    }

    private func validatedCurrentIdentity(
        expected: CanvasExecutionIdentity,
        fallback: CanvasExecutionIdentity
    ) throws -> CanvasExecutionIdentity {
        let actual: CanvasExecutionIdentity
        if let provider = currentIdentityProvider, let provided = provider() {
            actual = provided
        } else if currentIdentityProvider != nil {
            throw VideoTaskExecutionError.contextMismatch("Canvas execution scope is no longer current")
        } else {
            actual = fallback
        }
        guard validateCanvasWriteback(expected: expected, actual: actual, isCancelled: false) == .accepted else {
            throw VideoTaskExecutionError.contextMismatch("Canvas execution scope is no longer current")
        }
        return actual
    }

    private func validateWorkerResult(
        _ workerProjection: CanvasWorkerProjection,
        recordID: String,
        context: MediaTaskContext,
        currentIdentity: CanvasExecutionIdentity
    ) throws {
        guard workerProjection.provider == context.providerSnapshot,
              let actualProjection = currentWorkerProjectionProvider?(),
              actualProjection.provider == context.providerSnapshot,
              actualProjection.identity == currentIdentity,
              case .accepted = CanvasWorkerSeam.acceptResult(
                  projection: workerProjection,
                  resultFingerprint: recordID,
                  actualIdentity: actualProjection.identity,
                  actualGraphRevision: actualProjection.graphRevision,
                  actualGraphFingerprint: actualProjection.graphFingerprint
              ) else {
            throw VideoTaskExecutionError.contextMismatch(
                "Canvas worker result no longer matches the frozen scope"
            )
        }
    }

    private func commit(
        _ record: VideoTaskRecord,
        context: MediaTaskContext,
        currentIdentity: CanvasExecutionIdentity,
        cancelled: Bool,
        workerProjection: CanvasWorkerProjection?
    ) async throws -> CanvasTaskRunResult {
        if requiresExecutionEnvelope, context.executionEnvelope == nil {
            throw VideoTaskExecutionError.contextMismatch(
                "Canvas production media writeback requires a DAG execution envelope"
            )
        }
        let actualIdentity = try validatedCurrentIdentity(expected: context.identity, fallback: currentIdentity)
        if let workerProjection {
            try validateWorkerResult(
                workerProjection,
                recordID: record.id,
                context: context,
                currentIdentity: actualIdentity
            )
        }
        let completion: ArtifactCompletion
        if let executionEnvelope = context.executionEnvelope {
            completion = try await artifactStore.recordMediaCompletionResult(
                record,
                context: context,
                executionEnvelope: executionEnvelope,
                isCancelled: cancelled
            )
        } else {
            completion = try await artifactStore.recordMediaCompletionResult(
                record,
                context: context,
                isCancelled: cancelled
            )
        }
        let receipt = completion.receipt
        let assetSnapshotBeforeWriteback = await assetStore.snapshot()
        do {
            let writeback: MediaTaskWritebackDecision
            if let executionEnvelope = context.executionEnvelope {
                let executionLease: CanvasExecutionScopeLease?
                if let executionLeaseProvider {
                    guard let providedLease = executionLeaseProvider() else {
                        throw VideoTaskExecutionError.contextMismatch(
                            "Canvas execution lease is no longer current"
                        )
                    }
                    guard providedLease.identity == context.identity,
                          providedLease.identity == actualIdentity else {
                        _ = providedLease.consume { _ in () }
                        throw VideoTaskExecutionError.contextMismatch(
                            "Canvas execution lease is no longer current"
                        )
                    }
                    executionLease = providedLease
                } else {
                    executionLease = nil
                }
                writeback = await assetStore.registerVideoTaskResultAtomically(
                    record,
                    context: context,
                    currentIdentity: actualIdentity,
                    executionEnvelope: executionEnvelope,
                    currentIdentityProvider: currentIdentityProvider,
                    executionLease: executionLease,
                    isCancelled: cancelled,
                    artifactID: receipt.id,
                    persistenceDirectory: assetPersistenceDirectory
                )
            } else {
                let executionLease: CanvasExecutionScopeLease?
                if let executionLeaseProvider {
                    guard let providedLease = executionLeaseProvider() else {
                        throw VideoTaskExecutionError.contextMismatch(
                            "Canvas execution lease is no longer current"
                        )
                    }
                    guard providedLease.identity == context.identity,
                          providedLease.identity == actualIdentity else {
                        _ = providedLease.consume { _ in () }
                        throw VideoTaskExecutionError.contextMismatch(
                            "Canvas execution lease is no longer current"
                        )
                    }
                    executionLease = providedLease
                } else {
                    executionLease = nil
                }
                writeback = await assetStore.registerVideoTaskResultAtomically(
                    record,
                    context: context,
                    currentIdentity: actualIdentity,
                    currentIdentityProvider: currentIdentityProvider,
                    executionLease: executionLease,
                    isCancelled: cancelled,
                    artifactID: receipt.id,
                    persistenceDirectory: assetPersistenceDirectory
                )
            }
            guard case .accepted = writeback else {
                await rollbackRejectedWriteback(
                    record: record,
                    context: context,
                    completion: completion,
                    assetSnapshotBeforeWriteback: assetSnapshotBeforeWriteback
                )
                return CanvasTaskRunResult(record: record, writeback: writeback, artifactID: nil)
            }

            if let workerProjection {
                try validateWorkerResult(
                    workerProjection,
                    recordID: record.id,
                    context: context,
                    currentIdentity: actualIdentity
                )
            }
            return CanvasTaskRunResult(record: record, writeback: writeback, artifactID: receipt.id)
        } catch {
            await rollbackRejectedWriteback(
                record: record,
                context: context,
                completion: completion,
                assetSnapshotBeforeWriteback: assetSnapshotBeforeWriteback
            )
            throw error
        }
    }

    private func rollbackRejectedWriteback(
        record: VideoTaskRecord,
        context: MediaTaskContext,
        completion: ArtifactCompletion,
        assetSnapshotBeforeWriteback: CanvasAssetStoreSnapshot
    ) async {
        if completion.created {
            await artifactStore.discardNewReceipt(id: completion.receipt.id)
        }

        let currentSnapshot = await assetStore.snapshot()
        let priorAssetIDs = Set(
            assetSnapshotBeforeWriteback.assetsByCanvas[context.identity.canvasID, default: []]
                .map(\.id)
        )
        let currentAssets = currentSnapshot.assetsByCanvas[context.identity.canvasID, default: []]
        let lateAssetIDs = Set(
            currentAssets
                .filter {
                    !priorAssetIDs.contains($0.id)
                        && ($0.jobID == record.id
                            || $0.metadata["idempotencyKey"] == context.idempotencyKey)
                }
                .map(\.id)
        )
        if !lateAssetIDs.isEmpty {
            var nextAssetsByCanvas = currentSnapshot.assetsByCanvas
            nextAssetsByCanvas[context.identity.canvasID] = currentAssets.filter {
                !lateAssetIDs.contains($0.id)
            }
            await assetStore.replace(with: CanvasAssetStoreSnapshot(assetsByCanvas: nextAssetsByCanvas))
            if let assetPersistenceDirectory {
                await assetStore.persist(to: assetPersistenceDirectory)
            }
        }

        let shouldClearTaskAsset = completion.created || !lateAssetIDs.isEmpty
        if shouldClearTaskAsset,
           let assetPath = record.assetPath,
           removeDownloadedAssetIfOwnedByTaskRoot(assetPath) {
            _ = media.executor.store.clearSucceededAssetPath(
                id: record.id,
                expectedPath: assetPath
            )
        }
    }

    private func removeDownloadedAssetIfOwnedByTaskRoot(_ path: String?) -> Bool {
        guard let path,
              let taskRoot = assetPersistenceDirectory,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        let root = taskRoot.standardizedFileURL
        guard file == resolved,
              file.path != root.path,
              file.path.hasPrefix(root.path + "/") else {
            return false
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return true }
        do {
            try FileManager.default.removeItem(at: file)
            return !FileManager.default.fileExists(atPath: file.path)
        } catch {
            return false
        }
    }

    func runVideo(
        context: MediaTaskContext,
        promptFingerprint: String,
        request: CloudVideoRequest,
        currentIdentity: CanvasExecutionIdentity,
        workerProjection: CanvasWorkerProjection? = nil
    ) async throws -> CanvasTaskRunResult {
        let scopedContext = context.withPromptFingerprint(promptFingerprint)
        _ = try validatedCurrentIdentity(expected: scopedContext.identity, fallback: currentIdentity)
        let record = try await media.start(
            context: scopedContext,
            promptFingerprint: promptFingerprint,
            request: request
        )
        let cancelled = await media.isCanceled(idempotencyKey: scopedContext.idempotencyKey)
        return try await commit(
            record,
            context: scopedContext,
            currentIdentity: currentIdentity,
            cancelled: cancelled,
            workerProjection: workerProjection
        )
    }

    @discardableResult
    func cancel(context: MediaTaskContext) async -> Bool {
        await media.cancel(idempotencyKey: context.idempotencyKey)
    }

    @discardableResult
    func cancel(context: MediaTaskContext, promptFingerprint: String) async -> Bool {
        await media.cancel(context: context, promptFingerprint: promptFingerprint)
    }

    func retryVideo(
        id: String,
        context: MediaTaskContext,
        promptFingerprint: String,
        request: CloudVideoRequest,
        currentIdentity: CanvasExecutionIdentity,
        workerProjection: CanvasWorkerProjection? = nil
    ) async throws -> CanvasTaskRunResult {
        let scopedContext = context.withPromptFingerprint(promptFingerprint)
        let record = try await media.retry(
            id: id,
            context: scopedContext,
            promptFingerprint: promptFingerprint,
            request: request
        )
        let effectiveContext = try await media.context(for: record.id) ?? scopedContext
        let cancelled = await media.isCanceled(idempotencyKey: effectiveContext.idempotencyKey)
        return try await commit(
            record,
            context: effectiveContext,
            currentIdentity: currentIdentity,
            cancelled: cancelled,
            workerProjection: workerProjection
        )
    }

    func recoverVideo(
        id: String,
        context: MediaTaskContext,
        currentIdentity: CanvasExecutionIdentity,
        workerProjection: CanvasWorkerProjection? = nil
    ) async throws -> CanvasTaskRunResult? {
        guard let record = try await media.recover(id: id, context: context) else { return nil }
        let cancelled = await media.isCanceled(idempotencyKey: context.idempotencyKey)
        return try await commit(
            record,
            context: context,
            currentIdentity: currentIdentity,
            cancelled: cancelled,
            workerProjection: workerProjection
        )
    }
}
