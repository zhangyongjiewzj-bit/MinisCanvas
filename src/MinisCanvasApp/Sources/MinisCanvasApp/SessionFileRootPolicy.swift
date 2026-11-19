import Foundation

/// A configured root is explicit user authority. An absent setting derives
/// from this session's project; it never means the user's entire home.
enum SessionFileRootPolicy {
    static func root(explicit: URL?, workingDirectory: String?, sessionDirectory: URL,
                     sessionID: UUID?, home: String = NSHomeDirectory()) -> URL {
        if let explicit { return explicit.standardizedFileURL }
        if let workingDirectory, workingDirectory.hasPrefix("/"),
           !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        }
        // A projectless chat does not inherit process cwd or home authority.
        // This is its private workspace identity, not a newly minted grant.
        return privateWorkspaceBase(sessionDirectory: sessionDirectory, home: home)
            .appendingPathComponent(sessionID?.uuidString ?? "unselected", isDirectory: true)
            .standardizedFileURL
    }

    /// 普通会话（不在项目里）的私有工作目录的上级。对齐 Claude Code：总有一个工作目录。
    /// 会话数据目录在 Application Support 内时，文件工具默认拒绝整个 Application Support，
    /// 目录放在那里等于不可用，所以改放用户主目录下的「MinisCanvas工作区」；
    /// 隔离测试配置等不在 Application Support 内的会话目录保持原位置（不污染真实主目录）。
    static func privateWorkspaceBase(sessionDirectory: URL, home: String = NSHomeDirectory()) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .standardizedFileURL.path
        let session = sessionDirectory.standardizedFileURL.path
        if let support, session == support || session.hasPrefix(support + "/") {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("MinisCanvas工作区", isDirectory: true)
        }
        return sessionDirectory.appendingPathComponent("workspaces", isDirectory: true)
    }
}
