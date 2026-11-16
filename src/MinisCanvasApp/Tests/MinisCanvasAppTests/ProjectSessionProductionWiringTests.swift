import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("24C production tool composition")
@MainActor
struct ProjectSessionProductionWiringTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-session-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("three tools become visible only with a recovered App handler")
    func catalogFollowsHandlerBinding() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
        #expect((bridge.chat.agentEngine as? AgentLoopChatEngine)?.projectSessionDefinitions == nil)
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        #expect(bridge.productionProjectSessionHandler != nil)
        #expect(Set((bridge.chat.agentEngine as? AgentLoopChatEngine)?
            .projectSessionDefinitions?.map(\.name) ?? []) == ProjectSessionToolContract.toolNames)
        #expect(bridge.chat.projectSessionHandler === bridge.productionProjectSessionHandler)
    }

    @Test("same canonical directory reuses the one SessionStore and App handler")
    func sameDirectoryRebindKeepsAuthority() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        let store = try #require(bridge.chat.sessionStore)
        let handler = try #require(bridge.productionProjectSessionHandler)
        bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: root.appendingPathComponent("."))
        #expect(bridge.chat.sessionStore === store)
        #expect(bridge.productionProjectSessionHandler === handler)
        #expect(bridge.chat.projectSessionHandler === handler)
        #expect(!bridge.chat.logManager.recentLogs().contains {
            $0.category == "ProjectSession" && $0.message == "PROJECT_SESSION_HANDLER_INITIALIZATION_FAILED"
        })
        #expect(Set((bridge.chat.agentEngine as? AgentLoopChatEngine)?
            .projectSessionDefinitions?.map(\.name) ?? []) == ProjectSessionToolContract.toolNames)
    }

    @Test("a different persistence domain cannot install a second App handler")
    func differentDirectoryFailsClosed() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other", isDirectory: true)
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        let store = try #require(bridge.chat.sessionStore)
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: other)
        #expect(bridge.chat.sessionStore === store)
        #expect(bridge.productionProjectSessionHandler == nil)
        #expect(bridge.chat.projectSessionHandler == nil)
        #expect(!bridge.chat.logManager.recentLogs().contains {
            $0.category == "ProjectSession" && $0.message == "PROJECT_SESSION_HANDLER_INITIALIZATION_FAILED"
        })
    }

    @Test("concurrent target bindings stay separate and a retired target cannot fall through")
    func targetBindingIsolation() throws {
        let sourceID = UUID().uuidString
        let source = ParentRuntimeIdentity(sessionID: sourceID, conversationID: sourceID,
            turnID: "turn-handle:1", taskID: "source-task", actorID: "app")
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let first = TargetWorkspaceBinding(source: source, targetSessionID: firstID,
            taskID: "task-1", runID: "run-1", projectID: "project-1",
            workingDirectory: "/one")
        let second = TargetWorkspaceBinding(source: source, targetSessionID: secondID,
            taskID: "task-2", runID: "run-2", projectID: "project-2",
            workingDirectory: "/two")
        let bindings = ProjectSessionWorkspaceBindings()
        try bindings.register(first)
        try bindings.register(second)
        #expect(throws: ProjectSessionAppError.self) {
            try bindings.register(TargetWorkspaceBinding(source: source,
                targetSessionID: firstID, taskID: "other-task", runID: "other-run",
                projectID: "project-1", workingDirectory: "/one"))
        }
        #expect(bindings.lookup(sessionID: firstID).binding == first)
        #expect(bindings.lookup(sessionID: secondID).binding == second)
        bindings.retire(sessionID: firstID, runID: "different-run")
        #expect(bindings.lookup(sessionID: firstID).binding == first)
        bindings.retire(sessionID: firstID, runID: "run-1")
        #expect(bindings.lookup(sessionID: firstID).wasTarget)
        #expect(bindings.lookup(sessionID: firstID).binding == nil)
        #expect(bindings.lookup(sessionID: secondID).binding == second)
    }

    @Test("unrecoverable reservation journal keeps the tool catalog hidden")
    func corruptJournalFailsClosed() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid".utf8).write(
            to: root.appendingPathComponent("project-session-reservations-v1.json"))
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        #expect(bridge.productionProjectSessionHandler == nil)
        #expect((bridge.chat.agentEngine as? AgentLoopChatEngine)?.projectSessionDefinitions == nil)
        #expect(bridge.chat.projectSessionHandler == nil && bridge.chat.logManager.recentLogs().filter {
            $0.level == .error && $0.category == "ProjectSession"
                && $0.message == "PROJECT_SESSION_HANDLER_INITIALIZATION_FAILED"
        }.count == 1)
    }

    @Test("session project metadata and an arbitrary ID never become a grant")
    func onlyNativeSelectionCanGrant() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try ProjectSessionGrantRegistry(directory: root)
        #expect(registry.list().isEmpty)
        #expect(throws: ProjectSessionAppError.self) {
            _ = try registry.resolve(id: "session-project-id")
        }
        let alias = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(throws: ProjectSessionAppError.self) {
            _ = try registry.registerNativeSelection(alias, displayName: "别名")
        }
        #expect(registry.list().isEmpty)
        let physicalRoot = URL(fileURLWithPath: try DarwinSystemPathResolver.resolve(root), isDirectory: true)
        try Data("owned instruction".utf8).write(to: physicalRoot.appendingPathComponent("AGENTS.md"))
        let frozen = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: physicalRoot))
        let projectID = try registry.registerNativeSelection(root, displayName: "Owned instruction project")
        #expect(!registry.hasInstructionTrust(frozen, projectID: projectID))
        try registry.trustInstructions(frozen, projectID: projectID)
        let reopened = try ProjectSessionGrantRegistry(directory: root)
        #expect(reopened.hasInstructionTrust(frozen, projectID: projectID))
        try Data("changed instruction".utf8).write(to: physicalRoot.appendingPathComponent("AGENTS.md"))
        let changed = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: physicalRoot))
        #expect(!reopened.hasInstructionTrust(changed, projectID: projectID))
        #expect(reopened.hasInstructionTrust(frozen, projectID: projectID))
        #expect(frozen.systemPromptPrefix.contains("owned instruction"))
        try reopened.revokeInstructionTrust(projectID: projectID)
        #expect(!reopened.hasInstructionTrust(frozen, projectID: projectID))
        #expect(try reopened.resolve(id: projectID).projectID == projectID)
        let cold = try ProjectSessionGrantRegistry(directory: root)
        #expect(cold.instructionTrustRows().isEmpty)
    }
    @Test func projectDirectoriesPersistWhileSessionDirectoriesRemainEphemeral() throws {
        let root = try temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let extraCanonicalPath = root.appendingPathComponent("extra")
            .resolvingSymlinksInPath().standardizedFileURL.path
        let extra = URL(fileURLWithPath: extraCanonicalPath, isDirectory: true)
        for url in [project, extra] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let registry = try ProjectSessionGrantRegistry(directory: root)
        let projectID = try registry.registerNativeSelection(project, displayName: "N07 owned project")
        let identity = try ProjectSessionGrantRegistry.directoryIdentity(extra)
        try registry.approveDirectory(extra, identity: identity, sessionID: "session-a", projectID: projectID,
            workingDirectory: project.path, persistForProject: true)
        try registry.approveDirectory(extra, identity: identity, sessionID: "session-b", projectID: projectID,
            workingDirectory: project.path, persistForProject: false)
        let projectGrant = try #require(registry.directoryGrants().first { $0.sessionID == nil })
        let reopened = try ProjectSessionGrantRegistry(directory: root)
        #expect(reopened.directoryGrants() == [projectGrant])
        let actualDirectory = try reopened.validatedDirectory(projectGrant)
        let actualDirectoryIdentity = try ProjectSessionGrantRegistry.directoryIdentity(actualDirectory)
        try #require(actualDirectory.path == projectGrant.path && actualDirectoryIdentity == projectGrant.identity)
        #expect(actualDirectory == extra,
            "Actual URL=\(actualDirectory.absoluteString) directory=\(actualDirectory.hasDirectoryPath); expected URL=\(extra.absoluteString) directory=\(extra.hasDirectoryPath); canonical path and inode matched")
        try registry.revokeDirectory(projectGrant.id)
        let rereopened = try ProjectSessionGrantRegistry(directory: root)
        let revoked = try #require(rereopened.directoryGrants().first)
        #expect(revoked.revoked && revoked.revision != projectGrant.revision)
        #expect(throws: ProjectSessionAppError.self) { _ = try reopened.validatedDirectory(revoked) }
        registry.retainDirectorySessions([])
        #expect(!registry.directoryGrants().contains { $0.sessionID == "session-b" })
    }

}
