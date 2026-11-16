import Foundation

/// Exact frozen call identity for a transient web-fetch permission. Neither this
/// value nor its eventual permit is Codable or accepted from tool arguments.
struct WebFetchCallBinding: Equatable, Sendable {
    let call: ComposerCallSnapshot
    let facts: ComposerPolicyFactSource
    let endpoint: WebFetchEndpoint

    init(snapshot: ComposerSubmissionSnapshot, facts: ComposerPolicyFactSource,
         callID: String, input: ComposerToolInput, now: Date = Date()) throws {
        guard !callID.isEmpty, snapshot.hasRequiredPolicyIdentity,
              snapshot.workspaceID == facts.workspaceID,
              snapshot.policyRevision == facts.revision,
              snapshot.grantEpoch == facts.grantEpoch,
              !facts.leaseID.isEmpty, !facts.revoked, facts.expiresAt > now,
              case .string(let raw) = input.values["url"], let url = URL(string: raw) else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        call = snapshot.callSnapshot(callID: callID, input: input)
        self.facts = facts
        endpoint = try WebFetchEndpoint(url)
    }

    func validate(snapshot: ComposerSubmissionSnapshot, facts current: ComposerPolicyFactSource,
                  callID: String, input: ComposerToolInput, now: Date = Date()) throws {
        let currentBinding = try WebFetchCallBinding(snapshot: snapshot, facts: current,
            callID: callID, input: input, now: now)
        guard currentBinding == self else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
    }

    /// This comparison is necessary, but not itself human authorization. The
    /// producer must obtain this receipt from its consumed original controller
    /// preauthorization; callers cannot submit a decoded receipt as a permit.
    func matchesFreshHumanReceipt(_ receipt: ComposerApprovalReceipt) -> Bool {
        receipt.persistentRuleID == nil && !receipt.requestID.isEmpty
            && receipt.callID == call.callID && receipt.sessionID == call.sessionID
            && receipt.turnID == call.turnID && receipt.taskID == call.taskID
            && receipt.attemptID == call.attemptID && receipt.messageID == call.messageID
            && receipt.inputDigest == call.inputDigest && receipt.identityDigest == call.identityDigest
            && receipt.policyRevision == call.policyRevision && receipt.grantEpoch == call.grantEpoch
            && receipt.leaseID == facts.leaseID && receipt.leaseExpiresAt == facts.expiresAt
            && !receipt.leaseRevoked
    }
}
