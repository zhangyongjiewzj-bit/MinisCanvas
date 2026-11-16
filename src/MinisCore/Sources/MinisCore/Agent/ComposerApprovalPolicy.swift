import Foundation
import CryptoKit

fileprivate enum ComposerDigest {
    static func sha256<C: Encodable>(_ value: C) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "invalid" }
        return sha256(data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Created only by the live Composer controller after validating its frozen
/// confirmed policy. Host code cannot construct or install this task-local
/// origin from two public call strings.
final class BrowserBypassPolicyOrigin: @unchecked Sendable {
    let callID: String
    let inputDigest: String
    private let sessionID: String
    private let workspaceID: String
    private let lock = NSLock()
    private var boundScopeID: String?
    private var boundGeneration: UInt64?
    private var boundSession: ObjectIdentifier?

    fileprivate init(callID: String, inputDigest: String, sessionID: String, workspaceID: String) {
        self.callID = callID
        self.inputDigest = inputDigest
        self.sessionID = sessionID
        self.workspaceID = workspaceID
    }

    func claim(
        identity: BrowserSideEffectExecutionIdentity?,
        scope: BrowserSessionScope,
        generation: UInt64,
        session: BrowserSession
    ) -> Bool {
        guard let identity, identity.isValid,
              identity.callID == callID, identity.inputDigest == inputDigest,
              let key = scope.isolationKey,
              key.surface == .agentBrowser, key.profile == "production",
              key.session == sessionID, key.workspace == workspaceID,
              generation > 0 else { return false }
        let resource = ObjectIdentifier(session)
        lock.lock(); defer { lock.unlock() }
        if let boundScopeID {
            return boundScopeID == scope.id && boundGeneration == generation
                && boundSession == resource
        }
        boundScopeID = scope.id
        boundGeneration = generation
        boundSession = resource
        return true
    }
}

enum BrowserBypassPermissionCallContext {
    @TaskLocal static var current: BrowserBypassPolicyOrigin?
}

public enum ComposerTaskMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case manual
    case autoEdit = "auto-edit"
    case plan
    case auto
    case bypassPermission = "bypass-permission"

    /// Minimum user ceiling required for this request mode. Tool-specific
    /// capability, approval, lease and PolicyRuntime checks still apply.
    public var requiredAutonomyLevel: AutonomyLevel {
        switch self {
        case .plan: return .l0
        case .manual: return .l1
        case .autoEdit: return .l2
        case .auto, .bypassPermission: return .l3
        }
    }
}

public enum ComposerApprovalScope: String, Codable, CaseIterable, Equatable, Sendable {
    case request
    case turn
    case session
    case workspace
}

public enum ComposerEffort: String, Codable, CaseIterable, Equatable, Sendable {
    case low
    case standard
    case high
}

/// Persisted default policy for new Composer submissions.
///
/// A setting is only a default: each submission copies these values into its
/// immutable snapshot, so changing the setting cannot mutate an in-flight turn.
public struct ComposerPolicySettings: Codable, Equatable, Sendable {
    public var mode: ComposerTaskMode
    public var approvalScope: ComposerApprovalScope
    public var effort: ComposerEffort
    /// One-time acknowledgement for bypass mode. Per-call approval remains
    /// mandatory for model-initiated permission/settings mutations.
    public var bypassModeConfirmed: Bool
    /// 「禁用绕过」开关（共用电脑场景）。默认关；打开后绕过模式不可选，
    /// 已选的回落到手动。旧数据缺省解码为 false。
    public var disableBypass: Bool
    /// 凭据类路径保护（~/.ssh、.env 等；钥匙串目录是绕过下的硬底线，不受此开关控制）。只在已确认的绕过模式下生效
    /// （用户 2026-10-22 决定；其他模式走原有审批路径）。默认开（安全默认）；
    /// 旧数据缺省解码为 true。
    public var protectCredentialPaths: Bool

    public static let `default` = ComposerPolicySettings(
        mode: .manual,
        approvalScope: .request,
        effort: .standard,
        bypassModeConfirmed: false
    )

    public init(
        mode: ComposerTaskMode = .manual,
        approvalScope: ComposerApprovalScope = .request,
        effort: ComposerEffort = .standard,
        bypassModeConfirmed: Bool = false,
        disableBypass: Bool = false,
        protectCredentialPaths: Bool = true
    ) {
        self.mode = mode
        self.approvalScope = approvalScope
        self.effort = effort
        self.bypassModeConfirmed = bypassModeConfirmed
        self.disableBypass = disableBypass
        self.protectCredentialPaths = protectCredentialPaths
    }

    private enum CodingKeys: String, CodingKey {
        case mode, approvalScope, effort, bypassModeConfirmed, disableBypass, protectCredentialPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(ComposerTaskMode.self, forKey: .mode)
        approvalScope = try c.decode(ComposerApprovalScope.self, forKey: .approvalScope)
        effort = try c.decode(ComposerEffort.self, forKey: .effort)
        bypassModeConfirmed = try c.decode(Bool.self, forKey: .bypassModeConfirmed)
        // 新字段向后兼容：缺省值就是安全默认。
        disableBypass = try c.decodeIfPresent(Bool.self, forKey: .disableBypass) ?? false
        protectCredentialPaths = try c.decodeIfPresent(Bool.self, forKey: .protectCredentialPaths) ?? true
    }
}

/// Immutable policy identity captured when a chat turn is created.
public struct ComposerSubmissionSnapshot: Codable, Equatable, Sendable {
    public let mode: ComposerTaskMode
    public let approvalScope: ComposerApprovalScope
    public let effort: ComposerEffort
    public let sessionID: String
    public let turnID: Int
    public let taskID: String
    public let attemptID: String
    public let messageID: String
    /// A turn snapshot may leave this nil until AgentLoop receives a model call.
    public let callID: String?
    public let inputDigest: String?
    public let workspaceID: String
    public let createdAt: Date
    /// Non-optional policy identity. A missing/empty legacy value is rejected
    /// by the authorization controller instead of silently widening policy.
    public let policyRevision: String
    public let grantEpoch: String
    public let bypassModeConfirmed: Bool
    /// Frozen user ceiling for this turn; nil legacy snapshots fail closed.
    public let autonomyCeiling: AutonomyLevel?
    /// Set by the interactive Composer entry point for this submission only.
    /// Intentionally excluded from serialization: restored turns have no such authority.
    public private(set) var explicitlySelectedInteractiveAutoMode = false

    private enum CodingKeys: String, CodingKey {
        case mode, approvalScope, effort, sessionID, turnID, taskID, attemptID, messageID
        case callID, inputDigest, workspaceID, createdAt, policyRevision, grantEpoch
        case bypassModeConfirmed, autonomyCeiling
    }

    public var hasRequiredPolicyIdentity: Bool {
        !policyRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !grantEpoch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        mode: ComposerTaskMode,
        approvalScope: ComposerApprovalScope,
        effort: ComposerEffort,
        sessionID: String,
        turnID: Int,
        taskID: String,
        attemptID: String = "",
        messageID: String = "",
        callID: String? = nil,
        inputDigest: String? = nil,
        workspaceID: String,
        createdAt: Date,
        policyRevision: String,
        grantEpoch: String = "epoch-0",
        bypassModeConfirmed: Bool = false,
        autonomyCeiling: AutonomyLevel? = nil,
        explicitlySelectedInteractiveAutoMode: Bool = false
    ) {
        self.mode = mode
        self.approvalScope = approvalScope
        self.effort = effort
        self.sessionID = sessionID
        self.turnID = turnID
        self.taskID = taskID
        self.attemptID = attemptID
        self.messageID = messageID
        self.callID = callID
        self.inputDigest = inputDigest
        self.workspaceID = workspaceID
        self.createdAt = createdAt
        self.policyRevision = policyRevision
        self.grantEpoch = grantEpoch
        self.bypassModeConfirmed = bypassModeConfirmed
        self.autonomyCeiling = autonomyCeiling
        self.explicitlySelectedInteractiveAutoMode = explicitlySelectedInteractiveAutoMode
    }

    public func callSnapshot(
        callID: String,
        input: ComposerToolInput
    ) -> ComposerCallSnapshot {
        ComposerCallSnapshot(
            submission: self,
            callID: callID,
            inputDigest: input.digest
        )
    }
}

public struct ComposerCallSnapshot: Codable, Equatable, Sendable {
    public let mode: ComposerTaskMode
    public let approvalScope: ComposerApprovalScope
    public let effort: ComposerEffort
    public let sessionID: String
    public let turnID: Int
    public let taskID: String
    public let attemptID: String
    public let messageID: String
    public let callID: String
    public let inputDigest: String
    public let workspaceID: String
    public let createdAt: Date
    public let policyRevision: String
    public let grantEpoch: String
    public let identityDigest: String

    fileprivate init(
        submission: ComposerSubmissionSnapshot,
        callID: String,
        inputDigest: String
    ) {
        self.mode = submission.mode
        self.approvalScope = submission.approvalScope
        self.effort = submission.effort
        self.sessionID = submission.sessionID
        self.turnID = submission.turnID
        self.taskID = submission.taskID
        self.attemptID = submission.attemptID
        self.messageID = submission.messageID
        self.callID = callID
        self.inputDigest = inputDigest
        self.workspaceID = submission.workspaceID
        self.createdAt = submission.createdAt
        self.policyRevision = submission.policyRevision
        self.grantEpoch = submission.grantEpoch
        self.identityDigest = ComposerDigest.sha256(ComposerCallIdentity(
            sessionID: submission.sessionID,
            turnID: submission.turnID,
            taskID: submission.taskID,
            attemptID: submission.attemptID,
            messageID: submission.messageID,
            callID: callID,
            workspaceID: submission.workspaceID,
            policyRevision: submission.policyRevision,
            grantEpoch: submission.grantEpoch,
            inputDigest: inputDigest
        ))
    }
}

fileprivate struct ComposerCallIdentity: Codable {
    let sessionID: String
    let turnID: Int
    let taskID: String
    let attemptID: String
    let messageID: String
    let callID: String
    let workspaceID: String
    let policyRevision: String
    let grantEpoch: String
    let inputDigest: String
}

/// Immutable capability and workspace facts captured with a submission.
public struct ComposerPolicyFactSource: Equatable, Sendable {
    public let knownCapabilities: Set<String>
    public let grantedCapabilities: Set<String>
    /// Optional canonical grant identities for dynamic capabilities. A changed
    /// descriptor/schema/grant must not inherit a cached approval by name alone.
    public let capabilityGrantBindings: [String: String]
    public let allowedWriteRoots: [String]
    /// Canonical native project root, distinct from separately mounted grants.
    public let trustedProjectRoot: String?
    public let workspaceID: String
    public let revision: String
    public let grantEpoch: String
    /// Stable identity for the lease that issued these immutable facts.
    /// An empty value is rejected before capability evaluation.
    public let leaseID: String
    public let expiresAt: Date
    public let revoked: Bool
    /// Captured from the active production Goal when these facts are minted.
    public let autonomyCeiling: AutonomyLevel?

    public init(
        knownCapabilities: Set<String>,
        grantedCapabilities: Set<String>,
        capabilityGrantBindings: [String: String] = [:],
        allowedWriteRoots: [String],
        workspaceID: String,
        revision: String,
        grantEpoch: String = "epoch-0",
        leaseID: String,
        expiresAt: Date,
        revoked: Bool = false,
        autonomyCeiling: AutonomyLevel? = nil,
        trustedProjectRoot: String? = nil
    ) {
        self.knownCapabilities = knownCapabilities
        self.grantedCapabilities = grantedCapabilities
        self.capabilityGrantBindings = capabilityGrantBindings
        self.allowedWriteRoots = allowedWriteRoots
        self.trustedProjectRoot = trustedProjectRoot
        self.workspaceID = workspaceID
        self.revision = revision
        self.grantEpoch = grantEpoch
        self.leaseID = leaseID
        self.expiresAt = expiresAt
        self.revoked = revoked
        self.autonomyCeiling = autonomyCeiling
    }

    public static let unconfigured = ComposerPolicyFactSource(
        knownCapabilities: [],
        grantedCapabilities: [],
        allowedWriteRoots: [],
        workspaceID: "unconfigured",
        revision: "",
        grantEpoch: "revoked",
        leaseID: "unconfigured",
        expiresAt: .distantPast,
        revoked: true
    )
}

public enum ComposerAuthorizationError: Error, Equatable, Sendable {
    case unknownCapability(String)
    case missingCapabilityGrant(String)
    case scopeMismatch
    case policyRevisionMismatch
    case grantEpochMismatch
    case leaseIdentityMissing
    case factsExpired
    case autonomyCeilingMissing
    case autonomyCeilingMismatch
    case modeExceedsAutonomyCeiling(required: AutonomyLevel, maximum: AutonomyLevel)
    case authorizationRevoked
    case invalidInput
    case invalidPath(String)
    case pathOutsideAllowedRoots(String)
    case approvalRequired(String)
    case approvalDenied(String?)
    case bypassConfirmationRequired
    case authorizationBindingMismatch
    case hookDecisionDenied(HookDecisionReason)
    /// A registered Hook returned an explicit deny together with its reason text.
    case hookRejected(String)
}

extension ComposerAuthorizationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownCapability(let capability):
            return "Unknown Composer capability '\(capability)' is blocked"
        case .missingCapabilityGrant(let capability):
            return "Composer capability '\(capability)' has no grant"
        case .scopeMismatch:
            return "Composer approval scope does not match this workspace"
        case .policyRevisionMismatch:
            return "Composer policy facts changed after submission"
        case .grantEpochMismatch:
            return "Composer grants changed after submission"
        case .leaseIdentityMissing:
            return "Composer authorization lease has no stable identity"
        case .factsExpired:
            return "Composer policy facts expired"
        case .autonomyCeilingMissing:
            return "Composer user autonomy ceiling is missing"
        case .autonomyCeilingMismatch:
            return "Composer turn autonomy ceiling does not match its policy facts"
        case .modeExceedsAutonomyCeiling(let required, let maximum):
            return "当前模式需要自主权上限 L\(required.rawValue)，而你的上限是 L\(maximum.rawValue)。请把输入框齿轮里的模式改为手动审批，或到 设置 → 智能体运行 → 运行安全上限 调高上限。"
        case .authorizationRevoked:
            return "Composer authorization was revoked"
        case .invalidInput:
            return "Composer tool input is not a supported immutable value"
        case .invalidPath(let path):
            return "Invalid Composer file path: \(path)"
        case .pathOutsideAllowedRoots(let path):
            return "Composer file path is outside allowed roots: \(path)"
        case .approvalRequired(let capability):
            return "Composer approval is required for '\(capability)'"
        case .approvalDenied(let reason):
            return reason ?? "Composer approval was denied"
        case .bypassConfirmationRequired:
            return "Bypass permission mode requires explicit second confirmation"
        case .authorizationBindingMismatch:
            return "Composer authorization does not match this exact tool call"
        case .hookDecisionDenied(let reason):
            return "Composer hook blocked this tool call: \(reason.rawValue)"
        case .hookRejected(let reason):
            return "Composer hook blocked this tool call: " + reason
        }
    }
}

/// Frozen, recursively Sendable input values used by the Composer actor.
///
/// ToolExecutor still accepts the legacy `[String: Any]` at its public seam,
/// but `ComposerToolInput` immediately copies it into this value tree before
/// crossing an actor boundary. Reference-backed or otherwise unsupported
/// values are rejected rather than carried under `@unchecked Sendable`.
public enum ComposerInputValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([ComposerInputValue])
    case object([String: ComposerInputValue])
}

public struct ComposerToolInput: Codable, Equatable, Sendable {
    public let values: [String: ComposerInputValue]

