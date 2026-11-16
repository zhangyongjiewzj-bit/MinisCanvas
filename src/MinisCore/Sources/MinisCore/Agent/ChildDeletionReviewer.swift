import Foundation
import CryptoKit

/// Eligibility for an optional independent classification; never a replacement
/// for the existing parent's ApprovalGate, command policy, roots or receipt.
public struct ChildDeletionReviewConfiguration: Sendable {
    public var enabled: Bool
    public var whitelistDirectories: [URL]
    public var timeout: TimeInterval
    public init(enabled: Bool = false, whitelistDirectories: [URL] = [], timeout: TimeInterval = 10) {
        self.enabled = enabled
        self.whitelistDirectories = whitelistDirectories
        self.timeout = timeout
    }
}

public enum ChildDeletionReviewReason: String, Codable, Sendable, Equatable {
    case disabled, notChildDeletion, outsideWhitelist, permissionRelated, checkpointUnavailable
    case unsafePath, fileChanged, modelRequiresHuman, classifierFailed, timedOut, cancelled, journalUnavailable
    case independentRecommendation
}

/// Content-free record. The checkpoint ID links the existing restore UI; no
/// model prose, file content, conversation, or child result enters this record.
public struct ChildDeletionReviewRecord: Codable, Sendable {
    public let id: UUID
    public let requestIDHash: String
    public let checkpointID: UUID?
    public let recordedAt: Date
    public let reason: ChildDeletionReviewReason
}

public struct ChildDeletionReviewResult: Sendable {
    public let recommendsRecoverableDeletion: Bool
    public let record: ChildDeletionReviewRecord
}

public struct ChildDeletionReviewer: Sendable {
    public let configuration: ChildDeletionReviewConfiguration
    private let classifier: any IndependentDeletionClassifying
    private let recordSink: (@Sendable (ChildDeletionReviewRecord) async throws -> Void)?

    public init(configuration: ChildDeletionReviewConfiguration = .init(),
        classifier: any IndependentDeletionClassifying,
        recordSink: (@Sendable (ChildDeletionReviewRecord) async throws -> Void)? = nil) {
        self.configuration = configuration; self.classifier = classifier; self.recordSink = recordSink
    }

