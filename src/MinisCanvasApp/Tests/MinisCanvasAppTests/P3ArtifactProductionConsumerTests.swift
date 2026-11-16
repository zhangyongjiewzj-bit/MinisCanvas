import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

private func p3ArtifactContext(canvasID: UUID = UUID(), runID: UUID = UUID()) -> MediaTaskContext {
    let nodeID = UUID()
    let identity = CanvasExecutionIdentity(
        canvasID: canvasID,
        runID: runID,
        graphRevision: 4,
        nodeID: nodeID,
        nodeRevision: 4
    )
    let snapshot = ProviderSnapshot(
        providerID: "p3-artifact-provider",
        modelID: "p3-artifact-model",
        capabilities: [.video],
        configurationFingerprint: "p3-artifact-config"
    )
    return MediaTaskContext(
        identity: identity,
        providerSnapshot: snapshot,
        promptFingerprint: "p3-artifact-prompt"
    )
}

private func p3ArtifactRecord(
    context: MediaTaskContext,
    path: String,
    id: String = "artifact-task-1"
) -> VideoTaskRecord {
    VideoTaskRecord(
        id: id,
        nodeID: context.identity.nodeID,
        providerID: context.providerSnapshot.providerID,
        taskID: "remote-artifact-1",
        promptFingerprint: context.promptFingerprint,
        status: .succeeded,
        videoURL: "https://cdn.example/artifact.mp4",
        idempotencyKey: context.idempotencyKey,
        assetPath: path
    )
}

@Suite("P3 Artifact production consumer")
struct P3ArtifactProductionConsumerTests {
    @Test @MainActor
    func productionAssetSnapshotUsesVideoTaskStoreDirectoryAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-asset-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDirectory = root.appendingPathComponent("tasks", isDirectory: true)
        let draftDirectory = root.appendingPathComponent("drafts", isDirectory: true)
        let taskStore = VideoTaskStore(directory: taskDirectory)
        let canvas = CanvasStore(
            videoTaskStore: taskStore,
            videoAssetDirectory: root.appendingPathComponent("videoAssets", isDirectory: true),
            videoProviderFactory: { _ in P3ArtifactProvider() }
        )
        #expect(canvas.assetPersistenceDirectory == taskDirectory)
        canvas.attachDraftStore(DraftStore(directory: draftDirectory))
        canvas.noteGraphChanged()
        canvas.flushCanvasDraft()
        let canvasID = canvas.currentCanvasID
        let asset = MediaAsset(
            id: UUID(),
            kind: .video,
            source: .generated,
            localURL: root.appendingPathComponent("video.mp4").path,
            sourceCanvasID: canvasID
        )
        await canvas.assetStore.register(asset, canvasID: canvasID)
        await canvas.assetStore.persist(to: canvas.assetPersistenceDirectory)
        #expect(CanvasAssetStore.loadSnapshot(from: taskDirectory)?.assetsByCanvas[canvasID]?.first?.id == asset.id)
        #expect(CanvasAssetStore.loadSnapshot(from: draftDirectory) == nil)

