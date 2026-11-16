import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("R36 A7 Chat/Canvas zero mutation and late writeback")
struct R36A7ChatCanvasZeroMutationTests {
    @Test("ordinary Chat sendDraft has zero Canvas target calls at current SHA")
    @MainActor
    func ordinaryChatSendDraftDoesNotCallCanvasTarget() async throws {
        let target = R36A7CanvasMutationTargetSpy()
        let bridge = BridgeStore(
            canvas: CanvasStore(),
            canvasMutationCoordinator: R36A7TestFixtures.makeMutationCoordinator(target: target)
        )
        bridge.chat.agentEngine = ComposerSnapshotMockChatEngine()
        bridge.chat.streamingProviderOverride = MockProvider.shared
        bridge.chat.draftText = "普通聊天回答，不要修改画布。"

        bridge.chat.sendDraft()
        let deadline = Date().addingTimeInterval(15)
        while bridge.chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(bridge.chat.isStreaming == false)
        #expect(bridge.chat.messages.last?.role == .assistant)
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(target.totalMutationCalls == 0)
    }

    @Test("Canvas session switch rejects the old run before a provider call")
    func canvasSessionSwitchRejectsOldIdentityBeforeSubmit() async throws {
        let directory = try R36A7TestFixtures.directory("session-switch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "session switch")
        let firstCanvasID = UUID()
        let firstRunID = UUID()
        let scope = CanvasExecutionScopeBox()
        scope.begin(canvasID: firstCanvasID, runID: firstRunID, graphRevision: 3)
        let oldIdentity = try #require(scope.identity(for: node))

        let provider = R36A7CountingProvider()
        let coordinator = R36A7TestFixtures.makeCoordinator(
            directory: directory,
            provider: provider,
            identityProvider: { scope.identity(for: node) }
        )
        scope.begin(canvasID: UUID(), runID: UUID(), graphRevision: 3)

        do {
            _ = try await coordinator.runVideo(
                context: R36A7TestFixtures.context(identity: oldIdentity, providerID: provider.providerID),
                promptFingerprint: "session-switch",
                request: CloudVideoRequest(prompt: "must not submit"),
                currentIdentity: oldIdentity
            )
            Issue.record("切换 Canvas/session 后，旧任务必须在 Provider 前拒绝")
        } catch VideoTaskExecutionError.contextMismatch {
            // expected
        }
        #expect(await provider.submitCount == 0)
    }

    @Test("graph revision drift leaves no Canvas asset or artifact receipt")
    func graphRevisionDriftRollsBackLateWriteback() async throws {
        let directory = try R36A7TestFixtures.directory("graph-drift")
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "graph drift")
        let canvasID = UUID()
        let runID = UUID()
        let scope = CanvasExecutionScopeBox()
        scope.begin(canvasID: canvasID, runID: runID, graphRevision: 4)
        let identity = try #require(scope.identity(for: node))
        let provider = R36A7CountingProvider()
        let assetStore = CanvasAssetStore()
        let artifactStore = ArtifactStore(
            directory: directory.appendingPathComponent("artifacts", isDirectory: true)
        )
        let staleIdentity = CanvasExecutionIdentity(
            canvasID: canvasID,
            runID: runID,
            graphRevision: 5,
            nodeID: node.id,
            nodeRevision: 5
        )
        let identityProvider = R36A7DriftingIdentity(
            initial: identity,
            drifted: staleIdentity
        )
        let coordinator = R36A7TestFixtures.makeCoordinator(
            directory: directory,
            provider: provider,
            assetStore: assetStore,
            artifactStore: artifactStore,
            identityProvider: { identityProvider.current() }
        )

        do {
            _ = try await coordinator.runVideo(
                context: R36A7TestFixtures.context(identity: identity, providerID: provider.providerID),
                promptFingerprint: "graph-drift",
                request: CloudVideoRequest(prompt: "late graph result"),
                currentIdentity: identity
            )
            Issue.record("Provider 返回后 graph revision 漂移必须拒绝")
        } catch VideoTaskExecutionError.contextMismatch {
            // expected: the second identity read is the final writeback gate.
        }

        // The coordinator rejects the graph revision before it can reach the
        // provider, so this negative path is zero-call as well as zero-receipt.
        #expect(await provider.submitCount == 0)
        #expect(await assetStore.assets(canvasID: canvasID, includingDeleted: true).isEmpty)
        #expect(await artifactStore.allReceipts().isEmpty)
    }

