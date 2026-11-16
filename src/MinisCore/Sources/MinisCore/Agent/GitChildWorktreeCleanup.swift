import Foundation

/// App lifecycle projection, not a grant. The App captures the existing child
/// scope and parent authority; no model/config input may construct this source.
public struct GitChildWorktreeCleanupSnapshot: Equatable, Sendable {
    public let allocation: GitChildWorktreeAllocation
    public let parentIdentity: GitChildWorktreeIdentity
    public let goalID: String
    public let scopeID: String
    public let leaseID: String
    public let generation: UUID
    public let taskIsActive: Bool
    public let childScopeRevoked: Bool
    public let parentAuthorityValid: Bool

    public init(allocation: GitChildWorktreeAllocation, parentIdentity: GitChildWorktreeIdentity,
                goalID: String, scopeID: String, leaseID: String, generation: UUID,
                taskIsActive: Bool, childScopeRevoked: Bool, parentAuthorityValid: Bool) {
        self.allocation = allocation; self.parentIdentity = parentIdentity
        self.goalID = goalID; self.scopeID = scopeID; self.leaseID = leaseID
        self.generation = generation; self.taskIsActive = taskIsActive
        self.childScopeRevoked = childScopeRevoked; self.parentAuthorityValid = parentAuthorityValid
    }
}

public protocol GitChildWorktreeCleanupSource: Sendable {
    func currentSnapshot() async throws -> GitChildWorktreeCleanupSnapshot
    /// Reuse the existing owner path boundary (including symlink and explicit
    /// deny checks). Accept only this allocation's exact root, never its parent.
    func validateExactWorktreePath(_ allocation: GitChildWorktreeAllocation) async throws
    /// Must hold the existing task/resource mutation lease for the whole
    /// operation, preventing task restart, scope reuse, or owner replacement.
    /// Compare the live parent authority and scope to expected before invoking.
    func withExclusiveCleanupAccess(
        expected: GitChildWorktreeCleanupSnapshot,
        operation: @Sendable (GitChildWorktreeCleanupSnapshot) async throws -> GitChildWorktreeCleanupResult
    ) async throws -> GitChildWorktreeCleanupResult
}

public struct GitChildWorktreeCleanupRequest: Equatable, Sendable {
    public let snapshot: GitChildWorktreeCleanupSnapshot
    public let approvalText: String
    fileprivate let evidence: GitChildWorktreeCleanupService.Evidence
}

public struct GitChildWorktreeCleanupResult: Equatable, Sendable {
    public let originalPath: String
    public let trashURL: URL
    public let message: String
}

/// Fixed producer output; there is no public command/path initializer.
public struct GitChildWorktreeCleanupReadSet: Equatable, Sendable {
    public let command: String
    public let repositoryPath: String
    public let workingDirectory: String
    public let approvalChecklist: String
}

/// Bridge sets outputComplete only after the original shell envelope has no
/// timeout, truncation, artifact preview or output-limit failure. No cap is raised.
public struct GitChildWorktreeCleanupReadSetResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let outputComplete: Bool
    public init(exitCode: Int32, stdout: String, stderr: String, outputComplete: Bool) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
        self.outputComplete = outputComplete
    }
}

/// No process launch, permanent removal, branch deletion, prune or automatic
/// cleanup. Every read uses the existing approved-project executor; only the
/// injected explicitly approved platform trash callback may retire a directory.
public enum GitChildWorktreeCleanupService {
    public enum CleanupError: Error, Equatable, Sendable, LocalizedError {
        case rejected(String)
        public var errorDescription: String? {
            switch self { case .rejected(let reason): return reason }
        }
    }
    struct Evidence: Equatable, Sendable {
        let parentCheckout: String
        let childCheckout: String
        let commonDirectory: String
        let branch: String
        let status: String
        let index: String
        let head: String
    }

    public typealias ReadOnlyExecutor = @Sendable (GitChildWorktreeCleanupReadSet) async throws -> GitChildWorktreeCleanupReadSetResult
    public typealias ApprovedTrash = @Sendable (GitChildWorktreeCleanupRequest) async throws -> URL

