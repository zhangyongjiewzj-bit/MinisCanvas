import Foundation

/// Read-only projection of the already-admitted execution scope. Providers
/// use this while capturing checkpoints/records; tool JSON supplies no roots.
public enum AdmittedFileWorkspaceRoots {
    /// Scope only an existing owner's validated directories. No raw roots,
    /// approval token, lease or policy epoch is accepted or created here.
    /// The caller must retain its original approval and mutation lease.
    public static func withValidatedOwner<T: Sendable>(
        owner: BuiltinToolExecutor, workingDirectory: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard let directory = PolicyRuntimePathBoundary.canonicalPath(workingDirectory) else {
            throw ToolExecutorError.pathViolation(workingDirectory)
        }
        let cwd = try owner.validatedTargetWorkspaceDirectory(directory)
        // Canonicalize existing configured aliases using the owner's ordinary
        // runtime validator. Never reclassify old mounts as new grants.
        let roots = try ([cwd] + owner.additionalAllowedRoots).map { root in
            guard let physical = PolicyRuntimePathBoundary.canonicalPath(root.path) else {
                throw ToolExecutorError.pathViolation(root.path)
            }
            return try owner.validatedTargetWorkspaceDirectory(physical).path
        }
        let inherited = ChildToolWorkspaceScope.current
        if let inherited {
            guard roots.allSatisfy({ PolicyRuntimePathBoundary.isWithinRoots(path: $0, roots: inherited.writeRoots) }),
                  PolicyRuntimePathBoundary.isWithinRoots(path: cwd.path, roots: inherited.writeRoots),
                  roots.allSatisfy({ root in !inherited.deniedRoots.contains {
                      PolicyRuntimePathBoundary.foldedCandidate(root, isWithin: $0)
                  } }) else {
                throw ToolExecutorError.pathViolation(workingDirectory)
            }
        }
        let scope = ChildToolWorkspaceScope(readRoots: roots, writeRoots: roots,
            workingDirectory: cwd.path,
            deniedRoots: owner.deniedRoots.map(\.path) + (inherited?.deniedRoots ?? []),
            parentAuthorityCheck: inherited?.parentAuthorityCheck,
            explicitDeniedRoots: owner.explicitDeniedRoots.map(\.path)
                + (inherited.map { $0.explicitDeniedRoots ?? $0.deniedRoots } ?? []))
        return try await ChildToolWorkspaceScope.$current.withValue(scope) {
            try await operation()
        }
    }

    public static func currentWriteRoots(fallback: [URL]) -> [URL] {
        guard let scope = ChildToolWorkspaceScope.current else { return fallback }
        return scope.writeRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
