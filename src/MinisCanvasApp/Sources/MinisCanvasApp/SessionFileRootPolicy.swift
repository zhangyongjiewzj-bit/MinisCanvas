import Foundation

/// A configured root is explicit user authority. An absent setting derives
/// from this session's project; it never means the user's entire home.
enum SessionFileRootPolicy {
    static func root(explicit: URL?, workingDirectory: String?, sessionDirectory: URL,
                     sessionID: UUID?) -> URL {
        if let explicit { return explicit.standardizedFileURL }
        if let workingDirectory, workingDirectory.hasPrefix("/"),
           !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        }
        // A projectless chat does not inherit process cwd or home authority.
        // This is its private workspace identity, not a newly minted grant.
        return sessionDirectory.appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(sessionID?.uuidString ?? "unselected", isDirectory: true)
            .standardizedFileURL
    }
}
