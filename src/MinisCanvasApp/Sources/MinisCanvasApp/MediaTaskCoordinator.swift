import Foundation
import CanvasCore
import MinisCore

/// Immutable scope carried by every independent media operation.
/// `runID` identifies the run; the idempotency key identifies the intent and
/// therefore remains stable when `attempt` increases for an explicit retry.
struct MediaTaskContext: Codable, Equatable, Hashable, Sendable {
    let identity: CanvasExecutionIdentity
    let attempt: Int
    let providerSnapshot: ProviderSnapshot
    let promptFingerprint: String
    let idempotencyKey: String
    let executionEnvelope: DAGExecutionEnvelope?

    init(
        identity: CanvasExecutionIdentity,
        attempt: Int = 1,
        providerSnapshot: ProviderSnapshot,
        promptFingerprint: String = "",
        idempotencyKey: String? = nil,
        executionEnvelope: DAGExecutionEnvelope? = nil
    ) {
        self.identity = identity
        self.attempt = max(1, attempt)
        self.providerSnapshot = providerSnapshot
        self.promptFingerprint = promptFingerprint
        self.idempotencyKey = idempotencyKey ?? Self.makeIdempotencyKey(
            identity: identity,
            providerSnapshot: providerSnapshot,
            promptFingerprint: promptFingerprint,
            executionEnvelope: executionEnvelope
        )
        self.executionEnvelope = executionEnvelope
    }

    init(
        envelope: DAGExecutionEnvelope,
        nodeID: UUID,
        nodeRevision: Int,
        attempt: Int = 1,
        providerSnapshot: ProviderSnapshot,
        promptFingerprint: String = "",
        idempotencyKey: String? = nil
    ) {
        self.init(
            identity: envelope.identity(for: nodeID, nodeRevision: nodeRevision),
            attempt: attempt,
            providerSnapshot: providerSnapshot,
            promptFingerprint: promptFingerprint,
            idempotencyKey: idempotencyKey,
            executionEnvelope: envelope
        )
    }

    init(
        executionEnvelope: DAGExecutionEnvelope,
        nodeID: UUID,
        nodeRevision: Int,
        attempt: Int = 1,
        providerSnapshot: ProviderSnapshot,
        promptFingerprint: String = "",
        idempotencyKey: String? = nil
    ) {
        self.init(
            envelope: executionEnvelope,
            nodeID: nodeID,
            nodeRevision: nodeRevision,
            attempt: attempt,
            providerSnapshot: providerSnapshot,
            promptFingerprint: promptFingerprint,
            idempotencyKey: idempotencyKey
        )
    }

    static func makeIdempotencyKey(
        identity: CanvasExecutionIdentity,
        providerSnapshot: ProviderSnapshot,
        promptFingerprint: String = "",
        executionEnvelope: DAGExecutionEnvelope? = nil
    ) -> String {
        var parts = [
            identity.canvasID.uuidString.lowercased(),
            identity.runID.uuidString.lowercased(),
            identity.graphRevision.description,
            identity.nodeID.uuidString.lowercased(),
            identity.nodeRevision.description,
            providerSnapshot.providerID,
            providerSnapshot.modelID,
            providerSnapshot.configurationFingerprint,
            promptFingerprint,
        ]
        if let executionEnvelope {
            parts.append(executionEnvelope.graphFingerprint)
            parts.append(executionEnvelope.cancellationGeneration.description)
            parts.append(executionEnvelope.idempotencyKey ?? "")
        }
        return parts.joined(separator: "|")
    }

    func withAttempt(_ nextAttempt: Int) -> MediaTaskContext {
        MediaTaskContext(
            identity: identity,
            attempt: nextAttempt,
            providerSnapshot: providerSnapshot,
            promptFingerprint: promptFingerprint,
            idempotencyKey: idempotencyKey,
            executionEnvelope: executionEnvelope
        )
    }

    func withPromptFingerprint(_ fingerprint: String) -> MediaTaskContext {
        guard promptFingerprint.isEmpty else { return self }
        return MediaTaskContext(
            identity: identity,
            attempt: attempt,
            providerSnapshot: providerSnapshot,
            promptFingerprint: fingerprint,
            executionEnvelope: executionEnvelope
        )
    }

