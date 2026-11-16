import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// D-5：右栏文件页跟随会话项目目录，不再回落到进程工作目录。
@Suite("Goal18 file tree follows the session root", .serialized)
@MainActor
struct Goal18FileTreeSessionRootTests {
    @Test func productionTaskScopeFollowsProjectAndKeepsPersistentRulesSeparate() async throws {
        let fixture = try await projectScopeFixture()
        let bridge = fixture.bridge
        let chat = bridge.chat
        let root = fixture.profile.rootDirectory.resolvingSymlinksInPath()
        let a = root.appendingPathComponent("project-a", isDirectory: true)
        let b = root.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let session = try #require(chat.activeSessionID)
        let prepare = try #require(chat.prepareTopLevelTaskPolicy)
        let rules = PersistentApprovalRuleStore(fileURL: root.appendingPathComponent("rules/rules.json"))
        let input: [String: Any] = ["command": "git status"]
        var capturedA: ComposerPolicyFactSource?
        for (index, directory) in [a, b, a].enumerated() {
            chat.setProject(.init(id: directory.lastPathComponent, name: directory.lastPathComponent,
                workingDirectory: directory.path), forSession: session)
            try #require(prepare("project-scope-\(index)", Date(), nil, false))
            let facts = chat.composerPolicyFacts
            #expect(facts.allowedWriteRoots == [directory.path])
            if index == 0 {
                capturedA = facts
                let rule = try #require(rules.makeRule(capability: "shell_execute", input: input, facts: facts))
                try #require(rules.add(rule))
            }
            #expect((rules.match(capability: "shell_execute", input: input, facts: facts) != nil) == (index != 1))
        }
        #expect(capturedA?.allowedWriteRoots == [a.path])
        chat.setProject(nil, forSession: session)
        try #require(prepare("project-scope-fallback", Date(), nil, false))
        #expect(chat.composerPolicyFacts.allowedWriteRoots == [root.path])
        #expect(rules.match(capability: "shell_execute", input: input, facts: chat.composerPolicyFacts) == nil)
    }

    @Test func projectSelectionCannotWidenTheInstalledSafetyCeiling() async throws {
        let mounted = try root("mounted-project").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: mounted) }
        let fixture = try await projectScopeFixture(mountedRoot: mounted)
        let chat = fixture.bridge.chat
        let session = try #require(chat.activeSessionID)
        let outside = fixture.profile.rootDirectory.deletingLastPathComponent()
        let prepare = try #require(chat.prepareTopLevelTaskPolicy)
        chat.setProject(.init(id: "mounted", name: "mounted", workingDirectory: mounted.path), forSession: session)
        try #require(prepare("mounted-project", Date(), nil, false))
        #expect(chat.composerPolicyFacts.allowedWriteRoots == [mounted.path])
        let before = chat.composerPolicyFacts
        chat.setProject(.init(id: "outside", name: "outside", workingDirectory: outside.path), forSession: session)
        #expect(!prepare("outside-project", Date(), nil, false))
        #expect(chat.composerPolicyFacts == before)
        chat.setProject(nil, forSession: session)
        try #require(prepare("mounted-fallback", Date(), nil, false))
        #expect(Set(chat.composerPolicyFacts.allowedWriteRoots.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }) == Set([fixture.profile.rootDirectory.resolvingSymlinksInPath().path, mounted.path]))
    }

    private func projectScopeFixture(mountedRoot: URL? = nil) async throws -> (profile: RuntimeIsolationProfile, bridge: BridgeStore) {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "Goal19ProjectScope",
            processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let sessions = SessionStore(directory: profile.sessionDirectory)
        _ = try sessions.createSession(id: UUID().uuidString, title: "project scope")
        let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
        let bridge = BridgeStore(shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
            sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            agentTaskStore: try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: profile.rootDirectory.appendingPathComponent("manifest.json")),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() })
        try #require(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        // No credentials, provider, network or UI: exercise the installed
        // production task producer and its real rule-store consumer.
        await bridge.attachProductionServices(fileAccessAllowedRoot: profile.rootDirectory,
            fileAccessDeniedRoots: [], fileAccessMountedRoots: mountedRoot.map { [$0] } ?? [],
            sessionDirectory: profile.sessionDirectory,
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: profile.makeKeychainStore()),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false).value
        return (profile, bridge)
    }

    private func root(_ marker: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g18-file-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(marker.utf8).write(to: url.appendingPathComponent("\(marker).txt"))
        return url
    }

    private func settledNames(in store: FileTreeStore, expecting name: String) async -> [String] {
        for _ in 0..<100 {
            let names = store.rootNodes.map(\.name)
            if names.contains(name) { return names }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return store.rootNodes.map(\.name)
    }

    @Test("without a session root the tree is empty instead of the process directory")
    func noSessionRootDoesNotScanProcessDirectory() async throws {
        let store = FileTreeStore()
        store.followSession(root: nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.rootURL == nil)
        #expect(store.rootNodes.isEmpty)
    }

    @Test("session working directory resolves to a root only when it names an existing directory")
    func sessionRootResolution() throws {
        let existing = try root("resolved-project")
        defer { try? FileManager.default.removeItem(at: existing) }
        #expect(FileTreeStore.sessionRoot(path: nil) == nil)
        #expect(FileTreeStore.sessionRoot(path: "") == nil)
        #expect(FileTreeStore.sessionRoot(path: "  \n") == nil)
        #expect(FileTreeStore.sessionRoot(path: existing.appendingPathComponent("missing").path) == nil)
        #expect(FileTreeStore.sessionRoot(path: " \(existing.path) ")?.path == existing.path)
    }

    @Test("a manual root stays until the session root changes; repeating the same root is a no-op")
    func manualRootAndRepeatedFollow() async throws {
        let session = try root("session-project")
        let manual = try root("manual-project")
        defer {
            try? FileManager.default.removeItem(at: session)
            try? FileManager.default.removeItem(at: manual)
        }
        let store = FileTreeStore()
        store.followSession(root: session)
        _ = await settledNames(in: store, expecting: "session-project.txt")
        store.selectedURL = session.appendingPathComponent("session-project.txt")
        store.followSession(root: session)
        #expect(store.selectedURL != nil)

        store.changeRoot(manual)
        #expect(await settledNames(in: store, expecting: "manual-project.txt") == ["manual-project.txt"])
        store.followSession(root: session)
        #expect(await settledNames(in: store, expecting: "session-project.txt") == ["session-project.txt"])
    }

    @Test("switching sessions moves the tree to the new project directory")
    func followsSessionRootChanges() async throws {
        let first = try root("first-project")
        let second = try root("second-project")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let store = FileTreeStore()

        store.followSession(root: first)
        #expect(await settledNames(in: store, expecting: "first-project.txt") == ["first-project.txt"])

        store.followSession(root: second)
        #expect(store.rootURL?.standardizedFileURL == second.standardizedFileURL)
        #expect(await settledNames(in: store, expecting: "second-project.txt") == ["second-project.txt"])

        store.followSession(root: nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.rootURL == nil)
        #expect(store.rootNodes.isEmpty)
    }
}
