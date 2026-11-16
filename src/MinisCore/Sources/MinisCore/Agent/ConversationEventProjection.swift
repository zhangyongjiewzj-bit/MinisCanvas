import Foundation

public struct ConversationEventIdentity: Codable, Equatable, Hashable, Sendable {
    public let sessionID: String
    public let turnID: String
    public let taskID: String
    public let attempt: Int
    public let scopeID: String

    public init?(
        sessionID: String,
        turnID: String,
        taskID: String,
        attempt: Int,
        scopeID: String
    ) {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              attempt > 0 else {
            return nil
        }
        self.sessionID = sessionID
        self.turnID = turnID
        self.taskID = taskID
        self.attempt = attempt
        self.scopeID = scopeID
    }
}

public enum ConversationEventKind: String, Codable, CaseIterable, Sendable {
    case thinking
    case stop
    case duration
    case model
    case tool
    case approval
    case task

    public static let modelSwitch: Self = .model

    public var label: String {
        switch self {
        case .thinking: return "思考"
        case .stop: return "停止"
        case .duration: return "耗时"
        case .model: return "模型"
        case .tool: return "工具"
        case .approval: return "审批"
        case .task: return "任务"
        }
    }
}

public enum ConversationEventStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case requested
    case running
    case waiting
    case needsReview
    case succeeded
    case failed
    case cancelled
    case blocked
    case stopped

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .blocked, .stopped:
            return true
        case .queued, .requested, .running, .waiting, .needsReview:
            return false
        }
    }

    public var label: String {
        switch self {
        case .queued: return "排队中"
        case .requested: return "已请求"
        case .running: return "进行中"
        case .waiting: return "等待中"
        case .needsReview: return "需要复核"
        case .succeeded: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .blocked: return "已阻断"
        case .stopped: return "已停止"
        }
    }
}

public enum ConversationApprovalDecision: String, Codable, CaseIterable, Sendable {
    case requested
    case approved
    case denied
    case expired
    case cancelled
    case revoked
    case interrupted
}

public enum ConversationEventErrorCategory: String, Codable, CaseIterable, Sendable {
    case cancelled
    case timeout
    case authorization
    case provider
    case model
    case tool
    case network
    case validation
    case review
    case unknown
}

public enum ConversationEventRedactor {
    public static let maximumSummaryLength = 160
    public static let maximumFieldLength = 120

    public static func redact(_ summary: String, knownSecrets: [String] = []) -> String {
        let value = redactFieldValue(summary, maximumLength: maximumSummaryLength, knownSecrets: knownSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "事件更新" }

        return value
    }

