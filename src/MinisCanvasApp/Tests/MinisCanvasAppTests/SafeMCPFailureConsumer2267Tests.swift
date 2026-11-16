import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private struct Safe2267NoNetwork: SettingsProviderReadinessTransport {
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}
private final class Safe2267MCP: MCPToolBridgeTurnSnapshotting, @unchecked Sendable {
    enum Failure { case snapshot, discovery, cancellation, heldDiscovery }
    private let lock = NSLock()
    let discoveryGate = HeldSubmissionDiagnosticPreflight()
    private var snapshotCount = 0, discoveryCount = 0, invocationCount = 0
    private var releasedDiscoveryCount = 0
    let failure: Failure
    init(failure: Failure) { self.failure = failure }
    var snapshots: Int { lock.lock(); defer { lock.unlock() }; return snapshotCount }
    var discoveries: Int { lock.lock(); defer { lock.unlock() }; return discoveryCount }
    var invocations: Int { lock.lock(); defer { lock.unlock() }; return invocationCount }
    var releasedDiscoveries: Int { lock.withLock { releasedDiscoveryCount } }
    private func observed(_ kind: Int) {
        lock.lock(); defer { lock.unlock() }
        if kind == 0 { snapshotCount += 1 }
        else if kind == 1 { discoveryCount += 1 }
        else { invocationCount += 1 }
    }
    func snapshotForTurn() throws -> any MCPToolBridge {
        observed(0)
        if failure == .snapshot { throw MCPClientError.transportNotStarted }
        return self
    }
    func mcpBoundTools() async throws -> [MCPBoundTool] {
        observed(1)
        if failure == .heldDiscovery {
            _ = await discoveryGate.read()
            lock.withLock { releasedDiscoveryCount += 1 }
            return []
        }
        if failure == .cancellation { throw CancellationError() }
        throw MCPClientError.transportNotStarted
    }
    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        observed(2)
        throw MCPClientError.toolNotFound(fullName)
    }
}

@Suite("D-SAFE2 MCP unavailable consumer2267", .serialized)
@MainActor
struct SafeMCPFailureConsumer2267Tests {
    private struct Fixture {
        let root: URL
        let center: SettingsCenter
        let bridge: BridgeStore
        let mcp: Safe2267MCP
    }
    private func fixture(locked: Bool, failure: Safe2267MCP.Failure) async throws -> Fixture {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal).appendingPathComponent("Safe2267-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let core = root.appendingPathComponent("core"), chat = root.appendingPathComponent("chat")
        let keys = KeychainStore(backing: InMemoryKeychainBacking())
        let mcp = Safe2267MCP(failure: failure)
        let center = SettingsCenter(settingsStore: SettingsStore(directory: core),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keys),
            memoryStore: MemoryStore(directory: chat), memoryFileStore: MemoryFileStore(directory: chat),
            sessionStore: SessionStore(directory: chat),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keys),
            skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessTransport: Safe2267NoNetwork(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let bridge = BridgeStore(preferencesDefaults: defaults, logManager: center.logManager,
            sessionStore: center.sessionStore, canvasRuntimeState: .disabled,
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json")),
            memoryStore: center.memoryStore,
            providerReadinessStore: center.providerReadinessStore, canvasFeatureLane: .phase3NonCanvas)
        center.onSafetyRuntimeSnapshotChanged = { _ = bridge.updateSafetyRuntimeSnapshot($0) }
        if locked { center.enableSafeMode(); center.engageKillSwitch() }
        await bridge.attachProductionServices(fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: chat, mcpManager: center.mcpManager, skillStore: center.skillStore, mcpBridgeOverride: mcp,
            canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false).value
        bridge.chat.newSession(projectID: "safe2267-project", projectName: "Owned optional failure",
            workingDirectory: root.path)
        let id = try #require(bridge.chat.activeSessionID)
        let scope = MemoryScope(sessionID: id.uuidString, projectID: "safe2267-project")
        center.memoryScopeProvider = { scope }
        bridge.chat.streamingProviderOverride = MockProvider.shared
        #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
        #expect(bridge.chat.sessionStore === center.sessionStore)
        #expect(SettingsCenter.active === center)
        #expect(bridge.isSafetyFeatureEnabled(.userSkills) == !locked)
        return Fixture(root: root, center: center, bridge: bridge, mcp: mcp)
    }
    private func run(_ f: Fixture) async throws -> ChatSession {
        let chat = f.bridge.chat
        let id = try #require(chat.activeSessionID)
        chat.draftText = "safe2267 owned unavailable"
        chat.submitComposer()
        let task = try #require(chat.turnTaskForTests(sessionID: id))
        await task.value
        #expect(!chat.isStreaming)
        return try #require(f.center.sessionStore.loadSession(id: id.uuidString))
    }
    @Test func disabledMCPDoesNotReadFailingOptionalModuleAndPersistsAssistant() async throws {
        let f = try await fixture(locked: true, failure: .snapshot)
        #expect(!f.bridge.isSafetyFeatureEnabled(.mcp))
        let saved = try await run(f)
        #expect(f.mcp.snapshots == 0 && f.mcp.discoveries == 0 && f.mcp.invocations == 0)
        #expect(saved.messages.contains { $0.role == .assistant && $0.content.contains("收到：safe2267 owned unavailable") })
        #expect(f.bridge.providerRuntimeObservations.count == 1)
    }
    @Test func enabledMCPSnapshotFailureOmitsUnavailableToolsAndPersistsAssistant() async throws {
        let f = try await fixture(locked: false, failure: .snapshot)
        #expect(f.bridge.isSafetyFeatureEnabled(.mcp))
        let saved = try await run(f)
        #expect(f.mcp.snapshots == 1 && f.mcp.discoveries == 0 && f.mcp.invocations == 0)
        #expect(saved.messages.contains { $0.role == .assistant && $0.content.contains("收到：safe2267 owned unavailable") })
        #expect(f.bridge.providerRuntimeObservations.count == 1)
    }
    @Test func enabledMCPDiscoveryUnavailableKeepsBuiltinChatAndPersistsAssistant() async throws {
        let f = try await fixture(locked: false, failure: .discovery)
        let saved = try await run(f)
        #expect(f.mcp.snapshots == 1 && f.mcp.discoveries == 1 && f.mcp.invocations == 0)
        #expect(saved.messages.contains { $0.role == .assistant && $0.content.contains("收到：safe2267 owned unavailable") })
        #expect(f.bridge.providerRuntimeObservations.count == 1)
    }
    @Test func discoveryCancellationStillRejectsTurnBeforeProvider() async throws {
        let f = try await fixture(locked: false, failure: .cancellation)
        let saved = try await run(f)
        #expect(f.mcp.snapshots == 1 && f.mcp.discoveries == 1 && f.mcp.invocations == 0)
        #expect(!saved.messages.contains { $0.role == .assistant && $0.content.contains("收到：safe2267 owned unavailable") })
        #expect(f.bridge.providerRuntimeObservations.isEmpty)
    }

