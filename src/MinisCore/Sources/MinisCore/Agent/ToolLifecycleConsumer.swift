import Foundation
import Darwin

public enum ToolLifecycleConsumerError: Error, Equatable, Sendable {
    case corruptPersistence
    case persistenceFailed
}

public struct ToolLifecyclePersistenceMetrics: Equatable, Sendable {
    public let journalAppendCount: Int
    public let journalAppendBytes: Int64
    public let snapshotWriteCount: Int
    public let snapshotWriteBytes: Int64

    public var totalWriteCount: Int {
        journalAppendCount + snapshotWriteCount
    }

    public var totalBytes: Int64 {
        journalAppendBytes + snapshotWriteBytes
    }
}

/// Serializes writer transactions on Swift's structured concurrency runtime.
/// Unlike a continuation hop onto a low-QoS DispatchQueue, an awaited actor
/// job participates in task priority and forward-progress accounting.
private actor ToolLifecycleWriterExecutor {
    func perform<Result: Sendable>(_ operation: @Sendable () -> Result) -> Result {
        operation()
    }
}

/// The single canonical consumer for producer-owned tool facts.
///
/// The ingest path validates immutable input, then hands the complete
/// projection/persistence transaction to one serial actor. Sequence
/// allocation, journal append, compaction, and canonical state publication can
/// therefore never overlap or reenter while file I/O is suspended.
public final class ToolLifecycleConsumer: @unchecked Sendable {
    private static let schemaVersion = 1
    private static let defaultCompactionInterval = 1024
    // Keep journal recovery bounded by the existing persisted-payload limit.
    // A journal is compacted before this limit in normal operation; the same
    // limit prevents an untrusted recovery file from becoming an allocation
    // request during initialization.
    private static let maxJournalBytes = Int64(CompactionCheckpoint.maxPersistedBytes)
    // Snapshot recovery uses the same finite persisted-payload budget as the
    // existing checkpoint domain. The writer checks this budget before an
    // atomic replacement, so a produced snapshot is always reloadable.
    private static let maxSnapshotBytes = Int64(CompactionCheckpoint.maxPersistedBytes)

    private struct PersistedState: Codable {
        let schemaVersion: Int
        let events: [ConversationEvent]
    }

    private struct JournalRecord: Codable, Sendable {
        let schemaVersion: Int
        let event: ConversationEvent
    }