    /// Redacts optional metadata before it crosses the UI boundary. Metadata
    /// can originate from provider/tool payloads just like an event summary.
    public static func redactField(_ value: String?, knownSecrets: [String] = []) -> String? {
        guard let value else { return nil }
        let redacted = redactFieldValue(value, maximumLength: maximumFieldLength, knownSecrets: knownSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? nil : redacted
    }

    private static func redactFieldValue(
        _ rawValue: String,
        maximumLength: Int,
        knownSecrets: [String]
    ) -> String {
        var value = ContentSecretRedactor.redact(rawValue, knownSecrets: knownSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        value = value.replacingOccurrences(
            of: #"https?://[^\s]+"#,
            with: "[remote resource]",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?<![A-Za-z0-9:])(?:/|~/)[^\s"'<>]+"#,
            with: "[local path]",
            options: .regularExpression
        )
        value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        guard value.count > maximumLength else { return value }
        return String(value.prefix(maximumLength - 3)) + "..."
    }
}

public struct ConversationEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let identity: ConversationEventIdentity
    public let sequence: Int64
    public let occurredAt: Date
    public let kind: ConversationEventKind
    public let status: ConversationEventStatus
    public let summary: String
    public let providerID: String?
    public let modelID: String?
    public let fromModelID: String?
    public let toModelID: String?
    public let toolName: String?
    /// Bounded, redacted target from the producing tool descriptor. Never raw
    /// command arguments; nil for old events or an unrecognized descriptor.
    public let toolTargetDisplay: String?
    /// Bounded structured browser result from the settled canonical tool fact.
    /// Optional so persisted events from older builds still decode.
    public let browserDetail: BrowserToolExecutionDetail?
    /// Content-free metrics/signals from the settled tool fact. This survives
    /// summary truncation and is never an authorization or success decision.
    /// Optional so persisted events from older builds still decode.
    public let outputSummary: ToolOutputSummary?
    /// Native tool-call identity. Callback event IDs may differ across
    /// retries, but one tool call must still project to one lifecycle record.
    public let toolCallID: String?
    /// Stable tool execution key; progress has no receipt until execution is minted.
    public let toolCompositeKey: ToolExecutionCompositeKey?
    /// Exact approval call and original request binding, never an authorization.
    public let approvalCompositeKey: ToolExecutionCompositeKey?
    public let approvalIdentityDigest: String?
    /// Opaque canonical receipt identity for a tool or approval fact.
    public let receiptID: String?
    /// Decision fact carried by an approval event; projection never derives it.
    public let approvalDecision: ConversationApprovalDecision?
    /// Frozen retry facts carried by a failed lifecycle event.
    public let retryEnvelope: ChatRetryEnvelope?
    public let elapsedMilliseconds: Int?
    public let errorCategory: ConversationEventErrorCategory?

    fileprivate var closesIdentity: Bool {
        (kind == .task || kind == .stop) && status.isTerminal
    }

    public init(
        id: String,
        identity: ConversationEventIdentity,
        sequence: Int64,
        occurredAt: Date,
        kind: ConversationEventKind,
        status: ConversationEventStatus,
        summary: String,
        providerID: String? = nil,
        modelID: String? = nil,
        fromModelID: String? = nil,
        toModelID: String? = nil,
        toolName: String? = nil,
        toolTargetDisplay: String? = nil,
        browserDetail: BrowserToolExecutionDetail? = nil,
        outputSummary: ToolOutputSummary? = nil,
        toolCallID: String? = nil,
        toolCompositeKey: ToolExecutionCompositeKey? = nil,
        approvalCompositeKey: ToolExecutionCompositeKey? = nil,
        approvalIdentityDigest: String? = nil,
        receiptID: String? = nil,
        approvalDecision: ConversationApprovalDecision? = nil,
        retryEnvelope: ChatRetryEnvelope? = nil,
        elapsedMilliseconds: Int? = nil,
        errorCategory: ConversationEventErrorCategory? = nil,
        knownSecrets: [String] = []
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identity = identity
        self.sequence = max(0, sequence)
        self.occurredAt = occurredAt
        self.kind = kind
        self.status = status
        self.summary = ConversationEventRedactor.redact(summary, knownSecrets: knownSecrets)
        self.providerID = providerID
        self.modelID = modelID
        self.fromModelID = fromModelID
        self.toModelID = toModelID
        self.toolName = toolName
        let safeTarget = toolTargetDisplay.map {
            ConversationEventRedactor.redact($0, knownSecrets: knownSecrets)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.toolTargetDisplay = safeTarget.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        self.browserDetail = browserDetail
        self.outputSummary = outputSummary
        let normalizedToolCallID = toolCallID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.toolCallID = normalizedToolCallID?.isEmpty == true ? nil : normalizedToolCallID
        self.toolCompositeKey = toolCompositeKey
        self.approvalCompositeKey = approvalCompositeKey
        self.approvalIdentityDigest = approvalIdentityDigest
        let normalizedReceiptID = receiptID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.receiptID = normalizedReceiptID?.isEmpty == true ? nil : normalizedReceiptID
        self.approvalDecision = approvalDecision
        self.retryEnvelope = retryEnvelope
        self.elapsedMilliseconds = elapsedMilliseconds.map { max(0, $0) }
        self.errorCategory = errorCategory
    }
}

/// The bounded, redacted value object consumed by product UI. Keeping this
/// separate from `ConversationEvent` prevents raw provider metadata from
/// becoming a display contract by accident.
public struct ConversationEventDisplayProjection: Codable, Equatable, Sendable {
    public let kind: ConversationEventKind
    public let status: ConversationEventStatus
    public let kindLabel: String
    public let statusLabel: String
    public let summary: String
    public let elapsed: String
    public let provider: String
    public let model: String
    public let errorCategory: String?
    public let accessibilityLabel: String

    fileprivate init(event: ConversationEvent, knownSecrets: [String]) {
        self.kind = event.kind
        self.status = event.status
        self.kindLabel = event.kind.label
        self.statusLabel = event.status.label
        self.summary = ConversationEventRedactor.redact(event.summary, knownSecrets: knownSecrets)
        self.elapsed = Self.elapsedLabel(for: event.elapsedMilliseconds)
        self.provider = ConversationEventRedactor.redactField(event.providerID, knownSecrets: knownSecrets) ?? "未标识"
        self.model = ConversationEventRedactor.redactField(event.modelID, knownSecrets: knownSecrets) ?? "未标识"
        self.errorCategory = event.errorCategory.map { $0.rawValue }

        let fields = [
            kindLabel,
            statusLabel,
            "耗时 \(elapsed)",
            "Provider \(provider)",
            "Model \(model)"
        ] + (errorCategory.map { ["错误 \($0)"] } ?? [])
        self.accessibilityLabel = ConversationEventRedactor.redact(
            fields.joined(separator: "，"),
            knownSecrets: knownSecrets
        )
    }

    private static func elapsedLabel(for milliseconds: Int?) -> String {
        guard let milliseconds else { return "未记录" }
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        return String(format: "%.2f s", Double(milliseconds) / 1_000)
    }
}

public struct ConversationEventProjection: Codable, Equatable, Sendable {
    public private(set) var events: [ConversationEvent]

    public var toolLifecycleEvents: [ConversationEvent] {
        events.filter { $0.kind == .tool }
    }

    public var approvalHistory: [ConversationEvent] {
        events.filter { $0.kind == .approval }
    }

    /// Produces the only UI-facing representation of a conversation event.
    /// Callers receive labels and scrubbed metadata, never raw provider fields.
    public static func display(
        for event: ConversationEvent,
        knownSecrets: [String] = []
    ) -> ConversationEventDisplayProjection {
        ConversationEventDisplayProjection(event: event, knownSecrets: knownSecrets)
    }

    public init(events: [ConversationEvent] = []) {
        self.events = []
        for event in events.sorted(by: Self.isEarlier) {
            _ = ingest(event)
        }
    }

    /// Read-only startup view of receipts that were pending at durable takeover.
    /// This never settles the fact ledger or appends to the lifecycle journal.
    /// A missing phase row uses an explicit recovery-only identity; it does not
    /// claim to reconstruct the original task or workspace scope.
    public func projectingRecoveredPendingTools(
        _ receipts: [ToolExecutionReceipt],
        activeExecutions: Set<AgentExecutionIdentity>,
        occurredAt: Date,
        neverDispatchedFileWrites: Set<ToolExecutionCompositeKey> = []
    ) -> ConversationEventProjection {
        var projected = self
        for receipt in receipts {
            guard let key = receipt.compositeKey, key.isValid,
                  let execution = receipt.executionIdentity, execution.isValid,
                  !activeExecutions.contains(execution),
                  execution.turn.sessionID == key.sessionID,
                  execution.turn.turnID == key.turnID,
                  execution.turn.messageID == key.messageID,
                  execution.operationID == key.operationID,
                  execution.attempt == key.attemptNumber,
                  receipt.toolCallID == key.toolCallID,
                  receipt.attemptID == key.attemptID,
                  receipt.attemptNumber == key.attemptNumber,
                  !receipt.receiptID.isEmpty,
                  !receipt.toolName.isEmpty else { continue }
            let lastSequence = projected.events.map(\.sequence).max() ?? 0
            guard lastSequence < Int64.max else { continue }
            let previous = projected.events.first {
                $0.kind == .tool && $0.toolCompositeKey == key
            }
            let recoveryIdentity = ConversationEventIdentity(
                sessionID: key.sessionID,
                turnID: String(key.turnID),
                taskID: "recovered-tool:\(key.rawValue)",
                attempt: key.attemptNumber,
                scopeID: "recovered-tool-fact-ledger"
            )
            let identity = previous?.identity ?? recoveryIdentity
            guard let identity,
                  identity.sessionID == key.sessionID,
                  identity.turnID == String(key.turnID),
                  identity.attempt == key.attemptNumber else { continue }
            // The fact ledger is authoritative for pending. Even a conflicting
            // terminal display row cannot make this receipt a settled fact.
            var candidate = ConversationEventProjection(events: projected.events.filter {
                !($0.kind == .tool && $0.toolCompositeKey == key)
            })
            let summary = receipt.toolName == "file_write"
                && neverDispatchedFileWrites.contains(key)
                ? "恢复后未执行：file_write；重试需用户确认"
                : "恢复后工具结果待核验：\(receipt.toolName)"
            let event = ConversationEvent(
                id: previous?.id ?? key.rawValue,
                identity: identity,
                sequence: lastSequence + 1,
                occurredAt: occurredAt,
                kind: .tool,
                status: .needsReview,
                summary: summary,
                toolName: receipt.toolName,
                toolTargetDisplay: previous?.toolTargetDisplay,
                toolCallID: key.toolCallID,
                toolCompositeKey: key
            )
            if candidate.ingest(event) {
                projected = candidate
            } else if previous != nil, let recoveryIdentity,
                      recoveryIdentity != identity {
                // A closed original task can reject its old identity. Keep a
                // review row under the explicit display-only recovery scope.
                let fallback = ConversationEvent(
                    id: key.rawValue,
                    identity: recoveryIdentity,
                    sequence: lastSequence + 1,
                    occurredAt: occurredAt,
                    kind: .tool,
                    status: .needsReview,
                    summary: summary,
                    toolName: receipt.toolName,
                toolTargetDisplay: previous?.toolTargetDisplay,
                    toolCallID: key.toolCallID,
                    toolCompositeKey: key
                )
                if candidate.ingest(fallback) {
                    projected = candidate
                }
            }
        }
        return projected
    }

    @discardableResult
    public mutating func ingest(_ event: ConversationEvent) -> Bool {
        guard !event.id.isEmpty else { return false }
        if let envelope = event.retryEnvelope {
            guard event.status == .failed,
                  envelope.sessionID == event.identity.sessionID,
                  envelope.turnID == event.identity.turnID,
                  envelope.taskID == event.identity.taskID,
                  envelope.attempt == event.identity.attempt else {
                return false
            }
        }
        switch event.kind {
        case .tool:
            guard event.toolCallID != nil,
                  event.receiptID != nil || (event.toolCompositeKey?.isValid == true && !event.status.isTerminal) else {
                return false
            }
            if let key = event.toolCompositeKey {
                guard key.isValid,
                      key.sessionID == event.identity.sessionID,
                      String(key.turnID) == event.identity.turnID,
                      key.attemptNumber == event.identity.attempt,
                      key.toolCallID == event.toolCallID else { return false }
            }
        case .approval:
            guard event.toolCallID != nil,
                  event.receiptID != nil,
                  event.approvalDecision != nil else { return false }
            if let key = event.approvalCompositeKey {
                guard key.isValid,
                      key.sessionID == event.identity.sessionID,
                      String(key.turnID) == event.identity.turnID,
                      key.attemptNumber == event.identity.attempt,
                      key.toolCallID == event.toolCallID,
                      let digest = event.approvalIdentityDigest,
                      !digest.isEmpty else { return false }
                if event.status == .waiting {
                    guard event.approvalDecision == .requested else { return false }
                } else {
                    guard event.status.isTerminal,
                          event.approvalDecision != .requested else { return false }
                }
            }
        default:
            break
        }
        // Once a newer attempt for the same session/turn/task/scope has been
        // observed, callbacks from an older attempt are stale even when they
        // arrive with a fresh transport event ID.
        guard !events.contains(where: {
            Self.sameAttemptLineage($0.identity, event.identity)
                && $0.identity.attempt > event.identity.attempt
        }) else {
            return false
        }

        let matchingEventIndex = events.firstIndex(where: { $0.id == event.id })
        let matchingToolCallIndex: Int? = {
            guard event.kind == .tool, let toolCallID = event.toolCallID else { return nil }
            return events.firstIndex {
                $0.kind == .tool
                    && $0.identity == event.identity
                    && $0.toolCallID == toolCallID
            }
        }()
        let matchingApprovalReceiptIndex: Int? = {
            guard event.kind == .approval, let receiptID = event.receiptID else { return nil }
            return events.firstIndex {
                $0.kind == .approval
                    && $0.identity == event.identity
                    && $0.receiptID == receiptID
                    && $0.approvalCompositeKey == event.approvalCompositeKey
                    && $0.approvalIdentityDigest == event.approvalIdentityDigest
            }
        }()

        if let index = matchingEventIndex ?? matchingToolCallIndex ?? matchingApprovalReceiptIndex {
            let current = events[index]
            guard current.identity == event.identity,
                  current.kind == event.kind,
                  current.toolCallID == event.toolCallID,
                  current.toolCompositeKey == event.toolCompositeKey,
                  current.approvalCompositeKey == event.approvalCompositeKey,
                  current.approvalIdentityDigest == event.approvalIdentityDigest,
                  (current.receiptID == event.receiptID ||
                    (current.kind == .tool && current.receiptID == nil && event.receiptID != nil && event.status.isTerminal)),
                  !current.status.isTerminal else {
                return false
            }
            if current.kind == .tool && current.receiptID == nil && event.receiptID == nil {
                guard current.status == .queued && event.status == .running else { return false }
            }
            if current.kind == .approval && current.approvalCompositeKey != nil {
                guard current.status == .waiting,
                      current.approvalDecision == .requested,
                      event.status.isTerminal else { return false }
            }
            // A callback retry can carry a fresh transport event ID. For a
            // canonical toolCallID, equal sequence/time is the same callback
            // and must remain idempotent instead of being tie-broken by ID.
            let isLater: Bool
            if matchingToolCallIndex != nil || matchingApprovalReceiptIndex != nil {
                isLater = Self.isLaterCanonicalFact(event, than: current)
            } else {
                isLater = Self.isLater(event, than: current)
            }
            guard isLater else { return false }
            events[index] = event
        } else {
            guard !events.contains(where: {
                $0.identity == event.identity && $0.closesIdentity
            }) else {
                return false
            }
            if event.closesIdentity {
                events.removeAll {
                    $0.identity == event.identity && Self.isLater($0, than: event)
                }
            }
            events.append(event)
        }

        events.sort(by: Self.isEarlier)
        return true
    }

    private static func isLater(_ candidate: ConversationEvent, than current: ConversationEvent) -> Bool {
        if candidate.sequence != current.sequence {
            return candidate.sequence > current.sequence
        }
        if candidate.occurredAt != current.occurredAt {
            return candidate.occurredAt > current.occurredAt
        }
        return candidate.id > current.id
    }

    private static func isLaterCanonicalFact(
        _ candidate: ConversationEvent,
        than current: ConversationEvent
    ) -> Bool {
        if candidate.sequence != current.sequence {
            return candidate.sequence > current.sequence
        }
        return candidate.occurredAt > current.occurredAt
    }

    private static func sameAttemptLineage(
        _ lhs: ConversationEventIdentity,
        _ rhs: ConversationEventIdentity
    ) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.turnID == rhs.turnID
            && lhs.taskID == rhs.taskID
            && lhs.scopeID == rhs.scopeID
    }

    private static func isEarlier(_ lhs: ConversationEvent, _ rhs: ConversationEvent) -> Bool {
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        if lhs.occurredAt != rhs.occurredAt {
            return lhs.occurredAt < rhs.occurredAt
        }
        return lhs.id < rhs.id
    }
}
