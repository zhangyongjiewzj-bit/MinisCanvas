import Foundation

// MARK: - UX-03 contract-only conversation event projection

enum ConversationEventKind: String, Codable, CaseIterable, Sendable {
    case stop
    case thinking
    case model
    case tool
    case task

    var label: String {
        switch self {
        case .stop: return "停止"
        case .thinking: return "思考"
        case .model: return "模型"
        case .tool: return "工具"
        case .task: return "任务"
        }
    }
}

enum ConversationEventStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case waiting
    case succeeded
    case failed
    case cancelled
    case stopped

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .stopped:
            return true
        case .queued, .running, .waiting:
            return false
        }
    }

    var label: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "进行中"
        case .waiting: return "等待中"
        case .succeeded: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .stopped: return "已停止"
        }
    }
}

enum ConversationEventErrorCategory: String, Codable, CaseIterable, Sendable {
    case cancelled
    case timeout
    case authorization
    case provider
    case model
    case tool
    case network
    case validation
    case unknown
}

struct ConversationEventIdentity: Codable, Equatable, Hashable, Sendable {
    let sessionID: String
    let turnID: String
    let taskID: String
    let attempt: Int
    let scopeID: String

    init?(
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

enum ConversationEventRedactor {
    static let maximumSummaryLength = 160

    static func redact(_ summary: String) -> String {
        var value = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "事件更新" }

        value = value.replacingOccurrences(
            of: #"(?i)(api[_-]?key|token|secret|password|cookie|authorization)\s*[:=]\s*(?:bearer\s+)?[^\s,;]+"#,
            with: "$1=[REDACTED]",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"https?://[^\s]+"#,
            with: "[remote resource]",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?<![A-Za-z0-9:])/(?:[^/\s]+/)+[^/\s]+"#,
            with: "[local path]",
            options: .regularExpression
        )
        value = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        guard value.count > maximumSummaryLength else { return value }
        return String(value.prefix(maximumSummaryLength - 3)) + "..."
    }

    static func identifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sanitized = trimmed.replacingOccurrences(
            of: #"[^A-Za-z0-9._:-]+"#,
            with: "_",
            options: .regularExpression
        )
        guard !sanitized.isEmpty else { return nil }
        return String(sanitized.prefix(80))
    }
}

struct ConversationEvent: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let identity: ConversationEventIdentity
    let sequence: Int64
    let occurredAt: Date
    let kind: ConversationEventKind
    let status: ConversationEventStatus
    let summary: String
    let providerID: String?
    let modelID: String?
    let toolName: String?
    let elapsedMilliseconds: Int?
    let errorCategory: ConversationEventErrorCategory?

    init(
        id: String,
        identity: ConversationEventIdentity,
        sequence: Int64,
        occurredAt: Date,
        kind: ConversationEventKind,
        status: ConversationEventStatus,
        summary: String,
        providerID: String? = nil,
        modelID: String? = nil,
        toolName: String? = nil,
        elapsedMilliseconds: Int? = nil,
        errorCategory: ConversationEventErrorCategory? = nil
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identity = identity
        self.sequence = max(0, sequence)
        self.occurredAt = occurredAt
        self.kind = kind
        self.status = status
        self.summary = ConversationEventRedactor.redact(summary)
        self.providerID = ConversationEventRedactor.identifier(providerID)
        self.modelID = ConversationEventRedactor.identifier(modelID)
        self.toolName = ConversationEventRedactor.identifier(toolName)
        self.elapsedMilliseconds = elapsedMilliseconds.map { max(0, $0) }
        self.errorCategory = errorCategory
    }
}

struct ConversationEventProjection: Codable, Equatable, Sendable {
    private(set) var events: [ConversationEvent]

    init(events: [ConversationEvent] = []) {
        self.events = []
        for event in events {
            _ = ingest(event)
        }
    }

    @discardableResult
    mutating func ingest(_ event: ConversationEvent) -> Bool {
        guard !event.id.isEmpty else { return false }

        if let index = events.firstIndex(where: { $0.id == event.id }) {
            let current = events[index]
            guard current.identity == event.identity else { return false }
            guard !current.status.isTerminal else { return false }
            guard isLater(event, than: current) else { return false }
            events[index] = event
        } else {
            events.append(event)
        }

        events.sort(by: isEarlier)
        return true
    }

    private func isLater(_ candidate: ConversationEvent, than current: ConversationEvent) -> Bool {
        if candidate.sequence != current.sequence {
            return candidate.sequence > current.sequence
        }
        if candidate.occurredAt != current.occurredAt {
            return candidate.occurredAt > current.occurredAt
        }
        return candidate.id > current.id
    }

    private func isEarlier(_ lhs: ConversationEvent, _ rhs: ConversationEvent) -> Bool {
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        if lhs.occurredAt != rhs.occurredAt {
            return lhs.occurredAt < rhs.occurredAt
        }
        return lhs.id < rhs.id
    }
}
