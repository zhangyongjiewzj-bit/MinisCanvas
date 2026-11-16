import Foundation

// AgentContext owns the provider/executor handles that are already boxed by
// their Core protocols. The actor below serializes access to one turn, so this
// bridge keeps Swift 6 from treating the local mutable turn as actor-shared.
extension AgentContext: @unchecked Sendable {}

/// Conversation intent and execution are separate axes.  A conversation mode
/// changes how a turn is described; it never grants a capability by itself.
public enum ChatConversationMode: String, Codable, Equatable, Hashable, Sendable {
    case discuss
    case directTask
    case hybrid
    case agentGuided
}

public enum ChatOperationMode: String, Codable, Equatable, Hashable, Sendable {
    case manual
    case edit
    case plan
    case auto
    case boundedAuto
    case bypass
}

public enum ChatReasoningSummaryMode: String, Codable, Equatable, Hashable, Sendable {
    case none
    case concise
    case detailed
}

public enum ChatSessionRuntimeError: Error, Equatable, Sendable {
    case invalidSession
    case invalidScope
    case startupNotReady
    case toolCatalogMissing
    case toolExecutionFactLedgerMissing
    case executionIdentityMissing
    case partialHistoryInvalid
    case retrySnapshotMissing
    case retryTurnNotActive
    case turnFailed(ChatRetryEnvelope)
    case contextMismatch
    case providerRuntimeSnapshotMissing
    case personaMismatch
    case skillScopeMismatch
    case bypassNotAllowed
    case proposalExpired
    case proposalNotFound
    case duplicateCapsuleSend
    case capsuleSessionMismatch
    case capsuleTextMismatch
}

public struct ChatRetryFailureError: LocalizedError, Equatable, Sendable {
    public let originalMessage: String
    public let retryMessage: String

    public init(originalMessage: String, retryMessage: String) {
        self.originalMessage = originalMessage
        self.retryMessage = retryMessage
    }

    public var errorDescription: String? {
        "Turn failed: \(originalMessage); retry failure: \(retryMessage)"
    }
}

public enum ChatRetryTurnState: Equatable, Sendable {
    case unknown
    case active
    case finished
    case cancelled
}

public enum ChatRetryEnvelopeRejection: String, Codable, Equatable, Hashable, Sendable {
    case invalidAttempt
    case invalidIdentity
    case invalidPartialHistory
}

/// Immutable identity facts frozen when a chat turn is prepared.
public struct ChatRuntimeContext: Codable, Equatable, Hashable, Sendable {
    public let sessionID: String
    public let conversationID: String
    public let providerID: String
    public let modelID: String
    public let personaID: String
    public let memoryScope: MemoryScope
    public let skillIDs: [String]
    public let conversationMode: ChatConversationMode
    public let operationMode: ChatOperationMode
    public let reasoningSummaryMode: ChatReasoningSummaryMode
    public let snapshot: ConversationContextSnapshotV1

    public init(
        sessionID: String,
        conversationID: String,
        providerID: String,
        modelID: String,
        personaID: String,
        memoryScope: MemoryScope,
        skillIDs: [String],
        conversationMode: ChatConversationMode = .discuss,
        operationMode: ChatOperationMode = .auto,
        reasoningSummaryMode: ChatReasoningSummaryMode = .concise,
        configurationFingerprint: String? = nil
    ) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.providerID = providerID
        self.modelID = modelID
        self.personaID = personaID
        self.memoryScope = memoryScope
        self.skillIDs = skillIDs
        self.conversationMode = conversationMode
        self.operationMode = operationMode
        self.reasoningSummaryMode = reasoningSummaryMode
        self.snapshot = ConversationContextSnapshotV1(
            sessionID: sessionID,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint
                ?? "provider:\(providerID)|model:\(modelID)",
            skillIdentifiers: skillIDs,
            conversationID: conversationID
        )
    }
}

public struct ChatInputCapsule: Codable, Equatable, Hashable, Sendable {
    public let capsuleID: String
    public let sessionID: String
    public let originalSnapshot: String
    public let sendSnapshot: String

    public init(
        capsuleID: String = UUID().uuidString,
        sessionID: String,
        originalSnapshot: String,
        sendSnapshot: String
    ) {
        self.capsuleID = capsuleID
        self.sessionID = sessionID
        self.originalSnapshot = originalSnapshot
        self.sendSnapshot = sendSnapshot
    }
}

/// Immutable failure/retry facts. A retry consumer can serialize this
/// envelope and replay it without consulting mutable session, provider, policy,
/// or grant state.
public struct ChatRetryEnvelope: Codable, Equatable, Hashable, Sendable {
    public let envelopeID: String
    public let inputText: String
    public let sessionID: String
    public let conversationID: String
    public let turnID: String
    public let taskID: String
    public let attempt: Int
    public let providerID: String
    public let modelID: String
    public let configurationFingerprint: String
    public let policySnapshotID: String
    public let grantSnapshotID: String
    public let executionIdentity: AgentExecutionIdentity?
    public let canonicalAttemptID: String?
    public let identityBinding: String?
    public let toolCalls: [LLMToolCall]
    public let partialMessages: [LLMMessage]
    public let toolExecutionFacts: [ToolExecutionFact]
    public let failureMessage: String
    public let createdAt: Date
    public let rejection: ChatRetryEnvelopeRejection?

    public var toolCallIDs: [String] {
        toolCalls.map(\.id)
    }

    public var policyRevision: String {
        policySnapshotID
    }

    public var grantEpoch: String {
        grantSnapshotID
    }

