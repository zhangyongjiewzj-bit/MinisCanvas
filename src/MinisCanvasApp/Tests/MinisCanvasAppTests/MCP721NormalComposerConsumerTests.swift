import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor MCP721Approval: ApprovalDelegate {
    private var approvalsLeft: Int
    private(set) var requests: [ApprovalRequest] = []
    private var held = false
    private var pending: CheckedContinuation<Void, Never>?
    func hold() { held = true }
    func release() { held = false; pending?.resume(); pending = nil }
    init(approvals: Int) { approvalsLeft = approvals }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        if held { await withCheckedContinuation { pending = $0 } }
        let allow = approvalsLeft > 0
        if allow { approvalsLeft -= 1 }
        return ApprovalDecision(approved: allow, reason: allow ? nil : "synthetic user denial",
            confirmed: allow, requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// Fixed local model input only. It observes, never invents, tool-result messages.
private final class MCP721Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "mcp721-local"
    private var configurationMaterial: String? = "mcp721-fixed-local"
    var runtimeConfigurationMaterial: String? {
        get { lock.withLock { configurationMaterial } }
        set { lock.withLock { configurationMaterial = newValue } }
    }
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var currentModel = LLMModel(id: "mcp721", displayName: "Synthetic721", provider: "mcp721-local")
    var model: LLMModel {
        get { lock.withLock { currentModel } }
        set { lock.withLock { currentModel = newValue } }
    }
    private var replies: [String] = []
    private var captured: [[LLMMessage]] = []
    private var definitions: [[AgentToolDefinition]] = []
    func catalogs() -> [[AgentToolDefinition]] { lock.withLock { definitions } }
    func configure(_ replies: [String]) { lock.withLock { self.replies = replies } }
    func requests() -> [[LLMMessage]] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let reply: String? = lock.withLock {
            captured.append(messages)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        if let reply { return LLMResponse(text: reply, stopReason: "stop", usage: nil) }
        let outcomes = messages.flatMap { $0.toAgentContentParts() }.compactMap { part -> Bool? in
            if case .toolResult(_, _, _, let isError, _, _, _, _) = part { return isError }
            return nil
        }
        let text = !outcomes.isEmpty && outcomes.allSatisfy { $0 }
            ? "已停止，未执行。" : (outcomes.contains(true) ? "部分调用未执行。" : "已处理工具结果。")
        return LLMResponse(text: text, stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { definitions.append(tools) }
        return try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw CancellationError() // This provider does not advertise streaming.
    }
}

@Suite("721 normal Composer canonical MCP consumer", .serialized)
@MainActor
struct MCP721NormalComposerConsumerTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCP721-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }
    private func makeBridge(root: URL, provider: MCP721Provider, approval: MCP721Approval, registry: MCPToolRegistry, agentSettings: AgentSettings = .default) throws -> BridgeStore {
        let defaults = try #require(UserDefaults(suiteName: "mcp721-" + UUID().uuidString))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        let lineage = ProviderReadinessLineage.derived(providerID: provider.name, modelID: provider.model.id, checkedAt: now)
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(providerID: provider.name,
            modelID: provider.model.id, status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "mcp721-owned-synthetic", isApplied: false,
            discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt)]))
        try #require(readiness.applyDiscoveredModels(providerID: provider.name,
            modelIDs: [provider.model.id], appliedAt: now.addingTimeInterval(1)).count == 1)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("721 is non-Canvas") },
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
        try #require(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        bridge.attachProductionServices(agentSettings: agentSettings, fileAccessAllowedRoot: root,
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"),
                                        keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            mcpBridgeOverride: registry,
            approvalDelegateOverride: approval,
            policyDefaults: ProductionPolicyDefaults(budget: 100, deadlineHorizon: 600,
                                                     autonomyLevel: .l1, networkDomains: []),
            externalRunners: [:],
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                                               keychain: KeychainStore(backing: InMemoryKeychainBacking())))
        try #require(bridge.chat.sessionStore === sessions)
        try #require(bridge.chat.sessionManager?.store === sessions)
        try #require(bridge.chat.sessionManager?.badgeStore === badges)
        try #require(bridge.chat.agentEngine is AgentLoopChatEngine)
        bridge.updateApprovalPolicy(.alwaysAsk)
        bridge.chat.streamingProviderOverride = provider
        return bridge
    }
    private func call(_ id: String, _ name: String, _ input: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": id, "name": name, "input": input]]]), as: UTF8.self)
    }
    private func submit(_ bridge: BridgeStore, _ provider: MCP721Provider, replies: [String],
                        mode: ComposerTaskMode, scope: ComposerApprovalScope = .request) async throws -> [LLMMessage] {
        let before = provider.requests().count
        provider.configure(replies)
        bridge.chat.composerPolicySelection = ComposerPolicySelection(mode: mode, approvalScope: scope,
            effort: .standard, bypassModeConfirmed: false)
        bridge.chat.draftText = "721 owned synthetic operation"
        bridge.chat.submitComposer()
        for _ in 0..<500 {
            if !bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!bridge.chat.isStreaming)
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

    private struct Fixture {
        let root: URL
        let provider: MCP721Provider
        let approval: MCP721Approval
        let manager: MCPServerManager
        let center: SettingsCenter
        let registry: MCPToolRegistry
        let bridge: BridgeStore
        let effect: URL
        let transport: MCP721Transport
        var name: String { MCPBoundTool.makeFullName(serverID: "owned721", toolName: "record") }
    }

    private func makeFixture(approvals: Int = 1, grantTool: Bool = true,
                             allowlist: MCPToolAuthorization? = nil, outsideRoot: Bool = false,
                             toolTimeoutSeconds: Int? = nil, delay: Duration? = nil) async throws -> Fixture {
        let root = try makeRoot(), provider = MCP721Provider(), approval = MCP721Approval(approvals: approvals)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("owned-mcps.json"), keychain: keychain)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("provider"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("settings-memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("settings-logs"), ringCapacity: 10),
            mcpManager: manager,
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("settings-skills")),
            usageStore: UsageStore(domain: .suite("mcp721-" + UUID().uuidString)))
        let server = MCPServer(id: "owned721", name: "Owned synthetic", command: "never-spawned721")
        try #require(center.addMCPServer(server))
        try #require(center.setMCPServerAuthorized(id: server.id, authorized: true))
        if grantTool { try #require(center.setMCPToolAuthorized(serverID: server.id, toolName: "record", authorized: true)) }
        let effectRoot = outsideRoot ? try makeRoot() : root
        let effect = effectRoot.appendingPathComponent("mcp-effect.txt")
        if let toolTimeoutSeconds { center.toolTimeoutSeconds = toolTimeoutSeconds }
        let transport = MCP721Transport(effect: effect, delay: delay)
        let factory: @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0, transport: transport) }
        try #require(await center.discoverMCPTools(for: server, clientFactory: factory))
        try #require(manager.discoverySnapshot(serverID: server.id) != nil)
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory, authorization: allowlist)
        let bridge = try makeBridge(root: root, provider: provider, approval: approval, registry: registry,
                                    agentSettings: center.settingsStore.settings.agent)
        return Fixture(root: root, provider: provider, approval: approval, manager: manager,
                       center: center, registry: registry, bridge: bridge, effect: effect, transport: transport)
    }

    // R3-11：MCP 工具不受设置里的“其它工具超时”约束，各自用 MCP 服务器配置的超时
    // （MCP 页可单独设，对齐 Claude Code 的 MCP 工具超时独立）；设置值仍持久化并接到引擎。
    @Test func approvedMCPToolIgnoresPersistedOtherToolTimeout() async throws {
        for (limit, shouldTimeout) in [(1, false), (5, false)] {
            let f = try await makeFixture(toolTimeoutSeconds: limit, delay: .seconds(2))
            defer {
                f.bridge.chat.stopAllStreamingForSafety()
                f.registry.disconnectAll()
                try? FileManager.default.removeItem(at: f.root)
            }
            let reopenedSettings = SettingsStore(directory: f.center.settingsStore.directory).settings.agent
            #expect(reopenedSettings.toolTimeoutSeconds == limit)
            #expect(reopenedSettings.shellCommandTimeoutSeconds == AgentSettings.default.shellCommandTimeoutSeconds)
            let engine = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
            #expect(engine.toolTimeoutSeconds == limit)

            let callID = "other-tool-timeout-\(limit)"
            f.provider.configure([try call(callID, f.name, ["path": f.effect.path, "value": "owned721"])])
            f.bridge.chat.composerPolicySelection = .default
            f.bridge.chat.draftText = "合成 MCP 工具超时验证"
            f.bridge.chat.submitComposer()
            for _ in 0..<500 {
                if !f.bridge.chat.isStreaming { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!f.bridge.chat.isStreaming)
            #expect(await f.approval.requests.count == 1)
            #expect(f.transport.calls == 1)
            let terminal = try #require(engine.toolExecutionFactLedger.facts.first { $0.toolCallID == callID })
            #expect(terminal.status == (shouldTimeout ? .failed : .succeeded))
            #expect(terminal.failureCategory == (shouldTimeout ? .timeout : nil))
            #expect(FileManager.default.fileExists(atPath: f.effect.path) == !shouldTimeout)
        }
    }

    @Test func settingsAuthorizedToolReachesNormalComposerAndDurableReceipt() async throws {
        let f = try await makeFixture()
        defer { f.registry.disconnectAll() }
        let provider = f.provider, approval = f.approval, manager = f.manager
        let bridge = f.bridge, effect = f.effect, transport = f.transport
        let server = try #require(manager.server(id: "owned721"))
        let discovery = try #require(manager.discoverySnapshot(serverID: server.id))
        let name = MCPBoundTool.makeFullName(serverID: server.id, toolName: "record")
        let request = try await submit(bridge, provider,
            replies: [call("mcp721-call", name, ["value": "owned721", "path": effect.path])], mode: .manual)
        let result = try terminal(request, id: "mcp721-call")
        #expect(provider.catalogs().count == 2)
        #expect(provider.catalogs().allSatisfy { $0.filter { $0.name == name }.count == 1 })
        #expect(manager.discoverySnapshot(serverID: server.id) == discovery)
        #expect(!result.1, "An explicitly authorized canonical MCP tool must reach normal Composer approval and execution")
        #expect(await approval.requests.count == 1)
        #expect(transport.calls == 1)
        #expect(FileManager.default.fileExists(atPath: effect.path))
        if FileManager.default.fileExists(atPath: effect.path) {
            #expect(try String(contentsOf: effect, encoding: .utf8) == "owned721")
        }
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.count == 1)
        #expect(engine.toolExecutionFactLedger.facts.allSatisfy { $0.status == .succeeded })
        #expect(bridge.composerApprovalReceipts.count == 1)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        let receipt = try #require(bridge.composerApprovalReceipts.first)
        let requestIdentity = try #require(await approval.requests.first)
        #expect(receipt.requestID == requestIdentity.requestID && receipt.callID == "mcp721-call")
        #expect(receipt.sessionID == snapshot.sessionID && receipt.turnID == snapshot.turnID)
        #expect(receipt.taskID == snapshot.taskID && receipt.attemptID == snapshot.attemptID)
        #expect(receipt.messageID == snapshot.messageID && snapshot.workspaceID == bridge.chat.composerPolicyFacts.workspaceID)
        #expect(receipt.policyRevision == snapshot.policyRevision && receipt.grantEpoch == snapshot.grantEpoch)
        #expect(receipt.leaseID == bridge.chat.composerPolicyFacts.leaseID && !receipt.leaseRevoked)
        let fact = try #require(engine.toolExecutionFactLedger.facts.first)
        let key = try #require(fact.compositeKey)
        let execution = try #require(fact.executionIdentity)
        #expect(key.isValid && !fact.receiptID.isEmpty && fact.toolName == name)
        #expect(key.sessionID == snapshot.sessionID && key.turnID == snapshot.turnID)
        #expect(key.messageID == snapshot.messageID && key.toolCallID == receipt.callID)
        #expect(key.operationID == execution.operationID && execution.turn.sessionID == snapshot.sessionID)
        #expect(key.attemptID == fact.attemptID && key.attemptNumber == fact.attemptNumber)
        let restored = try reopened(bridge)
        #expect(restored.messages == bridge.chat.messages.map { $0.asLLMMessage() })
    }
    @Test(arguments: ["approval-denied", "outside-root", "server-only", "static-deny"])
    func explicitDiscoveryNeverBypassesOtherAuthorities(boundary: String) async throws {
        let f = try await makeFixture(approvals: boundary == "approval-denied" ? 0 : 1,
            grantTool: boundary != "server-only", allowlist: boundary == "static-deny" ? .denyAll : nil,
            outsideRoot: boundary == "outside-root")
        defer { f.registry.disconnectAll() }
        let messages = try await submit(f.bridge, f.provider,
            replies: [call("deny721", f.name, ["value": "owned721", "path": f.effect.path])], mode: .manual)
        // MCP 工具的 path 参数是服务端自己的约定，不再按项目根拦截（对齐 Claude Code）：
        // 授权目录外的路径参数经一次审批后照常执行；其余边界仍然拦住。
        let reachesTool = boundary == "outside-root"
        #expect((try terminal(messages, id: "deny721")).1 == !reachesTool)
        #expect(f.transport.calls == (reachesTool ? 1 : 0))
        #expect(FileManager.default.fileExists(atPath: f.effect.path) == reachesTool)
        let approvals = await f.approval.requests.count
        #expect(approvals == (["approval-denied", "outside-root"].contains(boundary) ? 1 : 0))
        #expect(f.bridge.composerApprovalReceipts.count == (boundary == "outside-root" ? 1 : 0))
        let engine = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.allSatisfy { ($0.status == .succeeded) == reachesTool })
        #expect(try reopened(f.bridge).messages == f.bridge.chat.messages.map { $0.asLLMMessage() })
    }

    @Test(arguments: ["disable", "revoke", "descriptor", "restart", "cancel"])
    func approvalWaitingCannotExecuteRetiredGrant(boundary: String) async throws {
        let f = try await makeFixture()
        defer { f.registry.disconnectAll() }
        await f.approval.hold()
        f.provider.configure([try call("held721", f.name, ["value": "owned721", "path": f.effect.path])])
        f.bridge.chat.composerPolicySelection = ComposerPolicySelection(mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        f.bridge.chat.draftText = "721 held owned request"
        f.bridge.chat.submitComposer()
        for _ in 0..<500 {
            if await f.approval.requests.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let reachedApproval = await f.approval.requests.count == 1
        if !reachedApproval { await f.approval.release() }
        try #require(reachedApproval)
        #expect(f.provider.requests().count == 1 && f.transport.calls == 0)
        #expect(f.provider.catalogs().first?.filter { $0.name == f.name }.count == 1)
        switch boundary {
        case "disable": try #require(f.center.toggleMCPServer(id: "owned721", enabled: false))
        case "revoke": try #require(f.center.setMCPToolAuthorized(serverID: "owned721", toolName: "record", authorized: false))
        case "descriptor":
            let currentServer = try #require(f.manager.server(id: "owned721"))
            var edit = MCPServerEditDraft(existing: currentServer)
            edit.command = "owned-changed-never-spawned721"
            try #require(edit.save(to: f.center))
        case "restart": f.registry.disconnectAll()
        default: f.bridge.chat.stopStreaming()
        }
        await f.approval.release()
        for _ in 0..<500 {
            if !f.bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!f.bridge.chat.isStreaming)
        #expect(f.transport.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: f.effect.path))
        let engine = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.allSatisfy { $0.status != .succeeded })
        if boundary != "cancel" {
            try #require(f.provider.requests().count == 2)
            #expect((try terminal(try #require(f.provider.requests().last), id: "held721")).1)
        } else {
            #expect(f.provider.requests().count == 1)
        }
        #expect(try reopened(f.bridge).messages == f.bridge.chat.messages.map { $0.asLLMMessage() })
    }

    @Test func sessionApprovalReusesOnlySameCanonicalGrant() async throws {
        let f = try await makeFixture()
        defer { f.registry.disconnectAll() }
        for id in ["session-first721", "session-same721"] {
            if id == "session-same721" {
                let before = try #require(f.manager.discoverySnapshot(serverID: "owned721"))
                let factory: @Sendable (MCPServer) -> MCPClient = { [transport = f.transport] in
                    MCPClient(server: $0, transport: transport)
                }
                let server = try #require(f.manager.server(id: "owned721"))
                try #require(await f.center.discoverMCPTools(for: server, clientFactory: factory))
                let after = try #require(f.manager.discoverySnapshot(serverID: "owned721"))
                #expect(before.id == after.id && before.schemaDigest == after.schemaDigest)
            }
            let messages = try await submit(f.bridge, f.provider,
                replies: [call(id, f.name, ["value": "owned721-" + id, "path": f.effect.path])],
                mode: .manual, scope: .session)
            let result = try terminal(messages, id: id)
            if id == "session-first721" {
                #expect(!result.1)
            } else {
                #expect(result.1)
                #expect(result.0.contains("synthetic user denial"), "Same grant must reach fresh approval")
            }
        }
        try #require(f.transport.calls == 1)
        try #require(await f.approval.requests.count == 2)
        let original = f.bridge.composerApprovalReceipts
        try #require(original.count == 1)
        #expect(try String(contentsOf: f.effect, encoding: .utf8) == "owned721-session-first721")
        try #require(f.center.setMCPToolAuthorized(serverID: "owned721", toolName: "record", authorized: false))
        try #require(f.center.setMCPToolAuthorized(serverID: "owned721", toolName: "record", authorized: true))
        let factory: @Sendable (MCPServer) -> MCPClient = { [transport = f.transport] in MCPClient(server: $0, transport: transport) }
        try #require(await f.center.discoverMCPTools(for: try #require(f.manager.server(id: "owned721")), clientFactory: factory))
        for foreignSession in [false, true] {
            if foreignSession { f.bridge.chat.newSession() }
            let id = foreignSession ? "foreign-session721" : "new-grant721"
            let messages = try await submit(f.bridge, f.provider,
                replies: [call(id, f.name, ["value": "owned721-" + id, "path": f.effect.path])],
                mode: .manual, scope: .session)
            let denial = try terminal(messages, id: id)
            #expect(denial.1)
            #expect(denial.0.contains("synthetic user denial"), "Owned response must reach fresh approval, not another rejection")
            #expect(f.transport.calls == 1)
        }
        let approvalCount = await f.approval.requests.count
        #expect(approvalCount == 4)
        #expect(f.bridge.composerApprovalReceipts == original)
        #expect(try reopened(f.bridge).messages == f.bridge.chat.messages.map { $0.asLLMMessage() })
    }

    @Test(arguments: [false, true])
    func originalRuntimeSnapshotCannotAuthorizeAnotherTurn(foreignSession: Bool) async throws {
        let f = try await makeFixture(approvals: 2)
        defer { f.registry.disconnectAll() }
        let factory = try #require(f.bridge.chat.turnRuntimeSnapshotFactory)
        var captured: ChatTurnRuntimeSnapshot?
        f.bridge.chat.turnRuntimeSnapshotFactory = { turn, provider in
            let value = factory(turn, provider)
            captured = value
            return value
        }
        let first = try await submit(f.bridge, f.provider,
            replies: [call("capture721", f.name, ["value": "owned721", "path": f.effect.path])], mode: .manual)
        try #require(!(try terminal(first, id: "capture721")).1)
        try #require(f.transport.calls == 1)
        let frozen = try #require(captured)
        let original = f.bridge.composerApprovalReceipts
        if foreignSession { f.bridge.chat.newSession() }
        f.bridge.chat.turnRuntimeSnapshotFactory = { _, _ in frozen }
        f.provider.configure([try call("stale721", f.name, ["value": "owned721", "path": f.effect.path])])
        f.bridge.chat.draftText = "721 cannot reuse prior runtime"
        f.bridge.chat.submitComposer()
        for _ in 0..<500 {
            if !f.bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!f.bridge.chat.isStreaming)
        #expect(f.provider.requests().count == 2)
        #expect(f.transport.calls == 1)
        #expect(await f.approval.requests.count == 1)
        #expect(f.bridge.composerApprovalReceipts == original)
        let engine = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.count == 1)
        #expect(try reopened(f.bridge).messages == f.bridge.chat.messages.map { $0.asLLMMessage() })
    }

}

