import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("24C copied source backlink deep-link consumer")
@MainActor
struct ProjectSessionDeepLinkBacklinkConsumerTests {
    private struct Fixture {
        let root: URL
        let grantedDirectory: URL
        let bridge: BridgeStore
        let handler: ProjectSessionAppHandler
        let store: SessionStore
        let sourceID: UUID
        let targetID: UUID
        let projectID: String
        let card: SessionReferenceCard
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backlink-deep-link-\(UUID().uuidString)", isDirectory: true)
        let grantedDirectory = root.appendingPathComponent("granted-project", isDirectory: true)
        try FileManager.default.createDirectory(at: grantedDirectory, withIntermediateDirectories: true)
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        let handler = try #require(bridge.productionProjectSessionHandler)
        let store = try #require(bridge.chat.sessionStore)
        let sourceID = bridge.chat.applyNewSession(title: "来源会话")
        let projectID = try handler.authorizeFolderFromNativePicker(grantedDirectory)
        let project = ProjectSessionAuthorizedProject(projectID: projectID,
            displayName: "授权项目", workdirReference: "grant:\(projectID):test")
        let targetID = UUID()
        try bridge.chat.createProjectTarget(id: targetID.uuidString, title: "目标任务",
            sourceID: sourceID.uuidString, project: project, directory: grantedDirectory,
            taskID: "task-deep-link", runID: "run-deep-link")
        let card = SessionReferenceCard(id: UUID().uuidString,
            sourceSessionID: sourceID.uuidString, targetSessionID: targetID.uuidString,
            taskID: "task-deep-link", runID: "run-deep-link", projectID: projectID,
            projectTitle: "授权项目", title: "目标任务", createdAt: Date(), status: .running)
        try bridge.chat.appendSourceCard(card)
        return Fixture(root: root, grantedDirectory: grantedDirectory, bridge: bridge,
            handler: handler, store: store, sourceID: sourceID, targetID: targetID,
            projectID: projectID, card: card)
    }

    @Test("an authorized copied backlink opens through the production session switch")
    func authorizedCopiedBacklinkOpensTarget() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        #expect(value.bridge.chat.canOpenSourceCard(value.card))
        #expect(value.card.deepLink?.absoluteString ==
            "miniscanvas://session/\(value.targetID.uuidString)")
        #expect(value.card.deepLink.flatMap(DeepLinkRouter.parse(url:)) ==
            .openSession(id: value.targetID.uuidString))
        DeepLinkHandler(bridge: value.bridge).handle(.openSession(id: value.targetID.uuidString))
        #expect(value.bridge.chat.activeSessionID == value.targetID)
    }

    @Test("revoked grant disables both the card and a previously copied backlink")
    func revokedGrantBlocksCopiedBacklink() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        #expect(value.bridge.chat.canOpenSourceCard(value.card))
        try value.handler.revokeProject(id: value.projectID)
        #expect(!value.bridge.chat.canOpenSourceCard(value.card))
        DeepLinkHandler(bridge: value.bridge).handle(.openSession(id: value.targetID.uuidString))
        #expect(value.bridge.chat.activeSessionID == value.sourceID)
    }

    @Test("stale native bookmark blocks a copied backlink")
    func staleBookmarkBlocksCopiedBacklink() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let moved = value.root.appendingPathComponent("moved-project", isDirectory: true)
        try FileManager.default.moveItem(at: value.grantedDirectory, to: moved)
        #expect(!value.handler.isProjectAvailable(id: value.projectID))
        #expect(!value.bridge.chat.canOpenSourceCard(value.card))
        DeepLinkHandler(bridge: value.bridge).handle(.openSession(id: value.targetID.uuidString))
        #expect(value.bridge.chat.activeSessionID == value.sourceID)
    }

    @Test("deleted canonical target cannot be reopened from an in-memory session")
    func deletedTargetBlocksCopiedBacklink() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let preview = try value.store.previewDeletion(id: value.targetID.uuidString)
        let intent = preview.withFirstConfirmation("已核对这份预览")
            .withSecondConfirmation("永久删除")
        _ = try value.store.deleteSession(id: value.targetID.uuidString, intent: intent)
        #expect(value.bridge.chat.sessions.contains { $0.id == value.targetID })
        #expect(!value.bridge.chat.canOpenSourceCard(value.card))
        DeepLinkHandler(bridge: value.bridge).handle(.openSession(id: value.targetID.uuidString))
        #expect(value.bridge.chat.activeSessionID == value.sourceID)
        #expect(value.store.loadSession(id: value.targetID.uuidString) == nil)
    }

    @Test("ordinary legacy session still opens without a project grant")
    func ordinarySessionKeepsLegacyDeepLinkRoute() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let legacyID = value.bridge.chat.applyNewSession(title: "普通会话")
        #expect(value.bridge.chat.applySwitchSession(id: value.sourceID))
        try value.handler.revokeProject(id: value.projectID)
        DeepLinkHandler(bridge: value.bridge).handle(.openSession(id: legacyID.uuidString))
        #expect(value.bridge.chat.activeSessionID == legacyID)
    }
}
