import Foundation

/// Projections of existing approval receipts around one real shell effect.
/// The producer sets these only after the original approval chain completes.
enum ApprovedShellCallScope {
    @TaskLocal static var currentComposerReceipt: ComposerApprovalReceipt?
    @TaskLocal static var currentLegacyReceipt: ApprovalReceipt?

    static func permits(input: [String: Any]) -> Bool {
        guard let digest = try? ComposerToolInput(input).digest else { return false }
        if let receipt = currentComposerReceipt {
            return receipt.inputDigest == digest && receipt.persistentRuleID == nil
                && !receipt.leaseRevoked && receipt.leaseExpiresAt > Date()
        }
        guard let receipt = currentLegacyReceipt,
              let legacyDigest = ApprovalAuthorizationContext.payloadDigest(for: input),
              receipt.toolName == "shell_execute", receipt.status == .approved,
              receipt.inputDigest == legacyDigest else { return false }
        return receipt.expiresAt.map { $0 > Date() } ?? true
    }
}

/// Stores the receipt delivered by the existing ApprovalGate callback. This
/// does not manufacture a decision, receipt or reusable command grant.
final class ApprovedShellReceiptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ApprovalReceipt?
    func record(_ receipt: ApprovalReceipt) { lock.lock(); defer { lock.unlock() }; value = receipt }
    func load() -> ApprovalReceipt? { lock.lock(); defer { lock.unlock() }; return value }
}
