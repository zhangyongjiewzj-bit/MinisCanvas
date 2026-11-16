import Foundation
import Darwin

// Independently designed from the TASK2565 behavior contract and non-target consumers.
// The durable journal stores only canonical identities and bounded result metadata.
public enum ToolExecutionStatus: String, Codable, Hashable, Sendable {
    case succeeded, failed, cancelled
    public var isTerminal: Bool { true }
}
public typealias ToolExecutionTerminalStatus = ToolExecutionStatus
public enum ToolExecutionFailureCategory: String, Codable, Hashable, Sendable { case timeout }

public struct BrowserToolExecutionDetail: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case action, outcome, refusalReason, readCharacterCount, failureCode, resultPreview, automaticRuleCategory
    }

    public let action: String
    public let outcome: String
    public let refusalReason: String?
    public let readCharacterCount: Int?
    public let failureCode: String?
    public let resultPreview: String
    /// Closed producer-owned rule-use fact; absent on old or manual executions.
    public let automaticRuleCategory: BrowserInteractionCategory?

    public init?(action: String, outcome: String, result: String? = nil,
                 refusalReason: String? = nil, untrustedPageContent: String? = nil,
                 failureCode: String? = nil,
                 automaticRuleCategory: BrowserInteractionCategory? = nil) {
        guard ["navigate", "click", "type", "read", "back", "screenshot", "download", "upload"].contains(action) else { return nil }
        switch outcome {
        case "succeeded":
            guard action != "read", refusalReason == nil, failureCode == nil,
                  untrustedPageContent == nil else { return nil }
        case "read":
            guard action == "read", result == nil, refusalReason == nil,
                  failureCode == nil, untrustedPageContent != nil else { return nil }
        case "denied":
            guard result == nil, untrustedPageContent == nil, failureCode == nil,
                  let refusalReason, !refusalReason.isEmpty,
                  refusalReason.utf8.count <= 128,
                  Self.isCanonicalDenial(refusalReason) else { return nil }
        case "failed":
            guard action == "back", failureCode == "cannot_go_back", result == nil,
                  refusalReason == nil, untrustedPageContent == nil else { return nil }
        default: return nil
        }
        self.action = action
        self.outcome = outcome
        self.refusalReason = refusalReason
        self.readCharacterCount = untrustedPageContent?.count
        guard automaticRuleCategory == nil || (outcome == "succeeded" &&
            ((automaticRuleCategory == .input && action == "type") ||
             (automaticRuleCategory == .click && action == "click"))) else { return nil }
        self.automaticRuleCategory = automaticRuleCategory
        self.failureCode = failureCode
        self.resultPreview = Self.safePreview(action: action, outcome: outcome,
                                              readCharacterCount: untrustedPageContent?.count)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let action = try values.decode(String.self, forKey: .action)
        let outcome = try values.decode(String.self, forKey: .outcome)
        let reason = try values.decodeIfPresent(String.self, forKey: .refusalReason)
        let count = try values.decodeIfPresent(Int.self, forKey: .readCharacterCount)
        let code = try values.decodeIfPresent(String.self, forKey: .failureCode)
        let automatic = try values.decodeIfPresent(BrowserInteractionCategory.self, forKey: .automaticRuleCategory)
        // Persisted previews are never trusted. Old records may omit this
        // field; forged records may supply arbitrary page or path bytes.
        let valid: Bool
        switch outcome {
        case "succeeded":
            valid = action != "read" && reason == nil && count == nil && code == nil
        case "read":
            valid = action == "read" && reason == nil && code == nil
                && (count.map { $0 >= 0 } ?? false)
        case "denied":
            valid = reason.map(Self.isCanonicalDenial) == true && count == nil && code == nil
        case "failed":
            valid = action == "back" && code == "cannot_go_back" && reason == nil && count == nil
        default:
            valid = false
        }
        guard ["navigate", "click", "type", "read", "back", "screenshot", "download", "upload"].contains(action),
              valid else {
            throw DecodingError.dataCorruptedError(forKey: .outcome, in: values,
                debugDescription: "Invalid browser detail")
        }
        self.action = action
        self.outcome = outcome
        self.refusalReason = reason
        self.readCharacterCount = count
        guard automatic == nil || (outcome == "succeeded" &&
            ((automatic == .input && action == "type") || (automatic == .click && action == "click"))) else {
            throw DecodingError.dataCorruptedError(forKey: .automaticRuleCategory, in: values,
                debugDescription: "Invalid browser automatic rule category")
        }
        self.automaticRuleCategory = automatic
        self.failureCode = code
        self.resultPreview = Self.safePreview(action: action, outcome: outcome,
                                              readCharacterCount: count)
    }

    private static func isCanonicalDenial(_ reason: String) -> Bool {
        guard !reason.isEmpty, reason.utf8.count <= 128 else { return false }
        if reason == "write_authorization_required" || reason == "invalid_scope" { return true }
        let prefix = "navigation_denied:"
        return reason.hasPrefix(prefix) && BrowserNavigationPolicy.Denial(
            rawValue: String(reason.dropFirst(prefix.count))
        ) != nil
    }

    private static func safePreview(action: String, outcome: String,
                                    readCharacterCount: Int?) -> String {
        switch outcome {
        case "read": return "已读取 \(readCharacterCount ?? 0) 字符"
        case "denied": return "已拒绝"
        case "failed": return "cannot_go_back"
        default:
            switch action {
            case "navigate": return "页面已打开"
            case "click": return "已点击"
            case "type": return "已输入"
            case "back": return "已返回上一页"
            case "screenshot": return "截图已完成"
            default: return "已完成"
            }
        }
    }
}

