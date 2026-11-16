import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor Tool11DenyingApproval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(
            approved: false,
            reason: "isolated test denial",
            confirmed: false,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private final class Tool11ScriptedProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "tool11-local"
    var model = LLMModel(id: "tool11-model", displayName: "Tool11 Local", provider: "tool11-local")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "tool11-owned-input"
    private let lock = NSLock()
    private var pending: LLMToolCall?
    private var count = 0

    func setCall(_ call: LLMToolCall) { lock.withLock { pending = call } }
    var requestCount: Int { lock.withLock { count } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let call = lock.withLock { () -> LLMToolCall? in
            count += 1
            let result = pending
            pending = nil
            return result
        }
        if let call {
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [call])
        }
        return LLMResponse(text: "隔离请求结束", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// SettingsCenter.active is process wide. The fixture retains its owner through
// each real ChatStore submission and never touches a user data directory.
@Suite("D-TOOL-11 persisted settings to new production requests", .serialized)
@MainActor
struct Tool11SettingsRequestConsumer1534Tests {
    @Test func threePersistedPoliciesReachNewRequestsAndBuiltinEffects() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("tool11-1534-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "tool11-1534-\(UUID().uuidString)"))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let provider = Tool11ScriptedProvider()
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        let lineage = ProviderReadinessLineage.derived(
            providerID: provider.name, modelID: provider.model.id, checkedAt: now
        )
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: provider.name, modelID: provider.model.id, status: .passed,
            readinessState: .mock, checkedAt: now, evidenceID: "tool11-isolated-input",
            isApplied: false, discoveryReceiptID: lineage.discoveryReceiptID,
            discoveredAt: lineage.discoveredAt
        )]))
        try #require(readiness.applyDiscoveredModels(
            providerID: provider.name, modelIDs: [provider.model.id],
            appliedAt: now.addingTimeInterval(1)
        ).count == 1)

        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                                  keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"),
                                         keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("tool11-1534-\(UUID().uuidString)")),
            providerReadinessStore: readiness
        )
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("bridge-logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json")),
            memoryStore: settings.memoryStore, providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas
        )
        try #require(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        let approval = Tool11DenyingApproval()
        bridge.attachProductionServices(
            agentSettings: settings.settings.agent,
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"),
                                         keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            skillStore: settings.skillStore,
            approvalDelegateOverride: approval,
            policyDefaults: ProductionPolicyDefaults(
                budget: 100, deadlineHorizon: 600, autonomyLevel: .l3, networkDomains: []
            ),
            externalRunners: [:],
            sessionReadSecretStore: settings.envStore
        )
        settings.onApprovalPolicyChanged = { [weak bridge] policy in
            bridge?.updateApprovalPolicy(policy)
        }
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false
        )
        defer { bridge.chat.stopAllStreamingForSafety() }
        try #require(SettingsCenter.active === settings)

        let read = root.appendingPathComponent("read.txt")
        try "TOOL11_OWNED_READ".write(to: read, atomically: true, encoding: .utf8)
        let blocked = root.appendingPathComponent("blocked.txt")
        let cases: [(ApprovalPolicy, String, [String: Any], ApprovalPolicy, Int, Int)] = [
            // 用户 2026-11-16：每次询问档下授权目录内读文件不弹卡、直接执行。
            (.alwaysAsk, "file_read", ["path": read.path], .autoApprove, 0, 1),
            (.autoApprove, "file_read", ["path": read.path], .autoApprove, 0, 1),
            (.autoApprove, "file_write", ["path": blocked.path, "content": "must-not-write"],
             .autoApprove, 1, 0),
            (.riskOnlyAsk, "file_read", ["path": read.path], .autoApprove, 0, 1),
            (.riskOnlyAsk, "file_write", ["path": blocked.path, "content": "must-not-write"],
             .alwaysAsk, 1, 0)
        ]
        var submittedTaskIDs: Set<String> = []
        for (index, entry) in cases.enumerated() {
            let (policy, tool, input, expectedGatePolicy, expectedPrompts, expectedEffects) = entry
            settings.approvalPolicy = policy
            try #require(settings.lastPersistenceError == nil)
            let reopenedPolicy = SettingsStore(directory: settings.settingsStore.directory).settings.agent.approvalPolicy
            #expect(reopenedPolicy == (policy == .autoApprove ? .riskOnlyAsk : policy))
            let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
            #expect(engine.loop.approvalGate?.policy(for: tool) == expectedGatePolicy)
            let beforePrompts = await approval.requests.count
            let beforeEffects = engine.toolExecutionFactLedger.facts.count
            let beforeProviderRequests = provider.requestCount
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            provider.setCall(LLMToolCall(id: "tool11-\(index)", name: tool,
                                         rawArguments: String(decoding: data, as: UTF8.self),
                                         arguments: input))
            bridge.chat.draftText = "new owned request \(index)"
            bridge.chat.submitComposer()
            let deadline = Date().addingTimeInterval(20)
            while bridge.chat.isStreaming && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!bridge.chat.isStreaming)
            #expect(provider.requestCount == beforeProviderRequests + 2)
            #expect(await approval.requests.count - beforePrompts == expectedPrompts)
            #expect(engine.toolExecutionFactLedger.facts.count - beforeEffects == expectedEffects)
            let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
            #expect(submittedTaskIDs.insert(snapshot.taskID).inserted)
            #expect(snapshot.policyRevision == bridge.chat.composerPolicyFacts.revision)
            if tool == "file_write" {
                #expect(!FileManager.default.fileExists(
                    atPath: blocked.path
                ))
            }
        }
    }
}
