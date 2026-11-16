import Foundation
import MinisCore

// MARK: - 生视频任务状态机与持久化
//
// 任务记录属于 App 的执行恢复层，不改变画布节点模型。旧版记录的
// submitted/succeeded/failed rawValue 保持不变；新增 queued/polling/canceled/expired
// 用于独立媒体任务执行器。所有写入仍采用 JSON + .atomic，损坏文件会移动到
// quarantine，避免静默丢失远程 taskID。

/// 可重试/恢复的视频请求快照。
///
/// `CloudVideoRequest` 属于 MinisCore 的运行时值，不直接承担 App 层落盘协议；
/// 此快照显式固定 wire 字段，保证旧任务恢复时不会凭空重建或重复提交不同请求。
struct VideoTaskRequestSnapshot: Codable, Equatable, Sendable {
    let request: CloudVideoRequest

    init(_ request: CloudVideoRequest) {
        self.request = request
    }

    private enum CodingKeys: String, CodingKey {
        case prompt
        case imageURL
        case aspectRatio
        case duration
        case modelOverride
        case extraParams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.request = CloudVideoRequest(
            prompt: try container.decode(String.self, forKey: .prompt),
            imageURL: try container.decodeIfPresent(String.self, forKey: .imageURL),
            aspectRatio: try container.decodeIfPresent(String.self, forKey: .aspectRatio),
            duration: try container.decodeIfPresent(String.self, forKey: .duration),
            modelOverride: try container.decodeIfPresent(String.self, forKey: .modelOverride),
            extraParams: try container.decodeIfPresent(
                [String: String].self, forKey: .extraParams
            ) ?? [:]
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request.prompt, forKey: .prompt)
        try container.encodeIfPresent(request.imageURL, forKey: .imageURL)
        try container.encodeIfPresent(request.aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(request.duration, forKey: .duration)
        try container.encodeIfPresent(request.modelOverride, forKey: .modelOverride)
        try container.encode(request.extraParams, forKey: .extraParams)
    }
}

/// 生视频任务记录（Codable，落盘 videoTasks.json）。
struct VideoTaskRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable, Equatable, CaseIterable {
        case queued
        case submitted
        case polling
        case succeeded
        case failed
        case canceled
        case expired

        var isTerminal: Bool {
            switch self {
            case .succeeded, .failed, .canceled, .expired:
                return true
            case .queued, .submitted, .polling:
                return false
            }
        }

        var isActive: Bool { !isTerminal }

        /// 只允许状态机中的单向迁移；同态写入作为幂等操作允许。
        func canTransition(to target: Self) -> Bool {
            if self == target { return true }
            switch (self, target) {
            case (.queued, .submitted),
                 (.queued, .failed),
                 (.queued, .canceled),
                 (.queued, .expired),
                 (.submitted, .polling),
                 (.submitted, .succeeded),
                 (.submitted, .failed),
                 (.submitted, .canceled),
                 (.submitted, .expired),
                 (.polling, .succeeded),
                 (.polling, .failed),
                 (.polling, .canceled),
                 (.polling, .expired):
                return true
            default:
                return false
            }
        }
    }

    /// 远端取消的独立事实状态；不与本地 `Status.canceled` 互相替代。
    enum RemoteCancellationState: String, Codable, Sendable, Equatable, CaseIterable {
        case notRequested
        case requested
        case accepted
        case alreadyCanceled
        case unsupported
        case unknown
    }

