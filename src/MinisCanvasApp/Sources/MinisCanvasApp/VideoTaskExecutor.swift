import Foundation
import MinisCore

/// 独立媒体任务的后端契约。它与画布 `VideoGenerating` 分开，避免把会话内
/// 媒体任务的恢复、取消和资产落盘耦合到画布节点执行器。
protocol VideoTaskBackend: Sendable {
    func submitVideo(_ request: CloudVideoRequest) async throws -> String
    func pollVideo(taskID: String) async throws -> CloudTaskState
    /// 后端没有远端取消 API 时返回 `.unsupported`；本地取消仍然会立即生效。
    func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome
}

extension VideoTaskBackend {
    func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome {
        .unsupported
    }
}

/// 生产 CloudVideoGenerator 的适配器；真实 Provider 的 submit/poll 仍由
/// MinisCore 实现，执行层只负责持久化和生命周期。
struct CloudVideoTaskBackend: VideoTaskBackend {
    let provider: any CloudVideoGenerator
    let cancelHandler: (@Sendable (String) async throws -> CloudVideoCancellationOutcome)?

    init(
        provider: any CloudVideoGenerator,
        cancelHandler: (@Sendable (String) async throws -> CloudVideoCancellationOutcome)? = nil
    ) {
        self.provider = provider
        self.cancelHandler = cancelHandler
    }

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        try await provider.submitVideo(request)
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        try await provider.pollVideo(taskID: taskID)
    }

    func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome {
        if let cancelHandler {
            return try await cancelHandler(taskID)
        } else {
            return try await provider.cancelVideo(taskID: taskID)
        }
    }
}

/// 资产下载器可注入 replay/mock，生产实现使用 URLSession 并以 `.atomic` 写入。
protocol VideoAssetDownloader: Sendable {
    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL
}

struct URLSessionVideoAssetDownloader: VideoAssetDownloader {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(remoteURL: String, recordID: String, into directory: URL) async throws -> URL {
        guard let url = URL(string: remoteURL),
              url.scheme == "http" || url.scheme == "https" else {
            throw VideoTaskExecutionError.invalidAssetURL(remoteURL)
        }
        let (data, response) = try await session.data(from: url)
        if let response = response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            throw VideoTaskExecutionError.assetDownloadFailed("HTTP \(response.statusCode)")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(recordID).mp4", isDirectory: false)
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

struct VideoTaskExecutionRequest: Sendable, Equatable {
    let nodeID: UUID
    let providerID: String
    let promptFingerprint: String
    let request: CloudVideoRequest
    let idempotencyKey: String
    let context: MediaTaskContext?

    init(
        nodeID: UUID,
        providerID: String,
        promptFingerprint: String,
        request: CloudVideoRequest,
        idempotencyKey: String? = nil
    ) {
        self.nodeID = nodeID
        self.providerID = providerID
        self.promptFingerprint = promptFingerprint
        self.request = request
        self.idempotencyKey = idempotencyKey ?? VideoTaskRecord.makeIdempotencyKey(
            nodeID: nodeID,
            promptFingerprint: promptFingerprint
        )
        self.context = nil
    }

    init(
        context: MediaTaskContext,
        promptFingerprint: String,
        request: CloudVideoRequest
    ) {
        self.nodeID = context.identity.nodeID
        self.providerID = context.providerSnapshot.providerID
        self.promptFingerprint = promptFingerprint
        self.request = request
        self.idempotencyKey = context.idempotencyKey
        self.context = context
    }
}

enum VideoTaskExecutionError: Error, Equatable, Sendable, LocalizedError {
    case missingRemoteTaskID(String)
    case missingVideoURL(String)
    case pollTimeout(String)
    case invalidAssetURL(String)
    case assetDownloadFailed(String)
    case assetOutsideDirectory(String)
    case remoteCanceled(String)
    case contextMismatch(String)
    case scopedRecoveryUnavailable(String)
    case retryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingRemoteTaskID(let id): return "视频任务 \(id) 未返回远端 task ID"
        case .missingVideoURL(let id): return "视频任务 \(id) 成功但未返回视频 URL"
        case .pollTimeout(let id): return "视频任务 \(id) 轮询超时"
        case .invalidAssetURL(let url): return "视频资产 URL 无效：\(url)"
        case .assetDownloadFailed(let detail): return "视频资产下载失败：\(detail)"
        case .assetOutsideDirectory(let path): return "视频资产路径越界：\(path)"
        case .remoteCanceled(let id): return "远端视频任务 \(id) 已取消"
        case .contextMismatch(let detail): return "视频任务身份校验失败：\(detail)"
        case .scopedRecoveryUnavailable(let id): return "视频任务 \(id) 缺少线6恢复身份，已拒绝继续执行"
        case .retryUnavailable(let detail): return "视频任务无法重试：\(detail)"
        }
    }
}