    private struct StableFileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modificationSeconds = Int64(info.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changeSeconds = Int64(info.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    private enum PersistenceOutcome {
        case appended(appendBytes: Int, snapshotBytes: Int)
        case compacted(appendBytes: Int, snapshotBytes: Int)
        case failed
    }

    /// Fast read-only projection for App/UI consumers. The serial writer is the
    /// only publisher; readers never wait behind journal or compaction I/O.
    private final class ReadSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var projection: ConversationEventProjection
        private var metrics: ToolLifecyclePersistenceMetrics

        init(
            projection: ConversationEventProjection,
            metrics: ToolLifecyclePersistenceMetrics
        ) {
            self.projection = projection
            self.metrics = metrics
        }

        var events: [ConversationEvent] {
            lock.lock()
            defer { lock.unlock() }
            return projection.events
        }

        var readOnlyProjection: ConversationEventProjection {
            lock.lock()
            defer { lock.unlock() }
            return projection
        }

        var persistenceMetrics: ToolLifecyclePersistenceMetrics {
            lock.lock()
            defer { lock.unlock() }
            return metrics
        }

        func publish(
            projection: ConversationEventProjection,
            metrics: ToolLifecyclePersistenceMetrics
        ) {
            lock.lock()
            self.projection = projection
            self.metrics = metrics
            lock.unlock()
        }
    }

    private let persistenceURL: URL?
    private let journalURL: URL?
    private let compactionInterval: Int
    private let writerExecutor = ToolLifecycleWriterExecutor()
    private let readSnapshot: ReadSnapshot

    // Canonical mutable state. Access is restricted to writerExecutor.
    private var writerProjection: ConversationEventProjection
    private var writerSequence: Int64
    private var writerJournalEventCount: Int
    private var writerJournalAppendCount = 0
    private var writerJournalAppendBytes: Int64 = 0
    private var writerSnapshotWriteCount = 0
    private var writerSnapshotWriteBytes: Int64 = 0

    public init() {
        let projection = ConversationEventProjection()
        persistenceURL = nil
        journalURL = nil
        compactionInterval = Self.defaultCompactionInterval
        writerProjection = projection
        writerSequence = 0
        writerJournalEventCount = 0
        readSnapshot = ReadSnapshot(
            projection: projection,
            metrics: Self.zeroMetrics
        )
    }

    public init(
        persistenceURL: URL,
        compactionInterval: Int = 1024
    ) throws {
        let standardizedURL = persistenceURL.standardizedFileURL
        let journalURL = Self.journalURL(for: standardizedURL)

        var restoredProjection = ConversationEventProjection()
        if let data = try Self.readStableRegularFileData(
            at: standardizedURL,
            maxBytes: Self.maxSnapshotBytes
        ) {
            let stored: PersistedState
            do {
                stored = try Self.decoder().decode(PersistedState.self, from: data)
            } catch {
                throw ToolLifecycleConsumerError.corruptPersistence
            }
            guard stored.schemaVersion == Self.schemaVersion else {
                throw ToolLifecycleConsumerError.corruptPersistence
            }
            restoredProjection = ConversationEventProjection(events: stored.events)
            guard restoredProjection.events == stored.events else {
                throw ToolLifecycleConsumerError.corruptPersistence
            }
        }

        let snapshotSequence = restoredProjection.events.map(\.sequence).max() ?? 0
        let journal = try Self.loadJournal(at: journalURL, after: snapshotSequence)
        let journalEvents = journal.events
        // Compaction may fold earlier phases out of the snapshot. Their
        // validated journal records are already covered by its high water mark.
        for event in journalEvents where event.sequence > snapshotSequence {
            guard restoredProjection.ingest(event) else {
                throw ToolLifecycleConsumerError.corruptPersistence
            }
        }
        if let recovery = journal.recovery {
            // Repair only after every complete record and the restored
            // projection have validated. Leave rejected evidence untouched.
            guard try Self.readStableRegularFileData(
                at: journalURL,
                maxBytes: Self.maxJournalBytes
            ) == recovery.original else {
                throw ToolLifecycleConsumerError.corruptPersistence
            }
            do {
                try recovery.prefix.write(to: journalURL, options: [.atomic])
            } catch {
                throw ToolLifecycleConsumerError.persistenceFailed
            }
        }
        self.persistenceURL = standardizedURL
        self.journalURL = journalURL
        self.compactionInterval = max(1, compactionInterval)
        writerProjection = restoredProjection
        writerSequence = restoredProjection.events.map(\.sequence).max() ?? 0
        writerJournalEventCount = journalEvents.count
        readSnapshot = ReadSnapshot(
            projection: restoredProjection,
            metrics: Self.zeroMetrics
        )
    }

    public var events: [ConversationEvent] {
        readSnapshot.events
    }

    public var readOnlyProjection: ConversationEventProjection {
        readSnapshot.readOnlyProjection
    }

    public var toolLifecycleEvents: [ConversationEvent] {
        events.filter { $0.kind == .tool }
    }

    public var isDurable: Bool {
        persistenceURL != nil
    }

    public var persistenceMetrics: ToolLifecyclePersistenceMetrics {
        readSnapshot.persistenceMetrics
    }

    /// Publish receipt-free progress using the existing canonical tool journal.
    /// A late phase cannot replace a terminal fact for the same composite key.
    @discardableResult
    public func ingestToolExecutionPhase(
        _ phase: ToolExecutionPhaseFact,
        eventID: String,
        eventName: String,
        taskID: String,
        expectedAttemptID: String,
        scopeID: String
    ) async -> Bool {
        let key = phase.compositeKey
        let execution = phase.executionIdentity
        let toolName = phase.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isValid, execution.isValid, !toolName.isEmpty,
              key.sessionID == execution.turn.sessionID,
              key.turnID == execution.turn.turnID,
              key.messageID == execution.turn.messageID,
              key.operationID == execution.operationID,
              key.attemptID == expectedAttemptID,
              key.attemptNumber == execution.attempt,
              key.toolCallID == eventID,
              toolName == eventName,
              !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let identity = ConversationEventIdentity(
                sessionID: key.sessionID,
                turnID: String(key.turnID),
                taskID: taskID,
                attempt: key.attemptNumber,
                scopeID: scopeID
              ) else { return false }
        let status: ConversationEventStatus = phase.phase == .queued ? .queued : .running
        return await writerExecutor.perform { [self] in
            let proposedSequence = writerSequence + 1
            let event = ConversationEvent(
                id: key.rawValue,
                identity: identity,
                sequence: proposedSequence,
                occurredAt: phase.occurredAt,
                kind: .tool,
                status: status,
                summary: status == .queued ? "工具排队：\(toolName)" : "工具运行：\(toolName)",
                toolName: toolName,
                toolCallID: key.toolCallID,
                toolCompositeKey: key
            )
            return commitOnWriter(event: event, proposedSequence: proposedSequence)
        }
    }

    /// Ingest one producer-owned terminal tool fact.
    ///
    /// Validation is immutable and may run on any caller executor. All
    /// canonical mutation and durable I/O is serialized by writerExecutor.
    @discardableResult
    public func ingestToolExecutionFact(
        _ fact: ToolExecutionFact,
        eventID: String,
        eventName: String,
        taskID: String,
        expectedAttemptID: String,
        scopeID: String,
        occurredAt: Date = Date(),
        toolTargetDisplay: String? = nil,
        liveFailureFeedback: ToolExecutionLiveFailureFeedback? = nil
    ) async -> Bool {
        // A bare fact carries no measured execution interval; only a settled
        // `ToolRunResult` can. Elapsed stays nil so the projection renders
        // 「耗时 未记录」 rather than a fabricated duration.
        await ingestToolExecutionFact(
            fact,
            eventID: eventID,
            eventName: eventName,
            taskID: taskID,
            expectedAttemptID: expectedAttemptID,
            scopeID: scopeID,
            occurredAt: occurredAt,
            elapsedMilliseconds: fact.elapsedMilliseconds,
            toolTargetDisplay: toolTargetDisplay,
            liveFailureFeedback: liveFailureFeedback
        )
    }

    /// Shared validation and ingestion core. `elapsedMilliseconds` must be a
    /// processing duration measured by the executor-side owner, never an
    /// "already elapsed" relative timestamp.
    @discardableResult
    private func ingestToolExecutionFact(
        _ fact: ToolExecutionFact,
        eventID: String,
        eventName: String,
        taskID: String,
        expectedAttemptID: String,
        scopeID: String,
        occurredAt: Date,
        elapsedMilliseconds: Int?,
        toolTargetDisplay: String? = nil,
        liveFailureFeedback: ToolExecutionLiveFailureFeedback? = nil
    ) async -> Bool {
        let callID = fact.toolCallID.trimmingCharacters(in: .whitespacesAndNewlines)
        let receiptID = fact.receiptID.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = fact.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let attemptID = fact.attemptID.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventName = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedAttemptID = expectedAttemptID.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeID = scopeID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !callID.isEmpty,
              callID != "agent-loop",
              !receiptID.isEmpty,
              !toolName.isEmpty,
              !attemptID.isEmpty,
              !taskID.isEmpty,
              !expectedAttemptID.isEmpty,
              !scopeID.isEmpty,
              callID == eventID,
              toolName == eventName,
              attemptID == expectedAttemptID,
              fact.attemptNumber > 0,
              let executionIdentity = fact.executionIdentity,
              executionIdentity.isValid,
              executionIdentity.attempt == fact.attemptNumber,
              let compositeKey = fact.compositeKey,
              compositeKey.isValid,
              compositeKey.sessionID == executionIdentity.turn.sessionID,
              compositeKey.turnID == executionIdentity.turn.turnID,
              compositeKey.messageID == executionIdentity.turn.messageID,
              compositeKey.operationID == executionIdentity.operationID,
              compositeKey.attemptID == attemptID,
              compositeKey.attemptNumber == fact.attemptNumber,
              compositeKey.toolCallID == callID
        else {
            return false
        }

        guard let identity = ConversationEventIdentity(
            sessionID: executionIdentity.turn.sessionID,
            turnID: String(executionIdentity.turn.turnID),
            taskID: taskID,
            attempt: fact.attemptNumber,
            scopeID: scopeID
        ) else {
            return false
        }

        let status: ConversationEventStatus
        switch fact.status {
        case .succeeded:
            status = .succeeded
        case .failed:
            status = .failed
        case .cancelled:
            status = .cancelled
        }
        let isFailure = fact.status == .failed
        // Only the canonical browser tools may project a browser detail. The
        // detail is already bounded to fixed labels/codes by AgentProvider.
        let readPermissionRefusal = liveFailureFeedback.map { feedback in
            feedback.compositeKey == compositeKey && feedback.receiptID == receiptID
                && feedback.executionIdentity == executionIdentity
                && fact.toolName == "file_read" && fact.status == .failed
                && fact.elapsedMilliseconds != nil
                && feedback.reason == .builtinFileReadPermissionDenied
        } ?? false
        let browserDetail = (
            toolName == BrowserTool.toolName || toolName == BrowserTool.legacyToolName
        ) ? fact.browserDetail : nil

        return await writerExecutor.perform { [self] in
            ingestOnWriter(
                receiptID: receiptID,
                identity: identity,
                status: status,
                toolName: toolName,
                toolCallID: callID,
                compositeKey: compositeKey,
                browserDetail: browserDetail,
                outputSummary: fact.outputSummary,
                readPermissionRefusal: readPermissionRefusal,
                isFailure: isFailure,
                failureCategory: fact.failureCategory,
                occurredAt: occurredAt,
                elapsedMilliseconds: elapsedMilliseconds,
                toolTargetDisplay: toolTargetDisplay
            )
        }
    }

    /// Consume the terminal result emitted by `ConcurrentToolRunner` without
    /// allowing its transport payload to become a second source of truth.
    ///
    /// The settled `ToolExecutionFact` remains the canonical identity/status
    /// authority. The runner result is accepted only when its invocation,
    /// terminal state, and payload shape agree with that fact; duplicate,
    /// late, or forged result identities therefore fail closed at the same
    /// projection boundary as direct fact ingestion.
    @discardableResult
    public func ingestToolRunResult(
        _ result: ToolRunResult,
        fact: ToolExecutionFact,
        taskID: String,
        expectedAttemptID: String,
        scopeID: String,
        occurredAt: Date = Date()
    ) async -> Bool {
        let invocationName = result.invocation.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.hasExactlyOneTerminalPayload,
              !invocationName.isEmpty,
              result.invocationIdentity == fact.toolCallID,
              invocationName == fact.toolName,
              result.terminalStatus == fact.status
        else {
            return false
        }

        return await ingestToolExecutionFact(
            fact,
            eventID: fact.toolCallID,
            eventName: fact.toolName,
            taskID: taskID,
            expectedAttemptID: expectedAttemptID,
            scopeID: scopeID,
            occurredAt: occurredAt,
            // Only a started execution carries a measured interval; the
            // producer leaves rejected/never-run invocations at nil.
            elapsedMilliseconds: fact.elapsedMilliseconds ?? result.elapsedMilliseconds
        )
    }

    /// Accept only an observation bound to the original call. An authority
    /// outcome needs the already-journaled true UI presentation; an automatic
    /// gate result or a rejected UI presentation cannot invent waiting.
    @discardableResult
    public func ingestApprovalLifecycleFact(_ fact: ApprovalLifecycleFact) async -> Bool {
        let key = fact.compositeKey
        let execution = fact.executionIdentity
        guard key.isValid, execution.isValid,
              key.sessionID == execution.turn.sessionID,
              key.turnID == execution.turn.turnID,
              key.messageID == execution.turn.messageID,
              key.operationID == execution.operationID,
              key.attemptNumber == execution.attempt,
              !fact.requestID.isEmpty, !fact.identityDigest.isEmpty,
              !fact.toolName.isEmpty, !fact.taskID.isEmpty, !fact.scopeID.isEmpty,
              let identity = ConversationEventIdentity(
                sessionID: key.sessionID,
                turnID: String(key.turnID),
                taskID: fact.taskID,
                attempt: key.attemptNumber,
                scopeID: fact.scopeID
              ) else { return false }
        return await writerExecutor.perform { [self] in
            if fact.stage != .presented {
                guard writerProjection.events.contains(where: {
                    $0.kind == .approval && $0.status == .waiting &&
                    $0.identity == identity && $0.receiptID == fact.requestID &&
                    $0.approvalCompositeKey == key &&
                    $0.approvalIdentityDigest == fact.identityDigest
                }) else { return false }
            }
            let projection = Self.approvalLifecycleProjection(for: fact.stage)
            let proposedSequence = writerSequence + 1
            let event = ConversationEvent(
                id: Self.approvalEventID(
                    key: key, requestID: fact.requestID, digest: fact.identityDigest
                ),
                identity: identity,
                sequence: proposedSequence,
                occurredAt: fact.occurredAt,
                kind: .approval,
                status: projection.status,
                summary: "\(projection.summary)：\(fact.toolName)",
                toolName: fact.toolName,
                toolCallID: key.toolCallID,
                approvalCompositeKey: key,
                approvalIdentityDigest: fact.identityDigest,
                receiptID: fact.requestID,
                approvalDecision: projection.decision,
                errorCategory: projection.errorCategory
            )
            return commitOnWriter(event: event, proposedSequence: proposedSequence)
        }
    }

    private static func approvalEventID(
        key: ToolExecutionCompositeKey,
        requestID: String,
        digest: String
    ) -> String {
        [key.rawValue, requestID, digest].map { "\($0.utf8.count)#\($0)" }.joined()
    }

    private static func approvalLifecycleProjection(
        for stage: ApprovalLifecycleStage
    ) -> (
        status: ConversationEventStatus,
        decision: ConversationApprovalDecision,
        errorCategory: ConversationEventErrorCategory?,
        summary: String
    ) {
        switch stage {
        case .presented: return (.waiting, .requested, nil, "等待审批")
        case .authorityApproved: return (.succeeded, .approved, nil, "审批通过")
        case .authorityDenied: return (.failed, .denied, .authorization, "审批拒绝")
        case .authorityExpired: return (.failed, .expired, .timeout, "审批已过期")
        case .authorityCancelled: return (.cancelled, .cancelled, .cancelled, "审批已取消")
        case .authorityRevoked: return (.blocked, .revoked, .authorization, "审批授权已撤销")
        }
    }

    /// Call once at a new composition-root startup before any new UI prompt.
    /// The old continuation no longer exists after process death; the durable
    /// pending card is closed as interrupted, never revived as an approval.
    @discardableResult
    public func invalidateRecoveredApprovalWaiting() async -> Int {
        guard persistenceURL != nil else { return 0 }
        return await writerExecutor.perform { [self] in
            var closed = 0
            let pending = writerProjection.events.filter {
                $0.kind == .approval && $0.status == .waiting &&
                $0.approvalCompositeKey != nil && $0.approvalIdentityDigest != nil
            }
            for old in pending {
                let proposedSequence = writerSequence + 1
                let event = ConversationEvent(
                    id: old.id,
                    identity: old.identity,
                    sequence: proposedSequence,
                    occurredAt: Date(),
                    kind: .approval,
                    status: .stopped,
                    summary: "审批中断：\(old.toolName ?? "工具")",
                    toolName: old.toolName,
                    toolCallID: old.toolCallID,
                    approvalCompositeKey: old.approvalCompositeKey,
                    approvalIdentityDigest: old.approvalIdentityDigest,
                    receiptID: old.receiptID,
                    approvalDecision: .interrupted,
                    errorCategory: .cancelled
                )
                if commitOnWriter(event: event, proposedSequence: proposedSequence) {
                    closed += 1
                }
            }
            return closed
        }
    }

    /// Ingest one canonical approval fact pair and publish it as an `.approval`
    /// conversation event — the only producer of the kind that
    /// `ConversationEventProjection.approvalHistory` consumes.
    ///
    /// The pair is the same material `ApprovalGate.validated` accepts before it
    /// authorizes an effect, so no event can describe an approval the gate
    /// itself would not have honored:
    /// * the request must actually require approval — a call that was never
    ///   gated produces no approval fact,
    /// * the request must carry the full conversation identity
    ///   (`sessionID`/`turnID`/`taskID`/`attemptID`/`approvalScope`); a legacy
    ///   identity-less request is rejected instead of being padded with a
    ///   synthetic lineage,
    /// * `attempt` is the caller's claim about which attempt was gated and must
    ///   be positive; approval facts carry no numeric attempt themselves, so it
    ///   is never derived or defaulted,
    /// * a decision that names a different request, or a bound request whose
    ///   digest the decision does not carry, is dropped,
    /// * an approved decision whose grant had already expired at `occurredAt`
    ///   is dropped rather than recorded as an approval,
    /// * `.revoked` has no faithful `ConversationApprovalDecision` case and is
    ///   therefore not projected at all; the kind stays absent instead of
    ///   being relabelled as a denial.
    ///
    /// Approval facts carry no measured duration, so `elapsedMilliseconds` and
    /// `retryEnvelope` stay nil and the projection keeps rendering 耗时 未记录.
    @discardableResult
    public func ingestApprovalDecision(
        _ decision: ApprovalDecision,
        for request: ApprovalRequest,
        attempt: Int,
        occurredAt: Date = Date()
    ) async -> Bool {
        let callID = request.callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let receiptID = request.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = request.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = request.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskID = request.taskID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attemptID = request.attemptID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeID = request.approvalScope?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard request.requiresApproval,
              attempt > 0,
              !callID.isEmpty,
              callID != "agent-loop",
              !receiptID.isEmpty,
              !toolName.isEmpty,
              let sessionID, !sessionID.isEmpty,
              let turnID = request.turnID,
              let taskID, !taskID.isEmpty,
              let attemptID, !attemptID.isEmpty,
              let scopeID, !scopeID.isEmpty else {
            return false
        }

        guard let facts = Self.approvalEventFacts(
            for: decision,
            request: request,
            occurredAt: occurredAt
        ) else {
            return false
        }

        guard let identity = ConversationEventIdentity(
            sessionID: sessionID,
            turnID: String(turnID),
            taskID: taskID,
            attempt: attempt,
            scopeID: scopeID
        ) else {
            return false
        }

        return await writerExecutor.perform { [self] in
            ingestApprovalOnWriter(
                identity: identity,
                toolName: toolName,
                toolCallID: callID,
                receiptID: receiptID,
                approvalDecision: facts.approvalDecision,
                status: facts.status,
                errorCategory: facts.errorCategory,
                occurredAt: occurredAt
            )
        }
    }

    /// Maps an approval decision onto the event's decision/status/category.
    /// Returns nil when the pair carries no faithful conversation-event fact.
    /// Mirrors `ApprovalGate.validated`'s rejection order and stays stricter
    /// than it: contradictory approved/non-approved pairs never publish.
    private static func approvalEventFacts(
        for decision: ApprovalDecision,
        request: ApprovalRequest,
        occurredAt: Date
    ) -> (
        approvalDecision: ConversationApprovalDecision,
        status: ConversationEventStatus,
        errorCategory: ConversationEventErrorCategory?
    )? {
        if let decisionRequestID = decision.requestID,
           decisionRequestID != request.requestID {
            return nil
        }
        if let digest = decision.bindingDigest, digest != request.identityDigest {
            return nil
        }
        if request.binding != nil {
            // A durable effect may only be authorized by a decision that names
            // this request and carries its identity digest.
            guard decision.requestID == request.requestID,
                  let digest = decision.bindingDigest,
                  digest == request.identityDigest else {
                return nil
            }
        }

        switch (decision.approved, decision.status) {
        case (true, .approved):
            guard !request.requiresSecondConfirmation || decision.confirmed else {
                // L3 without the explicit second confirmation: the real fact is
                // "waiting for the user to review", not an approval.
                return (.requested, .needsReview, .review)
            }
            guard let expiresAt = request.expiresAt else {
                return (.approved, .succeeded, nil)
            }
            // An expired grant cannot be recorded as an approval the user gave.
            return expiresAt > occurredAt ? (.approved, .succeeded, nil) : nil
        case (false, .approved), (false, .denied):
            return (.denied, .failed, .authorization)
        case (false, .expired):
            return (.expired, .failed, .timeout)
        case (false, .cancelled):
            return (.cancelled, .cancelled, .cancelled)
        case (true, .cancelled), (true, .denied), (true, .expired),
             (_, .revoked):
            // No faithful approval-event fact for these pairs; keep the kind absent.
            return nil
        }
    }

    private func ingestApprovalOnWriter(
        identity: ConversationEventIdentity,
        toolName: String,
        toolCallID: String,
        receiptID: String,
        approvalDecision: ConversationApprovalDecision,
        status: ConversationEventStatus,
        errorCategory: ConversationEventErrorCategory?,
        occurredAt: Date
    ) -> Bool {
        let summary: String
        switch approvalDecision {
        case .requested: summary = "等待审批复核：\(toolName)"
        case .approved: summary = "审批通过：\(toolName)"
        case .denied: summary = "审批拒绝：\(toolName)"
        case .expired: summary = "审批已过期：\(toolName)"
        case .cancelled: summary = "审批已取消：\(toolName)"
        case .revoked: summary = "审批授权已撤销：\(toolName)"
        case .interrupted: summary = "审批中断：\(toolName)"
        }

        let proposedSequence = writerSequence + 1
        let event = ConversationEvent(
            id: receiptID,
            identity: identity,
            sequence: proposedSequence,
            occurredAt: occurredAt,
            kind: .approval,
            status: status,
            summary: summary,
            toolName: toolName,
            toolCallID: toolCallID,
            receiptID: receiptID,
            approvalDecision: approvalDecision,
            errorCategory: errorCategory
        )
        return commitOnWriter(event: event, proposedSequence: proposedSequence)
    }

    /// Shared canonical publication for a validated event: ingest into the
    /// writer projection, then journal/snapshot exactly as the tool path does.
    /// A failed append never becomes visible in memory.
    private func commitOnWriter(
        event: ConversationEvent,
        proposedSequence: Int64
    ) -> Bool {
        var candidate = writerProjection
        guard candidate.ingest(event) else {
            return false
        }

        guard let persistenceURL, let journalURL else {
            publishOnWriter(
                projection: candidate,
                sequence: proposedSequence,
                outcome: nil
            )
            return true
        }

        let shouldCompact = writerJournalEventCount + 1 >= compactionInterval
        let outcome = Self.persist(
            event: event,
            candidate: shouldCompact ? candidate : nil,
            persistenceURL: persistenceURL,
            journalURL: journalURL
        )
        guard case .failed = outcome else {
            publishOnWriter(
                projection: candidate,
                sequence: proposedSequence,
                outcome: outcome
            )
            return true
        }
        return false
    }

    private func ingestOnWriter(
        receiptID: String,
        identity: ConversationEventIdentity,
        status: ConversationEventStatus,
        toolName: String,
        toolCallID: String,
        compositeKey: ToolExecutionCompositeKey,
        browserDetail: BrowserToolExecutionDetail?,
        outputSummary: ToolOutputSummary?,
        readPermissionRefusal: Bool,
        isFailure: Bool,
        failureCategory: ToolExecutionFailureCategory?,
        occurredAt: Date,
        elapsedMilliseconds: Int?,
        toolTargetDisplay: String? = nil
    ) -> Bool {
        let proposedSequence = writerSequence + 1
        let event = ConversationEvent(
            id: receiptID,
            identity: identity,
            sequence: proposedSequence,
            occurredAt: occurredAt,
            kind: .tool,
            status: status,
            summary: readPermissionRefusal
                ? "工具调用：file_read · 读取被拒绝：没有访问此文件的权限"
                : browserDetail.map { "浏览器动作：\($0.action)" }
                ?? outputSummary?.displaySuffix.map { "工具调用：\(toolName) · \($0)" }
                ?? "工具调用：\(toolName)",
            toolName: toolName,
            toolTargetDisplay: toolTargetDisplay,
            browserDetail: browserDetail,
            outputSummary: browserDetail == nil ? outputSummary : nil,
            toolCallID: toolCallID,
            toolCompositeKey: compositeKey,
            receiptID: receiptID,
            elapsedMilliseconds: elapsedMilliseconds,
            errorCategory: browserDetail?.outcome == "denied"
                ? .authorization
                : (isFailure ? (failureCategory == .timeout ? .timeout : .tool) : nil)
        )
        var candidate = writerProjection
        guard candidate.ingest(event) else {
            return false
        }

        guard let persistenceURL, let journalURL else {
            publishOnWriter(
                projection: candidate,
                sequence: proposedSequence,
                outcome: nil
            )
            return true
        }

        let shouldCompact = writerJournalEventCount + 1 >= compactionInterval
        let outcome = Self.persist(
            event: event,
            candidate: shouldCompact ? candidate : nil,
            persistenceURL: persistenceURL,
            journalURL: journalURL
        )
        guard case .failed = outcome else {
            publishOnWriter(
                projection: candidate,
                sequence: proposedSequence,
                outcome: outcome
            )
            return true
        }
        // The failed append never becomes visible in memory. A failed
        // compaction after a successful append is returned as `.appended`, so
        // the durable journal remains the recovery source and no event is lost.
        return false
    }

    private static func persist(
        event: ConversationEvent,
        candidate: ConversationEventProjection?,
        persistenceURL: URL,
        journalURL: URL
    ) -> PersistenceOutcome {
        let appendBytes: Int
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let record = JournalRecord(
                schemaVersion: Self.schemaVersion,
                event: event
            )
            var data = try Self.encoder().encode(record)
            data.append(0x0A)
            appendBytes = data.count
            try Self.append(data, to: journalURL)
        } catch {
            return .failed
        }

        guard let candidate else {
            return .appended(appendBytes: appendBytes, snapshotBytes: 0)
        }

        let snapshotData: Data
        do {
            let snapshot = PersistedState(
                schemaVersion: Self.schemaVersion,
                events: candidate.events
            )
            snapshotData = try Self.encoder().encode(snapshot)
            guard snapshotData.count <= Int(Self.maxSnapshotBytes) else {
                // The event is already durable in the journal. Keep that
                // source of truth and retry compaction on a later event.
                return .appended(appendBytes: appendBytes, snapshotBytes: 0)
            }
            try snapshotData.write(to: persistenceURL, options: [.atomic])
        } catch {
            // The journal append is already durable. Keep it as the recovery
            // source and retry compaction on a later event.
            return .appended(appendBytes: appendBytes, snapshotBytes: 0)
        }

        do {
            try Data().write(to: journalURL, options: [.atomic])
            return .compacted(
                appendBytes: appendBytes,
                snapshotBytes: snapshotData.count
            )
        } catch {
            // Snapshot and journal both contain the event. Reload de-duplicates
            // the overlap; the next event retries compaction.
            return .appended(
                appendBytes: appendBytes,
                snapshotBytes: snapshotData.count
            )
        }
    }

