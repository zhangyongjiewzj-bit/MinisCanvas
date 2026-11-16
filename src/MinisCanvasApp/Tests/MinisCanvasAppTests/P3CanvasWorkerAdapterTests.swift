import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

private struct P3WorkerAdapterDownloader: VideoAssetDownloader {
    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try Data("worker-adapter".utf8).write(to: destination, options: .atomic)
        return destination
    }
}

private struct P3WorkerAdapterProvider: CloudVideoGenerator {
    let providerID = "p3-worker-adapter-provider"
    let displayName = "P3 Worker Adapter Provider"
    let isConfigured = true

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        "p3-worker-adapter-remote"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.example/worker-adapter.mp4")
    }
}

private final class P3WorkerProjectionState: @unchecked Sendable {
    private let lock = NSLock()
    private let identityValue: CanvasExecutionIdentity
    private var projectionValue: CanvasWorkerProjection
    private let driftedProjection: CanvasWorkerProjection
    private var identityReads = 0

    init(
        identity: CanvasExecutionIdentity,
        projection: CanvasWorkerProjection,
        driftedProjection: CanvasWorkerProjection
    ) {
        self.identityValue = identity
        self.projectionValue = projection
        self.driftedProjection = driftedProjection
    }

    func identity() -> CanvasExecutionIdentity {
        lock.lock()
        defer { lock.unlock() }
        identityReads += 1
        if identityReads == 3 {
            projectionValue = driftedProjection
        }
        return identityValue
    }

    func projection() -> CanvasWorkerProjection {
        lock.lock()
        defer { lock.unlock() }
        return projectionValue
    }
}

@Suite("P3 Canvas worker adapter")
struct P3CanvasWorkerAdapterTests {
    @Test
    func executionScopePublishesFrozenWorkerProjection() throws {
        let scope = CanvasExecutionScopeBox()
        let canvasID = UUID()
        let runID = UUID()
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "worker")
        let graph = NodeGraph(nodes: [node], revision: 7)
        let provider = ProviderSnapshot(
            providerID: "p3-worker-provider",
            modelID: "p3-worker-model",
            capabilities: [.video],
            configurationFingerprint: "p3-worker-config"
        )

        scope.begin(
            canvasID: canvasID,
            runID: runID,
            graphRevision: graph.revision,
            graphFingerprint: graph.fingerprint
        )

