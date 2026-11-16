import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// 第二批线 R 共用夹具（假 Provider、不联网、临时目录隔离）。
// 复用 Batch2O 的夹具写法：SettingsCenter + BridgeStore + 假 Provider 发一次工具调用，
// 审批用记录型 ApprovalDelegate（可指定拒绝的工具名）。

/// 绕过模式要求自主权上限 L3；默认保守值是 L1，绕过用例必须显式提升，否则回合在授权前就被拒。
func batch2BypassPolicyDefaults(_ mode: ComposerTaskMode) -> ProductionPolicyDefaults {
    var defaults = ProductionPolicyDefaults.default
    if mode == .bypassPermission { defaults.autonomyLevel = .l3 }
    return defaults
}

actor Batch2RApproval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    private let denied: Set<String>

    init(denying denied: Set<String> = []) { self.denied = denied }

    var settingsRequests: [ApprovalRequest] {
        requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }
    }
    var catalogReadRequests: [ApprovalRequest] {
        requests.filter { $0.toolName == BL6SettingsToolApproval.catalogToolName }
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        let allowed = !denied.contains(request.toolName)
        return ApprovalDecision(
            approved: allowed, confirmed: allowed,
            requestID: request.requestID, bindingDigest: request.identityDigest
        )
    }
}

/// 第一次请求发一次工具调用（toolName 为 nil 时直接回文本），其后回文本；
/// finalUsage 附在最终文本回复上，走生产的用量/上下文占用记录路径。
final class Batch2RProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "batch2r-offline"
    var model = LLMModel(id: "batch2r-model", displayName: "Batch2R",
                         provider: "batch2r-offline", contextWindow: 200_000)
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "batch2r-isolated"
    private let lock = NSLock()
    private var requests: [[LLMMessage]] = []
    private let callName: String?
    private let callInput: [String: Any]
    private let callID: String
    private let finalUsage: LLMUsage?

    init(name: String?, input: [String: Any], callID: String, finalUsage: LLMUsage? = nil) {
        callName = name
        callInput = input
        self.callID = callID
        self.finalUsage = finalUsage
    }

    var requestCount: Int { lock.withLock { requests.count } }
    var returnedToolMessage: String? {
        lock.withLock {
            requests.dropFirst().flatMap { $0 }
                .first(where: { $0.role == .tool && $0.toolCallID == callID })?.content
        }
    }
    var toolFailed: Bool { returnedToolMessage?.contains("Error executing tool") == true }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let count = lock.withLock { requests.append(messages); return requests.count }
        if count == 1, let callName {
            let data = try JSONSerialization.data(withJSONObject: callInput, options: [.sortedKeys])
            let call = LLMToolCall(
                id: callID, name: callName,
                rawArguments: String(decoding: data, as: UTF8.self), arguments: callInput
            )
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [call])
        }
        return LLMResponse(text: "已处理。", stopReason: "stop", usage: finalUsage)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

struct Batch2RCatalog {
    let body: String
    let json: [String: Any]
    let values: [String: BL6SettingValue]

