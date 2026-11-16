import CryptoKit
import Foundation

// MARK: - Approval Policy

/// Per-tool approval policy (E1 工具审批流).
///
/// Mirrors the Codex desktop permission flow: a tool call is either approved
/// automatically (`autoApprove`), sent to a human/UI delegate for a decision
/// (`alwaysAsk` / `riskOnlyAsk`), or blocked outright (`deny`).
public enum ApprovalPolicy: String, Codable, Sendable, Equatable {
    /// Execute without asking (low-risk tools like reads).
    case autoApprove
    /// Ask the `ApprovalDelegate` before every call.
    case alwaysAsk
    /// Ask only for high-risk calls; low-risk calls proceed automatically.
    case riskOnlyAsk
    /// Never allow this tool — the gate denies it without consulting anyone.
    case deny
    /// Legacy source compatibility. This remains a true deny policy.
    case never
}

// MARK: - Risk Level

/// Subjective risk classification attached to an approval request so the UI
/// can style the prompt (green/yellow/red) without re-deriving policy.
public enum ApprovalRiskLevel: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high

    fileprivate var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func max(_ lhs: Self, _ rhs: Self) -> Self {
        lhs.rank >= rhs.rank ? lhs : rhs
    }
}

/// Immutable identity that must survive the prompt and reach the effect
/// boundary. Bound approvals cannot be replayed for another effect.
public struct ApprovalAuthorizationContext: Sendable, Equatable {
    public let actorID: String
    public let sessionID: String
    public let turnID: Int
    public let taskID: String
    /// Capability name is part of the immutable approval identity. It is
    /// optional at construction time for legacy callers and is filled by the
    /// bound gate before a request is presented.
    public let toolName: String
    public let runID: String
    public let attemptID: String
    public let effectID: String
    public let scope: String
    public let payloadDigest: String
    public let expiresAt: Date
    public let policyRevision: String
    public let grantEpoch: String

    public init(actorID: String, sessionID: String, turnID: Int, taskID: String, runID: String, attemptID: String, effectID: String, scope: String, payloadDigest: String, expiresAt: Date, policyRevision: String, grantEpoch: String, toolName: String = "") {
        self.actorID = actorID; self.sessionID = sessionID; self.turnID = turnID
        self.taskID = taskID; self.toolName = toolName; self.runID = runID; self.attemptID = attemptID
        self.effectID = effectID; self.scope = scope; self.payloadDigest = payloadDigest
        self.expiresAt = expiresAt; self.policyRevision = policyRevision; self.grantEpoch = grantEpoch
    }

    public var canonical: String {
        [actorID, sessionID, String(turnID), taskID, toolName, runID, attemptID, effectID, scope,
         payloadDigest, String(expiresAt.timeIntervalSinceReferenceDate), policyRevision,
         grantEpoch].joined(separator: "\u{0}")
    }

    /// Compatibility alias for the lease generation carried as `grantEpoch`.
    public var leaseGeneration: String { grantEpoch }

    /// Returns the same authorization facts bound to one concrete tool.
    /// Legacy contexts are intentionally upgraded before the request digest
    /// is emitted, so the tool cannot be swapped after prompting.
    public func binding(to tool: String) -> Self {
        guard toolName.isEmpty else { return self }
        return Self(
            actorID: actorID, sessionID: sessionID, turnID: turnID,
            taskID: taskID, runID: runID, attemptID: attemptID,
            effectID: effectID, scope: scope, payloadDigest: payloadDigest,
            expiresAt: expiresAt, policyRevision: policyRevision,
            grantEpoch: grantEpoch, toolName: tool
        )
    }