public struct ToolExecutionCompositeKey: Codable, Hashable, Sendable {
    public let sessionID: String
    public let turnID: Int
    public let messageID: String
    public let operationID: String
    public let attemptID: String
    public let attemptNumber: Int
    public let toolCallID: String
    public init(sessionID: String, turnID: Int, messageID: String, operationID: String,
                attemptID: String, attemptNumber: Int, toolCallID: String) {
        self.sessionID = sessionID; self.turnID = turnID; self.messageID = messageID
        self.operationID = operationID; self.attemptID = attemptID
        self.attemptNumber = attemptNumber; self.toolCallID = toolCallID
    }
    public var isValid: Bool {
        turnID >= 0 && attemptNumber > 0 &&
        [sessionID, messageID, operationID, attemptID, toolCallID].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    // Length framing keeps opaque identifiers collision-free even when they contain separators.
    public var rawValue: String {
        [sessionID, String(turnID), messageID, operationID, attemptID,
         String(attemptNumber), toolCallID].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public enum ToolExecutionPhase: String, Codable, Hashable, Sendable { case queued, running }
public struct ToolExecutionPhaseFact: Codable, Hashable, Sendable {
    public let compositeKey: ToolExecutionCompositeKey
    public let executionIdentity: AgentExecutionIdentity
    public let toolName: String
    public let phase: ToolExecutionPhase
    public let occurredAt: Date
    public init(compositeKey: ToolExecutionCompositeKey, executionIdentity: AgentExecutionIdentity,
                toolName: String, phase: ToolExecutionPhase, occurredAt: Date) {
        self.compositeKey = compositeKey; self.executionIdentity = executionIdentity
        self.toolName = toolName; self.phase = phase; self.occurredAt = occurredAt
    }
}
public enum ApprovalLifecycleStage: String, Codable, Hashable, Sendable {
    case presented, authorityApproved, authorityDenied, authorityExpired,
         authorityCancelled, authorityRevoked
}
public struct ApprovalLifecycleFact: Codable, Hashable, Sendable {
    public let compositeKey: ToolExecutionCompositeKey
    public let executionIdentity: AgentExecutionIdentity
    public let toolName: String
    public let stage: ApprovalLifecycleStage
    public let requestID: String
    public let identityDigest: String
    public let taskID: String
    public let scopeID: String
    public let occurredAt: Date
}
public struct ApprovalPresentationContext: Sendable {
    @TaskLocal public static var current: ApprovalPresentationContext?
    public let compositeKey: ToolExecutionCompositeKey
    public let executionIdentity: AgentExecutionIdentity
    public let toolName: String
    public let eventSink: @Sendable (ApprovalLifecycleFact) -> Void
    public init(compositeKey: ToolExecutionCompositeKey, executionIdentity: AgentExecutionIdentity,
                toolName: String, eventSink: @escaping @Sendable (ApprovalLifecycleFact) -> Void) {
        self.compositeKey = compositeKey; self.executionIdentity = executionIdentity
        self.toolName = toolName; self.eventSink = eventSink
    }
    public func makeFact(for request: ApprovalRequest, stage: ApprovalLifecycleStage,
                         occurredAt: Date = Date()) -> ApprovalLifecycleFact? {
        guard compositeKey.isValid, executionIdentity.isValid,
              compositeKey.sessionID == executionIdentity.turn.sessionID,
              compositeKey.turnID == executionIdentity.turn.turnID,
              compositeKey.messageID == executionIdentity.turn.messageID,
              compositeKey.operationID == executionIdentity.operationID,
              compositeKey.attemptNumber == executionIdentity.attempt,
              request.callID == compositeKey.toolCallID, request.toolName == toolName,
              request.sessionID == compositeKey.sessionID,
              request.turnID == compositeKey.turnID,
              request.attemptID == compositeKey.attemptID,
              request.runID == nil || request.runID == compositeKey.operationID,
              request.runID == nil || request.binding != nil,
              request.messageID == (request.runID == nil
                  ? compositeKey.messageID : compositeKey.operationID),
              let digest = request.identityDigest, !digest.isEmpty,
              let taskID = request.taskID, !taskID.isEmpty,
              let scopeID = request.approvalScope, !scopeID.isEmpty,
              !request.requestID.isEmpty,
              request.expiresAt == nil || occurredAt <= request.expiresAt! else { return nil }
        return ApprovalLifecycleFact(compositeKey: compositeKey,
            executionIdentity: executionIdentity, toolName: toolName, stage: stage,
            requestID: request.requestID, identityDigest: digest, taskID: taskID,
            scopeID: scopeID, occurredAt: occurredAt)
    }
}

public struct ToolExecutionReceipt: Codable, Hashable, Sendable {
    public let toolCallID: String
    public let receiptID: String
    public let toolName: String
    public let attemptID: String
    public let attemptNumber: Int
    public let executionIdentity: AgentExecutionIdentity?
    public let compositeKey: ToolExecutionCompositeKey?
    public let parentRuntimeIdentity: ParentRuntimeIdentity?
    public let childTranscriptLocator: ChildTranscriptLocator?
    public let targetTaskBinding: TaskFileArtifactBinding?
    public let targetTaskSource: ParentRuntimeIdentity?
    public init(toolCallID: String, receiptID: String, toolName: String,
                attemptID: String, attemptNumber: Int,
                executionIdentity: AgentExecutionIdentity? = nil,
                compositeKey: ToolExecutionCompositeKey? = nil,
                parentRuntimeIdentity: ParentRuntimeIdentity? = nil,
                childTranscriptLocator: ChildTranscriptLocator? = nil,
                targetTaskBinding: TaskFileArtifactBinding? = nil,
                targetTaskSource: ParentRuntimeIdentity? = nil) {
        self.toolCallID = toolCallID; self.receiptID = receiptID; self.toolName = toolName
        self.attemptID = attemptID; self.attemptNumber = attemptNumber
        self.executionIdentity = executionIdentity; self.compositeKey = compositeKey
        self.parentRuntimeIdentity = parentRuntimeIdentity
        self.childTranscriptLocator = childTranscriptLocator
        self.targetTaskBinding = targetTaskBinding; self.targetTaskSource = targetTaskSource
    }
}
public struct ToolExecutionFact: Codable, Hashable, Sendable {
    public let toolCallID: String
    public let receiptID: String
    public let toolName: String
    public let status: ToolExecutionStatus
    public let attemptID: String
    public let attemptNumber: Int
    public let executionIdentity: AgentExecutionIdentity?
    public let compositeKey: ToolExecutionCompositeKey?
    public let parentRuntimeIdentity: ParentRuntimeIdentity?
    public let childTranscriptLocator: ChildTranscriptLocator?
    public let targetTaskBinding: TaskFileArtifactBinding?
    public let targetTaskSource: ParentRuntimeIdentity?
    public let browserDetail: BrowserToolExecutionDetail?
    public let outputSummary: ToolOutputSummary?
    public let elapsedMilliseconds: Int?
    public let failureCategory: ToolExecutionFailureCategory?
    public var terminalStatus: ToolExecutionStatus { status }
    public var attemptIdentity: AgentExecutionIdentity? { executionIdentity }
    public init(toolCallID: String, receiptID: String, toolName: String,
                status: ToolExecutionStatus, attemptID: String, attemptNumber: Int,
                executionIdentity: AgentExecutionIdentity? = nil,
                compositeKey: ToolExecutionCompositeKey? = nil,
                parentRuntimeIdentity: ParentRuntimeIdentity? = nil,
                childTranscriptLocator: ChildTranscriptLocator? = nil,
                targetTaskBinding: TaskFileArtifactBinding? = nil,
                targetTaskSource: ParentRuntimeIdentity? = nil,
                browserDetail: BrowserToolExecutionDetail? = nil,
                outputSummary: ToolOutputSummary? = nil,
                elapsedMilliseconds: Int? = nil,
                failureCategory: ToolExecutionFailureCategory? = nil) {
        self.toolCallID = toolCallID; self.receiptID = receiptID; self.toolName = toolName
        self.status = status; self.attemptID = attemptID; self.attemptNumber = attemptNumber
        self.executionIdentity = executionIdentity; self.compositeKey = compositeKey
        self.parentRuntimeIdentity = parentRuntimeIdentity
        self.childTranscriptLocator = childTranscriptLocator
        self.targetTaskBinding = targetTaskBinding; self.targetTaskSource = targetTaskSource
        self.browserDetail = browserDetail; self.outputSummary = outputSummary
        self.elapsedMilliseconds = elapsedMilliseconds; self.failureCategory = failureCategory
    }
}
public enum ToolExecutionFactLedgerError: Error, Equatable, Sendable {
    case durableAuthorityRequired, invalidAttemptIdentity, invalidCanonicalIdentity
    case duplicateToolCallID(String), unknownReceipt, receiptIdentityMismatch
    case externalOutcomeUnverified, persistenceFailed, corruptLedger, staleWriter
}
public struct PendingFileWriteEvidence: Codable, Hashable, Sendable {
    public let receiptID: String
    public let compositeKey: ToolExecutionCompositeKey
    public let targetPath: String
    public let beforeSHA256: String?
    public let expectedSHA256: String?
    public let completedSHA256: String?
}
public enum ToolExecutionReceiptContext {
    @TaskLocal public static var current: ToolExecutionReceipt?
    @TaskLocal public static var ledger: ToolExecutionFactLedger?
}

/// An immutable cancellation handle for one canonical fact observation.
/// Dropping the owner unregisters the callback; it never cancels tool work.
public final class ToolExecutionSettlementObservation: Sendable {
    private let unregister: @Sendable () -> Void
    fileprivate init(unregister: @escaping @Sendable () -> Void) {
        self.unregister = unregister
    }
    public func cancel() { unregister() }
    deinit { unregister() }
}

public final class ToolExecutionFactLedger: @unchecked Sendable {
    private struct DiskState: Codable {
        var schemaVersion: Int
        var writerID: String
        var fence: Int?
        var pending: [String: ToolExecutionReceipt]
        var facts: [String: ToolExecutionFact]
        var order: [String]
        var unstartedFileWrites: Set<String>?
        var fileWrites: [String: PendingFileWriteEvidence]?
        static func empty() -> DiskState {
            DiskState(schemaVersion: 6, writerID: "", fence: nil, pending: [:], facts: [:],
                      order: [], unstartedFileWrites: [], fileWrites: [:])
        }
    }
    // This shape is based solely on synthetic JSON emitted by the old public
    // ledger API. It is deliberately separate from the current disk schema.
    private struct LegacyDiskState: Decodable {
        let schemaVersion: Int
        let writerID: String
        let fence: Int
        let pending: [String: ToolExecutionReceipt]
        let facts: [String: ToolExecutionFact]
        let order: [String]
        let unstartedFileWrites: [String: String]?
        let pendingFileWrites: [String: PendingFileWriteEvidence]?
    }
    private let persistenceURL: URL?
    private let writerID: String
    private let stateLock = NSLock()
    private var state: DiskState
    private struct SettlementObserver {
        let key: ToolExecutionCompositeKey
        let receiptID: String
        let receive: @Sendable (ToolExecutionFact, ToolExecutionLiveFailureFeedback?) -> Void
    }
    // Registration, settlement lookup and removal share the canonical state
    // lock. Callbacks run only after the durable transaction releases it.
    private var settlementObservers: [UUID: SettlementObserver] = [:]
    private let startupPending: [ToolExecutionReceipt]
    private static let hookLock = NSLock()
    private nonisolated(unsafe) static var takeoverHooks: [String: @Sendable () -> Void] = [:]
    private nonisolated(unsafe) static var mintHooks: [String: @Sendable () -> Void] = [:]

    public static func setTakeoverTestHook(for url: URL, _ hook: (@Sendable () -> Void)?) {
        hookLock.withLock { takeoverHooks[url.standardizedFileURL.path] = hook }
    }
    public static func setMintBeforeLockTestHook(for url: URL, _ hook: (@Sendable () -> Void)?) {
        hookLock.withLock { mintHooks[url.standardizedFileURL.path] = hook }
    }
    private static func hook(for url: URL, takeover: Bool) -> (@Sendable () -> Void)? {
        hookLock.withLock {
            takeover ? takeoverHooks[url.standardizedFileURL.path] : mintHooks[url.standardizedFileURL.path]
        }
    }
    private static func locked<T>(url: URL, _ body: () throws -> T) throws -> T {
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw ToolExecutionFactLedgerError.persistenceFailed }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ToolExecutionFactLedgerError.persistenceFailed }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    private static func read(_ url: URL) throws -> DiskState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let version = root?["schemaVersion"] as? Int else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
            switch version {
            case 6:
                let decoded = try JSONDecoder().decode(DiskState.self, from: data)
                try validateCurrentJSON(decoded, root: root!)
                try validateCurrent(decoded)
                return decoded
            case 4:
                return try migrateLegacy(data, root: root!)
            default:
                throw ToolExecutionFactLedgerError.corruptLedger
            }
        } catch let error as ToolExecutionFactLedgerError { throw error }
        catch { throw ToolExecutionFactLedgerError.corruptLedger }
    }
    private static func legacyKey(_ key: ToolExecutionCompositeKey) -> String {
        [key.sessionID, String(key.turnID), key.messageID, key.operationID,
         key.attemptID, String(key.attemptNumber), key.toolCallID]
            .map { "\($0.utf8.count)#\($0)" }.joined()
    }
    private static func canonicalRecord(_ key: ToolExecutionCompositeKey?,
                                        _ identity: AgentExecutionIdentity?,
                                        toolCallID: String, toolName: String,
                                        attemptID: String, attemptNumber: Int,
                                        receiptID: String,
                                        parent: ParentRuntimeIdentity?,
                                        child: ChildTranscriptLocator?,
                                        target: TaskFileArtifactBinding?,
                                        targetSource: ParentRuntimeIdentity?) throws -> ToolExecutionCompositeKey {
        guard let key, key.isValid, let identity, identity.isValid,
              !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !receiptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              key.toolCallID == toolCallID, key.attemptID == attemptID,
              key.attemptNumber == attemptNumber,
              key.sessionID == identity.turn.sessionID,
              key.turnID == identity.turn.turnID,
              key.messageID == identity.turn.messageID,
              key.operationID == identity.operationID,
              key.attemptNumber == identity.attempt,
              validProvenance(identity: identity, parent: parent, child: child,
                              target: target, targetSource: targetSource) else {
            throw ToolExecutionFactLedgerError.corruptLedger
        }
        return key
    }
    private static func validProvenance(identity: AgentExecutionIdentity,
                                        parent: ParentRuntimeIdentity?,
                                        child: ChildTranscriptLocator?,
                                        target: TaskFileArtifactBinding?,
                                        targetSource: ParentRuntimeIdentity?) -> Bool {
        // Missing pairs are legacy UNKNOWN, never reconstructed from a selected
        // task. A claimed origin, however, must bind to this exact tool turn.
        switch (parent, child) {
        case (nil, nil): break
        case (let parent?, let child?):
            let prefix = "turn-handle:"
            guard parent.isValid, child.isWellFormed,
                  parent.sessionID == child.parentSessionID,
                  // Schema 1 binds one logical and runtime parent. Schema 2
                  // may retain the original Task Center owner while a retry
                  // executes under a new, Store-verified Composer parent.
                  parent.taskID == (child.runtimeParentID ?? child.parentID),
                  identity.turn.sessionID == child.childSessionID,
                  identity.turn.messageID == child.taskID,
                  parent.turnID.hasPrefix(prefix),
                  let parentTurn = Int(parent.turnID.dropFirst(prefix.count)),
                  parentTurn > 0, parentTurn <= identity.turn.turnID else { return false }
        default: return false
        }
        switch (target, targetSource) {
        case (nil, nil): break
        case (let target?, let source?):
            guard target.isValid, source.isValid,
                  target.runID == identity.operationID,
                  target.producerSessionID == identity.turn.sessionID,
                  target.sourceSessionID == source.sessionID,
                  target.parentID == source.taskID else { return false }
        default: return false
        }
        return true
    }
    private static func validateCurrent(_ state: DiskState) throws {
        let keys = Set(state.pending.keys).union(state.facts.keys)
        guard state.schemaVersion == 6, !state.writerID.isEmpty,
              state.fence.map({ $0 >= 0 }) ?? true,
              Set(state.pending.keys).isDisjoint(with: state.facts.keys),
              state.order.count == keys.count, Set(state.order) == keys else {
            throw ToolExecutionFactLedgerError.corruptLedger
        }
        var receipts = Set<String>()
        for (stored, receipt) in state.pending {
            let key = try canonicalRecord(receipt.compositeKey, receipt.executionIdentity,
                toolCallID: receipt.toolCallID, toolName: receipt.toolName,
                attemptID: receipt.attemptID, attemptNumber: receipt.attemptNumber,
                receiptID: receipt.receiptID, parent: receipt.parentRuntimeIdentity,
                child: receipt.childTranscriptLocator, target: receipt.targetTaskBinding,
                targetSource: receipt.targetTaskSource)
            guard key.rawValue == stored, receipts.insert(receipt.receiptID).inserted else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
        }
        for (stored, fact) in state.facts {
            let key = try canonicalRecord(fact.compositeKey, fact.executionIdentity,
                toolCallID: fact.toolCallID, toolName: fact.toolName,
                attemptID: fact.attemptID, attemptNumber: fact.attemptNumber,
                receiptID: fact.receiptID, parent: fact.parentRuntimeIdentity,
                child: fact.childTranscriptLocator, target: fact.targetTaskBinding,
                targetSource: fact.targetTaskSource)
            guard key.rawValue == stored, receipts.insert(fact.receiptID).inserted else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
        }
        for stored in state.unstartedFileWrites ?? [] {
            guard let receipt = state.pending[stored], receipt.toolName == "file_write",
                  state.fileWrites?[stored] == nil else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
        }
        for (stored, evidence) in state.fileWrites ?? [:] {
            guard let receipt = state.pending[stored], receipt.toolName == "file_write",
                  receipt.receiptID == evidence.receiptID,
                  receipt.compositeKey == evidence.compositeKey,
                  !evidence.targetPath.isEmpty,
                  evidence.completedSHA256 == nil ||
                    (evidence.completedSHA256 == evidence.expectedSHA256 &&
                     !evidence.completedSHA256!.isEmpty) else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
        }
    }
    private static func validateCurrentJSON(_ state: DiskState,
                                            root: [String: Any]) throws {
        // JSONDecoder ignores unknown keys. A takeover writes a new journal,
        // so accepting them here would silently erase an external writer's
        // durable evidence before the caller can inspect it.
        let allowed: Set<String> = ["schemaVersion", "writerID", "fence", "pending",
                                    "facts", "order", "unstartedFileWrites", "fileWrites"]
        guard Set(root.keys).isSubset(of: allowed),
              let rawPending = root["pending"] as? [String: Any],
              let rawFacts = root["facts"] as? [String: Any],
              Set(rawPending.keys) == Set(state.pending.keys),
              Set(rawFacts.keys) == Set(state.facts.keys),
              !(root["fence"] is NSNull),
              !(root["fileWrites"] is NSNull),
              !(root["unstartedFileWrites"] is NSNull) else {
            throw ToolExecutionFactLedgerError.corruptLedger
        }
        for (key, receipt) in state.pending {
            guard matchesLegacyJSON(receipt, rawPending[key]) else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
        }
        for (key, fact) in state.facts {
            guard matchesLegacyJSON(fact, rawFacts[key]) else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
        }
        if let raw = root["fileWrites"] {
            guard let rawWrites = raw as? [String: Any],
                  let writes = state.fileWrites,
                  Set(rawWrites.keys) == Set(writes.keys) else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
            for (key, evidence) in writes {
                guard matchesLegacyJSON(evidence, rawWrites[key]) else {
                    throw ToolExecutionFactLedgerError.corruptLedger
                }
            }
        }
        if let raw = root["unstartedFileWrites"] {
            guard let entries = raw as? [String],
                  let decoded = state.unstartedFileWrites,
                  entries.count == decoded.count, Set(entries) == decoded else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
        }
    }
    private static func matchesLegacyJSON<T: Encodable>(_ value: T, _ original: Any?) -> Bool {
        guard let original,
              let encoded = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value)),
              let originalBytes = try? JSONSerialization.data(withJSONObject: original,
                                                                options: [.sortedKeys]),
              let encodedBytes = try? JSONSerialization.data(withJSONObject: encoded,
                                                               options: [.sortedKeys]) else { return false }
        return originalBytes == encodedBytes
    }
    private static func migrateLegacy(_ data: Data, root: [String: Any]) throws -> DiskState {
        let allowed: Set<String> = ["schemaVersion", "writerID", "fence", "pending",
                                    "facts", "order", "unstartedFileWrites", "pendingFileWrites"]
        guard Set(root.keys).isSubset(of: allowed),
              !(root["unstartedFileWrites"] is NSNull) else {
            throw ToolExecutionFactLedgerError.corruptLedger
        }
        let old = try JSONDecoder().decode(LegacyDiskState.self, from: data)
        guard let rawPending = root["pending"] as? [String: Any],
              let rawFacts = root["facts"] as? [String: Any],
              let rawWrites = (root["pendingFileWrites"] as? [String: Any]) ??
                (root["pendingFileWrites"] == nil ? [:] : nil),
              Set(rawPending.keys) == Set(old.pending.keys),
              Set(rawFacts.keys) == Set(old.facts.keys),
              Set(rawWrites.keys) == Set((old.pendingFileWrites ?? [:]).keys) else {
            throw ToolExecutionFactLedgerError.corruptLedger
        }
        guard old.schemaVersion == 4, !old.writerID.isEmpty,
              old.fence >= 0, old.fence < Int.max else {
            throw ToolExecutionFactLedgerError.corruptLedger
        }
        let allOldKeys = Set(old.pending.keys).union(old.facts.keys)
        guard Set(old.pending.keys).isDisjoint(with: old.facts.keys),
              old.order.count == allOldKeys.count,
              Set(old.order) == allOldKeys else {
            throw ToolExecutionFactLedgerError.corruptLedger
        }
        var migrated = DiskState.empty()
        migrated.fence = old.fence
        var receiptIDs = Set<String>()
        var keyMap: [String: String] = [:]
        for (stored, receipt) in old.pending {
            guard matchesLegacyJSON(receipt, rawPending[stored]) else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
            let key = try canonicalRecord(receipt.compositeKey, receipt.executionIdentity,
                toolCallID: receipt.toolCallID, toolName: receipt.toolName,
                attemptID: receipt.attemptID, attemptNumber: receipt.attemptNumber,
                receiptID: receipt.receiptID, parent: receipt.parentRuntimeIdentity,
                child: receipt.childTranscriptLocator, target: receipt.targetTaskBinding,
                targetSource: receipt.targetTaskSource)
            guard stored == legacyKey(key), receiptIDs.insert(receipt.receiptID).inserted,
                  migrated.pending[key.rawValue] == nil else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
            migrated.pending[key.rawValue] = receipt
            keyMap[stored] = key.rawValue
        }
        for (stored, fact) in old.facts {
            guard matchesLegacyJSON(fact, rawFacts[stored]) else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
            let key = try canonicalRecord(fact.compositeKey, fact.executionIdentity,
                toolCallID: fact.toolCallID, toolName: fact.toolName,
                attemptID: fact.attemptID, attemptNumber: fact.attemptNumber,
                receiptID: fact.receiptID, parent: fact.parentRuntimeIdentity,
                child: fact.childTranscriptLocator, target: fact.targetTaskBinding,
                targetSource: fact.targetTaskSource)
            guard stored == legacyKey(key), receiptIDs.insert(fact.receiptID).inserted,
                  migrated.facts[key.rawValue] == nil,
                  migrated.pending[key.rawValue] == nil else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
            migrated.facts[key.rawValue] = fact
            keyMap[stored] = key.rawValue
        }
        migrated.order = try old.order.map { stored in
            guard let key = keyMap[stored] else { throw ToolExecutionFactLedgerError.corruptLedger }
            return key
        }
        for (stored, receiptID) in old.unstartedFileWrites ?? [:] {
            guard let key = keyMap[stored], let receipt = migrated.pending[key],
                  receipt.toolName == "file_write", receipt.receiptID == receiptID,
                  old.pendingFileWrites?[stored] == nil else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
            migrated.unstartedFileWrites?.insert(key)
        }
        for (stored, evidence) in old.pendingFileWrites ?? [:] {
            guard matchesLegacyJSON(evidence, rawWrites[stored]) else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
            guard let key = keyMap[stored], let receipt = migrated.pending[key],
                  receipt.toolName == "file_write", receipt.receiptID == evidence.receiptID,
                  receipt.compositeKey == evidence.compositeKey,
                  !evidence.targetPath.isEmpty,
                  evidence.completedSHA256 == nil ||
                    (evidence.completedSHA256 == evidence.expectedSHA256 &&
                     !evidence.completedSHA256!.isEmpty) else {
                throw ToolExecutionFactLedgerError.corruptLedger
            }
            migrated.fileWrites?[key] = evidence
        }
        try validateCurrentAfterTakeoverPreparation(migrated)
        return migrated
    }
    private static func validateCurrentAfterTakeoverPreparation(_ state: DiskState) throws {
        var writable = state
        writable.writerID = "validated-legacy-writer"
        try validateCurrent(writable)
    }
    private static func save(_ state: DiskState, at url: URL) throws {
        do { try JSONEncoder().encode(state).write(to: url, options: .atomic) }
        catch { throw ToolExecutionFactLedgerError.persistenceFailed }
    }
    public init() {
        persistenceURL = nil
        writerID = UUID().uuidString
        state = .empty()
        state.writerID = writerID
        startupPending = []
    }
    public init(persistenceURL: URL) throws {
        self.persistenceURL = persistenceURL.standardizedFileURL
        let token = UUID().uuidString
        writerID = token
        let url = persistenceURL.standardizedFileURL
            let pendingBox = PendingBox()
            let restored = try Self.locked(url: url) { () throws -> DiskState in
                var old = try Self.read(url) ?? .empty()
                // The test hook intentionally pauses after decode while the file lock is held.
                Self.hook(for: url, takeover: true)?()
                let pendingAtTakeover = old.order.compactMap { old.pending[$0] }
                if let fence = old.fence {
                    guard fence < Int.max else { throw ToolExecutionFactLedgerError.corruptLedger }
                    old.fence = fence + 1
                }
                old.writerID = token
                try Self.save(old, at: url)
                // Preserve the exact takeover snapshot; no outcome is inferred from file bytes.
                pendingBox.value = pendingAtTakeover
                return old
            }
            state = restored
            startupPending = pendingBox.value
    }
    // Local box avoids publishing a partially initialized self inside the lock closure.
    private final class PendingBox { var value: [ToolExecutionReceipt] = [] }

    public var hasDurableAuthority: Bool { persistenceURL != nil }
    public var facts: [ToolExecutionFact] {
        stateLock.withLock { state.order.compactMap { state.facts[$0] } }
    }
    public var pendingReceipts: [ToolExecutionReceipt] {
        stateLock.withLock { state.order.compactMap { state.pending[$0] } }
    }
    public var recoveredPendingReceipts: [ToolExecutionReceipt] { startupPending }
    public func fact(compositeKey: ToolExecutionCompositeKey, receiptID: String) -> ToolExecutionFact? {
        stateLock.withLock {
            let fact = state.facts[compositeKey.rawValue]
            return fact?.receiptID == receiptID ? fact : nil
        }
    }
    /// Observe exactly one existing canonical reservation. An already settled
    /// fact is delivered immediately, after unlocking; a pending reservation
    /// is delivered once after its successful durable settlement. Unknown or
    /// mismatched reservations cannot acquire an observation.
    public func observeSettlement(
        compositeKey: ToolExecutionCompositeKey,
        receiptID: String,
        receive: @escaping @Sendable (ToolExecutionFact) -> Void
    ) -> ToolExecutionSettlementObservation? {
        observeSettlement(compositeKey: compositeKey, receiptID: receiptID) { fact, _ in
            receive(fact)
        }
    }

    /// Live feedback is not retained or replayed. The durable fact remains
    /// the sole authority for status and execution identity.
    public func observeSettlement(
        compositeKey: ToolExecutionCompositeKey,
        receiptID: String,
        receive: @escaping @Sendable (ToolExecutionFact, ToolExecutionLiveFailureFeedback?) -> Void
    ) -> ToolExecutionSettlementObservation? {
        guard compositeKey.isValid, !receiptID.isEmpty else { return nil }
        let id = UUID()
        var existing: ToolExecutionFact?
        let registered = stateLock.withLock {
            if let fact = state.facts[compositeKey.rawValue] {
                guard fact.receiptID == receiptID else { return false }
                existing = fact
                return false
            }
            guard let pending = state.pending[compositeKey.rawValue],
                  pending.receiptID == receiptID else { return false }
            settlementObservers[id] = SettlementObserver(
                key: compositeKey, receiptID: receiptID, receive: receive)
            return true
        }
        if let existing { receive(existing, nil) }
        guard registered else { return nil }
        return ToolExecutionSettlementObservation { [weak self] in
            _ = self?.stateLock.withLock { self?.settlementObservers.removeValue(forKey: id) }
        }
    }

    private func publishSettlement(
        _ fact: ToolExecutionFact,
        liveFailureReason: ToolExecutionLiveFailureFeedback.Reason? = nil
    ) {
        let feedback: ToolExecutionLiveFailureFeedback?
        if let reason = liveFailureReason, fact.toolName == "file_read", fact.status == .failed,
           fact.elapsedMilliseconds != nil, let key = fact.compositeKey, key.isValid,
           let execution = fact.executionIdentity, execution.isValid {
            feedback = ToolExecutionLiveFailureFeedback(fact: fact, key: key,
                execution: execution, reason: reason)
        } else { feedback = nil }
        let callbacks = stateLock.withLock {
            let matches = settlementObservers.filter {
                $0.value.key == fact.compositeKey && $0.value.receiptID == fact.receiptID
            }
            for id in matches.keys { settlementObservers.removeValue(forKey: id) }
            return matches.values.map(\.receive)
        }
        for receive in callbacks { receive(fact, feedback) }
    }

    public func facts(executionIdentity: AgentExecutionIdentity, attemptID: String,
                      attemptNumber: Int) -> [ToolExecutionFact] {
        facts.filter { $0.executionIdentity == executionIdentity &&
            $0.attemptID == attemptID && $0.attemptNumber == attemptNumber }
    }
    private func transaction<T>(_ mutation: (inout DiskState) throws -> T) throws -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let url = persistenceURL else { throw ToolExecutionFactLedgerError.durableAuthorityRequired }
        return try Self.locked(url: url) {
            guard let onDisk = try Self.read(url) else { throw ToolExecutionFactLedgerError.persistenceFailed }
            guard onDisk.writerID == writerID else { throw ToolExecutionFactLedgerError.staleWriter }
            var proposed = onDisk
            let value = try mutation(&proposed)
            if let fence = proposed.fence {
                guard fence < Int.max else { throw ToolExecutionFactLedgerError.corruptLedger }
                proposed.fence = fence + 1
            }
            try Self.save(proposed, at: url)
            state = proposed
            return value
        }
    }
    public func mint(toolCallID: String, toolName: String, attemptID: String,
                     attemptNumber: Int, executionIdentity: AgentExecutionIdentity?,
                     parentRuntimeIdentity: ParentRuntimeIdentity? = nil,
                     childTranscriptLocator: ChildTranscriptLocator? = nil,
                     targetTaskBinding: TaskFileArtifactBinding? = nil,
                     targetTaskSource: ParentRuntimeIdentity? = nil) throws -> ToolExecutionReceipt {
        guard let executionIdentity else { throw ToolExecutionFactLedgerError.invalidCanonicalIdentity }
        guard attemptNumber > 0, executionIdentity.attempt == attemptNumber,
              !attemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionFactLedgerError.invalidAttemptIdentity
        }
        let key = ToolExecutionCompositeKey(sessionID: executionIdentity.turn.sessionID,
            turnID: executionIdentity.turn.turnID, messageID: executionIdentity.turn.messageID,
            operationID: executionIdentity.operationID, attemptID: attemptID,
            attemptNumber: attemptNumber, toolCallID: toolCallID)
        guard executionIdentity.isValid, key.isValid,
              !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.validProvenance(identity: executionIdentity, parent: parentRuntimeIdentity,
                                   child: childTranscriptLocator, target: targetTaskBinding,
                                   targetSource: targetTaskSource) else {
            throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
        }
        if let url = persistenceURL { Self.hook(for: url, takeover: false)?() }
        return try transaction { draft in
            let identifier = key.rawValue
            guard draft.pending[identifier] == nil, draft.facts[identifier] == nil else {
                throw ToolExecutionFactLedgerError.duplicateToolCallID(toolCallID)
            }
            let receipt = ToolExecutionReceipt(toolCallID: toolCallID,
                receiptID: UUID().uuidString, toolName: toolName, attemptID: attemptID,
                attemptNumber: attemptNumber, executionIdentity: executionIdentity,
                compositeKey: key, parentRuntimeIdentity: parentRuntimeIdentity,
                childTranscriptLocator: childTranscriptLocator,
                targetTaskBinding: targetTaskBinding, targetTaskSource: targetTaskSource)
            draft.pending[identifier] = receipt
            draft.order.append(identifier)
            return receipt
        }
    }
    public func settle(_ receipt: ToolExecutionReceipt, status: ToolExecutionStatus,
                       browserDetail: BrowserToolExecutionDetail? = nil,
                       outputSummary: ToolOutputSummary? = nil,
                       elapsedMilliseconds: Int? = nil,
                       failureCategory: ToolExecutionFailureCategory? = nil,
                       liveFailureReason: ToolExecutionLiveFailureFeedback.Reason? = nil) throws -> ToolExecutionFact? {
        guard let key = receipt.compositeKey, key.isValid else {
            throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
        }
        let fact: ToolExecutionFact? = try transaction { draft in
            let identifier = key.rawValue
            if let old = draft.facts[identifier] {
                guard old.receiptID == receipt.receiptID else {
                    throw ToolExecutionFactLedgerError.receiptIdentityMismatch
                }
                return nil
            }
            guard let pending = draft.pending[identifier] else {
                throw ToolExecutionFactLedgerError.unknownReceipt
            }
            guard pending == receipt else { throw ToolExecutionFactLedgerError.receiptIdentityMismatch }
            let fact = ToolExecutionFact(toolCallID: receipt.toolCallID,
                receiptID: receipt.receiptID, toolName: receipt.toolName, status: status,
                attemptID: receipt.attemptID, attemptNumber: receipt.attemptNumber,
                executionIdentity: receipt.executionIdentity, compositeKey: receipt.compositeKey,
                parentRuntimeIdentity: receipt.parentRuntimeIdentity,
                childTranscriptLocator: receipt.childTranscriptLocator,
                targetTaskBinding: receipt.targetTaskBinding,
                targetTaskSource: receipt.targetTaskSource,
                browserDetail: browserDetail, outputSummary: outputSummary,
                elapsedMilliseconds: elapsedMilliseconds.map { max(0, $0) },
                failureCategory: failureCategory)
            draft.pending.removeValue(forKey: identifier)
            draft.facts[identifier] = fact
            draft.fileWrites?.removeValue(forKey: identifier)
            draft.unstartedFileWrites?.remove(identifier)
            return fact
        }
        if let fact { publishSettlement(fact, liveFailureReason: liveFailureReason) }
        return fact
    }
    public func reconcilePending() throws {
        if !pendingReceipts.isEmpty { throw ToolExecutionFactLedgerError.externalOutcomeUnverified }
    }
    public func prepareFileWrite(_ receipt: ToolExecutionReceipt) throws {
        try transaction { draft in
            let key = try Self.requirePending(receipt, draft)
            if draft.fileWrites?[key] == nil { draft.unstartedFileWrites?.insert(key) }
        }
    }
    public func beginFileWrite(_ receipt: ToolExecutionReceipt, targetPath: String,
                               expectedSHA256: String?, beforeSHA256: String?) throws {
        try transaction { draft in
            let key = try Self.requirePending(receipt, draft)
            guard !targetPath.isEmpty else { throw ToolExecutionFactLedgerError.invalidCanonicalIdentity }
            draft.fileWrites?[key] = PendingFileWriteEvidence(receiptID: receipt.receiptID,
                compositeKey: receipt.compositeKey!, targetPath: targetPath,
                beforeSHA256: beforeSHA256, expectedSHA256: expectedSHA256,
                completedSHA256: nil)
            draft.unstartedFileWrites?.remove(key)
        }
    }
    public func completeFileWrite(_ receipt: ToolExecutionReceipt, outputSHA256: String) throws {
        try transaction { draft in
            let key = try Self.requirePending(receipt, draft)
            guard let old = draft.fileWrites?[key], !outputSHA256.isEmpty,
                  old.expectedSHA256 == outputSHA256 else {
                throw ToolExecutionFactLedgerError.receiptIdentityMismatch
            }
            draft.fileWrites?[key] = PendingFileWriteEvidence(receiptID: old.receiptID,
                compositeKey: old.compositeKey, targetPath: old.targetPath,
                beforeSHA256: old.beforeSHA256, expectedSHA256: old.expectedSHA256,
                completedSHA256: outputSHA256)
        }
    }
    private static func requirePending(_ receipt: ToolExecutionReceipt,
                                       _ state: DiskState) throws -> String {
        guard let key = receipt.compositeKey, key.isValid else {
            throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
        }
        guard state.pending[key.rawValue] == receipt else {
            throw ToolExecutionFactLedgerError.unknownReceipt
        }
        return key.rawValue
    }
    public func pendingFileWriteEvidence(for receipt: ToolExecutionReceipt) -> PendingFileWriteEvidence? {
        stateLock.withLock {
            guard let key = receipt.compositeKey, state.pending[key.rawValue] == receipt else { return nil }
            return state.fileWrites?[key.rawValue]
        }
    }
    public func fileWriteWasNeverDispatched(_ receipt: ToolExecutionReceipt) -> Bool {
        stateLock.withLock {
            guard let key = receipt.compositeKey, state.pending[key.rawValue] == receipt else { return false }
            return startupPending.contains(receipt) &&
                state.unstartedFileWrites?.contains(key.rawValue) == true
        }
    }
}

