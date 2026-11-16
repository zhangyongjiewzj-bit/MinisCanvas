import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

private actor VideoTaskControlProvider: CloudVideoGenerator {
    let providerID = "control-provider"
    let displayName = "Control Provider"
    let isConfigured = true
    private var pollResults: [CloudTaskState]
    private(set) var submitCount = 0
    private(set) var pollCount = 0
    private(set) var submitStarted = false
    private var releaseSubmit = false

    init(pollResults: [CloudTaskState]) {
        self.pollResults = pollResults
    }

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitCount += 1
        submitStarted = true
        while !releaseSubmit {
            await Task.yield()
        }
        return "remote-control"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        pollCount += 1
        if pollResults.count > 1 {
            return pollResults.removeFirst()
        }
        return pollResults.first ?? CloudTaskState(phase: .succeeded, videoURL: "https://cdn.test/control.mp4")
    }

    func allowSubmitToReturn() {
        releaseSubmit = true
    }
}

private struct VideoTaskControlAssetProbe: VideoAssetDownloader {
    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try Data("video".utf8).write(to: destination, options: .atomic)
        return destination
    }
}

@Suite("视频任务可见控制与恢复契约")
struct VideoTaskControlTests {
    private func makeDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func requestSnapshotSurvivesStoreReloadForRetry() throws {
        let directory = try makeDirectory("video-request-snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = CloudVideoRequest(
            prompt: "持久化重试请求",
            imageURL: "https://cdn.test/reference.png",
            aspectRatio: "16:9",
            duration: "5",
            modelOverride: "control-v1",
            extraParams: ["mode": "t2v"]
        )
        let store = VideoTaskStore(directory: directory)
        let record = store.resumeOrCreate(
            nodeID: UUID(),
            providerID: "control-provider",
            promptFingerprint: "full-fingerprint",
            requestSnapshot: VideoTaskRequestSnapshot(request)
        )

        let reloaded = try #require(VideoTaskStore(directory: directory).record(id: record.id))
        #expect(reloaded.requestSnapshot?.request == request)
    }

    @Test func cancelTaskUsesTheInvokerExecutorOperation() async throws {
        let directory = try makeDirectory("video-control-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = VideoTaskControlProvider(pollResults: [])
        let store = VideoTaskStore(directory: directory)
        let invoker = MinisCanvasVideoInvoker(
            taskStore: store,
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            assetDownloader: VideoTaskControlAssetProbe(),
            providerFactory: { _ in provider }
        )
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "可取消视频")
        var backend = NodeBackendConfig()
        backend.providerID = "control-provider"

        let operation = Task {
            try? await invoker.generate(
                node: node,
                prompt: "取消共享执行器",
                firstFrame: nil,
                backend: backend
            )
        }
        for _ in 0..<2_000 where await provider.submitStarted == false {
            try await Task.sleep(for: .milliseconds(1))
        }
        let record = try #require(store.allRecords().first)
        #expect(await invoker.cancelTask(idempotencyKey: record.idempotencyKey))
        await provider.allowSubmitToReturn()
        _ = await operation.value

        #expect(store.record(id: record.id)?.status == .canceled)
    }

    @Test func recoverPendingTasksRoutesByPersistedProvider() async throws {
        let directory = try makeDirectory("video-control-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoTaskStore(directory: directory)
        let queued = store.enqueue(
            nodeID: UUID(),
            providerID: "control-provider",
            promptFingerprint: "recover-fingerprint"
        )
        #expect(store.markSubmitted(id: queued.id, taskID: "remote-control"))
        #expect(store.markPolling(id: queued.id))

        let provider = VideoTaskControlProvider(
            pollResults: [CloudTaskState(phase: .succeeded, videoURL: "https://cdn.test/recovered.mp4")]
        )
        let invoker = MinisCanvasVideoInvoker(
            taskStore: VideoTaskStore(directory: directory),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            assetDownloader: VideoTaskControlAssetProbe(),
            providerFactory: { _ in provider }
        )

        let recovered = try await invoker.recoverPendingTasks()
        #expect(recovered.count == 1)
        #expect(recovered[0].status == .succeeded)
        #expect(await provider.submitCount == 0)
        #expect(await provider.pollCount == 1)
    }

    @Test func whitespaceRemoteTaskIDIsNotEligibleForRecoveryPolling() throws {
        let directory = try makeDirectory("video-control-whitespace-task-id")
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = """
        [{"id":"whitespace","nodeID":"\(UUID().uuidString)","providerID":"control-provider","taskID":"  \\n\\t ","promptFingerprint":"recover-fingerprint","status":"submitted","videoURL":null,"errorMessage":null,"createdAt":"2026-08-13T00:00:00Z","updatedAt":"2026-08-13T00:00:00Z"}]
        """
        try Data(legacy.utf8).write(
            to: directory.appendingPathComponent(VideoTaskStore.fileName),
            options: .atomic
        )

        let store = VideoTaskStore(directory: directory)
        #expect(store.pendingTasks().count == 1)
        #expect(store.recoverableTasks().isEmpty)
    }
}