    public var identityDigest: String {
        SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func payloadDigest(for input: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var isValid: Bool {
        [actorID, sessionID, taskID, runID, attemptID, effectID, scope, payloadDigest, policyRevision, grantEpoch].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } && expiresAt.timeIntervalSinceReferenceDate.isFinite
    }
}

public enum ApprovalDecisionStatus: String, Codable, Sendable, Equatable {
    case approved
    case denied
    case expired
    case revoked
    case cancelled
}

/// Display provenance from the verified runtime, never from tool input.
public enum ToolApprovalSource: Sendable, Equatable {
    case childTask(taskID: String, parentID: String)
}

// MARK: - Request / Decision

/// A tool call pending approval.
///
/// `inputSummary` is a redacted, truncated one-line digest of the tool input
/// (file payloads and secrets are masked) — safe to render in a UI prompt.
public struct ApprovalRequest: Sendable, Equatable {
    /// Stable id for the pending call (the agent loop's `tool_use_id`).
    public let id: String
    /// Stable approval request and model call identities. Legacy callers
    /// default both to `id`; Composer supplies the real AgentLoop call id.
    public let requestID: String
    public let callID: String
    /// Tool name, e.g. `file_write`, `shell_execute`.
    public let toolName: String
    /// Redacted summary of the tool input.
    public let inputSummary: String
    /// Risk level derived from the tool name.
    public let riskLevel: ApprovalRiskLevel
    /// Risk level derived from the concrete input (path, URL, command, etc.).
    public let inputRiskLevel: ApprovalRiskLevel
    /// Whether this call actually needs approval under the active policy.
    public let requiresApproval: Bool
    /// L3/destructive inputs require a second, explicit confirmation in the UI.
    public let requiresSecondConfirmation: Bool
    /// Immutable Composer turn identity. Nil preserves non-composer callers.
    public let sessionID: String?
    public let turnID: Int?
    public let taskID: String?
    public let attemptID: String?
    public let approvalScope: String?
    public let composerMode: String?
    public let messageID: String?
    public let policyRevision: String?
    public let grantEpoch: String?
    public let inputDigest: String?
    public let identityDigest: String?
    public let actorID: String?
    public let runID: String?
    public let effectID: String?
    public let expiresAt: Date?
    public var sourceTaskTitle: String? = nil
    public var source: ToolApprovalSource? = nil
    /// Display-only offer for "allow from now on". It is not part of the
    /// request identity and grants nothing by itself.
    public var persistentAllowOffer: ApprovalPersistentAllowOffer? = nil
    /// Parsed call intent only. Site/risk facts must come from BrowserSession.
    var browserNavigationDestination: URL? = nil
    public var browserInteractionInput: BrowserInteractionInput? = nil
    public var browserRiskWarning: String? = nil
    /// Display-only classification from the request’s frozen terminal policy.
    /// Not an authorization input; nil preserves legacy and non-shell prompts.
    public var terminalPolicyDisposition: TerminalCommandDisposition? = nil
    /// Display-only normalized authority from the trusted web-fetch producer.
    /// Never parsed as approval, grant, or identity material.
    public var webFetchAuthority: String? = nil
    /// Redacted path for presentation only; excluded from approval binding.
    public var displayTargetPath: String? = nil
    public var isHookAsk: Bool = false
    public var sessionScopeEligible = false
    public var hookAskReason: String? = nil
    public let filePreview: ApprovalFilePreview?
    public var skillDiff: FileChangeDiffPayload? = nil
    public var skillDeletionIntent: OperationIntent? = nil

    public init(
        id: String,
        requestID: String? = nil,
        callID: String? = nil,
        toolName: String,
        inputSummary: String,
        riskLevel: ApprovalRiskLevel,
        requiresApproval: Bool,
        inputRiskLevel: ApprovalRiskLevel = .low,
        requiresSecondConfirmation: Bool = false,
        sessionID: String? = nil,
        turnID: Int? = nil,
        taskID: String? = nil,
        attemptID: String? = nil,
        approvalScope: String? = nil,
        composerMode: String? = nil,
        messageID: String? = nil,
        policyRevision: String? = nil,
        grantEpoch: String? = nil,
        inputDigest: String? = nil,
        identityDigest: String? = nil,
        actorID: String? = nil,
        runID: String? = nil,
        effectID: String? = nil,
        expiresAt: Date? = nil,
        filePreview: ApprovalFilePreview? = nil,
        webFetchAuthority: String? = nil,
        displayTargetPath: String? = nil
    ) {
        self.id = id
        self.requestID = requestID ?? id
        self.callID = callID ?? id
        self.toolName = toolName
        self.inputSummary = inputSummary
        self.riskLevel = riskLevel
        self.inputRiskLevel = inputRiskLevel
        self.requiresApproval = requiresApproval
        self.requiresSecondConfirmation = requiresSecondConfirmation
        self.sessionID = sessionID
        self.turnID = turnID
        self.taskID = taskID
        self.attemptID = attemptID
        self.approvalScope = approvalScope
        self.composerMode = composerMode
        self.messageID = messageID
        self.policyRevision = policyRevision
        self.grantEpoch = grantEpoch
        self.inputDigest = inputDigest
        self.identityDigest = identityDigest
        self.actorID = actorID
        self.runID = runID
        self.effectID = effectID
        self.expiresAt = expiresAt
        self.filePreview = filePreview
        self.webFetchAuthority = webFetchAuthority
        self.displayTargetPath = displayTargetPath
    }

