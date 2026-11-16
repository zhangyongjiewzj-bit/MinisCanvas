import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// 第二批线 O：对话中新增/移除/列出 MCP 服务器（RED）。
//
// 约定的输入形态（复用 conversation_settings，不另造工具）：
//   新增  changes["mcp.servers.add"]    = object{id:text, name:text, command:text, args:list, env:object{变量名: text 值}}
//   移除  changes["mcp.servers.remove"] = object{id:text}
//   expectedRevision = settings_catalog 返回的 mcpRevision（与现有 MCP 改名/启停同一把 CAS）
// 列出沿用 settings_catalog 的 mcp.<hex(id)>.name / .enabled / .authorized。

private actor Batch2OApproval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    private let denied: Set<String>

    init(denying denied: Set<String> = []) { self.denied = denied }

    var settingsRequests: [ApprovalRequest] {
        requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }
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

private final class Batch2OProvider:
    LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable
{
    let name = "batch2o-offline"
    var model = LLMModel(id: "batch2o-model", displayName: "Batch2O", provider: "batch2o-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "batch2o-isolated"
    private let lock = NSLock()
    private var requests: [[LLMMessage]] = []
    private let callName: String
    private let callInput: [String: Any]
    private let callID: String

    init(name: String, input: [String: Any], callID: String) {
        callName = name
        callInput = input
        self.callID = callID
    }

    var requestCount: Int { lock.withLock { requests.count } }
    var returnedToolMessage: String? {
        lock.withLock {
            requests.dropFirst().flatMap { $0 }
                .first(where: { $0.role == .tool && $0.toolCallID == callID })?.content
        }
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let count = lock.withLock { requests.append(messages); return requests.count }
        if count == 1 {
            let data = try JSONSerialization.data(withJSONObject: callInput, options: [.sortedKeys])
            let call = LLMToolCall(
                id: callID, name: callName,
                rawArguments: String(decoding: data, as: UTF8.self), arguments: callInput
            )
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [call])
        }
        return LLMResponse(text: "已处理。", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Batch2O conversation MCP server management", .serialized)
@MainActor
struct Batch2O_ConversationMCPServerManagementTests {
    private static let envName = "GITHUB_TOKEN"
    private static let envValue = "batch2o-env-value-must-not-show"

    private func makeFixture() throws -> (SettingsCenter, BridgeStore, URL) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("batch2o-\(UUID().uuidString)")
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
                providerID: "batch2o-offline", modelID: "batch2o-model",
                status: .passed, readinessState: .mock, checkedAt: now,
                evidenceID: "batch2o-synthetic-readiness", isApplied: true,
                discoveryReceiptID: "batch2o-synthetic-discovery", discoveredAt: now,
                applyReceiptID: "provider-readiness-apply:batch2o-synthetic",
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
            usageStore: UsageStore(domain: .suite("batch2o-\(UUID().uuidString)")),
            providerReadinessStore: readiness
        )
        let defaults = try #require(UserDefaults(suiteName: "batch2o-\(UUID().uuidString)"))
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
        return (center, bridge, root)
    }

    private func attach(
        _ bridge: BridgeStore, _ center: SettingsCenter, _ root: URL,
        approval: Batch2OApproval,
        mode: ComposerTaskMode = .manual,
        scope: ComposerApprovalScope = .request,
        bypassConfirmed: Bool = false
    ) async {
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval,
            policyDefaults: batch2BypassPolicyDefaults(mode), externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: mode, approvalScope: scope,
            effort: .standard, bypassModeConfirmed: bypassConfirmed
        )
    }

    private func run(_ bridge: BridgeStore, tool: String, input: [String: Any],
                     callID: String) async throws -> Batch2OProvider {
        let provider = Batch2OProvider(name: tool, input: input, callID: callID)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = "批次2O 合成请求。"
        bridge.chat.submitComposer()
        try await Task.sleep(for: .milliseconds(100))
        let deadline = Date().addingTimeInterval(20)
        while bridge.chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!bridge.chat.isStreaming)
        return provider
    }

    private func hex(_ id: String) -> String {
        id.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private func addInput(revision: String, id: String = "batch2o-github",
                          name: String = "GitHub 工具", command: String = "npx",
                          args: [String] = ["-y", "@modelcontextprotocol/server-github"]) -> [String: Any] {
        [
            "operation": "apply", "expectedRevision": revision,
            "changes": ["mcp.servers.add": [
                "kind": "object",
                "object": [
                    "id": ["kind": "text", "text": id],
                    "name": ["kind": "text", "text": name],
                    "command": ["kind": "text", "text": command],
                    "args": ["kind": "list", "list": args],
                    "env": ["kind": "object", "object": [
                        Self.envName: ["kind": "text", "text": Self.envValue]
                    ]]
                ]
            ]]
        ]
    }

    private func removeInput(revision: String, id: String) -> [String: Any] {
        [
            "operation": "apply", "expectedRevision": revision,
            "changes": ["mcp.servers.remove": [
                "kind": "object", "object": ["id": ["kind": "text", "text": id]]
            ]]
        ]
    }

    private func catalogValues(_ body: String) throws -> [String: BL6SettingValue] {
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let raw = try #require(catalog["values"] as? [String: Any])
        return try raw.mapValues {
            try JSONDecoder().decode(
                BL6SettingValue.self,
                from: JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]))
        }
    }

    // MARK: 1 新增

    @Test("model adds an MCP server: approval card shows name/command/args/env names only, allow writes it like the Settings page")
    func approvedAddWritesEquivalentServer() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2OApproval()
        await attach(bridge, center, root, approval: approval)
        let revision = try #require(center.mcpManager.bl6NameRevision())

        let provider = try await run(bridge, tool: BL6SettingsToolApproval.toolName,
                                     input: addInput(revision: revision), callID: "b2o-add")
        #expect(provider.requestCount == 2)

        let asked = await approval.settingsRequests
        #expect(asked.count == 1)
        let summary = try #require(asked.first?.inputSummary)
        for shown in ["GitHub 工具", "npx", "-y", "@modelcontextprotocol/server-github", Self.envName] {
            #expect(summary.contains(shown), "审批卡缺少 \(shown)")
        }
        #expect(!summary.contains(Self.envValue))

        let stored = try #require(center.mcpManager.server(id: "batch2o-github"))
        #expect(stored.name == "GitHub 工具")
        #expect(stored.type == .stdio)
        #expect(stored.enabled)
        #expect(stored.command == "npx")
        #expect(stored.args == ["-y", "@modelcontextprotocol/server-github"])
        #expect(stored.env == [Self.envName: Self.envValue])
        // 与设置页手动新增一致：写入后尚未获得授权，需用户在设置页授权后才能连接。
        #expect(center.isMCPServerAuthorized(id: "batch2o-github") == false)
        #expect(center.mcpServers.contains { $0.id == "batch2o-github" })

        let receipt = try #require(provider.returnedToolMessage)
        #expect(!receipt.contains(Self.envValue))
        #expect((try? JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(receipt.utf8))) != nil)
    }

    @Test("denied add leaves the MCP store untouched")
    func deniedAddWritesNothing() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2OApproval(denying: [BL6SettingsToolApproval.toolName])
        await attach(bridge, center, root, approval: approval)
        let revision = try #require(center.mcpManager.bl6NameRevision())
        let before = try? Data(contentsOf: center.mcpManager.fileURL)

        let provider = try await run(bridge, tool: BL6SettingsToolApproval.toolName,
                                     input: addInput(revision: revision), callID: "b2o-add-deny")
        #expect(await approval.settingsRequests.count == 1)
        #expect(center.mcpManager.server(id: "batch2o-github") == nil)
        #expect(center.mcpManager.listServers().isEmpty)
        #expect((try? Data(contentsOf: center.mcpManager.fileURL)) == before)
        #expect(provider.returnedToolMessage?.contains("Error executing tool") == true)
    }

    // MARK: 2 移除

    @Test("removing an existing MCP server needs approval; allow moves it to the MCP trash like the Settings page")
    func approvedRemoveDeletesServer() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        #expect(center.addMCPServer(MCPServer(
            id: "batch2o-old", name: "旧服务器", type: .stdio, enabled: true,
            command: "uvx", args: ["mcp-server-old"], env: [Self.envName: Self.envValue])))
        let approval = Batch2OApproval()
        await attach(bridge, center, root, approval: approval)
        let revision = try #require(center.mcpManager.bl6NameRevision())

        let provider = try await run(bridge, tool: BL6SettingsToolApproval.toolName,
                                     input: removeInput(revision: revision, id: "batch2o-old"),
                                     callID: "b2o-remove")
        let asked = await approval.settingsRequests
        #expect(asked.count == 1)
        let summary = try #require(asked.first?.inputSummary)
        #expect(summary.contains("旧服务器"))
        #expect(!summary.contains(Self.envValue))
        #expect(center.mcpManager.server(id: "batch2o-old") == nil)
        #expect(center.mcpManager.trashedServers().contains { $0.id == "batch2o-old" })
        #expect(provider.returnedToolMessage?.contains("Error executing tool") == false)
    }

    @Test("denied remove keeps the server")
    func deniedRemoveKeepsServer() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        #expect(center.addMCPServer(MCPServer(
            id: "batch2o-keep", name: "保留", type: .stdio, enabled: true, command: "uvx")))
        let approval = Batch2OApproval(denying: [BL6SettingsToolApproval.toolName])
        await attach(bridge, center, root, approval: approval)
        let revision = try #require(center.mcpManager.bl6NameRevision())

        _ = try await run(bridge, tool: BL6SettingsToolApproval.toolName,
                          input: removeInput(revision: revision, id: "batch2o-keep"),
                          callID: "b2o-remove-deny")
        #expect(await approval.settingsRequests.count == 1)
        #expect(center.mcpManager.server(id: "batch2o-keep") != nil)
    }

    // MARK: 3 列出

    @Test("listing shows names and status of existing servers and includes one the model just added")
    func catalogListsServersAfterAdd() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        #expect(center.addMCPServer(MCPServer(
            id: "batch2o-a", name: "甲", type: .stdio, enabled: true, command: "a-cmd")))
        #expect(center.addMCPServer(MCPServer(
            id: "batch2o-b", name: "乙", type: .stdio, enabled: false, command: "b-cmd")))
        #expect(center.setMCPServerAuthorized(id: "batch2o-a", authorized: true))
        let approval = Batch2OApproval()
        await attach(bridge, center, root, approval: approval)

        let revision = try #require(center.mcpManager.bl6NameRevision())
        _ = try await run(bridge, tool: BL6SettingsToolApproval.toolName,
                          input: addInput(revision: revision), callID: "b2o-add-list")

        let read = try await run(bridge, tool: BL6SettingsToolApproval.catalogToolName,
                                 input: [:], callID: "b2o-list")
        let body = try #require(read.returnedToolMessage)
        let values = try catalogValues(body)
        #expect(values["mcp.\(hex("batch2o-a")).name"] == .text("甲"))
        #expect(values["mcp.\(hex("batch2o-a")).enabled"] == .toggle(true))
        #expect(values["mcp.\(hex("batch2o-a")).authorized"] == .toggle(true))
        #expect(values["mcp.\(hex("batch2o-b")).name"] == .text("乙"))
        #expect(values["mcp.\(hex("batch2o-b")).enabled"] == .toggle(false))
        #expect(values["mcp.\(hex("batch2o-github")).name"] == .text("GitHub 工具"))
        #expect(values["mcp.\(hex("batch2o-github")).enabled"] == .toggle(true))
        #expect(values["mcp.\(hex("batch2o-github")).authorized"] == .toggle(false))
        #expect(!body.contains(Self.envValue))
    }

    // MARK: 4 护栏

    @Test("a scoped session/workspace consent earned by an ordinary settings change never silently covers adding an MCP server",
          arguments: [ComposerApprovalScope.session, .workspace])
    func scopedConsentCannotCoverAdd(_ scope: ComposerApprovalScope) async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2OApproval()
        await attach(bridge, center, root, approval: approval, scope: scope)

        let snapshot = try #require(center.bl6EffectiveSettingsSnapshot)
        _ = try await run(bridge, tool: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": snapshot.catalogRevision,
            "changes": ["general.language": ["kind": "text", "text": "en"]]
        ], callID: "b2o-ordinary")
        #expect(await approval.settingsRequests.count == 1)

        let revision = try #require(center.mcpManager.bl6NameRevision())
        _ = try await run(bridge, tool: BL6SettingsToolApproval.toolName,
                          input: addInput(revision: revision), callID: "b2o-add-scoped")
        // 第二次调用必须再弹一张卡（新增 MCP = 授权本机执行任意命令，不得借用已有的范围同意）。
        let asked = await approval.settingsRequests
        #expect(asked.count == 2)
        #expect(asked.last?.inputSummary.contains("npx") == true)
    }

    @Test("confirmed bypass registers an inert MCP server without granting trust")
    func bypassModeCannotSilentlyAdd() async throws {
        let (center, bridge, root) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Batch2OApproval(denying: [BL6SettingsToolApproval.toolName])
        await attach(bridge, center, root, approval: approval,
                     mode: .bypassPermission, bypassConfirmed: true)
        let revision = try #require(center.mcpManager.bl6NameRevision())

        let id = "batch2o-bypass-inert"
        let provider = try await run(bridge, tool: BL6SettingsToolApproval.toolName,
            input: addInput(revision: revision, id: id, name: "合成注册", command: "/usr/bin/false", args: []),
            callID: "b2o-add-bypass")
        #expect(await approval.settingsRequests.isEmpty)
        let stored = try #require(center.mcpManager.server(id: id))
        #expect(stored.enabled)
        #expect(stored.command == "/usr/bin/false")
        #expect(!center.isMCPServerAuthorized(id: id))
        let response = try #require(provider.returnedToolMessage)
        #expect(!response.contains(Self.envValue))
        let receipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(response.utf8))
        #expect(receipt.changedKeys == ["mcp.servers.add"])
    }
}
