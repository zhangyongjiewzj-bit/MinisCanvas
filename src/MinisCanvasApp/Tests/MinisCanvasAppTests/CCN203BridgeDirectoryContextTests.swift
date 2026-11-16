import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("N2-03 production Bridge directory context guards")
@MainActor struct CCN203BridgeDirectoryContextTests {
    @Test func exactContextRequiresTheOriginalSessionProjectLeaseAndGeneration() {
        let now = Date()
        let session = UUID()
        let request = PendingCommandRequest(id: UUID(), commandID: "add-dir",
            args: ["path": "/synthetic/extra"], requiresPolicyApproval: true)
        let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: session.uuidString, turnID: 1, taskID: "task", messageID: "message",
            workspaceID: "workspace", createdAt: now, policyRevision: "revision", grantEpoch: "epoch")
        func facts(epoch: String = "epoch", lease: String = "lease", revision: String = "revision",
            revoked: Bool = false) -> ComposerPolicyFactSource {
            .init(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
                allowedWriteRoots: ["/synthetic/project"], workspaceID: "workspace",
                revision: revision, grantEpoch: epoch, leaseID: lease,
                expiresAt: now.addingTimeInterval(60), revoked: revoked)
        }
        let original = facts()
        let context = ComposerCommandAdjudicationCenter.AdditionalDirectoryApprovalContext(
            request: request, snapshot: snapshot, facts: original,
            physicalDirectory: URL(fileURLWithPath: "/synthetic/extra"), directoryIdentity: "device:inode",
            projectID: "project", workingDirectory: "/synthetic/project", attachmentGeneration: 7)
        func matches(_ pending: PendingCommandRequest?, _ currentSession: UUID?,
            _ project: String?, _ cwd: String?, _ currentFacts: ComposerPolicyFactSource,
            _ generation: UInt64, _ time: Date) -> Bool {
            BridgeStore.additionalDirectoryContextMatches(context, pendingRequest: pending,
                activeSessionID: currentSession, projectID: project, workingDirectory: cwd,
                facts: currentFacts, attachmentGeneration: generation, now: time)
        }
        #expect(matches(request, session, "project", "/synthetic/project", original, 7, now))
        #expect(!matches(nil, session, "project", "/synthetic/project", original, 7, now))
        #expect(!matches(request, UUID(), "project", "/synthetic/project", original, 7, now))
        #expect(!matches(request, session, "other-project", "/synthetic/project", original, 7, now))
        #expect(!matches(request, session, "project", "/synthetic/other", original, 7, now))
        for changed in [facts(epoch: "other-epoch"), facts(lease: "other-goal-lease"),
            facts(revision: "other-revision"), facts(revoked: true)] {
            #expect(!matches(request, session, "project", "/synthetic/project", changed, 7, now))
        }
        #expect(!matches(request, session, "project", "/synthetic/project", original, 8, now))
        #expect(!matches(request, session, "project", "/synthetic/project", original, 7, now.addingTimeInterval(61)))
    }

    @Test func noApprovedDirectoryKeepsTheOriginalOwnerAndExistingAliasMount() throws {
        let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("add-dir-old-mount-\(UUID().uuidString)")
        let project = fixture.appendingPathComponent("project")
        let mounted = fixture.appendingPathComponent("mounted")
        let alias = fixture.appendingPathComponent("existing-alias")
        for directory in [project, mounted] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mounted)
        let base = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [], additionalAllowedRoots: [alias])
        let initialPaths = base.additionalAllowedRoots.map(\.path)
        let unchanged = try BridgeStore.additionalDirectoryOwner(base: base, approved: [])
        #expect(unchanged === base)
        #expect(initialPaths == [alias.standardizedFileURL.path])
        #expect(unchanged.additionalAllowedRoots.map(\.path) == initialPaths)
        // Reclassifying this same old alias as a new /add-dir request is still
        // refused by the strict new-directory admission method.
        #expect(throws: (any Error).self) {
            try BridgeStore.additionalDirectoryOwner(base: base, approved: [alias])
        }
    }

    @Test func directoryReplacementAndSymlinkCannotReuseFrozenIdentity() throws {
        let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("add-dir-identity-\(UUID().uuidString)")
        let original = fixture.appendingPathComponent("directory")
        let replacement = fixture.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let identity = try BridgeStore.additionalDirectoryIdentity(original)
        #expect(identity == (try BridgeStore.additionalDirectoryIdentity(original)))
        try FileManager.default.moveItem(at: original, to: fixture.appendingPathComponent("old"))
        try FileManager.default.moveItem(at: replacement, to: original)
        #expect(identity != (try BridgeStore.additionalDirectoryIdentity(original)))
        let alias = fixture.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        #expect(throws: (any Error).self) { try BridgeStore.additionalDirectoryIdentity(alias) }
    }
    @Test func permissionsIsNavigationDuringGenerationWhileDirectoryGrantsRemainGated() {
        #expect(CommandRegistry.runsDuringGeneration("permissions"))
        #expect(!CommandRegistry.runsDuringGeneration("add-dir"))
        #expect(ComposerCommandAdjudicationCenter.readinessContract(for: "permissions") == .localDesktopAction)
        #expect(ComposerCommandAdjudicationCenter.readinessContract(for: "add-dir") == .scopedAdditionalDirectory)
    }

}