    /// A refreshed presentation retains the same model action and effect,
    /// while the ordinary request ID rejects a late answer to the old card.
    func refreshingFilePreview(_ preview: ApprovalFilePreview, inputSummary: String? = nil) -> Self {
        let newID = UUID().uuidString
        var result = Self(id: newID, requestID: newID, callID: callID, toolName: toolName,
            inputSummary: inputSummary ?? self.inputSummary, riskLevel: riskLevel, requiresApproval: requiresApproval,
            inputRiskLevel: inputRiskLevel, requiresSecondConfirmation: requiresSecondConfirmation,
            sessionID: sessionID, turnID: turnID, taskID: taskID, attemptID: attemptID,
            approvalScope: approvalScope, composerMode: composerMode, messageID: messageID,
            policyRevision: policyRevision, grantEpoch: grantEpoch, inputDigest: inputDigest,
            identityDigest: identityDigest, actorID: actorID, runID: runID, effectID: effectID,
            expiresAt: expiresAt, filePreview: preview, webFetchAuthority: webFetchAuthority,
            displayTargetPath: displayTargetPath)
        result.skillDiff = skillDiff
        result.skillDeletionIntent = skillDeletionIntent
        result.source = source
        result.sourceTaskTitle = sourceTaskTitle
        result.persistentAllowOffer = persistentAllowOffer
        result.browserNavigationDestination = browserNavigationDestination
        result.browserInteractionInput = browserInteractionInput
        result.browserRiskWarning = browserRiskWarning
        result.terminalPolicyDisposition = terminalPolicyDisposition
        result.isHookAsk = isHookAsk
        result.sessionScopeEligible = sessionScopeEligible
        result.hookAskReason = hookAskReason
        return result
    }

    /// A durable effect may use this request only when every identity field
    /// is present; legacy requests intentionally return nil.
    public var binding: ApprovalAuthorizationContext? {
        guard let actorID, let sessionID, let turnID, let taskID,
              let runID, let attemptID, let effectID, let scope = approvalScope,
              let payloadDigest = inputDigest, let expiresAt,
              let policyRevision, let grantEpoch else { return nil }
        let context = ApprovalAuthorizationContext(
            actorID: actorID, sessionID: sessionID, turnID: turnID,
            taskID: taskID, runID: runID, attemptID: attemptID,
            effectID: effectID, scope: scope, payloadDigest: payloadDigest,
            expiresAt: expiresAt, policyRevision: policyRevision,
            grantEpoch: grantEpoch, toolName: toolName
        )
        guard identityDigest == context.identityDigest else { return nil }
        return context
    }
}

/// The delegate's verdict on an `ApprovalRequest`.
public struct ApprovalDecision: Sendable, Equatable {
    /// `true` → the tool call may proceed.
    public let approved: Bool
    /// Optional human-readable justification (shown to the model on denial).
    public let reason: String?
    /// True only after the UI completed the required explicit confirmation.
    /// It defaults to false so a newly constructed approval cannot accidentally
    /// satisfy an L3 gate.
    public let confirmed: Bool
    public let status: ApprovalDecisionStatus
    public let requestID: String?
    public let bindingDigest: String?
    public let filePreview: ApprovalFilePreview?
    /// True only when the user explicitly chose "allow from now on" for this
    /// approval. It never changes how this call itself is authorized.
    public let persistAllow: Bool
    public let allowInSession: Bool
    /// Set by the bound native risk confirmation, never model input.
    public let skillRiskConfirmed: Bool

    /// Set only by the browser risk confirmation UI control, independently of generic approval.
    public let browserRiskConfirmed: Bool

    public init(approved: Bool, reason: String? = nil, confirmed: Bool = false, status: ApprovalDecisionStatus? = nil, requestID: String? = nil, bindingDigest: String? = nil, filePreview: ApprovalFilePreview? = nil, persistAllow: Bool = false, skillRiskConfirmed: Bool = false, browserRiskConfirmed: Bool = false, allowInSession: Bool = false) {
        self.persistAllow = persistAllow
        self.allowInSession = allowInSession
        self.skillRiskConfirmed = skillRiskConfirmed
        self.browserRiskConfirmed = browserRiskConfirmed
        self.approved = approved
        self.reason = reason
        self.confirmed = confirmed
        self.status = status ?? (approved ? .approved : .denied)
        self.requestID = requestID
        self.bindingDigest = bindingDigest
        self.filePreview = filePreview
    }