    private func publishOnWriter(
        projection: ConversationEventProjection,
        sequence: Int64,
        outcome: PersistenceOutcome?
    ) {
        writerProjection = projection
        writerSequence = sequence

        switch outcome {
        case .appended(let appendBytes, let snapshotBytes):
            writerJournalEventCount += 1
            writerJournalAppendCount += 1
            writerJournalAppendBytes += Int64(appendBytes)
            if snapshotBytes > 0 {
                writerSnapshotWriteCount += 1
                writerSnapshotWriteBytes += Int64(snapshotBytes)
            }
        case .compacted(let appendBytes, let snapshotBytes):
            writerJournalEventCount = 0
            writerJournalAppendCount += 1
            writerJournalAppendBytes += Int64(appendBytes)
            writerSnapshotWriteCount += 1
            writerSnapshotWriteBytes += Int64(snapshotBytes)
        case .failed:
            preconditionFailure("failed persistence cannot be published")
        case nil:
            break
        }

        readSnapshot.publish(
            projection: writerProjection,
            metrics: writerMetrics
        )
    }

    private var writerMetrics: ToolLifecyclePersistenceMetrics {
        ToolLifecyclePersistenceMetrics(
            journalAppendCount: writerJournalAppendCount,
            journalAppendBytes: writerJournalAppendBytes,
            snapshotWriteCount: writerSnapshotWriteCount,
            snapshotWriteBytes: writerSnapshotWriteBytes
        )
    }