    func matches(executionEnvelope envelope: DAGExecutionEnvelope) -> Bool {
        guard envelope.isValid,
              envelope.identity(for: identity.nodeID, nodeRevision: identity.nodeRevision) == identity else {
            return false
        }
        if let providerFingerprint = envelope.providerSnapshotFingerprint,
           providerFingerprint != providerSnapshot.configurationFingerprint {
            return false
        }
        if let boundEnvelope = executionEnvelope, boundEnvelope != envelope {
            return false
        }
        return true
    }

    /// Compatibility context for pre-line-6 callers. It is intentionally
    /// marked legacy by its zero identity and is never accepted for scoped
    /// write-back.
    static func legacy(
        nodeID: UUID,
        providerID: String,
        promptFingerprint: String,
        idempotencyKey: String
    ) -> MediaTaskContext {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let snapshot = ProviderSnapshot(
            providerID: providerID,
            modelID: "",
            capabilities: [.video],
            configurationFingerprint: "legacy"
        )
        let identity = CanvasExecutionIdentity(
            canvasID: zero,
            runID: zero,
            graphRevision: 0,
            nodeID: nodeID,
            nodeRevision: 0
        )
        return MediaTaskContext(
            identity: identity,
            providerSnapshot: snapshot,
            promptFingerprint: promptFingerprint,
            idempotencyKey: idempotencyKey.isEmpty
                ? "legacy|\(nodeID.uuidString)|\(promptFingerprint)"
                : idempotencyKey
        )
    }
}

enum MediaTaskMetadataError: Error, Equatable, LocalizedError, Sendable {
    case missing(String)
    case identityConflict(String)
    case invalidAttempt
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .missing(let recordID): return "任务 \(recordID) 没有持久化线6身份"
        case .identityConflict(let recordID): return "任务 \(recordID) 的身份或 Provider 快照不一致"
        case .invalidAttempt: return "任务 attempt 必须为正数"
        case .persistenceFailed: return "线6任务身份无法持久化，已拒绝提交"
        }
    }
}

/// Sidecar persistence for fields that the frozen VideoTaskStore schema cannot
/// carry. It is keyed by the store record ID and written atomically alongside
/// the store's own file. No transcript/session lookup is involved.
final class MediaTaskMetadataStore: @unchecked Sendable {
    private struct Snapshot: Codable {
        let schemaVersion: Int
        let contexts: [String: MediaTaskContext]
    }

    /// Every provider executor creates its own store for the same directory.
    /// Coordinate the read/modify/write transaction by sidecar path, without
    /// serializing stores whose files live in different directories.
    private final class PathLocks: @unchecked Sendable {
        private let registryLock = NSLock()
        private var locks: [String: NSLock] = [:]

        func lock(for path: String) -> NSLock {
            registryLock.lock(); defer { registryLock.unlock() }
            if let existing = locks[path] { return existing }
            let created = NSLock()
            locks[path] = created
            return created
        }
    }

