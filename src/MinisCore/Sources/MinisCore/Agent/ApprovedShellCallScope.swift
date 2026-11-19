import Foundation

/// Projections of existing approval receipts around one real shell effect.
/// The producer sets these only after the original approval chain completes.
enum ApprovedShellCallScope {
    @TaskLocal static var currentComposerReceipt: ComposerApprovalReceipt?
    @TaskLocal static var currentLegacyReceipt: ApprovalReceipt?
    /// 没有用户当场批准、靠规则或计划/自动档免问放行的 shell 调用：执行前由 `runShell`
    /// 再过一次效果检查器（防止检查之后路径被换成符号链接）。
    @TaskLocal static var effectRecheck: ShellEffectRecheck?

    /// 规则命中的回执同样可以放行"未登记"命令：规则本身就是用户的授权，
    /// 命令内容是否仍在规则范围内由 `recheckViolation` 在执行前复检。
    static func permits(input: [String: Any]) -> Bool {
        guard let digest = try? ComposerToolInput(input).digest else { return false }
        if let receipt = currentComposerReceipt {
            return receipt.inputDigest == digest
                && !receipt.leaseRevoked && receipt.leaseExpiresAt > Date()
        }
        guard let receipt = currentLegacyReceipt,
              let legacyDigest = ApprovalAuthorizationContext.payloadDigest(for: input),
              receipt.toolName == "shell_execute", receipt.status == .approved,
              receipt.inputDigest == legacyDigest else { return false }
        return receipt.expiresAt.map { $0 > Date() } ?? true
    }

    /// nil 表示通过或不需要复检；否则是不能执行的原因。`workingDirectory` 是真正用来执行的目录。
    static func recheckViolation(input: [String: Any], workingDirectory: String) -> String? {
        guard let recheck = effectRecheck else { return nil }
        var context = recheck.context
        context.baseDirectory = workingDirectory
        context.requireDefaultCWD = false
        return ShellEffectGuard.violation(input: input, context: context, mode: recheck.mode)
    }
}

/// 执行前复检所需的冻结信息：检查模式和授权根。
struct ShellEffectRecheck: Sendable {
    let mode: ShellEffectGuard.Mode
    let context: ShellEffectGuard.Context
}

/// Stores the receipt delivered by the existing ApprovalGate callback. This
/// does not manufacture a decision, receipt or reusable command grant.
final class ApprovedShellReceiptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ApprovalReceipt?
    func record(_ receipt: ApprovalReceipt) { lock.lock(); defer { lock.unlock() }; value = receipt }
    func load() -> ApprovalReceipt? { lock.lock(); defer { lock.unlock() }; return value }
}
