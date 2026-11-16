import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private struct Safe2216NoNetwork: SettingsProviderReadinessTransport {
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}
private final class Safe2216Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    func reset() { lock.lock(); count = 0; lock.unlock() }
    func observe(_ access: SkillStoreFilesystemAccess) {
        guard case .fileRead = access else { return }
        lock.lock(); count += 1; lock.unlock()
    }
}

@Suite("D-SAFE2 disabled optional authority failure2216", .serialized)
@MainActor
struct SafeOptionalFailureConsumer2216Tests {
    private struct Fixture {
        let root: URL
        let center: SettingsCenter
        let bridge: BridgeStore
        let reads: Safe2216Reads
        let skillID: String
    }
    private func fixture(locked: Bool) async throws -> Fixture {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal).appendingPathComponent("Safe2216-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let core = root.appendingPathComponent("core"), chat = root.appendingPathComponent("chat")
        let keys = KeychainStore(backing: InMemoryKeychainBacking())
        let reads = Safe2216Reads()
        let center = SettingsCenter(settingsStore: SettingsStore(directory: core),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keys),
            memoryStore: MemoryStore(directory: chat), memoryFileStore: MemoryFileStore(directory: chat),
            sessionStore: SessionStore(directory: chat),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keys),
            skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills"),
                filesystemAccessObserver: { reads.observe($0) }),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessTransport: Safe2216NoNetwork(),
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
            sessionDirectory: chat, mcpManager: center.mcpManager, skillStore: center.skillStore,
            canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false).value
        bridge.chat.newSession(projectID: "safe2216-project", projectName: "Owned optional failure",
            workingDirectory: root.path)
        let id = try #require(bridge.chat.activeSessionID)
        let scope = MemoryScope(sessionID: id.uuidString, projectID: "safe2216-project")
        center.memoryScopeProvider = { scope }
        let imported = try center.skillStore.importSkillThroughLifecycle(content: """
        ---
        name: safe2216-owned
        description: safe2216 owned trigger
        version: 1
        ---
        SAFE2216_APPROVED_BODY
        """, reason: "synthetic optional authority failure", scope: scope,
            approval: SkillApproval(approverID: "safe2216-owner", scope: scope))
        bridge.chat.streamingProviderOverride = MockProvider.shared
        #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
        #expect(bridge.chat.sessionStore === center.sessionStore)
        #expect(SettingsCenter.active === center)
        #expect(bridge.isSafetyFeatureEnabled(.userSkills) == !locked)
        reads.reset()
        return Fixture(root: root, center: center, bridge: bridge, reads: reads, skillID: imported.skill.id)
    }
    private func run(_ f: Fixture, drift: Bool, epochDrift: Bool = false) async throws
        -> (ComposerSubmissionSnapshot, ChatSession, Int) {
        let chat = f.bridge.chat
        let id = try #require(chat.activeSessionID)
        chat.draftText = "safe2216 owned trigger"
        chat.submitComposer()
        let submission = try #require(chat.lastComposerSubmissionSnapshot)
        let task = try #require(chat.turnTaskForTests(sessionID: id))
        // These synchronous MainActor mutations happen after capture and before
        // publication can resume on that actor, independently of worker timing.
        let readsBeforeMutation = f.reads.reads
        if drift {
            f.center.skillStore.setEnabled(f.skillID, enabled: false)
            f.center.skillStore.setEnabled(f.skillID, enabled: true)
        }
        // setEnabled refreshes the on-disk projection itself. Exclude only
        // these synchronous fixture reads; keep all consumer reads observable.
        let mutationReads = f.reads.reads - readsBeforeMutation
        if epochDrift {
            f.center.disengageKillSwitch()
            f.center.disableSafeMode()
            f.center.enableSafeMode()
            f.center.engageKillSwitch()
        }
        await task.value
        #expect(!chat.isStreaming)
        return (submission, try #require(f.center.sessionStore.loadSession(id: id.uuidString)), mutationReads)
    }
    @Test func disabledOptionalAuthorityDriftStillPersistsRealChatWithoutSkillReads() async throws {
        let f = try await fixture(locked: true)
        #expect(f.center.optionalModulesDisabled && f.center.chatBackupRecoveryRemainEnabled)
        let (turn, saved, mutationReads) = try await run(f, drift: true)
        #expect(f.reads.reads - mutationReads == 0)
        #expect(saved.messages.contains { $0.role == .assistant && $0.content.contains("收到：safe2216 owned trigger") })
        #expect(f.bridge.providerRuntimeObservations.count == 1)
        let manifest = try #require(f.bridge.contextManifestStore.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: turn.sessionID, turnID: turn.turnID, messageID: turn.messageID), operationID: "chat:\(turn.sessionID):\(turn.turnID):\(turn.messageID)", attempt: 1))))
        #expect(manifest.snapshot.skillIdentifiers.isEmpty)
        #expect(f.bridge.chat.lastSkillInjectionReceipts.isEmpty)
        #expect(f.bridge.chat.executionSnapshot(forSessionID: try #require(UUID(uuidString: turn.sessionID)))?.failureReason == nil)
    }
    @Test func enabledOptionalAuthorityDriftStillRejectsRealTurn() async throws {
        let f = try await fixture(locked: false)
        let (turn, saved, _) = try await run(f, drift: true)
        #expect(f.bridge.providerRuntimeObservations.isEmpty)
        #expect(!saved.messages.contains { $0.role == .assistant && $0.content.contains("收到：safe2216 owned trigger") })
        #expect(f.bridge.contextManifestStore.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: turn.sessionID, turnID: turn.turnID, messageID: turn.messageID), operationID: "chat:\(turn.sessionID):\(turn.turnID):\(turn.messageID)", attempt: 1))) == nil)
    }
    @Test func enabledStableAuthorityStillConsumesApprovedSkill() async throws {
        let f = try await fixture(locked: false)
        let (turn, saved, _) = try await run(f, drift: false)
        #expect(f.reads.reads > 0)
        #expect(saved.messages.contains { $0.role == .assistant && $0.content.contains("收到：safe2216 owned trigger") })
        let manifest = try #require(f.bridge.contextManifestStore.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: turn.sessionID, turnID: turn.turnID, messageID: turn.messageID), operationID: "chat:\(turn.sessionID):\(turn.turnID):\(turn.messageID)", attempt: 1))))
        #expect(manifest.snapshot.skillIdentifiers == [f.skillID])
        #expect(f.bridge.chat.lastSkillInjectionReceipts.first?.skillID == f.skillID)
    }
    @Test func disabledTurnStillRejectsSafetyEpochABA() async throws {
        let f = try await fixture(locked: true)
        let (turn, saved, _) = try await run(f, drift: false, epochDrift: true)
        #expect(f.bridge.providerRuntimeObservations.isEmpty)
        #expect(!saved.messages.contains { $0.role == .assistant && $0.content.contains("收到：safe2216 owned trigger") })
        #expect(f.bridge.contextManifestStore.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: turn.sessionID, turnID: turn.turnID, messageID: turn.messageID), operationID: "chat:\(turn.sessionID):\(turn.turnID):\(turn.messageID)", attempt: 1))) == nil)
    }
}
