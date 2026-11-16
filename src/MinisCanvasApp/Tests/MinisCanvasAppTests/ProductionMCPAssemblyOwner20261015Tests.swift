import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("ARCH1 original assembly MCP owner admission", .serialized)
@MainActor
struct ProductionMCPAssemblyOwner20261015Tests {
    private enum Route: CaseIterable { case primary, degraded, blocked }

    @MainActor
    private struct Inputs {
        let profile: RuntimeIsolationProfile
        let defaults: UserDefaults
        let shortcuts: ShortcutStore
        let sessions: SessionStore
        let badges: SessionBadgeStore
        let log: LogManager
        let workflows: WorkflowStore
        let settings: SettingsCenter
        let secondSettings: SettingsCenter
        let skills: SkillsStore
        let scheduler: SchedulerTaskStore

        init(label: String) throws {
            _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
            profile = try RuntimeIsolationProfile.makeIsolatedTest(label: label, canvasRuntimeState: .disabled)
            defaults = profile.makeUserDefaults()
            shortcuts = ShortcutStore(defaults: defaults)
            sessions = SessionStore(directory: profile.sessionDirectory)
            badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
            log = profile.makeLogManager()
            workflows = WorkflowStore.startForAppBootstrap(
                storeDirectory: profile.minisCanvasDirectory.appendingPathComponent("Workflows"))
            let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
            settings = ProductionDomainAssembly.makeSettings(
                profile: profile, keychain: KeychainStore(backing: InMemoryKeychainBacking()),
                sessionStore: sessions, sessionBadgeStore: badges, logManager: log,
                store: shortcuts, readinessTransport: FailClosedProviderReadinessTransport(),
                providerReadinessStore: readiness)
            // A second original composition over the same profile, not an
            // arbitrary library manager pretending to be an App owner.
            secondSettings = ProductionDomainAssembly.makeSettings(
                profile: profile, keychain: KeychainStore(backing: InMemoryKeychainBacking()),
                sessionStore: sessions, sessionBadgeStore: badges, logManager: log,
                store: shortcuts, readinessTransport: FailClosedProviderReadinessTransport(),
                providerReadinessStore: readiness)
            skills = SkillsStore(
                appStore: settings.skillStore, stateFileURL: profile.skillStateURL, loadImmediately: false)
            scheduler = SchedulerTaskStore(defaults: defaults,
                occurrenceLedgerURL: profile.minisCanvasDirectory.appendingPathComponent("scheduler-occurrences-v1.json"))
        }

        func bridge(route: Route) throws -> BridgeStore {
            if route == .degraded {
                try FileManager.default.createDirectory(at: profile.agentTaskStorePersistenceURL,
                    withIntermediateDirectories: true)
            }
            return ProductionDomainAssembly.makeBridge(
                profile: profile, bootstrapFailure: route == .blocked ? .unexpectedProfileResolution : nil,
                settings: settings, store: shortcuts, defaults: defaults, skillsStore: skills,
                schedulerStore: scheduler, logManager: log, workflowStore: workflows,
                sessionBadgeStore: badges, sessionStore: sessions)
        }

        func attach(to bridge: BridgeStore, manager: MCPServerManager?) -> Task<Void, Never> {
            ProductionOrchestrationDefaults.attachProductionServices(
                to: bridge, fileAccessAllowedRoot: profile.rootDirectory,
                sessionDirectory: sessions.directory, mcpManager: manager,
                skillStore: settings.skillStore, canvasRuntimeState: .disabled,
                externalNetworkAllowed: false, sessionReadSecretStore: settings.envStore)
        }

        func documentBytes() throws -> [String: Data] {
            var output: [String: Data] = [:]
            for url in [settings.settingsStore.fileURL,
                        settings.mcpManager.fileURL, settings.mcpManager.authorizationFileURL] {
                if FileManager.default.fileExists(atPath: url.path) {
                    output[url.lastPathComponent] = try Data(contentsOf: url)
                }
            }
            return output
        }
    }

    private func registry(_ bridge: BridgeStore) throws -> MCPToolRegistry {
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let turnBridge = try #require(engine.mcpBridge as? TurnScopedMCPToolBridge)
        return try #require(turnBridge.base as? MCPToolRegistry)
    }

