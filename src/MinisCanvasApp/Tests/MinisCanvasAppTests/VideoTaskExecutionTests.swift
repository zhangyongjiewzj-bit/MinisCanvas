import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

private actor VideoBackendProbe: VideoTaskBackend {
    let providerID = "test-video"
    let displayName = "Test Video"
    let isConfigured = true
    var submitCount = 0
    var pollCount = 0
    var cancelCount = 0
    var states: [CloudTaskState]
    let cancellationOutcome: CloudVideoCancellationOutcome
    let cancellationShouldThrow: Bool

    init(
        states: [CloudTaskState],
        cancellationOutcome: CloudVideoCancellationOutcome = .unsupported,
        cancellationShouldThrow: Bool = false
    ) {
        self.states = states
        self.cancellationOutcome = cancellationOutcome
        self.cancellationShouldThrow = cancellationShouldThrow
    }

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitCount += 1
        return "remote-1"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        pollCount += 1
        return states.isEmpty
            ? CloudTaskState(phase: .succeeded, videoURL: "https://cdn.test/video.mp4")
            : states.removeFirst()
    }

    func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome {
        cancelCount += 1
        if cancellationShouldThrow {
            throw URLError(.cannotConnectToHost)
        }
        return cancellationOutcome
    }
}

private actor BlockingSubmitVideoBackend: VideoTaskBackend {
    private(set) var submitStarted = false
    private var submitWaiter: CheckedContinuation<String, Never>?
    private(set) var cancelIDs: [String] = []

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        submitStarted = true
        return await withCheckedContinuation { continuation in
            submitWaiter = continuation
        }
    }

    func releaseSubmit(taskID: String = "remote-race") {
        submitWaiter?.resume(returning: taskID)
        submitWaiter = nil
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .succeeded, videoURL: "https://cdn.test/race.mp4")
    }

    func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome {
        cancelIDs.append(taskID)
        return .accepted
    }
}

private actor BlockingCancellationBackend: VideoTaskBackend {
    private(set) var cancelStarted = false
    private var cancelWaiter: CheckedContinuation<CloudVideoCancellationOutcome, Never>?

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        "remote-cancel-race"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .running)
    }

    func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome {
        cancelStarted = true
        return await withCheckedContinuation { continuation in
            cancelWaiter = continuation
        }
    }

    func releaseCancellation(
        outcome: CloudVideoCancellationOutcome = .accepted
    ) {
        cancelWaiter?.resume(returning: outcome)
        cancelWaiter = nil
    }
}

private actor CloudVideoProviderCancellationProbe: CloudVideoGenerator {
    let providerID = "cloud-video-cancel-probe"
    let displayName = "Cloud Video Cancel Probe"
    let isConfigured = true
    private(set) var cancelIDs: [String] = []

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        "remote-cancel"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        CloudTaskState(phase: .running)
    }

    func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome {
        cancelIDs.append(taskID)
        return .accepted
    }
}

private struct VideoAssetProbe: VideoAssetDownloader {
    let data: Data

    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4")
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

@Suite("视频任务执行层")
struct VideoTaskExecutionTests {
    private func makeDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func submitPollDownloadIsIdempotentAndPersistsAsset() async throws {
        let directory = try makeDirectory("video-executor")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoTaskStore(directory: directory)
        let backend = VideoBackendProbe(states: [
            CloudTaskState(phase: .running),
            CloudTaskState(phase: .succeeded, videoURL: "https://cdn.test/video.mp4")
        ])
        let executor = VideoTaskExecutor(
            store: store,
            backend: backend,
            assetDownloader: VideoAssetProbe(data: Data("video".utf8)),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0
        )
        let request = VideoTaskExecutionRequest(
            nodeID: UUID(),
            providerID: "test-video",
            promptFingerprint: "prompt-1",
            request: CloudVideoRequest(prompt: "测试")
        )

        let first = try await executor.start(request)
        let second = try await executor.start(request)
        let submitCount = await backend.submitCount
        let assetPath = try #require(first.assetPath)

        #expect(first.status == .succeeded)
        #expect(second.id == first.id)
        #expect(submitCount == 1)
        #expect(FileManager.default.fileExists(atPath: assetPath))
    }

