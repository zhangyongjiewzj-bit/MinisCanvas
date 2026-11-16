import Foundation
import Testing
@testable import MinisCore

// AJ-45 挂载外部文件夹：authorized additional allowed roots (whitelist).
// 挂载目录作为 BuiltinToolExecutor.additionalAllowedRoots 加入白名单后，
// Agent 可读写位于该目录内的文件；deniedRoots 仍继续拦截。
struct ToolExecutorAdditionalAllowedRootsTests {
    @Test func trustedClonePreservesConfigurationAndDenialsWithoutChangingOldOwner() throws {
        let root = URL(fileURLWithPath: "/synthetic-project")
        let oldRoot = URL(fileURLWithPath: "/synthetic-old-mount")
        let newRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("clone-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: newRoot) }
        let hardDenied = newRoot.appendingPathComponent("private")
        let floor = URL(fileURLWithPath: "/synthetic-app-private")
        let policy = TerminalPolicySnapshot(settings: TerminalPolicySettings(userDeniedCommands: ["blocked-tool"]))
        let original = BuiltinToolExecutor(allowedRoot: root, defaultShellTimeout: 17,
            deniedRoots: [hardDenied], appPrivateDeniedRoots: [floor],
            additionalAllowedRoots: [oldRoot], registeredToolNames: ["file_read"],
            terminalPolicySnapshot: policy, sessionDerivedRoot: true)
        original.fileCheckpointsEnabled = true
        original.fileChangeSessionID = "synthetic-session"
        let copy = try original.copyingAddingAdditionalAllowedRoots([newRoot])
        #expect(copy !== original)
        #expect(original.additionalAllowedRoots == [oldRoot])
        #expect(copy.additionalAllowedRoots == [oldRoot, newRoot])
        #expect(copy.allowedRoot == root)
        #expect(copy.sessionDerivedRoot)
        #expect(copy.explicitDeniedRoots == [hardDenied])
        #expect(copy.appPrivateDeniedRoots == [floor])
        #expect(Set(copy.deniedRoots) == Set([hardDenied, floor]))
        #expect(copy.defaultShellTimeout == 17)
        #expect(copy.registeredToolNames == ["file_read"])
        #expect(copy.fileCheckpointsEnabled)
        #expect(copy.fileChangeSessionID == "synthetic-session")
        #expect(copy.terminalPolicySnapshot.classify(command: "blocked-tool") == .denied)
        copy.fileChangeSessionID = "next-session"
        #expect(original.fileChangeSessionID == "synthetic-session")
    }


    @Test func trustedCloneRejectsDeniedCredentialControlAndSymlinkDestinations() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("clone-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let allowed = base.appendingPathComponent("allowed", isDirectory: true)
        let denied = base.appendingPathComponent("denied")
        let floor = base.appendingPathComponent("private-floor")
        let credential = base.appendingPathComponent(".env")
        let control = base.appendingPathComponent(".git/hooks")
        for path in [allowed, denied, floor, credential, control] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let owner = BuiltinToolExecutor(allowedRoot: base,
            deniedRoots: [denied], appPrivateDeniedRoots: [floor])
        for path in [denied, floor, credential, control, base.appendingPathComponent("missing")] {
            #expect(throws: ToolExecutorError.self) { try owner.copyingAddingAdditionalAllowedRoots([path]) }
        }
        let link = base.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: denied)
        #expect(throws: ToolExecutorError.self) { try owner.copyingAddingAdditionalAllowedRoots([link]) }
        let allowedLink = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: allowedLink, withDestinationURL: allowed)
        #expect(throws: ToolExecutorError.self) { try owner.copyingAddingAdditionalAllowedRoots([allowedLink]) }
        #expect(try owner.copyingAddingAdditionalAllowedRoots([allowed]).additionalAllowedRoots == [allowed])
        let explicitEmpty = BuiltinToolExecutor(allowedRoot: base, deniedRoots: [])
        #expect(try explicitEmpty.copyingAddingAdditionalAllowedRoots([floor]).deniedRoots.isEmpty)
        let implicitDefault = BuiltinToolExecutor(allowedRoot: base)
        let clone = try implicitDefault.copyingAddingAdditionalAllowedRoots([allowed])
        #expect(clone.explicitDeniedRoots.isEmpty)
        #expect(Set(clone.appPrivateDeniedRoots) == Set(implicitDefault.appPrivateDeniedRoots))
    }

    @Test func nonexistentDenyRootDoesNotRejectUnrelatedExistingDirectory() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("clone-missing-deny-\(UUID().uuidString)")
        let allowed = base.appendingPathComponent("allowed", isDirectory: true)
        let absentDeny = base.appendingPathComponent("not-created/nested-deny")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(!FileManager.default.fileExists(atPath: absentDeny.path))
        #expect(PolicyRuntimePathBoundary.canonicalPath(absentDeny.path) == absentDeny.path)
        let owner = BuiltinToolExecutor(allowedRoot: base, deniedRoots: [absentDeny])
        let copy = try owner.copyingAddingAdditionalAllowedRoots([allowed])
        #expect(copy.additionalAllowedRoots == [allowed])
        #expect(copy.explicitDeniedRoots == [absentDeny])
        #expect(copy.deniedRoots == [absentDeny])
        #expect(!FileManager.default.fileExists(atPath: absentDeny.path))
    }

    @Test func addingNewRootPreservesExistingAliasMountWithoutRevalidation() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("clone-existing-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let existing = base.appendingPathComponent("existing")
        let alias = base.appendingPathComponent("existing-alias", isDirectory: true)
        let newRoot = base.appendingPathComponent("new", isDirectory: true)
        let denied = base.appendingPathComponent("denied", isDirectory: true)
        for root in [existing, newRoot, denied] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: existing)
        let owner = BuiltinToolExecutor(allowedRoot: base, deniedRoots: [denied],
            additionalAllowedRoots: [alias])
        let unchanged = try owner.copyingAddingAdditionalAllowedRoots([])
        #expect(unchanged.additionalAllowedRoots == [alias])
        let expanded = try owner.copyingAddingAdditionalAllowedRoots([newRoot])
        #expect(expanded.additionalAllowedRoots == [alias, newRoot])
        #expect(owner.additionalAllowedRoots == [alias])
        #expect(expanded.explicitDeniedRoots == [denied])
        #expect(throws: ToolExecutorError.self) { try owner.copyingAddingAdditionalAllowedRoots([denied]) }
        // A caller cannot pass an unowned alias as an existing mount.
        let unowned = BuiltinToolExecutor(allowedRoot: base, deniedRoots: [])
        #expect(throws: ToolExecutorError.self) { try unowned.copyingAddingAdditionalAllowedRoots([alias]) }
    }

    private func makeFixture() -> (root: URL, mounted: URL, mountedFile: URL, outsideFile: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("ToolExecutorMountedRootsTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("work", isDirectory: true)
        let mounted = base.appendingPathComponent("mounted", isDirectory: true)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        try! fm.createDirectory(at: mounted, withIntermediateDirectories: true)

        let mountedFile = mounted.appendingPathComponent("note.txt")
        try! "hello mounted".data(using: .utf8)!.write(to: mountedFile)
        let outsideFile = base.appendingPathComponent("outside.txt")
        try! "outside".data(using: .utf8)!.write(to: outsideFile)

        return (root, mounted, mountedFile, outsideFile)
    }

    @Test func fileReadAllowsMountedFolder() async throws {
        let (root, mounted, mountedFile, _) = makeFixture()
        let executor = BuiltinToolExecutor(
            allowedRoot: root,
            deniedRoots: [],
            additionalAllowedRoots: [mounted]
        )
        let out = try await executor.execute(name: "file_read", input: ["path": mountedFile.path])
        #expect(out.contains("hello mounted"))
    }

    @Test func fileWriteAllowsMountedFolder() async throws {
        let (root, mounted, _, _) = makeFixture()
        let executor = BuiltinToolExecutor(
            allowedRoot: root,
            deniedRoots: [],
            additionalAllowedRoots: [mounted]
        )
        let target = mounted.appendingPathComponent("new-note.txt")
        let out = try await executor.execute(name: "file_write", input: ["path": target.path, "content": "hi"])
        #expect(out.contains("new-note.txt"))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func fileEditAllowsMountedFolder() async throws {
        let (root, mounted, mountedFile, _) = makeFixture()
        try! "one two".data(using: .utf8)!.write(to: mountedFile)
        let executor = BuiltinToolExecutor(
            allowedRoot: root,
            deniedRoots: [],
            additionalAllowedRoots: [mounted]
        )
        let out = try await executor.execute(
            name: "file_edit",
            input: ["path": mountedFile.path, "old_string": "one", "new_string": "1"]
        )
        #expect(out.contains("replaced 1 occurrence"))
    }

    @Test func fileReadRejectsOutsideBothRoots() async throws {
        let (root, mounted, _, outsideFile) = makeFixture()
        let executor = BuiltinToolExecutor(
            allowedRoot: root,
            deniedRoots: [],
            additionalAllowedRoots: [mounted]
        )
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_read", input: ["path": outsideFile.path])
        }
    }

    @Test func mountedFolderStillBlockedByDeniedRoot() async throws {
        let (root, mounted, _, _) = makeFixture()
        let denied = mounted.appendingPathComponent("Library/Application Support", isDirectory: true)
        try! FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        let secret = denied.appendingPathComponent("secret.json")
        try! "{}".data(using: .utf8)!.write(to: secret)

        let executor = BuiltinToolExecutor(
            allowedRoot: root,
            deniedRoots: [denied],
            additionalAllowedRoots: [mounted]
        )
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_read", input: ["path": secret.path])
        }
    }

    @Test func emptyAdditionalAllowedRootsBehavesAsBefore() async throws {
        let (root, _, _, outsideFile) = makeFixture()
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_read", input: ["path": outsideFile.path])
        }
    }

    @Test func targetWorkspaceMustStayCanonicalMountedAndOutsideDeniedRoots() throws {
        let (root, mounted, _, outsideFile) = makeFixture()
        let denied = mounted.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        let executor = BuiltinToolExecutor(allowedRoot: root,
            deniedRoots: [denied], additionalAllowedRoots: [mounted])
        #expect(try executor.validatedTargetWorkspaceDirectory(mounted.path).path == mounted.path)
        #expect(throws: ToolExecutorError.self) {
            _ = try executor.validatedTargetWorkspaceDirectory(denied.path)
        }
        #expect(throws: ToolExecutorError.self) {
            _ = try executor.validatedTargetWorkspaceDirectory(outsideFile.deletingLastPathComponent().path)
        }
        let alias = root.appendingPathComponent("mounted-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mounted)
        #expect(throws: ToolExecutorError.self) {
            _ = try executor.validatedTargetWorkspaceDirectory(alias.path)
        }
    }

    @Test func toolJSONCannotSupplyTargetWorkspaceWithoutTrustedTurn() async throws {
        let (root, mounted, mountedFile, _) = makeFixture()
        let executor = BuiltinToolExecutor(allowedRoot: root,
            deniedRoots: [], additionalAllowedRoots: [mounted])
        let source = ParentRuntimeIdentity(sessionID: UUID().uuidString,
            conversationID: UUID().uuidString, turnID: "turn-handle:1",
            taskID: "source-task", actorID: "app")
        let binding = TargetWorkspaceBinding(source: source,
            targetSessionID: UUID().uuidString, taskID: "target-task",
            runID: "run-1", projectID: "project-1", workingDirectory: mounted.path)
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.executeInTargetWorkspace(name: "file_read",
                input: ["path": mountedFile.path, "working_directory": mounted.path], binding: binding)
        }
    }
}
