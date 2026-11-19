import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor Policy02Approval: ApprovalDelegate {
    private var approvalsLeft: Int
    private let confirmationAllowed: Bool
    private(set) var requests: [ApprovalRequest] = []
    /// 先无条件拒绝的请求个数：未确认的绕过现在按手动审批走（会产生请求），
    /// 用它拒绝这些请求，避免吃掉后面真正要批准的额度。
    private var denialsLeft: Int
    init(approvals: Int, confirmationAllowed: Bool = true, denyFirst: Int = 0) {
        approvalsLeft = approvals
        denialsLeft = denyFirst
        self.confirmationAllowed = confirmationAllowed
    }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        if denialsLeft > 0 {
            denialsLeft -= 1
            return ApprovalDecision(approved: false, reason: "synthetic user denial",
                confirmed: false, requestID: request.requestID, bindingDigest: request.identityDigest)
        }
        let allow = approvalsLeft > 0
        if allow { approvalsLeft -= 1 }
        return ApprovalDecision(approved: allow, reason: allow ? nil : "synthetic user denial",
            confirmed: allow && confirmationAllowed, requestID: request.requestID,
            bindingDigest: request.identityDigest)
    }
}

/// Fixed local model input only. Its final answer makes no execution claim.
private final class Policy02Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "policy02-local"
    private var configurationMaterial: String? = "policy02-fixed-local"
    var runtimeConfigurationMaterial: String? {
        get { lock.withLock { configurationMaterial } }
        set { lock.withLock { configurationMaterial = newValue } }
    }
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var currentModel = LLMModel(id: "policy02", displayName: "Synthetic02", provider: "policy02-local")
    var model: LLMModel {
        get { lock.withLock { currentModel } }
        set { lock.withLock { currentModel = newValue } }
    }
    private var replies: [String] = []
    private var replyDelays: [Duration?] = []
    private var captured: [[LLMMessage]] = []
    func configure(_ replies: [String], delays: [Duration?] = []) {
        lock.withLock {
            self.replies = replies
            replyDelays = delays
        }
    }
    func requests() -> [[LLMMessage]] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let (reply, delay): (String?, Duration?) = lock.withLock {
            captured.append(messages)
            let delay = replyDelays.isEmpty ? nil : replyDelays.removeFirst()
            return (replies.isEmpty ? nil : replies.removeFirst(), delay)
        }
        if let delay { try await Task.sleep(for: delay) }
        if let reply { return LLMResponse(text: reply, stopReason: "stop", usage: nil) }
        return LLMResponse(text: "工具结果已收到。", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw CancellationError() // This provider does not advertise streaming.
    }
}

/// Retain the canonical Settings owner for the complete ordinary turn. An
/// ambient owner from another test/profile must not provide this fixture's context.
@MainActor
private struct Policy02Fixture {
    let bridge: BridgeStore
    let settings: SettingsCenter
}

