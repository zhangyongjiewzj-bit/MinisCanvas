import Foundation

/// Lives only around the effect of a freshly approved Composer call. The
/// existing receipt and immutable tool input supply identity; no reusable
/// directory grant is created, and no mutation consults this scope.
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
              scope.receipt.persistentRuleID == nil,
              PolicyRuntimePathBoundary.canonicalPath(scope.path) == scope.path,
              let physical = PolicyRuntimePathBoundary.canonicalPath(path) else { return false }
        return physical == scope.path || (tool != "file_read" && physical.hasPrefix(scope.path + "/"))
    }

    static func additionalRoot(for tool: String, path: String) -> URL? {
        guard permits(tool: tool, path: path), let scope = current else { return nil }
        return URL(fileURLWithPath: scope.path)
    }
}