private final class MCP721Transport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let effect: URL
    let delay: Duration?
    init(effect: URL, delay: Duration? = nil) {
        self.effect = effect
        self.delay = delay
    }
    var calls: Int { lock.withLock { count } }
    func start() async throws {}
    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() {}
    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"), "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("owned721"), "version": .string("1")])]))
        case "tools/list":
            return MCPJSONRPCResponse(id: request.id, result: .object(["tools": .array([.object([
                "name": .string("record"), "inputSchema": .object([
                    "type": .string("object"), "properties": .object(["value": .object(["type": .string("string")]),
                                           "path": .object(["type": .string("string")])]),
                    "required": .array([.string("value"), .string("path")])])])])]))
        case "tools/call":
            guard case .object(let parameters)? = request.params,
                  case .object(let arguments)? = parameters["arguments"],
                  case .string(let path)? = arguments["path"], path == effect.path,
                  case .string(let value)? = arguments["value"],
                  ["owned721", "owned721-session-first721", "owned721-session-same721",
                   "owned721-new-grant721", "owned721-foreign-session721"].contains(value) else {
                throw MCP721FixtureError.unexpectedArguments
            }
            lock.withLock { count += 1 }
            if let delay { try await Task.sleep(for: delay) }
            try Task.checkCancellation()
            try Data(value.utf8).write(to: URL(fileURLWithPath: path))
            return MCPJSONRPCResponse(id: request.id, result: .object(["content": .array([
                .object(["type": .string("text"), "text": .string("owned721 recorded")])])]))
        default:
            return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "unknown owned fixture method"))
        }
    }
}

private enum MCP721FixtureError: Error { case unexpectedArguments }