    /// The gate attaches the exact preview the user saw; a delegate cannot
    /// replace it with a fresh snapshot after accepting an old prompt.
    func carrying(_ preview: ApprovalFilePreview?) -> Self {
        Self(approved: approved, reason: reason, confirmed: confirmed, status: status,
             requestID: requestID, bindingDigest: bindingDigest, filePreview: preview,
             persistAllow: persistAllow, skillRiskConfirmed: skillRiskConfirmed,
             browserRiskConfirmed: browserRiskConfirmed, allowInSession: allowInSession)
    }

    public static let approve = ApprovalDecision(approved: true, reason: "Approved", confirmed: true)
    public static let deny = ApprovalDecision(approved: false, reason: "Denied by user")
}

/// Immutable, redacted fact emitted after an approval gate allows a call.
public struct ApprovalReceipt: Codable, Sendable, Equatable {
    public let requestID: String
    public let toolName: String
    public let policy: ApprovalPolicy
    public let riskLevel: ApprovalRiskLevel
    public let inputSummary: String
    public let approvedAt: Date
    public let status: ApprovalDecisionStatus
    public let actorID: String?
    public let sessionID: String?
    public let turnID: Int?
    public let taskID: String?
    public let runID: String?
    public let attemptID: String?
    public let effectID: String?
    public let approvalScope: String?
    public let inputDigest: String?
    public let identityDigest: String?
    public let expiresAt: Date?
    public let policyRevision: String?
    public let grantEpoch: String?

    public init(
        requestID: String,
        toolName: String,
        policy: ApprovalPolicy,
        riskLevel: ApprovalRiskLevel,
        inputSummary: String,
        approvedAt: Date = Date(),
        status: ApprovalDecisionStatus = .approved,
        actorID: String? = nil, sessionID: String? = nil, turnID: Int? = nil,
        taskID: String? = nil, runID: String? = nil, attemptID: String? = nil,
        effectID: String? = nil, approvalScope: String? = nil,
        inputDigest: String? = nil, identityDigest: String? = nil,
        expiresAt: Date? = nil, policyRevision: String? = nil, grantEpoch: String? = nil
    ) {
        self.requestID = requestID
        self.toolName = Self.boundedReceiptLabel(toolName, fallback: "tool")
        self.policy = policy
        self.riskLevel = riskLevel
        self.inputSummary = Self.boundedReceiptInputSummary(inputSummary)
        self.approvedAt = approvedAt
        self.status = status
        self.actorID = actorID; self.sessionID = sessionID; self.turnID = turnID
        self.taskID = taskID; self.runID = runID; self.attemptID = attemptID
        self.effectID = effectID
        self.approvalScope = approvalScope.map {
            Self.boundedReceiptLabel($0, fallback: "scope")
        }
        self.inputDigest = inputDigest; self.identityDigest = identityDigest
        self.expiresAt = expiresAt; self.policyRevision = policyRevision; self.grantEpoch = grantEpoch
    }