    public static func prepare(source: any GitChildWorktreeCleanupSource,
                               managedRoot: GitChildWorktreeRoot,
                               readOnly: ReadOnlyExecutor) async throws -> GitChildWorktreeCleanupRequest {
        try Task.checkCancellation()
        let snapshot = try await source.currentSnapshot()
        try validate(snapshot, managedRoot: managedRoot)
        try await source.validateExactWorktreePath(snapshot.allocation)
        let evidence = try await inspect(snapshot.allocation, managedRoot: managedRoot, execute: readOnly)
        guard try await source.currentSnapshot() == snapshot else { throw CleanupError.rejected("任务归属或状态已变化，请重新查看") }
        return GitChildWorktreeCleanupRequest(snapshot: snapshot,
            approvalText: "将隔离工作树移到废纸篓？\n" + snapshot.allocation.workingDirectory
                + "\n任务：" + snapshot.allocation.identity.taskID
                + "\nGit 登记与分支保留；不会永久删除。", evidence: evidence)
    }

    public static func retire(request: GitChildWorktreeCleanupRequest,
                              source: any GitChildWorktreeCleanupSource,
                              managedRoot: GitChildWorktreeRoot,
                              readOnly: @escaping ReadOnlyExecutor,
                              approvedTrash: @escaping ApprovedTrash) async throws -> GitChildWorktreeCleanupResult {
        try await source.withExclusiveCleanupAccess(expected: request.snapshot) { live in
            try Task.checkCancellation()
            guard live == request.snapshot else { throw CleanupError.rejected("任务归属或状态已变化，未移动目录") }
            try validate(live, managedRoot: managedRoot)
            try await source.validateExactWorktreePath(live.allocation)
            let evidence = try await inspect(live.allocation, managedRoot: managedRoot, execute: readOnly)
            guard evidence == request.evidence else { throw CleanupError.rejected("Git 状态已变化，请重新确认") }
            try Task.checkCancellation()
            // App must bind explicit confirmation to this exact request and
            // revalidate path/symlink/denies immediately before trashItem.
            // A thrown error leaves the request unretired; never retry as remove.
            try await source.validateExactWorktreePath(live.allocation)
            let trashURL = try await approvedTrash(request)
            return GitChildWorktreeCleanupResult(originalPath: live.allocation.workingDirectory,
                trashURL: trashURL, message: "目录已移废纸篓，Git 登记与分支保留")
        }
    }