    @Test func cancelStopsPollingAndMarksTaskCanceled() async throws {
        let directory = try makeDirectory("video-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoTaskStore(directory: directory)
        let backend = VideoBackendProbe(states: [
            CloudTaskState(phase: .running),
            CloudTaskState(phase: .running),
            CloudTaskState(phase: .succeeded, videoURL: "https://cdn.test/video.mp4")
        ])
        let executor = VideoTaskExecutor(
            store: store,
            backend: backend,
            assetDownloader: VideoAssetProbe(data: Data("video".utf8)),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0.05
        )
        let request = VideoTaskExecutionRequest(
            nodeID: UUID(),
            providerID: "test-video",
            promptFingerprint: "prompt-cancel",
            request: CloudVideoRequest(prompt: "取消")
        )

        let operation = Task { try await executor.start(request) }
        let pollingDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await backend.pollCount == 0, ContinuousClock.now < pollingDeadline {
            await Task.yield()
        }
        let pollingStarted = await backend.pollCount > 0
        if !pollingStarted {
            operation.cancel()
            _ = await operation.result
        }
        try #require(pollingStarted, "Cancellation requires the real backend polling phase to have started")
        let canceled = await executor.cancel(idempotencyKey: request.idempotencyKey)
        _ = await operation.result
        let record = try #require(store.activeTask(nodeID: request.nodeID, promptFingerprint: request.promptFingerprint) ?? store.allRecords().first)
        let pollCount = await backend.pollCount
        let cancelCount = await backend.cancelCount

        #expect(canceled)
        #expect(record.status == .canceled)
        #expect(record.remoteCancellationState == .unsupported)
        #expect(pollCount <= 2)
        #expect(cancelCount == 1)
    }

    @Test func restartRecoveryPollsPersistedRemoteTaskWithoutResubmitting() async throws {
        let directory = try makeDirectory("video-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeID = UUID()
        let store = VideoTaskStore(directory: directory)
        let queued = store.enqueue(
            nodeID: nodeID,
            providerID: "test-video",
            promptFingerprint: "prompt-recover"
        )
        #expect(store.markSubmitted(id: queued.id, taskID: "remote-restored"))
        #expect(store.markPolling(id: queued.id))

        let backend = VideoBackendProbe(states: [
            CloudTaskState(phase: .succeeded, videoURL: "https://cdn.test/restored.mp4")
        ])
        let executor = VideoTaskExecutor(
            store: VideoTaskStore(directory: directory),
            backend: backend,
            assetDownloader: VideoAssetProbe(data: Data("restored".utf8)),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0
        )

        let recovered = try await executor.recoverPending()
        let submitCount = await backend.submitCount

        #expect(recovered.count == 1)
        #expect(recovered[0].status == .succeeded)
        #expect(recovered[0].taskID == "remote-restored")
        #expect(submitCount == 0)
    }

    @Test func cancelDuringSubmitCancelsRemoteTaskAfterSubmitReturns() async throws {
        let directory = try makeDirectory("video-cancel-submit-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoTaskStore(directory: directory)
        let backend = BlockingSubmitVideoBackend()
        let executor = VideoTaskExecutor(
            store: store,
            backend: backend,
            assetDownloader: VideoAssetProbe(data: Data("video".utf8)),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0
        )
        let request = VideoTaskExecutionRequest(
            nodeID: UUID(),
            providerID: "test-video",
            promptFingerprint: "prompt-cancel-submit-race",
            request: CloudVideoRequest(prompt: "提交竞态取消")
        )

        let operation = Task { try await executor.start(request) }
        for _ in 0..<2_000 where await backend.submitStarted == false {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await backend.submitStarted, "测试后端必须已经进入 submit 挂起点")

        #expect(await executor.cancel(idempotencyKey: request.idempotencyKey))
        await backend.releaseSubmit()
        _ = await operation.result

        #expect(await backend.cancelIDs == ["remote-race"])
        #expect(store.allRecords().first?.status == .canceled)
        #expect(store.allRecords().first?.remoteCancellationState == .accepted)
    }

    @Test func cancelTasksCallsCloudProviderAndPersistsCanceledRecord() async throws {
        let directory = try makeDirectory("video-provider-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoTaskStore(directory: directory)
        let provider = CloudVideoProviderCancellationProbe()
        let providerID = provider.providerID
        let record = store.enqueue(
            nodeID: UUID(),
            providerID: providerID,
            promptFingerprint: "provider-cancel"
        )
        #expect(store.markSubmitted(id: record.id, taskID: "remote-cancel"))
        #expect(store.markPolling(id: record.id))

        let context = MediaTaskContext(
            identity: CanvasExecutionIdentity(
                canvasID: UUID(),
                runID: UUID(),
                graphRevision: 1,
                nodeID: record.nodeID,
                nodeRevision: 1
            ),
            providerSnapshot: ProviderSnapshot(
                providerID: providerID,
                modelID: "cancel-model",
                capabilities: [.video],
                configurationFingerprint: "cancel-config"
            ),
            promptFingerprint: record.promptFingerprint,
            idempotencyKey: record.idempotencyKey
        )
        try MediaTaskMetadataStore(directory: directory).bind(
            recordID: record.id,
            context: context,
            allowLegacyBinding: true
        )
        let executor = VideoTaskExecutor(
            store: store,
            backend: CloudVideoTaskBackend(provider: provider),
            assetDownloader: VideoAssetProbe(data: Data("video".utf8)),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0
        )

        #expect(await executor.cancelTasks(runID: context.identity.runID))
        #expect(await provider.cancelIDs == ["remote-cancel"])
        #expect(store.record(id: record.id)?.status == .canceled)
        #expect(store.record(id: record.id)?.remoteCancellationState == .accepted)
    }

    @Test func cancelWithoutRemoteTaskIDKeepsNotRequestedState() async throws {
        let directory = try makeDirectory("video-cancel-local-only")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoTaskStore(directory: directory)
        let backend = VideoBackendProbe(states: [])
        let executor = VideoTaskExecutor(
            store: store,
            backend: backend,
            assetDownloader: VideoAssetProbe(data: Data("video".utf8)),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0
        )
        let request = VideoTaskExecutionRequest(
            nodeID: UUID(),
            providerID: "test-video",
            promptFingerprint: "local-only-cancel",
            request: CloudVideoRequest(prompt: "本地取消")
        )
        let record = store.enqueue(
            nodeID: request.nodeID,
            providerID: request.providerID,
            promptFingerprint: request.promptFingerprint,
            idempotencyKey: request.idempotencyKey,
            requestSnapshot: VideoTaskRequestSnapshot(request.request)
        )

        #expect(await executor.cancel(idempotencyKey: request.idempotencyKey))
        #expect(store.record(id: record.id)?.status == .canceled)
        #expect(store.record(id: record.id)?.remoteCancellationState == .notRequested)
        #expect(await backend.cancelCount == 0)
    }

    @Test func cancelTransportFailurePersistsUnknownRemoteState() async throws {
        let directory = try makeDirectory("video-cancel-unknown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoTaskStore(directory: directory)
        let backend = VideoBackendProbe(
            states: [CloudTaskState(phase: .running)],
            cancellationShouldThrow: true
        )
        let executor = VideoTaskExecutor(
            store: store,
            backend: backend,
            assetDownloader: VideoAssetProbe(data: Data("video".utf8)),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0.05
        )
        let request = VideoTaskExecutionRequest(
            nodeID: UUID(),
            providerID: "test-video",
            promptFingerprint: "unknown-cancel",
            request: CloudVideoRequest(prompt: "取消未知")
        )

        let operation = Task { try await executor.start(request) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await executor.cancel(idempotencyKey: request.idempotencyKey))
        _ = await operation.result
        let record = try #require(store.allRecords().first)

        #expect(record.status == .canceled)
        #expect(record.remoteCancellationState == .unknown)
    }

    @Test func staleCancellationOutcomeCannotOverwriteRetriedAttempt() async throws {
        let directory = try makeDirectory("video-cancel-retry-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoTaskStore(directory: directory)
        let record = store.enqueue(
            nodeID: UUID(),
            providerID: "test-video",
            promptFingerprint: "cancel-retry-race"
        )
        #expect(store.markSubmitted(id: record.id, taskID: "remote-old"))
        #expect(store.markPolling(id: record.id))
        let backend = BlockingCancellationBackend()
        let executor = VideoTaskExecutor(
            store: store,
            backend: backend,
            assetDownloader: VideoAssetProbe(data: Data("video".utf8)),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0
        )

        let cancellation = Task {
            await executor.cancel(idempotencyKey: record.idempotencyKey)
        }
        for _ in 0..<2_000 where await backend.cancelStarted == false {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await backend.cancelStarted)

        let retried = try #require(store.retry(id: record.id))
        #expect(retried.attempt == record.attempt + 1)
        await backend.releaseCancellation()
        #expect(await cancellation.value)

        let current = try #require(store.record(id: record.id))
        #expect(current.status == .queued)
        #expect(current.attempt == retried.attempt)
        #expect(current.taskID.isEmpty)
        #expect(current.remoteCancellationState == .notRequested)
    }

    @Test func staleCancellationGenerationCannotOverwriteCurrentOutcome() throws {
        let directory = try makeDirectory("video-cancel-generation-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = VideoTaskRecord(
            id: "generation-race",
            nodeID: UUID(),
            providerID: "test-video",
            taskID: "remote-generation",
            promptFingerprint: "generation-race",
            status: .canceled,
            attempt: 1,
            cancellationGeneration: 7
        )
        try JSONEncoder().encode([original]).write(
            to: directory.appendingPathComponent(VideoTaskStore.fileName),
            options: .atomic
        )
        let store = VideoTaskStore(directory: directory)

        #expect(store.beginRemoteCancellation(
            id: original.id,
            taskID: original.taskID,
            attempt: original.attempt,
            cancellationGeneration: original.cancellationGeneration
        ))
        #expect(!store.completeRemoteCancellation(
            id: original.id,
            taskID: original.taskID,
            attempt: original.attempt,
            cancellationGeneration: original.cancellationGeneration - 1,
            outcome: .accepted
        ))
        #expect(store.record(id: original.id)?.remoteCancellationState == .requested)
        #expect(store.completeRemoteCancellation(
            id: original.id,
            taskID: original.taskID,
            attempt: original.attempt,
            cancellationGeneration: original.cancellationGeneration,
            outcome: .accepted
        ))
    }