@Suite("D-POLICY-02 auto and bypass production effects")
@MainActor
struct Policy02AutoBypassProductionEffectTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Policy02-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }
    private func makeBridge(root: URL, provider: Policy02Provider, approval: Policy02Approval,
                            deadlineHorizon: TimeInterval = 600) throws -> Policy02Fixture {
        let defaults = try #require(UserDefaults(suiteName: "policy02-" + UUID().uuidString))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        let lineage = ProviderReadinessLineage.derived(providerID: provider.name, modelID: provider.model.id, checkedAt: now)
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(providerID: provider.name,
            modelID: provider.model.id, status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "policy02-owned-synthetic", isApplied: false,
            discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt)]))
        try #require(readiness.applyDiscoveredModels(providerID: provider.name,
            modelIDs: [provider.model.id], appliedAt: now.addingTimeInterval(1)).count == 1)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("02 is non-Canvas") },
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"),
                                  keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: bridge.chat.logManager,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"),
                                        keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("policy02-usage-" + UUID().uuidString)),
            providerReadinessStore: readiness)
        try #require(SettingsCenter.active === settings)
        try #require(settings.sessionStore === sessions)
        try #require(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        bridge.attachProductionServices(fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"),
                                        keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            approvalDelegateOverride: approval,
            policyDefaults: ProductionPolicyDefaults(budget: 100, deadlineHorizon: deadlineHorizon,
                                                     autonomyLevel: .l3, networkDomains: []),
            externalRunners: [:],
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                                               keychain: KeychainStore(backing: InMemoryKeychainBacking())))
        try #require(bridge.chat.sessionStore === sessions)
        try #require(bridge.chat.sessionManager?.store === sessions)
        try #require(bridge.chat.sessionManager?.badgeStore === badges)
        try #require(bridge.chat.agentEngine is AgentLoopChatEngine)
        bridge.updateApprovalPolicy(.autoApprove)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerSubmissionDiagnosticsEnabled = true
        return Policy02Fixture(bridge: bridge, settings: settings)
    }
    private func call(_ id: String, _ name: String, _ input: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": id, "name": name, "input": input]]]), as: UTF8.self)
    }
    private func submit(_ bridge: BridgeStore, _ provider: Policy02Provider, replies: [String],
                        mode: ComposerTaskMode, scope: ComposerApprovalScope = .request,
                        delays: [Duration?] = [], bypassConfirmed: Bool = false) async throws -> [LLMMessage] {
        let before = provider.requests().count
        provider.configure(replies, delays: delays)
        bridge.chat.composerPolicySelection = ComposerPolicySelection(mode: mode, approvalScope: scope,
            effort: .standard, bypassModeConfirmed: bypassConfirmed)
        bridge.chat.draftText = "02 owned synthetic operation"
        bridge.chat.submitComposer()
        for _ in 0..<500 {
            if !bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!bridge.chat.isStreaming)
        if provider.requests().count != before + replies.count + 1 {
            let stages = bridge.chat.logManager.recentLogs().filter {
                $0.category == "ComposerSubmission"
            }.reversed().map(\.message)
            let assistant = bridge.chat.messages.filter { $0.role == .assistant }.map(\.content)
            print("POLICY02_DIAGNOSTIC mode=\(mode.rawValue) scope=\(scope.rawValue) providerRequests=\(provider.requests().count) expected=\(before + replies.count + 1) streaming=\(bridge.chat.isStreaming) networkAllowed=\(bridge.productionExternalNetworkAllowed)")
            print("POLICY02_DIAGNOSTIC stages=\(stages) assistant=\(assistant) feedback=\(bridge.chat.pastedTextActionFeedback ?? "none")")
        }
        try #require(provider.requests().count == before + replies.count + 1)
        return try #require(provider.requests().last)
    }
    private func terminal(_ messages: [LLMMessage], id: String) throws -> (String, Bool) {
        let values = messages.flatMap { $0.toAgentContentParts() }.compactMap { part -> (String, Bool)? in
            guard case .toolResult(let callID, _, let content, let error, _, _, _, _) = part,
                  callID == id else { return nil }
            return (content, error)
        }
        try #require(values.count == 1)
        return try #require(values.first)
    }
    private func reopened(_ bridge: BridgeStore) throws -> MinisCore.ChatSession {
        let directory = try #require(bridge.chat.sessionStore).directory
        let id = try #require(bridge.chat.activeSessionID)
        return try #require(SessionStore(directory: directory).loadSession(id: id.uuidString))
    }

    @Test func autoExecutesRealInRootEffectWithoutApprovalAndBlocksOutOfRoot() async throws {
        let root = try makeRoot(), provider = Policy02Provider(), approval = Policy02Approval(approvals: 0)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        let target = root.appendingPathComponent("auto-effect.txt")
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("policy02-auto-outside-" + UUID().uuidString + ".txt")
        try "unchanged".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let request = try await submit(bridge, provider, replies: [
            call("auto-effect", "file_write", ["path": target.path, "content": "real-auto-effect"]),
            call("auto-outside", "file_write", ["path": outside.path, "content": "forbidden"])
        ], mode: .auto)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(snapshot.mode == .auto && !snapshot.bypassModeConfirmed)
        #expect(!(try terminal(request, id: "auto-effect")).1)
        #expect((try terminal(request, id: "auto-outside")).1)
        #expect(try String(contentsOf: target, encoding: .utf8) == "real-auto-effect")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "unchanged")
        #expect(await approval.requests.isEmpty)
        #expect(bridge.composerApprovalReceipts.isEmpty)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        // 2026-11-16：授权根外的写改为逐次审批（不再预先拦截）；没人批准，所以文件未变，
        // 账本里该调用是失败记录，根内那次仍是唯一的成功记录。
        #expect(engine.toolExecutionFactLedger.facts.count == 2)
        #expect(engine.toolExecutionFactLedger.facts.filter { $0.status == .succeeded }.map(\.toolCallID) == ["auto-effect"])
        #expect(engine.toolExecutionFactLedger.facts.first { $0.toolCallID == "auto-outside" }?.status == .failed)
        #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        let restored = try reopened(bridge)
        #expect(restored.messages == bridge.chat.messages.map { $0.asLLMMessage() })
        #expect(try Data(contentsOf: target) == Data("real-auto-effect".utf8))
    }

    @Test func bypassNeedsComposerConfirmationThenCallBoundApprovalForRealEffect() async throws {
        let root = try makeRoot(), provider = Policy02Provider(), approval = Policy02Approval(approvals: 1, denyFirst: 1)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        let unconfirmed = root.appendingPathComponent("unconfirmed.txt")
        let blocked = try await submit(bridge, provider, replies: [
            call("bypass-unconfirmed", "file_write", ["path": unconfirmed.path, "content": "forbidden"])
        ], mode: .bypassPermission)
        // 2026-11-18（a350e70e）：未确认的绕过按手动审批走——必须产生审批请求；没人批准（桩拒绝）就没有效果。
        #expect((try terminal(blocked, id: "bypass-unconfirmed")).1)
        #expect(!FileManager.default.fileExists(atPath: unconfirmed.path))
        let unconfirmedRequests = await approval.requests
        #expect(unconfirmedRequests.count == 1 && unconfirmedRequests.first?.toolName == "file_write")
        #expect(bridge.composerApprovalReceipts.isEmpty)

        try #require(fixture.settings.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l3)))
        var policy = fixture.settings.composerPolicy
        policy.mode = .bypassPermission
        policy.protectCredentialPaths = true
        fixture.settings.composerPolicy = policy
        try #require(SkillBypassRiskConfirmation.confirm([], riskConfirmed: true,
            expectedFacts: bridge.chat.composerPolicyFacts, currentFacts: bridge.chat.composerPolicyFacts,
            store: bridge.chat.composerGrantStore.persistentRules) {
                Policy05BypassSettingsConfirmation.setConfirmed(true, in: fixture.settings)
            })
        let allowed = root.appendingPathComponent("bypass-allowed.txt")
        let second = root.appendingPathComponent("bypass-second.txt")
        let credential = root.appendingPathComponent(".env")
        try "POLICY02_SYNTHETIC_SECRET=protected".write(to: credential, atomically: true, encoding: .utf8)
        #expect(fixture.settings.composerPolicy.protectCredentialPaths)
        let request = try await submit(bridge, provider, replies: [
            call("bypass-allowed", "file_write", ["path": allowed.path, "content": "real-bypass-effect"]),
            call("bypass-second", "file_write", ["path": second.path, "content": "second-effect"]),
            call("bypass-credential", "file_read", ["path": credential.path])
        ], mode: .bypassPermission, bypassConfirmed: fixture.settings.composerPolicy.bypassModeConfirmed)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(snapshot.mode == .bypassPermission && snapshot.bypassModeConfirmed)
        #expect(!(try terminal(request, id: "bypass-allowed")).1)
        #expect(!(try terminal(request, id: "bypass-second")).1)
        // 2026-11-16：绕过档读 .env 不再直接拒绝，改为弹卡询问；批准后只读这一个文件，且输出不含明文密钥。
        #expect(!(try terminal(request, id: "bypass-credential")).1)
        #expect(!(try terminal(request, id: "bypass-credential")).0.contains("POLICY02_SYNTHETIC_SECRET=protected"))
        #expect(try String(contentsOf: allowed, encoding: .utf8) == "real-bypass-effect")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second-effect")
        #expect(try String(contentsOf: credential, encoding: .utf8) == "POLICY02_SYNTHETIC_SECRET=protected")
        // 请求共两个：未确认那次的 file_write（已被拒）、读 .env 的 file_read（已批准）。
        let credentialRequests = await approval.requests.filter { $0.toolName == "file_read" }
        #expect(credentialRequests.count == 1)
        #expect(await approval.requests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: unconfirmed.path))
        #expect(bridge.composerApprovalReceipts.count == 1)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        // 账本：被拒的未确认调用在执行前就被挡下，不产生执行记录；只有另外三次成功记录。
        #expect(engine.toolExecutionFactLedger.facts.count == 3)
        #expect(Set(engine.toolExecutionFactLedger.facts.filter { $0.status == .succeeded }.map(\.toolCallID))
            == ["bypass-allowed", "bypass-second", "bypass-credential"])
        #expect(engine.toolExecutionFactLedger.facts.first { $0.toolCallID == "bypass-unconfirmed" } == nil)
        #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        let restored = try reopened(bridge)
        #expect(restored.messages == bridge.chat.messages.map { $0.asLLMMessage() })
        #expect(try Data(contentsOf: allowed) == Data("real-bypass-effect".utf8))
    }

    @Test func bypassRejectsApprovalWithoutSecondConfirmationBeforeEffect() async throws {
        let root = try makeRoot(), provider = Policy02Provider()
        let approval = Policy02Approval(approvals: 0, confirmationAllowed: false)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        var policy = fixture.settings.composerPolicy
        policy.mode = .bypassPermission
        fixture.settings.composerPolicy = policy
        try #require(Policy05BypassSettingsConfirmation.setConfirmed(false, in: fixture.settings))
        try #require(fixture.settings.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l2)))
        #expect(!Policy05BypassSettingsConfirmation.setConfirmed(true, in: fixture.settings))
        #expect(!fixture.settings.composerPolicy.bypassModeConfirmed)
        let target = root.appendingPathComponent("second-confirmation-denied.txt")
        let request = try await submit(bridge, provider, replies: [
            call("bypass-no-second", "file_write", ["path": target.path, "content": "forbidden"])
        ], mode: .bypassPermission, bypassConfirmed: fixture.settings.composerPolicy.bypassModeConfirmed)
        // 未确认的绕过按手动审批走：必须产生审批请求；没人批准（桩拒绝）就没有效果。
        #expect((try terminal(request, id: "bypass-no-second")).1)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(await approval.requests.count == 1)

        try #require(fixture.settings.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l3)))
        #expect(!SkillBypassRiskConfirmation.confirm([], riskConfirmed: false,
            expectedFacts: bridge.chat.composerPolicyFacts, currentFacts: bridge.chat.composerPolicyFacts,
            store: bridge.chat.composerGrantStore.persistentRules) {
                Policy05BypassSettingsConfirmation.setConfirmed(true, in: fixture.settings)
            })
        #expect(!fixture.settings.composerPolicy.bypassModeConfirmed)
        let unacknowledged = try await submit(bridge, provider, replies: [
            call("bypass-no-consent", "file_write", ["path": target.path, "content": "forbidden"])
        ], mode: .bypassPermission, bypassConfirmed: fixture.settings.composerPolicy.bypassModeConfirmed)
        #expect((try terminal(unacknowledged, id: "bypass-no-consent")).1)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(await approval.requests.count == 2)
        #expect(await approval.requests.allSatisfy { $0.toolName == "file_write" })
        #expect(bridge.composerApprovalReceipts.isEmpty)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.filter { $0.status == .succeeded }.isEmpty)
        #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        let restored = try reopened(bridge)
        #expect(restored.messages == bridge.chat.messages.map { $0.asLLMMessage() })
    }

}

