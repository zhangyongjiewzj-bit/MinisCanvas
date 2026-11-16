import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Command session list uses the App's attached profile store", .serialized)
@MainActor
struct CommandSessionListIsolation2239Tests {
    @Test("menu registry lists only the injected session root, before and after Chat attachment")
    func sessionListCannotReadAmbientRoot() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent(
            "command-session-list-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let owned = SessionStore(directory: root.appendingPathComponent("owned", isDirectory: true))
        let ownedA = try owned.createSession(title: "2239-owned-alpha")
        let ownedB = try owned.createSession(title: "2239-owned-beta")

        // The former CommandDependencies default must remain wholly synthetic
        // in a formal test. Its known foreign fixture distinguishes an ambient
        // fallback from the App-owned store without reading user sessions.
        let ambientDirectory = SessionStore.defaultDirectory
        #expect(ambientDirectory.path.hasPrefix(profile.rootDirectory.path + "/"))
        #expect(ambientDirectory.standardizedFileURL != owned.directory.standardizedFileURL)
        let ambient = SessionStore(directory: ambientDirectory)
        let foreign = try ambient.createSession(title: "2239-foreign-only")
        defer { try? ambient.deleteSessionForMaintenance(id: foreign.id) }

        let suiteName = "command-session-list-2239-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: owned.directory),
            sessionStore: owned,
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            canvasFeatureLane: .phase3NonCanvas
        )

        let beforeAttach = try await bridge.commandRegistry.execute(id: "session.list")
        #expect(beforeAttach.ok)
        #expect(beforeAttach.text.contains("会话（2 个）"))
        #expect(beforeAttach.text.contains(ownedA.title))
        #expect(beforeAttach.text.contains(ownedB.title))
        #expect(!beforeAttach.text.contains(foreign.title))

        #expect(bridge.chat.attachPersistence(owned, badgeStore: bridge.sessionBadgeStore))
        #expect(bridge.chat.sessionStore === owned)
        let afterAttach = try await bridge.commandRegistry.execute(id: "session.list")
        #expect(afterAttach.ok)
        #expect(afterAttach.text.contains("会话（\(owned.listSessions().count) 个）"))
        #expect(!afterAttach.text.contains(foreign.title))
        for item in bridge.chat.sessionList {
            #expect(afterAttach.text.contains(String(item.session.id.uuidString.prefix(8))))
        }

        // An absent owner is a failure result, even when the formal test's
        // ambient synthetic root contains a known foreign session.
        let withoutOwner = CommandRegistry(commands: PresetCommands.all(
            dependencies: CommandDependencies(sessions: nil)
        ))
        let denied = try await withoutOwner.execute(id: "session.list")
        #expect(!denied.ok)
        #expect(denied.text == "会话存储未配置")
    }
}
