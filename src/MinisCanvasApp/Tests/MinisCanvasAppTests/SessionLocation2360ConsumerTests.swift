import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SESSION-13 session location outputs")
@MainActor
struct SessionLocation2360ConsumerTests {
    private func fixture() throws -> (URL, BridgeStore, SessionStore, UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("会话 定位 2360 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
        bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        let store = try #require(bridge.chat.sessionStore)
        let id = bridge.chat.applyNewSession(
            title: "中文 空格 会话", projectID: "synthetic-project",
            projectName: "合成项目",
            workingDirectory: root.path
        )
        bridge.chat.appendUser("合成消息")
        return (root, bridge, store, id)
    }

    @Test("actual copy and Finder commands emit canonical values into owned outputs")
    func copyAndRevealUseCanonicalSession() throws {
        let (root, bridge, store, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var copied: [String] = []
        var revealed: [URL] = []
        bridge.chat.sessionTextOutput = { copied.append($0) }
        bridge.chat.sessionFinderOutput = { revealed.append($0) }

        #expect(bridge.chat.copySessionID(id))
        #expect(bridge.chat.copySessionDeepLink(id))
        bridge.chat.revealSessionInFinder(id)

        let link = try #require(URL(string: copied[1]))
        #expect(copied[0] == id.uuidString)
        #expect(copied[1] == "miniscanvas://session/\(id.uuidString)")
        #expect(DeepLinkRouter.parse(url: link) == .openSession(id: id.uuidString))
        #expect(!copied[1].contains("合成项目"))
        #expect(!copied[1].contains(root.path))
        let expectedFile = store.sessionsDirectory
            .appendingPathComponent("\(id.uuidString).json").standardizedFileURL
        #expect(revealed == [expectedFile])
        #expect(expectedFile.absoluteString.contains("%20"))

        let unknown = UUID()
        #expect(!bridge.chat.copySessionID(unknown))
        #expect(!bridge.chat.copySessionDeepLink(unknown))
        bridge.chat.revealSessionInFinder(unknown)
        #expect(copied.count == 2)
        #expect(revealed.count == 1)
        #expect(DeepLinkRouter.parse(url: URL(string: copied[1] + "?endpoint=https://elsewhere.invalid")!) == nil)
    }

    @Test("copied link resolves after a new store loads the same persisted session")
    func copiedLinkSurvivesReloadAndArchivedTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("会话 重开 2360 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var copied = ""
        let id: UUID
        do {
            let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
            bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
            id = bridge.chat.applyNewSession(title: "归档后重开")
            bridge.chat.appendUser("合成消息")
            bridge.chat.sessionTextOutput = { copied = $0 }
            #expect(bridge.chat.copySessionDeepLink(id))
            bridge.chat.archiveSession(id: id)
            #expect(bridge.chat.archivedSessions.contains { $0.id == id })
        }

        let reopened = BridgeStore(agentTaskStore: AgentTaskStore())
        reopened.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: root)
        #expect(reopened.chat.archivedSessions.contains { $0.id == id })
        let action = try #require(DeepLinkRouter.parse(url: URL(string: copied)!))
        DeepLinkHandler(bridge: reopened).handle(action)
        #expect(reopened.chat.activeSessionID == id)
        #expect(reopened.chat.sessions.contains { $0.id == id })
        #expect(!reopened.chat.archivedSessions.contains { $0.id == id })
    }
}