/// 独立视频任务执行器：本地记录是唯一状态事实源，submit 只在 queued 且没有
/// remote task ID 时发生；重启恢复只轮询 recoverableTasks，不会再次 submit。
final actor VideoTaskExecutor {
    let store: VideoTaskStore
    let backend: any VideoTaskBackend
    let assetDownloader: any VideoAssetDownloader
    let assetDirectory: URL
    let pollInterval: TimeInterval
    let pollTimeout: TimeInterval
    let metadataStore: MediaTaskMetadataStore
    private var operations: [String: Task<VideoTaskRecord, Error>] = [:]
    private var cancelRequested: Set<String> = []

    init(
        store: VideoTaskStore = .shared,
        backend: any VideoTaskBackend,
        assetDownloader: any VideoAssetDownloader = URLSessionVideoAssetDownloader(),
        assetDirectory: URL,
        pollInterval: TimeInterval = 5,
        pollTimeout: TimeInterval = 600,
        metadataStore: MediaTaskMetadataStore? = nil
    ) {
        self.store = store
        self.backend = backend
        self.assetDownloader = assetDownloader
        self.assetDirectory = assetDirectory.standardizedFileURL
        self.pollInterval = max(0, pollInterval)
        self.pollTimeout = max(0.001, pollTimeout)
        self.metadataStore = metadataStore ?? MediaTaskMetadataStore(directory: store.directory)
    }

    /// 幂等入口。终态记录也会复用，显式重试必须先调用 `retry(id:)`。
    func start(_ request: VideoTaskExecutionRequest) async throws -> VideoTaskRecord {
        if let context = request.context {
            guard context.identity.isValid,
                  context.identity.nodeID == request.nodeID,
                  context.providerSnapshot.providerID == request.providerID,
                  context.providerSnapshot.isValid,
                  context.providerSnapshot.capabilities.contains(.video),
                  context.promptFingerprint.isEmpty || context.promptFingerprint == request.promptFingerprint,
                  context.idempotencyKey == request.idempotencyKey else {
                throw VideoTaskExecutionError.contextMismatch("请求字段与任务上下文不一致")
            }
        }
        let existing = store.allRecords().first {
            $0.idempotencyKey == request.idempotencyKey && $0.status.isActive
        }
        if let terminal = store.allRecords().first(where: {
            $0.idempotencyKey == request.idempotencyKey && $0.status.isTerminal
        }) {
            if let context = request.context {
                guard try metadataStore.context(recordID: terminal.id) == context else {
                    throw VideoTaskExecutionError.contextMismatch("终态记录没有匹配的持久化身份")
                }
            }
            return terminal
        }

        let record = store.resumeOrCreate(
            nodeID: request.nodeID,
            providerID: request.providerID,
            promptFingerprint: request.promptFingerprint,
            idempotencyKey: request.idempotencyKey,
            requestSnapshot: VideoTaskRequestSnapshot(request.request),
            cancellationGeneration: request.context?.executionEnvelope?.cancellationGeneration ?? 0
        )
        if let context = request.context {
            do {
                try metadataStore.bind(
                    recordID: record.id,
                    context: context,
                    allowLegacyBinding: existing == nil
                )
            } catch {
                throw VideoTaskExecutionError.contextMismatch(error.localizedDescription)
            }
        }
        let key = record.idempotencyKey
        return try await run(
            record: record,
            request: record.requestSnapshot?.request ?? request.request,
            key: key
        )
    }

    /// 取消本地执行并尽力调用远端取消；状态先落盘为 canceled，后续轮询
    /// 即使返回 succeeded 也不能覆盖这个终态。
    @discardableResult
    func cancel(idempotencyKey: String) async -> Bool {
        guard let record = store.allRecords().first(where: {
            $0.idempotencyKey == idempotencyKey && $0.status.isActive
        }) else {
            return false
        }
        cancelRequested.insert(idempotencyKey)
        operations[idempotencyKey]?.cancel()
        let marked = store.markCanceled(id: record.id)
        if !record.taskID.isEmpty {
            await cancelRemote(
                recordID: record.id,
                taskID: record.taskID,
                attempt: record.attempt,
                cancellationGeneration: record.cancellationGeneration
            )
        }
        return marked || store.record(id: record.id)?.status == .canceled
    }

    /// Cancel every active scoped task belonging to one Canvas run.
    /// The run identity comes from the persisted sidecar, never from a path
    /// or an in-memory UI projection.
    func cancelTasks(runID: UUID) async -> Bool {
        let records = store.allRecords().filter { $0.status.isActive }
        var cancelled = false
        for record in records {
            guard let context = try? metadataStore.context(recordID: record.id),
                  context.identity.runID == runID else { continue }
            cancelled = await cancel(idempotencyKey: record.idempotencyKey) || cancelled
        }
        return cancelled
    }

    /// 重启后只恢复带 remote task ID 的任务。queued 记录没有提交请求，必须
    /// 由原调用方重新提供请求，不能猜测参数并自动扣费。
    func recoverPending() async throws -> [VideoTaskRecord] {
        var results: [VideoTaskRecord] = []
        for record in store.recoverableTasks() {
            do {
                if let recovered = try await recover(id: record.id) {
                    results.append(recovered)
                }
            } catch {
                if let current = store.record(id: record.id) {
                    results.append(current)
                }
            }
        }
        return results
    }

    /// 恢复单条已有远端任务，并复用 `start` 的同一 operations 去重表。
    /// 只有持久化了 remote task ID 的记录允许走该入口，避免重启时猜参数 submit。
    func recover(id: String) async throws -> VideoTaskRecord? {
        guard let record = store.record(id: id),
              record.status.isActive,
              !record.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try await run(record: record, request: nil, key: record.idempotencyKey)
    }

    /// Scoped recovery requires the sidecar identity to match exactly. A
    /// legacy record with only taskID/providerID is deliberately insufficient.
    func recover(id: String, context: MediaTaskContext) async throws -> VideoTaskRecord? {
        guard try metadataStore.context(recordID: id) == context else {
            throw VideoTaskExecutionError.scopedRecoveryUnavailable(id)
        }
        guard let record = store.record(id: id),
              record.status.isActive,
              !record.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard record.idempotencyKey == context.idempotencyKey,
              record.nodeID == context.identity.nodeID,
              record.providerID == context.providerSnapshot.providerID else {
            throw VideoTaskExecutionError.contextMismatch("恢复记录与任务上下文不一致")
        }
        return try await run(record: record, request: nil, key: record.idempotencyKey)
    }

    func context(for recordID: String) throws -> MediaTaskContext? {
        try metadataStore.context(recordID: recordID)
    }

    /// 显式重试入口，只有 failed/canceled/expired 允许回到 queued。
    func retry(
        id: String,
        request: VideoTaskExecutionRequest
    ) async throws -> VideoTaskRecord {
        if let context = request.context {
            guard let stored = try metadataStore.context(recordID: id),
                  stored.identity == context.identity,
                  stored.providerSnapshot == context.providerSnapshot,
                  stored.idempotencyKey == context.idempotencyKey,
                  stored.attempt == context.attempt else {
                throw VideoTaskExecutionError.contextMismatch("重试身份未匹配持久化任务")
            }
        }
        guard let existing = store.record(id: id) else {
            return try await start(request)
        }
        let retryable = existing.status == .failed
            || existing.status == .canceled
            || existing.status == .expired
        guard retryable else {
            return try await start(request)
        }
        guard existing.attempt < Int.max else {
            throw VideoTaskExecutionError.retryUnavailable("attempt 已达到 Int.max")
        }
        guard let retried = store.retry(id: id) else {
            throw VideoTaskExecutionError.retryUnavailable("持久化 attempt fence 未通过")
        }
        let matchingRequest: VideoTaskExecutionRequest
        if let context = request.context {
            let (nextAttempt, overflow) = context.attempt.addingReportingOverflow(1)
            guard !overflow else {
                throw VideoTaskExecutionError.retryUnavailable("上下文 attempt 已达到 Int.max")
            }
            let nextContext = context.withAttempt(nextAttempt)
            do {
                try metadataStore.bind(recordID: retried.id, context: nextContext, allowLegacyBinding: false)
            } catch {
                throw VideoTaskExecutionError.contextMismatch(error.localizedDescription)
            }
            matchingRequest = VideoTaskExecutionRequest(
                context: nextContext,
                promptFingerprint: retried.promptFingerprint,
                request: request.request
            )
        } else {
            matchingRequest = VideoTaskExecutionRequest(
                nodeID: retried.nodeID,
                providerID: retried.providerID,
                promptFingerprint: retried.promptFingerprint,
                request: request.request,
                idempotencyKey: retried.idempotencyKey
            )
        }
        return try await start(matchingRequest)
    }

    private func run(
        record: VideoTaskRecord,
        request: CloudVideoRequest?,
        key: String
    ) async throws -> VideoTaskRecord {
        if let operation = operations[key] {
            return try await operation.value
        }

        let operation = Task { [self] in
            try await execute(record: record, request: request)
        }
        operations[key] = operation
        defer {
            operations[key] = nil
            cancelRequested.remove(key)
        }
        return try await operation.value
    }

    private func execute(
        record: VideoTaskRecord,
        request: CloudVideoRequest?
    ) async throws -> VideoTaskRecord {
        var current = record
        var submittedTaskID: String?
        do {
            try Task.checkCancellation()
            var taskID = current.taskID
            if taskID.isEmpty {
                guard let request else {
                    throw VideoTaskExecutionError.missingRemoteTaskID(current.id)
                }
                let submitted = try await backend.submitVideo(request)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !submitted.isEmpty else {
                    throw VideoTaskExecutionError.missingRemoteTaskID(current.id)
                }
                // Keep the returned ID in a local variable before the next
                // cancellation check: a stop can race the persistence write.
                submittedTaskID = submitted
                guard store.markSubmitted(id: current.id, taskID: submitted) else {
                    // `cancel()` may have marked the local record terminal while
                    // the remote submit was still in flight. The provider has
                    // now accepted the task, so best-effort cancellation must
                    // happen even though the local transition is no longer
                    // legal. Without this branch the cloud task is orphaned.
                    if cancelRequested.contains(current.idempotencyKey) {
                        await cancelRemote(
                            recordID: current.id,
                            taskID: submitted,
                            attempt: current.attempt,
                            cancellationGeneration: current.cancellationGeneration
                        )
                    }
                    return store.record(id: current.id) ?? current
                }
                taskID = submitted
                current = store.record(id: current.id) ?? current
            }

            guard !Task.isCancelled,
                  cancelRequested.contains(current.idempotencyKey) == false else {
                throw CancellationError()
            }
            _ = store.markPolling(id: current.id)
            let deadline = Date().addingTimeInterval(pollTimeout)
            while true {
                try Task.checkCancellation()
                guard cancelRequested.contains(current.idempotencyKey) == false else {
                    throw CancellationError()
                }
                let state = try await backend.pollVideo(taskID: taskID)
                switch state.phase {
                case .succeeded:
                    guard let remoteURL = state.videoURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !remoteURL.isEmpty else {
                        throw VideoTaskExecutionError.missingVideoURL(current.id)
                    }
                    let localURL = try await assetDownloader.download(
                        remoteURL: remoteURL,
                        recordID: current.id,
                        into: assetDirectory
                    )
                    guard Self.isWithin(localURL, directory: assetDirectory),
                          FileManager.default.fileExists(atPath: localURL.path) else {
                        throw VideoTaskExecutionError.assetOutsideDirectory(localURL.path)
                    }
                    guard store.markSucceeded(
                        id: current.id,
                        videoURL: remoteURL,
                        assetPath: localURL.path
                    ) else {
                        return store.record(id: current.id) ?? current
                    }
                    return store.record(id: current.id) ?? current
                case .failed:
                    throw CloudBackendError.taskFailed(
                        providerID: current.providerID,
                        taskID: taskID,
                        message: state.message ?? "unknown"
                    )
                case .canceled:
                    throw VideoTaskExecutionError.remoteCanceled(current.id)
                case .queued, .running, .unknown:
                    guard Date() < deadline else {
                        throw VideoTaskExecutionError.pollTimeout(current.id)
                    }
                    if pollInterval > 0 {
                        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    }
                }
            }
        } catch is CancellationError {
            let remoteTaskID = current.taskID.isEmpty ? submittedTaskID : current.taskID
            _ = store.markCanceled(id: current.id)
            if let remoteTaskID, !remoteTaskID.isEmpty,
               cancelRequested.contains(current.idempotencyKey) == false {
                await cancelRemote(
                    recordID: current.id,
                    taskID: remoteTaskID,
                    attempt: current.attempt,
                    cancellationGeneration: current.cancellationGeneration
                )
            }
            throw CancellationError()
        } catch {
            if Task.isCancelled || cancelRequested.contains(current.idempotencyKey) {
                let remoteTaskID = current.taskID.isEmpty ? submittedTaskID : current.taskID
                _ = store.markCanceled(id: current.id)
                if let remoteTaskID, !remoteTaskID.isEmpty,
                   cancelRequested.contains(current.idempotencyKey) == false {
                    await cancelRemote(
                        recordID: current.id,
                        taskID: remoteTaskID,
                        attempt: current.attempt,
                        cancellationGeneration: current.cancellationGeneration
                    )
                }
                throw CancellationError()
            }
            _ = store.markFailed(id: current.id, message: error.localizedDescription)
            throw error
        }
    }

    private func cancelRemote(
        recordID: String,
        taskID: String,
        attempt: Int,
        cancellationGeneration: Int
    ) async {
        let remoteID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteID.isEmpty else { return }
        guard store.beginRemoteCancellation(
            id: recordID,
            taskID: remoteID,
            attempt: attempt,
            cancellationGeneration: cancellationGeneration
        ) else {
            return
        }
        do {
            let outcome = try await backend.cancelVideo(taskID: remoteID)
            _ = store.completeRemoteCancellation(
                id: recordID,
                taskID: remoteID,
                attempt: attempt,
                cancellationGeneration: cancellationGeneration,
                outcome: outcome
            )
        } catch {
            _ = store.completeRemoteCancellationAsUnknown(
                id: recordID,
                taskID: remoteID,
                attempt: attempt,
                cancellationGeneration: cancellationGeneration
            )
        }
    }

    private static func isWithin(_ file: URL, directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }
}