    /// 本地客户端幂等键；旧记录没有该字段时由 nodeID + promptFingerprint 重建。
    var id: String
    var nodeID: UUID
    var providerID: String
    /// 远端 taskID；queued 阶段为空。
    var taskID: String
    var promptFingerprint: String
    var idempotencyKey: String
    var status: Status
    var attempt: Int
    /// Canvas execution generation used to fence late cancellation callbacks.
    /// Legacy records decode this as zero.
    var cancellationGeneration: Int
    var remoteCancellationState: RemoteCancellationState
    var videoURL: String?
    /// 成功后资产下载/落盘的本地路径，和远端 videoURL 分开保存。
    var assetPath: String?
    /// submit 前完整请求快照；旧记录没有此字段时保持 nil，禁止猜测请求参数。
    var requestSnapshot: VideoTaskRequestSnapshot?
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        nodeID: UUID,
        providerID: String,
        taskID: String,
        promptFingerprint: String,
        status: Status = .submitted,
        attempt: Int = 1,
        cancellationGeneration: Int = 0,
        remoteCancellationState: RemoteCancellationState = .notRequested,
        videoURL: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        idempotencyKey: String? = nil,
        assetPath: String? = nil,
        requestSnapshot: VideoTaskRequestSnapshot? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.providerID = providerID
        self.taskID = taskID
        self.promptFingerprint = promptFingerprint
        self.idempotencyKey = idempotencyKey ?? Self.makeIdempotencyKey(
            nodeID: nodeID, promptFingerprint: promptFingerprint
        )
        self.status = status
        self.attempt = max(1, attempt)
        self.cancellationGeneration = max(0, cancellationGeneration)
        self.remoteCancellationState = remoteCancellationState
        self.videoURL = videoURL
        self.assetPath = assetPath
        self.requestSnapshot = requestSnapshot
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeID
        case providerID
        case taskID
        case promptFingerprint
        case idempotencyKey
        case status
        case attempt
        case cancellationGeneration
        case remoteCancellationState
        case videoURL
        case assetPath
        case requestSnapshot
        case errorMessage
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.nodeID = try container.decode(UUID.self, forKey: .nodeID)
        self.providerID = try container.decode(String.self, forKey: .providerID)
        self.taskID = try container.decode(String.self, forKey: .taskID)
        self.promptFingerprint = try container.decode(String.self, forKey: .promptFingerprint)
        self.idempotencyKey = try container.decodeIfPresent(
            String.self, forKey: .idempotencyKey
        ) ?? Self.makeIdempotencyKey(
            nodeID: nodeID, promptFingerprint: promptFingerprint
        )
        self.status = try container.decode(Status.self, forKey: .status)
        self.attempt = max(1, try container.decodeIfPresent(Int.self, forKey: .attempt) ?? 1)
        self.cancellationGeneration = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .cancellationGeneration) ?? 0
        )
        self.remoteCancellationState = try container.decodeIfPresent(
            RemoteCancellationState.self, forKey: .remoteCancellationState
        ) ?? .notRequested
        self.videoURL = try container.decodeIfPresent(String.self, forKey: .videoURL)
        self.assetPath = try container.decodeIfPresent(String.self, forKey: .assetPath)
        self.requestSnapshot = try container.decodeIfPresent(
            VideoTaskRequestSnapshot.self, forKey: .requestSnapshot
        )
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        self.createdAt = try Self.decodeDate(container, forKey: .createdAt)
        self.updatedAt = try Self.decodeDate(container, forKey: .updatedAt)
    }

    static func makeIdempotencyKey(
        nodeID: UUID,
        promptFingerprint: String
    ) -> String {
        "\(nodeID.uuidString.lowercased())|\(promptFingerprint)"
    }

    private static func decodeDate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Date {
        if let date = try? container.decode(Date.self, forKey: key) {
            return date
        }
        let text = try container.decode(String.self, forKey: key)
        guard let date = ISO8601DateFormatter().date(from: text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Unsupported video task date format"
            )
        }
        return date
    }
}

/// 生视频任务持久化存储。
///
/// `enqueue`/`resumeOrCreate` 是新媒体执行器的幂等入口；旧的
/// `recordSubmitted` 保留给现有画布执行链。两套入口共享同一记录和状态机，
/// 不需要建立第二份任务状态。
final class VideoTaskStore: @unchecked Sendable {
    static let fileName = "videoTasks.json"
    static let quarantineDirectoryName = "quarantine"