    @Test("recovery with a stale graph revision creates no asset or receipt")
    func staleRecoveryDoesNotWriteArtifactReceipt() async throws {
        let directory = try R36A7TestFixtures.directory("stale-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeID = UUID()
        let identity = CanvasExecutionIdentity(
            canvasID: UUID(),
            runID: UUID(),
            graphRevision: 6,
            nodeID: nodeID,
            nodeRevision: 6
        )
        let provider = R36A7CountingProvider()
        let context = R36A7TestFixtures.context(identity: identity, providerID: provider.providerID)
        let taskStore = VideoTaskStore(directory: directory)
        let queued = taskStore.enqueue(
            nodeID: nodeID,
            providerID: provider.providerID,
            promptFingerprint: context.promptFingerprint,
            idempotencyKey: context.idempotencyKey
        )
        #expect(taskStore.markSubmitted(id: queued.id, taskID: "r36-a7-recovery-task"))
        #expect(taskStore.markPolling(id: queued.id))
        try MediaTaskMetadataStore(directory: directory).bind(
            recordID: queued.id,
            context: context,
            allowLegacyBinding: true
        )

        let staleIdentity = CanvasExecutionIdentity(
            canvasID: identity.canvasID,
            runID: identity.runID,
            graphRevision: identity.graphRevision + 1,
            nodeID: identity.nodeID,
            nodeRevision: identity.nodeRevision
        )
        let assetStore = CanvasAssetStore()
        let artifactStore = ArtifactStore(
            directory: directory.appendingPathComponent("artifacts", isDirectory: true)
        )
        let coordinator = R36A7TestFixtures.makeCoordinator(
            directory: directory,
            provider: provider,
            assetStore: assetStore,
            artifactStore: artifactStore,
            identityProvider: { staleIdentity }
        )

        do {
            _ = try await coordinator.recoverVideo(
                id: queued.id,
                context: context,
                currentIdentity: identity
            )
            Issue.record("恢复时 graph revision 漂移必须拒绝")
        } catch VideoTaskExecutionError.contextMismatch {
            // expected
        }
        #expect(await provider.pollCount == 1)
        #expect(await assetStore.assets(canvasID: identity.canvasID, includingDeleted: true).isEmpty)
        #expect(await artifactStore.allReceipts().isEmpty)
    }
}

private enum R36A7TestFixtures {
    static func directory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("r36-a7-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func context(
        identity: CanvasExecutionIdentity,
        providerID: String
    ) -> MediaTaskContext {
        MediaTaskContext(
            identity: identity,
            providerSnapshot: ProviderSnapshot(
                providerID: providerID,
                modelID: "r36-a7-model",
                capabilities: [.video],
                configurationFingerprint: "r36-a7-provider-config"
            ),
            promptFingerprint: "r36-a7-prompt"
        )
    }

    static func makeCoordinator(
        directory: URL,
        provider: any CloudVideoGenerator,
        assetStore: CanvasAssetStore = CanvasAssetStore(),
        artifactStore: ArtifactStore? = nil,
        identityProvider: (@Sendable () -> CanvasExecutionIdentity?)? = nil
    ) -> CanvasTaskCoordinator {
        let artifactStore = artifactStore ?? ArtifactStore(
            directory: directory.appendingPathComponent("artifacts", isDirectory: true)
        )
        let executor = VideoTaskExecutor(
            store: VideoTaskStore(directory: directory),
            backend: CloudVideoTaskBackend(provider: provider),
            assetDownloader: R36A7Downloader(),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0,
            pollTimeout: 1
        )
        return CanvasTaskCoordinator(
            media: MediaTaskCoordinator(executor: executor),
            assetStore: assetStore,
            artifactStore: artifactStore,
            currentIdentityProvider: identityProvider
        )
    }

    @MainActor
    static func makeMutationCoordinator(
        target: any CanvasMutationTarget
    ) -> CanvasMutationCoordinator {
        CanvasMutationCoordinator(
            target: target,
            facts: ComposerPolicyFactSource(
                knownCapabilities: [],
                grantedCapabilities: [],
                allowedWriteRoots: [],
                workspaceID: "r36-a7-chat",
                revision: "r36-a7-revision",
                grantEpoch: "r36-a7-epoch",
                leaseID: "r36-a7-lease",
                expiresAt: Date().addingTimeInterval(60),
                revoked: false
            )
        )
    }
}

private struct R36A7Downloader: VideoAssetDownloader {
    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try Data("r36-a7-video".utf8).write(to: destination, options: .atomic)
        return destination
    }
}

private actor R36A7CountingProvider: CloudVideoGenerator {
    let providerID = "r36-a7-provider"
    let displayName = "R36 A7 Provider"
    let isConfigured = true
    private(set) var submitCount = 0
    private(set) var pollCount = 0

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitCount += 1
        return "r36-a7-remote"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        pollCount += 1
        return CloudTaskState(phase: .succeeded, videoURL: "https://cdn.example/r36-a7.mp4")
    }
}

private final class R36A7DriftingIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private let initial: CanvasExecutionIdentity
    private let drifted: CanvasExecutionIdentity
    private var reads = 0

    init(initial: CanvasExecutionIdentity, drifted: CanvasExecutionIdentity) {
        self.initial = initial
        self.drifted = drifted
    }

    func current() -> CanvasExecutionIdentity {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return reads == 3 ? drifted : initial
    }
}

@MainActor
private final class R36A7CanvasMutationTargetSpy: CanvasMutationTarget {
    var currentCanvasID = UUID()
    var graph = NodeGraph()
    var totalMutationCalls = 0

    @discardableResult
    func addNode(ofType _: String, at _: Point?) -> CanvasNode? {
        totalMutationCalls += 1
        return nil
    }

    func runGraph(from _: Set<UUID>?) { totalMutationCalls += 1 }
    func autoLayout() { totalMutationCalls += 1 }
    func resetStatuses() { totalMutationCalls += 1 }

    @discardableResult
    func deleteCanvas(id _: UUID) -> Bool {
        totalMutationCalls += 1
        return true
    }

    func removeNode(id _: UUID) { totalMutationCalls += 1 }

    @discardableResult
    func updateNodeContent(_: String, for _: UUID) -> Bool {
        totalMutationCalls += 1
        return true
    }
}