    @Test func heldCatalogDoesNotAdmitTurnOrConsumeBackgroundResultBeforeProviderDispatch() async throws {
        let f = try await fixture(locked: false, failure: .heldDiscovery)
        let chat = f.bridge.chat
        let sessionID = try #require(chat.activeSessionID)
        try #require(f.bridge.isSafetyFeatureEnabled(.mcp))
        let child = SubAgentTask(id: "deadline-child", title: "Owned background result", instructions: "synthetic")
        let report = SubAgentReport(taskID: child.id, agentType: .builtin, duration: 1,
            result: .succeeded(output: "owned result"), parentID: "deadline-parent",
            runID: "deadline-child-run", attemptID: "deadline-child-attempt")
        let owner = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: sessionID.uuidString, turnID: 1, messageID: "deadline-owner"))
        let notice = BackgroundChildResultNotice(sourceSessionID: sessionID.uuidString,
            executionIdentity: owner, task: child, parentID: "deadline-parent", report: report)
        chat.receiveBackgroundResult(notice)
        try #require(chat.pendingBackgroundResults[sessionID] == [notice])

        let draft = "safe2267 held MCP directory"
        chat.draftText = draft
        var admission: Bool?
        let started = ContinuousClock.now
        let submission = Task {
            admission = await chat.submitComposerAwaitingAdmission(literal: true)
        }
        defer {
            chat.stopStreamingPreservingQueue()
            submission.cancel()
            Task { await f.mcp.discoveryGate.finish() }
        }
        let entryLimit = started + .seconds(5)
        while !(await f.mcp.discoveryGate.isPending()) && ContinuousClock.now < entryLimit {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await f.mcp.discoveryGate.isPending())
        try #require(f.mcp.snapshots == 1 && f.mcp.discoveries == 1)
        try #require(f.bridge.providerRuntimeObservations.isEmpty)
        let originalTurn = try #require(chat.turnTaskForTests(sessionID: sessionID))
        let committed = try #require(chat.messages.first { $0.role == .user && $0.content == draft })

        // The catalog runs inside the real AgentLoop stream producer. Give
        // ChatStore's stream-open continuation time to run while MCP is held.
        try await Task.sleep(for: .milliseconds(250))
        try #require(await f.mcp.discoveryGate.isPending())
        #expect(chat.isComposerProviderPreparationPending)
        #expect(admission == nil)
        #expect(chat.pendingBackgroundResults[sessionID] == [notice])
        #expect(f.bridge.providerRuntimeObservations.isEmpty)

        let observationLimit = started + .seconds(31)
        while (chat.isComposerProviderPreparationPending || admission == nil)
                && ContinuousClock.now < observationLimit {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await f.mcp.discoveryGate.isPending())
        #expect(!chat.isComposerProviderPreparationPending)
        #expect(admission == false)
        #expect(chat.pendingBackgroundResults[sessionID] == [notice])
        #expect(chat.messages.last?.content.contains("超时") == true)
        #expect(chat.messages.filter { $0.role == .user }.map(\.id) == [committed.id])
        #expect(f.bridge.providerRuntimeObservations.isEmpty)
        let settledMessages = chat.messages

        await f.mcp.discoveryGate.finish()
        let releaseLimit = ContinuousClock.now + .seconds(3)
        while f.mcp.releasedDiscoveries == 0 && ContinuousClock.now < releaseLimit {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(f.mcp.releasedDiscoveries == 1)
        await originalTurn.value
        await submission.value
        #expect(f.mcp.invocations == 0)
        #expect(f.bridge.providerRuntimeObservations.isEmpty)
        #expect(chat.messages == settledMessages)
        #expect(chat.pendingBackgroundResults[sessionID] == [notice])
    }
}