    fileprivate var hasFiniteNumbers: Bool {
        values.values.allSatisfy(\.hasFiniteNumbers)
    }

    public init(_ values: [String: Any]) throws {
        var frozen: [String: ComposerInputValue] = [:]
        frozen.reserveCapacity(values.count)
        for (key, value) in values {
            frozen[key] = try Self.freeze(value)
        }
        self.values = frozen
    }

    public init(values: [String: ComposerInputValue]) {
        self.values = values
    }

    public var digest: String {
        ComposerDigest.sha256(values)
    }

    fileprivate var foundationDictionary: [String: Any] {
        values.mapValues(\.foundationValue)
    }

    fileprivate func stringValue(for key: String) -> String? {
        guard case .string(let value) = values[key] else { return nil }
        return value
    }

    private static func freeze(_ value: Any) throws -> ComposerInputValue {
        if value is NSNull { return .null }
        if type(of: value) == Bool.self, let value = value as? Bool {
            return .bool(value)
        }
        if type(of: value) == Int.self, let value = value as? Int {
            return .integer(Int64(value))
        }
        if type(of: value) == Int8.self, let value = value as? Int8 {
            return .integer(Int64(value))
        }
        if type(of: value) == Int16.self, let value = value as? Int16 {
            return .integer(Int64(value))
        }
        if type(of: value) == Int32.self, let value = value as? Int32 {
            return .integer(Int64(value))
        }
        if type(of: value) == Int64.self, let value = value as? Int64 {
            return .integer(value)
        }
        if type(of: value) == UInt.self, let value = value as? UInt {
            guard value <= UInt(Int64.max) else { throw ComposerAuthorizationError.invalidInput }
            return .integer(Int64(value))
        }
        if type(of: value) == UInt8.self, let value = value as? UInt8 {
            return .integer(Int64(value))
        }
        if type(of: value) == UInt16.self, let value = value as? UInt16 {
            return .integer(Int64(value))
        }
        if type(of: value) == UInt32.self, let value = value as? UInt32 {
            return .integer(Int64(value))
        }
        if type(of: value) == UInt64.self, let value = value as? UInt64 {
            guard value <= UInt64(Int64.max) else { throw ComposerAuthorizationError.invalidInput }
            return .integer(Int64(value))
        }
        if type(of: value) == Double.self,
           let value = value as? Double,
           value.isFinite {
            return .number(value)
        }
        if type(of: value) == Float.self,
           let value = value as? Float,
           value.isFinite {
            return .number(Double(value))
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            // JSONSerialization may box integers as NSNumber. Passing them
            // through Double first changes values above 2^53 and would bind
            // approval to a different input. Keep integral boxes exact and
            // reject values outside our Int64 value tree.
            switch String(cString: number.objCType) {
            case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q":
                guard let integer = Int64(number.stringValue) else {
                    throw ComposerAuthorizationError.invalidInput
                }
                return .integer(integer)
            default:
                break
            }
            let double = number.doubleValue
            guard double.isFinite else { throw ComposerAuthorizationError.invalidInput }
            if double.rounded() == double, let integer = Int64(exactly: double) {
                return .integer(integer)
            }
            return .number(double)
        }
        if let value = value as? String { return .string(value) }
        if let value = value as? [Any] {
            return .array(try value.map(Self.freeze))
        }
        if let value = value as? [String: Any] {
            var object: [String: ComposerInputValue] = [:]
            object.reserveCapacity(value.count)
            for (key, nested) in value {
                object[key] = try freeze(nested)
            }
            return .object(object)
        }
        throw ComposerAuthorizationError.invalidInput
    }
}

fileprivate extension ComposerInputValue {
    var hasFiniteNumbers: Bool {
        switch self {
        case .number(let value): return value.isFinite
        case .array(let values): return values.allSatisfy(\.hasFiniteNumbers)
        case .object(let values): return values.values.allSatisfy(\.hasFiniteNumbers)
        case .null, .bool, .integer, .string: return true
        }
    }
}

fileprivate extension ComposerInputValue {
    var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .integer(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationValue)
        case .object(let values):
            return values.mapValues(\.foundationValue)
        }
    }
}

/// Immutable audit identity emitted after an approval is accepted.
public struct ComposerApprovalReceipt: Codable, Equatable, Sendable {
    public let requestID: String
    public let callID: String
    public let messageID: String
    public let sessionID: String
    public let turnID: Int
    public let taskID: String
    public let attemptID: String
    public let approvalScope: ComposerApprovalScope
    public let mode: ComposerTaskMode
    public let riskLevel: ApprovalRiskLevel
    public let policyRevision: String
    public let grantEpoch: String
    public let leaseID: String
    public let leaseExpiresAt: Date
    public let leaseRevoked: Bool
    public let inputDigest: String
    public let approvedAt: Date
    public let identityDigest: String
    public let receiptDigest: String
    /// Set only when a persistent "allow from now on" rule authorized this
    /// call instead of a fresh prompt. The call-bound receipt is still minted.
    public let persistentRuleID: String?

    public var digest: String { receiptDigest }

    public init(
        requestID: String,
        callID: String,
        snapshot: ComposerSubmissionSnapshot,
        facts: ComposerPolicyFactSource,
        riskLevel: ApprovalRiskLevel,
        inputDigest: String,
        approvedAt: Date,
        persistentRuleID: String? = nil
    ) {
        self.persistentRuleID = persistentRuleID
        self.requestID = requestID
        self.callID = callID
        self.messageID = snapshot.messageID
        self.sessionID = snapshot.sessionID
        self.turnID = snapshot.turnID
        self.taskID = snapshot.taskID
        self.attemptID = snapshot.attemptID
        self.approvalScope = snapshot.approvalScope
        self.mode = snapshot.mode
        self.riskLevel = riskLevel
        self.policyRevision = snapshot.policyRevision
        self.grantEpoch = snapshot.grantEpoch
        self.leaseID = facts.leaseID
        self.leaseExpiresAt = facts.expiresAt
        self.leaseRevoked = facts.revoked
        self.inputDigest = inputDigest
        self.approvedAt = approvedAt
        let identity = ComposerCallIdentity(
            sessionID: snapshot.sessionID,
            turnID: snapshot.turnID,
            taskID: snapshot.taskID,
            attemptID: snapshot.attemptID,
            messageID: snapshot.messageID,
            callID: callID,
            workspaceID: snapshot.workspaceID,
            policyRevision: snapshot.policyRevision,
            grantEpoch: snapshot.grantEpoch,
            inputDigest: inputDigest
        )
        self.identityDigest = ComposerDigest.sha256(identity)
        self.receiptDigest = ComposerDigest.sha256(ComposerReceiptDigestPayload(
            requestID: requestID,
            callID: callID,
            messageID: messageID,
            sessionID: sessionID,
            turnID: turnID,
            taskID: taskID,
            attemptID: attemptID,
            approvalScope: approvalScope,
            mode: mode,
            riskLevel: riskLevel,
            policyRevision: policyRevision,
            grantEpoch: grantEpoch,
            leaseID: leaseID,
            leaseExpiresAt: leaseExpiresAt,
            leaseRevoked: leaseRevoked,
            inputDigest: inputDigest,
            approvedAt: approvedAt,
            identityDigest: identityDigest,
            persistentRuleID: persistentRuleID
        ))
    }
}

fileprivate struct ComposerReceiptDigestPayload: Codable {
    let requestID: String
    let callID: String
    let messageID: String
    let sessionID: String
    let turnID: Int
    let taskID: String
    let attemptID: String
    let approvalScope: ComposerApprovalScope
    let mode: ComposerTaskMode
    let riskLevel: ApprovalRiskLevel
    let policyRevision: String
    let grantEpoch: String
    let leaseID: String
    let leaseExpiresAt: Date
    let leaseRevoked: Bool
    let inputDigest: String
    let approvedAt: Date
    let identityDigest: String
    /// Omitted from the encoding when nil, so ordinary receipts keep their digest.
    let persistentRuleID: String?
}

