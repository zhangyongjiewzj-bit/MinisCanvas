import Foundation
import Testing
@testable import MinisCore

@Suite("Checkpoint restore scopes retain an existing owner boundary")
struct AdmittedFileWorkspaceRestoreScopeTests {
    @Test func existingOwnerScopeIsTemporaryAndRejectsOutsideOrDeniedDirectories() async throws {
        let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("restore-scope-\(UUID().uuidString)")
        let project = fixture.appendingPathComponent("project")
        let mounted = fixture.appendingPathComponent("mounted")
        let denied = project.appendingPathComponent("denied")
        let outside = fixture.appendingPathComponent("outside")
        for directory in [project, mounted, denied, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }
        let owner = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [denied],
            additionalAllowedRoots: [mounted])
        #expect(AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: []).isEmpty)
        let scopedRoots = try await AdmittedFileWorkspaceRoots.withValidatedOwner(owner: owner,
            workingDirectory: project.path) {
            AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: []).map(\.path)
        }
        #expect(Set(scopedRoots) == Set([project.path, mounted.path]))
        #expect(AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: []).isEmpty)
        for forbidden in [denied, outside] {
            await #expect(throws: (any Error).self) {
                try await AdmittedFileWorkspaceRoots.withValidatedOwner(owner: owner,
                    workingDirectory: forbidden.path) { true }
            }
        }
        #expect(AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: []).isEmpty)
        let narrow = ChildToolWorkspaceScope(readRoots: [mounted.path], writeRoots: [mounted.path],
            workingDirectory: mounted.path, deniedRoots: [], parentAuthorityCheck: nil)
        await ChildToolWorkspaceScope.$current.withValue(narrow) {
            await #expect(throws: (any Error).self) {
                try await AdmittedFileWorkspaceRoots.withValidatedOwner(owner: owner,
                    workingDirectory: project.path) { true }
            }
        }
        let alias = fixture.appendingPathComponent("existing-mount-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mounted)
        let aliasOwner = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [], additionalAllowedRoots: [alias])
        let aliasRoots = try await AdmittedFileWorkspaceRoots.withValidatedOwner(owner: aliasOwner,
            workingDirectory: project.path) {
            AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: []).map(\.path)
        }
        #expect(Set(aliasRoots) == Set([project.path, mounted.path]))
        #expect(AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: []).isEmpty)
        let floorOwner = BuiltinToolExecutor(allowedRoot: project, appPrivateDeniedRoots: [denied])
        await #expect(throws: (any Error).self) {
            try await AdmittedFileWorkspaceRoots.withValidatedOwner(owner: floorOwner,
                workingDirectory: denied.path) { true }
        }
    }
}

@Suite("Checkpoint restore owner scope does not replace session or hash checks")
struct AdmittedFileWorkspaceRestoreOwnershipTests {
    @Test func mountedCheckpointStillRejectsAnotherSessionAndChangedAfterHash() async throws {
        let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("restore-owned-\(UUID().uuidString)")
        let project = fixture.appendingPathComponent("project")
        let mounted = fixture.appendingPathComponent("mounted")
        for directory in [project, mounted] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }
        let owner = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [], additionalAllowedRoots: [mounted])
        let store = try FileCheckpointStore(directory: fixture.appendingPathComponent("checkpoints"),
            allowedRoots: [project], allowedRootsProvider: {
                AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: [project])
            })
        let file = mounted.appendingPathComponent("file.txt")
        let before = Data("before".utf8), after = Data("after".utf8)
        try before.write(to: file)
        let checkpoint = try await AdmittedFileWorkspaceRoots.withValidatedOwner(owner: owner,
            workingDirectory: project.path) {
            let id = try store.begin(path: file, sessionID: "child-session", operation: .edit,
                expectedAfter: after, parentSessionID: "parent-session")
            try after.write(to: file)
            try store.commit(id)
            return id
        }
        #expect(throws: FileCheckpointStore.Failure.self) {
            try store.restore(checkpoint, sessionID: "parent-session", expectedPath: file.path)
        }
        try await ToolFileMutationScope.withLock(path: file) {
            try await AdmittedFileWorkspaceRoots.withValidatedOwner(owner: owner,
                workingDirectory: project.path) {
                #expect(throws: FileCheckpointStore.Failure.self) {
                    try store.restore(checkpoint, sessionID: "unrelated-session", expectedPath: file.path)
                }
                try Data("newer-external-change".utf8).write(to: file)
                #expect(throws: FileCheckpointStore.Failure.self) {
                    try store.restore(checkpoint, sessionID: "parent-session", expectedPath: file.path)
                }
                #expect(try Data(contentsOf: file) == Data("newer-external-change".utf8))
                try after.write(to: file)
                _ = try store.restore(checkpoint, sessionID: "parent-session", expectedPath: file.path)
                #expect(try Data(contentsOf: file) == before)
            }
        }
        #expect(AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: []).isEmpty)
    }
}
