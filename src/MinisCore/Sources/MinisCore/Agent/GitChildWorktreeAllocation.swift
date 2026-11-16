import Foundation
import CryptoKit


/// Cross-module adapter implemented only by the App's existing runtime profile.
/// Consumers must capture that profile, never construct one from model/config
/// path input. This seam selects storage; it never grants a filesystem root.
public protocol GitChildWorktreeRuntimeProfile: Sendable {
    var worktreeProfileIsDisposable: Bool { get }
    var worktreeProfileIsBlocked: Bool { get }
    func validatedWorktreeProfileHome() throws -> URL
}

/// Trusted App storage selection, not a root grant. Public callers cannot inject
/// an arbitrary URL. Tests use internal synthetic facts without filesystem I/O.
public struct GitChildWorktreeRoot: Equatable, Sendable {
    fileprivate let path: String
    /// Set only by the qualified disposable factory below when its captured
    /// home is the Darwin /private/var temporary directory. Never derived from
    /// a path spelling at use sites; production and synthetic roots are false.
    let usesStableVarSpelling: Bool
    private init(path: String, usesStableVarSpelling: Bool) {
        self.path = path
        self.usesStableVarSpelling = usesStableVarSpelling
    }

    struct HomeFacts {
        let canonicalPath: String
        let isDirectory: Bool
    }

    public static func appManaged(profile: some GitChildWorktreeRuntimeProfile) throws -> GitChildWorktreeRoot {
        try appManaged(
            profile: profile,
            productionHome: FileManager.default.homeDirectoryForCurrentUser,
            privateRoots: BuiltinToolExecutor.defaultDeniedRoots(),
            inspect: { url in
                var directory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
                return HomeFacts(canonicalPath: url.resolvingSymlinksInPath().standardizedFileURL.path,
                                 isDirectory: exists && directory.boolValue)
            })
    }

    /// Synthetic facts seam is internal; it cannot be used by the App to inject
    /// model paths or bypass the live factory's filesystem verification.
    static func appManaged(
        profile: some GitChildWorktreeRuntimeProfile,
        productionHome: URL,
        privateRoots: [URL],
        inspect: (URL) throws -> HomeFacts
    ) throws -> GitChildWorktreeRoot {
        guard !profile.worktreeProfileIsBlocked else { throw GitChildWorktreeService.AllocationError.invalidManagedRoot }
        let home = try profile.validatedWorktreeProfileHome()
        let isDisposable = profile.worktreeProfileIsDisposable
        let usesVarAlias = isDisposable && (home.path.hasPrefix("/private/var/") || home.path.hasPrefix("/var/"))
        let path = usesVarAlias ? physicalVarPath(home.path) : home.path
        let standardized = home.standardizedFileURL.path
        guard home.isFileURL, home.path.hasPrefix("/"),
              path == (usesVarAlias ? physicalVarPath(standardized) : standardized),
              !home.path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw GitChildWorktreeService.AllocationError.invalidManagedRoot
        }
        let facts = try inspect(home)
        let canonical = usesVarAlias ? physicalVarPath(facts.canonicalPath) : facts.canonicalPath
        let productionPath = productionHome.standardizedFileURL.path
        let realHome = usesVarAlias ? physicalVarPath(productionPath) : productionPath
        let systemRoots = ["/", "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/dev"]
        let systemDirectory = path == "/" || systemRoots.dropFirst().contains { within(path, $0) }
        guard facts.isDirectory, canonical == path, !systemDirectory,
              !SensitiveFilePolicy.isSensitive(home),
              !home.pathComponents.contains(where: { $0.lowercased() == "application support" }),
              !privateRoots.contains(where: { denied in
                  let deniedPath = denied.standardizedFileURL.path
                  return within(path, usesVarAlias ? physicalVarPath(deniedPath) : deniedPath)
              }),
              !SensitiveFilePolicy.isCredentialPath(path, home: realHome, directoriesOnly: true),
              !SensitiveFilePolicy.isCredentialPath(path, home: path, directoriesOnly: true) else {
            throw GitChildWorktreeService.AllocationError.invalidManagedRoot
        }
        if isDisposable {
            guard !within(path, realHome) else { throw GitChildWorktreeService.AllocationError.invalidManagedRoot }
        } else {
            guard path == realHome else { throw GitChildWorktreeService.AllocationError.invalidManagedRoot }
        }
        let managedPath = usesVarAlias ? path + "/.minis-worktrees"
            : home.appendingPathComponent(".minis-worktrees", isDirectory: true).path
        return GitChildWorktreeRoot(path: managedPath, usesStableVarSpelling: usesVarAlias)
    }

    // Foundation can spell the same Darwin system directory as /var even
    // when the captured disposable profile uses its physical /private/var path.
    private static func physicalVarPath(_ path: String) -> String {
        path == "/var" || path.hasPrefix("/var/") ? "/private" + path : path
    }

    private static func within(_ path: String, _ root: String) -> Bool {
        let candidate = path.precomposedStringWithCanonicalMapping.lowercased()
        let parent = root.precomposedStringWithCanonicalMapping.lowercased()
        return candidate == parent || candidate.hasPrefix(parent + "/")
    }

    init(syntheticRoot: String) {
        self.path = syntheticRoot
        self.usesStableVarSpelling = false
    }
}

