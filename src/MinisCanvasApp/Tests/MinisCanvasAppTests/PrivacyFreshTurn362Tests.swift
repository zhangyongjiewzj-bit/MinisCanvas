import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Adds a new Core-minted task identity after unmount to the existing 297
/// assembly proof. This is not the packaged SettingsView gesture or a bypass
/// of the fixed disposable file-access root.
@Suite("D-PRIVACY-04 fresh parent turn after durable unmount", .serialized)
@MainActor
struct PrivacyFreshTurn362Tests {
    private func context(sourceID: String, controller: TurnController,
                         handle: TurnController.TurnHandle) -> AgentExecutionContextSnapshot {
        AgentExecutionContextSnapshot(
            provider: MockProvider.shared, approvalGate: nil,
            turnController: controller, currentConversationID: sourceID,
            makeChildBudget: nil, deadline: Date().addingTimeInterval(60),
            parentTurnHandle: handle,
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: sourceID, conversationID: sourceID,
                turnID: "turn-handle:\(handle.turnID)",
                taskID: "privacy362-task-\(handle.turnID)", actorID: "app"
            )
        )
    }

    @Test func unmountRefusesANewTaskWhileItsOrdinaryWorkspaceRemainsUsable() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Privacy362", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName {
                defaults.removePersistentDomain(forName: suite)
            }
            try? profile.cleanupDisposableRoots()
        }
        let keychain = profile.makeKeychainStore()
        let logManager = profile.makeLogManager()
        let readinessStore = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.minisCoreDirectory, keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: logManager,
            mcpManager: MCPServerManager(fileURL: profile.mcpDirectory.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: readinessStore
        )
        let workspace = profile.rootDirectory.appendingPathComponent("workspace")
        let mounted = profile.rootDirectory.appendingPathComponent("mounted")
        for root in [workspace, mounted] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let local = workspace.appendingPathComponent("local.txt")
        let external = mounted.appendingPathComponent("external.txt")
        try "local-control".write(to: local, atomically: true, encoding: .utf8)
        try "mounted-before-unmount".write(to: external, atomically: true, encoding: .utf8)
        #expect(center.setFileAccessAllowedRoot(workspace.path))
        let workflowStore = WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("Workflows"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: logManager,
            workflowStore: workflowStore,
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            agentTaskStore: AgentTaskStore(), contextManifestStore: ContextManifestStore(),
            memoryStore: center.memoryStore, memoryProposalConsumer: center.memoryProposalConsumer,
            providerReadinessStore: readinessStore,
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        #expect(bridge.workflowChat.workflowStore === workflowStore)
        #expect(bridge.canvasIfAvailable == nil)
        // Preserve the real profile boundary: this test does not make an
        // isolated profile consume user settings. Only the existing assembly
        // seam is invoked below with paths that this fixture owns.
        ProductionOrchestrationDefaults.bindFileAccessSettings(to: bridge, settings: center, profile: profile)
        // Goal19: owned isolated settings now bind G1 commits; privacy roots
        // remain fixed. This fixture still replaces the callback below to
        // exercise its original synthetic mounted-folder assembly contract.
        #expect(center.onFileAccessSettingsChanged != nil)
        var commits: [[String]] = []
        center.onFileAccessSettingsChanged = {
            commits.append(SettingsStore(directory: profile.settingsDirectory).settings.privacy.mountedFolderPaths)
            ProductionOrchestrationDefaults.attachProductionServices(
                to: bridge, agentSettings: center.settings.agent,
                fileAccessAllowedRoot: workspace,
                fileAccessDeniedRoots: center.runtimeDeniedRoots.map { URL(fileURLWithPath: $0) },
                fileAccessMountedRoots: center.effectiveMountedFolders.map { URL(fileURLWithPath: $0) },
                sessionDirectory: profile.sessionDirectory,
                mcpManager: center.mcpManager, skillStore: center.skillStore,
                canvasRuntimeState: .disabled, childConcurrencySelection: center.childConcurrencySelection,
                externalNetworkAllowed: false, sessionReadSecretStore: center.envStore
            )
        }
        defer { center.onFileAccessSettingsChanged = nil }
        #expect(center.mountFolder(mounted.path))
        let sourceID = try #require(bridge.chat.activeSessionID).uuidString
        let sourceStore = try #require(bridge.chat.sessionStore)
        if sourceStore.loadSession(id: sourceID) == nil {
            _ = try sourceStore.createSession(id: sourceID, title: "synthetic Privacy362 source")
        }
        let controller = TurnController()
        let first = await controller.beginTurn()
        let firstContext = context(sourceID: sourceID, controller: controller, handle: first)
        #expect(firstContext.hasVerifiedParentRuntime)
        do {
            try await AgentExecutionContext.$current.withValue(firstContext) {
                let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
                #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": external.path]) == "     1\tmounted-before-unmount")
            }
            await first.finish()
        } catch {
            await first.finish()
            throw error
        }
        center.unmountFolder(mounted.path)
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(commits == [[mounted.path], []])
        #expect(SettingsStore(directory: profile.settingsDirectory).settings.privacy.mountedFolderPaths.isEmpty)
        let before = try Data(contentsOf: external)
        let second = await controller.beginTurn()
        let secondContext = context(sourceID: sourceID, controller: controller, handle: second)
        #expect(second.turnID != first.turnID)
        #expect(secondContext.parentRuntimeIdentity != firstContext.parentRuntimeIdentity)
        #expect(secondContext.hasVerifiedParentRuntime)
        do {
            try await AgentExecutionContext.$current.withValue(secondContext) {
                let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
                // A valid same-route positive control distinguishes a revoked
                // path from rejection due to a malformed new parent identity.
                #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": local.path]) == "     1\tlocal-control")
                let refusal = ToolExecutorError.invalidParameter(PolicyEnforcedToolExecutorError.policyViolation(.fileRootNotAllowed).localizedDescription)
                await #expect(throws: refusal) {
                    _ = try await engine.composedExecutor.execute(name: "file_read", input: ["path": external.path])
                }
                await #expect(throws: refusal) {
                    _ = try await engine.composedExecutor.execute(name: "file_write", input: ["path": external.path, "content": "revoked write"])
                }
                await #expect(throws: refusal) {
                    _ = try await engine.composedExecutor.execute(name: "file_edit", input: ["path": external.path,
                                                                                          "old_string": "mounted", "new_string": "revoked"])
                }
            }
            await second.finish()
        } catch {
            await second.finish()
            throw error
        }
        #expect(try Data(contentsOf: external) == before)
        #expect(try String(contentsOf: local, encoding: .utf8) == "local-control")
    }
}