    /// Caller holds the existing exact-file mutation lock across preparation,
    /// this call, the original ApprovalGate, and the file effect/commit. The
    /// result alone can never execute a deletion or issue a capability grant.
    /// Missing durable preparation always falls back to the existing human UI.
    public func review(request: ApprovalRequest, checkpointStore: FileCheckpointStore?,
        checkpointID: UUID?) async -> ChildDeletionReviewResult {
        func result(_ reason: ChildDeletionReviewReason, recommends: Bool = false) -> ChildDeletionReviewResult {
            ChildDeletionReviewResult(recommendsRecoverableDeletion: recommends,
                record: ChildDeletionReviewRecord(id: UUID(), requestIDHash:
                    SHA256.hash(data: Data(request.requestID.utf8)).map { String(format: "%02x", $0) }.joined(),
                    checkpointID: checkpointID, recordedAt: Date(), reason: reason))
        }
        guard configuration.enabled else { return result(.disabled) }
        let validBoundIdentity = request.binding.map { $0.isValid && $0.expiresAt > Date() } == true
        // Composer owns a different existing call identity. Accept it only
        // through the canonical pre-Gate resource context; never synthesize a
        // legacy binding from child labels or model arguments.
        let validComposerIdentity = request.composerMode != nil
            && ChildDeletionReviewPreparationContext.current?.matches(request) == true
        guard request.toolName == "file_delete", case let .childTask(taskID, parentID)? = request.source,
              request.taskID == taskID, !parentID.isEmpty, validBoundIdentity || validComposerIdentity,
              let sessionID = request.sessionID,
              let preview = request.filePreview, preview.available,
              let version = preview.version else { return result(.notChildDeletion) }
        let path = URL(fileURLWithPath: version.canonicalPath).standardizedFileURL
        guard !path.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return result(.unsafePath)
        }
        guard !preview.isSensitive, !Self.permissionRelated(path) else { return result(.permissionRelated) }
        guard let root = configuration.whitelistDirectories.first(where: {
            let root = $0.standardizedFileURL
            return root.isFileURL && root == root.resolvingSymlinksInPath()
                && path.path.hasPrefix(root.path + "/")
        }) else { return result(.outsideWhitelist) }
        guard let checkpointStore, let checkpointID,
              let before = try? checkpointStore.verifiedDeletionBackup(checkpointID, path: path, sessionID: sessionID)
        else { return result(.checkpointUnavailable) }
        guard (try? preview.validateCurrent()) != nil else { return result(.fileChanged) }
        guard !Task.isCancelled else { return result(.cancelled) }
        guard let recordSink else { return result(.journalUnavailable) }
        let relativePath = String(path.path.dropFirst(root.standardizedFileURL.path.count + 1))
        let input = ChildDeletionClassifierInput(relativePath: relativePath, byteCount: before.byteCount)
        let timeout = configuration.timeout.isFinite ? min(max(configuration.timeout, 0.01), 60) : 10
        let outcome = await classifyWithinDeadline(input, timeout: timeout)
        let reason: ChildDeletionReviewReason
        switch outcome {
        case .verdict(.allowRecoverableDeletion): reason = .independentRecommendation
        case .verdict(.requireHuman): reason = .modelRequiresHuman
        case .failed: reason = .classifierFailed
        case .timedOut: reason = .timedOut
        case .cancelled: reason = .cancelled
        }
        guard !Task.isCancelled else { return result(.cancelled) }
        guard reason == .independentRecommendation else {
            let fallback = result(reason)
            try? await recordSink(fallback.record)
            return fallback
        }
        guard (try? preview.validateCurrent()) != nil,
              (try? checkpointStore.verifiedDeletionBackup(checkpointID, path: path, sessionID: sessionID)) == before
        else { return result(.fileChanged) }
        let recommendation = result(.independentRecommendation, recommends: true)
        do { try await recordSink(recommendation.record) }
        catch { return result(.journalUnavailable) }
        // A durable sink can suspend. It cannot hide changes made while saving.
        guard !Task.isCancelled else { return result(.cancelled) }
        guard (try? preview.validateCurrent()) != nil,
              (try? checkpointStore.verifiedDeletionBackup(checkpointID, path: path, sessionID: sessionID)) == before
        else { return result(.fileChanged) }
        return recommendation
    }

    private static func permissionRelated(_ path: URL) -> Bool {
        let parts = path.pathComponents.map { $0.lowercased() }
        let name = parts.last ?? ""
        return SensitiveFilePolicy.isSensitive(path)
            || parts.contains(".codex") || parts.contains(".agents") || parts.contains(".claude")
            || ["agents.md", "permissions.json", "policy.json", "mcp.json", "settings.json", "config.toml"].contains(name)
    }

    private enum ClassificationOutcome: Sendable {
        case verdict(ChildDeletionModelVerdict), failed, timedOut, cancelled
    }
    /// Late/noncooperative provider responses are discarded. They cannot renew
    /// a timed-out request or issue any approval in the background.
    private final class ClassificationRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ClassificationOutcome, Never>?
        private var outcome: ClassificationOutcome?
        private var tasks: [Task<Void, Never>] = []
        func install(_ waiter: CheckedContinuation<ClassificationOutcome, Never>) {
            lock.lock()
            if let outcome { lock.unlock(); waiter.resume(returning: outcome) }
            else { continuation = waiter; lock.unlock() }
        }
        func installTasks(_ newTasks: [Task<Void, Never>]) {
            lock.lock()
            if outcome != nil { lock.unlock(); newTasks.forEach { $0.cancel() } }
            else { tasks = newTasks; lock.unlock() }
        }
        func finish(_ value: ClassificationOutcome) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            outcome = value
            let waiter = continuation; continuation = nil
            let running = tasks; tasks = []
            lock.unlock()
            running.forEach { $0.cancel() }
            waiter?.resume(returning: value)
        }
    }

    private func classifyWithinDeadline(_ input: ChildDeletionClassifierInput,
        timeout: TimeInterval) async -> ClassificationOutcome {
        let race = ClassificationRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                race.install(waiter)
                guard !Task.isCancelled else { race.finish(.cancelled); return }
                let classifier = self.classifier
                let work = Task {
                    do { race.finish(.verdict(try await classifier.classify(input))) }
                    catch is CancellationError { race.finish(.cancelled) }
                    catch { race.finish(.failed) }
                }
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(timeout)) }
                    catch { return }
                    if !Task.isCancelled { race.finish(.timedOut) }
                }
                race.installTasks([work, deadline])
            }
        } onCancel: { race.finish(.cancelled) }
    }
}