        let restarted = CanvasStore(
            videoTaskStore: VideoTaskStore(directory: taskDirectory),
            videoAssetDirectory: root.appendingPathComponent("videoAssets", isDirectory: true),
            videoProviderFactory: { _ in P3ArtifactProvider() }
        )
        restarted.attachDraftStore(DraftStore(directory: draftDirectory))
        // Deterministic seam: the snapshot file on the unified persistence root is
        // the authoritative fact source. Reload it directly instead of racing the
        // actor's async replace with a single Task.yield (this test flaked twice
        // in the asset-root-fix-green2/green3 evidence runs).
        let requiredValue561_1 = CanvasAssetStore.loadSnapshot(from: taskDirectory)
        let snapshot561: CanvasAssetStoreSnapshot = try #require(requiredValue561_1)
        let reloaded = CanvasAssetStore(
            snapshot: snapshot561
        )
        let restoredAssetIDs = await reloaded.assets(canvasID: canvasID).map(\.id)
        #expect(restoredAssetIDs == [asset.id])
    }

    @Test
    func mediaCompletionCreatesDurableReceiptWithChecksum() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-red-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaURL = mediaDirectory.appendingPathComponent("video.mp4")
        try Data("artifact-bytes".utf8).write(to: mediaURL, options: .atomic)

        let store = ArtifactStore(directory: root.appendingPathComponent("artifacts", isDirectory: true))
        let context = p3ArtifactContext()
        let record = p3ArtifactRecord(context: context, path: mediaURL.path)
        let receipt = try await store.recordMediaCompletion(record, context: context)

        #expect(receipt.canvasID == context.identity.canvasID)
        #expect(receipt.runID == context.identity.runID)
        #expect(receipt.checksum == "6521df166eb07efaf36eba5b6bedefd9d6a252e9c80bab1c99653700ec71473c")
        #expect(await store.receipt(id: receipt.id) == receipt)
    }

    @Test
    func reusedTaskIDAcrossCanvasesIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-cross-canvas-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaURL = mediaDirectory.appendingPathComponent("video.mp4")
        try Data("artifact-bytes".utf8).write(to: mediaURL, options: .atomic)

        let store = ArtifactStore(
            directory: root.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )
        let canvasA = p3ArtifactContext()
        let canvasB = p3ArtifactContext()
        let sharedTaskID = "shared-canvas-task"

        _ = try await store.recordMediaCompletion(
            p3ArtifactRecord(context: canvasA, path: mediaURL.path, id: sharedTaskID),
            context: canvasA
        )

        do {
            _ = try await store.recordMediaCompletion(
                p3ArtifactRecord(context: canvasB, path: mediaURL.path, id: sharedTaskID),
                context: canvasB
            )
            Issue.record("相同任务 ID 跨 Canvas 复用必须被拒绝")
        } catch ArtifactStoreError.identityMismatch {
            // expected
        } catch {
            Issue.record("expected identityMismatch, got \(error)")
        }
    }

    @Test
    func productionCanvasCompletionPublishesStableArtifactReference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-consumer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        let artifactDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        let taskStore = VideoTaskStore(directory: root.appendingPathComponent("tasks", isDirectory: true))
        let provider = P3ArtifactProvider()
        let executor = VideoTaskExecutor(
            store: taskStore,
            backend: CloudVideoTaskBackend(provider: provider),
            assetDownloader: P3ArtifactDownloader(),
            assetDirectory: mediaDirectory,
            pollInterval: 0,
            pollTimeout: 1
        )
        let context = p3ArtifactContext()
        let request = CloudVideoRequest(prompt: "artifact consumer")
        let artifactStore = ArtifactStore(directory: artifactDirectory)
        let coordinator = CanvasTaskCoordinator(
            media: MediaTaskCoordinator(executor: executor),
            assetStore: CanvasAssetStore(),
            artifactStore: artifactStore
        )

        let result = try await coordinator.runVideo(
            context: context,
            promptFingerprint: context.promptFingerprint,
            request: request,
            currentIdentity: context.identity
        )

        #expect(result.artifactID?.hasPrefix("artifact-") == true)
        #expect(await artifactStore.allReceipts().count == 1)
    }

    @Test
    func restartDoesNotDuplicateReceiptAndRejectsOutsidePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaURL = mediaDirectory.appendingPathComponent("video.mp4")
        try Data("artifact-bytes".utf8).write(to: mediaURL, options: .atomic)
        let artifactDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        let context = p3ArtifactContext()
        let record = p3ArtifactRecord(context: context, path: mediaURL.path)

        let first = ArtifactStore(directory: artifactDirectory)
        let receipt = try await first.recordMediaCompletion(record, context: context)
        let second = ArtifactStore(directory: artifactDirectory)
        #expect(await second.allReceipts().count == 1)
        #expect(try await second.recordMediaCompletion(record, context: context) == receipt)

        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let outside = outsideRoot.appendingPathComponent("outside.mp4")
        try Data("outside".utf8).write(to: outside, options: .atomic)
        do {
            _ = try await second.recordMediaCompletion(
                p3ArtifactRecord(context: context, path: outside.path, id: "artifact-task-outside"),
                context: context
            )
            Issue.record("路径越界必须拒绝")
        } catch ArtifactStoreError.pathOutsideDirectory {
            // expected
        } catch {
            Issue.record("expected pathOutsideDirectory, got \(error)")
        }
    }

    @Test
    func deleteRestoreAndCancelledCompletionFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaURL = root.appendingPathComponent("video.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("artifact-bytes".utf8).write(to: mediaURL, options: .atomic)
        let store = ArtifactStore(directory: root.appendingPathComponent("artifacts", isDirectory: true))
        let context = p3ArtifactContext()
        let record = p3ArtifactRecord(context: context, path: mediaURL.path)
        let receipt = try await store.recordMediaCompletion(record, context: context)
        #expect(await store.delete(id: receipt.id))
        do {
            _ = try await store.recordMediaCompletion(record, context: context)
            Issue.record("删除后的迟到完成必须拒绝")
        } catch ArtifactStoreError.deleted {
            // expected
        } catch {
            Issue.record("expected deleted, got \(error)")
        }
        #expect(await store.restore(id: receipt.id))
        let restored = try await store.recordMediaCompletion(record, context: context)
        #expect(restored.id == receipt.id)
        #expect(restored.checksum == receipt.checksum)
        do {
            _ = try await store.recordMediaCompletion(record, context: context, isCancelled: true)
            Issue.record("取消任务不得生成 artifact")
        } catch ArtifactStoreError.cancelled {
            // expected
        } catch {
            Issue.record("expected cancelled, got \(error)")
        }
    }

    @Test
    func symlinkMediaPathIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let realURL = mediaDirectory.appendingPathComponent("real.mp4")
        let linkURL = mediaDirectory.appendingPathComponent("link.mp4")
        try Data("artifact-bytes".utf8).write(to: realURL, options: .atomic)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        let store = ArtifactStore(
            directory: root.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )
        let context = p3ArtifactContext()
        do {
            _ = try await store.recordMediaCompletion(
                p3ArtifactRecord(context: context, path: linkURL.path, id: "artifact-task-link"),
                context: context
            )
            Issue.record("符号链接媒体路径必须拒绝")
        } catch ArtifactStoreError.symlinkRejected {
            // expected
        } catch {
            Issue.record("expected symlinkRejected, got \(error)")
        }
    }

    @Test
    func concurrentCompletionsShareOneReceiptSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-concurrent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let firstURL = mediaDirectory.appendingPathComponent("first.mp4")
        let secondURL = mediaDirectory.appendingPathComponent("second.mp4")
        try Data("first".utf8).write(to: firstURL, options: .atomic)
        try Data("second".utf8).write(to: secondURL, options: .atomic)

        let store = ArtifactStore(
            directory: root.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )
        let firstContext = p3ArtifactContext()
        let secondContext = p3ArtifactContext()
        let firstRecord = p3ArtifactRecord(context: firstContext, path: firstURL.path, id: "concurrent-first")
        let secondRecord = p3ArtifactRecord(context: secondContext, path: secondURL.path, id: "concurrent-second")

        async let first = store.recordMediaCompletion(firstRecord, context: firstContext)
        async let second = store.recordMediaCompletion(secondRecord, context: secondContext)
        _ = try await (first, second)

        #expect(await store.allReceipts().map(\.taskID) == ["concurrent-first", "concurrent-second"])
        let restarted = ArtifactStore(
            directory: root.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )
        #expect(await restarted.allReceipts().count == 2)
    }

    @Test @MainActor
    func productionCanvasWritebackAnchorsReceiptRecoverableAcrossRestart() async throws {
        // The real production consumer path (CanvasStore -> MinisCanvasVideoInvoker
        // -> CanvasTaskCoordinator) must anchor the receipt in the single injected
        // ArtifactStore so a restarted process reloads the same anchor from disk.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-prod-writeback-anchor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = P3AnchorRecoveryProvider()
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue,
            title: "锚点视频",
            backendConfig: NodeBackendConfig(
                providerType: .cloud,
                providerID: provider.providerID,
                modelID: "p3-anchor-model"
            )
        )
        let taskStore = VideoTaskStore(directory: directory)
        let assetDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        let artifactDirectory = directory.appendingPathComponent("artifacts", isDirectory: true)
        let artifactStore = ArtifactStore(directory: artifactDirectory, allowedMediaRoot: directory)
        let canvas = CanvasStore(
            graph: NodeGraph(nodes: [node]),
            videoTaskStore: taskStore,
            videoAssetDirectory: assetDirectory,
            videoAssetDownloader: P3ArtifactDownloader(),
            videoProviderFactory: { _ in provider },
            artifactStore: artifactStore
        )
        guard let invoker = canvas.context.videoInvoker as? MinisCanvasVideoInvoker else {
            Issue.record("默认 CanvasStore 必须装配生产视频调用器")
            return
        }
        // 唯一 ArtifactStore 注入：生产构造点必须传递同一实例，而非 fallback 第二份 store。
        #expect(invoker.artifactStore === artifactStore)

        let runID = UUID()
        let executionEnvelope = DAGExecutionEnvelope(
            canvasID: canvas.currentCanvasID,
            runID: runID,
            graph: canvas.graph
        )
        let identity = CanvasExecutionIdentity(
            canvasID: canvas.currentCanvasID,
            runID: runID,
            graphRevision: executionEnvelope.graphRevision,
            nodeID: node.id,
            nodeRevision: executionEnvelope.graphRevision
        )
        let snapshot = ProviderSnapshot(
            providerID: provider.providerID,
            modelID: "p3-anchor-model",
            capabilities: [.video],
            configurationFingerprint: MinisCanvasVideoInvoker.configurationFingerprint(
                providerID: provider.providerID,
                modelID: "p3-anchor-model"
            )
        )
        let context = MediaTaskContext(
            envelope: executionEnvelope,
            nodeID: node.id,
            nodeRevision: identity.nodeRevision,
            providerSnapshot: snapshot,
            promptFingerprint: "p3-anchor-recovery"
        )
        let queued = taskStore.enqueue(
            nodeID: node.id,
            providerID: provider.providerID,
            promptFingerprint: context.promptFingerprint,
            idempotencyKey: context.idempotencyKey
        )
        #expect(taskStore.markSubmitted(id: queued.id, taskID: "p3-anchor-remote"))
        #expect(taskStore.markPolling(id: queued.id))
        try MediaTaskMetadataStore(directory: directory).bind(
            recordID: queued.id,
            context: context,
            allowLegacyBinding: true
        )

        let recovered = try await invoker.recoverPendingTasks()
        #expect(recovered.map(\.id) == [queued.id])

        // 可恢复 receipt 锚点：收据落在注入的唯一 store，资产索引只保存引用锚点。
        let receipts = await artifactStore.allReceipts()
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        let assets = await canvas.assetStore.assets(canvasID: canvas.currentCanvasID)
        #expect(assets.count == 1)
        let asset = try #require(assets.first)
        #expect(asset.metadata["artifactID"] == receipt.id)
        #expect(asset.metadata["checksum"] == nil)

        // 重启锚点：同一目录重建 ArtifactStore 能重载同一收据（模拟进程重启）。
        let restarted = ArtifactStore(directory: artifactDirectory, allowedMediaRoot: directory)
        #expect(await restarted.receipt(id: receipt.id)?.checksum == receipt.checksum)
    }

    @Test @MainActor
    func defaultCanvasContextWiresCanonicalSharedArtifactStoreIntoVideoConsumer() async throws {
        // The default formal-test composition uses its profile store. Verify
        // the producer and actual node read consumer share that durable owner.
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let canvas = CanvasStore(graph: NodeGraph(nodes: [node]))
        let invoker = try #require(canvas.context.videoInvoker as? MinisCanvasVideoInvoker)
        let artifactDirectory = profile.minisCoreDirectory.appendingPathComponent("artifacts", isDirectory: true)
        let actualDirectory = await invoker.artifactStore.directory
        #expect(actualDirectory.standardizedFileURL == artifactDirectory.standardizedFileURL)

        let mediaURL = profile.minisCoreDirectory.appendingPathComponent("artifact-default-\(UUID().uuidString).mp4")
        try Data("artifact-bytes".utf8).write(to: mediaURL, options: .atomic)
        let context = p3ArtifactContext()
        let receipt = try await invoker.artifactStore.recordMediaCompletion(
            p3ArtifactRecord(context: context, path: mediaURL.path, id: UUID().uuidString),
            context: context
        )
        var backend = node.backendConfig ?? NodeBackendConfig()
        backend.params["artifact.id"] = receipt.id
        canvas.updateBackendConfig(backend, for: node.id)
        #expect(await canvas.artifactReceipt(forNode: node.id) == receipt)
        let reopened = ArtifactStore(directory: artifactDirectory)
        #expect(await reopened.receipt(id: receipt.id) == receipt)
    }

    @Test
    func directoryMediaPathIsRejectedAsNonRegularFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-directory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let store = ArtifactStore(
            directory: root.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )
        let context = p3ArtifactContext()
        do {
            _ = try await store.recordMediaCompletion(
                p3ArtifactRecord(context: context, path: mediaDirectory.path, id: "directory-media"),
                context: context
            )
            Issue.record("目录不得被接受为媒体文件")
        } catch ArtifactStoreError.notRegularFile {
            // expected
        } catch {
            Issue.record("expected notRegularFile, got \(error)")
        }
    }

    @Test
    func missingMediaFileIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let store = ArtifactStore(
            directory: root.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )
        let context = p3ArtifactContext()
        let missing = mediaDirectory.appendingPathComponent("missing.mp4")
        do {
            _ = try await store.recordMediaCompletion(
                p3ArtifactRecord(context: context, path: missing.path, id: "artifact-task-missing"),
                context: context
            )
            Issue.record("不存在的媒体文件必须拒绝")
        } catch ArtifactStoreError.missingFile {
            // expected
        } catch {
            Issue.record("expected missingFile, got \(error)")
        }
    }

    @Test
    func invalidExecutionContextIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-invalid-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaURL = mediaDirectory.appendingPathComponent("video.mp4")
        try Data("artifact-bytes".utf8).write(to: mediaURL, options: .atomic)

        let store = ArtifactStore(
            directory: root.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )
        // graphRevision 为负 → CanvasExecutionIdentity.isValid == false
        let invalidIdentity = CanvasExecutionIdentity(
            canvasID: UUID(),
            runID: UUID(),
            graphRevision: -1,
            nodeID: UUID(),
            nodeRevision: 0
        )
        let invalidContext = MediaTaskContext(
            identity: invalidIdentity,
            providerSnapshot: ProviderSnapshot(
                providerID: "p3-artifact-provider",
                modelID: "p3-artifact-model",
                capabilities: [.video],
                configurationFingerprint: "p3-artifact-config"
            ),
            promptFingerprint: "p3-invalid-context"
        )
        do {
            _ = try await store.recordMediaCompletion(
                p3ArtifactRecord(context: invalidContext, path: mediaURL.path, id: "artifact-task-invalid-context"),
                context: invalidContext
            )
            Issue.record("无效执行身份必须拒绝")
        } catch ArtifactStoreError.invalidContext {
            // expected
        } catch {
            Issue.record("expected invalidContext, got \(error)")
        }
    }

    @Test
    func invalidPayloadMutationsAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-invalid-payload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaURL = mediaDirectory.appendingPathComponent("video.mp4")
        try Data("artifact-bytes".utf8).write(to: mediaURL, options: .atomic)

        let store = ArtifactStore(
            directory: root.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )
        let context = p3ArtifactContext()

        func variant(
            id: String = "artifact-task-1",
            status: VideoTaskRecord.Status = .succeeded,
            nodeID: UUID? = nil,
            providerID: String? = nil,
            fingerprint: String? = nil,
            key: String? = nil,
            assetPath: String? = nil
        ) -> VideoTaskRecord {
            VideoTaskRecord(
                id: id,
                nodeID: nodeID ?? context.identity.nodeID,
                providerID: providerID ?? context.providerSnapshot.providerID,
                taskID: "remote-artifact-1",
                promptFingerprint: fingerprint ?? context.promptFingerprint,
                status: status,
                videoURL: "https://cdn.example/artifact.mp4",
                idempotencyKey: key ?? context.idempotencyKey,
                assetPath: assetPath ?? mediaURL.path
            )
        }

        let cases: [(String, VideoTaskRecord)] = [
            ("非成功状态", variant(status: .failed)),
            ("空任务 id", variant(id: "")),
            ("节点不匹配", variant(nodeID: UUID())),
            ("provider 不匹配", variant(providerID: "other-provider")),
            ("提示词指纹不匹配", variant(fingerprint: "other-fingerprint")),
            ("幂等键不匹配", variant(key: "other-key")),
            ("空资产路径", variant(assetPath: "")),
        ]
        for (label, record) in cases {
            do {
                _ = try await store.recordMediaCompletion(record, context: context)
                Issue.record("invalidPayload 未拒绝: \(label)")
            } catch ArtifactStoreError.invalidPayload {
                // expected
            } catch {
                Issue.record("expected invalidPayload for \(label), got \(error)")
            }
        }
    }

    @Test
    func persistenceFailureIsReported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-persist-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaURL = mediaDirectory.appendingPathComponent("video.mp4")
        try Data("artifact-bytes".utf8).write(to: mediaURL, options: .atomic)
        // artifacts 路径被同名普通文件占用 → createDirectory 必败 → persistenceFailed
        let artifactDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        try Data("blocked".utf8).write(to: artifactDirectory, options: .atomic)

        let store = ArtifactStore(directory: artifactDirectory, allowedMediaRoot: mediaDirectory)
        let context = p3ArtifactContext()
        do {
            _ = try await store.recordMediaCompletion(
                p3ArtifactRecord(context: context, path: mediaURL.path),
                context: context
            )
            Issue.record("持久化失败必须报告 persistenceFailed")
        } catch ArtifactStoreError.persistenceFailed {
            // expected
        } catch {
            Issue.record("expected persistenceFailed, got \(error)")
        }
    }

    @Test
    func discardNewReceiptRollsBackOnlyFreshReceipts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-discard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaURL = mediaDirectory.appendingPathComponent("video.mp4")
        try Data("artifact-bytes".utf8).write(to: mediaURL, options: .atomic)

        let store = ArtifactStore(
            directory: root.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )
        let context = p3ArtifactContext()

        // 新建收据可丢弃 → 全部清空
        let first = try await store.recordMediaCompletion(
            p3ArtifactRecord(context: context, path: mediaURL.path, id: "discard-a"),
            context: context
        )
        #expect(await store.discardNewReceipt(id: first.id))
        #expect(await store.allReceipts().isEmpty)
        // 重复丢弃 → false
        #expect(!(await store.discardNewReceipt(id: first.id)))
        // 不存在的 id → false
        #expect(!(await store.discardNewReceipt(id: "artifact-nope")))

        // 已删除收据（isDeleted）→ false
        let second = try await store.recordMediaCompletion(
            p3ArtifactRecord(context: context, path: mediaURL.path, id: "discard-b"),
            context: context
        )
        #expect(await store.delete(id: second.id))
        #expect(!(await store.discardNewReceipt(id: second.id)))
        // 恢复后的旧收据（version > 1）→ false
        #expect(await store.restore(id: second.id))
        #expect(!(await store.discardNewReceipt(id: second.id)))
    }

    @Test @MainActor
    func nodeArtifactAnchorResolvesReceiptThroughProductionReadSeam() async throws {
        // 真实缺口：生产侧 receipt 只有写入（coordinator），没有任何读取 consumer；
        // 计划 C 受控转换链 artifact-<taskID> -> metadata[artifactID] -> params[artifact.id]
        // 的读取端（锚点 -> 持久化收据）在生产代码中缺失。本 seam 用生产构造点
        // （CanvasStore 注入同一 ArtifactStore）把节点锚点解析回收据。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-reader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaURL = mediaDirectory.appendingPathComponent("video.mp4")
        try Data("artifact-bytes".utf8).write(to: mediaURL, options: .atomic)

        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let artifactStore = ArtifactStore(
            directory: root.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )
        let canvas = CanvasStore(
            graph: NodeGraph(nodes: [node]),
            videoTaskStore: VideoTaskStore(directory: root),
            videoAssetDirectory: root.appendingPathComponent("videoAssets", isDirectory: true),
            artifactStore: artifactStore
        )
        // 生产写回（ArtifactStore 级记录）创建持久化收据。
        let context = p3ArtifactContext()
        let receipt = try await artifactStore.recordMediaCompletion(
            p3ArtifactRecord(context: context, path: mediaURL.path, id: "reader-task"),
            context: context
        )

        // 生产锚点：syncGeneratedVideoResults 在真实运行后写 params["artifact.id"]。
        var backend = node.backendConfig ?? NodeBackendConfig()
        backend.params["artifact.id"] = receipt.id
        canvas.updateBackendConfig(backend, for: node.id)

        // 生产读取 seam：由节点锚点解析同一注入 store 的持久化收据。
        let resolved = await canvas.artifactReceipt(forNode: node.id)
        #expect(resolved?.id == receipt.id)
        #expect(resolved?.checksum == receipt.checksum)
        #expect(resolved?.localPath == mediaURL.path)
    }

    @Test @MainActor
    func testOnlyInitPersistsAssetsInInjectedContextTaskStoreDirectory() async throws {
        // B1 regression: the test-only init(graph:context:) previously hardcoded
        // assetPersistenceDirectory = VideoTaskStore.defaultDirectory(), so a
        // context whose MinisCanvasVideoInvoker is backed by a custom
        // VideoTaskStore leaked asset snapshots into the default AppSupport root
        // instead of following the injected context's task-store directory.
        // The B1 seam passes the context's task-store directory explicitly; the
        // write/read round-trip must land there and never in the default root.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-b1-custom-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDirectory = root.appendingPathComponent("tasks", isDirectory: true)
        let taskStore = VideoTaskStore(directory: taskDirectory)
        let invoker = MinisCanvasVideoInvoker(
            taskStore: taskStore,
            assetDirectory: root.appendingPathComponent("videoAssets", isDirectory: true),
            assetDownloader: P3ArtifactDownloader(),
            providerFactory: { _ in P3ArtifactProvider() }
        )
        let context = GraphExecutionContext(
            executors: NodeExecutors(
                llmInvoker: MinisCanvasLLMInvoker(),
                blenderInvoker: MinisCanvasBlenderInvoker()
            ),
            imageInvoker: MinisCanvasImageInvoker(),
            videoInvoker: invoker
        )
        let canvas = CanvasStore(
            graph: NodeGraph(),
            context: context,
            assetPersistenceDirectory: taskStore.directory
        )

        // The injected context is backed by the custom task store; asset
        // persistence must follow it — never the default AppSupport root.
        #expect(canvas.assetPersistenceDirectory == taskStore.directory)
        #expect(canvas.assetPersistenceDirectory != VideoTaskStore.defaultDirectory())

        let canvasID = canvas.currentCanvasID
        let asset = MediaAsset(
            id: UUID(),
            kind: .video,
            source: .generated,
            localURL: root.appendingPathComponent("video.mp4").path,
            sourceCanvasID: canvasID
        )
        await canvas.assetStore.register(asset, canvasID: canvasID)
        await canvas.assetStore.persist(to: canvas.assetPersistenceDirectory)

        // Write/read round-trip lands in the custom task directory…
        let requiredValue561_2 = CanvasAssetStore.loadSnapshot(from: taskDirectory)
        let snapshot = try #require(requiredValue561_2)
        #expect(snapshot.assetsByCanvas[canvasID]?.first?.id == asset.id)
        // …and never leaks into the default AppSupport root.
        let defaultSnapshot = CanvasAssetStore.loadSnapshot(from: VideoTaskStore.defaultDirectory())
        #expect(defaultSnapshot?.assetsByCanvas[canvasID] == nil)
    }
}

private struct P3ArtifactDownloader: VideoAssetDownloader {
    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try Data("artifact-bytes".utf8).write(to: destination, options: .atomic)
        return destination
    }
}

private actor P3AnchorRecoveryProvider: CloudVideoGenerator {
    let providerID = "p3-anchor-video"
    let displayName = "P3 Anchor Recovery Video"
    let isConfigured = true
    private(set) var submitCount = 0

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitCount += 1
        return "unexpected-anchor-submit"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.example/p3-anchor.mp4")
    }
}

private struct P3ArtifactProvider: CloudVideoGenerator {
    let providerID = "p3-artifact-provider"
    let displayName = "P3 Artifact Provider"
    let isConfigured = true

    func submitVideo(_ request: CloudVideoRequest) async throws -> String { "artifact-task-1" }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.example/artifact.mp4")
    }
}