    private enum CodingKeys: String, CodingKey {
        case envelopeID
        case inputText
        case sessionID
        case conversationID
        case turnID
        case taskID
        case attempt
        case providerID
        case modelID
        case configurationFingerprint
        case policySnapshotID
        case grantSnapshotID
        case executionIdentity
        case canonicalAttemptID
        case identityBinding
        case toolCalls
        case partialMessages
        case toolExecutionFacts
        case failureMessage
        case createdAt
        case rejection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let envelopeID = try c.decode(String.self, forKey: .envelopeID)
        let inputText = try c.decode(String.self, forKey: .inputText)
        let sessionID = try c.decode(String.self, forKey: .sessionID)
        let conversationID = try c.decode(String.self, forKey: .conversationID)
        let turnID = try c.decode(String.self, forKey: .turnID)
        let taskID = try c.decode(String.self, forKey: .taskID)
        let attempt = try c.decode(Int.self, forKey: .attempt)
        let providerID = try c.decode(String.self, forKey: .providerID)
        let modelID = try c.decode(String.self, forKey: .modelID)
        let configurationFingerprint = try c.decode(
            String.self,
            forKey: .configurationFingerprint
        )
        let policySnapshotID = try c.decode(String.self, forKey: .policySnapshotID)
        let grantSnapshotID = try c.decode(String.self, forKey: .grantSnapshotID)
        let executionIdentity = try c.decodeIfPresent(
            AgentExecutionIdentity.self,
            forKey: .executionIdentity
        )
        let canonicalAttemptID = try c.decodeIfPresent(
            String.self,
            forKey: .canonicalAttemptID
        )
        let identityBinding = try c.decodeIfPresent(
            String.self,
            forKey: .identityBinding
        )
        let toolCalls = try c.decodeIfPresent([LLMToolCall].self, forKey: .toolCalls) ?? []
        let partialMessages = try c.decodeIfPresent(
            [LLMMessage].self,
            forKey: .partialMessages
        ) ?? []
        let toolExecutionFacts = try c.decodeIfPresent(
            [ToolExecutionFact].self,
            forKey: .toolExecutionFacts
        ) ?? []
        let failureMessage = try c.decode(String.self, forKey: .failureMessage)
        let createdAt = try c.decode(Date.self, forKey: .createdAt)
        let rejection = try c.decodeIfPresent(
            ChatRetryEnvelopeRejection.self,
            forKey: .rejection
        )