    /// 正式测试使用 Core 隔离根；生产和正常 field 沿用 AppSupport/MinisCore。
    static func defaultDirectory() -> URL {
        if let profile = RuntimeIsolationProfile.formalTestProfileForDefaultConsumer() {
            let dir = profile.minisCoreDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MinisCore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let shared = VideoTaskStore(directory: defaultDirectory())

    let directory: URL
    let quarantineDirectory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private var records: [String: VideoTaskRecord] = [:]

    init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.quarantineDirectory = directory.appendingPathComponent(
            Self.quarantineDirectoryName, isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.records = load()
    }

    // MARK: - 新状态机入口

    /// 新建排队记录；相同 nodeID + promptFingerprint 的活动任务始终复用旧记录。
    @discardableResult
    func enqueue(
        nodeID: UUID,
        providerID: String,
        promptFingerprint: String,
        idempotencyKey: String? = nil,
        id: String? = nil,
        requestSnapshot: VideoTaskRequestSnapshot? = nil,
        cancellationGeneration: Int = 0
    ) -> VideoTaskRecord {
        resumeOrCreate(
            nodeID: nodeID,
            providerID: providerID,
            promptFingerprint: promptFingerprint,
            idempotencyKey: idempotencyKey,
            id: id,
            requestSnapshot: requestSnapshot,
            cancellationGeneration: cancellationGeneration
        )
    }

    /// submit 前的幂等入口：活动记录返回 resume，只有不存在活动记录时才创建 queued。
    @discardableResult
    func resumeOrCreate(
        nodeID: UUID,
        providerID: String,
        promptFingerprint: String,
        idempotencyKey: String? = nil,
        id: String? = nil,
        requestSnapshot: VideoTaskRequestSnapshot? = nil,
        cancellationGeneration: Int = 0
    ) -> VideoTaskRecord {
        let key = idempotencyKey ?? VideoTaskRecord.makeIdempotencyKey(
            nodeID: nodeID, promptFingerprint: promptFingerprint
        )
        lock.lock(); defer { lock.unlock() }
        if var existing = records.values
            .filter({ $0.status.isActive })
            .first(where: { $0.idempotencyKey == key }) {
            if existing.requestSnapshot == nil, let requestSnapshot {
                existing.requestSnapshot = requestSnapshot
                existing.updatedAt = Date()
                records[existing.id] = existing
                saveLocked()
            }
            return existing
        }
        let now = Date()
        let record = VideoTaskRecord(
            id: id ?? UUID().uuidString,
            nodeID: nodeID,
            providerID: providerID,
            taskID: "",
            promptFingerprint: promptFingerprint,
            status: .queued,
            cancellationGeneration: cancellationGeneration,
            createdAt: now,
            updatedAt: now,
            idempotencyKey: key,
            requestSnapshot: requestSnapshot
        )
        records[record.id] = record
        saveLocked()
        return record
    }

    /// 绑定远端 taskID，queued → submitted。空 taskID 或非法迁移都会拒绝。
    @discardableResult
    func markSubmitted(id: String, taskID: String) -> Bool {
        let remoteID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteID.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard var record = records[id], record.status.canTransition(to: .submitted) else {
            return false
        }
        if record.status == .submitted && !record.taskID.isEmpty && record.taskID != remoteID {
            return false
        }
        record.status = .submitted
        record.taskID = remoteID
        record.updatedAt = Date()
        records[id] = record
        saveLocked()
        return true
    }

    @discardableResult
    func markPolling(id: String) -> Bool {
        transition(id: id, to: .polling)
    }

    @discardableResult
    func markSucceeded(
        id: String,
        videoURL: String,
        assetPath: String? = nil
    ) -> Bool {
        let normalizedURL = videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard var record = records[id], record.status.canTransition(to: .succeeded) else {
            return false
        }
        // A duplicate terminal event is idempotent: preserve the first durable
        // result instead of allowing a late provider callback to replace it.
        guard record.status != .succeeded else { return true }
        record.status = .succeeded
        record.videoURL = normalizedURL
        record.assetPath = assetPath
        record.errorMessage = nil
        record.updatedAt = Date()
        records[id] = record
        saveLocked()
        return true
    }

    /// 记录资产落盘路径。成功状态之后才允许写入，避免把半成品路径当成可用资产。
    @discardableResult
    func markAssetPersisted(id: String, assetPath: String) -> Bool {
        let path = assetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard var record = records[id], record.status == .succeeded else { return false }
        record.assetPath = path
        record.updatedAt = Date()
        records[id] = record
        saveLocked()
        return true
    }

    /// Clears a succeeded record's local asset path only when it still points
    /// at the path being compensated, avoiding clobbering a later retry.
    @discardableResult
    func clearSucceededAssetPath(id: String, expectedPath: String) -> Bool {
        let path = expectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard var record = records[id],
              record.status == .succeeded,
              record.assetPath == expectedPath else {
            return false
        }
        record.assetPath = nil
        record.updatedAt = Date()
        records[id] = record
        saveLocked()
        return true
    }

    @discardableResult
    func markFailed(id: String, message: String) -> Bool {
        transition(id: id, to: .failed) { record in
            record.errorMessage = message
            record.videoURL = nil
            record.assetPath = nil
        }
    }

    @discardableResult
    func markCanceled(id: String, message: String = "任务已取消") -> Bool {
        transition(id: id, to: .canceled) { record in
            record.errorMessage = message
            record.videoURL = nil
            record.assetPath = nil
        }
    }

    /// 在调用远端取消前以 taskID + attempt + generation 做 CAS，确保请求中的
    /// 中断不会跨 retry 或 DAG cancellation generation 污染当前任务。
    @discardableResult
    func beginRemoteCancellation(
        id: String,
        taskID: String,
        attempt: Int,
        cancellationGeneration: Int = 0
    ) -> Bool {
        let remoteID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteID.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard var record = records[id],
              record.status == .canceled,
              record.attempt == max(1, attempt),
              record.cancellationGeneration == cancellationGeneration else {
            return false
        }
        if record.taskID.isEmpty {
            record.taskID = remoteID
        }
        guard record.taskID == remoteID else { return false }
        record.remoteCancellationState = .requested
        record.updatedAt = Date()
        records[id] = record
        saveLocked()
        return true
    }

    /// 仅在取消仍属于同一个 taskID + attempt + generation 时落盘 Provider 的结果。
    @discardableResult
    func completeRemoteCancellation(
        id: String,
        taskID: String,
        attempt: Int,
        cancellationGeneration: Int = 0,
        outcome: CloudVideoCancellationOutcome
    ) -> Bool {
        let state: VideoTaskRecord.RemoteCancellationState
        switch outcome {
        case .accepted:
            state = .accepted
        case .alreadyCanceled:
            state = .alreadyCanceled
        case .unsupported:
            state = .unsupported
        }
        return setRemoteCancellationState(
            id: id,
            taskID: taskID,
            attempt: attempt,
            cancellationGeneration: cancellationGeneration,
            state: state
        )
    }

    /// 仅在取消仍属于同一个 taskID + attempt + generation 时记录未知效果。
    @discardableResult
    func completeRemoteCancellationAsUnknown(
        id: String,
        taskID: String,
        attempt: Int,
        cancellationGeneration: Int = 0
    ) -> Bool {
        setRemoteCancellationState(
            id: id,
            taskID: taskID,
            attempt: attempt,
            cancellationGeneration: cancellationGeneration,
            state: .unknown
        )
    }

    @discardableResult
    func markExpired(id: String, message: String = "任务已过期") -> Bool {
        transition(id: id, to: .expired) { record in
            record.errorMessage = message
            record.videoURL = nil
            record.assetPath = nil
        }
    }

    /// 显式重试：失败/取消/过期记录回到 queued，复用同一 client/idempotency key；
    /// 成功或仍在运行的记录拒绝重试，避免无意重复提交/扣费。
    @discardableResult
    func retry(id: String) -> VideoTaskRecord? {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[id],
              record.status == .failed || record.status == .canceled || record.status == .expired
        else { return nil }
        guard record.attempt < Int.max else { return nil }
        let (nextAttempt, overflow) = record.attempt.addingReportingOverflow(1)
        guard !overflow else { return nil }
        record.status = .queued
        record.taskID = ""
        record.attempt = nextAttempt
        record.remoteCancellationState = .notRequested
        record.videoURL = nil
        record.assetPath = nil
        record.errorMessage = nil
        record.updatedAt = Date()
        records[id] = record
        saveLocked()
        return record
    }

    // MARK: - 兼容现有画布执行链

    /// 旧调用入口：submit 成功后登记 submitted 记录。调用者可忽略返回值，保持原签名语义。
    func recordSubmitted(
        id: String,
        nodeID: UUID,
        providerID: String,
        taskID: String,
        promptFingerprint: String
    ) {
        let remoteID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteID.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }

        if let existing = records[id] {
            guard existing.status == .queued else { return }
            var updated = existing
            updated.status = .submitted
            updated.taskID = remoteID
            updated.updatedAt = Date()
            records[id] = updated
            saveLocked()
            return
        }

        let key = VideoTaskRecord.makeIdempotencyKey(
            nodeID: nodeID, promptFingerprint: promptFingerprint
        )
        // 即使旧 invoker 传来不同 clientToken，也不能在活动意图上重复登记。
        if records.values.contains(where: { $0.status.isActive && $0.idempotencyKey == key }) {
            return
        }
        let now = Date()
        let record = VideoTaskRecord(
            id: id,
            nodeID: nodeID,
            providerID: providerID,
            taskID: remoteID,
            promptFingerprint: promptFingerprint,
            status: .submitted,
            createdAt: now,
            updatedAt: now,
            idempotencyKey: key
        )
        records[id] = record
        saveLocked()
    }

    // MARK: - 查询

    /// 活动任务（queued/submitted/polling），按创建时间排序。
    func pendingTasks() -> [VideoTaskRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values
            .filter { $0.status.isActive }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 只有带远端 taskID 的活动任务才可直接恢复轮询；queued 需先完成 submit。
    func recoverableTasks() -> [VideoTaskRecord] {
        pendingTasks().filter { Self.hasRemoteTaskID($0.taskID) }
    }

    /// 给新媒体执行器查询同节点同提示词的活动记录（包括 queued/polling）。
    func activeTask(nodeID: UUID, promptFingerprint: String) -> VideoTaskRecord? {
        lock.lock(); defer { lock.unlock() }
        return records.values.first {
            $0.nodeID == nodeID &&
            $0.promptFingerprint == promptFingerprint &&
            $0.status.isActive
        }
    }

    /// 旧画布执行链的防重查询：只返回带 remote taskID 的活动记录，避免把 queued
    /// 记录交给 `pollVideo(taskID:)`。
    func pendingTask(nodeID: UUID, promptFingerprint: String) -> VideoTaskRecord? {
        lock.lock(); defer { lock.unlock() }
        return records.values.first {
            $0.nodeID == nodeID &&
            $0.promptFingerprint == promptFingerprint &&
            $0.status.isActive &&
            Self.hasRemoteTaskID($0.taskID)
        }
    }

    func record(id: String) -> VideoTaskRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }

    func allRecords() -> [VideoTaskRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - 内部

    @discardableResult
    private func transition(
        id: String,
        to target: VideoTaskRecord.Status,
        mutate: ((inout VideoTaskRecord) -> Void)? = nil
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[id], record.status.canTransition(to: target) else {
            return false
        }
        record.status = target
        mutate?(&record)
        record.updatedAt = Date()
        records[id] = record
        saveLocked()
        return true
    }

    @discardableResult
    private func setRemoteCancellationState(
        id: String,
        taskID: String,
        attempt: Int,
        cancellationGeneration: Int,
        state: VideoTaskRecord.RemoteCancellationState
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let remoteID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteID.isEmpty,
              var record = records[id],
              record.status == .canceled,
              record.taskID == remoteID,
              record.attempt == max(1, attempt),
              record.cancellationGeneration == cancellationGeneration,
              record.remoteCancellationState == .requested else {
            return false
        }
        if record.remoteCancellationState == state { return true }
        record.remoteCancellationState = state
        record.updatedAt = Date()
        records[id] = record
        saveLocked()
        return true
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(
            records.values.sorted { $0.createdAt < $1.createdAt }
        ) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func hasRemoteTaskID(_ taskID: String) -> Bool {
        !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() -> [String: VideoTaskRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([VideoTaskRecord].self, from: data) else {
            quarantineCorruptFile()
            return [:]
        }
        var result: [String: VideoTaskRecord] = [:]
        for record in list { result[record.id] = record }
        return result
    }

    private func quarantineCorruptFile() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
            let destination = quarantineDirectory.appendingPathComponent(
                "\(Self.fileName).\(UUID().uuidString).corrupt"
            )
            try fm.moveItem(at: fileURL, to: destination)
        } catch {
            // 隔离失败时保留原文件；空集返回仍保证画布执行链不因坏记录崩溃。
        }
    }
}