public func sanitizeToolId(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics
    return String(value.unicodeScalars.map { scalar in
        allowed.contains(scalar) || scalar == "_" || scalar == "-" ? Character(scalar) : "-"
    })
}

public enum AgentParamType: String, Sendable { case string, integer, boolean, object }
public struct AgentToolParam: Sendable, Equatable {
    public let type: AgentParamType
    public let description: String
    public let enumValues: [String]?
    public init(type: AgentParamType, description: String, enumValues: [String]? = nil) {
        self.type = type; self.description = description; self.enumValues = enumValues
    }
}
public struct AgentToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: [String: AgentToolParam]
    public let required: [String]
    public let propertyOrdering: [String]?
    public init(name: String, description: String, parameters: [String: AgentToolParam],
                required: [String], propertyOrdering: [String]? = nil) {
        self.name = name; self.description = description
        self.parameters = parameters; self.required = required
        self.propertyOrdering = propertyOrdering
    }
    private var schema: [String: Any] {
        var properties: [String: Any] = [:]
        for (key, param) in parameters {
            var entry: [String: Any] = ["type": param.type.rawValue]
            if !param.description.isEmpty { entry["description"] = param.description }
            if let values = param.enumValues { entry["enum"] = values }
            properties[key] = entry
        }
        return ["type": "object", "properties": properties, "required": required]
    }
    public var openAIFunctionDict: [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                      "parameters": schema]]
    }
    public var anthropicToolDict: [String: Any] {
        ["name": name, "description": description, "input_schema": schema]
    }
}