    private static let zeroMetrics = ToolLifecyclePersistenceMetrics(
        journalAppendCount: 0,
        journalAppendBytes: 0,
        snapshotWriteCount: 0,
        snapshotWriteBytes: 0
    )

    private static func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw ToolLifecycleConsumerError.persistenceFailed
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func loadJournal(at url: URL, after snapshotSequence: Int64) throws -> (
        events: [ConversationEvent], recovery: (original: Data, prefix: Data)?
    ) {
        guard let data = try readStableRegularFileData(
            at: url,
            maxBytes: Self.maxJournalBytes
        ) else {
            return ([], nil)
        }
        guard !data.isEmpty else { return ([], nil) }

        // A crash can split the last UTF-8 code point. Frame bytes first;
        // every complete line still has to be valid UTF-8 and a closed record.
        let lines = data.split(
            separator: 0x0A,
            omittingEmptySubsequences: false
        )
        let completeLines = lines.dropLast()
        var events: [ConversationEvent] = []
        var journalProjection = ConversationEventProjection()
        for line in completeLines where !line.isEmpty {
            do {
                let recordData = Data(line)
                guard String(data: recordData, encoding: .utf8) != nil else {
                    throw ToolLifecycleConsumerError.corruptPersistence
                }
                let record = try decoder().decode(
                    JournalRecord.self,
                    from: recordData
                )
                guard record.schemaVersion == Self.schemaVersion else {
                    throw ToolLifecycleConsumerError.corruptPersistence
                }
                let sequence = record.event.sequence
                guard sequence > 0 else {
                    throw ToolLifecycleConsumerError.corruptPersistence
                }
                if let previous = events.last?.sequence {
                    guard previous < Int64.max, sequence == previous + 1 else {
                        throw ToolLifecycleConsumerError.corruptPersistence
                    }
                } else if sequence > snapshotSequence {
                    guard snapshotSequence < Int64.max, sequence == snapshotSequence + 1 else {
                        throw ToolLifecycleConsumerError.corruptPersistence
                    }
                }
                // Validate covered prefix records too; a checkpoint never
                // makes an unknown or malformed complete record ignorable.
                guard journalProjection.ingest(record.event) else {
                    throw ToolLifecycleConsumerError.corruptPersistence
                }
                events.append(record.event)
            } catch let error as ToolLifecycleConsumerError {
                throw error
            } catch {
                throw ToolLifecycleConsumerError.corruptPersistence
            }
        }
        guard data.last != 0x0A else { return (events, nil) }
        let prefixLength = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        return (events, (data, Data(data.prefix(prefixLength))))
    }