    func revision(_ field: String) -> String? { json[field] as? String }
    func entry(_ id: String) -> [String: Any]? {
        (json["entries"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }
    func isAgentMutable(_ id: String) -> Bool? { entry(id)?["agentMutable"] as? Bool }
    func entryIDs(prefix: String) -> [String] {
        ((json["entries"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            .filter { $0.hasPrefix(prefix) }
    }
}

@MainActor
final class Batch2RFixture {
    let center: SettingsCenter
    let bridge: BridgeStore
    let root: URL
    let scheduler: SchedulerTaskStore
    let approval: Batch2RApproval
    let notificationDefaultsName: String
    let notificationDefaults: UserDefaults
    let notifications: SystemNotificationController
    let sessionID: UUID
    let projectID = "batch2r-project"
    private var callCounter = 0

    var chat: ChatStore { bridge.chat }

    private init(center: SettingsCenter, bridge: BridgeStore, root: URL, scheduler: SchedulerTaskStore,
                 approval: Batch2RApproval, notificationDefaultsName: String,
                 notificationDefaults: UserDefaults, notifications: SystemNotificationController,
                 sessionID: UUID) {
        self.center = center
        self.bridge = bridge
        self.root = root
        self.scheduler = scheduler
        self.approval = approval
        self.notificationDefaultsName = notificationDefaultsName
        self.notificationDefaults = notificationDefaults
        self.notifications = notifications
        self.sessionID = sessionID
    }

    func cleanup() {
        bridge.chat.stopAllStreamingForSafety()
        notificationDefaults.removePersistentDomain(forName: notificationDefaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    static func make(
        denying denied: Set<String> = [],
        project: Bool = true,
        mode: ComposerTaskMode = .manual,
        scope: ComposerApprovalScope = .request,
        bypassConfirmed: Bool = false
    ) async throws -> Batch2RFixture {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("batch2r-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        try #require(readiness.upsert([
            ProviderReadinessPersistenceRecord(
                providerID: "batch2r-offline", modelID: "batch2r-model",
                status: .passed, readinessState: .mock, checkedAt: now,
                evidenceID: "batch2r-synthetic-readiness", isApplied: true,
                discoveryReceiptID: "batch2r-synthetic-discovery", discoveredAt: now,
                applyReceiptID: "provider-readiness-apply:batch2r-synthetic",
                appliedAt: now
            )
        ]))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain
            ),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("batch2r-usage-\(UUID().uuidString)")),
            providerReadinessStore: readiness
        )
        let defaultsName = "batch2r-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let notificationName = "batch2r-notif-\(UUID().uuidString)"
        let notificationDefaults = try #require(UserDefaults(suiteName: notificationName))
        let notifications = SystemNotificationController(
            defaults: notificationDefaults, canUseSystemNotifications: false)
        center.systemNotifications = notifications
        let skills = SkillsStore(
            appStore: center.skillStore,
            stateFileURL: root.appendingPathComponent("skill-state.json")
        )
        let scheduler = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: root.appendingPathComponent("scheduler-occurrences.json")
        )
        let bridge = try BridgeStore(
            taskStorePersistenceURL: root.appendingPathComponent("agent-tasks.json"),
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            settingsCatalogSkillsStore: skills,
            settingsCatalogSchedulerStore: scheduler,
            logManager: LogManager(directory: root.appendingPathComponent("bridge-logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: badges,
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, memoryStore: center.memoryStore,
            providerReadinessStore: readiness,
            canvasFeatureLane: .phase3NonCanvas
        )
        bridge.bindProductionEffectiveSettingsSource { [weak center] in
            center?.bl6EffectiveSettingsSnapshot
        }
        let sessionID = try #require(bridge.chat.activeSessionID)
        if project {
            bridge.chat.setProject(
                ChatStore.SessionProject(id: "batch2r-project", name: "批次2R 合成项目",
                                         workingDirectory: root.path),
                forSession: sessionID
            )
        }
        center.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        let approval = Batch2RApproval(denying: denied)
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval,
            policyDefaults: batch2BypassPolicyDefaults(mode), externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: mode, approvalScope: scope, effort: .standard, bypassModeConfirmed: bypassConfirmed
        )
        return Batch2RFixture(
            center: center, bridge: bridge, root: root, scheduler: scheduler, approval: approval,
            notificationDefaultsName: notificationName, notificationDefaults: notificationDefaults,
            notifications: notifications, sessionID: sessionID
        )
    }

    // MARK: 发起一轮

    func run(tool: String?, input: [String: Any], usage: LLMUsage? = nil) async throws -> Batch2RProvider {
        callCounter += 1
        let provider = Batch2RProvider(name: tool, input: input, callID: "b2r-call-\(callCounter)",
                                       finalUsage: usage)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = "批次2R 合成请求 \(callCounter)。"
        bridge.chat.submitComposer()
        try await Task.sleep(for: .milliseconds(100))
        let deadline = Date().addingTimeInterval(20)
        while bridge.chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!bridge.chat.isStreaming)
        return provider
    }

    func readCatalog() async throws -> Batch2RCatalog {
        let provider = try await run(tool: BL6SettingsToolApproval.catalogToolName, input: [:])
        let body = try #require(provider.returnedToolMessage)
        let json = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let raw = try #require(json["values"] as? [String: Any])
        let values = try raw.mapValues {
            try JSONDecoder().decode(
                BL6SettingValue.self,
                from: JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]))
        }
        return Batch2RCatalog(body: body, json: json, values: values)
    }

    func write(_ changes: [String: Any], revision: String) async throws -> Batch2RProvider {
        try await run(tool: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision, "changes": changes
        ])
    }

    // MARK: 输入构造与种子数据

    static func text(_ value: String) -> [String: Any] { ["kind": "text", "text": value] }
    static func toggle(_ value: Bool) -> [String: Any] { ["kind": "toggle", "toggle": value] }
    static func integer(_ value: Int) -> [String: Any] { ["kind": "integer", "integer": value] }
    static func object(_ fields: [String: [String: Any]]) -> [String: Any] {
        ["kind": "object", "object": fields]
    }

    /// 目标就是当前会话/项目的定时任务（与会话右键“为此会话创建定时任务”预填同口径）。
    @discardableResult
    func seedTask(name: String, enabled: Bool = true, turn: Int = 1,
                  session: UUID? = nil, project: String? = nil) throws -> SchedulerTask {
        #expect(scheduler.add(
            name: name, cronExpression: "0 9 * * *", command: "总结昨日会话", isEnabled: enabled,
            targetSessionID: session ?? sessionID, targetProjectID: project ?? projectID,
            targetTurnID: turn
        ) == nil)
        return try #require(scheduler.allTasks().first { $0.name == name })
    }

    func ordinaryCatalogRevision() throws -> String {
        try #require(center.bl6EffectiveSettingsSnapshot?.catalogRevision)
    }
}