public enum AgentContentPart: @unchecked Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(id: String, name: String, content: String, isError: Bool,
                    imageData: Data? = nil, imageMimeType: String? = nil,
                    pageURL: String? = nil, imagePath: String? = nil)
    case imageData(data: Data, mimeType: String, filename: String? = nil)
}
public struct AgentMessage: @unchecked Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let parts: [AgentContentPart]
    public let isInterrupted: Bool
    public let reasoningContent: String?
    public init(role: Role, parts: [AgentContentPart], isInterrupted: Bool = false,
                reasoningContent: String? = nil) {
        self.role = role; self.parts = parts
        self.isInterrupted = isInterrupted; self.reasoningContent = reasoningContent
    }
    public func gatingInlineMedia(for capabilities: ModelCapabilities) -> AgentMessage {
        let gated: [AgentContentPart] = parts.map { part in
            switch part {
            case .imageData(let data, let mime, let filename):
                let decision = MediaPayloadValidation.decision(data: data, mimeType: mime, capabilities: capabilities)
                if let note = MediaCapabilityGate.rejectionNote(for: decision, mimeType: mime) {
                    return .text(note)
                }
                return .imageData(data: data, mimeType: mime, filename: filename)
            case .toolResult(let id, let name, let content, let error, let bytes, let mime, let url, let path):
                guard let bytes, let mime else { return part }
                let decision = MediaPayloadValidation.decision(data: bytes, mimeType: mime, capabilities: capabilities)
                guard decision.isAllowed else {
                    return .toolResult(id: id, name: name, content: content, isError: error,
                                       imageData: nil, imageMimeType: nil, pageURL: url, imagePath: path)
                }
                return part
            default: return part
            }
        }
        return AgentMessage(role: role, parts: gated, isInterrupted: isInterrupted,
                            reasoningContent: reasoningContent)
    }
}
public enum AgentStopReason: String, Sendable { case endTurn, toolUse, maxTokens, refusal }
public enum AgentContentBlockStart: Sendable {
    case text
    case toolUse
    case mcpDiscoveryFailure(AgentToolCatalogDiscoveryFailure)
}
public enum ToolNonExecutionReason: Sendable, Equatable {
    case dryRun, blockedBeforeExecution, requestPreflightExpired
}
/// Non-Codable feedback accompanying one successful durable settlement.
/// It carries no raw error text/path and is never an authorization decision.
public struct ToolExecutionLiveFailureFeedback: Sendable {
    public enum Reason: Equatable, Sendable { case builtinFileReadPermissionDenied }
    public let compositeKey: ToolExecutionCompositeKey
    public let receiptID: String
    public let executionIdentity: AgentExecutionIdentity
    public let reason: Reason
    fileprivate init(fact: ToolExecutionFact, key: ToolExecutionCompositeKey,
                     execution: AgentExecutionIdentity, reason: Reason) {
        compositeKey = key; receiptID = fact.receiptID
        executionIdentity = execution; self.reason = reason
    }
}

