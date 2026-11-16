import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("P3 Canvas scope and artifact transaction")
struct P3CanvasScopeAndArtifactTransactionTests {
    @Test
    func executionScopePublishesTheFrozenDAGEnvelope() {
        let scope = CanvasExecutionScopeBox()
        let envelope = DAGExecutionEnvelope(
            canvasID: UUID(),
            runID: UUID(),
            graphRevision: 3,
            graphFingerprint: "scope-envelope"
        )

        scope.begin(
            canvasID: envelope.canvasID,
            runID: envelope.runID,
            graphRevision: envelope.graphRevision,
            graphFingerprint: envelope.graphFingerprint,
            executionEnvelope: envelope
        )

        #expect(scope.executionEnvelope() == envelope)
        scope.end()
        #expect(scope.executionEnvelope() == nil)
    }

    @Test
    func executionScopeLeaseBlocksEndUntilCommitBodyReturns() throws {
        let scope = CanvasExecutionScopeBox()
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        scope.begin(canvasID: UUID(), runID: UUID(), graphRevision: 1)
        let lease = try #require(scope.executionLease(for: node))
        let commitEntered = DispatchSemaphore(value: 0)
        let endAttempted = DispatchSemaphore(value: 0)
        let releaseBody = DispatchSemaphore(value: 0)
        let commitReturned = DispatchSemaphore(value: 0)
        let endReturned = DispatchSemaphore(value: 0)
        let commitQueue = DispatchQueue(label: "miniscanvas.p3.scope-lease.commit")
        let endQueue = DispatchQueue(label: "miniscanvas.p3.scope-lease.end")

        commitQueue.async {
            scope.withExecutionLease(lease) { _ in
                commitEntered.signal()
                releaseBody.wait()
            }
            commitReturned.signal()
        }
        #expect(commitEntered.wait(timeout: .now() + .seconds(1)) == .success)

        endQueue.async {
            endAttempted.signal()
            scope.end()
            endReturned.signal()
        }
        #expect(endAttempted.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(endReturned.wait(timeout: .now() + .milliseconds(100)) == .timedOut)

        releaseBody.signal()
        #expect(commitReturned.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(endReturned.wait(timeout: .now() + .seconds(1)) == .success)
    }

    @Test
    func executionScopeLeaseRejectsStaleScopeAndCannotBeReused() throws {
        let scope = CanvasExecutionScopeBox()
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        scope.begin(canvasID: UUID(), runID: UUID(), graphRevision: 1)
        let lease = try #require(scope.executionLease(for: node))

        scope.end()
        scope.begin(canvasID: UUID(), runID: UUID(), graphRevision: 2)
        #expect(scope.withExecutionLease(lease) { _ in true } == nil)

        let currentLease = try #require(scope.executionLease(for: node))
        #expect(scope.withExecutionLease(currentLease) { _ in true } == true)
        #expect(scope.withExecutionLease(currentLease) { _ in true } == nil)
    }

    @Test
    func assetWritebackConsumesIdentityBoundLeaseExactlyOnce() async throws {
        let scope = CanvasExecutionScopeBox()
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let canvasID = UUID()
        scope.begin(canvasID: canvasID, runID: UUID(), graphRevision: 1)
        let identity = try #require(scope.identity(for: node))
        let lease = try #require(scope.executionLease(for: node))
        let context = p3ScopeContext(identity: identity, providerID: "p3-lease-provider")
        let record = VideoTaskRecord(
            id: "p3-lease-task",
            nodeID: node.id,
            providerID: context.providerSnapshot.providerID,
            taskID: "p3-lease-remote",
            promptFingerprint: context.promptFingerprint,
            status: .succeeded,
            videoURL: "https://cdn.example/p3-lease.mp4",
            idempotencyKey: context.idempotencyKey
        )
        let assetStore = CanvasAssetStore()

        let first = await assetStore.registerVideoTaskResultAtomically(
            record,
            context: context,
            currentIdentity: identity,
            executionLease: lease
        )
        let second = await assetStore.registerVideoTaskResultAtomically(
            record,
            context: context,
            currentIdentity: identity,
            executionLease: lease
        )

        #expect(first == .accepted)
        #expect(second == .rejected(.identity(.rejected(.graphRevisionMismatch))))
        #expect(await assetStore.assets(canvasID: canvasID).count == 1)
    }

