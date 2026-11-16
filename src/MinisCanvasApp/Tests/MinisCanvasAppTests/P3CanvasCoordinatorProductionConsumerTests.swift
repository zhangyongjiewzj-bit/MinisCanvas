import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

private struct P3CanvasAssetDownloader: VideoAssetDownloader {
    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try Data("video".utf8).write(to: destination, options: .atomic)
        return destination
    }
}

private struct P3CanvasProvider: CloudVideoGenerator {
    let providerID = "p3-test-video"
    let displayName = "P3 Test Video"
    let isConfigured = true

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        "p3-remote-task"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.example/p3.mp4")
    }
}

private actor P3CancellableCanvasProvider: CloudVideoGenerator {
    let providerID = "p3-cancellable-video"
    let displayName = "P3 Cancellable Video"
    let isConfigured = true
    private(set) var submitStarted = false
    private var releaseSubmit = false
    private var submitWaiters: [CheckedContinuation<Void, Never>] = []

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitStarted = true
        let waiters = submitWaiters
        submitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        while !releaseSubmit {
            await Task.yield()
        }
        return "p3-cancellable-remote"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.example/p3-cancellable.mp4")
    }

    func release() {
        releaseSubmit = true
    }

    /// Deterministic latch: suspends until submitVideo has been entered, then
    /// returns. Actor isolation makes the handoff exact — no wall-clock polling.
    func waitUntilSubmitted() async {
        if submitStarted { return }
        await withCheckedContinuation { continuation in
            submitWaiters.append(continuation)
        }
    }
}

private actor P3RecoveryProvider: CloudVideoGenerator {
    let providerID = "p3-recovery-video"
    let displayName = "P3 Recovery Video"
    let isConfigured = true
    private(set) var submitCount = 0
    private(set) var pollCount = 0

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitCount += 1
        return "unexpected-submit"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        pollCount += 1
        return CloudTaskState(phase: .succeeded, videoURL: "https://cdn.example/p3-recovery.mp4")
    }
}

@Suite("P3 Canvas coordinator production consumer")
struct P3CanvasCoordinatorProductionConsumerTests {
    @Test @MainActor
    func defaultCanvasContextSharesCanonicalAssetStoreWithVideoConsumer() {
        let canvas = CanvasStore()
        guard let invoker = canvas.context.videoInvoker as? MinisCanvasVideoInvoker else {
            Issue.record("默认 Canvas context 必须使用 MinisCanvasVideoInvoker")
            return
        }
        #expect(invoker.assetStore === canvas.assetStore)
    }

    @Test
    func scopedVideoConsumerRegistersAcceptedResultInCanonicalAssetStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-coordinator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let canvasID = UUID()
        let runID = UUID()
        let graph = NodeGraph(nodes: [node], revision: 7)
        let executionEnvelope = DAGExecutionEnvelope(
            canvasID: canvasID,
            runID: runID,
            graph: graph
        )
        let store = CanvasAssetStore()
        let taskStore = VideoTaskStore(directory: directory)
        let invoker = MinisCanvasVideoInvoker(
            taskStore: taskStore,
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            assetDownloader: P3CanvasAssetDownloader(),
            providerFactory: { _ in P3CanvasProvider() },
            assetStore: store
        )
        let scoped = invoker.scoped(canvasID: canvasID, runID: runID, graphRevision: 7)
        let backend = NodeBackendConfig(
            providerType: .cloud,
            providerID: "p3-test-video",
            modelID: "p3-model"
        )

        let outcome = try await scoped.generate(
            node: node,
            prompt: "scoped production consumer",
            firstFrame: nil,
            backend: backend,
            executionEnvelope: executionEnvelope
        )

        guard case .videoWithArtifact(let path, let artifactID) = outcome else {
            Issue.record("scoped consumer 应返回已落盘视频")
            return
        }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(artifactID.hasPrefix("artifact-"))
        let assets = await store.assets(canvasID: canvasID)
        #expect(assets.count == 1)
        #expect(assets.first?.kind == .video)
        #expect(assets.first?.sourceCanvasID == canvasID)
        #expect(assets.first?.sourceNodeID == node.id)

