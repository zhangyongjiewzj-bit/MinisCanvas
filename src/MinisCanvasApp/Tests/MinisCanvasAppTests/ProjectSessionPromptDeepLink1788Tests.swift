import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("D-BACKLINKB session-directed prompt deep-link consumer", .serialized)
@MainActor
struct ProjectSessionPromptDeepLink1788Tests {
    private struct Fixture {
        let root: URL
        let grantedDirectory: URL
        let bridge: BridgeStore
        let handler: ProjectSessionAppHandler
        let store: SessionStore
        let sourceID: UUID
        let targetID: UUID
        let projectID: String
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "backlink-prompt-1788-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("granted-project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore(),
            allowsLegacyCanvasCommandExecutionForTests: true)
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        // Directed prompt routing is the contract here. An ordinary prompt
        // uses the offline provider instead of entering the 300-second Canvas
        // mutation approval flow for an unrelated synthetic command.
        bridge.chat.streamingProviderOverride = MockProvider()
        let handler = try #require(bridge.productionProjectSessionHandler)
        let store = try #require(bridge.chat.sessionStore)
        let sourceID = bridge.chat.applyNewSession(title: "来源会话")
        let projectID = try handler.authorizeFolderFromNativePicker(directory)
        let project = ProjectSessionAuthorizedProject(projectID: projectID,
            displayName: "授权项目", workdirReference: "grant:\(projectID):test")
        let targetID = UUID()
        try bridge.chat.createProjectTarget(id: targetID.uuidString, title: "目标任务",
            sourceID: sourceID.uuidString, project: project, directory: directory,
            taskID: "task-prompt", runID: "run-prompt")
        let card = SessionReferenceCard(id: UUID().uuidString,
            sourceSessionID: sourceID.uuidString, targetSessionID: targetID.uuidString,
            taskID: "task-prompt", runID: "run-prompt", projectID: projectID,
            projectTitle: "授权项目", title: "目标任务",
            createdAt: Date(), status: .running)
        try bridge.chat.appendSourceCard(card)
        #expect(bridge.chat.canOpenSourceCard(card))
        return Fixture(root: root, grantedDirectory: directory, bridge: bridge,
            handler: handler, store: store, sourceID: sourceID,
            targetID: targetID, projectID: projectID)
    }

    private func assertPromptDenied(_ value: Fixture, target: String, failure: DeepLinkFailure) {
        let originalDraft = "保留来源草稿"
        value.bridge.chat.draftText = originalDraft
        let userCount = value.bridge.chat.sessions.reduce(0) { total, session in
            total + session.messages.filter { $0.role == .user }.count
        }
        DeepLinkHandler(bridge: value.bridge).handle(.sendPrompt(
            text: "建节点 不应执行", session: target))
        #expect(value.bridge.chat.activeSessionID == value.sourceID)
        #expect(value.bridge.chat.draftText == originalDraft)
        #expect(value.bridge.chat.sessions.reduce(0) { total, session in
            total + session.messages.filter { $0.role == .user }.count
        } == userCount)
        #expect(value.bridge.chat.messages.contains { $0.role == .system
            && $0.content.contains(failure.notice) })
    }

    @Test("authorized target receives prompt through the real directed consumer")
    func authorizedTargetPromptRoutesToTarget() throws {
        let value = try fixture()
        defer {
            value.bridge.chat.stopStreaming()
            try? FileManager.default.removeItem(at: value.root)
        }
        #expect(value.bridge.chat.activeSessionID == value.sourceID)
        DeepLinkHandler(bridge: value.bridge).handle(.sendPrompt(
            text: "定向提示词：授权目标", session: value.targetID.uuidString))
        #expect(value.bridge.chat.activeSessionID == value.targetID)
        #expect(value.bridge.chat.sessions.first(where: { $0.id == value.targetID })?
            .messages.contains { $0.role == .user && $0.content == "定向提示词：授权目标" } == true)
        #expect(value.bridge.chat.sessions.first(where: { $0.id == value.sourceID })?
            .messages.contains { $0.role == .user && $0.content == "定向提示词：授权目标" } == false)
    }

    @Test("revoked project grant rejects directed prompt before draft or Provider")
    func revokedGrantPromptFailsClosed() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        try value.handler.revokeProject(id: value.projectID)
        assertPromptDenied(value, target: value.targetID.uuidString, failure: .grantUnavailable)
    }

    @Test("stale native bookmark rejects directed prompt")
    func staleBookmarkPromptFailsClosed() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        try FileManager.default.moveItem(at: value.grantedDirectory,
            to: value.root.appendingPathComponent("moved-project", isDirectory: true))
        #expect(!value.handler.isProjectAvailable(id: value.projectID))
        assertPromptDenied(value, target: value.targetID.uuidString, failure: .grantUnavailable)
    }

    @Test("deleted canonical target cannot be revived by failure notice")
    func deletedTargetPromptFailsClosed() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let preview = try value.store.previewDeletion(id: value.targetID.uuidString)
        let intent = preview.withFirstConfirmation("已核对这份预览")
            .withSecondConfirmation("永久删除")
        _ = try value.store.deleteSession(id: value.targetID.uuidString, intent: intent)
        #expect(value.bridge.chat.sessions.contains { $0.id == value.targetID })
        assertPromptDenied(value, target: value.targetID.uuidString, failure: .sessionChanged)
        #expect(value.store.loadSession(id: value.targetID.uuidString) == nil)
    }

    @Test("unknown target fails instead of sending into the active session")
    func missingTargetPromptDoesNotFallBackToSource() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        assertPromptDenied(value, target: UUID().uuidString, failure: .sessionMissing)
    }

    @Test("ordinary legacy session still accepts a directed local prompt")
    func legacySessionPromptKeepsRoute() throws {
        let value = try fixture()
        defer {
            value.bridge.chat.stopStreaming()
            try? FileManager.default.removeItem(at: value.root)
        }
        let legacyID = value.bridge.chat.applyNewSession(title: "普通会话")
        #expect(value.bridge.chat.applySwitchSession(id: value.sourceID))
        try value.handler.revokeProject(id: value.projectID)
        DeepLinkHandler(bridge: value.bridge).handle(.sendPrompt(
            text: "定向提示词：普通会话", session: legacyID.uuidString))
        #expect(value.bridge.chat.activeSessionID == legacyID)
        #expect(value.bridge.chat.sessions.first(where: { $0.id == legacyID })?
            .messages.contains { $0.role == .user && $0.content == "定向提示词：普通会话" } == true)
    }
}