    @Test
    func artifactStoreRejectsMediaContextBoundToAnotherDAGEnvelope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-artifact-envelope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let nodeID = UUID()
        let envelope = DAGExecutionEnvelope(
            canvasID: UUID(),
            runID: UUID(),
            graphRevision: 4,
            graphFingerprint: "artifact-envelope"
        )
        let foreignEnvelope = DAGExecutionEnvelope(
            canvasID: envelope.canvasID,
            runID: envelope.runID,
            graphRevision: envelope.graphRevision,
            graphFingerprint: "foreign-envelope"
        )
        let provider = ProviderSnapshot(
            providerID: "p3-envelope-provider",
            modelID: "p3-envelope-model",
            capabilities: [.video],
            configurationFingerprint: "p3-envelope-config"
        )
        let context = MediaTaskContext(
            envelope: envelope,
            nodeID: nodeID,
            nodeRevision: envelope.graphRevision,
            providerSnapshot: provider,
            promptFingerprint: "p3-envelope-prompt"
        )
        let mediaDirectory = directory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaURL = mediaDirectory.appendingPathComponent("result.mp4")
        try Data("artifact".utf8).write(to: mediaURL)
        let record = VideoTaskRecord(
            id: "p3-envelope-task",
            nodeID: nodeID,
            providerID: provider.providerID,
            taskID: "remote-p3-envelope-task",
            promptFingerprint: context.promptFingerprint,
            status: .succeeded,
            videoURL: "https://cdn.example/p3-envelope.mp4",
            idempotencyKey: context.idempotencyKey,
            assetPath: mediaURL.path
        )
        let store = ArtifactStore(
            directory: directory.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: mediaDirectory
        )

