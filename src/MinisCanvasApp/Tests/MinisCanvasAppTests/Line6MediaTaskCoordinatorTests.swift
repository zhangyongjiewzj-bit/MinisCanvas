import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("线6独立媒体任务身份与写回保护")
struct Line6MediaTaskCoordinatorTests {
    private func identity(
        canvasID: UUID = UUID(),
        runID: UUID = UUID(),
        graphRevision: Int = 4,
        nodeID: UUID = UUID(),
        nodeRevision: Int = 2
    ) -> CanvasExecutionIdentity {
        CanvasExecutionIdentity(
            canvasID: canvasID,
            runID: runID,
            graphRevision: graphRevision,
            nodeID: nodeID,
            nodeRevision: nodeRevision
        )
    }

    private func context(
        identity: CanvasExecutionIdentity,
        attempt: Int = 1,
        providerID: String = "line6-provider"
    ) -> MediaTaskContext {
        MediaTaskContext(
            identity: identity,
            attempt: attempt,
            providerSnapshot: ProviderSnapshot(
                providerID: providerID,
                modelID: "video-v1",
                capabilities: [.video],
                configurationFingerprint: "config-fp"
            ),
            promptFingerprint: "fp"
        )
    }

    @Test func contextCarriesStableIdentityProviderSnapshotAndRetryAttempt() {
        let original = context(identity: identity())
        let retried = original.withAttempt(2)

        #expect(original.identity.canvasID == retried.identity.canvasID)
        #expect(original.identity.runID == retried.identity.runID)
        #expect(original.identity.graphRevision == retried.identity.graphRevision)
        #expect(original.identity.nodeID == retried.identity.nodeID)
        #expect(original.identity.nodeRevision == retried.identity.nodeRevision)
        #expect(original.providerSnapshot == retried.providerSnapshot)
        #expect(original.idempotencyKey == retried.idempotencyKey)
        #expect(retried.attempt == 2)
    }

    @Test func mediaContextBridgesDAGEnvelopeForAssetWriteback() async {
        let canvasID = UUID()
        let nodeID = UUID()
        let envelope = DAGExecutionEnvelope(
            canvasID: canvasID,
            runID: UUID(),
            graphRevision: 4,
            graphFingerprint: "graph-fp",
            cancellationGeneration: 2,
            providerSnapshotFingerprint: "config-fp",
            idempotencyKey: "dag-run"
        )
        let provider = ProviderSnapshot(
            providerID: "line6-provider",
            modelID: "video-v1",
            capabilities: [.video],
            configurationFingerprint: "config-fp"
        )
        let taskContext = MediaTaskContext(
            envelope: envelope,
            nodeID: nodeID,
            nodeRevision: 4,
            providerSnapshot: provider,
            promptFingerprint: "fp"
        )
        let record = VideoTaskRecord(
            id: "envelope-task",
            nodeID: nodeID,
            providerID: provider.providerID,
            taskID: "remote-envelope-task",
            promptFingerprint: "fp",
            status: .succeeded,
            videoURL: "https://cdn.example/envelope.mp4",
            idempotencyKey: taskContext.idempotencyKey,
            assetPath: "/tmp/envelope.mp4"
        )
        let assets = CanvasAssetStore()

        #expect(taskContext.executionEnvelope == envelope)
        #expect(
            await assets.registerVideoTaskResult(
                record,
                context: taskContext,
                currentIdentity: taskContext.identity,
                executionEnvelope: envelope
            ) == .accepted
        )
        #expect((await assets.assets(canvasID: canvasID)).count == 1)

