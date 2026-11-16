import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Synthetic durable settings -> production assembly -> fresh executor.
/// The callback substitutes only the production profile's paths: invoking
/// bindFileAccessSettings with .production would touch real session storage,
/// while disposable profiles deliberately do not consume user file roots.
/// This does not establish the packaged profile/on-screen unmount journey.
@Suite("D-PRIVACY-04 durable unmount production assembly", .serialized)
@MainActor
struct PrivacyProductionFileAccess297Tests {
    /// AgentLoopChatEngine is a value. Observe its actual production builtin
    /// owner through the existing executor ownership contract instead.
    private func builtinOwner(of executor: any ToolExecutor) -> BuiltinToolExecutor? {
        if let concurrent = executor as? ConcurrentToolLimitingExecutor {
            return builtinOwner(of: concurrent.baseBox.value)
        }
        return (executor as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
    }

    @Test("committed unmount replaces the next executor and rejects every file tool")
    func committedUnmountRejectsFreshFileDispatchWithoutMutation() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory
            .appendingPathComponent("Privacy297-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let mounted = root.appendingPathComponent("mounted", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: true)
        let suiteName = "Privacy297.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let logManager = LogManager(directory: root.appendingPathComponent("logs"))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: logManager,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(suiteName)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
        #expect(center.setFileAccessAllowedRoot(workspace.path))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: logManager,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("sessions")),
            canvasRuntimeState: .disabled,
            memoryStore: center.memoryStore, memoryProposalConsumer: center.memoryProposalConsumer,
            providerReadinessStore: center.providerReadinessStore,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-center-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        #expect(bridge.canvasIfAvailable == nil)
        var callbacks = 0
        var durableMountsAtCallback: [[String]] = []
        center.onFileAccessSettingsChanged = {
            callbacks += 1
            durableMountsAtCallback.append(
                SettingsStore(directory: root.appendingPathComponent("settings"))
                    .settings.privacy.mountedFolderPaths
            )
            ProductionOrchestrationDefaults.attachProductionServices(
                to: bridge,
                agentSettings: center.settings.agent,
                fileAccessAllowedRoot: center.fileAccessAllowedRoot.map { URL(fileURLWithPath: $0) },
                fileAccessDeniedRoots: center.runtimeDeniedRoots.map { URL(fileURLWithPath: $0) },
                fileAccessMountedRoots: center.effectiveMountedFolders.map { URL(fileURLWithPath: $0) },
                sessionDirectory: root.appendingPathComponent("sessions"),
                mcpManager: center.mcpManager,
                skillStore: center.skillStore,
                canvasRuntimeState: .disabled,
                childConcurrencySelection: center.childConcurrencySelection,
                externalNetworkAllowed: false,
                sessionReadSecretStore: center.envStore
            )
        }
        defer { center.onFileAccessSettingsChanged = nil }
        #expect(center.mountFolder(mounted.path))
        #expect(callbacks == 1)
        #expect(durableMountsAtCallback == [[mounted.path]])
        // File dispatch requires the same Core-minted parent source identity as
        // production. This source is durable only in this synthetic profile.
        let sourceID = try #require(bridge.chat.activeSessionID).uuidString
        let sourceStore = try #require(bridge.chat.sessionStore)
        if sourceStore.loadSession(id: sourceID) == nil {
            _ = try sourceStore.createSession(id: sourceID, title: "Privacy297 synthetic source")
        }
        #expect(sourceStore.loadSession(id: sourceID) != nil)
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let runtime = AgentExecutionContextSnapshot(
            provider: MockProvider.shared, approvalGate: nil,
            turnController: controller, currentConversationID: sourceID,
            makeChildBudget: nil, deadline: Date().addingTimeInterval(60),
            parentTurnHandle: handle,
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: sourceID, conversationID: sourceID,
                turnID: "turn-handle:\(handle.turnID)",
                taskID: "privacy297-file-dispatch", actorID: "app"
            )
        )
        #expect(runtime.hasVerifiedParentRuntime)
        do {
            try await AgentExecutionContext.$current.withValue(runtime) {
                let before = try #require(bridge.productionBuiltinToolExecutor)
                let beforeEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
                let beforeEngineOwner = try #require(builtinOwner(of: beforeEngine.composedExecutor))
                #expect(beforeEngineOwner === before)
                let note = mounted.appendingPathComponent("note.txt")
                try "unchanged".write(to: note, atomically: true, encoding: .utf8)
                // Dispatch through the real composition chain, whose existing ownership
                // contract keeps the non-Sendable builtin on the production executor route.
                #expect(try await beforeEngine.composedExecutor.execute(name: "file_read", input: ["path": note.path]) == "unchanged")

                center.unmountFolder(mounted.path)
                await bridge.lastChildGovernorSafetyTask?.value
                #expect(callbacks == 2)
                #expect(durableMountsAtCallback == [[mounted.path], []])
                let after = try #require(bridge.productionBuiltinToolExecutor)
                let afterEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
                let afterEngineOwner = try #require(builtinOwner(of: afterEngine.composedExecutor))
                #expect(after !== before)
                #expect(afterEngineOwner === after)
                #expect(afterEngineOwner !== beforeEngineOwner)
                #expect(after.additionalAllowedRoots.isEmpty)
                let afterBuiltinBox = ToolExecutorBox(value: after)
                await #expect(throws: ToolExecutorError.invalidParameter("Policy violation: fileRootNotAllowed")) {
                    _ = try await afterEngine.composedExecutor.execute(name: "file_read", input: ["path": note.path])
                }
                await #expect(throws: ToolExecutorError.pathViolation(note.path)) {
                    _ = try await afterBuiltinBox.value.execute(name: "file_read", input: ["path": note.path])
                }
                let target = mounted.appendingPathComponent("nested/new.txt")
                await #expect(throws: ToolExecutorError.invalidParameter("Policy violation: fileRootNotAllowed")) {
                    _ = try await afterEngine.composedExecutor.execute(name: "file_write", input: ["path": target.path, "content": "blocked", "create_dirs": true])
                }
                await #expect(throws: ToolExecutorError.pathViolation(target.path)) {
                    _ = try await afterBuiltinBox.value.execute(name: "file_write", input: [
                        "path": target.path, "content": "blocked", "create_dirs": true
                    ])
                }
                await #expect(throws: ToolExecutorError.invalidParameter("Policy violation: fileRootNotAllowed")) {
                    _ = try await afterEngine.composedExecutor.execute(name: "file_edit", input: ["path": note.path, "old_string": "unchanged", "new_string": "changed"])
                }
                await #expect(throws: ToolExecutorError.pathViolation(note.path)) {
                    _ = try await afterBuiltinBox.value.execute(name: "file_edit", input: [
                        "path": note.path, "old_string": "unchanged", "new_string": "changed"
                    ])
                }
                #expect(try String(contentsOf: note, encoding: .utf8) == "unchanged")
                #expect(!FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))

                // A genuinely new grant is required to restore access; refusal is not sticky.
                #expect(center.mountFolder(mounted.path))
                await bridge.lastChildGovernorSafetyTask?.value
                #expect(callbacks == 3)
                let remounted = try #require(bridge.productionBuiltinToolExecutor)
                let remountedEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
                let remountedEngineOwner = try #require(builtinOwner(of: remountedEngine.composedExecutor))
                #expect(remounted !== after)
                #expect(remountedEngineOwner === remounted)
                #expect(remountedEngineOwner !== afterEngineOwner)
                #expect(try await remountedEngine.composedExecutor.execute(name: "file_read", input: ["path": note.path]) == "unchanged")
            }
            await handle.finish()
        } catch {
            await handle.finish()
            throw error
        }
    }
}