        do {
            _ = try await store.recordMediaCompletionResult(
                record,
                context: context,
                executionEnvelope: foreignEnvelope
            )
            Issue.record("跨 DAG envelope 的 artifact 写回必须被拒绝")
        } catch ArtifactStoreError.invalidPayload {
            // expected
        }
    }

    @Test
    func configuredScopedInvokerFailsClosedWhenIdentityIsMissing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-scope-missing-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let provider = P3IdentityMissingProvider()
        let invoker = MinisCanvasVideoInvoker(
            taskStore: VideoTaskStore(directory: directory),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            assetDownloader: P3ScopeDownloader(),
            providerFactory: { _ in provider },
            assetStore: CanvasAssetStore(),
            scopeProvider: { _ in nil }
        )
        var backend = NodeBackendConfig()
        backend.providerID = provider.providerID

        do {
            _ = try await invoker.generate(
                node: node,
                prompt: "missing identity",
                firstFrame: nil,
                backend: backend
            )
            Issue.record("已配置 scoped wiring 但 identity 缺失时必须 fail-closed")
        } catch VideoTaskExecutionError.contextMismatch {
            // expected
        }
        #expect(await provider.submitCount == 0)
    }

    @Test
    func invalidScopeRejectsBeforeProviderSubmit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-scope-preflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let scope = CanvasExecutionScopeBox()
        let canvasID = UUID()
        let runID = UUID()
        scope.begin(canvasID: canvasID, runID: runID, graphRevision: 2)
        let identity = try #require(scope.identity(for: node))
        scope.end()
        let provider = P3GatedProvider()
        let context = p3ScopeContext(identity: identity, providerID: provider.providerID)
        let executor = VideoTaskExecutor(
            store: VideoTaskStore(directory: directory),
            backend: CloudVideoTaskBackend(provider: provider),
            assetDownloader: P3ScopeDownloader(),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0,
            pollTimeout: 1
        )
        let coordinator = CanvasTaskCoordinator(
            media: MediaTaskCoordinator(executor: executor),
            assetStore: CanvasAssetStore(),
            artifactStore: ArtifactStore(directory: directory.appendingPathComponent("artifacts", isDirectory: true)),
            currentIdentityProvider: { scope.identity(for: node) }
        )

        do {
            _ = try await coordinator.runVideo(
                context: context,
                promptFingerprint: context.promptFingerprint,
                request: CloudVideoRequest(prompt: "preflight"),
                currentIdentity: identity
            )
            Issue.record("失效 scope 必须在 Provider submit 前拒绝")
        } catch VideoTaskExecutionError.contextMismatch {
            // expected
        }
        #expect(await provider.submitCount == 0)
    }

    @Test
    func atomicWritebackMapsMissingIdentityToCanvasDecisionRejection() async throws {
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let identity = CanvasExecutionIdentity(
            canvasID: UUID(),
            runID: UUID(),
            graphRevision: 2,
            nodeID: node.id,
            nodeRevision: 2
        )
        let context = p3ScopeContext(identity: identity, providerID: "p3-missing-current")
        let record = VideoTaskRecord(
            id: "p3-missing-current-task",
            nodeID: node.id,
            providerID: context.providerSnapshot.providerID,
            taskID: "p3-missing-current-remote",
            promptFingerprint: context.promptFingerprint,
            status: .succeeded,
            videoURL: "https://cdn.example/p3-missing-current.mp4",
            idempotencyKey: context.idempotencyKey
        )
        let decision = await CanvasAssetStore().registerVideoTaskResultAtomically(
            record,
            context: context,
            currentIdentity: identity,
            currentIdentityProvider: { nil }
        )

        #expect(
            decision == .rejected(.identity(.rejected(.graphRevisionMismatch)))
        )
    }

    @Test
    func scopeInvalidatedDuringSubmitLeavesNoAssetOrReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-scope-transaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let scope = CanvasExecutionScopeBox()
        let canvasID = UUID()
        let runID = UUID()
        scope.begin(canvasID: canvasID, runID: runID, graphRevision: 2)
        let identity = try #require(scope.identity(for: node))
        let provider = P3GatedProvider()
        let context = p3ScopeContext(identity: identity, providerID: provider.providerID)
        let assetStore = CanvasAssetStore()
        let artifactStore = ArtifactStore(directory: directory.appendingPathComponent("artifacts", isDirectory: true))
        let coordinator = CanvasTaskCoordinator(
            media: MediaTaskCoordinator(executor: VideoTaskExecutor(
                store: VideoTaskStore(directory: directory),
                backend: CloudVideoTaskBackend(provider: provider),
                assetDownloader: P3ScopeDownloader(),
                assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
                pollInterval: 0,
                pollTimeout: 1
            )),
            assetStore: assetStore,
            artifactStore: artifactStore,
            currentIdentityProvider: { scope.identity(for: node) }
        )

        let operation = Task {
            try? await coordinator.runVideo(
                context: context,
                promptFingerprint: context.promptFingerprint,
                request: CloudVideoRequest(prompt: "late"),
                currentIdentity: identity
            )
        }
        // Deterministic latch: wait until the submit is actually in flight,
        // then assert the precondition before invalidating the scope.
        await provider.waitUntilSubmitted()
        #expect(await provider.submitCount == 1)
        scope.end()
        await provider.release()
        _ = await operation.value

        #expect(await assetStore.assets(canvasID: canvasID, includingDeleted: true).isEmpty)
        #expect(await artifactStore.allReceipts().isEmpty)
    }

    @Test
    func scopeInvalidatedAfterFinalIdentityGateDoesNotCommitLateWriteback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-scope-final-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let scope = CanvasExecutionScopeBox()
        let canvasID = UUID()
        let runID = UUID()
        scope.begin(canvasID: canvasID, runID: runID, graphRevision: 2)
        let identity = try #require(scope.identity(for: node))
        let provider = P3IdentityMissingProvider()
        let context = p3ScopeContext(identity: identity, providerID: provider.providerID)
        let assetStore = CanvasAssetStore()
        let artifactStore = ArtifactStore(
            directory: directory.appendingPathComponent("artifacts", isDirectory: true)
        )
        let assetDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        let taskStore = VideoTaskStore(directory: directory)
        let gate = P3InvalidateScopeAfterFinalGate(scope: scope, node: node)
        let coordinator = CanvasTaskCoordinator(
            media: MediaTaskCoordinator(executor: VideoTaskExecutor(
                store: taskStore,
                backend: CloudVideoTaskBackend(provider: provider),
                assetDownloader: P3ScopeDownloader(),
                assetDirectory: assetDirectory,
                pollInterval: 0,
                pollTimeout: 1
            )),
            assetStore: assetStore,
            artifactStore: artifactStore,
            assetPersistenceDirectory: assetDirectory,
            currentIdentityProvider: { gate.currentIdentity() }
        )

        do {
            let result = try await coordinator.runVideo(
                context: context,
                promptFingerprint: context.promptFingerprint,
                request: CloudVideoRequest(prompt: "final gate race"),
                currentIdentity: identity
            )
            #expect(
                result.writeback
                    == .rejected(.identity(.rejected(.graphRevisionMismatch)))
            )
            #expect(result.artifactID == nil)
        } catch VideoTaskExecutionError.contextMismatch {
            Issue.record("最终 identity 门禁失效应返回 rejected writeback，而不是抛出 contextMismatch")
        }

        #expect(await assetStore.assets(canvasID: canvasID, includingDeleted: true).isEmpty)
        #expect(await artifactStore.allReceipts().isEmpty)
        #expect(taskStore.allRecords().first?.assetPath == nil)
        #expect(CanvasAssetStore.loadSnapshot(from: assetDirectory)?.assetsByCanvas[canvasID]?.isEmpty != false)
        let remainingAssetPaths = try? FileManager.default.contentsOfDirectory(
            at: assetDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "mp4" }
        #expect(remainingAssetPaths?.isEmpty == true, "残留下载文件: \(remainingAssetPaths ?? [])")
        #expect(gate.readCount == 3)
    }
}