        let foreignEnvelope = DAGExecutionEnvelope(
            canvasID: UUID(),
            runID: envelope.runID,
            graphRevision: envelope.graphRevision,
            graphFingerprint: envelope.graphFingerprint,
            cancellationGeneration: envelope.cancellationGeneration,
            providerSnapshotFingerprint: envelope.providerSnapshotFingerprint,
            idempotencyKey: envelope.idempotencyKey
        )
        #expect(
            await assets.registerVideoTaskResult(
                record,
                context: taskContext,
                currentIdentity: taskContext.identity,
                envelope: foreignEnvelope
            ) == .rejected(.identity(.rejected(.canvasMismatch)))
        )
    }

    @Test func metadataRoundTripRejectsCrossCanvasRebinding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("line6-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordID = "record-1"
        let first = context(identity: identity())
        let store = MediaTaskMetadataStore(directory: directory)
        try store.bind(recordID: recordID, context: first, allowLegacyBinding: true)

        let restored = MediaTaskMetadataStore(directory: directory)
        #expect(try restored.context(recordID: recordID) == first)
        do {
            try restored.bind(
                recordID: recordID,
                context: context(identity: identity(canvasID: UUID())),
                allowLegacyBinding: false
            )
            Issue.record("跨画布任务不应允许重绑定")
        } catch let error as MediaTaskMetadataError {
            #expect(error == .identityConflict(recordID))
        }
    }

    @Test func metadataRebindingRejectsPromptFingerprintChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("line6-metadata-prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordID = "record-prompt-1"
        let first = context(identity: identity())
        let store = MediaTaskMetadataStore(directory: directory)
        try store.bind(recordID: recordID, context: first, allowLegacyBinding: true)

        let changedPrompt = MediaTaskContext(
            identity: first.identity,
            attempt: first.attempt,
            providerSnapshot: first.providerSnapshot,
            promptFingerprint: "different-prompt",
            idempotencyKey: first.idempotencyKey
        )
        do {
            try store.bind(
                recordID: recordID,
                context: changedPrompt,
                allowLegacyBinding: false
            )
            Issue.record("同一 idempotency key 不应允许替换 prompt fingerprint")
        } catch let error as MediaTaskMetadataError {
            #expect(error == .identityConflict(recordID))
        }
    }

    @Test func assetStoreRejectsCrossCanvasAndLateIdentityWriteback() async {
        let canvasA = UUID()
        let canvasB = UUID()
        let taskIdentity = identity(canvasID: canvasA)
        let taskContext = context(identity: taskIdentity)
        let record = VideoTaskRecord(
            id: "line6-task",
            nodeID: taskIdentity.nodeID,
            providerID: taskContext.providerSnapshot.providerID,
            taskID: "remote-line6",
            promptFingerprint: "fp",
            status: .succeeded,
            videoURL: "https://cdn.example/line6.mp4",
            idempotencyKey: taskContext.idempotencyKey,
            assetPath: "/tmp/line6.mp4"
        )
        let assets = CanvasAssetStore()

        let accepted = await assets.registerVideoTaskResult(
            record,
            context: taskContext,
            currentIdentity: taskIdentity
        )
        #expect(accepted == .accepted)
        #expect((await assets.assets(canvasID: canvasA)).count == 1)

        let crossCanvas = await assets.registerVideoTaskResult(
            record,
            context: taskContext,
            currentIdentity: identity(
                canvasID: canvasB,
                runID: taskIdentity.runID,
                graphRevision: taskIdentity.graphRevision,
                nodeID: taskIdentity.nodeID,
                nodeRevision: taskIdentity.nodeRevision
            )
        )
        #expect(crossCanvas != .accepted)
        #expect(await assets.assets(canvasID: canvasB).isEmpty)

        let lateGraph = await assets.registerVideoTaskResult(
            record,
            context: taskContext,
            currentIdentity: identity(
                canvasID: canvasA,
                runID: taskIdentity.runID,
                graphRevision: taskIdentity.graphRevision + 1,
                nodeID: taskIdentity.nodeID,
                nodeRevision: taskIdentity.nodeRevision
            )
        )
        #expect(lateGraph != .accepted)
        #expect((await assets.assets(canvasID: canvasA)).count == 1)

        let canceled = await assets.registerVideoTaskResult(
            record,
            context: taskContext,
            currentIdentity: taskIdentity,
            isCancelled: true
        )
        #expect(canceled == .rejected(.identity(.rejected(.cancelled))))
    }

    @Test @MainActor func deletedCanvasRejectsDetachedTaskWriteback() async {
        let canvas = CanvasStore()
        let deleted = canvas.createCanvas(name: "待删除")
        let remaining = canvas.createCanvas(name: "保留")
        let taskIdentity = identity(canvasID: deleted.id)
        let taskContext = context(identity: taskIdentity)
        let record = VideoTaskRecord(
            id: "deleted-canvas-task",
            nodeID: taskIdentity.nodeID,
            providerID: taskContext.providerSnapshot.providerID,
            taskID: "remote-deleted-canvas",
            promptFingerprint: "fp",
            status: .succeeded,
            videoURL: "https://cdn.example/deleted-canvas.mp4",
            idempotencyKey: taskContext.idempotencyKey,
            assetPath: "/tmp/deleted-canvas.mp4"
        )

        #expect(canvas.deleteCanvas(id: deleted.id))
        #expect(canvas.currentCanvasID == remaining.id)

        let decision = await canvas.assetStore.registerVideoTaskResult(
            record,
            context: taskContext,
            currentIdentity: taskIdentity
        )
        #expect(decision != .accepted)
        #expect(await canvas.assetStore.assets(canvasID: deleted.id).isEmpty)
        #expect(await canvas.assetStore.assets(canvasID: remaining.id).isEmpty)
    }

    @Test func assetStoreRejectsTaskRecordWithMismatchedFrozenContext() async {
        let taskIdentity = identity()
        let taskContext = context(identity: taskIdentity)
        let mismatchedRecord = VideoTaskRecord(
            id: "line6-mismatched-task",
            nodeID: UUID(),
            providerID: "another-provider",
            taskID: "remote-line6-mismatch",
            promptFingerprint: "another-prompt",
            status: .succeeded,
            videoURL: "https://cdn.example/mismatch.mp4",
            idempotencyKey: "another-idempotency-key",
            assetPath: "/tmp/mismatch.mp4"
        )

        let assets = CanvasAssetStore()
        let decision = await assets.registerVideoTaskResult(
            mismatchedRecord,
            context: taskContext,
            currentIdentity: taskIdentity
        )

        #expect(decision == .rejected(.invalidPayload))
        #expect(await assets.assets(canvasID: taskIdentity.canvasID).isEmpty)
    }

    @Test func retryVideoUsesPersistedAttemptForAssetMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("line6-retry-attempt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let taskIdentity = identity()
        let taskContext = context(identity: taskIdentity)
        let taskStore = VideoTaskStore(directory: directory)
        let queued = taskStore.enqueue(
            nodeID: taskIdentity.nodeID,
            providerID: taskContext.providerSnapshot.providerID,
            promptFingerprint: taskContext.promptFingerprint,
            idempotencyKey: taskContext.idempotencyKey
        )
        #expect(taskStore.markCanceled(id: queued.id))
        try MediaTaskMetadataStore(directory: directory).bind(
            recordID: queued.id,
            context: taskContext,
            allowLegacyBinding: true
        )

        let backend = Line6ImmediateVideoBackend()
        let executor = VideoTaskExecutor(
            store: taskStore,
            backend: backend,
            assetDownloader: Line6AssetDownloader(),
            assetDirectory: directory.appendingPathComponent("assets"),
            pollInterval: 0
        )
        let assets = CanvasAssetStore()
        let artifacts = ArtifactStore(
            directory: directory.appendingPathComponent("artifacts")
        )
        let coordinator = CanvasTaskCoordinator(
            media: MediaTaskCoordinator(executor: executor),
            assetStore: assets,
            artifactStore: artifacts,
            currentIdentityProvider: { taskIdentity }
        )

        let result = try await coordinator.retryVideo(
            id: queued.id,
            context: taskContext,
            promptFingerprint: taskContext.promptFingerprint,
            request: CloudVideoRequest(prompt: "retry attempt"),
            currentIdentity: taskIdentity
        )

        #expect(result.writeback == .accepted)
        #expect(result.artifactID != nil)
        #expect(await backend.submitCount == 1)
        #expect(try await executor.context(for: queued.id)?.attempt == 2)
        let persistedAssets = await assets.assets(canvasID: taskIdentity.canvasID)
        #expect(persistedAssets.count == 1)
        #expect(persistedAssets.first?.metadata["attempt"] == "2")
        #expect(await artifacts.allReceipts().count == 1)
    }

    @Test func scopedRecoveryWithoutSidecarIdentityFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("line6-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeID = UUID()
        let store = VideoTaskStore(directory: directory)
        let queued = store.enqueue(
            nodeID: nodeID,
            providerID: "line6-provider",
            promptFingerprint: "recovery"
        )
        #expect(store.markSubmitted(id: queued.id, taskID: "remote-restored"))

        let backend = Line6ImmediateVideoBackend()
        let executor = VideoTaskExecutor(
            store: VideoTaskStore(directory: directory),
            backend: backend,
            assetDownloader: Line6AssetDownloader(),
            assetDirectory: directory.appendingPathComponent("assets"),
            pollInterval: 0
        )
        let taskContext = context(identity: identity(nodeID: nodeID))
        do {
            _ = try await executor.recover(id: queued.id, context: taskContext)
            Issue.record("没有 sidecar identity 的旧任务不应进入 scoped recovery")
        } catch let error as VideoTaskExecutionError {
            #expect(error == .scopedRecoveryUnavailable(queued.id))
        }
        #expect(await backend.submitCount == 0)
    }

    @Test func documentStageDoesNotWriteBackAfterIdentityBecomesStale() async {
        var pipeline = DocumentPipeline(stages: [
            DocumentStage(name: "视频提示词", providerID: "line6-provider", promptTemplate: "{{input}}")
        ])
        let stageID = pipeline.stages[0].id
        let scoped = DocumentStageExecutionContext(
            identity: identity(nodeID: stageID),
            providerSnapshot: ProviderSnapshot(
                providerID: "line6-provider",
                modelID: "video-v1",
                capabilities: [.video],
                configurationFingerprint: "config-fp"
            )
        )
        let llm: StageLLMCall = { _ in "late output" }

        await #expect(throws: DocumentStageError.self) {
            try await DocumentStageRunner.runStage(
                pipeline: &pipeline,
                index: 0,
                documentContent: "input",
                context: scoped,
                isCurrent: { false },
                llm: llm
            )
        }
        #expect(pipeline.stages[0].status == .stale)
        #expect(pipeline.stages[0].output.isEmpty)
    }

    @Test func assetStorePersistenceFailureIsRejected() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("line6-persist-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // persistenceDirectory 的父路径是普通文件 → createDirectory 必败 → persistenceFailed
        let blocked = directory.appendingPathComponent("blocked", isDirectory: false)
        try? Data("blocked".utf8).write(to: blocked)
        let persistenceDirectory = blocked.appendingPathComponent("assets", isDirectory: true)

        let taskIdentity = identity()
        let taskContext = context(identity: taskIdentity)
        let record = VideoTaskRecord(
            id: "line6-persist-fail-task",
            nodeID: taskIdentity.nodeID,
            providerID: taskContext.providerSnapshot.providerID,
            taskID: "remote-line6-persist-fail",
            promptFingerprint: "fp",
            status: .succeeded,
            videoURL: "https://cdn.example/persist-fail.mp4",
            idempotencyKey: taskContext.idempotencyKey,
            assetPath: "/tmp/persist-fail.mp4"
        )
        let assets = CanvasAssetStore()
        let decision = await assets.registerVideoTaskResult(
            record,
            context: taskContext,
            currentIdentity: taskIdentity,
            persistenceDirectory: persistenceDirectory
        )
        #expect(decision == .rejected(.persistenceFailed))
        #expect(await assets.assets(canvasID: taskIdentity.canvasID, includingDeleted: true).isEmpty)
    }
}

private actor Line6ImmediateVideoBackend: VideoTaskBackend {
    private(set) var submitCount = 0

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitCount += 1
        return "remote-line6"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.example/line6.mp4")
    }
}

private struct Line6AssetDownloader: VideoAssetDownloader {
    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try Data("line6".utf8).write(to: destination, options: .atomic)
        return destination
    }
}
