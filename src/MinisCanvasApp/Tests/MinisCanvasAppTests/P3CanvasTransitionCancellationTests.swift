import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

private struct P3TransitionAssetDownloader: VideoAssetDownloader {
    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try Data("transition-video".utf8).write(to: destination, options: .atomic)
        return destination
    }
}

private actor P3TransitionBlockedProvider: CloudVideoGenerator {
    let providerID = "p3-transition-video"
    let displayName = "P3 Transition Video"
    let isConfigured = true

    private var submitStarted = false
    private var released = false
    private var submitWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitStarted = true
        let waiters = submitWaiters
        submitWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        return "p3-transition-remote"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(
            phase: .succeeded,
            videoURL: "https://cdn.example/p3-transition.mp4"
        )
    }

    func release() {
        guard !released else { return }
        released = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        waiter?.resume()
    }

    func waitUntilSubmitted() async {
        if submitStarted {
            return
        }
        await withCheckedContinuation { continuation in
            submitWaiters.append(continuation)
        }
    }
}

@Suite("P3 Canvas transition cancellation")
struct P3CanvasTransitionCancellationTests {
    @Test @MainActor
    func createCanvasCancelsInFlightVideoBeforeProviderRelease() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let operation = try await startInFlight(fixture)

        let created = fixture.canvas.createCanvas(name: "新画布")
        #expect(created.id == fixture.canvas.currentCanvasID)
        #expect(await waitForCanceled(fixture.taskStore, id: operation.recordID))

        await fixture.provider.release()
        _ = await operation.task.value
    }

    @Test @MainActor
    func switchCanvasCancelsInFlightVideoBeforeProviderRelease() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let otherCanvasID = fixture.canvas.createCanvas(name: "另一画布").id
        #expect(fixture.canvas.switchCanvas(to: fixture.canvasID))
        rearmExecutionScope(fixture)
        let operation = try await startInFlight(fixture)

        #expect(fixture.canvas.switchCanvas(to: otherCanvasID))
        #expect(await waitForCanceled(fixture.taskStore, id: operation.recordID))

        await fixture.provider.release()
        _ = await operation.task.value
    }

    @Test @MainActor
    func deleteCanvasCancelsInFlightVideoBeforeProviderRelease() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let otherCanvasID = fixture.canvas.createCanvas(name: "另一画布").id
        #expect(fixture.canvas.switchCanvas(to: fixture.canvasID))
        rearmExecutionScope(fixture)
        let operation = try await startInFlight(fixture)

        #expect(fixture.canvas.deleteCanvas(id: fixture.canvasID))
        #expect(fixture.canvas.currentCanvasID == otherCanvasID)
        #expect(await waitForCanceled(fixture.taskStore, id: operation.recordID))

        await fixture.provider.release()
        _ = await operation.task.value
    }

    @MainActor
    private func makeFixture() throws -> TransitionFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "p3-canvas-transition-cancel-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var directoryOwnershipTransferred = false
        defer {
            if !directoryOwnershipTransferred {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let provider = P3TransitionBlockedProvider()
        let taskStore = VideoTaskStore(directory: directory)
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue,
            title: "在途视频",
            backendConfig: NodeBackendConfig(
                providerType: .cloud,
                providerID: provider.providerID,
                modelID: "p3-transition-model"
            )
        )
        let graph = NodeGraph(nodes: [node])
        let canvas = CanvasStore(
            graph: graph,
            videoTaskStore: taskStore,
            videoAssetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            videoAssetDownloader: P3TransitionAssetDownloader(),
            videoProviderFactory: { _ in provider },
            artifactStore: ArtifactStore(
                directory: directory.appendingPathComponent("artifacts", isDirectory: true)
            )
        )
        let canvasID = canvas.currentCanvasID
        let runID = UUID()
        let envelope = DAGExecutionEnvelope(
            canvasID: canvasID,
            runID: runID,
            graph: graph
        )
        canvas.beginExecutionScopeForTest(
            canvasID: canvasID,
            runID: runID,
            graphRevision: envelope.graphRevision,
            graphFingerprint: envelope.graphFingerprint
        )
        canvas.injectRunEnvelopeForTest(
            RunEnvelope(
                runID: runID,
                canvasID: canvasID,
                graphRevision: envelope.graphRevision,
                executionEnvelope: envelope
            )
        )
        guard canvas.context.videoInvoker is MinisCanvasVideoInvoker else {
            throw TestFailure("CanvasStore must use MinisCanvasVideoInvoker")
        }
        let fixture = TransitionFixture(
            directory: directory,
            canvas: canvas,
            canvasID: canvasID,
            node: node,
            provider: provider,
            taskStore: taskStore,
            envelope: envelope
        )
        directoryOwnershipTransferred = true
        return fixture
    }

    @MainActor
    private func startInFlight(
        _ fixture: TransitionFixture
    ) async throws -> InFlightOperation {
        guard let invoker = fixture.canvas.context.videoInvoker as? MinisCanvasVideoInvoker else {
            throw TestFailure("CanvasStore must use MinisCanvasVideoInvoker")
        }
        let task = Task {
            try? await invoker.generate(
                node: fixture.node,
                prompt: "边界切换期间的视频",
                firstFrame: nil,
                backend: fixture.node.backendConfig,
                executionEnvelope: fixture.envelope
            )
        }
        await fixture.provider.waitUntilSubmitted()
        guard let record = fixture.taskStore.allRecords().first else {
            throw TestFailure("in-flight video task record was not persisted")
        }
        return InFlightOperation(task: task, recordID: record.id)
    }

    @MainActor
    private func rearmExecutionScope(_ fixture: TransitionFixture) {
        fixture.canvas.beginExecutionScopeForTest(
            canvasID: fixture.canvasID,
            runID: fixture.envelope.runID,
            graphRevision: fixture.envelope.graphRevision,
            graphFingerprint: fixture.envelope.graphFingerprint
        )
        fixture.canvas.injectRunEnvelopeForTest(
            RunEnvelope(
                runID: fixture.envelope.runID,
                canvasID: fixture.canvasID,
                graphRevision: fixture.envelope.graphRevision,
                executionEnvelope: fixture.envelope
            )
        )
    }

    private func waitForCanceled(_ store: VideoTaskStore, id: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while clock.now < deadline {
            if store.record(id: id)?.status == .canceled {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return store.record(id: id)?.status == .canceled
    }
}

private struct TransitionFixture {
    let directory: URL
    let canvas: CanvasStore
    let canvasID: UUID
    let node: CanvasNode
    let provider: P3TransitionBlockedProvider
    let taskStore: VideoTaskStore
    let envelope: DAGExecutionEnvelope
}

private struct InFlightOperation {
    let task: Task<VideoGenerationOutcome?, Never>
    let recordID: String
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