        let projection = try #require(scope.workerProjection(for: node, provider: provider))
        #expect(projection.identity.canvasID == canvasID)
        #expect(projection.identity.runID == runID)
        #expect(projection.identity.nodeID == node.id)
        #expect(projection.graphRevision == graph.revision)
        #expect(projection.graphFingerprint == graph.fingerprint)
        #expect(CanvasWorkerSeam.accept(projection) != .rejected(.invalidIdentity))
    }

    @Test
    func recoveryScopePublishesProjectionFromStoredGraphAndProviderSnapshot() throws {
        let scope = CanvasRecoveryScopeBox()
        let canvasID = UUID()
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue,
            title: "恢复 worker",
            backendConfig: NodeBackendConfig(
                providerType: .cloud,
                providerID: "p3-recovery-worker-provider",
                modelID: "p3-recovery-worker-model"
            )
        )
        let graph = NodeGraph(nodes: [node], revision: 9)
        scope.replace(canvasID: canvasID, graph: graph)
        let identity = CanvasExecutionIdentity(
            canvasID: canvasID,
            runID: UUID(),
            graphRevision: graph.structuralRevision,
            nodeID: node.id,
            nodeRevision: graph.structuralRevision
        )
        let provider = ProviderSnapshot(
            providerID: "p3-recovery-worker-provider",
            modelID: "p3-recovery-worker-model",
            capabilities: [.video],
            configurationFingerprint: MinisCanvasVideoInvoker.configurationFingerprint(
                providerID: "p3-recovery-worker-provider",
                modelID: "p3-recovery-worker-model"
            )
        )
        let context = MediaTaskContext(
            identity: identity,
            providerSnapshot: provider,
            promptFingerprint: "p3-recovery-worker"
        )

        let projection = try #require(scope.workerProjection(for: context))
        #expect(projection.identity == identity)
        #expect(projection.provider == provider)
        #expect(projection.graphFingerprint == graph.fingerprint)
        #expect(CanvasWorkerSeam.accept(projection) != .rejected(.invalidIdentity))
    }

    @Test
    func coordinatorRejectsWorkerGraphDriftBeforeArtifactWriteback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-worker-adapter-drift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "漂移 worker")
        let identity = CanvasExecutionIdentity(
            canvasID: UUID(),
            runID: UUID(),
            graphRevision: 4,
            nodeID: node.id,
            nodeRevision: 4
        )
        let provider = ProviderSnapshot(
            providerID: "p3-worker-adapter-provider",
            modelID: "p3-worker-adapter-model",
            capabilities: [.video],
            configurationFingerprint: "p3-worker-adapter-config"
        )
        let context = MediaTaskContext(
            identity: identity,
            providerSnapshot: provider,
            promptFingerprint: "p3-worker-adapter-drift"
        )
        let frozenProjection = try CanvasWorkerProjection(
            identity: identity,
            provider: provider,
            graphRevision: identity.graphRevision,
            graphFingerprint: "frozen-graph"
        )
        let driftedProjection = try CanvasWorkerProjection(
            identity: identity,
            provider: provider,
            graphRevision: identity.graphRevision,
            graphFingerprint: "drifted-graph"
        )
        let taskStore = VideoTaskStore(directory: directory)
        let artifactStore = ArtifactStore(
            directory: directory.appendingPathComponent("artifacts", isDirectory: true)
        )
        let coordinator = CanvasTaskCoordinator(
            media: MediaTaskCoordinator(executor: VideoTaskExecutor(
                store: taskStore,
                backend: CloudVideoTaskBackend(provider: P3WorkerAdapterProvider()),
                assetDownloader: P3WorkerAdapterDownloader(),
                assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
                pollInterval: 0,
                pollTimeout: 1
            )),
            assetStore: CanvasAssetStore(),
            artifactStore: artifactStore,
            currentIdentityProvider: { identity },
            currentWorkerProjectionProvider: { driftedProjection }
        )

        await #expect(throws: VideoTaskExecutionError.self) {
            try await coordinator.runVideo(
                context: context,
                promptFingerprint: context.promptFingerprint,
                request: CloudVideoRequest(prompt: "drift"),
                currentIdentity: identity,
                workerProjection: frozenProjection
            )
        }
        #expect(await artifactStore.allReceipts().isEmpty)
        #expect(!taskStore.allRecords().isEmpty)
    }

    @Test
    func coordinatorRechecksWorkerGraphBeforeAssetWriteback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-worker-adapter-final-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "最终闸门 worker")
        let identity = CanvasExecutionIdentity(
            canvasID: UUID(),
            runID: UUID(),
            graphRevision: 5,
            nodeID: node.id,
            nodeRevision: 5
        )
        let provider = ProviderSnapshot(
            providerID: "p3-worker-adapter-provider",
            modelID: "p3-worker-adapter-model",
            capabilities: [.video],
            configurationFingerprint: "p3-worker-adapter-config"
        )
        let context = MediaTaskContext(
            identity: identity,
            providerSnapshot: provider,
            promptFingerprint: "p3-worker-adapter-final-gate"
        )
        let frozenProjection = try CanvasWorkerProjection(
            identity: identity,
            provider: provider,
            graphRevision: identity.graphRevision,
            graphFingerprint: "frozen-graph"
        )
        let driftedProjection = try CanvasWorkerProjection(
            identity: identity,
            provider: provider,
            graphRevision: identity.graphRevision,
            graphFingerprint: "drifted-graph"
        )
        let state = P3WorkerProjectionState(
            identity: identity,
            projection: frozenProjection,
            driftedProjection: driftedProjection
        )
        let taskStore = VideoTaskStore(directory: directory)
        let artifactStore = ArtifactStore(
            directory: directory.appendingPathComponent("artifacts", isDirectory: true)
        )
        let assetStore = CanvasAssetStore()
        let coordinator = CanvasTaskCoordinator(
            media: MediaTaskCoordinator(executor: VideoTaskExecutor(
                store: taskStore,
                backend: CloudVideoTaskBackend(provider: P3WorkerAdapterProvider()),
                assetDownloader: P3WorkerAdapterDownloader(),
                assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
                pollInterval: 0,
                pollTimeout: 1
            )),
            assetStore: assetStore,
            artifactStore: artifactStore,
            currentIdentityProvider: { state.identity() },
            currentWorkerProjectionProvider: { state.projection() }
        )

        await #expect(throws: VideoTaskExecutionError.self) {
            try await coordinator.runVideo(
                context: context,
                promptFingerprint: context.promptFingerprint,
                request: CloudVideoRequest(prompt: "final gate"),
                currentIdentity: identity,
                workerProjection: frozenProjection
            )
        }
        #expect(await artifactStore.allReceipts().isEmpty)
        #expect(await assetStore.assets(canvasID: identity.canvasID, includingDeleted: true).isEmpty)
    }
}