    /// Receipt fields cross the approval UI and durable Codable boundary.
    /// Keep canonical tool/scope values in ApprovalRequest and
    /// ApprovalAuthorizationContext, while projecting untrusted labels here.
    private static func boundedReceiptLabel(_ raw: String, fallback: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else {
            return fallback
        }
        guard value.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                 0x20, 0x2D, 0x2E, 0x3A, 0x5F:
                return true
            default:
                return false
            }
        }) else {
            return fallback
        }

        let lowercased = value.lowercased()
        let sensitiveMarkers = [
            "authorization", "proxy-authorization", "bearer", "api_key",
            "apikey", "token", "secret", "password", "credential", "cookie"
        ]
        guard !sensitiveMarkers.contains(where: lowercased.contains),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("?"),
              !value.contains("#") else {
            return fallback
        }
        return value
    }

    /// Input summaries may be supplied by legacy/direct receipt callers rather
    /// than by ApprovalGate.makeInputSummary. Re-apply the shared event
    /// boundary here so URL/path payloads cannot enter durable approval facts.
    private static func boundedReceiptInputSummary(_ raw: String) -> String {
        let projected = ConversationEventRedactor.redact(raw)
        let sanitized = projected.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F:
                return " "
            default:
                return String(scalar)
            }
        }.joined()
        let compact = sanitized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return "事件更新" }
        return compact.count > 160 ? String(compact.prefix(157)) + "..." : compact
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, toolName, policy, riskLevel, inputSummary, approvedAt, status,
             actorID, sessionID, turnID, taskID, runID, attemptID, effectID,
             approvalScope, inputDigest, identityDigest, expiresAt, policyRevision, grantEpoch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            requestID: try c.decode(String.self, forKey: .requestID),
            toolName: try c.decode(String.self, forKey: .toolName),
            policy: try c.decode(ApprovalPolicy.self, forKey: .policy),
            riskLevel: try c.decode(ApprovalRiskLevel.self, forKey: .riskLevel),
            inputSummary: try c.decode(String.self, forKey: .inputSummary),
            approvedAt: try c.decode(Date.self, forKey: .approvedAt),
            status: try c.decodeIfPresent(ApprovalDecisionStatus.self, forKey: .status) ?? .approved,
            actorID: try c.decodeIfPresent(String.self, forKey: .actorID),
            sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID),
            turnID: try c.decodeIfPresent(Int.self, forKey: .turnID),
            taskID: try c.decodeIfPresent(String.self, forKey: .taskID),
            runID: try c.decodeIfPresent(String.self, forKey: .runID),
            attemptID: try c.decodeIfPresent(String.self, forKey: .attemptID),
            effectID: try c.decodeIfPresent(String.self, forKey: .effectID),
            approvalScope: try c.decodeIfPresent(String.self, forKey: .approvalScope),
            inputDigest: try c.decodeIfPresent(String.self, forKey: .inputDigest),
            identityDigest: try c.decodeIfPresent(String.self, forKey: .identityDigest),
            expiresAt: try c.decodeIfPresent(Date.self, forKey: .expiresAt),
            policyRevision: try c.decodeIfPresent(String.self, forKey: .policyRevision),
            grantEpoch: try c.decodeIfPresent(String.self, forKey: .grantEpoch)
        )
    }
}

// MARK: - Errors

/// Thrown by `ApprovalGate.gate` when a call is refused.
public enum ApprovalError: Error, Equatable, Sendable {
    /// The call was refused — either by the delegate or by a `.never` policy.
    case denied(reason: String?)
    case expired(requestID: String)
    case revoked(requestID: String)
    case cancelled(requestID: String)
    case bindingMismatch(requestID: String)
    case missingIdentity(requestID: String)
    case alreadyConsumed(requestID: String)
}

extension ApprovalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .denied(let reason):
            return Self.boundedDenialReason(reason).map { "审批被拒绝: \($0)" } ?? "审批被拒绝"
        case .expired(let requestID): return "审批已过期（请求 \(requestID)），请重新发起"
        case .revoked(let requestID): return "审批已撤销（请求 \(requestID)），请重新授权"
        case .cancelled(let requestID): return "审批已取消（请求 \(requestID)），可重新尝试"
        case .bindingMismatch(let requestID): return "审批绑定不匹配（请求 \(requestID)），请检查任务后重试"
        case .missingIdentity(let requestID): return "审批缺少完整身份（请求 \(requestID)），请重新发起"
        case .alreadyConsumed(let requestID): return "审批已被消费（请求 \(requestID)），请重新发起"
        }
    }

    /// Decision reasons are user/model supplied text and may be copied into
    /// AgentLoop failure messages. Keep the denial case's raw Equatable value
    /// for audit semantics, but bound only this localized display surface.
    private static func boundedDenialReason(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let projected = ConversationEventRedactor.redact(raw)
        let sanitized = projected.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F:
                return " "
            default:
                return String(scalar)
            }
        }.joined()
        let compact = sanitized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty, compact != "事件更新" else { return nil }
        return compact.count > 160 ? String(compact.prefix(157)) + "..." : compact
    }
}


/// Future independent deletion review may only be requested after the existing
/// checkpoint owner proves recovery. This describes eligibility, never grants
/// approval, calls a model, or changes the parent's permission decision.
public struct ChildDeletionReviewPrerequisites: Sendable, Equatable {
    public var enabled = false
    public var hasRecoverableCheckpoint = false
    public var isWhitelisted = false
    public var changesPermissions = true

    public init() {}
    public var canRequestIndependentReview: Bool {
        enabled && hasRecoverableCheckpoint && isWhitelisted && !changesPermissions
    }
}
