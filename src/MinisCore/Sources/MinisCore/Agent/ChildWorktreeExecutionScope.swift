import Foundation

/// A single verified child checkout bound to an existing parent authorization.
/// Only trusted App composition supplies this value, after the original path
/// and Git approvals. It is runtime-only and has no raw-path initializer.
public final class ChildWorktreeExecutionScope: GitChildWorktreeCleanupSource, @unchecked Sendable {
    public let allocation: GitChildWorktreeAllocation
    public let executionID: String
    public let owner: BuiltinToolExecutor
    public let executor: any ToolExecutor
    public let goal: GoalEnvelope
    public let facts: ComposerPolicyFactSource
    private let lock = NSLock()
    private var active = true
    private var claimed = false
    private var cleanupInProgress = false
    private var resourceRetired = false
    private var resourceGeneration = UUID()
    private let validatedWorkingDirectory: String
    private let resourceDirectoryIdentity: String
    private let cleanupParentAuthority: (@Sendable () async throws -> Void)?

    public init(allocation: GitChildWorktreeAllocation, task: SubAgentTask,
        owner: BuiltinToolExecutor, executor: any ToolExecutor,
        goal: GoalEnvelope, lease: AutonomyLease, facts: ComposerPolicyFactSource,
        cleanupParentAuthority: (@Sendable () async throws -> Void)? = nil,
        now: Date = Date()) throws {
        guard task.isolation == .worktree, case .builtin = task.agentType,
              let executionID = task.executionID,
              executionID.split(separator: ":").last?.lowercased()
                == allocation.identity.executionID.uuidString.lowercased(),
              task.id == allocation.identity.taskID,
              task.parentContextSnapshotID == allocation.identity.parentContextSnapshotID,
              goal.goalID == lease.goalID, goal.scopeID == lease.scopeID,
              !lease.revoked, lease.issuedAt <= now, now < lease.expiresAt, now < goal.deadline,
              !facts.revoked, now < facts.expiresAt, !facts.leaseID.isEmpty,
              facts.allowedWriteRoots == goal.fileRoots,
              (executor as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound == true,
              (executor as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner === owner else {
            throw ToolExecutorError.invalidParameter("child_isolation_binding")
        }
        let directory = try owner.validatedTargetWorkspaceDirectory(allocation.workingDirectory)
        let validatedWorkingDirectory = directory.path
        guard goal.fileRoots == [validatedWorkingDirectory] else {
            throw ToolExecutorError.invalidParameter("child_isolation_binding")
        }
        self.validatedWorkingDirectory = validatedWorkingDirectory
        self.resourceDirectoryIdentity = try Self.directoryIdentity(directory)
        self.allocation = allocation
        self.executionID = executionID
        self.owner = owner
        self.executor = executor
        self.goal = goal
        self.facts = facts
        self.cleanupParentAuthority = cleanupParentAuthority
    }

    public var isActive: Bool { lock.withLock { active } }
    func claim(task: SubAgentTask) -> Bool {
        lock.withLock {
            guard active, !claimed, !cleanupInProgress, !resourceRetired, task.id == allocation.identity.taskID,
                  task.executionID == executionID,
                  task.parentContextSnapshotID == allocation.identity.parentContextSnapshotID else { return false }
            claimed = true
            return true
        }
    }
    func revoke() {
        lock.withLock {
            if active { active = false; resourceGeneration = UUID() }
        }
    }

    public func currentSnapshot() async throws -> GitChildWorktreeCleanupSnapshot {
        let parentValid: Bool
        if let cleanupParentAuthority {
            do { try await cleanupParentAuthority(); parentValid = true }
            catch { parentValid = false }
        } else { parentValid = false }
        return lock.withLock {
            GitChildWorktreeCleanupSnapshot(allocation: allocation, parentIdentity: allocation.identity,
                goalID: goal.goalID.uuidString, scopeID: goal.scopeID, leaseID: facts.leaseID,
                generation: resourceGeneration, taskIsActive: active,
                childScopeRevoked: !active, parentAuthorityValid: parentValid && !resourceRetired)
        }
    }

    public func validateExactWorktreePath(_ value: GitChildWorktreeAllocation) async throws {
        guard value == allocation, let cleanupParentAuthority else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("清理目标缺少原资源归属")
        }
        try await cleanupParentAuthority()
        let target = try owner.validatedTargetWorkspaceDirectory(value.workingDirectory)
        guard target.path == validatedWorkingDirectory,
              try Self.directoryIdentity(target) == resourceDirectoryIdentity else {
            throw ToolExecutorError.pathViolation(value.workingDirectory)
        }
    }

    private static func directoryIdentity(_ url: URL) throws -> String {
        guard url.isFileURL, url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw ToolExecutorError.pathViolation(url.path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw ToolExecutorError.pathViolation(url.path)
        }
        return "\(device.stringValue):\(inode.stringValue)"
    }

    public func withExclusiveCleanupAccess(expected: GitChildWorktreeCleanupSnapshot,
        operation: @Sendable (GitChildWorktreeCleanupSnapshot) async throws -> GitChildWorktreeCleanupResult
    ) async throws -> GitChildWorktreeCleanupResult {
        let live = try await currentSnapshot()
        guard live == expected, live.parentAuthorityValid else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("父授权或资源状态已改变")
        }
        // This is the original execution resource lock, shared with claim and
        // revoke. A cleanup cannot race a task restart or replace its owner.
        let admitted = lock.withLock {
            guard !active, !cleanupInProgress, !resourceRetired,
                  resourceGeneration == expected.generation else { return false }
            cleanupInProgress = true
            return true
        }
        guard admitted else { throw GitChildWorktreeCleanupService.CleanupError.rejected("执行资源仍被占用") }
        do {
            let current = try await currentSnapshot()
            guard current == expected else {
                throw GitChildWorktreeCleanupService.CleanupError.rejected("清理审批后资源状态已改变")
            }
            try await validateExactWorktreePath(allocation)
            let result = try await operation(current)
            lock.withLock {
                cleanupInProgress = false
                resourceRetired = true
                resourceGeneration = UUID()
            }
            return result
        } catch {
            lock.withLock { cleanupInProgress = false }
            throw error
        }
    }
}

enum ChildWorktreeExecutionContext {
    @TaskLocal static var current: ChildWorktreeExecutionScope?
}