/// 同一生产 invoker 内按 Provider 复用执行器，保证并发的同一幂等键共用
/// `operations` 去重表；Provider 配置变化通过重新创建 invoker 生效。
final actor VideoTaskExecutorRegistry {
    private let store: VideoTaskStore
    private let assetDownloader: any VideoAssetDownloader
    private let assetDirectory: URL
    private var executors: [String: VideoTaskExecutor] = [:]

    init(
        store: VideoTaskStore,
        assetDownloader: any VideoAssetDownloader,
        assetDirectory: URL
    ) {
        self.store = store
        self.assetDownloader = assetDownloader
        self.assetDirectory = assetDirectory
    }

    func executor(
        providerID: String,
        provider: any CloudVideoGenerator
    ) -> VideoTaskExecutor {
        if let existing = executors[providerID] {
            return existing
        }
        let executor = VideoTaskExecutor(
            store: store,
            backend: CloudVideoTaskBackend(provider: provider),
            assetDownloader: assetDownloader,
            assetDirectory: assetDirectory
        )
        executors[providerID] = executor
        return executor
    }

    func cancelTasks(runID: UUID) async -> Bool {
        var cancelled = false
        for executor in executors.values {
            cancelled = await executor.cancelTasks(runID: runID) || cancelled
        }
        return cancelled
    }
}
