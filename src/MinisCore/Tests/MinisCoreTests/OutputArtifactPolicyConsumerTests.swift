import Foundation
import Testing
@testable import MinisCore

@Suite("Owned output reads retain Composer and Goal gates")
struct OutputArtifactPolicyConsumerTests {
    @Test func ordinaryReadsKeepExplicitAndOpenChildDenialsWithAndWithoutBypass() async throws {
        let base = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? FileManager.default.temporaryDirectory
        let root = base.resolvingSymlinksInPath()
            .appendingPathComponent("ordinary-read-denials-\(UUID().uuidString)")
        let denied = root.appendingPathComponent("user-denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = denied.appendingPathComponent("ordinary.txt")
        try Data("ordinary synthetic content".utf8).write(to: file)
        let callerDenied = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [denied])
        for bypass in [false, true] {
            await BypassOpenScope.$isActive.withValue(bypass) {
                await #expect(throws: ToolExecutorError.pathViolation(file.path)) {
                    try await callerDenied.execute(name: "file_read", input: ["path": file.path])
                }
            }
        }
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let child = ChildToolWorkspaceScope(readRoots: [root.path], writeRoots: [root.path],
            workingDirectory: root.path, deniedRoots: [denied.path], parentAuthorityCheck: nil,
            filesOpen: true)
        await ChildToolWorkspaceScope.$current.withValue(child) {
            await BypassOpenScope.$isActive.withValue(true) {
                await #expect(throws: ToolExecutorError.pathViolation(file.path)) {
                    try await builtin.execute(name: "file_read", input: ["path": file.path])
                }
            }
        }
    }

    @Test func fileReadPagingKeepsDirectAndComposerFrozenIntegersEquivalent() async throws {
        let base = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("file-read-integers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lines.txt")
        try Data("line 1\nline 2\nline 3\nline 4".utf8).write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let cases: [(offset: Int, lines: Int, length: Int, expected: String)] = [
            (2, 2, 200, "line 2\nline 3"),
            (-2, -1, 200, "line 1"),
            (0, 0, 200, "line 1"),
            (1, 1, 0, "l\n…[truncated at 1 chars]"),
            (1, 1, -1, "l\n…[truncated at 1 chars]")
        ]
        for item in cases {
            let input: [String: Any] = ["path": file.path, "offset": item.offset,
                "lines": item.lines, "max_length": item.length]
            let direct = try await executor.execute(name: "file_read", input: input)
            let frozen = try ComposerToolInput(input).toolExecutionDictionary
            let throughFrozen = try await executor.execute(name: "file_read", input: frozen)
            #expect(direct == item.expected)
            #expect(throughFrozen == item.expected)
            #expect(throughFrozen == direct)
        }
    }

    @Test func fileReadPagingPreservesNSNumberIntegerInputs() async throws {
        let base = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("file-read-boxed-integers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lines.txt")
        try Data("line 1\nline 2\nline 3\nline 4".utf8).write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let native = try await executor.execute(name: "file_read", input: [
            "path": file.path, "offset": 2, "lines": 2, "max_length": 200])
        let boxed = try await executor.execute(name: "file_read", input: [
            "path": file.path, "offset": NSNumber(value: 2),
            "lines": NSNumber(value: 2), "max_length": NSNumber(value: 200)])
        #expect(native == "line 2\nline 3")
        #expect(boxed == native)
    }

    @Test func fileReadPagingDoesNotCoerceDoubleStringOrBool() async throws {
        let base = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("file-read-nonintegers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lines.txt")
        let content = "line 1\nline 2\nline 3\nline 4"
        try Data(content.utf8).write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        for value in [2.0, "2", true] as [Any] {
            let input: [String: Any] = ["path": file.path, "offset": value,
                "lines": value, "max_length": value]
            let direct = try await executor.execute(name: "file_read", input: input)
            let frozen = try ComposerToolInput(input).toolExecutionDictionary
            let throughFrozen = try await executor.execute(name: "file_read", input: frozen)
            #expect(direct == content)
            #expect(throughFrozen == content)
        }
    }

    @Test func privateFloorAndExplicitDenialsRemainIndependent() {
        let project = URL(fileURLWithPath: "/synthetic-project")
        let privateRoot = URL(fileURLWithPath: "/synthetic-private")
        let explicitRoot = URL(fileURLWithPath: "/synthetic-user-deny")
        let combined = BuiltinToolExecutor(allowedRoot: project,
            deniedRoots: [explicitRoot], appPrivateDeniedRoots: [privateRoot])
        #expect(Set(combined.deniedRoots) == Set([privateRoot, explicitRoot]))
        #expect(combined.explicitDeniedRoots == [explicitRoot])
        #expect(combined.appPrivateDeniedRoots == [privateRoot])
        let legacyEmpty = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [])
        #expect(legacyEmpty.deniedRoots.isEmpty)
        #expect(legacyEmpty.explicitDeniedRoots.isEmpty)
        let defaultOwner = BuiltinToolExecutor(allowedRoot: project)
        #expect(Set(defaultOwner.deniedRoots) == Set(BuiltinToolExecutor.defaultDeniedRoots()))
        #expect(defaultOwner.explicitDeniedRoots.isEmpty)
    }

    @Test func sameSessionProducedReadUsesOriginalToolAndExplicitGateDenyStillWins() async throws {
        let base = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? FileManager.default.temporaryDirectory
        let fixture = base.resolvingSymlinksInPath()
            .appendingPathComponent("artifact-policy-\(UUID().uuidString)")
        let project = fixture.appendingPathComponent("project")
        let storage = fixture.appendingPathComponent("private-storage")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sessionID = UUID()
        let artifact = try #require(try ToolOutputArtifactStore(sessionStorageRoot: storage, sessionID: sessionID)
            .persistIfLarge(redactedOutput: (1...7_000).map { "line \($0)" }.joined(separator: "\n")))
        let now = Date()
        let goal = GoalEnvelope(scopeID: "artifact-policy", allowedCapabilities: ["file_read"],
            fileRoots: [project.path], budget: 10, deadline: now.addingTimeInterval(600),
            concurrencyLimit: 1, autonomyLevel: .l3, creatorID: "OutputArtifactPolicyConsumerTests", createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: now, expiresAt: goal.deadline)
        let snapshot = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .session, effort: .standard,
            sessionID: sessionID.uuidString, turnID: 1, taskID: "synthetic-task", messageID: "synthetic-message",
            workspaceID: "synthetic-project", createdAt: now, policyRevision: "v1", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: [project.path], workspaceID: "synthetic-project", revision: "v1",
            leaseID: "synthetic-lease", expiresAt: goal.deadline, autonomyCeiling: .l3)
        let builtin = BuiltinToolExecutor(allowedRoot: project, appPrivateDeniedRoots: [storage])
        let owner = ToolExecutorReference(builtin)
        let resolver: OwnedOutputArtifactReadContext.Resolver = { path in
            guard let builtin = owner.value as? BuiltinToolExecutor else { return nil }
            return try builtin.resolveOwnedOutputArtifactRead(path: path)
        }
        func executor(deny: Bool, toolOwner: (any ToolExecutor)? = nil) -> ComposerPolicyEnforcedToolExecutor {
            let policy = PolicyEnforcedToolExecutor(base: toolOwner ?? builtin,
                goal: goal, lease: lease)
            return ComposerPolicyEnforcedToolExecutor(base: policy,
                controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
                approvalGate: ApprovalGate(policyByTool: deny ? ["file_read": .deny] : [:]))
        }
        let scope = ToolOutputArtifactSessionScope(sessionStorageRoot: storage, sessionID: sessionID)
        try await OwnedOutputArtifactReadContext.$current.withValue(resolver) {
        try await ToolOutputArtifactSessionScope.$current.withValue(scope) {
            let read = try await executor(deny: false).execute(callID: "owned-read", name: "file_read",
                input: ["path": artifact.fileURL.path, "offset": 2, "lines": 2, "max_length": 200])
            #expect(read == "line 2\nline 3")
            await #expect(throws: ComposerAuthorizationError.approvalDenied("Capability is blocked by approval policy")) {
                _ = try await executor(deny: true).execute(callID: "explicit-deny", name: "file_read",
                    input: ["path": artifact.fileURL.path])
            }
        }
        let explicitOwner = ToolExecutorReference(BuiltinToolExecutor(allowedRoot: project, deniedRoots: [storage],
            appPrivateDeniedRoots: [storage]))
        await ToolOutputArtifactSessionScope.$current.withValue(scope) {
            await OwnedOutputArtifactReadContext.$current.withValue({ path in
                guard let builtin = explicitOwner.value as? BuiltinToolExecutor else { return nil }
                return try builtin.resolveOwnedOutputArtifactRead(path: path)
            }) {
                await #expect(throws: ToolExecutorError.pathViolation(artifact.fileURL.path)) {
                    _ = try await executor(deny: false, toolOwner: explicitOwner.value).execute(
                        callID: "explicit-root-deny", name: "file_read", input: ["path": artifact.fileURL.path])
                }
            }
            let unknownScope = ChildToolWorkspaceScope(readRoots: [project.path], writeRoots: [project.path],
                workingDirectory: project.path, deniedRoots: [storage.path], parentAuthorityCheck: nil)
            await ChildToolWorkspaceScope.$current.withValue(unknownScope) {
                await #expect(throws: ToolExecutorError.pathViolation(artifact.fileURL.path)) {
                    _ = try await executor(deny: false).execute(callID: "unknown-deny-provenance", name: "file_read",
                        input: ["path": artifact.fileURL.path])
                }
            }
        }
        await ToolOutputArtifactSessionScope.$current.withValue(.init(sessionStorageRoot: storage, sessionID: UUID())) {
            await #expect(throws: ToolExecutorError.pathViolation(artifact.fileURL.path)) {
                _ = try await executor(deny: false).execute(callID: "wrong-session", name: "file_read",
                    input: ["path": artifact.fileURL.path])
            }
        }
        }
    }
}