    @Test func executorRetryAtMaximumAttemptFailsClosed() async throws {
        let directory = try makeDirectory("video-executor-retry-attempt-max")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = VideoTaskRecord(
            id: "executor-attempt-max",
            nodeID: UUID(),
            providerID: "test-video",
            taskID: "remote-attempt-max",
            promptFingerprint: "executor-attempt-max",
            status: .canceled,
            attempt: Int.max
        )
        try JSONEncoder().encode([original]).write(
            to: directory.appendingPathComponent(VideoTaskStore.fileName),
            options: .atomic
        )
        let store = VideoTaskStore(directory: directory)
        let executor = VideoTaskExecutor(
            store: store,
            backend: VideoBackendProbe(states: []),
            assetDownloader: VideoAssetProbe(data: Data("video".utf8)),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true),
            pollInterval: 0
        )
        let request = VideoTaskExecutionRequest(
            nodeID: original.nodeID,
            providerID: original.providerID,
            promptFingerprint: original.promptFingerprint,
            request: CloudVideoRequest(prompt: "最大 attempt")
        )

        do {
            _ = try await executor.retry(id: original.id, request: request)
            Issue.record("Int.max attempt 不得回退为 start 或返回终态成功")
        } catch let error as VideoTaskExecutionError {
            #expect(error == .retryUnavailable("attempt 已达到 Int.max"))
        }
        #expect(store.record(id: original.id) == original)
    }
}