    private static func validate(_ snapshot: GitChildWorktreeCleanupSnapshot, managedRoot: GitChildWorktreeRoot) throws {
        guard snapshot.parentAuthorityValid,
              !snapshot.taskIsActive, snapshot.childScopeRevoked else {
            throw CleanupError.rejected("任务仍活动、授权未撤销或父项目权限失效，不能清理")
        }
        guard snapshot.parentIdentity == snapshot.allocation.identity,
              [snapshot.goalID, snapshot.scopeID, snapshot.leaseID].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CleanupError.rejected("任务、会话、快照或父项目授权归属不匹配")
        }
        let allocation = snapshot.allocation
        let expected = try GitChildWorktreeService.prepare(approvedProjectDirectory: allocation.repositoryPath,
                                                          identity: allocation.identity, managedRoot: managedRoot)
        guard allocation.repositoryPath == expected.workingDirectory,
              allocation.workingDirectory == expected.path,
              allocation.branch == "minis/child-" + allocation.identity.executionID.uuidString.lowercased() else {
            throw CleanupError.rejected("目标不是本次可信分配的精确隔离目录")
        }
    }

    /// Exactly eight builtin Git checks, two trusted cwd values and seven
    /// fixed NUL separators. && proves every preceding Git/printf succeeded
    /// when the original shell's final exit is zero. No script, -z or permit.
    public static func readSet(for allocation: GitChildWorktreeAllocation) throws -> GitChildWorktreeCleanupReadSet {
        let repository = allocation.repositoryPath
        let child = allocation.workingDirectory
        for path in [repository, child] {
            guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path,
                  !path.unicodeScalars.contains(where: {
                      $0.properties.generalCategory == .control || $0.properties.generalCategory == .lineSeparator
                          || $0.properties.generalCategory == .paragraphSeparator
                  }) else { throw CleanupError.rejected("隔离检查路径无效或含控制字符") }
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let checks = [
            (repository, "rev-parse --show-toplevel"),
            (child, "rev-parse --show-toplevel"),
            (repository, "rev-parse --git-common-dir"),
            (child, "rev-parse --git-common-dir"),
            (child, "symbolic-ref -q HEAD"),
            (child, "status --porcelain=v1 --untracked-files=all --ignored=matching --ignore-submodules=none"),
            (child, "ls-files --stage"),
            (child, "rev-parse HEAD")
        ].map { "git -C " + quote($0.0) + " " + $0.1 }
        return GitChildWorktreeCleanupReadSet(
            command: checks.joined(separator: " && printf '\\000' && "),
            repositoryPath: repository, workingDirectory: child,
            approvalChecklist: "隔离工作树只读检查（准备和执行前各一次，共两次；移到废纸篓另需一次精确确认）\n父仓库：" + repository
                + "\n隔离工作树：" + child + "\n完整固定检查清单：\n"
                + checks.enumerated().map { "\($0.offset + 1). " + $0.element }.joined(separator: "\n"))
    }

    private static func inspect(_ allocation: GitChildWorktreeAllocation,
                                managedRoot: GitChildWorktreeRoot,
                                execute: ReadOnlyExecutor) async throws -> Evidence {
        let repository = allocation.repositoryPath
        let child = allocation.workingDirectory
        let readSet = try readSet(for: allocation)
        let result = try await execute(readSet)
        guard result.outputComplete else { throw CleanupError.rejected("隔离检查输出不完整、超时或超限，未移动目录") }
        guard result.exitCode == 0 else {
            throw GitWorkflowService.WorkflowError.commandFailed(command: readSet.command, exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        }
        let fields = result.stdout.components(separatedBy: "\0")
        guard fields.count == 8 else { throw CleanupError.rejected("隔离检查结果必须恰好包含八段完整输出") }
        let values = fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let parentTop = values[0], childTop = values[1]
        let allowsVarAlias = managedRoot.usesStableVarSpelling
        guard sameCheckout(reported: parentTop, expected: repository, allowsVarAlias: allowsVarAlias),
              sameCheckout(reported: childTop, expected: child, allowsVarAlias: allowsVarAlias) else {
            throw CleanupError.rejected("仓库或工作树身份已变化")
        }
        let parentCommon = values[2], childCommon = values[3]
        let common = absolute(parentCommon, directory: repository)
        guard common == absolute(childCommon, directory: child) else { throw CleanupError.rejected("工作树不属于原父仓库") }
        let branch = values[4]
        guard branch == "refs/heads/" + allocation.branch else { throw CleanupError.rejected("隔离分支已变化") }
        // Include untracked AND ignored entries. Unknown ignored data is never
        // silently disposed. Refuse submodules rather than guessing their state.
        let status = values[5]
        guard status.isEmpty else { throw CleanupError.rejected("工作树含修改、未跟踪或忽略文件，请先处理后再清理") }
        // Git emits LF-terminated lines. Remove only the final LF, never
        // trim malformed leading whitespace into valid structured evidence.
        let index = fields[6].hasSuffix("\n") ? String(fields[6].dropLast()) : fields[6]
        let head = values[7]
        guard [40, 64].contains(head.count), head.allSatisfy({ $0.isHexDigit }) else {
            throw CleanupError.rejected("无法确认工作树源提交")
        }
        let modes = try indexModes(index)
        guard !modes.contains("160000") else {
            throw CleanupError.rejected("工作树含子模块，需手动核对后清理")
        }
        return Evidence(parentCheckout: parentTop, childCheckout: childTop, commonDirectory: common,
                        branch: branch, status: status, index: index, head: head)
    }

    /// Equivalent to ^[0-7]{6} [0-9a-f]{40}(?:[0-9a-f]{24})? [0-3]\t.+$,
    /// checked per complete line before interpreting mode. Redaction preserves
    /// confidentiality but can invalidate evidence; invalid evidence never passes.
    private static func indexModes(_ index: String) throws -> [String] {
        if index.isEmpty { return [] }
        return try index.components(separatedBy: "\n").map { line in
            let columns = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3,
                  columns[0].count == 6, columns[0].allSatisfy({ "01234567".contains($0) }),
                  [40, 64].contains(columns[1].count),
                  columns[1].allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw CleanupError.rejected("检查输出被改写或结构异常，未移动目录")
            }
            let stageAndPath = columns[2].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard stageAndPath.count == 2, ["0", "1", "2", "3"].contains(String(stageAndPath[0])),
                  !stageAndPath[1].isEmpty,
                  !stageAndPath[1].unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
                throw CleanupError.rejected("检查输出被改写或结构异常，未移动目录")
            }
            return String(columns[0])
        }
    }

    /// Git reports the physical /private/var spelling. A qualified disposable
    /// root may match its stable /var spelling only for that fixed alias with a
    /// byte-identical suffix; everything else must be literally equal.
    static func sameCheckout(reported: String, expected: String, allowsVarAlias: Bool) -> Bool {
        if reported == expected { return true }
        guard allowsVarAlias, expected.hasPrefix("/var/") else { return false }
        return reported == "/private" + expected
    }

    private static func absolute(_ path: String, directory: String) -> String {
        URL(fileURLWithPath: path.hasPrefix("/") ? path : directory + "/" + path).standardizedFileURL.path
    }

}