public struct ToolCallMetadata: @unchecked Sendable {
    public let thoughtSignature: String?
    public let toolExecutionFact: ToolExecutionFact?
    public let orchestrationMessages: [LLMMessage]
    public let nonExecutionReason: ToolNonExecutionReason?
    public let liveFailureFeedback: ToolExecutionLiveFailureFeedback?
    public init(thoughtSignature: String? = nil, toolExecutionFact: ToolExecutionFact? = nil,
                orchestrationMessages: [LLMMessage] = [],
                nonExecutionReason: ToolNonExecutionReason? = nil,
                liveFailureFeedback: ToolExecutionLiveFailureFeedback? = nil) {
        self.thoughtSignature = thoughtSignature
        self.toolExecutionFact = toolExecutionFact
        self.orchestrationMessages = orchestrationMessages
        self.nonExecutionReason = nonExecutionReason
        self.liveFailureFeedback = liveFailureFeedback
    }
}
public enum AgentStreamEvent: @unchecked Sendable {
    case contentBlockStart(AgentContentBlockStart)
    case textDelta(String)
    case toolInputDelta(String)
    case toolCallComplete(id: String, name: String, args: [String: Any], metadata: ToolCallMetadata? = nil)
    case toolExecutionPhase(ToolExecutionPhaseFact)
    case approvalLifecycle(ApprovalLifecycleFact)
    case usage(LLMUsage)
    case thinkingDelta(String)
    case reasoningContent(String)
    case done(stopReason: AgentStopReason)
}

public protocol AgentProvider: Sendable {
    var name: String { get }
    var model: LLMModel { get }
    var defaultMaxTokens: Int { get }
    func streamAgentMessageClamped(messages: [AgentMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, thinkingLevel: ThinkingLevel?) async throws
        -> AsyncThrowingStream<AgentStreamEvent, Error>
}
public extension AgentProvider {
    func streamAgentMessage(messages: [AgentMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int? = nil,
        thinkingLevel: ThinkingLevel? = nil) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let requested = thinkingLevel ?? .off
        let maximum = model.catalogMaxThinkingLevel
        let clamped = min(requested, maximum)
        let gated = messages.map { $0.gatingInlineMedia(for: model.capabilities) }
        return try await streamAgentMessageClamped(messages: gated, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens ?? defaultMaxTokens, thinkingLevel: clamped)
    }
}
