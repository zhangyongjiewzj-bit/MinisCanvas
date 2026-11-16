import Foundation

/// Optional isolation plan. A plan is NOT a created worktree or an authorized root.
/// Consumer executes through ordinary shell approval, then authorizes `path` only
/// after success. Child completion revokes the root; removal needs a new approval.
public struct GitWorktreePlan: Equatable, Sendable {
    public let command: String
    public let workingDirectory: String
    public let path: String

    public enum PlanError: Error, Equatable { case invalidRepository, invalidDestination, invalidReference }

    public static func prepare(repositoryPath: String, destinationPath: String, branch: String, startPoint: String = "HEAD") throws -> GitWorktreePlan {
        try prepareTrustedChild(repositoryPath: repositoryPath, destinationPath: destinationPath,
                                branch: branch, startPoint: startPoint, stableVarSpelling: false)
    }

    /// Internal entry for the App-managed child worktree service. Only a
    /// qualified disposable root may request the stable /var destination
    /// spelling; every other caller keeps the original standardized path.
    static func prepareTrustedChild(repositoryPath: String, destinationPath: String, branch: String,
                                    startPoint: String, stableVarSpelling: Bool) throws -> GitWorktreePlan {
        guard repositoryPath.hasPrefix("/") else { throw PlanError.invalidRepository }
        guard destinationPath.hasPrefix("/"), destinationPath != repositoryPath,
              !destinationPath.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw PlanError.invalidDestination }
        guard isValidReference(branch), isValidReference(startPoint) else { throw PlanError.invalidReference }
        let repository = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        let standardizedDestination = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
        let destination = stableVarSpelling ? stableDarwinVarSpelling(standardizedDestination) : standardizedDestination
        guard destination != repository, destination != "/" else { throw PlanError.invalidDestination }
        return GitWorktreePlan(command: "git worktree add -b " + quote(branch) + " " + quote(destination) + " " + quote(startPoint), workingDirectory: repository, path: destination)
    }

    /// /private/var/<suffix> and /var/<suffix> name the same Darwin system
    /// directory. Returns the /var spelling Foundation reports once the path
    /// exists, independent of whether it exists now. No other prefix changes.
    static func stableDarwinVarSpelling(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    public static func isValidReference(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && !value.hasPrefix("/") && !value.hasSuffix("/") && !value.hasSuffix(".") && !value.contains("..") && !value.contains("@{") && !value.contains("//") && !value.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".lock") }) && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.").contains($0) }
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