    static let fileName = "line6MediaTaskMetadata.json"
    private static let schemaVersion = 1
    private static let pathLocks = PathLocks()
    private let fileURL: URL
    private let lock: NSLock
    private var contexts: [String: MediaTaskContext]

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        lock = Self.pathLocks.lock(for: fileURL.standardizedFileURL.resolvingSymlinksInPath().path)
        contexts = [:]
        contexts = (try? Self.load(fileURL: fileURL)) ?? [:]
    }

    func context(recordID: String) throws -> MediaTaskContext? {
        lock.lock(); defer { lock.unlock() }
        contexts = try Self.load(fileURL: fileURL)
        return contexts[recordID]
    }

    func bind(
        recordID: String,
        context: MediaTaskContext,
        allowLegacyBinding: Bool
    ) throws {
        guard context.attempt > 0 else { throw MediaTaskMetadataError.invalidAttempt }
        lock.lock(); defer { lock.unlock() }
        // Other provider stores may have committed since this instance loaded.
        // Merge against the latest sidecar while every same-path writer waits.
        contexts = try Self.load(fileURL: fileURL)
        if let existing = contexts[recordID] {
            guard Self.sameIntent(existing, context), context.attempt >= existing.attempt else {
                throw MediaTaskMetadataError.identityConflict(recordID)
            }
            contexts[recordID] = context
            do {
                try saveLocked()
            } catch {
                contexts[recordID] = existing
                throw MediaTaskMetadataError.persistenceFailed
            }
            return
        }
        guard allowLegacyBinding else {
            throw MediaTaskMetadataError.missing(recordID)
        }
        contexts[recordID] = context
        do {
            try saveLocked()
        } catch {
            contexts[recordID] = nil
            throw MediaTaskMetadataError.persistenceFailed
        }
    }

    private static func sameIntent(_ lhs: MediaTaskContext, _ rhs: MediaTaskContext) -> Bool {
        lhs.identity == rhs.identity &&
        lhs.providerSnapshot == rhs.providerSnapshot &&
        lhs.promptFingerprint == rhs.promptFingerprint &&
        lhs.idempotencyKey == rhs.idempotencyKey &&
        lhs.executionEnvelope == rhs.executionEnvelope
    }

    private func saveLocked() throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(
                Snapshot(schemaVersion: Self.schemaVersion, contexts: contexts)
            )
        } catch {
            throw MediaTaskMetadataError.persistenceFailed
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(fileURL: URL) throws -> [String: MediaTaskContext] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return [:]
            }
            throw MediaTaskMetadataError.persistenceFailed
        }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaVersion == schemaVersion else {
            return [:]
        }
        return snapshot.contexts
    }
}

enum MediaTaskWritebackDecision: Equatable, Sendable {
    case accepted
    case rejected(MediaTaskWritebackRejection)
}

enum MediaTaskWritebackRejection: Equatable, Sendable {
    case cancelled
    case identity(CanvasWritebackDecision)
    case invalidPayload
    case persistenceFailed
}

/// Shared operation lifecycle for media tasks. The coordinator is deliberately
/// independent of CanvasStore, BridgeStore, transcript, and UI state.
actor MediaTaskCoordinator {
    let executor: VideoTaskExecutor
    private var canceledKeys: Set<String> = []

    init(executor: VideoTaskExecutor) {
        self.executor = executor
    }

    func start(
        context: MediaTaskContext,
        promptFingerprint: String,
        request: CloudVideoRequest
    ) async throws -> VideoTaskRecord {
        let scopedContext = context.withPromptFingerprint(promptFingerprint)
        let executionRequest = VideoTaskExecutionRequest(
            context: scopedContext,
            promptFingerprint: promptFingerprint,
            request: request
        )
        return try await executor.start(executionRequest)
    }

    @discardableResult
    func cancel(idempotencyKey: String) async -> Bool {
        canceledKeys.insert(idempotencyKey)
        return await executor.cancel(idempotencyKey: idempotencyKey)
    }

    @discardableResult
    func cancel(context: MediaTaskContext, promptFingerprint: String) async -> Bool {
        let scopedContext = context.withPromptFingerprint(promptFingerprint)
        return await cancel(idempotencyKey: scopedContext.idempotencyKey)
    }

    func isCanceled(idempotencyKey: String) -> Bool {
        canceledKeys.contains(idempotencyKey)
    }

    func retry(
        id: String,
        context: MediaTaskContext,
        promptFingerprint: String,
        request: CloudVideoRequest
    ) async throws -> VideoTaskRecord {
        canceledKeys.remove(context.idempotencyKey)
        let scopedContext = context.withPromptFingerprint(promptFingerprint)
        canceledKeys.remove(scopedContext.idempotencyKey)
        let executionRequest = VideoTaskExecutionRequest(
            context: scopedContext,
            promptFingerprint: promptFingerprint,
            request: request
        )
        return try await executor.retry(id: id, request: executionRequest)
    }

    /// The executor increments the durable attempt during retry. Read the
    /// sidecar back so the Canvas commit records the same attempt as the task.
    func context(for recordID: String) async throws -> MediaTaskContext? {
        try await executor.context(for: recordID)
    }

    func recover(id: String, context: MediaTaskContext) async throws -> VideoTaskRecord? {
        try await executor.recover(id: id, context: context)
    }
}