public actor ComposerApprovalGrantStore {
    private struct GrantKey: Hashable {
        let capabilityGrantBinding: String?
        let capability: String
        let webFetchHost: String?
        let mode: ComposerTaskMode
        let policyRevision: String
        let grantEpoch: String
        let leaseID: String
        let workspaceID: String
        let sessionID: String?
        let turnID: Int?
        let taskID: String?
    }

    private var grants: Set<GrantKey> = []
    /// Human consent to a session/workspace scope is separate from the lease
    /// that authorized the approved call. A later task must still validate its
    /// own facts and bind its effect to its own lease.
    private struct ScopedConsent {
        let scope: ComposerApprovalScope
        let capability: String
        let webFetchHost: String?
        let mode: ComposerTaskMode
        let policyRevision: String
        let workspaceID: String
        let sessionID: String?
        let capabilityGrantBinding: String?
        let allowedWriteRoots: [String]
        let autonomyCeiling: AutonomyLevel?
        let riskLevel: ApprovalRiskLevel
        let taskID: String
        let grantEpoch: String
        let leaseID: String
        let expiresAt: Date
    }

    private var scopedConsents: [ScopedConsent] = []

    /// Durable "allow from now on" rules. Inert until the App root attaches a
    /// file; `revokeAll()` below never clears it (rules are user data).
    public nonisolated let persistentRules: PersistentApprovalRuleStore

    public init(persistentRules: PersistentApprovalRuleStore = PersistentApprovalRuleStore()) {
        self.persistentRules = persistentRules
    }

    public func revokeAll() {
        grants.removeAll()
        scopedConsents.removeAll()
    }

    fileprivate func contains(
        capability: String,
        input: ComposerToolInput,
        snapshot: ComposerSubmissionSnapshot,
        facts: ComposerPolicyFactSource,
        now: Date,
        scopeOverride: ComposerApprovalScope? = nil
    ) -> Bool {
        let scope = scopeOverride ?? snapshot.approvalScope
        guard let key = Self.key(capability: capability, input: input, snapshot: snapshot, facts: facts, scope: scope) else {
            return false
        }
        if grants.contains(key) { return true }
        guard scope == .session || scope == .workspace else {
            return false
        }
        let riskLevel = ApprovalGate.inputRiskLevel(tool: capability, input: input.foundationDictionary)
        return scopedConsents.contains { consent in
            consent.scope == scope
                && consent.capability == capability
                && consent.webFetchHost == key.webFetchHost
                && consent.mode == snapshot.mode
                && consent.policyRevision == facts.revision
                && consent.workspaceID == snapshot.workspaceID
                && consent.sessionID == (scope == .session ? snapshot.sessionID : nil)
                && consent.capabilityGrantBinding == facts.capabilityGrantBindings[capability]
                && consent.allowedWriteRoots == facts.allowedWriteRoots
                && consent.autonomyCeiling == facts.autonomyCeiling
                && Self.riskRank(riskLevel) <= Self.riskRank(consent.riskLevel)
                && consent.taskID != snapshot.taskID
                && consent.grantEpoch != facts.grantEpoch
                && consent.leaseID != facts.leaseID
                && consent.expiresAt > now
        }
    }

    fileprivate func insert(
        capability: String,
        input: ComposerToolInput,
        snapshot: ComposerSubmissionSnapshot,
        facts: ComposerPolicyFactSource,
        now: Date,
        scopeOverride: ComposerApprovalScope? = nil
    ) {
        let scope = scopeOverride ?? snapshot.approvalScope
        guard let key = Self.key(capability: capability, input: input, snapshot: snapshot, facts: facts, scope: scope) else {
            return
        }
        grants.insert(key)
        guard (scope == .session || scope == .workspace),
              facts.expiresAt > now else { return }
        scopedConsents.removeAll { $0.expiresAt <= now }
        scopedConsents.append(ScopedConsent(
            scope: scope,
            capability: capability,
            webFetchHost: key.webFetchHost,
            mode: snapshot.mode,
            policyRevision: facts.revision,
            workspaceID: snapshot.workspaceID,
            sessionID: scope == .session ? snapshot.sessionID : nil,
            capabilityGrantBinding: facts.capabilityGrantBindings[capability],
            allowedWriteRoots: facts.allowedWriteRoots,
            autonomyCeiling: facts.autonomyCeiling,
            riskLevel: ApprovalGate.inputRiskLevel(tool: capability, input: input.foundationDictionary),
            taskID: snapshot.taskID,
            grantEpoch: facts.grantEpoch,
            leaseID: facts.leaseID,
            expiresAt: facts.expiresAt
        ))
    }

    private static func riskRank(_ risk: ApprovalRiskLevel) -> Int {
        switch risk {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    private static func key(
        capability: String,
        input: ComposerToolInput,
        snapshot: ComposerSubmissionSnapshot,
        facts: ComposerPolicyFactSource,
        scope: ComposerApprovalScope
    ) -> GrantKey? {
        let webFetchHost: String?
        if capability == WebFetchToolContract.toolName {
            // A missing or invalid host cannot create or reuse a cached approval.
            guard let host = try? WebFetchToolContract.normalizedURLHost(input.foundationDictionary) else {
                return nil
            }
            webFetchHost = host
        } else {
            webFetchHost = nil
        }
        switch scope {
        case .request:
            return nil
        case .turn:
            return GrantKey(
                capabilityGrantBinding: facts.capabilityGrantBindings[capability],
                capability: capability,
                webFetchHost: webFetchHost,
                mode: snapshot.mode,
                policyRevision: facts.revision,
                grantEpoch: facts.grantEpoch,
                leaseID: facts.leaseID,
                workspaceID: snapshot.workspaceID,
                sessionID: snapshot.sessionID,
                turnID: snapshot.turnID,
                taskID: snapshot.taskID
            )
        case .session:
            return GrantKey(
                capabilityGrantBinding: facts.capabilityGrantBindings[capability],
                capability: capability,
                webFetchHost: webFetchHost,
                mode: snapshot.mode,
                policyRevision: facts.revision,
                grantEpoch: facts.grantEpoch,
                leaseID: facts.leaseID,
                workspaceID: snapshot.workspaceID,
                sessionID: snapshot.sessionID,
                turnID: nil,
                taskID: nil
            )
        case .workspace:
            return GrantKey(
                capabilityGrantBinding: facts.capabilityGrantBindings[capability],
                capability: capability,
                webFetchHost: webFetchHost,
                mode: snapshot.mode,
                policyRevision: facts.revision,
                grantEpoch: facts.grantEpoch,
                leaseID: facts.leaseID,
                workspaceID: snapshot.workspaceID,
                sessionID: nil,
                turnID: nil,
                taskID: nil
            )
        }
    }
}

public enum ComposerAuthorizationDecision: Equatable, Sendable {
    case execute
    case requestApproval(requiresSecondConfirmation: Bool)
    case dryRun
}

fileprivate enum ComposerAuthorizedDisposition: Sendable {
    case revoked
    case execute
    case dryRun
    case approved(ComposerApprovalReceipt, ComposerPendingApproval)
    case approvedSettings(ComposerApprovalReceipt, BL6SettingsApprovedCallContext, ApprovalAuthorizationContext)
    case approvedCatalogRead(ComposerApprovalReceipt)
    /// A persistent rule replaced the prompt; the receipt is still call-bound.
    case approvedByRule(ComposerApprovalReceipt)
}

struct ComposerPendingApproval: Sendable {
    let gate: ApprovalGate
    let request: ApprovalRequest
    let decision: ApprovalDecision
    /// The original, already-verified observation lane outlives authorizeExecution.
    /// It carries no grant and cannot change the approved call or effect.
    let presentation: ApprovalPresentationContext?
    var fileReviewWasUsed = false
    var approvedReadPath: String? = nil
}

actor ComposerExecutionAuthorization {
    private let callID: String
    private let capability: String
    private let inputDigest: String
    private let identityDigest: String
    private let leaseID: String
    private var disposition: ComposerAuthorizedDisposition
    private var consumed = false
    private var reviewingFileApproval = false
    private var abandonmentObserved = false

    /// A policy dry-run returns feedback but never crosses the tool-effect
    /// boundary. AgentLoop reads this typed decision before minting a fact.
    var isDryRun: Bool {
        if case .dryRun = disposition { return true }
        return false
    }

    /// AgentLoop calls this only when an authorized call is abandoned before
    /// execute consumes it. Tool terminal facts cannot settle approval waiting.
    /// This is observational and leaves the authorization's existing replay
    /// semantics untouched.
    func observeUnexecutedCancellation() {
        guard !consumed, !abandonmentObserved,
              case .approved(_, let pending) = disposition else { return }
        abandonmentObserved = true
        ApprovalAuthorityObservation.emit(
            .authorityCancelled, for: pending.request, using: pending.presentation
        )
    }

    fileprivate init(
        callID: String,
        capability: String,
        inputDigest: String,
        identityDigest: String,
        leaseID: String,
        disposition: ComposerAuthorizedDisposition
    ) {
        self.callID = callID
        self.capability = capability
        self.inputDigest = inputDigest
        self.identityDigest = identityDigest
        self.leaseID = leaseID
        self.disposition = disposition
    }

    /// Called under the existing physical-file scope before the one-shot
    /// authorization is consumed. Replaces the old pending approval in place;
    /// no new attempt, receipt identity, or replay-fence reset is created.
    fileprivate func reviewFileBeforeConsumption(input: ComposerToolInput,
        snapshot: ComposerSubmissionSnapshot, facts: ComposerPolicyFactSource) async throws {
        guard !consumed, !reviewingFileApproval else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        guard case .approved(let receipt, let pending) = disposition,
              let preview = pending.request.filePreview else { return }
        do { try preview.validateCurrent(); return }
        catch is ApprovalFileChangedError { }
        // Every observed stale version retires the pending approval, even
        // when its one allowed review was already used or no delegate exists.
        disposition = .revoked
        ApprovalAuthorityObservation.emit(.authorityRevoked, for: pending.request, using: pending.presentation)
        guard !pending.fileReviewWasUsed, let delegate = pending.gate.delegate else {
            throw ApprovalFileChangedError()
        }
        reviewingFileApproval = true
        defer { reviewingFileApproval = false }
        let reviewed = try await pending.gate.reviewChangedFile(request: pending.request,
            decision: pending.decision, input: input.foundationDictionary, delegate: delegate)
        try Task.checkCancellation()
        guard !consumed, reviewed.decision.approved, reviewed.decision.status == .approved,
              reviewed.decision.requestID == reviewed.request.requestID,
              reviewed.decision.bindingDigest == reviewed.request.identityDigest else {
            throw ComposerAuthorizationError.approvalDenied(reviewed.decision.reason)
        }
        guard !reviewed.request.requiresSecondConfirmation || reviewed.decision.confirmed else {
            throw ComposerAuthorizationError.bypassConfirmationRequired
        }
        try reviewed.request.filePreview?.validateCurrent()
        // Retire only the old unconsumed UI approval. The same canonical call
        // now owns the freshly reviewed request and its exact file version.
        let replacement = ComposerApprovalReceipt(requestID: reviewed.request.requestID,
            callID: receipt.callID, snapshot: snapshot, facts: facts,
            riskLevel: reviewed.request.riskLevel, inputDigest: input.digest, approvedAt: Date())
        disposition = .approved(replacement, ComposerPendingApproval(gate: pending.gate,
            request: reviewed.request, decision: reviewed.decision, presentation: pending.presentation,
            fileReviewWasUsed: true, approvedReadPath: pending.approvedReadPath))
    }

    fileprivate func consume(
        callID: String,
        capability: String,
        inputDigest: String,
        identityDigest: String,
        leaseID: String
    ) -> ComposerAuthorizedDisposition? {
        guard !consumed, !reviewingFileApproval,
              self.callID == callID,
              self.capability == capability,
              self.inputDigest == inputDigest,
              self.identityDigest == identityDigest,
              self.leaseID == leaseID else {
            return nil
        }
        consumed = true
        return disposition
    }
}

public actor ComposerAuthorizationController {
    public let snapshot: ComposerSubmissionSnapshot
    public let facts: ComposerPolicyFactSource
    public let grants: ComposerApprovalGrantStore

    private let now: @Sendable () -> Date
    private var revoked = false
    private let liveSkillBypassConfirmed: @Sendable () async -> Bool

    public init(
        snapshot: ComposerSubmissionSnapshot,
        facts: ComposerPolicyFactSource,
        grants: ComposerApprovalGrantStore = ComposerApprovalGrantStore(),
        now: @escaping @Sendable () -> Date = { Date() },
        liveSkillBypassConfirmed: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.liveSkillBypassConfirmed = liveSkillBypassConfirmed
        self.snapshot = snapshot
        self.facts = facts
        self.grants = grants
        self.now = now
    }

    public func revoke() {
        revoked = true
    }

    /// Required production seam: validate the frozen policy identity before
    /// any provider or tool call is started.
    public func validateSnapshot() throws {
        try validateIdentity()
    }

    public func authorize(
        capability: String,
        input: ComposerToolInput,
        policyRequiresApproval: Bool = false
    ) async throws -> ComposerAuthorizationDecision {
        try await authorizeResolvingRule(
            capability: capability, input: input, policyRequiresApproval: policyRequiresApproval
        ).decision
    }

    nonisolated var hasConfirmedBypass: Bool {
        snapshot.mode == .bypassPermission && snapshot.bypassModeConfirmed
    }

    /// The offer shown in the approval prompt; nil when this call kind has no
    /// persistent-allow concept (or no rule file is attached).
    public func persistentAllowOffer(
        capability: String, input: ComposerToolInput
    ) -> ApprovalPersistentAllowOffer? {
        grants.persistentRules.offer(
            capability: capability, input: input.foundationDictionary, facts: facts)
    }

    /// Persist the rule for a call the user just approved with "allow from
    /// now on". Re-evaluates eligibility from the raw frozen input.
    @discardableResult
    public func persistAllowRule(
        capability: String, input: ComposerToolInput
    ) -> PersistentApprovalRule? {
        persistAllowRule(capability: capability, input: input, expectedProjectKey: nil)
    }

    @discardableResult
    func persistAllowRule(
        capability: String, input: ComposerToolInput, expectedProjectKey: String?
    ) -> PersistentApprovalRule? {
        guard !revoked, !facts.revoked,
              let rule = grants.persistentRules.makeRule(
                capability: capability, input: input.foundationDictionary, facts: facts, now: now())
        else { return nil }
        // Compare the offered scope to the exact value handed to the store.
        if let expectedProjectKey {
            guard rule.projectKey == expectedProjectKey, rule.projectRoots.count == 1,
                  rule.capability == "shell_execute", rule.pattern == "git status" else { return nil }
        }
        guard grants.persistentRules.add(rule) else { return nil }
        return rule
    }

    /// `authorize`, additionally reporting a persistent rule that turned a
    /// would-be prompt into `.execute`. A rule can only replace the ordinary
    /// prompt: browser writes, settings mutations, file_delete, plan dry-run
    /// and bypass are decided before this point and never reach it.
    func authorizeResolvingRule(
        capability: String,
        input: ComposerToolInput,
        policyRequiresApproval: Bool = false,
        mandatoryHuman: Bool = false,
        excludingScopedGrant: Bool = false
    ) async throws -> (decision: ComposerAuthorizationDecision, rule: PersistentApprovalRule?) {
        let decision = try await baseAuthorize(
            capability: capability, input: input, policyRequiresApproval: policyRequiresApproval,
            mandatoryHuman: mandatoryHuman, excludingScopedGrant: excludingScopedGrant)
        if requiresExternalInputSkillReview(capability) { return (decision, nil) }
        if SkillMaintenanceTool.names.contains(capability), hasConfirmedBypass {
            if let rule = grants.persistentRules.match(
                capability: capability, input: input.foundationDictionary, facts: facts,
                bypassConfirmed: await liveSkillBypassConfirmed()
            ) {
                return (.execute, rule)
            }
            return (decision, nil)
        }
        guard case .requestApproval = decision,
              !mandatoryHuman,
              !Self.isAlwaysHuman(capability),
              !(try requiresOutsideReadApproval(capability: capability, input: input)),
              !requiresProtectedGitWriteApproval(capability: capability, input: input),
              !Self.isMCPServerManagement(capability: capability, input: input),
              capability != SessionReadTool.toolName,
              !BrowserSideEffectPolicy.inputRequiresApproval(
                tool: capability, input: input.foundationDictionary),
              let rule = grants.persistentRules.match(
                capability: capability, input: input.foundationDictionary, facts: facts,
                bypassConfirmed: await liveSkillBypassConfirmed())
        else { return (decision, nil) }
        return (.execute, rule)
    }

    private var outsideReadReceipts: Set<String> = []

    private func currentExternalInputLedger() -> (ToolExecutionReceipt, ToolExecutionFactLedger)? {
        guard let receipt = ToolExecutionReceiptContext.current,
              let ledger = ToolExecutionReceiptContext.ledger,
              let identity = receipt.executionIdentity,
              identity.turn.sessionID == snapshot.sessionID,
              identity.turn.turnID == snapshot.turnID,
              identity.turn.messageID == snapshot.messageID,
              receipt.attemptID == AgentToolExecutionAttemptID.canonical(
                  executionIdentity: identity, composerSnapshot: snapshot, childBoundary: nil),
              receipt.childTranscriptLocator == nil, ledger.pendingReceipts.contains(receipt)
        else { return nil }
        return (receipt, ledger)
    }

    static let externalInputSkillReviewEnabled = false

    private func requiresExternalInputSkillReview(_ capability: String) -> Bool {
        // 2026-11-15 用户决定（选"都不弹卡，绕过就是绕过"）：已确认的绕过档下整个会话按绕过处理，
        // 读过网页、外部会话、MCP 结果或项目外文件之后改技能，也不再额外弹卡。保留判定代码以便将来恢复。
        guard Self.externalInputSkillReviewEnabled else { return false }
        guard hasConfirmedBypass, SkillMaintenanceTool.names.contains(capability),
              let (receipt, ledger) = currentExternalInputLedger(), receipt.toolName == capability else { return false }
        return ledger.facts.contains { fact in
            guard fact.status == .succeeded, fact.executionIdentity == receipt.executionIdentity,
                  fact.attemptID == receipt.attemptID, fact.childTranscriptLocator == nil
            else { return false }
            let name = fact.toolName.lowercased()
            return name == WebFetchToolContract.toolName
                || BrowserSideEffectPolicy.browserToolNames.contains(name)
                || name == ExternalSessionToolNames.read || name == ExternalSessionToolNames.send
                || name.hasPrefix("mcp_") || outsideReadReceipts.contains(fact.receiptID)
        }
    }

    private func baseAuthorize(
        capability: String,
        input: ComposerToolInput,
        policyRequiresApproval: Bool = false,
        mandatoryHuman: Bool = false,
        excludingScopedGrant: Bool = false
    ) async throws -> ComposerAuthorizationDecision {
        try validate(capability: capability, input: input)

        if snapshot.mode == .plan, Self.hasSideEffect(capability) {
            return .dryRun
        }
        if hasConfirmedBypass {
            if requiresExternalInputSkillReview(capability) {
                return .requestApproval(requiresSecondConfirmation: true)
            }
            if ApprovedFileReadScope.isRead(capability),
               let (receipt, _) = currentExternalInputLedger(), receipt.toolName == capability,
               let path = input.stringValue(for: "path"),
               facts.trustedProjectRoot.map({ !PolicyRuntimePathBoundary.isWithinRoots(path: path, roots: [$0]) }) ?? true {
                outsideReadReceipts.insert(receipt.receiptID)
            }
            if SkillMaintenanceTool.names.contains(capability), !(await liveSkillBypassConfirmed()) {
                return .requestApproval(requiresSecondConfirmation: capability == "skill_delete")
            }
            if capability == "shell_execute",
               let command = input.stringValue(for: "command") {
                if let denial = SensitiveFilePolicy.protectedStateShellViolation(command: command)
                    ?? BypassSystemFloor.shellViolation(command: command)
                    ?? SensitiveFilePolicy.credentialShellViolation(command: command)
                    ?? BypassAppDataFloor.shellMentionViolation(command: command) {
                    throw ComposerAuthorizationError.approvalDenied(denial)
                }
                if BypassSystemFloor.requiresIrreversibleDeletionApproval(command: command) {
                    return .requestApproval(requiresSecondConfirmation: true)
                }
            }
            return .execute
        }
        if SkillMaintenanceTool.names.contains(capability) {
            return .requestApproval(requiresSecondConfirmation: capability == "skill_delete")
        }
        // The user's one-time Composer acknowledgement permits ordinary tool
        // calls without repeated prompts. The settings mutation is the sole
        // model-initiated approval exception and cannot reuse a scoped grant.
        // Browser writes never inherit auto/bypass permission. The browser
        // entry follows the user setting; every write still uses this gate.
        if BrowserSideEffectPolicy.inputRequiresApproval(tool: capability, input: input.foundationDictionary) {
            return .requestApproval(requiresSecondConfirmation: false)
        }
        if requiresProtectedGitWriteApproval(capability: capability, input: input) {
            return .requestApproval(requiresSecondConfirmation: false)
        }
        if mandatoryHuman || Self.isAlwaysHuman(capability) {
            return .requestApproval(requiresSecondConfirmation: false)
        }
        let outsideRead = try requiresOutsideReadApproval(capability: capability, input: input)
        if mandatoryHuman || outsideRead {
            return .requestApproval(requiresSecondConfirmation: false)
        }
        // Consent may cover the selected turn/session/workspace, while each
        // use still gets a fresh call-bound receipt at execution time.
        if capability == BL6SettingsToolApproval.catalogToolName
            || capability == BL6SettingsToolApproval.toolName {
            // Adding/removing an MCP server grants or revokes local command
            // execution: every call asks, never covered by a scoped consent.
            if Self.isMCPServerManagement(capability: capability, input: input) {
                return .requestApproval(requiresSecondConfirmation: false)
            }
            return .requestApproval(
                requiresSecondConfirmation: false
            )
        }
        // A physical deletion needs consent for each call. The ordinary
        // capability/input grant store is deliberately not consulted here.
        if capability == "file_delete" {
            return .requestApproval(
                requiresSecondConfirmation: false
            )
        }
        // A prior Composer capability grant is not a browser write grant.
        // Every concrete click/type needs its own approved, call-bound receipt.
        let browserSideEffect = BrowserSideEffectPolicy.inputRequiresApproval(
            tool: capability, input: input.foundationDictionary
        )
        guard browserSideEffect || policyRequiresApproval
                || Self.requiresApproval(mode: snapshot.mode, capability: capability) else {
            return .execute
        }
        // Reading another session asks on every call: a scoped consent has no
        // target/scope binding, so it must not cover a different read.
        if !excludingScopedGrant, try scopedGrantEligible(capability: capability, input: input) {
            if await grants.contains(capability: capability, input: input, snapshot: snapshot, facts: facts, now: now(), scopeOverride: .session) {
                return .execute
            }
            if await grants.contains(capability: capability, input: input, snapshot: snapshot, facts: facts, now: now()) {
                return .execute
            }
        }
        return .requestApproval(
            requiresSecondConfirmation: false
        )
    }

    static func isMCPServerManagement(capability: String, input: ComposerToolInput) -> Bool {
        guard capability == BL6SettingsToolApproval.toolName,
              let changes = input.foundationDictionary["changes"] as? [String: Any] else { return false }
        // Session trash/project, scheduled task and disabled user Hook
        // management also ask on every call.
        return changes.keys.contains {
            $0 == "mcp.servers.add" || $0 == "mcp.servers.remove"
                || $0 == "scheduler.tasks.add" || $0 == "scheduler.tasks.remove"
                || $0 == "hooks.entries.add" || $0 == "hooks.entries.remove"
                || ($0.hasPrefix("scheduler.") && $0.hasSuffix(".enabled"))
                || ($0.hasPrefix("session.") && ($0.hasSuffix(".trashed") || $0.hasSuffix(".archived") || $0.hasSuffix(".project")))
        }
    }

    public func recordApproval(
        capability: String,
        input: ComposerToolInput,
        allowInSession: Bool = false
    ) async throws {
        try validate(capability: capability, input: input)
        guard try scopedGrantEligible(capability: capability, input: input) else { return }
        await grants.insert(capability: capability, input: input, snapshot: snapshot, facts: facts,
                            now: now(), scopeOverride: allowInSession ? .session : nil)
    }

    func scopedGrantEligible(capability: String, input: ComposerToolInput) throws -> Bool {
        guard capability == "file_write" || capability == "file_edit",
              !ApprovalExecutionOriginContext.current.isUnattended,
              snapshot.mode != .bypassPermission,
              ApprovalGate.inputRiskLevel(tool: capability, input: input.foundationDictionary) != .high,
              !requiresProtectedGitWriteApproval(capability: capability, input: input),
              !(try requiresOutsideReadApproval(capability: capability, input: input))
        else { return false }
        return true
    }

    func revalidateSkillRule(_ receipt: ComposerApprovalReceipt, capability: String,
                             input: ComposerToolInput) async throws {
        let bypassConfirmed = await liveSkillBypassConfirmed()
        try validate(capability: capability, input: input)
        guard let current = grants.persistentRules.match(capability: capability,
            input: input.foundationDictionary, facts: facts,
            bypassConfirmed: bypassConfirmed),
              current.id == receipt.persistentRuleID else {
            throw ComposerAuthorizationError.approvalRequired(capability)
        }
    }

    func revalidateSkillBypass(capability: String, input: ComposerToolInput) async throws {
        guard hasConfirmedBypass, await liveSkillBypassConfirmed() else {
            throw ComposerAuthorizationError.approvalRequired(capability)
        }
        try validate(capability: capability, input: input)
    }

    public func revalidate(capability: String, input: ComposerToolInput) throws {
        try validate(capability: capability, input: input)
    }

    /// A native restore action uses the same confirmed Composer snapshot and
    /// path floors as a file effect. The stored checkpoint remains session,
    /// path, hash and expiry bound; no store-wide root is changed.
    public func restoreFileCheckpoint(
        _ id: UUID, store: FileCheckpointStore, sessionID: String
    ) throws -> Data? {
        guard snapshot.sessionID == sessionID, snapshot.mode == .bypassPermission,
              snapshot.bypassModeConfirmed,
              let summary = try store.summaries(sessionID: sessionID).first(where: { $0.id == id })
        else { throw ComposerAuthorizationError.authorizationBindingMismatch }
        let input = try ComposerToolInput(["path": summary.path])
        try validate(capability: "file_write", input: input)
        try Task.checkCancellation()
        return try BypassOpenScope.$isActive.withValue(true) {
            try store.restore(id, sessionID: sessionID, expectedPath: summary.path)
        }
    }

    /// Mint an internal browser origin only from this controller's canonical,
    /// confirmed frozen snapshot after the ordinary effect guards have run.
    /// A host-created matching TaskLocal identity alone is never authority.
    func browserBypassOrigin(
        callID: String,
        capability: String,
        input: ComposerToolInput
    ) throws -> BrowserBypassPolicyOrigin? {
        guard hasConfirmedBypass, !callID.isEmpty,
              BrowserSideEffectPolicy.inputRequiresApproval(tool: capability, input: input.foundationDictionary)
        else { return nil }
        try validate(capability: capability, input: input)
        return BrowserBypassPolicyOrigin(
            callID: callID, inputDigest: input.digest,
            sessionID: snapshot.sessionID, workspaceID: snapshot.workspaceID
        )
    }

    private func validate(capability: String, input: ComposerToolInput) throws {
        try validateIdentity()
        // The public typed initializer can bypass the Any-freezing path.
        // Never hash or authorize NaN/Infinity under a failed JSON digest.
        guard input.hasFiniteNumbers else {
            throw ComposerAuthorizationError.invalidInput
        }
        guard facts.knownCapabilities.contains(capability) else {
            throw ComposerAuthorizationError.unknownCapability(capability)
        }
        guard facts.grantedCapabilities.contains(capability) else {
            throw ComposerAuthorizationError.missingCapabilityGrant(capability)
        }
        if snapshot.mode == .bypassPermission, !snapshot.bypassModeConfirmed {
            throw ComposerAuthorizationError.bypassConfirmationRequired
        }
        try validatePath(capability: capability, input: input)
    }

    private func validateIdentity() throws {
        guard !revoked, !facts.revoked else {
            throw ComposerAuthorizationError.authorizationRevoked
        }
        guard facts.expiresAt > now() else {
            throw ComposerAuthorizationError.factsExpired
        }
        guard let ceiling = facts.autonomyCeiling,
              let frozenCeiling = snapshot.autonomyCeiling else {
            throw ComposerAuthorizationError.autonomyCeilingMissing
        }
        guard ceiling == frozenCeiling else {
            throw ComposerAuthorizationError.autonomyCeilingMismatch
        }
        guard snapshot.mode.requiredAutonomyLevel <= frozenCeiling else {
            throw ComposerAuthorizationError.modeExceedsAutonomyCeiling(
                required: snapshot.mode.requiredAutonomyLevel,
                maximum: frozenCeiling
            )
        }
        guard snapshot.workspaceID == facts.workspaceID else {
            throw ComposerAuthorizationError.scopeMismatch
        }
        // Policy identity is mandatory. Empty legacy snapshots and every
        // revision drift fail closed before capability or grant evaluation.
        guard snapshot.hasRequiredPolicyIdentity,
              !facts.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !facts.grantEpoch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snapshot.policyRevision == facts.revision else {
            throw ComposerAuthorizationError.policyRevisionMismatch
        }
        guard snapshot.grantEpoch == facts.grantEpoch else {
            throw ComposerAuthorizationError.grantEpochMismatch
        }
        guard !facts.leaseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComposerAuthorizationError.leaseIdentityMissing
        }
    }

    func matchingWebHostRule(input: ComposerToolInput) -> PersistentApprovalRule? {
        grants.persistentRules.match(capability: WebFetchToolContract.toolName, input: input.foundationDictionary, facts: facts)
    }

    func requiresProtectedGitWriteApproval(capability: String, input: ComposerToolInput) -> Bool {
        guard ["file_write", "file_edit", "file_delete"].contains(capability),
              let raw = input.stringValue(for: "path") else { return false }
        return SensitiveFilePolicy.isProtectedGitWritePath(raw)
            || PolicyRuntimePathBoundary.canonicalPath(raw).map(SensitiveFilePolicy.isProtectedGitWritePath) == true
    }

    func requiresOutsideReadApproval(capability: String, input: ComposerToolInput) throws -> Bool {
        guard ApprovedFileReadScope.isRead(capability),
              !(snapshot.mode == .bypassPermission && snapshot.bypassModeConfirmed),
              let path = input.stringValue(for: "path") else { return false }
        if capability == "file_read", try OwnedOutputArtifactReadContext.resolve(path: path) != nil { return false }
        return !PolicyRuntimePathBoundary.isWithinRoots(path: path, roots: facts.allowedWriteRoots)
    }

    private func validatePath(capability: String, input: ComposerToolInput) throws {
        guard capability == "file_read"
                || capability == "file_grep"
                || capability == "file_glob"
                || capability == "file_write"
                || capability == "file_edit"
                || capability == "file_delete"
        else { return }
        guard let rawPath = input.stringValue(for: "path"),
              rawPath.hasPrefix("/"),
              !rawPath.contains("\0")
        else {
            throw ComposerAuthorizationError.invalidPath(input.stringValue(for: "path") ?? "")
        }

        let ownedArtifactRead: Bool
        if capability == "file_read" {
            ownedArtifactRead = try OwnedOutputArtifactReadContext.resolve(path: rawPath) != nil
        } else { ownedArtifactRead = false }

        // 绕过模式（已确认）：不再受项目授权根限制，只保留系统底线与凭据保护。
        // 凭据保护（用户 2026-10-22 决定）只在绕过模式生效：读拒绝凭据目录与
        // .env/密钥文件名，写/改/删只拦凭据目录；设置里可关闭。
        // manual/autoEdit/plan/auto 不在此硬拒绝，读 .env 等走原有审批路径（7428f83 行为）。
        // 底线对规范化后的真实路径判断（解析符号链接），只约束改写/删除。
        if snapshot.mode == .bypassPermission, snapshot.bypassModeConfirmed {
            let isMutation = capability == "file_write" || capability == "file_edit" || capability == "file_delete"
            if let denial = SensitiveFilePolicy.credentialDenial(for: rawPath, forWrite: isMutation) {
                throw ComposerAuthorizationError.approvalDenied(denial)
            }
            if isMutation,
               let reason = BypassSystemFloor.violation(
                   path: rawPath, operation: capability == "file_delete" ? .delete : .modify) {
                throw ComposerAuthorizationError.approvalDenied(reason)
            }
            // MinisCanvas 自身数据/设置目录与钥匙串：读写删都拒绝（用户 2026-10-22 决定，
            // 取代绕过下对整个 Application Support 的拒绝）。
            if !ownedArtifactRead, let reason = BypassAppDataFloor.violation(
                path: rawPath,
                access: capability == "file_delete" ? .delete : (isMutation ? .modify : .read)) {
                throw ComposerAuthorizationError.approvalDenied(reason)
            }
            return
        }

        // A read outside the project is a promptable operation. Canonical
        // validity remains mandatory; the effect still needs a fresh receipt
        // and the builtin's denied/sensitive-path checks.
        if ApprovedFileReadScope.isRead(capability) {
            guard PolicyRuntimePathBoundary.canonicalPath(rawPath) != nil else {
                throw ComposerAuthorizationError.invalidPath(rawPath)
            }
            return
        }
        // Use the same PolicyRuntime canonical/real-path boundary as the
        // production goal executor. This catches traversal and symlink escape,
        // including a symlink in an existing parent directory.
        guard PolicyRuntimePathBoundary.isWithinRoots(
            path: rawPath,
            roots: facts.allowedWriteRoots
        ) else {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            throw ComposerAuthorizationError.pathOutsideAllowedRoots(path)
        }
    }

    /// Tools that need a fresh human decision on every call, in every mode
    /// including bypass, decided here so no caller can forget the argument.
    static func isAlwaysHuman(_ capability: String) -> Bool {
        capability == ExternalSessionToolNames.send
    }

    private static func hasSideEffect(_ capability: String) -> Bool {
        capability != AskUserQuestionTool.toolName
            && capability != ExternalSessionToolNames.read
            && capability != "file_read"
            && capability != "file_grep"
            && capability != "file_glob"
            && capability != "canvas_read"
            && capability != SessionReadTool.toolName
            && capability != OrchestrationToolExecutor.resultToolName
            && capability != BL6SettingsToolApproval.catalogToolName
            && capability != SessionTodoProgress.toolName
            && capability != ContextCompactTool.toolName
            && capability != SkillMaintenanceTool.readName
    }

    private static func requiresApproval(
        mode: ComposerTaskMode,
        capability: String
    ) -> Bool {
        // Reading another session needs the user's per-call decision (card shows
        // the target ID and scope); only bypass mode waives it.
        if capability == SessionReadTool.toolName { return mode != .bypassPermission }
        guard hasSideEffect(capability) else { return false }
        if isAlwaysHuman(capability) { return true }
        if capability == "file_delete" { return mode != .bypassPermission }
        switch mode {
        case .manual:
            return true
        case .autoEdit:
            return capability != "file_write" && capability != "file_edit"
        case .plan, .auto:
            return false
        case .bypassPermission:
            return false
        }
    }
}

/// One frozen tool call presented to an optional, registered hook handler.
public struct ComposerHookInvocation: Sendable {
    public let callID: String
    public let capability: String
    public let input: ComposerToolInput
    public let identityDigest: String
    /// Owning session, so a registered handler can resolve its project hooks.
    public let sessionID: String

    public init(
        callID: String, capability: String, input: ComposerToolInput, identityDigest: String,
        sessionID: String = ""
    ) {
        self.callID = callID
        self.capability = capability
        self.input = input
        self.identityDigest = identityDigest
        self.sessionID = sessionID
    }
}

public struct ComposerHookResult: Sendable {
    public let verdict: HookLayerVerdict
    public let invocationIdentityDigest: String
    /// Human-readable reason for a deny / ask; shown to the model and the user.
    public let reason: String?
    /// False for no hooks/no decision; a neutral allow cannot waive a prompt.
    public let hasDecision: Bool

    public init(verdict: HookLayerVerdict, invocationIdentityDigest: String, reason: String? = nil, hasDecision: Bool = true) {
        self.verdict = verdict
        self.invocationIdentityDigest = invocationIdentityDigest
        self.reason = reason
        self.hasDecision = hasDecision
    }
}

private struct ComposerHookCallIdentity: Encodable {
    let composerCallIdentityDigest: String
    let capability: String
}

private actor ComposerPreToolHookCache {
    private var tasks: [String: Task<ComposerHookResult, any Error>] = [:]
    func remove(_ identityDigest: String) { tasks.removeValue(forKey: identityDigest) }
    func result(_ invocation: ComposerHookInvocation,
                handler: @escaping @Sendable (ComposerHookInvocation) async throws -> ComposerHookResult) async throws -> ComposerHookResult {
        let task: Task<ComposerHookResult, any Error>
        if let current = tasks[invocation.identityDigest] { task = current }
        else {
            task = Task { try await handler(invocation) }
            tasks[invocation.identityDigest] = task
        }
        return try await withTaskCancellationHandler { try await task.value }
            onCancel: { task.cancel() }
    }
}

// Effect-local provenance only. No public initializer or TaskLocal setter can
// mint it; the final Composer installs it inside its existing authorized scope.
fileprivate struct ComposerIndependentFileEffect: Sendable {
    enum Kind: Sendable { case freshRead, confirmedBypass }
    @TaskLocal static var current: ComposerIndependentFileEffect?
    let ownerID: ObjectIdentifier
    let receipt: ToolExecutionReceipt
    let ledgerID: ObjectIdentifier
    let name: String
    let inputDigest: String
    let path: String?
    let kind: Kind
}

public final class ComposerPolicyEnforcedToolExecutor:
    NestedShellToolExecutor,
    ToolCatalogValidatingExecutor,
    PolicyRuntimeBoundToolExecutor,
    SessionReadCapabilityAwareToolExecutor,
    @unchecked Sendable
{
    /// Answers only whether this exact, pending call is already inside an
    /// independently authorized effect. It grants nothing and replaces none
    /// of the downstream Policy/Builtin/child safety checks.
    public static func hasIndependentFileEffectAuthority(
        owner: BuiltinToolExecutor, name: String, input: ComposerToolInput,
        receipt: ToolExecutionReceipt
    ) -> Bool {
        guard let effect = ComposerIndependentFileEffect.current,
              effect.ownerID == ObjectIdentifier(owner), effect.name == name,
              effect.inputDigest == input.digest, effect.receipt == receipt,
              ToolExecutionReceiptContext.current == receipt,
              let ledger = ToolExecutionReceiptContext.ledger,
              effect.ledgerID == ObjectIdentifier(ledger), ledger.pendingReceipts.contains(receipt),
              let identity = receipt.executionIdentity, identity.isValid,
              let key = receipt.compositeKey, key.isValid,
              key.operationID == identity.operationID, key.toolCallID == receipt.toolCallID else { return false }
        if name != "shell_execute" {
            guard let raw = input.stringValue(for: "path"),
                  let path = PolicyRuntimePathBoundary.canonicalPath(raw), path == effect.path else { return false }
        }
        switch effect.kind {
        case .freshRead:
            guard let path = effect.path else { return false }
            return ApprovedFileReadScope.permits(tool: name, path: path)
        case .confirmedBypass:
            guard BypassOpenScope.isActive else { return false }
            if AgentExecutionContext.current?.childRuntimeSnapshot != nil {
                return ChildToolWorkspaceScope.current?.filesOpen == true
            }
            return true
        }
    }

    private func withIndependentFileEffect(
        kind: ComposerIndependentFileEffect.Kind, callID: String,
        name: String, input: ComposerToolInput,
        action: () async throws -> String
    ) async rethrows -> String {
        let snapshot = controller.snapshot
        guard let owner = (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner,
              let receipt = ToolExecutionReceiptContext.current, receipt.toolName == name,
              receipt.toolCallID == callID, let identity = receipt.executionIdentity, identity.isValid,
              identity.turn.sessionID == snapshot.sessionID, identity.turn.turnID == snapshot.turnID,
              identity.turn.messageID == snapshot.messageID,
              receipt.attemptID == AgentToolExecutionAttemptID.canonical(
                executionIdentity: identity, composerSnapshot: snapshot, childBoundary: nil),
              let ledger = ToolExecutionReceiptContext.ledger, ledger.pendingReceipts.contains(receipt),
              ["file_read", "file_grep", "file_glob", "file_write", "file_edit", "file_delete", "shell_execute"].contains(name)
        else { return try await action() }
        let path = input.stringValue(for: "path").flatMap(PolicyRuntimePathBoundary.canonicalPath)
        let effect = ComposerIndependentFileEffect(ownerID: ObjectIdentifier(owner), receipt: receipt,
            ledgerID: ObjectIdentifier(ledger), name: name, inputDigest: input.digest, path: path, kind: kind)
        return try await ComposerIndependentFileEffect.$current.withValue(effect, operation: action)
    }

    private let preToolHookCache = ComposerPreToolHookCache()
    public let base: any ToolExecutor
    public let controller: ComposerAuthorizationController
    public let approvalGate: ApprovalGate?
    private let skillMaintenance: SkillMaintenanceTool?
    public var policyRuntimeBound: Bool {
        (base as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound == true
    }
    /// Production may persist this audit record without re-deriving identity
    /// from mutable UI state. The callback is invoked only after approval.
    public let onApprovalReceipt: (@Sendable (ComposerApprovalReceipt) -> Void)?
    /// Nil means there is no registered handler for this executor. The normal
    /// call remains eligible through an explicit neutral hook layer.
    public let hookHandler: (@Sendable (ComposerHookInvocation) async throws -> ComposerHookResult)?
    /// Goal18 Hooks: PostToolUse observer. It runs after a successful tool call and
    /// may only append context for the model; it cannot change the result's success.
    public let postToolHandler: (@Sendable (ComposerPostToolInvocation) async -> String?)?

    public init(
        base: any ToolExecutor,
        controller: ComposerAuthorizationController,
        approvalGate: ApprovalGate? = nil,
        skillMaintenance: SkillMaintenanceTool? = nil,
        onApprovalReceipt: (@Sendable (ComposerApprovalReceipt) -> Void)? = nil,
        hookHandler: (@Sendable (ComposerHookInvocation) async throws -> ComposerHookResult)? = nil,
        postToolHandler: (@Sendable (ComposerPostToolInvocation) async -> String?)? = nil
    ) {
        self.base = base
        self.controller = controller
        self.approvalGate = approvalGate
        self.skillMaintenance = skillMaintenance
        self.onApprovalReceipt = onApprovalReceipt
        self.hookHandler = hookHandler
        self.postToolHandler = postToolHandler
    }

    public func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        try (base as? any ToolCatalogValidatingExecutor)?.validateToolCatalog(tools)
    }

    /// A trusted orchestration consumer may issue one independent shell call
    /// through the real outer Composer. Keep the parent receipt as provenance,
    /// authorize this exact command afresh, then mint/settle its own receipt.
    public func executeNestedShell(callID: String, input: [String: Any]) async throws -> String {
        let frozen = try ComposerToolInput(input)
        let parent = try NestedShellReceiptBridge.captureParent(snapshot: controller.snapshot, callID: callID)
        return try await NestedShellExecutionScope.$requiresFreshApproval.withValue(true) {
            let authorization = try await self.authorizeExecution(callID: callID,
                name: "shell_execute", input: frozen.foundationDictionary)
            do {
                guard !(await authorization.isDryRun) else {
                    throw ToolExecutorError.approvalRequired("child_worktree_plan_mode")
                }
                return try await NestedShellReceiptBridge.execute(parent: parent, callID: callID,
                    input: frozen, executor: self) {
                    try await self.execute(preauthorization: authorization, callID: callID,
                        name: "shell_execute", input: frozen.foundationDictionary)
                }
            } catch {
                await authorization.observeUnexecutedCancellation()
                throw error
            }
        }
    }

    public func execute(name: String, input: [String: Any]) async throws -> String {
        let frozen = try ComposerToolInput(input)
        guard let receipt = ToolExecutionReceiptContext.current else {
            return try await execute(callID: "direct", name: name, input: frozen)
        }
        // Generic wrappers still run inside the original ledger-minted call.
        // A foreign or partial receipt must never become a new direct call.
        let snapshot = controller.snapshot
        guard receipt.toolName == name,
              let identity = receipt.executionIdentity, identity.isValid,
              let key = receipt.compositeKey, key.isValid,
              identity.turn.sessionID == snapshot.sessionID,
              identity.turn.turnID == snapshot.turnID,
              identity.turn.messageID == snapshot.messageID,
              receipt.attemptID == AgentToolExecutionAttemptID.canonical(
                executionIdentity: identity, composerSnapshot: snapshot, childBoundary: nil
              ),
              receipt.attemptNumber == identity.attempt,
              key.sessionID == identity.turn.sessionID,
              key.turnID == identity.turn.turnID,
              key.messageID == identity.turn.messageID,
              key.operationID == identity.operationID,
              key.attemptID == receipt.attemptID,
              key.attemptNumber == receipt.attemptNumber,
              key.toolCallID == receipt.toolCallID else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        return try await execute(callID: receipt.toolCallID, name: name, input: frozen)
    }

    /// AgentLoop's controlled call-aware entry. Only this final wrapper owns
    /// the Composer Policy -> Approval -> Executor chain; arbitrary
    /// ToolExecutor implementations cannot opt out of AgentLoop's gate.
    public func execute(
        callID: String,
        name: String,
        input: [String: Any]
    ) async throws -> String {
        let frozen = try ComposerToolInput(input)
        return try await execute(callID: callID, name: name, input: frozen)
    }

    public func execute(
        callID: String,
        name: String,
        input: ComposerToolInput
    ) async throws -> String {
        try await perform(callID: callID, name: name, input: input) { frozenInput in
            try await base.execute(name: name, input: frozenInput.foundationDictionary)
        }
    }

    /// A Composer mode can permit an effect, while the configured global
    /// gate still requires consent. Use its existing input classification
    /// inside the controller's original scope-grant and live-identity checks.
    private func preToolHook(callID: String, name: String, input: ComposerToolInput) async throws -> ComposerHookResult? {
        guard let handler = hookHandler ?? HookRuntime.installed?.composerHookHandler else { return nil }
        let digest = ComposerDigest.sha256(ComposerHookCallIdentity(
            composerCallIdentityDigest: controller.snapshot.callSnapshot(callID: callID, input: input).identityDigest,
            capability: name))
        let invocation = ComposerHookInvocation(callID: callID, capability: name, input: input,
            identityDigest: digest, sessionID: controller.snapshot.sessionID)
        let result = try await preToolHookCache.result(invocation, handler: handler)
        try Task.checkCancellation()
        guard result.invocationIdentityDigest == digest else {
            throw ComposerAuthorizationError.hookDecisionDenied(.hookHandlerIdentityMismatch)
        }
        return result
    }

    private func clearPreToolHook(callID: String, name: String, input: ComposerToolInput) async {
        let digest = ComposerDigest.sha256(ComposerHookCallIdentity(
            composerCallIdentityDigest: controller.snapshot.callSnapshot(callID: callID, input: input).identityDigest,
            capability: name))
        await preToolHookCache.remove(digest)
    }

    private func mcpRequiresUserInteraction(_ capability: String) -> Bool {
        let bridge = MCPToolBridgeTaskContext.current ?? (base as? BuiltinToolExecutor)?.mcpBridge
        return (bridge as? any MCPToolBridgeInteractionResolving)?.requiresUserInteraction(capability) ?? false
    }

    private var pinnedWebFetchConfiguration: WebFetchPinnedConfiguration? {
        guard let owner = (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner,
              let configuration = owner.webFetchPinnedConfiguration, configuration.isAdmitted else { return nil }
        return configuration
    }

    private func requiresPinnedWebFetch(_ input: ComposerToolInput) -> Bool {
        guard let configuration = pinnedWebFetchConfiguration,
              let raw = input.stringValue(for: "url"), let url = URL(string: raw) else { return false }
        return !configuration.isWithinConfiguredCeiling(url)
    }

    /// Runs only after the original human/rule/Hook decision. It cannot turn a
    /// private DNS answer or a proxy-required route into a web permission.
    private func validatePinnedWebFetchDestination(_ input: ComposerToolInput) async throws {
        guard requiresPinnedWebFetch(input), let configuration = pinnedWebFetchConfiguration,
              let raw = input.stringValue(for: "url"), let url = URL(string: raw) else { return }
        let endpoint = try WebFetchEndpoint(url)
        try configuration.routeProvider(endpoint.url).requireConfirmedDirect()
        let addresses = try await configuration.operations.resolve(endpoint)
        guard !addresses.isEmpty, addresses.allSatisfy(\.isPublic) else {
            throw WebFetchPinnedError.nonPublicDestination
        }
        try await controller.revalidate(capability: WebFetchToolContract.toolName, input: input)
    }

    /// Local route inspection only. DNS and public-address checks remain after approval.
    private func preflightPinnedWebFetchRoute(_ input: ComposerToolInput) throws {
        guard requiresPinnedWebFetch(input), let configuration = pinnedWebFetchConfiguration,
              let raw = input.stringValue(for: "url"), let url = URL(string: raw) else { return }
        let endpoint = try WebFetchEndpoint(url)
        try configuration.routeProvider(endpoint.url).requireConfirmedDirect()
    }

    private func makePinnedWebFetchPermit(callID: String, input: ComposerToolInput,
        approved: (ComposerApprovalReceipt, ComposerPendingApproval)?,
        ruleReceipt: ComposerApprovalReceipt?) async throws -> WebFetchPinnedCallPermit? {
        guard requiresPinnedWebFetch(input), let configuration = pinnedWebFetchConfiguration else { return nil }
        let binding = try WebFetchCallBinding(snapshot: controller.snapshot, facts: controller.facts,
            callID: callID, input: input)
        let source: WebFetchPinnedCallPermit.Source
        if let (receipt, pending) = approved {
            guard pending.decision.approved, pending.decision.status == .approved,
                  pending.request.callID == callID,
                  pending.decision.requestID == pending.request.requestID,
                  binding.matchesFreshHumanReceipt(receipt) else {
                throw ComposerAuthorizationError.authorizationBindingMismatch
            }
            source = .humanReceipt(receipt)
        } else if let receipt = ruleReceipt,
                  let rule = await controller.matchingWebHostRule(input: input),
                  rule.id == receipt.persistentRuleID {
            source = .rememberedProjectRule(rule.id)
        } else if controller.hasConfirmedBypass {
            source = .confirmedBypass
        } else { throw ComposerAuthorizationError.approvalRequired(WebFetchToolContract.toolName) }
        return WebFetchPinnedCallPermit(binding: binding, source: source) { url in
            try binding.validate(snapshot: self.controller.snapshot, facts: self.controller.facts,
                callID: callID, input: input)
            try await self.controller.revalidate(capability: WebFetchToolContract.toolName, input: input)
            let endpoint = try WebFetchEndpoint(url)
            let hopSource: WebFetchPinnedCallPermit.Source
            let hopInput: ComposerToolInput
            if url != binding.endpoint.url {
                let hop = try await self.authorizeWebFetchRedirect(url, rootCallID: callID)
                guard hop.binding.endpoint == endpoint, hop.rootCallID == callID else {
                    throw ComposerAuthorizationError.authorizationBindingMismatch
                }
                hopSource = hop.source
                hopInput = try ComposerToolInput(["url": url.absoluteString])
            } else {
                hopSource = source
                hopInput = input
            }
            if case .rememberedProjectRule(let id) = hopSource {
                guard await self.controller.matchingWebHostRule(input: hopInput)?.id == id else {
                    throw ComposerAuthorizationError.approvalRequired(WebFetchToolContract.toolName)
                }
            }
            try configuration.routeProvider(url).requireConfirmedDirect()
            let addresses = try await configuration.operations.resolve(endpoint)
            try await self.controller.revalidate(capability: WebFetchToolContract.toolName, input: input)
            // Resolve once, inspect all answers, then bind the selected numeric
            // endpoint to the actual connection. No DNS/network fallback retry.
            guard !addresses.isEmpty, addresses.allSatisfy(\.isPublic),
                  let address = addresses.first else { throw WebFetchPinnedError.nonPublicDestination }
            try configuration.routeProvider(url).requireConfirmedDirect()
            // A saved rule may have been removed while DNS was in flight.
            if case .rememberedProjectRule(let id) = hopSource {
                guard await self.controller.matchingWebHostRule(input: hopInput)?.id == id else {
                    throw ComposerAuthorizationError.approvalRequired(WebFetchToolContract.toolName)
                }
            }
            return try await configuration.operations.load(
                WebFetchPinnedCurlInvocation(endpoint: endpoint, address: address, route: .directConfirmed), url)
        }
    }

    private func authorizeWebFetchRedirect(_ url: URL, rootCallID: String) async throws -> WebFetchRedirectAuthorization {
        let callID = rootCallID + ":redirect:" + UUID().uuidString
        let input = try ComposerToolInput(["url": url.absoluteString])
        do {
            let resolved = try await authorizationDecision(callID: callID,
                capability: WebFetchToolContract.toolName, input: input)
            let binding = try WebFetchCallBinding(snapshot: controller.snapshot, facts: controller.facts,
                callID: callID, input: input)
            let source: WebFetchPinnedCallPermit.Source
            switch resolved.decision {
            case .dryRun: throw ComposerAuthorizationError.approvalRequired(WebFetchToolContract.toolName)
            case .execute:
                try await controller.revalidate(capability: WebFetchToolContract.toolName, input: input)
                if let configuration = pinnedWebFetchConfiguration, configuration.isWithinConfiguredCeiling(url) {
                    source = .configuredCeiling
                } else if let rule = resolved.rule,
                          await controller.matchingWebHostRule(input: input)?.id == rule.id {
                    source = .rememberedProjectRule(rule.id)
                } else if controller.hasConfirmedBypass {
                    source = .confirmedBypass
                } else { throw ComposerAuthorizationError.approvalRequired(WebFetchToolContract.toolName) }
            case .requestApproval(let second):
                try preflightPinnedWebFetchRoute(input)
                let pending = try await requestApproval(callID: callID, name: WebFetchToolContract.toolName,
                    input: input, requiresSecondConfirmation: second)
                try await validatePinnedWebFetchDestination(input)
                try await controller.revalidate(capability: WebFetchToolContract.toolName, input: input)
                let receipt = ComposerApprovalReceipt(requestID: pending.request.requestID,
                    callID: callID, snapshot: controller.snapshot, facts: controller.facts,
                    riskLevel: pending.request.riskLevel, inputDigest: input.digest, approvedAt: Date())
                guard binding.matchesFreshHumanReceipt(receipt) else {
                    throw ComposerAuthorizationError.authorizationBindingMismatch
                }
                source = .humanReceipt(receipt)
                try await persistAllowIfRequested(pending, name: WebFetchToolContract.toolName, input: input)
            }
            await clearPreToolHook(callID: callID, name: WebFetchToolContract.toolName, input: input)
            return WebFetchRedirectAuthorization(rootCallID: rootCallID, binding: binding, source: source)
        } catch {
            await clearPreToolHook(callID: callID, name: WebFetchToolContract.toolName, input: input)
            throw error
        }
    }

    // Module-visible for contract tests of the same production decision seam.
    private func requiresFreshShellApproval(capability: String, input: ComposerToolInput) -> Bool {
        capability == "shell_execute" && (NestedShellExecutionScope.requiresFreshApproval
            || (controller.snapshot.mode != .bypassPermission
                && (approvalGate?.requiresExplicitShellConfirmation(
                    tool: capability, input: input.foundationDictionary) == true
                    || input.stringValue(for: "command").map {
                        (approvalGate?.terminalPolicySnapshot ?? .default).classify(command: $0) == .unknown
                    } == true)))
    }

    /// A `.confirmation` shell command is approved per call: the scoped grant key
    /// carries no command, so it must not cover a later, different command. A
    /// persistent "allow from now on" rule (and its offer) still applies.
    private func requiresPerCallShellApproval(capability: String, input: ComposerToolInput) -> Bool {
        capability == "shell_execute" && input.stringValue(for: "command").map {
            (approvalGate?.terminalPolicySnapshot ?? .default).classify(command: $0) == .confirmation
        } == true
    }

    func authorizationDecision(
        callID: String,
        capability: String,
        input: ComposerToolInput,
        bypassApprovalGate: Bool = false
    ) async throws -> (decision: ComposerAuthorizationDecision, rule: PersistentApprovalRule?) {
        let mandatoryMCPInteraction = mcpRequiresUserInteraction(capability)
        let outsideRead = try await controller.requiresOutsideReadApproval(capability: capability, input: input)
        let protectedGitWrite = await controller.requiresProtectedGitWriteApproval(capability: capability, input: input)
        let unknownShell = requiresFreshShellApproval(capability: capability, input: input)
        let pinnedWeb = capability == WebFetchToolContract.toolName && requiresPinnedWebFetch(input)
        let snapshot = controller.snapshot
        let deferGlobalFilePrompt = snapshot.explicitlySelectedInteractiveAutoMode
            && (snapshot.mode == .autoEdit || snapshot.mode == .auto)
            && (capability == "file_write" || capability == "file_edit")
            && !HookPayload.touchesSensitivePath(input)
            && AgentExecutionContext.current?.childRuntimeSnapshot == nil
            && AgentExecutionContext.current?.childToolRuntimeBinding == nil
        var resolved = try await controller.authorizeResolvingRule(
            capability: capability,
            input: input,
            policyRequiresApproval: bypassApprovalGate
                ? false
                : (approvalGate?.shouldAsk(
                    tool: capability, input: input.foundationDictionary,
                    deferringGlobalFilePromptToComposer: deferGlobalFilePrompt
                ) ?? false),
            mandatoryHuman: unknownShell,
            excludingScopedGrant: requiresPerCallShellApproval(capability: capability, input: input)
        )
        if case .dryRun = resolved.decision { return resolved }
        if BrowserSideEffectPolicy.browserToolNames.contains(capability),
           input.stringValue(for: "action") == "navigate",
           let raw = input.stringValue(for: "url")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let destination = URL(string: raw), BrowserNavigationPolicy.isValidWebURL(destination),
           let host = destination.host,
           (base as? any BrowserDestinationPolicyChecking)?.permitsBrowserDestination(host: host) == false {
            throw ComposerAuthorizationError.approvalDenied(BrowserNavigationPolicy.allowedWebsitesSettingsGuidance)
        }
        if pinnedWeb && !controller.hasConfirmedBypass {
            if let rule = await controller.matchingWebHostRule(input: input) {
                resolved = (.execute, rule)
            } else {
                let second: Bool
                if case .requestApproval(let value) = resolved.decision { second = value } else { second = false }
                resolved = (.requestApproval(requiresSecondConfirmation: second), nil)
            }
        }
        if let gate = approvalGate,
           gate.policy(for: capability) == .deny || gate.policy(for: capability) == .never {
            throw ComposerAuthorizationError.approvalDenied("Capability is blocked by approval policy")
        }
        let hook = try await preToolHook(callID: callID, name: capability, input: input)
        try await controller.revalidate(capability: capability, input: input)
        if let hook, hook.hasDecision {
            switch hook.verdict {
            case .deny:
                throw ComposerAuthorizationError.hookRejected(hook.reason ?? "Hook 阻止本次工具调用")
            case .ask:
                if controller.hasConfirmedBypass { return resolved }
                let second: Bool
                if case .requestApproval(let requiresSecond) = resolved.decision { second = requiresSecond }
                else { second = false }
                return (.requestApproval(requiresSecondConfirmation: second), nil)
            case .allow:
                // Only ordinary prompt choice is replaceable. Mandatory human
                // contracts and every existing lower-level deny/floor remain.
                let mandatoryHuman = SkillMaintenanceTool.names.contains(capability)
                    || mandatoryMCPInteraction || capability == "file_delete"
                    || outsideRead || protectedGitWrite || unknownShell || pinnedWeb
                    || capability == BL6SettingsToolApproval.toolName
                    || capability == BL6SettingsToolApproval.catalogToolName
                    || ComposerAuthorizationController.isAlwaysHuman(capability)
                    || BrowserSideEffectPolicy.inputRequiresApproval(tool: capability, input: input.foundationDictionary)
                    || HookPayload.touchesSensitivePath(input)
                    || ApprovalGate.inputRiskLevel(tool: capability, input: input.foundationDictionary) == .high
                if !mandatoryHuman, case .requestApproval(let second) = resolved.decision, !second {
                    return (.execute, nil)
                }
            }
        }
        if mandatoryMCPInteraction && !controller.hasConfirmedBypass {
            // A server's tools/list metadata can tighten the existing human
            // approval contract, never override a deny or plan dry-run above.
            let second: Bool
            if case .requestApproval(let value) = resolved.decision { second = value } else { second = false }
            return (.requestApproval(requiresSecondConfirmation: second), nil)
        }
        return resolved
    }

    /// A rule hit replaces only the prompt. The call still gets its own
    /// call-bound receipt, minted from the same frozen snapshot and facts.
    private func ruleReceipt(
        callID: String, name: String, input: ComposerToolInput, rule: PersistentApprovalRule
    ) -> ComposerApprovalReceipt {
        ComposerApprovalReceipt(
            requestID: callID, callID: callID,
            snapshot: controller.snapshot, facts: controller.facts,
            // Same value the prompt path records (`ApprovalGate.makeRequest`):
            // the larger of the tool-level and the input-level risk.
            riskLevel: ApprovalRiskLevel.max(
                approvalGate?.riskLevel(for: name) ?? ApprovalGate.riskByTool[name] ?? .medium,
                ApprovalGate.inputRiskLevel(tool: name, input: input.foundationDictionary)),
            inputDigest: input.digest, approvedAt: Date(), persistentRuleID: rule.id
        )
    }

    /// Persist the user's "allow from now on" choice only after the approved
    /// call survived revalidation. Eligibility errors propagate through the
    /// authorization failure path; failure to save never fails the call.
    func persistAllowIfRequested(
        _ pending: ComposerPendingApproval, name: String, input: ComposerToolInput
    ) async throws {
        guard !requiresFreshShellApproval(capability: name, input: input),
              !(try await controller.requiresOutsideReadApproval(capability: name, input: input)),
              !(await controller.requiresProtectedGitWriteApproval(capability: name, input: input)) else { return }
        guard !SkillMaintenanceTool.names.contains(name) || pending.decision.skillRiskConfirmed else { return }
        guard !mcpRequiresUserInteraction(name), !pending.request.isHookAsk, pending.decision.persistAllow, pending.decision.approved,
              let offer = pending.request.persistentAllowOffer, offer.isAvailable else { return }
        _ = await controller.persistAllowRule(
            capability: name, input: input, expectedProjectKey: offer.projectKey)
    }

    func authorizeExecution(
        callID: String,
        name: String,
        input: [String: Any],
        bypassApprovalGate: Bool = false
    ) async throws -> ComposerExecutionAuthorization {
        let frozen = try ComposerToolInput(input)
        do {
        let resolved = try await authorizationDecision(
            callID: callID, capability: name,
            input: frozen,
            bypassApprovalGate: bypassApprovalGate
        )
        let disposition: ComposerAuthorizedDisposition
        switch resolved.decision {
        case .dryRun:
            disposition = .dryRun
        case .execute:
            if let rule = resolved.rule {
                try await controller.revalidate(capability: name, input: frozen)
                disposition = .approvedByRule(
                    ruleReceipt(callID: callID, name: name, input: frozen, rule: rule))
            } else if name == BL6SettingsToolApproval.toolName {
                let approved = try await approveSettingsCall(
                    callID: callID,
                    input: frozen,
                    requiresSecondConfirmation: false,
                    reusingScopedConsent: true
                )
                disposition = .approvedSettings(approved.receipt, approved.call, approved.facts)
            } else if name == BL6SettingsToolApproval.catalogToolName {
                let gate = try requireSettingsGate(name)
                disposition = .approvedCatalogRead(ComposerApprovalReceipt(
                    requestID: callID, callID: callID,
                    snapshot: controller.snapshot, facts: controller.facts,
                    riskLevel: gate.riskLevel(for: name),
                    inputDigest: frozen.digest, approvedAt: Date()
                ))
            } else {
                try await controller.revalidate(capability: name, input: frozen)
                disposition = .execute
            }
        case .requestApproval(let requiresSecondConfirmation):
            if name == BL6SettingsToolApproval.toolName {
                let approved = try await approveSettingsCall(
                    callID: callID,
                    input: frozen,
                    requiresSecondConfirmation: requiresSecondConfirmation
                )
                try await controller.recordApproval(capability: name, input: frozen)
                disposition = .approvedSettings(approved.receipt, approved.call, approved.facts)
            } else {
                if name == WebFetchToolContract.toolName { try preflightPinnedWebFetchRoute(frozen) }
                let pending = try await requestApproval(
                    callID: callID,
                    name: name,
                    input: frozen,
                    requiresSecondConfirmation: requiresSecondConfirmation
                )
                do {
                    if name == WebFetchToolContract.toolName { try await validatePinnedWebFetchDestination(frozen) }
                    if !["file_write", "file_edit", "file_delete"].contains(name) {
                        try await controller.recordApproval(capability: name, input: frozen)
                    }
                    try await controller.revalidate(capability: name, input: frozen)
                    try await persistAllowIfRequested(pending, name: name, input: frozen)
                } catch {
                    ApprovalAuthorityObservation.emit(
                        ApprovalAuthorityObservation.rejected(error, decision: pending.decision),
                        for: pending.request, using: pending.presentation
                    )
                    throw error
                }
                disposition = .approved(ComposerApprovalReceipt(
                    requestID: pending.request.requestID,
                    callID: pending.request.callID,
                    snapshot: controller.snapshot,
                    facts: controller.facts,
                    riskLevel: pending.request.riskLevel,
                    inputDigest: frozen.digest,
                    approvedAt: Date()
                ), pending)
            }
        }
        return ComposerExecutionAuthorization(
            callID: callID,
            capability: name,
            inputDigest: frozen.digest,
            identityDigest: controller.snapshot.callSnapshot(
                callID: callID,
                input: frozen
            ).identityDigest,
            leaseID: controller.facts.leaseID,
            disposition: disposition
        )
        } catch {
            await clearPreToolHook(callID: callID, name: name, input: frozen)
            throw error
        }
    }

    func execute(
        preauthorization: ComposerExecutionAuthorization,
        callID: String,
        name: String,
        input: [String: Any]
    ) async throws -> String {
        let frozen = try ComposerToolInput(input)
        if ["file_write", "file_edit", "file_delete"].contains(name),
           let path = frozen.stringValue(for: "path"),
           let receipt = ToolExecutionReceiptContext.current {
            return try await ToolFileMutationScope.withLock(path: URL(fileURLWithPath: path), receipt: receipt) {
                try await self.performAuthorized(preauthorization, callID: callID, name: name, input: frozen) { value in
                    try await self.base.execute(name: name, input: value.foundationDictionary)
                }
            }
        }
        return try await performAuthorized(
            preauthorization,
            callID: callID,
            name: name,
            input: frozen
        ) { frozenInput in
            try await base.execute(
                name: name,
                input: frozenInput.foundationDictionary
            )
        }
    }

    public func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        try await execute(
            callID: "direct",
            input: input,
            authorization: authorization,
            context: context,
            now: now
        )
    }

    public func execute(
        callID: String,
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        let frozen = try ComposerToolInput(input)
        return try await execute(
            callID: callID,
            input: frozen,
            authorization: authorization,
            context: context,
            now: now
        )
    }

    public func execute(
        callID: String,
        input: ComposerToolInput,
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        try await perform(callID: callID, name: SessionReadTool.toolName, input: input) { frozenInput in
            guard let aware = base as? any SessionReadCapabilityAwareToolExecutor else {
                throw CrossSessionReadAuthorizationError.capabilityRequired
            }
            return try await aware.executeSessionRead(
                input: frozenInput.foundationDictionary,
                authorization: authorization,
                context: context,
                now: now
            )
        }
    }

    func execute(
        preauthorization: ComposerExecutionAuthorization,
        callID: String,
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        let frozen = try ComposerToolInput(input)
        return try await performAuthorized(
            preauthorization,
            callID: callID,
            name: SessionReadTool.toolName,
            input: frozen
        ) { frozenInput in
            guard let aware = base as? any SessionReadCapabilityAwareToolExecutor else {
                throw CrossSessionReadAuthorizationError.capabilityRequired
            }
            return try await aware.executeSessionRead(
                input: frozenInput.foundationDictionary,
                authorization: authorization,
                context: context,
                now: now
            )
        }
    }

    /// Browser transfer preflight and its eventual effect retain this exact
    /// turn controller. Revalidation does not replace browser action approval.
    private func withBrowserTransferFileAccess<T>(
        name: String, operation: () async throws -> T
    ) async throws -> T {
        guard BrowserSideEffectPolicy.browserToolNames.contains(name.lowercased()) else {
            return try await operation()
        }
        let boundController = controller
        let fileAccess: BrowserTransferFileAccess = { capability, url in
            guard capability == "file_read" || capability == "file_write" else {
                throw ToolExecutorError.invalidParameter("browser transfer capability")
            }
            try await boundController.revalidate(capability: capability,
                input: ComposerToolInput(["path": url.path]))
        }
        return try await BrowserTransferFileAccessContext.$current.withValue(fileAccess) {
            try await operation()
        }
    }

    private func performAuthorized(
        _ preauthorization: ComposerExecutionAuthorization, callID: String, name: String,
        input: ComposerToolInput, action: (ComposerToolInput) async throws -> String
    ) async throws -> String {
        try await withBrowserTransferFileAccess(name: name) {
            try await performAuthorizedWithFileAccess(preauthorization, callID: callID,
                name: name, input: input, action: action)
        }
    }

    private func perform(
        callID: String, name: String, input: ComposerToolInput,
        action: (ComposerToolInput) async throws -> String
    ) async throws -> String {
        try await withBrowserTransferFileAccess(name: name) {
            try await performWithFileAccess(callID: callID, name: name, input: input, action: action)
        }
    }

    func requestApproval(
        callID: String, name: String, input: ComposerToolInput, requiresSecondConfirmation: Bool
    ) async throws -> ComposerPendingApproval {
        try await withBrowserTransferFileAccess(name: name) {
            try await requestApprovalWithFileAccess(callID: callID, name: name, input: input,
                requiresSecondConfirmation: requiresSecondConfirmation)
        }
    }

    private func performAuthorizedWithFileAccess(
        _ preauthorization: ComposerExecutionAuthorization,
        callID: String,
        name: String,
        input: ComposerToolInput,
        action: (ComposerToolInput) async throws -> String
    ) async throws -> String {
        let identityDigest = controller.snapshot.callSnapshot(
            callID: callID,
            input: input
        ).identityDigest
        try await controller.revalidate(capability: name, input: input)
        try await preauthorization.reviewFileBeforeConsumption(input: input,
            snapshot: controller.snapshot, facts: controller.facts)
        guard let disposition = await preauthorization.consume(
            callID: callID,
            capability: name,
            inputDigest: input.digest,
            identityDigest: identityDigest,
            leaseID: controller.facts.leaseID
        ) else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        do {
            try await controller.revalidate(capability: name, input: input)
        } catch {
            if case .approved(_, let pending) = disposition {
                ApprovalAuthorityObservation.emit(
                    ApprovalAuthorityObservation.rejected(error, decision: pending.decision),
                    for: pending.request, using: pending.presentation
                )
            }
            throw error
        }
        switch disposition {
        case .revoked:
            throw ComposerAuthorizationError.authorizationBindingMismatch
        case .dryRun:
            return #"{"status":"dry-run","capability":"\#(name)"}"#
        case .execute:
            return try await runAction(callID: callID, name: name, input: input, action: action)
        case .approvedSettings(let receipt, let approvedCall, let facts):
            try Task.checkCancellation()
            onApprovalReceipt?(receipt)
            return try await BL6SettingsToolApproval.$current.withValue(approvedCall) {
                try await BL6SettingsToolApproval.$currentAuthorizationFacts.withValue(facts) {
                    try await runAction(callID: callID, name: name, input: input, action: action)
                }
            }
        case .approvedByRule(let receipt):
            return try await runAction(
                callID: callID, name: name, input: input, ruleReceipt: receipt, action: action)
        case .approvedCatalogRead(let receipt):
            try Task.checkCancellation()
            onApprovalReceipt?(receipt)
            let read = BL6SettingsCatalogReadContext(approval: receipt)
            return try await BL6SettingsToolApproval.$currentCatalogRead.withValue(read) {
                try await runAction(callID: callID, name: name, input: input, action: action)
            }
        case .approved(let receipt, let pending):
            if name == BL6SettingsToolApproval.catalogToolName {
                let read = BL6SettingsCatalogReadContext(approval: receipt)
                return try await BL6SettingsToolApproval.$currentCatalogRead.withValue(read) {
                    try await runAction(
                        callID: callID, name: name, input: input,
                        approved: (receipt, pending), action: action
                    )
                }
            }
            return try await runAction(
                callID: callID,
                name: name,
                input: input,
                approved: (receipt, pending),
                action: action
            )
        }
    }

    private func performWithFileAccess(
        callID: String,
        name: String,
        input: ComposerToolInput,
        action: (ComposerToolInput) async throws -> String
    ) async throws -> String {
        let policyInput = input
        do {
        // Both settings tools need AgentLoop's preauthorization and durable
        // attempt identity. A direct Composer entry cannot mint either.
        guard name != BL6SettingsToolApproval.toolName,
              name != BL6SettingsToolApproval.catalogToolName,
              !SkillMaintenanceTool.names.contains(name) else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        let resolved = try await authorizationDecision(callID: callID, capability: name, input: policyInput)
        switch resolved.decision {
        case .dryRun:
            return #"{"status":"dry-run","capability":"\#(name)"}"#
        case .execute:
            try await controller.revalidate(capability: name, input: policyInput)
            let hitReceipt = resolved.rule.map {
                ruleReceipt(callID: callID, name: name, input: policyInput, rule: $0)
            }
            return try await runAction(
                callID: callID, name: name, input: policyInput, ruleReceipt: hitReceipt, action: action)
        case .requestApproval(let requiresSecondConfirmation):
            if name == WebFetchToolContract.toolName { try preflightPinnedWebFetchRoute(policyInput) }
            let pending = try await requestApproval(
                callID: callID,
                name: name,
                input: policyInput,
                requiresSecondConfirmation: requiresSecondConfirmation
            )
            do {
                if name == WebFetchToolContract.toolName { try await validatePinnedWebFetchDestination(policyInput) }
                if !["file_write", "file_edit", "file_delete"].contains(name) {
                    try await controller.recordApproval(capability: name, input: policyInput)
                }
                try await controller.revalidate(capability: name, input: policyInput)
                try await persistAllowIfRequested(pending, name: name, input: policyInput)
            } catch {
                ApprovalAuthorityObservation.emit(
                    ApprovalAuthorityObservation.rejected(error, decision: pending.decision),
                    for: pending.request, using: pending.presentation
                )
                throw error
            }
            let receipt = ComposerApprovalReceipt(
                requestID: pending.request.requestID,
                callID: pending.request.callID,
                snapshot: controller.snapshot,
                facts: controller.facts,
                riskLevel: pending.request.riskLevel,
                inputDigest: policyInput.digest,
                approvedAt: Date()
            )
            return try await runAction(
                callID: callID,
                name: name,
                input: policyInput,
                approved: (receipt, pending),
                action: action
            )
        }
        } catch {
            await clearPreToolHook(callID: callID, name: name, input: policyInput)
            throw error
        }
    }

    /// Goal18 Hooks: PostToolUse wraps the single effect boundary. It observes a
    /// successful result and can only append model-visible context to it.
    private func runAction(
        callID: String, name: String, input: ComposerToolInput,
        approved: (ComposerApprovalReceipt, ComposerPendingApproval)? = nil,
        ruleReceipt: ComposerApprovalReceipt? = nil,
        action: (ComposerToolInput) async throws -> String
    ) async throws -> String {
        let output: String
        do {
            output = try await runActionCore(callID: callID, name: name, input: input,
                approved: approved, ruleReceipt: ruleReceipt, action: action)
        } catch {
            await clearPreToolHook(callID: callID, name: name, input: input)
            throw error
        }
        await clearPreToolHook(callID: callID, name: name, input: input)
        guard let handler = postToolHandler ?? HookRuntime.installed?.postToolHandler else { return output }
        let invocation = ComposerPostToolInvocation(callID: callID, capability: name, input: input,
            output: output, sessionID: controller.snapshot.sessionID)
        guard let context = await handler(invocation), !context.isEmpty else { return output }
        return HookOutputAnnotation.annotate(output: output, context: context, toolName: name)
    }

    private func runActionCore(
        callID: String,
        name: String,
        input: ComposerToolInput,
        approved: (ComposerApprovalReceipt, ComposerPendingApproval)? = nil,
        ruleReceipt: ComposerApprovalReceipt? = nil,
        action: (ComposerToolInput) async throws -> String
    ) async throws -> String {
        // 绕过模式「全面放开」：只有已确认的绕过快照才会在效果边界打开
        // BypassOpenScope，下游执行器据此放开项目根与终端策略（系统底线仍在）。
        let openBypass = controller.snapshot.mode == .bypassPermission
            && controller.snapshot.bypassModeConfirmed
        func scopedAction(_ value: ComposerToolInput) async throws -> String {
            if approved == nil, approvalGate?.liftedUnattendedFileApproval(for: name) == true {
                guard let check = AgentExecutionContext.current?.parentAuthorityCheck,
                      await check() else { throw ComposerAuthorizationError.authorizationRevoked }
                try await controller.revalidate(capability: name, input: value)
                try Task.checkCancellation()
            }
            if name == WebFetchToolContract.toolName,
               let permit = try await makePinnedWebFetchPermit(callID: callID, input: value,
                   approved: approved, ruleReceipt: ruleReceipt) {
                do {
                    let output = try await WebFetchPinnedCallContext.$current.withValue(permit) {
                        try await action(value)
                    }
                    await permit.close()
                    return output
                } catch { await permit.close(); throw error }
            }
            if openBypass {
                return try await BypassOpenScope.$isActive.withValue(true) {
                    try await withIndependentFileEffect(kind: .confirmedBypass, callID: callID,
                        name: name, input: value) {
                        if name == "shell_execute", let (receipt, _) = approved {
                            return try await ApprovedShellCallScope.$currentComposerReceipt.withValue(receipt) {
                                try await action(value)
                            }
                        }
                        return try await action(value)
                    }
                }
            }
            if name == "shell_execute", let (receipt, _) = approved {
                return try await ApprovedShellCallScope.$currentComposerReceipt.withValue(receipt) {
                    try await action(value)
                }
            }
            if ApprovedFileReadScope.isRead(name), let (_, pending) = approved {
                guard let raw = value.stringValue(for: "path"),
                      PolicyRuntimePathBoundary.canonicalPath(raw) == pending.approvedReadPath else {
                    throw ComposerAuthorizationError.authorizationBindingMismatch
                }
            }
            if ApprovedFileReadScope.isRead(name), let (receipt, pending) = approved,
               let raw = value.stringValue(for: "path"),
               let path = PolicyRuntimePathBoundary.canonicalPath(raw),
               pending.decision.approved, pending.decision.status == .approved,
               pending.request.callID == callID, receipt.callID == callID,
               receipt.inputDigest == value.digest,
               path == pending.approvedReadPath,
               pending.decision.requestID == pending.request.requestID,
               pending.decision.bindingDigest == pending.request.identityDigest {
                let scope = ApprovedFileReadScope(tool: name, path: path, receipt: receipt)
                return try await ApprovedFileReadScope.$current.withValue(scope) {
                    try await withIndependentFileEffect(kind: .freshRead, callID: callID,
                        name: name, input: value) { try await action(value) }
                }
            }
            return try await action(value)
        }
        var authorityRecorded = false
        do {
            // Both direct execution and AgentLoop preauthorization reach this
            // single effect boundary. Invoke a registered handler once for the
            // frozen call, then merge its result with live policy/stop/timeout.
            try await controller.revalidate(capability: name, input: input)
            let result = try await preToolHook(callID: callID, name: name, input: input)
            let hookReason = result?.reason
            var verdict = result?.verdict ?? .allow
            if verdict == .ask, openBypass || approved != nil || BL6SettingsToolApproval.current != nil
                || BL6SettingsToolApproval.currentCatalogRead != nil { verdict = .allow }
            let digest = result?.invocationIdentityDigest
            let hook = digest.map { HookLayerSignal(verdict: verdict, handlerInvocationID: $0, handlerResultID: $0) }
                ?? .noHandler
            try await enforceMergedDecision(name: name, input: input, hook: hook, hookReason: hookReason)

            if let ruleReceipt {
                // Rule hit: no prompt, but the same revalidate -> merged
                // decision -> receipt order as an approved call.
                try await controller.revalidate(capability: name, input: input)
                try Task.checkCancellation()
                onApprovalReceipt?(ruleReceipt)
                try await enforceMergedDecision(name: name, input: input, hook: hook, hookReason: hookReason)
                try Task.checkCancellation()
            }
            if let (receipt, pending) = approved {
                if BrowserSideEffectPolicy.inputRequiresApproval(tool: name, input: input.foundationDictionary) {
                    try await pending.gate.acceptApprovedDecision(
                        pending.decision,
                        for: pending.request,
                        receiptExpiresAt: controller.facts.expiresAt
                    )
                }
                try await controller.revalidate(capability: name, input: input)
                try await enforceMergedDecision(name: name, input: input, hook: hook, hookReason: hookReason)
                try Task.checkCancellation()
                onApprovalReceipt?(receipt)
                // The approval callback may synchronously revoke authorization.
                // Keep the same hook result; never invoke its handler twice.
                try await enforceMergedDecision(name: name, input: input, hook: hook, hookReason: hookReason)
                try Task.checkCancellation()
                ApprovalAuthorityObservation.emit(
                    .authorityApproved, for: pending.request, using: pending.presentation
                )
                authorityRecorded = true
            }
            try Task.checkCancellation()
            if SkillMaintenanceTool.names.contains(name) {
                let receipt: ComposerApprovalReceipt
                let request: ApprovalRequest
                if let (freshReceipt, pending) = approved {
                    guard pending.decision.approved, pending.decision.confirmed,
                          pending.request.skillDiff != nil else {
                        throw ComposerAuthorizationError.approvalRequired(name)
                    }
                    receipt = freshReceipt
                    request = pending.request
                } else if openBypass, ruleReceipt == nil, let skillMaintenance {
                    let review = try skillMaintenance.prepare(name: name, input: input)
                    try await controller.revalidateSkillBypass(capability: name, input: input)
                    let snapshot = controller.snapshot
                    let identity = snapshot.callSnapshot(callID: callID, input: input).identityDigest
                    let bypassReceipt = ComposerApprovalReceipt(
                        requestID: callID, callID: callID, snapshot: snapshot,
                        facts: controller.facts, riskLevel: .high,
                        inputDigest: input.digest, approvedAt: Date()
                    )
                    var automaticRequest = ApprovalRequest(
                        id: callID, callID: callID, toolName: name,
                        inputSummary: "已确认绕过权限，使用当前技能预览执行",
                        riskLevel: .high, requiresApproval: false, composerMode: snapshot.mode.rawValue,
                        inputDigest: input.digest, identityDigest: identity
                    )
                    automaticRequest.skillDiff = review.diff
                    automaticRequest.skillDeletionIntent = review.deletionIntent
                    onApprovalReceipt?(bypassReceipt)
                    receipt = bypassReceipt
                    request = automaticRequest
                } else if let automatic = ruleReceipt, let skillMaintenance {
                    try await controller.revalidateSkillRule(automatic, capability: name, input: input)
                    let review = try skillMaintenance.prepare(name: name, input: input)
                    var automaticRequest = ApprovalRequest(id: callID, requestID: automatic.requestID,
                        callID: callID, toolName: name, inputSummary: "已按你的放行自动修改技能",
                        riskLevel: automatic.riskLevel, requiresApproval: false,
                        inputDigest: input.digest, identityDigest: automatic.identityDigest)
                    automaticRequest.skillDiff = review.diff
                    automaticRequest.skillDeletionIntent = review.deletionIntent
                    receipt = automatic
                    request = automaticRequest
                } else {
                    throw ComposerAuthorizationError.approvalRequired(name)
                }
                return try await SkillMaintenanceApprovalContext.$request.withValue(request) {
                    try await SkillMaintenanceApprovalContext.$receipt.withValue(receipt) {
                        try await SkillMaintenanceApprovalContext.$revalidateRule.withValue({ [controller] in
                            if receipt.persistentRuleID != nil {
                                try await controller.revalidateSkillRule(receipt, capability: name, input: input)
                            } else {
                                try await controller.revalidateSkillBypass(capability: name, input: input)
                            }
                        }) {
                            try await SkillMaintenanceApprovalContext.$usesConfirmedBypass.withValue(
                                openBypass && approved == nil && ruleReceipt == nil
                            ) {
                                try await scopedAction(input)
                            }
                        }
                    }
                }
            }
            let filePreview = approved?.1.request.filePreview
            try filePreview?.validateCurrent()
            return try await ApprovalFilePreviewContext.$current.withValue(filePreview) {
            if BrowserSideEffectPolicy.inputRequiresApproval(tool: name, input: input.foundationDictionary) {
                let identity = BrowserSideEffectExecutionIdentity(
                    callID: callID, inputDigest: input.digest
                )
                let bypassOrigin = try await controller.browserBypassOrigin(
                    callID: callID, capability: name, input: input
                )
                return try await BrowserSideEffectCallContext.$current.withValue(identity) {
                    if let bypassOrigin {
                        return try await BrowserBypassPermissionCallContext.$current.withValue(bypassOrigin) {
                            try await scopedAction(input)
                        }
                    }
                    return try await scopedAction(input)
                }
            }
            let result = try await scopedAction(input)
            // A cancelled/denied/stale approval must never leave a reusable
            // file grant. Publish scoped consent only after a real success.
            // A later revocation only prevents grant insertion; it must not
            // turn a completed file mutation into a reported failure.
            if let (_, pending) = approved, !pending.request.isHookAsk,
               ["file_write", "file_edit", "file_delete"].contains(name) {
                try? await controller.recordApproval(
                    capability: name, input: input,
                    allowInSession: pending.request.sessionScopeEligible && pending.decision.allowInSession
                )
            }
            return result
            }
        } catch {
            if !authorityRecorded, let (_, pending) = approved {
                ApprovalAuthorityObservation.emit(
                    ApprovalAuthorityObservation.rejected(error, decision: pending.decision),
                    for: pending.request, using: pending.presentation
                )
            }
            throw error
        }
    }

    private func enforceMergedDecision(
        name: String,
        input: ComposerToolInput,
        hook: HookLayerSignal,
        hookReason: String? = nil
    ) async throws {
        try await controller.revalidate(capability: name, input: input)
        let context = AgentExecutionContext.current
        let parentStopped = await context?.parentTurnHandle?.isCancelled() ?? false
        try await controller.revalidate(capability: name, input: input)
        let decision = HookDecisionReducer.decide(HookDecisionInput(
            policy: PolicyLayerSignal(verdict: .allow),
            approval: ApprovalLayerSignal(verdict: .allow),
            stop: StopLayerSignal(continueRequested: !Task.isCancelled && !parentStopped),
            timeout: TimeoutLayerSignal(expired: context?.deadline.map { Date() >= $0 } ?? false),
            hook: hook
        ))
        switch decision.outcome {
        case .allow:
            return
        case .ask:
            throw ComposerAuthorizationError.approvalRequired(name)
        case .deny:
            switch decision.reason {
            case .stopContinueFalse:
                throw InterruptedError()
            case .timeoutExpired:
                throw ToolExecutorError.toolTimeout(name)
            default:
                if decision.reason == .hookDeny, let hookReason, !hookReason.isEmpty {
                    throw ComposerAuthorizationError.hookRejected(hookReason)
                }
                throw ComposerAuthorizationError.hookDecisionDenied(decision.reason)
            }
        }
    }

    private func approveSettingsCall(
        callID: String,
        input: ComposerToolInput,
        requiresSecondConfirmation: Bool,
        reusingScopedConsent: Bool = false
    ) async throws -> (receipt: ComposerApprovalReceipt, call: BL6SettingsApprovedCallContext,
                       facts: ApprovalAuthorizationContext) {
        let name = BL6SettingsToolApproval.toolName
        let gate = try requireSettingsGate(name)
        let context = try settingsApprovalContext(callID: callID, input: input)
        let call: BL6SettingsApprovedCallContext
        if reusingScopedConsent {
            // authorize() already checked live scope and authority. Rebind
            // consent to this call; never carry an earlier effect context.
            call = BL6SettingsApprovedCallContext(requestID: context.effectID, binding: context)
        } else {
            call = try await gate.approveBL6SettingsCall(
                input: input.foundationDictionary,
                context: context,
                requiresSecondConfirmation: requiresSecondConfirmation
            )
        }
        try await controller.revalidate(capability: name, input: input)
        let receipt = ComposerApprovalReceipt(
            requestID: context.effectID,
            callID: callID,
            snapshot: controller.snapshot,
            facts: controller.facts,
            riskLevel: gate.riskLevel(for: name),
            inputDigest: input.digest,
            approvedAt: Date()
        )
        return (receipt, call, context)
    }

    private func requireSettingsGate(_ name: String) throws -> ApprovalGate {
        guard let gate = approvalGate, gate.policy(for: name) == .alwaysAsk,
              gate.delegate != nil else {
            throw ComposerAuthorizationError.approvalRequired(name)
        }
        return gate
    }

    private func settingsApprovalContext(
        callID: String,
        input: ComposerToolInput
    ) throws -> ApprovalAuthorizationContext {
        let snapshot = controller.snapshot
        let facts = controller.facts
        func present(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard present(callID), callID != "direct",
              present(snapshot.workspaceID), present(snapshot.sessionID),
              present(snapshot.taskID), present(snapshot.attemptID),
              present(snapshot.messageID), present(snapshot.policyRevision),
              present(snapshot.grantEpoch),
              let payloadDigest = ApprovalAuthorizationContext.payloadDigest(
                for: input.foundationDictionary
              ) else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        let context = ApprovalAuthorizationContext(
            actorID: "composer:\(snapshot.workspaceID)",
            sessionID: snapshot.sessionID,
            turnID: snapshot.turnID,
            taskID: snapshot.taskID,
            runID: snapshot.messageID,
            attemptID: snapshot.attemptID,
            effectID: callID,
            scope: snapshot.approvalScope.rawValue,
            payloadDigest: payloadDigest,
            expiresAt: facts.expiresAt,
            policyRevision: snapshot.policyRevision,
            grantEpoch: snapshot.grantEpoch,
            toolName: BL6SettingsToolApproval.toolName
        )
        guard context.isValid else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        return context
    }

    private func fileApprovalPreview(tool: String, input: ComposerToolInput, ownerID: ObjectIdentifier) async throws -> ApprovalFilePreview {
        try await controller.revalidate(capability: tool, input: input)
        guard let owner = (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner,
              ObjectIdentifier(owner) == ownerID else {
            throw ApprovalFileChangedError()
        }
        let preview = try await owner.prepareFileApprovalPreview(tool: tool, input: input)
        try Task.checkCancellation()
        try await controller.revalidate(capability: tool, input: input)
        guard let owner = (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner,
              ObjectIdentifier(owner) == ownerID else { throw ApprovalFileChangedError() }
        return preview
    }

    private func requestApprovalWithFileAccess(
        callID: String,
        name: String,
        input: ComposerToolInput,
        requiresSecondConfirmation: Bool
    ) async throws -> ComposerPendingApproval {
        guard var gate = approvalGate, let delegate = gate.delegate else {
            throw ComposerAuthorizationError.approvalRequired(name)
        }
        if gate.policy(for: name) == .deny || gate.policy(for: name) == .never {
            throw ComposerAuthorizationError.approvalDenied("Capability is blocked by approval policy")
        }
        if !gate.isKnownTool(name) {
            gate.policyByTool[name] = .alwaysAsk
        }

        let baseRequest = gate.makeRequest(
            id: callID,
            tool: name,
            input: input.foundationDictionary
        )
        let fileOwnerID: ObjectIdentifier?
        if ["file_write", "file_edit", "file_delete"].contains(name), let owner = (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner {
            fileOwnerID = ObjectIdentifier(owner)
        } else { fileOwnerID = nil }
        let refreshFilePreview: (() async throws -> ApprovalFilePreview)? = fileOwnerID.map { ownerID in
            { try await self.fileApprovalPreview(tool: name, input: input, ownerID: ownerID) }
        }
        let filePreview = try await refreshFilePreview?() ?? baseRequest.filePreview
        let gitSummary: String?
        if name == "shell_execute", let prepare = GitWriteApprovalSummaryContext.current {
            try await controller.revalidate(capability: name, input: input)
            gitSummary = try await prepare(input, gate.terminalPolicySnapshot)
            try await controller.revalidate(capability: name, input: input)
        } else { gitSummary = nil }
        // The send card is built from the located session; any failure
        // (not found, secret-shaped text, card over 4 KiB) refuses the call.
        let externalSendSummary: String?
        if name == ExternalSessionToolNames.send {
            guard let owner = (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner else {
                throw ToolExecutorError.toolNotConfigured(name)
            }
            try await controller.revalidate(capability: name, input: input)
            externalSendSummary = try await owner.externalSessionApprovalSummary(input: input.foundationDictionary)
            try await controller.revalidate(capability: name, input: input)
        } else { externalSendSummary = nil }
        let snapshot = controller.snapshot
        var request = ApprovalRequest(
            id: baseRequest.id,
            requestID: baseRequest.requestID,
            callID: callID,
            toolName: baseRequest.toolName,
            inputSummary: externalSendSummary
                ?? baseRequest.inputSummary + (gitSummary.map { "\n\n" + $0 } ?? ""),
            riskLevel: baseRequest.riskLevel,
            requiresApproval: true,
            inputRiskLevel: baseRequest.inputRiskLevel,
            requiresSecondConfirmation: requiresSecondConfirmation
                || baseRequest.requiresSecondConfirmation,
            sessionID: snapshot.sessionID,
            turnID: snapshot.turnID,
            taskID: snapshot.taskID,
            attemptID: snapshot.attemptID,
            approvalScope: snapshot.approvalScope.rawValue,
            composerMode: snapshot.mode.rawValue,
            messageID: snapshot.messageID,
            policyRevision: snapshot.policyRevision,
            grantEpoch: snapshot.grantEpoch,
            inputDigest: input.digest,
            identityDigest: ComposerDigest.sha256(ComposerCallIdentity(
                sessionID: snapshot.sessionID,
                turnID: snapshot.turnID,
                taskID: snapshot.taskID,
                attemptID: snapshot.attemptID,
                messageID: snapshot.messageID,
                callID: callID,
                workspaceID: snapshot.workspaceID,
                policyRevision: snapshot.policyRevision,
                grantEpoch: snapshot.grantEpoch,
                inputDigest: input.digest
            )),
            filePreview: filePreview
        )
        if SkillMaintenanceTool.names.contains(name) {
            guard let skillMaintenance else { throw ToolExecutorError.toolNotConfigured(name) }
            let review = try skillMaintenance.prepare(name: name, input: input)
            request.skillDiff = review.diff
            request.skillDeletionIntent = review.deletionIntent
        }
        request.terminalPolicyDisposition = controller.hasConfirmedBypass && name == "shell_execute"
            ? .confirmation : baseRequest.terminalPolicyDisposition
        request.browserNavigationDestination = baseRequest.browserNavigationDestination
        request.browserInteractionInput = baseRequest.browserInteractionInput
        request.webFetchAuthority = baseRequest.webFetchAuthority
        request.displayTargetPath = baseRequest.displayTargetPath
        if name == WebFetchToolContract.toolName,
           let raw = input.stringValue(for: "url"), let url = URL(string: raw) {
            request.webFetchAuthority = try WebFetchApprovalDisplay.authority(for: url)
        }
        if !controller.hasConfirmedBypass,
           let hook = try await preToolHook(callID: callID, name: name, input: input),
           hook.hasDecision, hook.verdict == .ask {
            request.isHookAsk = true
            request.hookAskReason = hook.reason
        }
        let outsideRead = try await controller.requiresOutsideReadApproval(capability: name, input: input)
        let protectedGitWrite = await controller.requiresProtectedGitWriteApproval(capability: name, input: input)
        request.sessionScopeEligible = try await controller.scopedGrantEligible(capability: name, input: input)
            && !request.isHookAsk && !mcpRequiresUserInteraction(name) && filePreview?.isSensitive != true
        if !controller.hasConfirmedBypass && !request.isHookAsk && !mcpRequiresUserInteraction(name) && !outsideRead && !protectedGitWrite
            && !requiresFreshShellApproval(capability: name, input: input) {
            request.persistentAllowOffer = await controller.persistentAllowOffer(capability: name, input: input)
        }
        let originalRequestID = request.requestID
        let readPath = ApprovedFileReadScope.isRead(name)
            ? input.stringValue(for: "path").flatMap(PolicyRuntimePathBoundary.canonicalPath) : nil
        var approval = await delegate.requestApproval(request)
        do {
            (request, approval) = try await gate.reviewChangedFile(
                request: request, decision: approval, input: input.foundationDictionary, delegate: delegate,
                refreshPreview: refreshFilePreview)
            try Task.checkCancellation()
            try request.filePreview?.validateCurrent()
            guard approval.approved else {
                throw ComposerAuthorizationError.approvalDenied(approval.reason)
            }
            // Every Composer approval belongs to this exact model call. A stale
            // delegate answer must not approve a different shell/file/settings
            // effect just because its Boolean is true.
            guard approval.status == .approved,
                  approval.requestID == request.requestID,
                  approval.bindingDigest == request.identityDigest else {
                throw ComposerAuthorizationError.authorizationBindingMismatch
            }
            guard !request.requiresSecondConfirmation || approval.confirmed else {
                throw ComposerAuthorizationError.bypassConfirmationRequired
            }
            let presentation = ApprovalPresentationContext.current.flatMap { context in
                context.makeFact(for: request, stage: .authorityApproved) == nil ? nil : context
            }
            return ComposerPendingApproval(
                gate: gate, request: request, decision: approval,
                presentation: presentation,
                fileReviewWasUsed: request.requestID != originalRequestID,
                approvedReadPath: readPath
            )
        } catch {
            ApprovalAuthorityObservation.emit(
                ApprovalAuthorityObservation.rejected(error, decision: approval), for: request
            )
            throw error
        }
    }
}

/// Only the original Composer producer in this file can construct a call
/// permit. It cannot be decoded, persisted, supplied by the model or retained
/// as a project grant. Redirect approval remains inside the same producer.
final class WebFetchPinnedCallPermit: Sendable {
    enum Source: Sendable {
        case configuredCeiling
        case confirmedBypass
        case rememberedProjectRule(String)
        case humanReceipt(ComposerApprovalReceipt)
    }
    let binding: WebFetchCallBinding
    let source: Source
    private let uses = WebFetchPinnedPermitUses()
    private let loadOperation: @Sendable (URL) async throws -> WebFetchHop

    fileprivate init(binding: WebFetchCallBinding, source: Source,
        load: @escaping @Sendable (URL) async throws -> WebFetchHop) {
        self.binding = binding
        self.source = source
        self.loadOperation = load
    }

    func validatePolicyInput(_ input: [String: Any]) throws {
        let frozen = try ComposerToolInput(input)
        guard frozen.digest == binding.call.inputDigest, !binding.facts.revoked,
              binding.facts.expiresAt > Date() else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        if let receipt = ToolExecutionReceiptContext.current {
            guard receipt.toolName == WebFetchToolContract.toolName,
                  receipt.toolCallID == binding.call.callID else {
                throw ComposerAuthorizationError.authorizationBindingMismatch
            }
        }
    }

    func load(_ url: URL) async throws -> WebFetchHop {
        try await uses.claim(url)
        return try await loadOperation(url)
    }
    func close() async { await uses.close() }
}

private actor WebFetchPinnedPermitUses {
    private var closed = false
    private var urls = Set<URL>()
    func claim(_ url: URL) throws {
        guard !closed, urls.insert(url).inserted else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
    }
    func close() { closed = true }
}

enum WebFetchPinnedCallContext {
    @TaskLocal static var current: WebFetchPinnedCallPermit?
}

/// Bound to the exact redirect input as well as its original parent call.
/// The enclosing call permit's one-use URL ledger consumes this authorization.
private struct WebFetchRedirectAuthorization: Sendable {
    let rootCallID: String
    let binding: WebFetchCallBinding
    let source: WebFetchPinnedCallPermit.Source
}