        if let rejection = Self.validationRejection(
            envelopeID: envelopeID,
            sessionID: sessionID,
            conversationID: conversationID,
            turnID: turnID,
            taskID: taskID,
            attempt: attempt,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            policySnapshotID: policySnapshotID,
            grantSnapshotID: grantSnapshotID,
            executionIdentity: executionIdentity,
            canonicalAttemptID: canonicalAttemptID,
            identityBinding: identityBinding,
            partialMessages: partialMessages,
            toolCalls: toolCalls,
            toolExecutionFacts: toolExecutionFacts
        ) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "retry envelope rejected as \(rejection.rawValue)"
            ))
        }
        self.init(
            envelopeID: envelopeID,
            inputText: inputText,
            sessionID: sessionID,
            conversationID: conversationID,
            turnID: turnID,
            taskID: taskID,
            attempt: attempt,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            policySnapshotID: policySnapshotID,
            grantSnapshotID: grantSnapshotID,
            executionIdentity: executionIdentity,
            canonicalAttemptID: canonicalAttemptID,
            identityBinding: identityBinding,
            toolCalls: toolCalls,
            partialMessages: partialMessages,
            toolExecutionFacts: toolExecutionFacts,
            failureMessage: failureMessage,
            createdAt: createdAt,
            rejection: rejection
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(envelopeID, forKey: .envelopeID)
        try c.encode(inputText, forKey: .inputText)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(conversationID, forKey: .conversationID)
        try c.encode(turnID, forKey: .turnID)
        try c.encode(taskID, forKey: .taskID)
        try c.encode(attempt, forKey: .attempt)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(modelID, forKey: .modelID)
        try c.encode(configurationFingerprint, forKey: .configurationFingerprint)
        try c.encode(policySnapshotID, forKey: .policySnapshotID)
        try c.encode(grantSnapshotID, forKey: .grantSnapshotID)
        try c.encode(executionIdentity, forKey: .executionIdentity)
        try c.encodeIfPresent(canonicalAttemptID, forKey: .canonicalAttemptID)
        try c.encodeIfPresent(identityBinding, forKey: .identityBinding)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encode(partialMessages, forKey: .partialMessages)
        try c.encode(toolExecutionFacts, forKey: .toolExecutionFacts)
        try c.encode(failureMessage, forKey: .failureMessage)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(rejection, forKey: .rejection)
    }

    public init(
        envelopeID: String,
        inputText: String,
        sessionID: String,
        conversationID: String,
        turnID: String,
        taskID: String,
        attempt: Int,
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        policySnapshotID: String,
        grantSnapshotID: String,
        executionIdentity: AgentExecutionIdentity? = nil,
        canonicalAttemptID: String? = nil,
        identityBinding: String? = nil,
        toolCalls: [LLMToolCall] = [],
        partialMessages: [LLMMessage] = [],
        toolExecutionFacts: [ToolExecutionFact] = [],
        failureMessage: String,
        createdAt: Date = Date(),
        rejection: ChatRetryEnvelopeRejection? = nil
    ) {
        self.envelopeID = envelopeID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.inputText = inputText
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTurnID = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.turnID = normalizedTurnID
        self.taskID = normalizedTaskID
        self.attempt = attempt
        self.providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configurationFingerprint = configurationFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.policySnapshotID = policySnapshotID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.grantSnapshotID = grantSnapshotID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.executionIdentity = executionIdentity
        let expectedAttemptID = executionIdentity.flatMap {
            AgentToolExecutionAttemptID.canonical(
                executionIdentity: $0,
                composerSnapshot: nil,
                childBoundary: nil
            )
        }
        let resolvedAttemptID = canonicalAttemptID ?? expectedAttemptID
        self.canonicalAttemptID = resolvedAttemptID
        let expectedBinding = executionIdentity.map {
            Self.identityBinding(
                identity: $0,
                canonicalAttemptID: resolvedAttemptID ?? "",
                turnID: normalizedTurnID,
                taskID: normalizedTaskID
            )
        }
        self.identityBinding = identityBinding ?? expectedBinding
        self.toolCalls = toolCalls
        self.partialMessages = partialMessages
        self.toolExecutionFacts = toolExecutionFacts
        self.failureMessage = ConversationEventRedactor.redact(failureMessage)
        self.createdAt = createdAt
        let validationRejection = Self.validationRejection(
            envelopeID: self.envelopeID,
            sessionID: self.sessionID,
            conversationID: self.conversationID,
            turnID: self.turnID,
            taskID: self.taskID,
            attempt: self.attempt,
            providerID: self.providerID,
            modelID: self.modelID,
            configurationFingerprint: self.configurationFingerprint,
            policySnapshotID: self.policySnapshotID,
            grantSnapshotID: self.grantSnapshotID,
            executionIdentity: self.executionIdentity,
            canonicalAttemptID: self.canonicalAttemptID,
            identityBinding: self.identityBinding,
            partialMessages: self.partialMessages,
            toolCalls: self.toolCalls,
            toolExecutionFacts: self.toolExecutionFacts
        )
        self.rejection = validationRejection ?? rejection
    }

    public func withRejection(
        _ rejection: ChatRetryEnvelopeRejection
    ) -> ChatRetryEnvelope {
        ChatRetryEnvelope(
            envelopeID: envelopeID,
            inputText: inputText,
            sessionID: sessionID,
            conversationID: conversationID,
            turnID: turnID,
            taskID: taskID,
            attempt: attempt,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            policySnapshotID: policySnapshotID,
            grantSnapshotID: grantSnapshotID,
            executionIdentity: executionIdentity,
            canonicalAttemptID: canonicalAttemptID,
            identityBinding: identityBinding,
            toolCalls: toolCalls,
            partialMessages: partialMessages,
            toolExecutionFacts: toolExecutionFacts,
            failureMessage: failureMessage,
            createdAt: createdAt,
            rejection: rejection
        )
    }

    static func identityBinding(
        identity: AgentExecutionIdentity,
        canonicalAttemptID: String,
        turnID: String,
        taskID: String
    ) -> String {
        [
            identity.turn.sessionID,
            String(identity.turn.turnID),
            identity.turn.messageID,
            identity.operationID,
            String(identity.attempt),
            canonicalAttemptID,
            turnID,
            taskID,
        ].map { value in
            "\(value.utf8.count)#\(value)"
        }.joined()
    }

    static func validatePartialHistory(
        partialMessages: [LLMMessage],
        toolCalls: [LLMToolCall],
        facts: [ToolExecutionFact],
        executionIdentity: AgentExecutionIdentity,
        sessionID: String,
        attempt: Int,
        canonicalAttemptID: String?
    ) -> Bool {
        guard let canonicalAttemptID,
              !canonicalAttemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let expectedIDs = toolCalls.map(\.id)
        guard Set(expectedIDs).count == expectedIDs.count,
              toolCalls.allSatisfy({
                  !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.rawArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return false
        }
        if expectedIDs.isEmpty {
            return facts.isEmpty
                && (partialMessages.isEmpty || partialMessages.map(\.role) == [.user])
        }
        let partialToolCalls = partialMessages.flatMap(\.toolCalls)
        let partialCallIDs = partialToolCalls.map(\.id)
        let partialResultIDs = partialMessages.compactMap {
            $0.role == .tool ? $0.toolCallID : nil
        }
        let factIDs = facts.map(\.toolCallID)
        let expectedNames = toolCalls.map(\.name)
        let expectedRawArguments = toolCalls.map(\.rawArguments)
        let expectedRoles: [LLMMessage.Role] =
            [.user, .assistant] + Array(repeating: .tool, count: expectedIDs.count)
        guard partialMessages.map(\.role) == expectedRoles,
              partialCallIDs == expectedIDs,
              partialResultIDs == expectedIDs,
              factIDs == expectedIDs,
              partialToolCalls.map(\.name) == expectedNames,
              partialToolCalls.map(\.rawArguments) == expectedRawArguments,
              facts.map(\.toolName) == expectedNames,
              partialToolCalls.allSatisfy({
                  !$0.rawArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              partialMessages.filter({ $0.role == .tool }).allSatisfy({
                  !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              facts.allSatisfy({
                  guard let key = $0.compositeKey else { return false }
                  return $0.executionIdentity == executionIdentity
                      && $0.attemptNumber == attempt
                      && $0.attemptID == canonicalAttemptID
                      && key.sessionID == sessionID
                      && key.turnID == executionIdentity.turn.turnID
                      && key.messageID == executionIdentity.turn.messageID
                      && key.operationID == executionIdentity.operationID
                      && key.attemptID == $0.attemptID
                      && key.attemptNumber == attempt
                      && key.toolCallID == $0.toolCallID
              }) else {
            return false
        }
        return true
    }

    fileprivate static func validationRejection(
        envelopeID: String,
        sessionID: String,
        conversationID: String,
        turnID: String,
        taskID: String,
        attempt: Int,
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        policySnapshotID: String,
        grantSnapshotID: String,
        executionIdentity: AgentExecutionIdentity?,
        canonicalAttemptID: String?,
        identityBinding: String?,
        partialMessages: [LLMMessage],
        toolCalls: [LLMToolCall],
        toolExecutionFacts: [ToolExecutionFact]
    ) -> ChatRetryEnvelopeRejection? {
        guard attempt > 0 else { return .invalidAttempt }
        let requiredStrings = [
            envelopeID, sessionID, conversationID, turnID, taskID,
            providerID, modelID, configurationFingerprint,
            policySnapshotID, grantSnapshotID,
        ]
        guard requiredStrings.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return .invalidIdentity
        }
        guard let executionIdentity,
              executionIdentity.isValid,
              executionIdentity.attempt == attempt,
              executionIdentity.turn.sessionID == sessionID,
              let canonicalAttemptID,
              !canonicalAttemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identityBinding == Self.identityBinding(
                  identity: executionIdentity,
                  canonicalAttemptID: canonicalAttemptID,
                  turnID: turnID,
                  taskID: taskID
              ) else {
            return .invalidIdentity
        }
        guard validatePartialHistory(
            partialMessages: partialMessages,
            toolCalls: toolCalls,
            facts: toolExecutionFacts,
            executionIdentity: executionIdentity,
            sessionID: sessionID,
            attempt: attempt,
            canonicalAttemptID: canonicalAttemptID
        ) else {
            return .invalidPartialHistory
        }
        return nil
    }
}

public struct ChatTurnRequest: Sendable {
    public let text: String
    public let context: ChatRuntimeContext
    public let sessionID: String?
    public let operationMode: ChatOperationMode?
    public let capsule: ChatInputCapsule?
    public let turnID: String?
    public let taskID: String?
    public let attempt: Int
    public let policySnapshotID: String?
    public let grantSnapshotID: String?
    public let executionIdentity: AgentExecutionIdentity?
    public let composerSnapshot: ComposerSubmissionSnapshot?

    public init(
        text: String,
        context: ChatRuntimeContext,
        sessionID: String? = nil,
        operationMode: ChatOperationMode? = nil,
        capsule: ChatInputCapsule? = nil,
        turnID: String? = nil,
        taskID: String? = nil,
        attempt: Int = 1,
        policySnapshotID: String? = nil,
        grantSnapshotID: String? = nil,
        policyRevision: String? = nil,
        grantEpoch: String? = nil,
        executionIdentity: AgentExecutionIdentity? = nil,
        composerSnapshot: ComposerSubmissionSnapshot? = nil
    ) {
        self.text = text
        self.context = context
        self.sessionID = sessionID
        self.operationMode = operationMode
        self.capsule = capsule
        self.turnID = turnID
        self.taskID = taskID
        self.attempt = attempt
        self.policySnapshotID = policySnapshotID ?? policyRevision
        self.grantSnapshotID = grantSnapshotID ?? grantEpoch
        self.executionIdentity = executionIdentity
        self.composerSnapshot = composerSnapshot
    }
}

public struct ChatTurnResult: Sendable {
    public let messages: [LLMMessage]
    public let context: ChatRuntimeContext
    public let isDryRun: Bool
    public let matchedSkillIDs: [String]
    public let reasoningSummary: String?
    public let executionIdentity: AgentExecutionIdentity?
    public let toolExecutionFacts: [ToolExecutionFact]

    public init(
        messages: [LLMMessage],
        context: ChatRuntimeContext,
        isDryRun: Bool,
        matchedSkillIDs: [String],
        reasoningSummary: String? = nil,
        executionIdentity: AgentExecutionIdentity? = nil,
        toolExecutionFacts: [ToolExecutionFact] = []
    ) {
        self.messages = messages
        self.context = context
        self.isDryRun = isDryRun
        self.matchedSkillIDs = matchedSkillIDs
        self.reasoningSummary = reasoningSummary
        self.executionIdentity = executionIdentity
        self.toolExecutionFacts = toolExecutionFacts
    }
}

public struct ChatMemoryProposal: Codable, Equatable, Sendable {
    public let proposalID: String
    public let text: String
    public let context: ChatRuntimeContext
    public let envelope: MemoryProposalEnvelope
    public let expiresAt: Date

    public init(
        proposalID: String,
        text: String,
        context: ChatRuntimeContext,
        envelope: MemoryProposalEnvelope,
        expiresAt: Date
    ) {
        self.proposalID = proposalID
        self.text = text
        self.context = context
        self.envelope = envelope
        self.expiresAt = expiresAt
    }
}

/// MinisCore's real session/chat consumer.  It is deliberately independent
/// from Canvas, BridgeStore and UI: ordinary chat has no Canvas identity,
/// approval scope, revision or mutation receipt.
public actor ChatSessionRuntime {
    /// An admitted App turn can retain its Soul selection through asynchronous
    /// Provider and context preparation. Other callers keep the live selector.
    public enum SoulTurnSelection: Sendable {
        case live
        case frozen(Soul?)
    }

    public let sessionStore: SessionStore
    public let memoryStore: MemoryStore
    public let skillStore: SkillStore
    /// Frozen by the composition owner; legacy consumers retain enabled behavior.
    private let skillsEnabled: Bool
    public let soulStore: SoulStore
    private let soulTurnSelection: SoulTurnSelection
    public let provider: any LLMProvider
    public let toolExecutor: any ToolExecutor
    public let toolCatalog: [AgentToolDefinition]?
    public let toolExecutionFactLedger: ToolExecutionFactLedger?
    private let providerRuntimeRoute: ProviderRuntimeRoute?
    private var startupReady: Bool
    private var latestRetryEnvelopeStorage: ChatRetryEnvelope?
    private struct RetryTurnIdentity: Hashable, Sendable {
        let sessionID: String
        let conversationID: String
        let turnID: String
        let taskID: String
        let attempt: Int
    }
    private var activeRetryTurn: RetryTurnIdentity?
    private var retiredRetryTurns: Set<RetryTurnIdentity> = []
    private var cancelledRetryTurns: Set<RetryTurnIdentity> = []

    private let memoryProposalConsumer: MemoryProposalConsumer
    private var sentCapsuleIDs: Set<String> = []
    private var inFlightCapsuleIDs: Set<String> = []
    private struct ApprovedMemoryRollback: Sendable {
        let factID: String
        let scope: MemoryScope
    }

    private var memoryRollbacks: [String: ApprovedMemoryRollback] = [:]

    public init(
        sessionStore: SessionStore,
        memoryStore: MemoryStore,
        skillStore: SkillStore,
        skillsEnabled: Bool = true,
        soulStore: SoulStore,
        soulTurnSelection: SoulTurnSelection = .live,
        provider: any LLMProvider,
        toolExecutor: any ToolExecutor,
        startupReady: Bool = true,
        toolCatalog: [AgentToolDefinition]? = nil,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil
    ) {
        self.sessionStore = sessionStore
        self.memoryStore = memoryStore
        self.skillStore = skillStore
        self.skillsEnabled = skillsEnabled
        self.soulStore = soulStore
        self.soulTurnSelection = soulTurnSelection
        self.provider = provider
        self.toolExecutor = toolExecutor
        self.toolCatalog = toolCatalog
        self.toolExecutionFactLedger = toolExecutionFactLedger
        self.providerRuntimeRoute = nil
        self.startupReady = startupReady
        self.latestRetryEnvelopeStorage = nil
        self.memoryProposalConsumer = MemoryProposalConsumer(store: memoryStore)
    }

    /// Production consumer receives the route already frozen on the provider
    /// owner's actor. The session actor stores only that Sendable route handle.
    public init(
        sessionStore: SessionStore,
        memoryStore: MemoryStore,
        skillStore: SkillStore,
        skillsEnabled: Bool = true,
        soulStore: SoulStore,
        soulTurnSelection: SoulTurnSelection = .live,
        providerRuntimeRoute: ProviderRuntimeRoute,
        toolExecutor: any ToolExecutor,
        startupReady: Bool = true,
        toolCatalog: [AgentToolDefinition]? = nil,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil
    ) {
        self.sessionStore = sessionStore
        self.memoryStore = memoryStore
        self.skillStore = skillStore
        self.skillsEnabled = skillsEnabled
        self.soulStore = soulStore
        self.soulTurnSelection = soulTurnSelection
        self.provider = providerRuntimeRoute
        self.toolExecutor = toolExecutor
        self.toolCatalog = toolCatalog
        self.toolExecutionFactLedger = toolExecutionFactLedger
        self.providerRuntimeRoute = providerRuntimeRoute
        self.startupReady = startupReady
        self.latestRetryEnvelopeStorage = nil
        self.memoryProposalConsumer = MemoryProposalConsumer(store: memoryStore)
    }

    /// Compatibility constructor for composition roots that still supply raw
    /// providers. It freezes them on their owning actor before actor storage.
    @MainActor
    public init(
        sessionStore: SessionStore,
        memoryStore: MemoryStore,
        skillStore: SkillStore,
        skillsEnabled: Bool = true,
        soulStore: SoulStore,
        soulTurnSelection: SoulTurnSelection = .live,
        provider: any LLMProvider,
        toolExecutor: any ToolExecutor,
        providerRuntimeSnapshot: ProviderRuntimeSnapshot,
        fallbackProviders: [any LLMProvider] = [],
        providerRuntimeObservationSink: (@Sendable (ProviderRuntimeRouteObservation) -> Void)? = nil,
        startupReady: Bool = true,
        toolCatalog: [AgentToolDefinition]? = nil,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil
    ) throws {
        let route = try ProviderRuntimeRoute(
            snapshot: providerRuntimeSnapshot,
            primary: provider,
            fallbacks: fallbackProviders,
            observationSink: providerRuntimeObservationSink
        )
        self.init(
            sessionStore: sessionStore,
            memoryStore: memoryStore,
            skillStore: skillStore,
            skillsEnabled: skillsEnabled,
            soulStore: soulStore,
            soulTurnSelection: soulTurnSelection,
            providerRuntimeRoute: route,
            toolExecutor: toolExecutor,
            startupReady: startupReady,
            toolCatalog: toolCatalog,
            toolExecutionFactLedger: toolExecutionFactLedger
        )
    }

    public var isStartupReady: Bool {
        startupReady
    }

    public var latestRetryEnvelope: ChatRetryEnvelope? {
        latestRetryEnvelopeStorage
    }

    /// Releases the startup gate exactly once. Existing composition roots
    /// default to ready for compatibility; recovery-aware roots can construct
    /// the runtime as not ready and open the gate after bootstrap completes.
    @discardableResult
    public func markStartupReady() -> Bool {
        guard !startupReady else { return false }
        startupReady = true
        return true
    }

    public func makeContext(
        sessionID: String,
        conversationID: String? = nil,
        personaID: String? = nil,
        skillIDs: [String]? = nil,
        conversationMode: ChatConversationMode = .discuss,
        operationMode: ChatOperationMode = .auto,
        reasoningSummaryMode: ChatReasoningSummaryMode = .concise
    ) throws -> ChatRuntimeContext {
        guard let session = sessionStore.loadSession(id: sessionID),
              let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectID.isEmpty,
              let soul = selectedSoul() else {
            throw ChatSessionRuntimeError.invalidScope
        }

        let scope = MemoryScope(sessionID: session.id, projectID: projectID)
        guard scope.isValid else { throw ChatSessionRuntimeError.invalidScope }
        if let personaID, personaID != soul.id {
            throw ChatSessionRuntimeError.personaMismatch
        }

        let pinnedSkillIDs = skillIDs ?? (skillsEnabled
            ? skillStore.allSkills().filter { skillStore.isInjectable($0, within: scope) }.map(\.id).sorted()
            : [])
        guard skillsEnabled || pinnedSkillIDs.isEmpty else {
            throw ChatSessionRuntimeError.skillScopeMismatch
        }
        for skillID in pinnedSkillIDs {
            guard let skill = skillStore.allSkills().first(where: { $0.id == skillID }),
                  skillStore.isInjectable(skill, within: scope) else {
                throw ChatSessionRuntimeError.skillScopeMismatch
            }
        }

        return ChatRuntimeContext(
            sessionID: session.id,
            conversationID: conversationID ?? session.id,
            providerID: provider.name,
            modelID: provider.model.id,
            personaID: soul.id,
            memoryScope: scope,
            skillIDs: pinnedSkillIDs,
            conversationMode: conversationMode,
            operationMode: operationMode,
            reasoningSummaryMode: reasoningSummaryMode,
            configurationFingerprint: providerRuntimeRoute?.snapshot.configurationFingerprint
        )
    }

    /// Capture retry facts from the request and its already-frozen context.
    /// This method intentionally performs no session/provider/policy lookup.
    public func makeRetryEnvelope(
        request: ChatTurnRequest,
        failureMessage: String,
        toolCalls: [LLMToolCall] = [],
        partialMessages: [LLMMessage] = [],
        toolExecutionFacts: [ToolExecutionFact] = [],
        envelopeID: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> ChatRetryEnvelope {
        let turnID: String
        if let rawTurnID = request.turnID {
            let trimmed = rawTurnID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                turnID = trimmed
            } else {
                turnID = request.context.conversationID
            }
        } else {
            turnID = request.context.conversationID
        }
        let taskID: String
        if let rawTaskID = request.taskID {
            let trimmed = rawTaskID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                taskID = trimmed
            } else {
                taskID = "task:\(request.context.sessionID):\(turnID)"
            }
        } else {
            taskID = "task:\(request.context.sessionID):\(turnID)"
        }
        let policySnapshotID = request.policySnapshotID.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let grantSnapshotID = request.grantSnapshotID.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let policySnapshotID, !policySnapshotID.isEmpty,
              let grantSnapshotID, !grantSnapshotID.isEmpty else {
            throw ChatSessionRuntimeError.retrySnapshotMissing
        }
        guard let executionIdentity = request.executionIdentity,
              executionIdentity.isValid,
              executionIdentity.attempt == request.attempt,
              executionIdentity.turn.sessionID == request.context.sessionID else {
            throw ChatSessionRuntimeError.executionIdentityMissing
        }
        guard let canonicalAttemptID = AgentToolExecutionAttemptID.canonical(
            executionIdentity: executionIdentity,
            composerSnapshot: request.composerSnapshot,
            childBoundary: nil
        ) else {
            throw ChatSessionRuntimeError.executionIdentityMissing
        }
        guard isValidPartialHistory(
            partialMessages: partialMessages,
            toolCalls: toolCalls,
            facts: toolExecutionFacts,
            executionIdentity: executionIdentity,
            sessionID: request.context.sessionID,
            attempt: request.attempt,
            canonicalAttemptID: canonicalAttemptID
        ) else {
            throw ChatSessionRuntimeError.partialHistoryInvalid
        }

        return ChatRetryEnvelope(
            envelopeID: envelopeID,
            inputText: request.text,
            sessionID: request.context.sessionID,
            conversationID: request.context.conversationID,
            turnID: turnID,
            taskID: taskID,
            attempt: request.attempt,
            providerID: request.context.providerID,
            modelID: request.context.modelID,
            configurationFingerprint: request.context.snapshot.configurationFingerprint,
            policySnapshotID: policySnapshotID,
            grantSnapshotID: grantSnapshotID,
            executionIdentity: executionIdentity,
            canonicalAttemptID: canonicalAttemptID,
            toolCalls: toolCalls,
            partialMessages: partialMessages,
            toolExecutionFacts: toolExecutionFacts,
            failureMessage: failureMessage,
            createdAt: createdAt
        )
    }

    private func isValidPartialHistory(
        partialMessages: [LLMMessage],
        toolCalls: [LLMToolCall],
        facts: [ToolExecutionFact],
        executionIdentity: AgentExecutionIdentity,
        sessionID: String,
        attempt: Int,
        canonicalAttemptID: String
    ) -> Bool {
        ChatRetryEnvelope.validatePartialHistory(
            partialMessages: partialMessages,
            toolCalls: toolCalls,
            facts: facts,
            executionIdentity: executionIdentity,
            sessionID: sessionID,
            attempt: attempt,
            canonicalAttemptID: canonicalAttemptID
        )
    }

    /// Retry is an envelope replay boundary only. It never revalidates or
    /// re-resolves mutable active state and never calls a Provider.
    public func retryEnvelope(_ envelope: ChatRetryEnvelope) -> ChatRetryEnvelope {
        if let rejection = ChatRetryEnvelope.validationRejection(
            envelopeID: envelope.envelopeID,
            sessionID: envelope.sessionID,
            conversationID: envelope.conversationID,
            turnID: envelope.turnID,
            taskID: envelope.taskID,
            attempt: envelope.attempt,
            providerID: envelope.providerID,
            modelID: envelope.modelID,
            configurationFingerprint: envelope.configurationFingerprint,
            policySnapshotID: envelope.policySnapshotID,
            grantSnapshotID: envelope.grantSnapshotID,
            executionIdentity: envelope.executionIdentity,
            canonicalAttemptID: envelope.canonicalAttemptID,
            identityBinding: envelope.identityBinding,
            partialMessages: envelope.partialMessages,
            toolCalls: envelope.toolCalls,
            toolExecutionFacts: envelope.toolExecutionFacts
        ) {
            return envelope.withRejection(rejection)
        }
        return envelope
    }

    @discardableResult
    public func beginRetryTurn(_ request: ChatTurnRequest) throws -> Bool {
        let identity = try retryTurnIdentity(for: request)
        guard activeRetryTurn == nil, !retiredRetryTurns.contains(identity) else {
            return false
        }
        activeRetryTurn = identity
        return true
    }

    @discardableResult
    public func finishRetryTurn(_ request: ChatTurnRequest) -> Bool {
        guard let identity = try? retryTurnIdentity(for: request),
              activeRetryTurn == identity else {
            return false
        }
        activeRetryTurn = nil
        retiredRetryTurns.insert(identity)
        cancelledRetryTurns.remove(identity)
        return true
    }

    @discardableResult
    public func cancelRetryTurn(_ request: ChatTurnRequest) -> Bool {
        guard let identity = try? retryTurnIdentity(for: request),
              activeRetryTurn == identity else {
            return false
        }
        activeRetryTurn = nil
        retiredRetryTurns.insert(identity)
        cancelledRetryTurns.insert(identity)
        return true
    }

    public func retryTurnState(
        for request: ChatTurnRequest
    ) -> ChatRetryTurnState {
        guard let identity = try? retryTurnIdentity(for: request) else {
            return .unknown
        }
        if activeRetryTurn == identity {
            return .active
        }
        if cancelledRetryTurns.contains(identity) {
            return .cancelled
        }
        if retiredRetryTurns.contains(identity) {
            return .finished
        }
        return .unknown
    }

    /// Attach a failure produced by an external production consumer to this
    /// runtime's frozen retry ledger without starting another Provider turn.
    @discardableResult
    public func recordRetryFailure(
        request: ChatTurnRequest,
        failureMessage: String,
        toolCalls: [LLMToolCall] = [],
        partialMessages: [LLMMessage] = [],
        toolExecutionFacts: [ToolExecutionFact] = []
    ) throws -> ChatRetryEnvelope {
        let identity = try retryTurnIdentity(for: request)
        guard activeRetryTurn == identity,
              !retiredRetryTurns.contains(identity) else {
            throw ChatSessionRuntimeError.retryTurnNotActive
        }
        let envelope = try makeRetryEnvelope(
            request: request,
            failureMessage: failureMessage,
            toolCalls: toolCalls,
            partialMessages: partialMessages,
            toolExecutionFacts: toolExecutionFacts
        )
        latestRetryEnvelopeStorage = envelope
        activeRetryTurn = nil
        retiredRetryTurns.insert(identity)
        cancelledRetryTurns.remove(identity)
        return envelope
    }

    private func retryTurnIdentity(
        for request: ChatTurnRequest
    ) throws -> RetryTurnIdentity {
        let turnID: String
        if let rawTurnID = request.turnID {
            let trimmed = rawTurnID.trimmingCharacters(in: .whitespacesAndNewlines)
            turnID = trimmed.isEmpty ? request.context.conversationID : trimmed
        } else {
            turnID = request.context.conversationID
        }
        let taskID: String
        if let rawTaskID = request.taskID {
            let trimmed = rawTaskID.trimmingCharacters(in: .whitespacesAndNewlines)
            taskID = trimmed.isEmpty
                ? "task:\(request.context.sessionID):\(turnID)"
                : trimmed
        } else {
            taskID = "task:\(request.context.sessionID):\(turnID)"
        }
        guard !request.context.sessionID.isEmpty,
              !request.context.conversationID.isEmpty,
              !turnID.isEmpty,
              !taskID.isEmpty,
              request.attempt > 0 else {
            throw ChatSessionRuntimeError.retryTurnNotActive
        }
        return RetryTurnIdentity(
            sessionID: request.context.sessionID,
            conversationID: request.context.conversationID,
            turnID: turnID,
            taskID: taskID,
            attempt: request.attempt
        )
    }

    /// Run a user turn through the same Core session store and AgentContext
    /// path used by chat.  Plan is explicitly local and has zero persistence
    /// and zero Provider calls.
    public func send(_ request: ChatTurnRequest) async throws -> ChatTurnResult {
        try await send(
            request,
            providerRuntimeRoute: nil,
            requireProviderRuntimeRoute: false
        )
    }

    /// Production chat send. A route must have been frozen by the
    /// snapshot-backed initializer; otherwise no provider call is permitted.
    public func sendProduction(_ request: ChatTurnRequest) async throws -> ChatTurnResult {
        guard startupReady else {
            throw ChatSessionRuntimeError.startupNotReady
        }
        guard let providerRuntimeRoute else {
            throw ChatSessionRuntimeError.providerRuntimeSnapshotMissing
        }
        return try await send(
            request,
            providerRuntimeRoute: providerRuntimeRoute,
            requireProviderRuntimeRoute: true
        )
    }

    private func send(
        _ request: ChatTurnRequest,
        providerRuntimeRoute: ProviderRuntimeRoute?,
        requireProviderRuntimeRoute: Bool
    ) async throws -> ChatTurnResult {
        guard startupReady else {
            throw ChatSessionRuntimeError.startupNotReady
        }
        if requireProviderRuntimeRoute, providerRuntimeRoute == nil {
            throw ChatSessionRuntimeError.providerRuntimeSnapshotMissing
        }
        let prepared = try prepare(request)
        if prepared.operationMode == .bypass {
            throw ChatSessionRuntimeError.bypassNotAllowed
        }
        if let capsule = request.capsule {
            guard capsule.sessionID == request.context.sessionID else {
                throw ChatSessionRuntimeError.capsuleSessionMismatch
            }
            guard capsule.sendSnapshot == request.text else {
                throw ChatSessionRuntimeError.capsuleTextMismatch
            }
            guard !sentCapsuleIDs.contains(capsule.capsuleID),
                  !inFlightCapsuleIDs.contains(capsule.capsuleID) else {
                throw ChatSessionRuntimeError.duplicateCapsuleSend
            }
        }

        if prepared.operationMode == .plan {
            return ChatTurnResult(
                messages: prepared.session.messages,
                context: request.context,
                isDryRun: true,
                matchedSkillIDs: prepared.matchedSkillIDs
            )
        }

        guard let toolCatalog, !toolCatalog.isEmpty else {
            throw ChatSessionRuntimeError.toolCatalogMissing
        }
        guard let toolExecutionFactLedger else {
            throw ChatSessionRuntimeError.toolExecutionFactLedgerMissing
        }
        guard let executionIdentity = request.executionIdentity,
              executionIdentity.isValid,
              executionIdentity.attempt == request.attempt,
              executionIdentity.turn.sessionID == request.context.sessionID else {
            throw ChatSessionRuntimeError.executionIdentityMissing
        }
        // Reserve on this actor before the provider await permits reentrancy.
        // Failed/cancelled turns retain the existing retry semantics.
        let capsuleID = request.capsule?.capsuleID
        if let capsuleID { inFlightCapsuleIDs.insert(capsuleID) }
        defer {
            if let capsuleID { inFlightCapsuleIDs.remove(capsuleID) }
        }
        let persistedMessageCount = prepared.session.messages.count
        try sessionStore.saveMessage(
            LLMMessage(role: .user, content: request.text),
            sessionID: request.context.sessionID
        )
        var context = AgentContext(
            messages: prepared.session.messages,
            toolExecutor: toolExecutor,
            provider: provider,
            providerRuntimeRoute: providerRuntimeRoute,
            systemPrompt: prepared.systemPrompt,
            tools: toolCatalog,
            currentConversationID: request.context.conversationID,
            toolExecutionFactLedger: toolExecutionFactLedger,
            executionIdentity: executionIdentity,
            composerSnapshot: request.composerSnapshot
        )
        let messages: [LLMMessage]
        do {
            messages = try await context.run(userMessage: request.text)
        } catch is CancellationError {
            throw CancellationError()
        } catch is InterruptedError {
            throw InterruptedError()
        } catch {
            let partialMessages = context.lastPartialMessages
            let toolCalls = partialMessages.flatMap(\.toolCalls)
            let toolExecutionFacts = facts(
                for: executionIdentity,
                ledger: toolExecutionFactLedger,
                composerSnapshot: request.composerSnapshot
            )
            let envelope = try makeRetryEnvelope(
                request: request,
                failureMessage: ChatGenerationFailureProjection(error: error).failureMessage,
                toolCalls: toolCalls,
                partialMessages: partialMessages,
                toolExecutionFacts: toolExecutionFacts
            )
            latestRetryEnvelopeStorage = envelope
            if let routeError = error as? FallbackRouterError {
                throw routeError
            }
            throw ChatSessionRuntimeError.turnFailed(envelope)
        }
        // The user message is persisted before the provider call so an
        // interrupted request still leaves an honest transcript. Persist the
        // remaining messages produced by this turn in canonical order: native
        // assistant toolCalls and matching tool-role toolCallID records must
        // survive restart, not just the final assistant text.
        let turnMessages = messages.dropFirst(persistedMessageCount + 1)
        for message in turnMessages {
            try sessionStore.saveMessage(message, sessionID: request.context.sessionID)
        }
        if let capsule = request.capsule {
            sentCapsuleIDs.insert(capsule.capsuleID)
        }
        return ChatTurnResult(
            messages: messages,
            context: request.context,
            isDryRun: false,
            matchedSkillIDs: prepared.matchedSkillIDs,
            reasoningSummary: request.context.reasoningSummaryMode == .none ? nil : "turn completed",
            executionIdentity: executionIdentity,
            toolExecutionFacts: facts(
                for: executionIdentity,
                ledger: toolExecutionFactLedger,
                composerSnapshot: request.composerSnapshot
            )
        )
    }

    public func proposeMemory(
        text: String,
        context: ChatRuntimeContext,
        proposalID: String = UUID().uuidString,
        expiresAt: Date
    ) throws -> ChatMemoryProposal {
        _ = try prepare(
            ChatTurnRequest(text: text, context: context, operationMode: .plan)
        )
        let envelope = try memoryProposalConsumer.submit(
            proposalID: proposalID,
            text: text,
            within: context.memoryScope,
            sourceID: "chat-session-runtime"
        )
        return ChatMemoryProposal(
            proposalID: envelope.proposal.proposalID,
            text: envelope.text,
            context: context,
            envelope: envelope,
            expiresAt: expiresAt
        )
    }

    @discardableResult
    public func approveMemory(
        _ proposal: ChatMemoryProposal,
        reason: String,
        now: Date = Date()
    ) throws -> MemoryProposalLifecycleReceipt {
        try validateContext(proposal.context)
        guard proposal.expiresAt > now else {
            throw ChatSessionRuntimeError.proposalExpired
        }
        guard memoryRollbacks[proposal.proposalID] == nil else {
            return proposal.envelope.approvalReceipt ?? proposal.envelope.proposal
        }
        let receipt = try memoryProposalConsumer.approve(
            proposalID: proposal.proposalID,
            within: proposal.context.memoryScope,
            reason: reason
        )
        memoryRollbacks[proposal.proposalID] = ApprovedMemoryRollback(
            factID: proposal.proposalID,
            scope: proposal.context.memoryScope
        )
        return receipt
    }

    public func rollbackMemory(proposalID: String, reason: String) throws {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rollback = memoryRollbacks[proposalID] else {
            throw ChatSessionRuntimeError.proposalNotFound
        }
        guard try memoryStore.facts().contains(where: {
            $0.id == rollback.factID && $0.memoryScope == rollback.scope
        }) else {
            throw ChatSessionRuntimeError.proposalNotFound
        }
        _ = try memoryStore.removeFactForRollback(id: rollback.factID)
        memoryRollbacks.removeValue(forKey: proposalID)
    }

    @discardableResult
    public func rollbackSkill(
        skillID: String,
        context: ChatRuntimeContext,
        reason: String
    ) throws -> SkillLifecycleReceipt {
        try validateContext(context)
        guard let receipt = skillStore.lifecycleReceipt(for: skillID),
              receipt.scope == context.memoryScope else {
            throw ChatSessionRuntimeError.skillScopeMismatch
        }
        return try skillStore.rollbackSkill(skillID, reason: reason)
    }

    private struct PreparedTurn {
        let session: ChatSession
        let systemPrompt: String
        let matchedSkillIDs: [String]
        let operationMode: ChatOperationMode
    }

    private func facts(
        for identity: AgentExecutionIdentity,
        ledger: ToolExecutionFactLedger,
        composerSnapshot: ComposerSubmissionSnapshot? = nil
    ) -> [ToolExecutionFact] {
        guard let attemptID = AgentToolExecutionAttemptID.canonical(
            executionIdentity: identity,
            composerSnapshot: composerSnapshot,
            childBoundary: nil
        ) else {
            return []
        }
        return ledger.facts(
            executionIdentity: identity,
            attemptID: attemptID,
            attemptNumber: identity.attempt
        )
    }

    private func prepare(_ request: ChatTurnRequest) throws -> PreparedTurn {
        let session = try validateContext(request.context, sessionID: request.sessionID)
        guard let soul = selectedSoul(), soul.id == request.context.personaID else {
            throw ChatSessionRuntimeError.personaMismatch
        }
        let scope = request.context.memoryScope
        // Freeze one turn-boundary projection so matching and prompt assembly
        // consume the same manifest-verified registry and payload snapshot.
        let skillInjector = skillsEnabled ? SkillInjector(store: skillStore).snapshotForTurn() : nil
        let matchedIDs = skillInjector?.matchingSkills(for: request.text, within: scope).map(\.id) ?? []
        guard Set(matchedIDs).isSubset(of: Set(request.context.skillIDs)) else {
            throw ChatSessionRuntimeError.contextMismatch
        }
        var prompt = soul.systemPrompt
        prompt = try MemoryInjector(store: memoryStore).systemPrompt(
            base: prompt,
            userMessage: request.text,
            memoryScope: scope
        )
        if let skills = skillInjector?.buildInjectionFragment(
            for: request.text,
            within: scope
        ) {
            prompt += "\n\n" + skills
        }
        return PreparedTurn(
            session: session,
            systemPrompt: prompt,
            matchedSkillIDs: matchedIDs,
            operationMode: request.operationMode ?? request.context.operationMode
        )
    }

    @discardableResult
    private func validateContext(
        _ context: ChatRuntimeContext,
        sessionID: String? = nil
    ) throws -> ChatSession {
        guard context.memoryScope.isValid,
              context.sessionID == context.memoryScope.sessionID,
              context.sessionID == (sessionID ?? context.sessionID),
              context.snapshot.sessionID == context.sessionID,
              context.snapshot.providerID == context.providerID,
              context.snapshot.modelID == context.modelID,
              context.snapshot.snapshotID == context.snapshot.canonicalSnapshotID(),
              context.providerID == provider.name,
              context.modelID == provider.model.id,
              let session = sessionStore.loadSession(id: context.sessionID),
              session.projectID == context.memoryScope.projectID else {
            throw ChatSessionRuntimeError.contextMismatch
        }
        guard let soul = selectedSoul(), soul.id == context.personaID else {
            throw ChatSessionRuntimeError.personaMismatch
        }
        guard skillsEnabled || context.skillIDs.isEmpty else {
            throw ChatSessionRuntimeError.skillScopeMismatch
        }
        for skillID in context.skillIDs {
            guard let skill = skillStore.allSkills().first(where: { $0.id == skillID }),
                  skillStore.isInjectable(skill, within: context.memoryScope) else {
                throw ChatSessionRuntimeError.skillScopeMismatch
            }
        }
        return session
    }

    private func selectedSoul() -> Soul? {
        return switch soulTurnSelection {
        case .live:
            soulStore.activeSoul()
        case .frozen(let soul):
            soul
        }
    }
}