private func p3ScopeContext(identity: CanvasExecutionIdentity, providerID: String) -> MediaTaskContext {
    MediaTaskContext(
        identity: identity,
        providerSnapshot: ProviderSnapshot(
            providerID: providerID,
            modelID: "p3-scope-model",
            capabilities: [.video],
            configurationFingerprint: "p3-scope-config"
        ),
        promptFingerprint: "p3-scope-prompt"
    )
}

private actor P3GatedProvider: CloudVideoGenerator {
    let providerID = "p3-gated-provider"
    let displayName = "P3 Gated Provider"
    let isConfigured = true
    private(set) var submitCount = 0
    private var released = false
    private var submitWaiters: [CheckedContinuation<Void, Never>] = []

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitCount += 1
        let waiters = submitWaiters
        submitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        while !released { await Task.yield() }
        return "p3-gated-remote"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.example/p3-gated.mp4")
    }

    func release() {
        released = true
    }

    /// Deterministic latch: suspends until the first submitVideo has been
    /// entered, then returns. Replaces the previous wall-clock polling loop.
    func waitUntilSubmitted() async {
        if submitCount > 0 { return }
        await withCheckedContinuation { continuation in
            submitWaiters.append(continuation)
        }
    }
}

private actor P3IdentityMissingProvider: CloudVideoGenerator {
    let providerID = "p3-missing-identity-provider"
    let displayName = "P3 Missing Identity Provider"
    let isConfigured = true
    private(set) var submitCount = 0

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitCount += 1
        return "p3-missing-identity-remote"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.example/p3-missing-identity.mp4")
    }
}

private final class P3InvalidateScopeAfterFinalGate: @unchecked Sendable {
    private let scope: CanvasExecutionScopeBox
    private let node: CanvasNode
    private let lock = NSLock()
    private var reads = 0

    init(
        scope: CanvasExecutionScopeBox,
        node: CanvasNode
    ) {
        self.scope = scope
        self.node = node
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func currentIdentity() -> CanvasExecutionIdentity? {
        lock.lock()
        reads += 1
        let read = reads
        lock.unlock()
        if read == 3 {
            scope.end()
            return nil
        }
        return scope.identity(for: node)
    }
}

private struct P3ScopeDownloader: VideoAssetDownloader {
    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try Data("scope-video".utf8).write(to: destination, options: .atomic)
        return destination
    }
}
