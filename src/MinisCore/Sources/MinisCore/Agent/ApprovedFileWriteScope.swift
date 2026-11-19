import Foundation

/// 只存在于一次"刚批准的项目外写入"的执行期间（对齐 Claude Code：授权根外的写/改先问，
/// 批准则本次可写）。回执与不可变输入摘要提供身份；它只放行这一个已批准的文件路径，
/// 不产生可复用的目录授权，也不放宽敏感路径、应用自身数据目录和系统底线（下游执行器照常拦截）。
struct ApprovedFileWriteScope: Sendable {
    @TaskLocal static var current: ApprovedFileWriteScope?
    /// 仅用于生成审批预览（只读）：预览这一个授权根外路径时放行根检查。
    @TaskLocal static var previewPath: String?
    let tool: String
    let path: String
    let receipt: ComposerApprovalReceipt

    static func isWrite(_ tool: String) -> Bool {
        tool == "file_write" || tool == "file_edit"
    }

    static func permits(tool: String, path: String) -> Bool {
        guard isWrite(tool), let scope = current, scope.tool == tool,
              !scope.receipt.leaseRevoked, scope.receipt.leaseExpiresAt > Date(),
              scope.receipt.persistentRuleID == nil,
              PolicyRuntimePathBoundary.canonicalPath(scope.path) == scope.path,
              let physical = PolicyRuntimePathBoundary.canonicalPath(path) else { return false }
        return physical == scope.path
    }

    /// 下游执行器的根检查用：当前写入作用域是否放行这个已规范化的路径。
    static func permits(path: String) -> Bool {
        if let preview = previewPath, let physical = PolicyRuntimePathBoundary.canonicalPath(path),
           physical == preview { return true }
        guard let scope = current else { return false }
        return permits(tool: scope.tool, path: path)
    }
}
