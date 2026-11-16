import Foundation

/// This tool is advertised only when its approved effect executor is installed.
public enum BL6SettingsToolApproval {
    public static let toolName = "conversation_settings"
    public static let catalogToolName = "settings_catalog"

    /// Only the Composer wrapper installs a gate-issued call in this scope.
    /// A model can supply tool arguments, but cannot construct a call context.
    @TaskLocal public static var current: BL6SettingsApprovedCallContext? = nil

    /// The exact gate-bound facts from the Composer wrapper. The model never
    /// supplies these; the effect owner compares them with its live state.
    @TaskLocal public static var currentAuthorizationFacts: ApprovalAuthorizationContext? = nil

    /// A separate, one-call read authority installed only after the ordinary
    /// Composer catalog-read approval. It never authorizes a mutation.
    @TaskLocal public static var currentCatalogRead: BL6SettingsCatalogReadContext? = nil
}

public actor BL6SettingsCatalogReadContext {
    private let approval: ComposerApprovalReceipt
    private var consumed = false

    internal init(approval: ComposerApprovalReceipt) {
        self.approval = approval
    }

    /// A bare executor call, a different tool receipt, or a repeated read
    /// cannot borrow the delegate's approval from another model call.
    public func consumeCurrent() throws -> ComposerApprovalReceipt {
        try Task.checkCancellation()
        guard !consumed,
              BL6SettingsToolApproval.currentCatalogRead === self,
              let receipt = ToolExecutionReceiptContext.current,
              receipt.toolName == BL6SettingsToolApproval.catalogToolName,
              let identity = receipt.executionIdentity,
              let key = receipt.compositeKey, key.isValid,
              receipt.toolCallID == approval.callID,
              receipt.attemptID == approval.attemptID,
              receipt.attemptNumber == identity.attempt,
              key.toolCallID == receipt.toolCallID,
              key.attemptID == receipt.attemptID,
              key.sessionID == approval.sessionID,
              key.turnID == approval.turnID,
              key.messageID == approval.messageID,
              identity.turn.sessionID == approval.sessionID,
              identity.turn.turnID == approval.turnID,
              identity.turn.messageID == approval.messageID,
              !approval.leaseRevoked,
              Date() < approval.leaseExpiresAt else {
            throw ApprovalError.bindingMismatch(requestID: approval.requestID)
        }
        consumed = true
        return approval
    }
}

/// Data returned only after the gate-issued call is consumed at an effect
/// boundary. A receipt string or this data's fields are not authorization.
public struct BL6SettingsAuthorizedCall: Sendable {
    public let requestID: String
    public let binding: ApprovalAuthorizationContext

    internal init(requestID: String, binding: ApprovalAuthorizationContext) {
        self.requestID = requestID
        self.binding = binding
    }
}

/// Process-local, one-call handoff from the existing bound ApprovalGate to the
/// settings owner. No public initializer, Codable representation or ambient
/// grant exists. The durable replay owner is a later D-SETD stage.
public actor BL6SettingsApprovedCallContext {
    private let requestID: String
    private let binding: ApprovalAuthorizationContext
    private var consumed = false

    internal init(requestID: String, binding: ApprovalAuthorizationContext) {
        self.requestID = requestID
        self.binding = binding
    }

    /// The effect owner supplies the exact trusted turn/fact binding with the
    /// canonical digest of the input it will execute. This comparison also
    /// rejects a swapped tool, profile, scope, policy revision or grant epoch.
    public func consume(
        expected: ApprovalAuthorizationContext
    ) throws -> BL6SettingsAuthorizedCall {
        try Task.checkCancellation()
        guard !consumed else {
            throw ApprovalError.alreadyConsumed(requestID: requestID)
        }
        guard binding.isValid,
              binding.toolName == BL6SettingsToolApproval.toolName,
              expected == binding else {
            throw ApprovalError.bindingMismatch(requestID: requestID)
        }
        guard Date() < binding.expiresAt else {
            throw ApprovalError.expired(requestID: requestID)
        }
        consumed = true
        return BL6SettingsAuthorizedCall(requestID: requestID, binding: binding)
    }
}