/// Installed only by the Core call owner while its existing physical-file lock
/// is held and a real durable deletion checkpoint has already been prepared.
/// This carries existing storage identity, never a caller asserted recovery Bool.
public struct ChildDeletionReviewPreparation: Sendable {
    let store: FileCheckpointStore
    let checkpointID: UUID
    let approvalContext: ApprovalPresentationContext?
    init(store: FileCheckpointStore, checkpointID: UUID, approvalContext: ApprovalPresentationContext? = nil) {
        self.store = store; self.checkpointID = checkpointID; self.approvalContext = approvalContext
    }
    func matches(_ request: ApprovalRequest) -> Bool {
        approvalContext?.makeFact(for: request, stage: .presented) != nil
    }
    func matches(_ receipt: ToolExecutionReceipt) -> Bool {
        guard let approvalContext else { return false }
        return receipt.compositeKey == approvalContext.compositeKey
            && receipt.executionIdentity == approvalContext.executionIdentity
            && receipt.toolName == approvalContext.toolName
    }
}
public enum ChildDeletionReviewPreparationContext {
    @TaskLocal public static var current: ChildDeletionReviewPreparation?
}

/// Decorates the exact existing human delegate. The original ApprovalGate still
/// validates binding, policy, cancellation, expiry, and consumes its own receipt.
/// No production call installs preparation until the lock/checkpoint hook exists.
public protocol ChildDeletionReviewPreparationDemand: ApprovalDelegate {
    var requiresDeletionPreparation: Bool { get }
}

public struct ChildDeletionApprovalDelegate: ChildDeletionReviewPreparationDemand {
    public var requiresDeletionPreparation: Bool {
        reviewer.configuration.enabled && !reviewer.configuration.whitelistDirectories.isEmpty
    }
    private let manualDelegate: any ApprovalDelegate
    private let reviewer: ChildDeletionReviewer
    /// Read-only view of the configuration this delegate was built with, so the
    /// App composition can be checked without reaching into the reviewer.
    public var reviewConfiguration: ChildDeletionReviewConfiguration { reviewer.configuration }
    public init(manualDelegate: any ApprovalDelegate, reviewer: ChildDeletionReviewer) {
        self.manualDelegate = manualDelegate; self.reviewer = reviewer
    }
    public func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        guard let preparation = ChildDeletionReviewPreparationContext.current,
              preparation.matches(request) else {
            return await manualDelegate.requestApproval(request)
        }
        let result = await reviewer.review(request: request, checkpointStore: preparation.store,
            checkpointID: preparation.checkpointID)
        guard result.recommendsRecoverableDeletion, !Task.isCancelled else {
            return await manualDelegate.requestApproval(request)
        }
        // Return through the original gate, never dispatch the file tool here.
        return ApprovalDecision(approved: true,
            reason: "独立删除审查允许；已记录可撤销检查点", confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest,
            filePreview: request.filePreview)
    }
}


public extension ChildDeletionReviewer {
    /// Only the current canonical prepared checkpoint may receive the metadata
    /// record. No active-session lookup or second journal store is involved.
    static let durableCheckpointRecordSink: @Sendable (ChildDeletionReviewRecord) async throws -> Void = { record in
        guard let preparation = ChildDeletionReviewPreparationContext.current,
              record.checkpointID == preparation.checkpointID else {
            throw FileCheckpointStore.Failure.invalidRecord
        }
        try preparation.store.recordDeletionReview(record)
    }
}
