import Foundation

/// Lives only around the effect of a freshly approved Composer call. The
/// existing receipt and immutable tool input supply identity; no reusable
/// directory grant is created, and no mutation consults this scope.
/// 例外：`file_read` 命中用户保存的"以后都允许读取此目录"规则时，同一回执（带规则 ID）
/// 同样只放行这一个文件；规则命中本身已在授权时、执行前各核对一次。
struct ApprovedFileReadScope: Sendable {
    @TaskLocal static var current: ApprovedFileReadScope?
    let tool: String
    let path: String
    let receipt: ComposerApprovalReceipt

    static func isRead(_ tool: String) -> Bool {
        ["file_read", "file_grep", "file_glob"].contains(tool)
    }

    static func permits(tool: String, path: String) -> Bool {
        guard isRead(tool), let scope = current, scope.tool == tool,
              !scope.receipt.leaseRevoked, scope.receipt.leaseExpiresAt > Date(),
              PolicyRuntimePathBoundary.canonicalPath(scope.path) == scope.path,
              let physical = PolicyRuntimePathBoundary.canonicalPath(path) else { return false }
        return physical == scope.path || (tool != "file_read" && physical.hasPrefix(scope.path + "/"))
    }

    static func additionalRoot(for tool: String, path: String) -> URL? {
        guard permits(tool: tool, path: path), let scope = current else { return nil }
        return URL(fileURLWithPath: scope.path)
    }
}