/// App-only identity. These values come from the validated parent execution,
/// never from the model's isolation payload. This value grants no filesystem access.
public struct GitChildWorktreeIdentity: Equatable, Sendable {
    public let taskID: String
    public let executionID: UUID
    public let parentSessionID: String
    public let parentContextSnapshotID: String

    public init(taskID: String, executionID: UUID, parentSessionID: String, parentContextSnapshotID: String) {
        self.taskID = taskID
        self.executionID = executionID
        self.parentSessionID = parentSessionID
        self.parentContextSnapshotID = parentContextSnapshotID
    }
}

/// A verified checkout, not an authorization token. The consumer must bind this
/// identity to its current parent authority/Goal/lease and obtain the existing
/// session-root approval before constructing the child's scope and ceiling.
public struct GitChildWorktreeAllocation: Equatable, Sendable {
    public let identity: GitChildWorktreeIdentity
    public let repositoryPath: String
    public let workingDirectory: String
    public let branch: String
}

public enum GitChildWorktreeService {
    public enum AllocationError: Error, Equatable, Sendable {
        case invalidIdentity
        case invalidApprovedProject
        case invalidManagedRoot
        case parentCheckoutMismatch(expected: String, actual: String)
    }

    /// Only the trusted App calls this with a parent-approved repository root.
    /// Destination and branch are derived exclusively from its execution UUID.
    /// App-managed root + repository SHA256 + execution UUID determines the path.
    /// HEAD is fixed; no model path/ref/branch is accepted by this interface.
    public static func prepare(approvedProjectDirectory: String, identity: GitChildWorktreeIdentity, managedRoot: GitChildWorktreeRoot) throws -> GitWorktreePlan {
        guard [identity.taskID, identity.parentSessionID, identity.parentContextSnapshotID].allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        }) else { throw AllocationError.invalidIdentity }
        guard approvedProjectDirectory.hasPrefix("/"),
              !approvedProjectDirectory.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw AllocationError.invalidApprovedProject
        }
        let repository = URL(fileURLWithPath: approvedProjectDirectory).standardizedFileURL.path
        guard repository != "/" else { throw AllocationError.invalidApprovedProject }
        let key = identity.executionID.uuidString.lowercased()
        // Foundation drops /private from an existing /private/var path but keeps
        // it while the child checkout does not exist yet. The qualified
        // disposable root fixes one spelling so creation and later recomputation
        // derive the identical plan.
        let standardizedRoot = URL(fileURLWithPath: managedRoot.path).standardizedFileURL.path
        let root = managedRoot.usesStableVarSpelling
            ? GitWorktreePlan.stableDarwinVarSpelling(standardizedRoot) : standardizedRoot
        guard root.hasPrefix("/"), root != "/", root != repository,
              !root.hasPrefix(repository + "/"),
              !root.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw AllocationError.invalidManagedRoot
        }
        let repositoryHash = SHA256.hash(data: Data(repository.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = URL(fileURLWithPath: root).appendingPathComponent(repositoryHash, isDirectory: true).appendingPathComponent(key, isDirectory: true).path
        return try GitWorktreePlan.prepareTrustedChild(repositoryPath: repository, destinationPath: destination,
            branch: "minis/child-" + key, startPoint: "HEAD", stableVarSpelling: managedRoot.usesStableVarSpelling)
    }

    /// The injected executor must use the existing call-bound Git approval and
    /// checkout protections, including symlink/path checks. No grant store is
    /// created here. Only the exact verified child directory may be approved by
    /// N203; explicit denies and symlink checks remain effective. A failed creation/verification throws; nothing is deleted
    /// and no parent-directory fallback is returned.
    public static func create(approvedProjectDirectory: String, identity: GitChildWorktreeIdentity, managedRoot: GitChildWorktreeRoot, executeApproved: GitWorkflowService.CommandExecutor) async throws -> GitChildWorktreeAllocation {
        let plan = try prepare(approvedProjectDirectory: approvedProjectDirectory, identity: identity, managedRoot: managedRoot)
        try Task.checkCancellation()
        let parent = try await executeApproved("git rev-parse --show-toplevel", plan.workingDirectory)
        guard parent.exitCode == 0 else {
            throw GitWorkflowService.WorkflowError.commandFailed(command: "git rev-parse --show-toplevel", exitCode: parent.exitCode, stdout: parent.stdout, stderr: parent.stderr)
        }
        let actual = parent.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actual.hasPrefix("/"), URL(fileURLWithPath: actual).standardizedFileURL.path == plan.workingDirectory else {
            throw AllocationError.parentCheckoutMismatch(expected: plan.workingDirectory, actual: actual)
        }
        try Task.checkCancellation()
        let checkout = try await GitWorkflowService.createWorktree(plan: plan, executeApproved: executeApproved)
        try Task.checkCancellation()
        return GitChildWorktreeAllocation(identity: identity, repositoryPath: plan.workingDirectory, workingDirectory: checkout, branch: "minis/child-" + identity.executionID.uuidString.lowercased())
    }
}