// Focused M07 selectors are kept in the App test target so the delivered
// package can run the same policy contract selectors as the core suite.
@Suite("Composer policy and approval contracts", .serialized)
@MainActor
struct Policy02ComposerApprovalModeTests {
    @Test("all five modes and four scopes preserve one frozen snapshot")
    func fiveByFourModeScopeMatrix() {
        for mode in ComposerTaskMode.allCases {
            for scope in ComposerApprovalScope.allCases {
                let snapshot = ComposerSubmissionSnapshot(
                    mode: mode, approvalScope: scope, effort: .standard,
                    sessionID: "session-\(mode.rawValue)-\(scope.rawValue)",
                    turnID: 7, taskID: "task-\(mode.rawValue)-\(scope.rawValue)",
                    messageID: "message-1", workspaceID: "workspace-1",
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                    policyRevision: "facts-1", grantEpoch: "epoch-0",
                    bypassModeConfirmed: mode == .bypassPermission,
                    autonomyCeiling: .l3)
                #expect(snapshot.mode == mode)
                #expect(snapshot.approvalScope == scope)
                #expect(snapshot.effort == .standard)
                #expect(snapshot.policyRevision == "facts-1")
                #expect(snapshot.grantEpoch == "epoch-0")
            }
        }
    }

    @Test("bypass permission requires user acknowledgement and the saved L3 ceiling")
    func bypassRequiresSecondConfirmation() async throws {
        try await Policy02AutoBypassProductionEffectTests()
            .bypassRejectsApprovalWithoutSecondConfirmationBeforeEffect()
    }
}