    @Test("original primary, degraded and blocked factories reject another MCP writer before assembly mutation")
    func secondOriginalAssemblyMCPWriterIsTypedRejectedOnAllLaunchRoutes() async throws {
        for route in Route.allCases {
            let inputs = try Inputs(label: "arch1-mcp-owner-\(route)")
            defer { try? inputs.profile.cleanupDisposableRoots() }
            _ = inputs.settings.settingsStore.update(\.agent.maxLoopIterations, to: 25)
            _ = try inputs.settings.mcpManager.addServer(MCPServer(id: "owned-assembly-mcp",
                name: "Owned assembly fact", type: .http, enabled: false, url: "http://127.0.0.1:9"))
            let bridge = try inputs.bridge(route: route)
            #expect(inputs.secondSettings.mcpManager !== inputs.settings.mcpManager)
            #expect(inputs.secondSettings.mcpManager.fileURL == inputs.settings.mcpManager.fileURL)
            await inputs.attach(to: bridge, manager: inputs.settings.mcpManager).value
            #expect(bridge.productionMCPWriterAdmission == .admitted)
            #expect(try registry(bridge).manager === inputs.settings.mcpManager)
            // Same-object reattach is legal; no global ban on creating public
            // managers or a new production registry is introduced.
            await inputs.attach(to: bridge, manager: inputs.settings.mcpManager).value
            #expect(bridge.productionMCPWriterAdmission == .admitted)
            let beforeRegistry = try registry(bridge)
            let beforeIdentity = try #require(beforeRegistry.runtimeIdentity)
            let beforeEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
            let beforeRevision = bridge.childGovernorControlRevision
            let beforeQueued = bridge.childConcurrencySelection.runtime?.queued
            let beforeRunning = bridge.childConcurrencySelection.runtime?.actualRunning
            let beforeHandler = bridge.productionProjectSessionHandler
            let beforeDocuments = try inputs.documentBytes()
            // Admission is synchronous at the original entry point: examine
            // existing public facts before the no-op Task yields to other work.
            let rejected = inputs.attach(to: bridge, manager: inputs.secondSettings.mcpManager)
            #expect(bridge.productionMCPWriterAdmission == .rejected(.conflictingMCPWriter))
            #expect(try registry(bridge) === beforeRegistry)
            #expect(try registry(bridge).runtimeIdentity == beforeIdentity)
            // AgentLoopChatEngine is a value. Observe its real shared control,
            // writeback and MCP dependencies; do not claim whole-value identity.
            let afterEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
            #expect(afterEngine.turnController === beforeEngine.turnController)
            #expect(afterEngine.turnRegistry === beforeEngine.turnRegistry)
            #expect(afterEngine.contextWritebackGate === beforeEngine.contextWritebackGate)
            let beforeTurnBridge = try #require(beforeEngine.mcpBridge as? TurnScopedMCPToolBridge)
            let afterTurnBridge = try #require(afterEngine.mcpBridge as? TurnScopedMCPToolBridge)
            #expect(afterTurnBridge === beforeTurnBridge)
            #expect(bridge.childGovernorControlRevision == beforeRevision)
            #expect(bridge.childConcurrencySelection.runtime?.queued == beforeQueued)
            #expect(bridge.childConcurrencySelection.runtime?.actualRunning == beforeRunning)
            #expect(bridge.productionProjectSessionHandler === beforeHandler)
            #expect(try inputs.documentBytes() == beforeDocuments)
            await rejected.value
            #expect(bridge.productionMCPWriterAdmission == .rejected(.conflictingMCPWriter))
            #expect(try registry(bridge) === beforeRegistry)
            #expect(try registry(bridge).manager === inputs.settings.mcpManager)
            #expect(try inputs.documentBytes() == beforeDocuments)
            let digests = beforeDocuments.keys.sorted().map {
                $0 + "=" + DeletionGate.fingerprint(beforeDocuments[$0]!)
            }
            print("ARCH_MCP_ASSEMBLY_REJECT route=\(route) error=conflictingMCPWriter registryOwner=\(beforeIdentity.ownerID) registryGeneration=\(beforeIdentity.generation) queuedBefore=\(String(describing: beforeQueued)) actualBefore=\(String(describing: beforeRunning)) documents=" + digests.joined(separator: " "))
            // A rejected different owner cannot poison the original owner.
            // Omitting manager resolves to the factory's pinned instance.
            await inputs.attach(to: bridge, manager: nil).value
            #expect(bridge.productionMCPWriterAdmission == .admitted)
            #expect(try registry(bridge).manager === inputs.settings.mcpManager)
            #expect(try inputs.documentBytes() == beforeDocuments)
        }
    }
}
