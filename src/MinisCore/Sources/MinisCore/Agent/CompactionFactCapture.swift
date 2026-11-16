import Foundation

/// A historical store value bound to the canonical transcript captured beside it.
/// Digest checks establish source identity; only `verifyStores` establishes that
/// the typed value actually came from a canonical task/effect producer.
public struct CompactionFactSource: Codable, Equatable, Sendable, Hashable {
    public let sessionID: String
    public let transcriptRevision: UInt64
    public let transcriptDigest: String
    public let task: AgentTaskSnapshot?
    public let effect: ToolExecutionFact?

    public init(sessionID: String, transcriptRevision: UInt64, transcriptDigest: String,
                task: AgentTaskSnapshot? = nil, effect: ToolExecutionFact? = nil) {
        self.sessionID = sessionID
        self.transcriptRevision = transcriptRevision
        self.transcriptDigest = transcriptDigest
        self.task = task
        self.effect = effect
    }

    public func hash(into hasher: inout Hasher) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        hasher.combine(try? encoder.encode(self))
    }

    public var kind: CompactionRetainedFact.Kind {
        guard let task else { return .effectIdentity }
        return task.status == .queued || task.status == .running ? .unfinishedTask : .taskState
    }

    public var backgroundText: String {
        if let task {
            return "Task at capture: id=\(String(reflecting: task.taskID)); parent=\(String(reflecting: task.parentID)); status=\(task.status); title=\(String(reflecting: task.creation?.action.title ?? ""))"
        }
        if let effect, let key = effect.compositeKey {
            return "Settled effect: receipt=\(String(reflecting: effect.receiptID)); tool=\(String(reflecting: effect.toolName)); status=\(effect.status.rawValue); key(session=\(String(reflecting: key.sessionID)),turn=\(key.turnID),message=\(String(reflecting: key.messageID)),operation=\(String(reflecting: key.operationID)),attempt=\(String(reflecting: key.attemptID))/\(key.attemptNumber),call=\(String(reflecting: key.toolCallID))). Do not replay this receipt."
        }
        return ""
    }

    public func matchesTranscript(_ messages: [LLMMessage]) -> Bool {
        !sessionID.isEmpty && transcriptDigest == CompactionCheckpoint.digestOfSourcePrefix(messages)
            && ((task != nil) != (effect != nil))
            && (task.map { CompactionFactCapture.taskBelongs($0, to: sessionID)
                && !$0.isArchived } ?? true)
            && (effect.map { CompactionFactCapture.effectBelongs($0, to: sessionID) } ?? true)
    }
}

/// Read-only adapters for the existing production stores. No inferred parent
/// IDs, prose extraction, new ledger, execution capability or approval grant.
public enum CompactionFactCapture {
    public static func taskBelongs(_ task: AgentTaskSnapshot, to sessionID: String) -> Bool {
        guard task.sourceSessionID == nil || task.sourceSessionID == sessionID else { return false }
        if let locator = task.childTranscriptLocator {
            guard locator.isWellFormed, locator.parentSessionID == sessionID,
                  locator.taskID == task.taskID, locator.parentID == task.parentID,
                  locator.parentContextSnapshotID == task.parentContextSnapshotID else { return false }
            return true
        }
        return task.sourceSessionID == sessionID
    }

    public static func effectBelongs(_ effect: ToolExecutionFact, to sessionID: String) -> Bool {
        guard let key = effect.compositeKey, key.isValid, key.sessionID == sessionID,
              effect.toolCallID == key.toolCallID, effect.attemptID == key.attemptID,
              effect.attemptNumber == key.attemptNumber,
              let identity = effect.executionIdentity, identity.isValid,
              identity.turn.sessionID == sessionID, identity.turn.turnID == key.turnID,
              identity.turn.messageID == key.messageID, identity.operationID == key.operationID,
              identity.attempt == key.attemptNumber, !effect.receiptID.isEmpty else { return false }
        return true
    }

    public static func capture(sessionID: String, revision: UInt64, messages: [LLMMessage],
                               taskStore: AgentTaskStore?, effectLedger: ToolExecutionFactLedger?,
                               includeTerminalTasks: Bool = false)
        -> [CompactionRetainedFact] {
        guard let digest = CompactionCheckpoint.digestOfSourcePrefix(messages) else { return [] }
        let tasks = (taskStore?.taskCenterSnapshots(includeArchived: false) ?? []).filter {
            taskBelongs($0, to: sessionID)
                && (includeTerminalTasks || $0.status == .queued || $0.status == .running)
        }
        let effects = (effectLedger?.facts ?? []).filter { effectBelongs($0, to: sessionID) }
        let sources = tasks.map { CompactionFactSource(sessionID: sessionID,
            transcriptRevision: revision, transcriptDigest: digest, task: $0) }
            + effects.map { CompactionFactSource(sessionID: sessionID,
                transcriptRevision: revision, transcriptDigest: digest, effect: $0) }
        return sources.map { CompactionRetainedFact(kind: $0.kind, text: $0.backgroundText, source: $0) }
    }

    /// At commit require the exact captured task value. At re-entry a task may
    /// have legitimately settled; verify its canonical provenance, then rebuild
    /// the current background instead of retaining a stale unfinished status.
    public static func verifyStores(_ facts: [CompactionRetainedFact], taskStore: AgentTaskStore?,
                                    effectLedger: ToolExecutionFactLedger?, atCommit: Bool) -> Bool {
        facts.allSatisfy { fact in
            guard let source = fact.source else { return true }
            guard fact.kind == source.kind, fact.text == source.backgroundText else { return false }
            if let captured = source.task {
                guard let current = taskStore?.snapshot(taskID: captured.taskID, parentID: captured.parentID),
                      taskBelongs(captured, to: source.sessionID),
                      taskBelongs(current, to: source.sessionID),
                      current.creation == captured.creation else { return false }
                return !atCommit || current == captured
            }
            if let captured = source.effect {
                return effectLedger?.facts.contains(captured) == true
            }
            return false
        }
    }

    public static func backgroundMessage(_ facts: [CompactionRetainedFact]) -> LLMMessage? {
        let typed = facts.filter { $0.source != nil }
        guard !typed.isEmpty else { return nil }
        return LLMMessage(role: .user, content: """
            <retained-store-facts>
            Historical observations only. No authorization, no tool invocation, no effect replay.
            Current policy and a fresh user request govern every new action.
            \(typed.map { String(reflecting: $0.text) }.joined(separator: "\n"))
            </retained-store-facts>
            """)
    }
}