    private static func readStableRegularFileData(
        at url: URL,
        maxBytes: Int64
    ) throws -> Data? {
        var pathInfo = stat()
        guard Darwin.lstat(url.path, &pathInfo) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw ToolLifecycleConsumerError.corruptPersistence
        }
        guard isSafeRegularFile(pathInfo, maxBytes: maxBytes) else {
            throw ToolLifecycleConsumerError.corruptPersistence
        }
        let expectedIdentity = StableFileIdentity(pathInfo)

        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ToolLifecycleConsumerError.corruptPersistence
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }

        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              isSafeRegularFile(openedInfo, maxBytes: maxBytes),
              StableFileIdentity(openedInfo) == expectedIdentity else {
            throw ToolLifecycleConsumerError.corruptPersistence
        }

        let readLimit = Int(expectedIdentity.size) + 1
        let data = try handle.read(upToCount: readLimit) ?? Data()

        var finalDescriptorInfo = stat()
        guard Darwin.fstat(descriptor, &finalDescriptorInfo) == 0,
              isSafeRegularFile(finalDescriptorInfo, maxBytes: maxBytes),
              StableFileIdentity(finalDescriptorInfo) == expectedIdentity,
              data.count == Int(expectedIdentity.size) else {
            throw ToolLifecycleConsumerError.corruptPersistence
        }

        var finalPathInfo = stat()
        guard Darwin.lstat(url.path, &finalPathInfo) == 0,
              isSafeRegularFile(finalPathInfo, maxBytes: maxBytes),
              StableFileIdentity(finalPathInfo) == expectedIdentity else {
            throw ToolLifecycleConsumerError.corruptPersistence
        }
        return data
    }

    private static func isSafeRegularFile(_ info: stat, maxBytes: Int64) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && info.st_nlink == 1
            && info.st_size >= 0
            && info.st_size <= off_t(maxBytes)
    }

    private static func journalURL(for snapshotURL: URL) -> URL {
        snapshotURL.deletingPathExtension().appendingPathExtension("journal")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