        let snapshot = try #require(CanvasAssetStore.loadSnapshot(from: directory))
        let reloaded = CanvasAssetStore(snapshot: snapshot)
        let restoredAssets = await reloaded.assets(canvasID: canvasID)
        #expect(restoredAssets.count == 1)
        #expect(restoredAssets.first?.metadata["artifactID"] == artifactID)
    }

    @Test
    func cancelTasksForRunCancelsTheScopedOperationBeforeWriteback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-coordinator-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = P3CancellableCanvasProvider()
        let assetStore = CanvasAssetStore()
        let taskStore = VideoTaskStore(directory: directory)
        let invoker = MinisCanvasVideoInvoker(
            taskStore: taskStore,
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            assetDownloader: P3CanvasAssetDownloader(),
            providerFactory: { _ in provider },
            assetStore: assetStore
        )
        let canvasID = UUID()
        let runID = UUID()
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "可取消视频")
        let executionEnvelope = DAGExecutionEnvelope(
            canvasID: canvasID,
            runID: runID,
            graph: NodeGraph(nodes: [node], revision: 3)
        )
        var backend = NodeBackendConfig()
        backend.providerID = provider.providerID
        backend.modelID = "p3-cancellable-model"
        let scoped = invoker.scoped(
            canvasID: canvasID,
            runID: runID,
            graphRevision: executionEnvelope.graphRevision
        )

        let operation = Task {
            try? await scoped
                .generate(
                    node: node,
                    prompt: "cancel me",
                    firstFrame: nil,
                    backend: backend,
                    executionEnvelope: executionEnvelope
                )
        }
        // Deterministic latch: waits until the provider submit has actually been
        // entered, so cancelTasks always sees the persisted record (no 2s poll).
        await provider.waitUntilSubmitted()

        #expect(await scoped.cancelTasks(runID: runID))
        await provider.release()
        _ = await operation.value

        #expect(scoped.taskStore.allRecords().first?.status == .canceled)
        #expect(await assetStore.assets(canvasID: canvasID).isEmpty)
    }

    @Test @MainActor
    func productionStartupRecoveryPollsPersistedTaskWithoutResubmitting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-coordinator-startup-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = P3RecoveryProvider()
        let taskStore = VideoTaskStore(directory: directory)
        let queued = taskStore.enqueue(
            nodeID: UUID(),
            providerID: provider.providerID,
            promptFingerprint: "p3-startup-recovery"
        )
        #expect(taskStore.markSubmitted(id: queued.id, taskID: "p3-recovery-remote"))
        #expect(taskStore.markPolling(id: queued.id))

        let invoker = MinisCanvasVideoInvoker(
            taskStore: taskStore,
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            assetDownloader: P3CanvasAssetDownloader(),
            providerFactory: { _ in provider }
        )
        let context = GraphExecutionContext(
            executors: NodeExecutors(
                llmInvoker: MinisCanvasLLMInvoker(),
                blenderInvoker: MinisCanvasBlenderInvoker()
            ),
            imageInvoker: MinisCanvasImageInvoker(),
            videoInvoker: invoker
        )
        let bridge = BridgeStore(canvas: CanvasStore(graph: NodeGraph(), context: context))

        let recovered = await bridge.recoverPendingCanvasMediaTasks()

        #expect(recovered.map(\.id) == [queued.id])
        #expect(recovered.first?.status == .succeeded)
        #expect(await provider.submitCount == 0)
        #expect(await provider.pollCount == 1)
    }

    @Test @MainActor
    func defaultCanvasStoreRecoversPersistedScopedVideoIntoRestoredCanvas() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-default-canvas-startup-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = P3RecoveryProvider()
        let taskStore = VideoTaskStore(directory: directory)
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue,
            title: "恢复视频",
            backendConfig: NodeBackendConfig(
                providerType: .cloud,
                providerID: provider.providerID,
                modelID: "p3-recovery-model"
            )
        )
        let artifactStore = ArtifactStore(
            directory: directory.appendingPathComponent("artifacts", isDirectory: true)
        )
        let canvas = CanvasStore(
            graph: NodeGraph(nodes: [node]),
            videoTaskStore: taskStore,
            videoAssetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            videoAssetDownloader: P3CanvasAssetDownloader(),
            videoProviderFactory: { _ in provider },
            artifactStore: artifactStore
        )
        let runID = UUID()
        let executionEnvelope = DAGExecutionEnvelope(
            canvasID: canvas.currentCanvasID,
            runID: runID,
            graph: canvas.graph
        )
        let identity = CanvasExecutionIdentity(
            canvasID: executionEnvelope.canvasID,
            runID: executionEnvelope.runID,
            graphRevision: executionEnvelope.graphRevision,
            nodeID: node.id,
            nodeRevision: executionEnvelope.graphRevision
        )
        let snapshot = ProviderSnapshot(
            providerID: provider.providerID,
            modelID: "p3-recovery-model",
            capabilities: [.video],
            configurationFingerprint: MinisCanvasVideoInvoker.configurationFingerprint(
                providerID: provider.providerID,
                modelID: "p3-recovery-model"
            )
        )
        let context = MediaTaskContext(
            envelope: executionEnvelope,
            nodeID: node.id,
            nodeRevision: identity.nodeRevision,
            providerSnapshot: snapshot,
            promptFingerprint: "p3-default-canvas-startup-recovery"
        )
        let queued = taskStore.enqueue(
            nodeID: node.id,
            providerID: provider.providerID,
            promptFingerprint: context.promptFingerprint,
            idempotencyKey: context.idempotencyKey
        )
        #expect(taskStore.markSubmitted(id: queued.id, taskID: "p3-default-canvas-remote"))
        #expect(taskStore.markPolling(id: queued.id))
        try MediaTaskMetadataStore(directory: directory).bind(
            recordID: queued.id,
            context: context,
            allowLegacyBinding: true
        )

        guard let invoker = canvas.context.videoInvoker as? MinisCanvasVideoInvoker else {
            Issue.record("默认 CanvasStore 必须装配生产视频调用器")
            return
        }
        let recovered = try await invoker.recoverPendingTasks()

        #expect(recovered.map(\.id) == [queued.id])
        #expect(recovered.first?.status == .succeeded)
        #expect(await provider.submitCount == 0)
        #expect(await provider.pollCount == 1)
        let assets = await canvas.assetStore.assets(canvasID: canvas.currentCanvasID)
        #expect(assets.count == 1)
        #expect(assets.first?.sourceNodeID == node.id)
        #expect(assets.first?.metadata["artifactID"]?.hasPrefix("artifact-") == true)
        // 恢复路径的 receipt 锚点落在注入的唯一 ArtifactStore，并可跨重启重载。
        let receipts = await artifactStore.allReceipts()
        #expect(receipts.count == 1)
        let restarted = ArtifactStore(
            directory: directory.appendingPathComponent("artifacts", isDirectory: true)
        )
        #expect(await restarted.receipt(id: receipts[0].id)?.checksum == receipts[0].checksum)
        await #expect(throws: VideoTaskExecutionError.self) {
            try await invoker.generate(
                node: node,
                prompt: "recovery must not create a live execution scope",
                firstFrame: nil,
                backend: node.backendConfig
            )
        }
    }

    @Test @MainActor
    func defaultCanvasStoreRejectsScopedRecoveryAfterSwitchingAwayFromPersistedCanvas() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-default-canvas-switch-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = P3RecoveryProvider()
        let taskStore = VideoTaskStore(directory: directory)
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue,
            title: "旧画布视频",
            backendConfig: NodeBackendConfig(
                providerType: .cloud,
                providerID: provider.providerID,
                modelID: "p3-recovery-model"
            )
        )
        let canvas = CanvasStore(
            graph: NodeGraph(nodes: [node]),
            videoTaskStore: taskStore,
            videoAssetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            videoAssetDownloader: P3CanvasAssetDownloader(),
            videoProviderFactory: { _ in provider },
            artifactStore: ArtifactStore(
                directory: directory.appendingPathComponent("artifacts", isDirectory: true)
            )
        )
        let persistedCanvasID = canvas.currentCanvasID
        let runID = UUID()
        let executionEnvelope = DAGExecutionEnvelope(
            canvasID: persistedCanvasID,
            runID: runID,
            graph: canvas.graph
        )
        let identity = CanvasExecutionIdentity(
            canvasID: executionEnvelope.canvasID,
            runID: executionEnvelope.runID,
            graphRevision: executionEnvelope.graphRevision,
            nodeID: node.id,
            nodeRevision: executionEnvelope.graphRevision
        )
        let snapshot = ProviderSnapshot(
            providerID: provider.providerID,
            modelID: "p3-recovery-model",
            capabilities: [.video],
            configurationFingerprint: MinisCanvasVideoInvoker.configurationFingerprint(
                providerID: provider.providerID,
                modelID: "p3-recovery-model"
            )
        )
        let context = MediaTaskContext(
            envelope: executionEnvelope,
            nodeID: node.id,
            nodeRevision: identity.nodeRevision,
            providerSnapshot: snapshot,
            promptFingerprint: "p3-switch-rejection"
        )
        let queued = taskStore.enqueue(
            nodeID: node.id,
            providerID: provider.providerID,
            promptFingerprint: context.promptFingerprint,
            idempotencyKey: context.idempotencyKey
        )
        #expect(taskStore.markSubmitted(id: queued.id, taskID: "p3-switch-rejection-remote"))
        #expect(taskStore.markPolling(id: queued.id))
        try MediaTaskMetadataStore(directory: directory).bind(
            recordID: queued.id,
            context: context,
            allowLegacyBinding: true
        )

        let switched = canvas.createCanvas(name: "当前画布")
        #expect(switched.id != persistedCanvasID)

        guard let invoker = canvas.context.videoInvoker as? MinisCanvasVideoInvoker else {
            Issue.record("默认 CanvasStore 必须装配生产视频调用器")
            return
        }
        let recovered = try await invoker.recoverPendingTasks()

        #expect(recovered.isEmpty)
        #expect(taskStore.record(id: queued.id)?.status == .polling)
        #expect(await provider.submitCount == 0)
        #expect(await provider.pollCount == 0)
        #expect(await canvas.assetStore.assets(canvasID: persistedCanvasID).isEmpty)
        #expect(await invoker.artifactStore.allReceipts().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("assets", isDirectory: true)
                .appendingPathComponent("\(queued.id).mp4").path
        ))
    }

    @Test @MainActor
    func createCanvasEndsOldExecutionScopeBeforeWriteback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-create-canvas-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = P3CancellableCanvasProvider()
        let taskStore = VideoTaskStore(directory: directory)
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue,
            title: "旧画布视频",
            backendConfig: NodeBackendConfig(
                providerType: .cloud,
                providerID: provider.providerID,
                modelID: "p3-create-model"
            )
        )
        let canvas = CanvasStore(
            graph: NodeGraph(nodes: [node]),
            videoTaskStore: taskStore,
            videoAssetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            videoAssetDownloader: P3CanvasAssetDownloader(),
            videoProviderFactory: { _ in provider },
            artifactStore: ArtifactStore(
                directory: directory.appendingPathComponent("artifacts", isDirectory: true)
            )
        )
        let oldCanvasID = canvas.currentCanvasID
        let runID = UUID()
        let executionEnvelope = DAGExecutionEnvelope(
            canvasID: oldCanvasID,
            runID: runID,
            graph: canvas.graph
        )
        canvas.beginExecutionScopeForTest(
            canvasID: oldCanvasID,
            runID: runID,
            graphRevision: executionEnvelope.graphRevision,
            graphFingerprint: executionEnvelope.graphFingerprint
        )
        guard let invoker = canvas.context.videoInvoker as? MinisCanvasVideoInvoker else {
            Issue.record("默认 CanvasStore 必须装配生产视频调用器")
            return
        }

        // Precondition：旧 scope 有效，在途 submit 被接受。
        let inFlight = Task {
            try? await invoker.generate(
                node: node,
                prompt: "in flight",
                firstFrame: nil,
                backend: node.backendConfig,
                executionEnvelope: executionEnvelope
            )
        }
        await provider.waitUntilSubmitted()
        #expect(await provider.submitStarted)

        canvas.createCanvas(name: "新画布")

        // 放行在途 submit：createCanvas 后旧 scope 必须已失效，写回被拒绝——
        // 旧画布无资产、无收据（与 switchCanvas/deleteCanvas 同一契约）。
        await provider.release()
        _ = await inFlight.value
        #expect(await canvas.assetStore.assets(canvasID: oldCanvasID, includingDeleted: true).isEmpty)
        #expect(await invoker.artifactStore.allReceipts().isEmpty)

        // 新 submit 在 Provider 前 fail-closed：scope 已 end。
        await #expect(throws: VideoTaskExecutionError.self) {
            try await invoker.generate(
                node: node,
                prompt: "after create",
                firstFrame: nil,
                backend: node.backendConfig
            )
        }
    }

    @Test
    func retryVideoWithDeadScopeFailsClosedWithoutAssetOrReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-coordinator-retry-dead-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let identity = CanvasExecutionIdentity(
            canvasID: UUID(),
            runID: UUID(),
            graphRevision: 3,
            nodeID: UUID(),
            nodeRevision: 3
        )
        let snapshot = ProviderSnapshot(
            providerID: "p3-test-video",
            modelID: "p3-model",
            capabilities: [.video],
            configurationFingerprint: MinisCanvasVideoInvoker.configurationFingerprint(
                providerID: "p3-test-video", modelID: "p3-model"
            )
        )
        let context = MediaTaskContext(
            identity: identity,
            providerSnapshot: snapshot,
            promptFingerprint: "p3-retry-dead-scope"
        )
        let taskStore = VideoTaskStore(directory: directory)
        let queued = taskStore.enqueue(
            nodeID: identity.nodeID,
            providerID: snapshot.providerID,
            promptFingerprint: context.promptFingerprint,
            idempotencyKey: context.idempotencyKey
        )
        #expect(taskStore.markCanceled(id: queued.id))
        try MediaTaskMetadataStore(directory: directory).bind(
            recordID: queued.id,
            context: context,
            allowLegacyBinding: true
        )

        let assetStore = CanvasAssetStore()
        let artifactStore = ArtifactStore(
            directory: directory.appendingPathComponent("artifacts", isDirectory: true)
        )
        let executor = VideoTaskExecutor(
            store: taskStore,
            backend: CloudVideoTaskBackend(provider: P3CanvasProvider()),
            assetDownloader: P3CanvasAssetDownloader(),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0,
            pollTimeout: 1
        )
        let coordinator = CanvasTaskCoordinator(
            media: MediaTaskCoordinator(executor: executor),
            assetStore: assetStore,
            artifactStore: artifactStore,
            currentIdentityProvider: { nil }
        )

        do {
            _ = try await coordinator.retryVideo(
                id: queued.id,
                context: context,
                promptFingerprint: context.promptFingerprint,
                request: CloudVideoRequest(prompt: "retry dead scope"),
                currentIdentity: context.identity
            )
            Issue.record("死 scope 下的显式重试必须 fail-closed")
        } catch VideoTaskExecutionError.contextMismatch {
            // expected
        }
        #expect(await assetStore.assets(canvasID: identity.canvasID, includingDeleted: true).isEmpty)
        #expect(await artifactStore.allReceipts().isEmpty)
    }
}

private extension MinisCanvasVideoInvoker {
    func scoped(canvasID: UUID, runID: UUID, graphRevision: Int) -> MinisCanvasVideoInvoker {
        MinisCanvasVideoInvoker(
            taskStore: taskStore,
            assetDirectory: assetDirectory,
            assetDownloader: assetDownloader,
            providerFactory: providerFactory,
            assetStore: assetStore,
            scopeProvider: { node in
                CanvasExecutionIdentity(
                    canvasID: canvasID,
                    runID: runID,
                    graphRevision: graphRevision,
                    nodeID: node.id,
                    nodeRevision: graphRevision
                )
            },
            workerProjectionProvider: { node, provider in
                let identity = CanvasExecutionIdentity(
                    canvasID: canvasID,
                    runID: runID,
                    graphRevision: graphRevision,
                    nodeID: node.id,
                    nodeRevision: graphRevision
                )
                return try? CanvasWorkerProjection(
                    identity: identity,
                    provider: provider,
                    graph: NodeGraph(nodes: [node], revision: graphRevision)
                )
            }
        )
    }
}
