import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Settings2893CatalogTransport: MCPTransport, @unchecked Sendable {
    func start() async throws {}
    func stop() {}
    func notify(_ notification: MCPJSONRPCNotification) throws {}

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"), "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("synthetic"), "version": .string("1")])
            ]))
        case "tools/list":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array(["read.name/β", "write"].map { name in
                    .object([
                        "name": .string(name), "description": .string("fixture-schema-secret"),
                        "inputSchema": .object(["type": .string("object"), "properties": .object([:])])
                    ])
                })
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id,
                error: MCPJSONRPCError(code: -32601, message: "method not found"))
        }
    }
}

private actor Settings2094Approval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    private let allowedTools: Set<String>?
    private var returnedRequestIDs: Set<String> = []

    init(allowedTools: Set<String>? = nil) {
        self.allowedTools = allowedTools
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        let allowed = allowedTools?.contains(request.toolName) ?? true
        let decision = ApprovalDecision(
            approved: allowed, confirmed: allowed,
            requestID: request.requestID, bindingDigest: request.identityDigest
        )
        returnedRequestIDs.insert(request.requestID)
        return decision
    }

    func callbackStatus(callID: String, submission: ComposerSubmissionSnapshot) -> (entered: Bool, returned: Bool) {
        let matched = requests.filter {
            $0.callID == callID && $0.sessionID == submission.sessionID && $0.turnID == submission.turnID
                && $0.taskID == submission.taskID && $0.attemptID == submission.attemptID
        }
        return (!matched.isEmpty, matched.contains { returnedRequestIDs.contains($0.requestID) })
    }
}

private final class Settings2094Provider:
    LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable
{
    let name = "settings2094-offline"
    var model = LLMModel(id: "settings2094-model", displayName: "Settings 2094", provider: "settings2094-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "settings2094-isolated"
    private let lock = NSLock()
    private var requests: [(names: [String], messages: [LLMMessage])] = []
    private let callName: String
    private let callInput: [String: Any]
    private let repeatedTurns: Bool
    private let callIDPrefix: String
    private let catalogCallsInOneStream: Int

    init(name: String, input: [String: Any], repeatedTurns: Bool = false,
         callIDPrefix: String = "settings2094-call", catalogCallsInOneStream: Int = 1) {
        callName = name
        callInput = input
        self.repeatedTurns = repeatedTurns
        self.callIDPrefix = callIDPrefix
        self.catalogCallsInOneStream = catalogCallsInOneStream
    }

    var offeredNames: [String] { lock.withLock { requests.first?.names ?? [] } }
    var returnedToolMessage: String? {
        let returned = lock.withLock {
            requests.dropFirst().flatMap(\.messages)
                .last(where: { $0.role == .tool && $0.toolCallID == "\(callIDPrefix)-1" && !$0.content.contains("已真实执行") })?.content
        }
        if callName == BL6SettingsToolApproval.catalogToolName,
           let returned, (try? JSONSerialization.jsonObject(with: Data(returned.utf8))) == nil {
            print("TASK3228_ACTUAL_CATALOG_FAILURE tool=\(callName) call=\(callIDPrefix)-1 response=\(returned)")
        }
        return returned
    }
    var requestCount: Int { lock.withLock { requests.count } }
    var firstCallID: String { "\(callIDPrefix)-1" }
    var latestToolMessages: [LLMMessage] {
        lock.withLock { requests.last?.messages.filter { $0.role == .tool } ?? [] }
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let count = lock.withLock {
            requests.append((tools.map(\.name), messages))
            return requests.count
        }
        let repeatsCatalog = callName == BL6SettingsToolApproval.catalogToolName
            && catalogCallsInOneStream > 1 && count <= catalogCallsInOneStream
        if count == 1 || (repeatedTurns && count == 3) || repeatsCatalog {
            let data = try JSONSerialization.data(withJSONObject: callInput, options: [.sortedKeys])
            let call = LLMToolCall(
                id: "\(callIDPrefix)-\(repeatsCatalog ? count : (count + 1) / 2)", name: callName,
                rawArguments: String(decoding: data, as: UTF8.self), arguments: callInput
            )
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [call])
        }
        return LLMResponse(text: "已处理隔离设置请求。", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("D-SETC production Provider settings consumer", .serialized)
@MainActor
struct ConversationSettingsProvider2094Tests {
    private func makeFixture(
        includeSyntheticSkill: Bool = false,
        canonicalSkillsState: Bool = false
    ) throws -> (SettingsCenter, BridgeStore, URL, SkillsStore, SchedulerTaskStore) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("setc2094-\(UUID().uuidString)")
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
                providerID: "settings2094-offline", modelID: "settings2094-model",
                status: .passed, readinessState: .mock, checkedAt: now,
                evidenceID: "settings2094-synthetic-readiness", isApplied: true,
                discoveryReceiptID: "settings2094-synthetic-discovery", discoveredAt: now,
                applyReceiptID: "provider-readiness-apply:settings2094-synthetic",
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
            usageStore: UsageStore(domain: .suite("setc2094-\(UUID().uuidString)")),
            providerReadinessStore: readiness
        )
        let defaults = try #require(UserDefaults(suiteName: "setc2094-\(UUID().uuidString)"))
        let hermes = root.appendingPathComponent("hermes", isDirectory: true)
        if includeSyntheticSkill {
            let skill = hermes.appendingPathComponent("creative/catalog-owned", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try "---\nname: catalog-owned\ndescription: synthetic\n---\nowned body".write(
                to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        }
        let skills = SkillsStore(
             appStore: center.skillStore,
            stateFileURL: root.appendingPathComponent(canonicalSkillsState ? "skills-enabled.json" : "skill-state.json")
        )
        if includeSyntheticSkill {
            _ = skills.addSkillDirectory(hermes)
            skills.reload()
        }
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
        // Only the explicit owned local catalog participates in this fixture;
        // app-managed Hermes deployment is a separate original consumer.
        bridge.bindProductionEffectiveSettingsSource { [weak center] in
            center?.bl6EffectiveSettingsSnapshot
        }
        return (center, bridge, root, skills, scheduler)
    }

    // 0949 A 类合同：逐值解码正式 typed projection；不把整个异构 values 强转为字典。
    private func decodeCatalogValues(_ catalog: [String: Any]) throws -> [String: BL6SettingValue] {
        let rawValues = try #require(catalog["values"] as? [String: Any])
        return try rawValues.mapValues { raw in
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(BL6SettingValue.self, from: data)
        }
    }

    private func settle(
        _ chat: ChatStore, approval: Settings2094Approval? = nil, phase: String? = nil, line: Int = #line
    ) async throws {
        try await Task.sleep(for: .milliseconds(100))
        let deadline = Date().addingTimeInterval(20)
        while chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let wasStreaming = chat.isStreaming
        var unsettledEvidence = ""
        if wasStreaming {
            let execution = chat.activeSessionID.flatMap { chat.executionSnapshot(forSessionID: $0) }
            let provider = chat.streamingProviderOverride as? Settings2094Provider
            let requests = provider?.requestCount ?? -1
            // Closed enum/Boolean/count fields only: no prompt, identifiers, paths or error text.
            unsettledEvidence = "submissionPresent=\(chat.lastComposerSubmissionSnapshot != nil) executionPresent=\(execution != nil) executionIdentityPresent=\(execution?.executionIdentity != nil) executionState=\(execution?.state.rawValue ?? "absent") credentialPending=\(chat.isComposerCredentialPreflightPending) providerPending=\(chat.isComposerProviderPreparationPending) attachmentPending=\(chat.isComposerAttachmentPreflightPending) activeGenerating=\(chat.isActiveSessionGenerating) providerRequests=\(requests) skillReceipts=\(chat.lastSkillInjectionReceipts.count) injectedSkillReceipts=\(chat.lastSkillInjectionReceipts.filter(\.injected).count)"
            unsettledEvidence += " settleLine=\(line) phase=\(phase ?? "unspecified")"
            if let approval, let provider, let submission = chat.lastComposerSubmissionSnapshot {
                let executionIdentity = execution?.executionIdentity
                let facts = (chat.agentEngine as? AgentLoopChatEngine)?.toolExecutionFactLedger.facts ?? []
                let terminal = facts.last {
                    executionIdentity != nil && $0.executionIdentity == executionIdentity
                        && $0.toolCallID == provider.firstCallID
                }?.status.rawValue ?? "absent"
                // Capture the original failure before this diagnostic actor hop.
                let callback = await approval.callbackStatus(callID: provider.firstCallID, submission: submission)
                unsettledEvidence += " approvalEntered=\(callback.entered) approvalReturned=\(callback.returned) terminal=\(terminal)"
            }
        }
        try #require(!wasStreaming, Comment(rawValue: unsettledEvidence))
    }

    @Test("one actual stream still blocks its third identical catalog call after two approved reads")
    func actualSingleStreamCatalogLoopGuardStillBlocksThird3228() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let provider = Settings2094Provider(
            name: BL6SettingsToolApproval.catalogToolName, input: [:],
            callIDPrefix: "settings3228-single-stream", catalogCallsInOneStream: 3
        )
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        bridge.chat.draftText = "在同一轮中连续读取三次合成设置目录。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(provider.requestCount == 4)
        #expect(provider.offeredNames.contains(BL6SettingsToolApproval.catalogToolName))
        let messages = provider.latestToolMessages
        for index in 1...2 {
            let body = try #require(messages.first {
                $0.toolCallID == "settings3228-single-stream-\(index)"
            }?.content)
            let catalog = try #require(
                JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            )
            #expect(catalog["catalogRevision"] as? String == before.catalogRevision)
        }
        let blocked = try #require(messages.first {
            $0.toolCallID == "settings3228-single-stream-3"
        }?.content)
        #expect(blocked.hasPrefix("[LOOP BLOCKED]"))
        #expect(blocked.contains(BL6SettingsToolApproval.catalogToolName))
        #expect(blocked.contains("连续 3 次"))
        let requests = await approval.requests
        #expect(requests.filter { $0.toolName == BL6SettingsToolApproval.catalogToolName }.count == 2)
        #expect(center.bl6EffectiveSettingsSnapshot?.catalogRevision == before.catalogRevision)
        print("TASK3228_ACTUAL_SINGLE_STREAM_GUARD response=\(blocked)")
    }

    @Test("real Bridge assembly offers typed tools and approved model call persists through reopen")
    func approvedMutationReachesProviderAndCanonicalSettingsOwner() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        let revision = try #require(center.bl6EffectiveSettingsSnapshot?.catalogRevision)
        let provider = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision,
            "changes": ["general.language": ["kind": "text", "text": "en"]]
        ])
        bridge.chat.streamingProviderOverride = provider
        #expect(bridge.chat.conversationSettingsSnapshot(
            from: center, sessionDirectory: root.appendingPathComponent("unrelated-sessions")
        ) == nil)
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        bridge.chat.draftText = "请把界面语言改成英文。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)

        if provider.requestCount == 0 {
            let blocked = bridge.chat.lastSubmissionBlockedByInvalidSettings
            let hasSnapshot = bridge.chat.effectiveSettingsSnapshotSource?() != nil
            let hasFactory = bridge.chat.turnRuntimeSnapshotFactory != nil
            let messages = bridge.chat.messages.map(\.content)
            let feedback = String(describing: bridge.chat.pastedTextActionFeedback)
            print("TASK2094 synthetic diagnostic messages=\(messages) feedback=\(feedback)")
            #expect(!blocked)
            #expect(hasSnapshot)
            #expect(hasFactory)
            #expect(messages.count >= 2)
            #expect(feedback == "nil")
        }

        #expect(provider.offeredNames.contains(BL6SettingsToolApproval.catalogToolName))
        #expect(provider.offeredNames.contains(BL6SettingsToolApproval.toolName))
        #expect(provider.requestCount >= 2)
        #expect(provider.returnedToolMessage?.contains("general.language") == true)
        #expect(center.bl6EffectiveSettingsSnapshot?.value(for: "general.language") == .text("en"))
        #expect(await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }.count == 1)
        let reopened = SettingsStore(directory: root.appendingPathComponent("settings"))
        #expect(reopened.settings.general.language == "en")
    }

    @Test("model typed width proposal updates the exact live draggable sidebar and legacy key")
    func modelSidebarWidthUsesCanonicalGateway2728() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        let key = SessionSidebarWidthContract.typedCatalogID
        let setting = bridge.sidebarWidthSetting
        setting.write(321)
        #expect(setting.effectiveWidth == 321)
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )

        let catalogProvider = Settings2094Provider(
            name: BL6SettingsToolApproval.catalogToolName, input: [:],
            callIDPrefix: "sidebar-catalog"
        )
        bridge.chat.streamingProviderOverride = catalogProvider
        bridge.chat.draftText = "查看侧栏宽度设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        let catalogText = try #require(catalogProvider.returnedToolMessage)
        let catalog = try #require(
            JSONSerialization.jsonObject(with: Data(catalogText.utf8)) as? [String: Any]
        )
        let revision = try #require(catalog["sidebarRevision"] as? String)
        let values = try decodeCatalogValues(catalog)
        #expect(values[key] == .decimal(321))
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        #expect(entries.contains {
            $0["id"] as? String == key && $0["kind"] as? String == "decimal"
                && $0["agentMutable"] as? Bool == true
        })

        let approvedProvider = Settings2094Provider(
            name: BL6SettingsToolApproval.toolName,
            input: ["operation": "apply", "expectedRevision": revision,
                    "changes": [key: ["kind": "decimal", "decimal": 360]]],
            callIDPrefix: "sidebar-apply"
        )
        bridge.chat.streamingProviderOverride = approvedProvider
        bridge.chat.draftText = "把会话侧栏宽度设为 360。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(approvedProvider.requestCount >= 2)
        #expect(setting.effectiveWidth == 360)
        #expect(SessionSidebarWidthContract.persistedRawValue(in: bridge.preferencesDefaults) == 360)
        let receiptText = try #require(approvedProvider.returnedToolMessage)
        let receipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(receiptText.utf8))
        #expect(receipt.changedKeys == [key])
        #expect(receipt.previousRevision == revision)
        #expect(try setting.bl6Snapshot(profileID: center.settingsStore.directory.standardizedFileURL.path).get().revision == receipt.effectiveRevision)
        let reopened = SessionSidebarWidthSetting(defaults: bridge.preferencesDefaults)
        #expect(reopened.effectiveWidth == 360)

        let invalidRevision = receipt.effectiveRevision
        for rejected in [10, -1] {
            let provider = Settings2094Provider(
                name: BL6SettingsToolApproval.toolName,
                input: ["operation": "apply", "expectedRevision": invalidRevision,
                        "changes": [key: ["kind": "decimal", "decimal": rejected]]],
                callIDPrefix: "sidebar-invalid-\(rejected)"
            )
            bridge.chat.streamingProviderOverride = provider
            bridge.chat.draftText = "尝试无效的侧栏宽度。"
            bridge.chat.submitComposer()
            try await settle(bridge.chat)
            #expect(provider.requestCount >= 2)
            #expect(provider.returnedToolMessage != nil)
            #expect(setting.effectiveWidth == 360)
            #expect(SessionSidebarWidthContract.persistedRawValue(in: bridge.preferencesDefaults) == 360)
            #expect(try setting.bl6Snapshot(profileID: center.settingsStore.directory.standardizedFileURL.path).get().revision == invalidRevision)
        }
        for excluded in BL6SettingsCatalog.excludedConversationKeys {
            #expect(throws: BL6SettingsDispatchError.self) {
                try BL6SettingsCatalog.production.validateApprovedMutation(changedKeys: [excluded])
            }
        }
        let nonfinite = setting.prepareBL6Replay(BL6SettingsApprovedInput(
            operation: .apply,
            changes: [key: .decimal(.infinity)],
            expectedRevision: invalidRevision
        ), profileID: center.settingsStore.directory.standardizedFileURL.path)
        if case .failure(.conflict) = nonfinite {
            // Explicit typed rejection; JSON cannot carry a non-finite Double.
        } else {
            Issue.record("non-finite sidebar width was admitted")
        }

        let undoProvider = Settings2094Provider(
            name: BL6SettingsToolApproval.toolName,
            input: ["operation": "rollback", "expectedRevision": invalidRevision,
                    "changes": [String: Any](), "undoReceiptID": receipt.receiptID],
            callIDPrefix: "sidebar-undo"
        )
        bridge.chat.streamingProviderOverride = undoProvider
        bridge.chat.draftText = "撤销侧栏宽度修改。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(undoProvider.requestCount >= 2)
        #expect(setting.effectiveWidth == 321)
        #expect(SessionSidebarWidthContract.persistedRawValue(in: bridge.preferencesDefaults) == 321)
        #expect(SessionSidebarWidthSetting(defaults: bridge.preferencesDefaults).effectiveWidth == 321)
        #expect(await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }.count == 4)
    }

    @Test("actual Provider catalog read asks each time under every saved scope",
          arguments: ComposerApprovalScope.allCases)
    func providerCatalogReadUsesChosenConsentScope(scope: ComposerApprovalScope) async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        let provider = Settings2094Provider(
            name: BL6SettingsToolApproval.catalogToolName, input: [:], repeatedTurns: true
        )
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: scope,
            effort: .standard, bypassModeConfirmed: false
        )
        bridge.chat.draftText = "查看当前可编辑设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        bridge.chat.draftText = "再查看当前可编辑设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)

        #expect(provider.requestCount == 4)
        #expect(provider.offeredNames.contains(BL6SettingsToolApproval.catalogToolName))
        #expect(provider.returnedToolMessage?.contains("general.language") == true)
        let asked = await approval.requests.filter {
            $0.toolName == BL6SettingsToolApproval.catalogToolName
        }
        #expect(asked.count == 2)
        #expect(Set(asked.map(\.requestID)).count == 2)
        #expect(Set(asked.compactMap(\.identityDigest)).count == 2)
        #expect(Set(asked.map(\.callID)).count == asked.count)
    }

    @Test("a catalog consent for one session does not approve a different session")
    func providerReadRejectsWrongSessionReuse() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        let provider = Settings2094Provider(
            name: BL6SettingsToolApproval.catalogToolName, input: [:], repeatedTurns: true
        )
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .session,
            effort: .standard, bypassModeConfirmed: false
        )
        let firstSession = try #require(bridge.chat.activeSessionID)
        bridge.chat.draftText = "查看当前可编辑设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        bridge.chat.newSession()
        let secondSession = try #require(bridge.chat.activeSessionID)
        #expect(firstSession != secondSession)
        bridge.chat.draftText = "再次查看当前可编辑设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)

        #expect(provider.requestCount == 4)
        let reads = await approval.requests.filter {
            $0.toolName == BL6SettingsToolApproval.catalogToolName
        }
        #expect(reads.count == 2)
        #expect(Set(reads.compactMap(\.sessionID)).count == 2)
    }

    @Test("four approval scopes read live safety controls but cannot mutate them",
          arguments: ComposerApprovalScope.allCases)
    func providerCatalogReadsSafetyWithoutGrantingSafetyWrite(
        _ scope: ComposerApprovalScope
    ) async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: scope,
            effort: .standard, bypassModeConfirmed: false
        )

        func readSafety(_ prefix: String) async throws -> [String: Any] {
            let provider = Settings2094Provider(
                name: BL6SettingsToolApproval.catalogToolName, input: [:],
                callIDPrefix: prefix
            )
            bridge.chat.streamingProviderOverride = provider
            bridge.chat.draftText = "查看安全设置状态。"
            bridge.chat.submitComposer()
            try await settle(bridge.chat, approval: approval, phase: prefix == "settings2401-safety-before" ? "safetyBefore" : "safetyAfter")
            #expect(provider.requestCount == 2)
            let body = try #require(provider.returnedToolMessage)
            return try #require(JSONSerialization.jsonObject(
                with: Data(body.utf8)
            ) as? [String: Any])
        }

        let first = try await readSafety("settings2401-safety-before")
        let firstValues = try decodeCatalogValues(first)
        #expect(firstValues["safety.safe-mode-enabled"] == .toggle(false))
        #expect(firstValues["safety.kill-switch-enabled"] == .toggle(false))
        let entries = try #require(first["entries"] as? [[String: Any]])
        for id in ["safety.safe-mode-enabled", "safety.kill-switch-enabled"] {
            let row = try #require(entries.first { $0["id"] as? String == id })
            #expect(row["kind"] as? String == "toggle")
            #expect(row["agentMutable"] as? Bool == false)
            #expect(row["secret"] as? Bool == false)
        }
        let originalProviderSettings = SettingsStore(
            directory: center.settingsStore.directory
        ).settings.providerSettings

        let denied = Settings2094Provider(
            name: BL6SettingsToolApproval.toolName,
            input: [
                "operation": "apply",
                "expectedRevision": try #require(first["catalogRevision"] as? String),
                "changes": ["safety.kill-switch-enabled": ["kind": "toggle", "toggle": true]]
            ],
            callIDPrefix: "settings2401-safety-denied"
        )
        bridge.chat.streamingProviderOverride = denied
        bridge.chat.draftText = "让模型修改安全锁。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat, approval: approval, phase: "safetyWrite")
        #expect(denied.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(!center.killSwitchEnabled)
        #expect(SettingsStore(directory: center.settingsStore.directory)
            .settings.providerSettings == originalProviderSettings)

        center.setSafeMode(true)
        #expect(center.safeModeEnabled)
        let second = try await readSafety("settings2401-safety-after")
        let secondValues = try decodeCatalogValues(second)
        #expect(secondValues["safety.safe-mode-enabled"] == .toggle(true))
        #expect(secondValues["safety.kill-switch-enabled"] == .toggle(false))
        let requests = await approval.requests.filter {
            $0.toolName == BL6SettingsToolApproval.catalogToolName
                || $0.toolName == BL6SettingsToolApproval.toolName
        }
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.approvalScope == scope.rawValue })
    }

    @Test("production Provider reads the canonical shortcut Store and rejects AppSettings revision drift")
    func providerReadsLiveShortcutsWithoutInventingWriteAuthority() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        let action = ShortcutAction.createPipeline
        let key = ShortcutStoreTypedCatalogAdapter.settingID(for: action)
        let binding = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
        #expect(bridge.shortcutStore.setBinding(binding, for: action) == nil)
        #expect(ShortcutStore(defaults: bridge.preferencesDefaults).binding(for: action) == binding)

        let read = Settings2094Provider(name: BL6SettingsToolApproval.catalogToolName, input: [:])
        bridge.chat.streamingProviderOverride = read
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        bridge.chat.draftText = "查看当前可编辑设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat, approval: approval)
        #expect(read.requestCount == 2)
        let body = try #require(read.returnedToolMessage)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        let shortcutRevision = try bridge.shortcutStore.bl6Snapshot(
            profileID: center.settingsStore.directory.standardizedFileURL.path
        ).get().revision
        #expect(json["shortcutRevision"] as? String == shortcutRevision)
        let entries = try #require(json["entries"] as? [[String: Any]])
        let entry = try #require(entries.first { $0["id"] as? String == key })
        #expect(entry["agentMutable"] as? Bool == true)
        #expect(entry["secret"] as? Bool == false)
        let values = try decodeCatalogValues(json)
        let typed = try #require(values[key])
        guard case .object(let fields) = typed else {
            Issue.record("Shortcut typed object missing")
            return
        }
        #expect(fields["key"] == .text("g"))

        let revision = try #require(center.bl6EffectiveSettingsSnapshot?.catalogRevision)
        let deniedWrite = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision,
            "changes": [key: ["kind": "object", "object": [
                "key": ["kind": "text", "text": "k"],
                "modifiers": ["kind": "object", "object": [
                    "command": ["kind": "toggle", "toggle": true],
                    "control": ["kind": "toggle", "toggle": false],
                    "option": ["kind": "toggle", "toggle": false],
                    "shift": ["kind": "toggle", "toggle": false]
                ]]
            ]]]
        ])
        bridge.chat.streamingProviderOverride = deniedWrite
        bridge.chat.draftText = "调整快捷键设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat, approval: approval)
        #expect(deniedWrite.requestCount == 2)
        #expect(deniedWrite.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(bridge.shortcutStore.binding(for: action) == binding)
        #expect(ShortcutStore(defaults: bridge.preferencesDefaults).binding(for: action) == binding)
    }

    @Test("approved Provider shortcut proposal commits, reopens, rolls back and exact replay stays inert",
          arguments: ComposerApprovalScope.allCases)
    func providerShortcutWriteUsesStoreReceiptAndOriginalScope(_ scope: ComposerApprovalScope) async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: scope,
            effort: .standard, bypassModeConfirmed: false
        )
        let action = ShortcutAction.createPipeline
        let settingID = ShortcutStoreTypedCatalogAdapter.settingID(for: action)
        let initial = bridge.shortcutStore.binding(for: action)
        let profileID = center.settingsStore.directory.standardizedFileURL.path
        let initialRevision = try bridge.shortcutStore.bl6Snapshot(profileID: profileID).get().revision
        let chosen = ShortcutBinding(key: "u", modifiers: ShortcutModifiers.command)
        let bindingValue: [String: Any] = [
            "kind": "object", "object": [
                "key": ["kind": "text", "text": "u"],
                "modifiers": ["kind": "object", "object": [
                    "command": ["kind": "toggle", "toggle": true],
                    "control": ["kind": "toggle", "toggle": false],
                    "option": ["kind": "toggle", "toggle": false],
                    "shift": ["kind": "toggle", "toggle": false]
                ]]
            ]
        ]
        let apply = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": initialRevision,
            "changes": [settingID: bindingValue]
        ])
        bridge.chat.streamingProviderOverride = apply
        bridge.chat.draftText = "把合成动作改为 ⌘U。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(apply.requestCount == 2)
        let appliedBody = try #require(apply.returnedToolMessage)
        let applied = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(appliedBody.utf8))
        #expect(applied.operation == .apply)
        #expect(applied.changedKeys == [settingID])
        #expect(applied.previousRevision == initialRevision)
        #expect(applied.rollbackValues.isEmpty)
        #expect(bridge.shortcutStore.binding(for: action) == chosen)
        #expect(ShortcutStore(defaults: bridge.preferencesDefaults).binding(for: action) == chosen)

        let undo = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "rollback", "expectedRevision": applied.effectiveRevision,
            "changes": [:], "undoReceiptID": applied.receiptID
        ], callIDPrefix: "settings2094-undo")
        bridge.chat.streamingProviderOverride = undo
        bridge.chat.draftText = "撤销刚才合成的快捷键修改。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(undo.requestCount == 2)
        let undoBody = try #require(undo.returnedToolMessage)
        let rolledBack = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(undoBody.utf8))
        #expect(rolledBack.operation == .rollback)
        #expect(rolledBack.changedKeys == [settingID])
        #expect(bridge.shortcutStore.binding(for: action) == initial)
        #expect(ShortcutStore(defaults: bridge.preferencesDefaults).binding(for: action) == initial)

        let original = try #require(try bridge.shortcutStore.bl6ReplayRecord(
            for: applied.requestID, profileID: profileID
        ).get())
        #expect(original.receipt == applied)
        #expect(try bridge.shortcutStore.commitBL6Replay(original, profileID: profileID).get() == applied)
        #expect(ShortcutStore(defaults: bridge.preferencesDefaults).binding(for: action) == initial)
    }

    @Test("catalog read consent cannot authorize a shortcut write")
    func providerShortcutWriteNeedsItsOwnApproval() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings2094Approval(allowedTools: [BL6SettingsToolApproval.catalogToolName])
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .session,
            effort: .standard, bypassModeConfirmed: false
        )
        let action = ShortcutAction.createPipeline
        let settingID = ShortcutStoreTypedCatalogAdapter.settingID(for: action)
        let original = bridge.shortcutStore.binding(for: action)
        let read = Settings2094Provider(name: BL6SettingsToolApproval.catalogToolName, input: [:])
        bridge.chat.streamingProviderOverride = read
        bridge.chat.draftText = "查看快捷键设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        let body = try #require(read.returnedToolMessage)
        let json = try #require(JSONSerialization.jsonObject(
            with: Data(body.utf8)
        ) as? [String: Any])
        let revision = try #require(json["shortcutRevision"] as? String)

        let write = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision,
            "changes": [settingID: ["kind": "object", "object": [
                "key": ["kind": "text", "text": "u"],
                "modifiers": ["kind": "object", "object": [
                    "command": ["kind": "toggle", "toggle": true],
                    "control": ["kind": "toggle", "toggle": false],
                    "option": ["kind": "toggle", "toggle": false],
                    "shift": ["kind": "toggle", "toggle": false]
                ]]
            ]]]
        ], callIDPrefix: "settings2094-denied-write")
        bridge.chat.streamingProviderOverride = write
        bridge.chat.draftText = "把合成动作改为 ⌘U。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(write.requestCount == 2)
        #expect(write.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(await approval.requests.filter {
            $0.toolName == BL6SettingsToolApproval.catalogToolName
        }.count == 1)
        #expect(await approval.requests.filter {
            $0.toolName == BL6SettingsToolApproval.toolName
        }.count == 1)
        #expect(bridge.shortcutStore.binding(for: action) == original)
        #expect(ShortcutStore(defaults: bridge.preferencesDefaults).binding(for: action) == original)
    }

    @Test("shortcut Provider rejects a revision drift after the catalog read")
    func providerShortcutWriteRejectsStoreDrift() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        let action = ShortcutAction.createPipeline
        let settingID = ShortcutStoreTypedCatalogAdapter.settingID(for: action)
        let profileID = center.settingsStore.directory.standardizedFileURL.path
        let stale = try bridge.shortcutStore.bl6Snapshot(profileID: profileID).get().revision
        let changed = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
        #expect(bridge.shortcutStore.setBinding(changed, for: action) == nil)
        let write = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": stale,
            "changes": [settingID: ["kind": "object", "object": [
                "key": ["kind": "text", "text": "u"],
                "modifiers": ["kind": "object", "object": [
                    "command": ["kind": "toggle", "toggle": true],
                    "control": ["kind": "toggle", "toggle": false],
                    "option": ["kind": "toggle", "toggle": false],
                    "shift": ["kind": "toggle", "toggle": false]
                ]]
            ]]]
        ])
        bridge.chat.streamingProviderOverride = write
        bridge.chat.draftText = "把合成动作改为 ⌘U。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(write.requestCount == 2)
        #expect(write.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(bridge.shortcutStore.binding(for: action) == changed)
        #expect(ShortcutStore(defaults: bridge.preferencesDefaults).binding(for: action) == changed)
    }

    @Test("approved Provider renames one MCP server with durable replay and undo")
    func providerMCPNameWriteUsesCanonicalStoreReceipt() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let server = MCPServer(
            id: "synthetic-mcp", name: "Before", type: .http,
            enabled: false, url: "https://mcp.invalid"
        )
        #expect(center.addMCPServer(server))
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .session,
            effort: .standard, bypassModeConfirmed: false
        )
        let read = Settings2094Provider(name: BL6SettingsToolApproval.catalogToolName, input: [:])
        bridge.chat.streamingProviderOverride = read
        bridge.chat.draftText = "查看 MCP 服务器设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        let readBody = try #require(read.returnedToolMessage)
        let catalog = try #require(JSONSerialization.jsonObject(
            with: Data(readBody.utf8)
        ) as? [String: Any])
        let revision = try #require(catalog["mcpRevision"] as? String)
        let id = "mcp." + server.id.utf8.map { String(format: "%02x", $0) }.joined() + ".name"
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        #expect(entries.contains { $0["id"] as? String == id && $0["agentMutable"] as? Bool == true })

        let apply = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision,
            "changes": [id: ["kind": "text", "text": "After"]]
        ], callIDPrefix: "settings2094-mcp-apply")
        bridge.chat.streamingProviderOverride = apply
        bridge.chat.draftText = "把这个 MCP 服务器名称改为 After。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        let applyBody = try #require(apply.returnedToolMessage)
        let receipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(applyBody.utf8))
        #expect(receipt.changedKeys == [id])
        #expect(center.mcpManager.server(id: server.id)?.name == "After")
        let reopened = MCPServerManager(
            fileURL: center.mcpManager.fileURL,
            keychain: KeychainStore(backing: InMemoryKeychainBacking())
        )
        #expect(reopened.server(id: server.id)?.name == "After")
        let profileID = center.settingsStore.directory.standardizedFileURL.path
        #expect(try reopened.bl6NameReplayRecord(
            for: receipt.requestID, profileID: profileID
        ).get()?.receipt == receipt)

        let duplicate = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": receipt.effectiveRevision,
            "changes": [id: ["kind": "text", "text": "Unapproved duplicate"]]
        ], callIDPrefix: "settings2094-mcp-apply")
        bridge.chat.streamingProviderOverride = duplicate
        bridge.chat.draftText = "再改为另一个名称。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(duplicate.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(center.mcpManager.server(id: server.id)?.name == "After")

        let undo = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "rollback", "expectedRevision": receipt.effectiveRevision,
            "changes": [:], "undoReceiptID": receipt.receiptID
        ], callIDPrefix: "settings2094-mcp-undo")
        bridge.chat.streamingProviderOverride = undo
        bridge.chat.draftText = "撤销刚才的 MCP 名称修改。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        let undoBody = try #require(undo.returnedToolMessage)
        let undone = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(undoBody.utf8))
        #expect(undone.operation == .rollback)
        #expect(center.mcpManager.server(id: server.id)?.name == "Before")
        #expect(MCPServerManager(
            fileURL: center.mcpManager.fileURL,
            keychain: KeychainStore(backing: InMemoryKeychainBacking())
        ).server(id: server.id)?.name == "Before")
        let original = try #require(try center.mcpManager.bl6NameReplayRecord(
            for: receipt.requestID, profileID: profileID
        ).get())
        #expect(try center.mcpManager.commitBL6NameReplay(
            original, profileID: profileID
        ).get() == receipt)
        #expect(center.mcpManager.server(id: server.id)?.name == "Before")
    }

    @Test("MCP catalog consent cannot authorize a name mutation")
    func providerMCPNameWriteRequiresItsOwnApproval() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let server = MCPServer(
            id: "synthetic-mcp", name: "Before", type: .http,
            enabled: false, url: "https://mcp.invalid"
        )
        #expect(center.addMCPServer(server))
        let approval = Settings2094Approval(allowedTools: [BL6SettingsToolApproval.catalogToolName])
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .session,
            effort: .standard, bypassModeConfirmed: false
        )
        let read = Settings2094Provider(name: BL6SettingsToolApproval.catalogToolName, input: [:])
        bridge.chat.streamingProviderOverride = read
        bridge.chat.draftText = "查看 MCP 名称。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        let body = try #require(read.returnedToolMessage)
        let json = try #require(JSONSerialization.jsonObject(
            with: Data(body.utf8)
        ) as? [String: Any])
        let revision = try #require(json["mcpRevision"] as? String)
        let id = "mcp." + server.id.utf8.map { String(format: "%02x", $0) }.joined() + ".name"
        let write = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision,
            "changes": [id: ["kind": "text", "text": "After"]]
        ], callIDPrefix: "settings2094-mcp-denied")
        bridge.chat.streamingProviderOverride = write
        bridge.chat.draftText = "把 MCP 名称改为 After。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(write.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(center.mcpManager.server(id: server.id)?.name == "Before")
        #expect(MCPServerManager(
            fileURL: center.mcpManager.fileURL,
            keychain: KeychainStore(backing: InMemoryKeychainBacking())
        ).server(id: server.id)?.name == "Before")
    }

    @Test("MCP transport descriptor or grant drift rejects a catalog name proposal")
    func providerMCPNameWriteRejectsDrift() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        var server = MCPServer(
            id: "synthetic-mcp", name: "Before", type: .http,
            enabled: false, url: "https://mcp.invalid"
        )
        #expect(center.addMCPServer(server))
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        let read = Settings2094Provider(name: BL6SettingsToolApproval.catalogToolName, input: [:])
        bridge.chat.streamingProviderOverride = read
        bridge.chat.draftText = "查看 MCP 名称。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        let body = try #require(read.returnedToolMessage)
        let json = try #require(JSONSerialization.jsonObject(
            with: Data(body.utf8)
        ) as? [String: Any])
        let staleRevision = try #require(json["mcpRevision"] as? String)
        server.url = "https://changed.invalid"
        #expect(center.addMCPServer(server))
        let id = "mcp." + server.id.utf8.map { String(format: "%02x", $0) }.joined() + ".name"
        let write = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": staleRevision,
            "changes": [id: ["kind": "text", "text": "After"]]
        ], callIDPrefix: "settings2094-mcp-stale")
        bridge.chat.streamingProviderOverride = write
        bridge.chat.draftText = "把 MCP 名称改为 After。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(write.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(center.mcpManager.server(id: server.id) == server)
        #expect(MCPServerManager(
            fileURL: center.mcpManager.fileURL,
            keychain: KeychainStore(backing: InMemoryKeychainBacking())
        ).server(id: server.id) == server)
    }

    @Test("production Provider reads only facts owned by the approved active memory scope",
          arguments: ["project", "session"])
    func providerCatalogKeepsMemorySessionAndProjectScope(_ boundary: String) async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        center.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        let originalSession = try #require(bridge.chat.activeSessionID)
        bridge.chat.setProject(
            ChatStore.SessionProject(id: "project-A", name: "合成项目", workingDirectory: root.path),
            forSession: originalSession
        )
        _ = try center.provisionBuiltInMemoryCandidateSubmissions()
        #expect(center.addMemoryFact("仅本会话可见的合成事实"))
        let fact = try #require(center.memoryFacts.first)
        let factKey = MemoryStoreTypedCatalogAdapter.settingID(for: fact)
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value

        func readCatalog() async throws -> [String: Any] {
            let provider = Settings2094Provider(
                name: BL6SettingsToolApproval.catalogToolName, input: [:]
            )
            bridge.chat.streamingProviderOverride = provider
            bridge.chat.composerPolicySelection = ComposerPolicySelection(
                mode: .manual, approvalScope: .request,
                effort: .standard, bypassModeConfirmed: false
            )
            bridge.chat.draftText = "查看当前设置。"
            bridge.chat.submitComposer()
            try await settle(bridge.chat)
            #expect(provider.requestCount == 2)
            let message = try #require(provider.returnedToolMessage)
            return try #require(
                JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
            )
        }

        let first = try await readCatalog()
        let firstEntries = try #require(first["entries"] as? [[String: Any]])
        let memoryEntry = try #require(firstEntries.first { $0["id"] as? String == factKey })
        #expect(memoryEntry["agentMutable"] as? Bool == true)
        #expect(first["memoryRevision"] as? String != nil)
        let firstValues = try #require(first["values"] as? [String: Any])
        #expect(firstValues[factKey] != nil)

        if boundary == "project" {
            bridge.chat.setProject(
                ChatStore.SessionProject(id: "project-B", name: "另一个合成项目", workingDirectory: root.path),
                forSession: originalSession
            )
        } else {
            bridge.chat.newSession()
            let otherSession = try #require(bridge.chat.activeSessionID)
            #expect(otherSession != originalSession)
            bridge.chat.setProject(
                ChatStore.SessionProject(id: "project-A", name: "合成项目", workingDirectory: root.path),
                forSession: otherSession
            )
        }
        let second = try await readCatalog()
        let secondValues = try #require(second["values"] as? [String: Any])
        #expect(secondValues[factKey] == nil)
        #expect(try MemoryStore(directory: center.memoryStore.directory).facts().contains {
            $0.id == fact.id && $0.memoryScope?.sessionID == originalSession.uuidString
        })
    }

    @Test("approved Provider memory edit commits, reopens, undoes and exactly replays in four scopes",
          arguments: ComposerApprovalScope.allCases)
    func providerMemoryEditUsesCanonicalLifecycleReceipt2979(_ scope: ComposerApprovalScope) async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: center.sessionStore.directory, approvalDelegateOverride: approval,
            externalNetworkAllowed: true).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: scope, effort: .standard, bypassModeConfirmed: false)
        center.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        let session = try #require(bridge.chat.activeSessionID)
        bridge.chat.setProject(ChatStore.SessionProject(id: "memory2979-project", name: "合成项目",
            workingDirectory: root.path), forSession: session)
        _ = try center.provisionBuiltInMemoryCandidateSubmissions()
        try #require(center.addMemoryFact("memory2979 original"))
        let fact = try #require(center.memoryFacts.first { $0.text == "memory2979 original" })
        let memoryScope = try #require(fact.memoryScope)
        let settingID = MemoryStoreTypedCatalogAdapter.settingID(for: fact)
        let catalog = try await readMemoryCatalog2979(bridge, prefix: "memory2979-read")
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        let entry = try #require(entries.first { $0["id"] as? String == settingID })
        #expect(entry["agentMutable"] as? Bool == true)
        let values = try #require(catalog["values"] as? [String: Any])
        let projected = try JSONDecoder().decode(BL6SettingValue.self,
            from: JSONSerialization.data(withJSONObject: try #require(values[settingID])))
        guard case .object(var fields) = projected else {
            Issue.record("Missing canonical scoped memory value"); return
        }
        fields["text"] = .text("memory2979 approved edit")
        let change = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(BL6SettingValue.object(fields))) as? [String: Any])
        let initialRevision = try #require(catalog["memoryRevision"] as? String)
        #expect(initialRevision == (try center.memoryStore.bl6MemoryRevision(within: memoryScope)))
        let apply = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": initialRevision, "changes": [settingID: change]
        ], callIDPrefix: "memory2979-apply")
        bridge.chat.streamingProviderOverride = apply
        bridge.chat.draftText = "把当前已授权记忆的文字改为合成编辑值。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(apply.requestCount == 2)
        let applied = try JSONDecoder().decode(BL6SettingsReceipt.self,
            from: Data(try #require(apply.returnedToolMessage).utf8))
        #expect(applied.operation == .apply && applied.changedKeys == [settingID])
        #expect(applied.previousRevision == initialRevision && applied.rollbackValues.isEmpty)
        let profileID = center.settingsStore.directory.standardizedFileURL.path
        let reopened = MemoryStore(directory: center.memoryStore.directory)
        let stored = try #require(try reopened.bl6MemoryReplayRecord(for: applied.requestID, profileID: profileID))
        #expect(stored.settings.receipt == applied)
        #expect(stored.settings.scope == scope.rawValue)
        #expect(stored.before == fact && stored.after.supersedesFactID == fact.id)
        #expect(stored.after.text == "memory2979 approved edit")
        #expect(try reopened.activeFacts().contains { $0.id == stored.after.id && $0.memoryScope == memoryScope })
        let undo = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "rollback", "expectedRevision": applied.effectiveRevision,
            "changes": [:], "undoReceiptID": applied.receiptID
        ], callIDPrefix: "memory2979-undo")
        bridge.chat.streamingProviderOverride = undo
        bridge.chat.draftText = "撤销刚才那条记忆文字编辑。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(undo.requestCount == 2)
        let undone = try JSONDecoder().decode(BL6SettingsReceipt.self,
            from: Data(try #require(undo.returnedToolMessage).utf8))
        #expect(undone.operation == .rollback && undone.changedKeys == [settingID])
        let afterUndo = MemoryStore(directory: center.memoryStore.directory)
        #expect(try afterUndo.activeFacts().contains { $0.id == fact.id && $0.text == fact.text })
        #expect(try afterUndo.activeFacts().allSatisfy { $0.id != stored.after.id })
        #expect(try afterUndo.replayBL6MemoryRecord(stored, profileID: profileID) == applied)
        #expect(try MemoryStore(directory: center.memoryStore.directory).activeFacts().contains {
            $0.id == fact.id && $0.text == "memory2979 original"
        })
        let asked = await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }
        // Each effect requires its own approved call and produces a fresh receipt.
        #expect(asked.count == 2)
        #expect(Set(asked.map(\.requestID)).count == 2)
        #expect(Set(asked.compactMap(\.identityDigest)).count == 2)
        #expect(asked.allSatisfy { $0.approvalScope == scope.rawValue })
        #expect(Set(asked.map(\.callID)).count == asked.count)
        #expect(applied.requestID != undone.requestID && applied.receiptID != undone.receiptID)
    }

    @Test("actual Provider memory mutation rejects drift, foreign scope, forged source and catalog-only consent",
          arguments: ["drift", "foreignScope", "forgedSource", "catalogConsentOnly"])
    func providerMemoryWriteFailsClosed2979(_ boundary: String) async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        center.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        let session = try #require(bridge.chat.activeSessionID)
        bridge.chat.setProject(ChatStore.SessionProject(id: "memory2979-A", name: "合成项目A",
            workingDirectory: root.path), forSession: session)
        _ = try center.provisionBuiltInMemoryCandidateSubmissions()
        try #require(center.addMemoryFact("memory2979 protected"))
        let fact = try #require(center.memoryFacts.first { $0.text == "memory2979 protected" })
        let key = MemoryStoreTypedCatalogAdapter.settingID(for: fact)
        let approval = Settings2094Approval(allowedTools: boundary == "catalogConsentOnly"
            ? [BL6SettingsToolApproval.catalogToolName] : nil)
        await bridge.attachProductionServices(fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let catalog = try await readMemoryCatalog2979(bridge, prefix: "memory2979-negative-read-" + boundary)
        let values = try #require(catalog["values"] as? [String: Any])
        let projected = try JSONDecoder().decode(BL6SettingValue.self,
            from: JSONSerialization.data(withJSONObject: try #require(values[key])))
        guard case .object(var fields) = projected else { Issue.record("Missing canonical object"); return }
        fields["text"] = .text("memory2979 forbidden effect")
        let originalRevision = try #require(catalog["memoryRevision"] as? String)
        if boundary == "drift" { _ = try center.editMemoryFact(id: fact.id, newText: "memory2979 newer live fact") }
        if boundary == "foreignScope" {
            bridge.chat.setProject(ChatStore.SessionProject(id: "memory2979-B", name: "合成项目B",
                workingDirectory: root.path), forSession: session)
        }
        if boundary == "forgedSource", case .object(var source)? = fields["source"] {
            source["sourceProposalID"] = .text("model-forged-source")
            fields["source"] = .object(source)
        }
        let beforeFacts = try Data(contentsOf: center.memoryStore.fileURL)
        let beforeReceipts = try center.memoryStore.lifecycleReceipts()
        let change = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(BL6SettingValue.object(fields))) as? [String: Any])
        let expected = boundary == "foreignScope"
            ? try center.memoryStore.bl6MemoryRevision(within: try #require(center.memoryScopeProvider?()))
            : originalRevision
        let provider = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": expected, "changes": [key: change]
        ], callIDPrefix: "memory2979-reject-" + boundary)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = "尝试合成负面对照，不应产生记忆写入。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(provider.requestCount == 2)
        let rejectedMessage = try #require(provider.returnedToolMessage)
        #expect((try? JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(rejectedMessage.utf8))) == nil)
        #expect(try Data(contentsOf: center.memoryStore.fileURL) == beforeFacts)
        #expect(try MemoryStore(directory: center.memoryStore.directory).lifecycleReceipts() == beforeReceipts)
    }

    private func readMemoryCatalog2979(_ bridge: BridgeStore, prefix: String) async throws -> [String: Any] {
        let provider = Settings2094Provider(name: BL6SettingsToolApproval.catalogToolName, input: [:], callIDPrefix: prefix)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = "读取当前授权记忆的 typed 设置目录。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        try #require(provider.requestCount == 2)
        let message = try #require(provider.returnedToolMessage)
        let decoded = try JSONSerialization.jsonObject(with: Data(message.utf8))
        return try #require(decoded as? [String: Any])
    }

    @Test(arguments: [ComposerApprovalScope.request, ComposerApprovalScope.turn, ComposerApprovalScope.session, ComposerApprovalScope.workspace])
    func providerSkillEnablementUsesOriginalJournal2979(_ approvalScope: ComposerApprovalScope) async throws {
        let (center, bridge, root, skills, _) = try makeFixture(canonicalSkillsState: true)
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        center.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        let session = try #require(bridge.chat.activeSessionID)
        bridge.chat.setProject(ChatStore.SessionProject(id: "skill2979-project", name: "合成技能项目",
            workingDirectory: root.path), forSession: session)
        let memoryScope = try #require(bridge.chat.activeMemoryScope)
        let imported = try center.skillStore.importSkillThroughLifecycle(
            content: "---\nname: Catalog Skills2979\ndescription: synthetic canonical settings\n---\nSKILL2979_OWNED_BODY",
            source: .file, reason: "synthetic user-reviewed local skill",
            scope: memoryScope, approval: SkillApproval(approverID: "synthetic-settings-user", scope: memoryScope))
        skills.reload()
        cafScopedSkillDiagnostics(label: "SKILLA_" + approvalScope.rawValue, skills: skills, store: center.skillStore, skillID: imported.skill.id)
        try #require(skills.catalogRefreshStatus == .ready)
        let initialLifecycle = try #require(center.skillStore.lifecycleReceipt(for: imported.skill.id))
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: center.sessionStore.directory, skillStore: center.skillStore,
            approvalDelegateOverride: approval, externalNetworkAllowed: true).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(mode: .manual,
            approvalScope: approvalScope, effort: .standard, bypassModeConfirmed: false)
        // attach's Task ends before its separate MainActor deployment callback
        // publishes the existing live injector. Wait for that real producer.
        let deploymentDeadline = Date().addingTimeInterval(20)
        while bridge.skillDeploymentStatus == .pending && Date() < deploymentDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if case .ready = bridge.skillDeploymentStatus {} else {
            Issue.record("owned canonical Skill deployment did not become ready")
        }
        let injector = try #require(bridge.skillInjector)
        let query = "Catalog Skills2979 synthetic canonical settings"
        #expect(injector.buildInjectionFragment(for: query, within: memoryScope)?.contains("SKILL2979_OWNED_BODY") == true)
        let catalog = try await readMemoryCatalog2979(bridge, prefix: "skill2979-read")
        let key = "skills.app:" + imported.skill.id + ".enabled"
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        let entry = try #require(entries.first { $0["id"] as? String == key })
        #expect(entry["agentMutable"] as? Bool == true)
        let revision = try #require(catalog["skillsRevision"] as? String)
        let changeObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BL6SettingValue.toggle(false)))
        let change = try #require(changeObject as? [String: Any])
        let apply = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision, "changes": [key: change]
        ], callIDPrefix: "skill2979-disable")
        bridge.chat.streamingProviderOverride = apply
        bridge.chat.draftText = "停用已批准的 Catalog Skills2979。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(apply.requestCount == 2)
        let applied = try JSONDecoder().decode(BL6SettingsReceipt.self,
            from: Data(try #require(apply.returnedToolMessage).utf8))
        #expect(applied.operation == .apply && applied.changedKeys == [key])
        #expect(applied.rollbackValues.isEmpty)
        #expect(!skills.isEnabled("app:" + imported.skill.id))
        #expect(injector.buildInjectionFragment(for: query, within: memoryScope) == nil)
        let reopened = SkillStore(skillsRoot: center.skillStore.skillsRoot)
        #expect(reopened.allSkills().first { $0.id == imported.skill.id }?.isEnabled == false)
        #expect(reopened.lifecycleReceipt(for: imported.skill.id) == initialLifecycle)
        let profileID = center.settingsStore.directory.standardizedFileURL.path
        let original = try #require(try reopened.bl6SkillEnablementReplayRecord(for: applied.requestID, profileID: profileID))
        #expect(original.receipt == applied && original.scope == approvalScope.rawValue)
        #expect(original.rollbackValues == [key: .toggle(true)])
        let undo = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "rollback", "expectedRevision": applied.effectiveRevision,
            "changes": [:], "undoReceiptID": applied.receiptID
        ], callIDPrefix: "skill2979-undo")
        bridge.chat.streamingProviderOverride = undo
        bridge.chat.draftText = "撤销刚才 Catalog Skills2979 的停用。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(undo.requestCount == 2)
        let undone = try JSONDecoder().decode(BL6SettingsReceipt.self,
            from: Data(try #require(undo.returnedToolMessage).utf8))
        #expect(undone.operation == .rollback && undone.changedKeys == [key])
        #expect(skills.isEnabled("app:" + imported.skill.id))
        #expect(injector.buildInjectionFragment(for: query, within: memoryScope)?.contains("SKILL2979_OWNED_BODY") == true)
        let afterUndo = SkillStore(skillsRoot: center.skillStore.skillsRoot)
        #expect(afterUndo.lifecycleReceipt(for: imported.skill.id) == initialLifecycle)
        #expect(afterUndo.allSkills().first { $0.id == imported.skill.id }?.isEnabled == true)
        let shared = root.appendingPathComponent("skills-enabled.json")
        let stateBeforeReplay = try? Data(contentsOf: shared)
        let journalBeforeReplay = try Data(contentsOf: afterUndo.lifecycleReceiptsFileURL)
        #expect(try afterUndo.replayBL6SkillEnablementRecord(original, profileID: profileID) == applied)
        #expect((try? Data(contentsOf: shared)) == stateBeforeReplay)
        #expect(try Data(contentsOf: afterUndo.lifecycleReceiptsFileURL) == journalBeforeReplay)
        #expect(SkillStore(skillsRoot: center.skillStore.skillsRoot).allSkills().first { $0.id == imported.skill.id }?.isEnabled == true)
        let writes = await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }
        #expect(writes.count == 2)
        #expect(Set(writes.map(\.requestID)).count == 2)
        #expect(Set(writes.compactMap(\.identityDigest)).count == 2)
        #expect(writes.allSatisfy { $0.approvalScope == approvalScope.rawValue })
        #expect(Set(writes.map(\.callID)).count == writes.count)
        #expect(applied.requestID != undone.requestID && applied.receiptID != undone.receiptID)
    }

    @Test("actual Provider Skill write rejects stale state, foreign scope, changed payload, read-only source and missing grants",
          arguments: ["drift", "foreignScope", "changedPayload", "catalogConsentOnly", "hermes", "pending"])
    func providerSkillEnablementFailsClosed2979(_ boundary: String) async throws {
        let (center, bridge, root, skills, _) = try makeFixture(
            includeSyntheticSkill: boundary == "hermes", canonicalSkillsState: true)
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        center.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        let session = try #require(bridge.chat.activeSessionID)
        bridge.chat.setProject(ChatStore.SessionProject(id: "skill2979-A", name: "合成项目A",
            workingDirectory: root.path), forSession: session)
        let scope = try #require(bridge.chat.activeMemoryScope)
        let imported = try center.skillStore.importSkillThroughLifecycle(
            content: "---\nname: Negative Skills2979\ndescription: synthetic protected\n---\nSKILL2979_PROTECTED_BODY",
            source: .file, reason: "synthetic original user approval",
            scope: boundary == "pending" ? nil : scope,
            approval: boundary == "pending" ? nil : SkillApproval(approverID: "synthetic-original-user", scope: scope))
        skills.reload()
        try #require(skills.catalogRefreshStatus == .ready)
        let approval = Settings2094Approval(allowedTools: boundary == "catalogConsentOnly"
            ? [BL6SettingsToolApproval.catalogToolName] : nil)
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: center.sessionStore.directory, skillStore: center.skillStore,
            approvalDelegateOverride: approval, externalNetworkAllowed: true).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(mode: .manual,
            approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        let catalog = try await readMemoryCatalog2979(bridge, prefix: "skill2979-negative-read-" + boundary)
        var key = "skills.app:" + imported.skill.id + ".enabled"
        if boundary == "hermes" {
            let entry = try #require(skills.entries.first { $0.source == .localDirectory })
            key = SkillsStoreTypedCatalogAdapter.settingID(for: entry)
            let entries = try #require(catalog["entries"] as? [[String: Any]])
            let row = try #require(entries.first { $0["id"] as? String == key })
            #expect(row["agentMutable"] as? Bool == false)
        }
        if boundary == "pending" {
            let entries = try #require(catalog["entries"] as? [[String: Any]])
            #expect(entries.allSatisfy { $0["id"] as? String != key })
        }
        var expectedRevision = try #require(catalog["skillsRevision"] as? String)
        if boundary == "drift" { try skills.setEnabled("app:" + imported.skill.id, enabled: false).get() }
        if boundary == "foreignScope" {
            bridge.chat.setProject(ChatStore.SessionProject(id: "skill2979-B", name: "合成项目B",
                workingDirectory: root.path), forSession: session)
            let current = try #require(bridge.chat.activeMemoryScope)
            expectedRevision = try center.skillStore.bl6SkillEnablementSnapshot(visibleTo: current).revision
        }
        if boundary == "changedPayload" {
            try "---\nname: Negative Skills2979\n---\nforged payload".write(
                to: center.skillStore.skillDirectoryURL(for: imported.skill.id).appendingPathComponent("SKILL.md"),
                atomically: true, encoding: .utf8)
            // Let the original owner quarantine this source drift before the
            // attempted settings write. That safety transition is not a BL6
            // enablement effect and must not be mistaken for one below.
            center.skillStore.reload()
            skills.reload()
        }
        let lifecycle = center.skillStore.lifecycleReceipt(for: imported.skill.id)
        let journalBefore = try Data(contentsOf: center.skillStore.lifecycleReceiptsFileURL)
        let stateBefore = try? Data(contentsOf: root.appendingPathComponent("skills-enabled.json"))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BL6SettingValue.toggle(false)))
        let change = try #require(object as? [String: Any])
        let writer = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": expectedRevision, "changes": [key: change]
        ], callIDPrefix: "skill2979-negative-write-" + boundary)
        bridge.chat.streamingProviderOverride = writer
        bridge.chat.draftText = "合成负面对照应拒绝技能状态写入。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(writer.requestCount == 2)
        let message = try #require(writer.returnedToolMessage)
        #expect((try? JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(message.utf8))) == nil)
        #expect(try Data(contentsOf: center.skillStore.lifecycleReceiptsFileURL) == journalBefore)
        #expect((try? Data(contentsOf: root.appendingPathComponent("skills-enabled.json"))) == stateBefore)
        #expect(center.skillStore.lifecycleReceipt(for: imported.skill.id) == lifecycle)
    }

    @Test("actual Provider reads each canonical provider record without URL or credential authority",
          arguments: ComposerApprovalScope.allCases)
    func providerRecordDirectoryUsesCanonicalReopen2979(_ scope: ComposerApprovalScope) async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        center.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        let providerID = "SETC2979_PROVIDER_API_KEY"
        let url = "https://provider2979.example/v1"
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: center.sessionStore.directory, approvalDelegateOverride: approval,
            externalNetworkAllowed: true).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: scope, effort: .standard, bypassModeConfirmed: false)
        // 空的隔离 fixture 是 credential absence 的负向对照；不得凭 registry 自证。
        let absentCatalog = try await readMemoryCatalog2979(bridge, prefix: "provider2979-absent")
        let absentWire = String(decoding: try JSONSerialization.data(withJSONObject: absentCatalog), as: UTF8.self)
        #expect(!absentWire.contains("synthetic2979-provider-key"))
        #expect(!absentWire.contains("synthetic2979-env-value"))
        let absentValues = try decodeCatalogValues(absentCatalog)
        #expect(absentValues["credential.provider-api-key"] == .redactedSecret(present: false))
        let absentEntries = try #require(absentCatalog["entries"] as? [[String: Any]])
        #expect(!absentEntries.contains { ($0["id"] as? String)?.hasPrefix("provider.record.") == true })

        try #require(center.saveProvider(name: providerID, credential: .replace("synthetic2979-provider-key"),
            baseURL: url, modelNames: ["model2979"], protocolType: .openaiResponses))
        try #require(center.setEnvVar(name: "SETC2979_PLAIN_ENV", value: "synthetic2979-env-value", isSecret: true))
        let canonical = try #require(center.chatProviderSettingsProjection(providerID: providerID))
        #expect(canonical.credentialPresent)
        let catalog = try await readMemoryCatalog2979(bridge, prefix: "provider2979-read")
        let output = String(decoding: try JSONSerialization.data(withJSONObject: catalog), as: UTF8.self)
        #expect(!output.contains(url) && !output.contains(canonical.metadataRevision))
        #expect(!output.contains("synthetic2979-provider-key") && !output.contains("synthetic2979-env-value"))
        #expect(!output.contains("SETC2979_PLAIN_ENV"))
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        let providerEntries = entries.filter { ($0["id"] as? String)?.hasPrefix("provider.record.") == true }
        #expect(providerEntries.count == center.providerRecords.count)
        #expect(providerEntries.count == 1)
        let entry = try #require(providerEntries.first)
        #expect(entry["agentMutable"] as? Bool == false)
        let id = try #require(entry["id"] as? String)
        let values = try decodeCatalogValues(catalog)
        #expect(values["credential.provider-api-key"] == .redactedSecret(present: true))
        let projected = try #require(values[id])
        guard case .object(let fields) = projected else { Issue.record("Provider metadata object missing"); return }
        #expect(fields["providerID"] == .text(canonical.providerID))
        #expect(fields["modelIDs"] == .list(canonical.modelIDs))
        #expect(fields["protocolType"] == .text(canonical.protocolType.rawValue))
        #expect(fields["credential"] == .redactedSecret(present: canonical.credentialPresent))
        let revision = try #require(fields["metadataRevision"])
        guard case .text(let token) = revision else { Issue.record("Metadata digest missing"); return }
        #expect(token.count == 64 && token.allSatisfy { $0.isHexDigit })
        let recordsBefore = center.providerRecords
        let change = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(projected)) as? [String: Any])
        let writer = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": try #require(catalog["catalogRevision"] as? String),
            "changes": [id: change]
        ], callIDPrefix: "provider2979-forbidden-write")
        bridge.chat.streamingProviderOverride = writer
        bridge.chat.draftText = "尝试将只读供应商目录作为修改，应拒绝。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(writer.requestCount == 2)
        let message = try #require(writer.returnedToolMessage)
        #expect((try? JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(message.utf8))) == nil)
        #expect(center.providerRecords == recordsBefore)
        #expect(center.chatProviderSettingsProjection(providerID: providerID) == canonical)
        #expect(throws: BL6SettingsDispatchError.self) {
            try BL6SettingsApprovedInput(operation: .configureProvider, expectedRevision: "same-fence").validateForApprovedEffect()
        }
        let asked = await approval.requests
        #expect(asked.contains { $0.toolName == BL6SettingsToolApproval.catalogToolName && $0.approvalScope == scope.rawValue })
    }

    @Test("production Provider offers MCP metadata and read-only authorization without exposing secrets")
    func providerCatalogReadsOnlyMCPMetadata() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let server = MCPServer(
            id: "synthetic.server", name: "Synthetic MCP", type: .http,
            enabled: true, command: "fixture-command-secret", args: ["fixture-arg-secret"],
            env: ["TOKEN": "fixture-env-secret"], url: "https://fixture-url-secret.invalid",
            headers: ["Authorization": "fixture-header-secret"]
        )
        try center.mcpManager.addServer(server)
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        let prefix = "mcp." + server.id.utf8.map { String(format: "%02x", $0) }.joined()
        let approval = Settings2094Approval(allowedTools: [BL6SettingsToolApproval.catalogToolName])
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        let read = Settings2094Provider(name: BL6SettingsToolApproval.catalogToolName, input: [:])
        bridge.chat.streamingProviderOverride = read
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        bridge.chat.draftText = "查看当前设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(read.requestCount == 2)
        let body = try #require(read.returnedToolMessage)
        let catalog = try #require(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        let values = try decodeCatalogValues(catalog)
        #expect(values["\(prefix).name"] == .text("Synthetic MCP"))
        #expect(values["\(prefix).enabled"] == .toggle(true))
        #expect(values["\(prefix).authorized"] == .toggle(true))
        #expect(values["\(prefix).type"] == .text("http"))
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        #expect(entries.filter { ($0["id"] as? String)?.hasPrefix(prefix) == true }.count == 4)
        #expect(entries.first { $0["id"] as? String == "\(prefix).name" }?["agentMutable"] as? Bool == true)
        #expect(entries.first { $0["id"] as? String == "\(prefix).enabled" }?["agentMutable"] as? Bool == true)
        #expect(entries.first { $0["id"] as? String == "\(prefix).authorized" }?["agentMutable"] as? Bool == false)
        #expect(entries.first { $0["id"] as? String == "\(prefix).type" }?["agentMutable"] as? Bool == false)
        for secret in ["fixture-command-secret", "fixture-arg-secret", "fixture-env-secret",
                       "fixture-url-secret", "fixture-header-secret", "Authorization", "TOKEN"] {
            #expect(!body.contains(secret))
        }

        let revision = try #require(catalog["mcpRevision"] as? String)
        #expect(revision == center.mcpManager.bl6NameRevision())
        let deniedWrite = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision,
            "changes": ["\(prefix).enabled": ["kind": "toggle", "toggle": false]]
        ])
        bridge.chat.streamingProviderOverride = deniedWrite
        bridge.chat.draftText = "调整连接设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(deniedWrite.requestCount == 2)
        #expect(deniedWrite.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(center.mcpManager.server(id: server.id)?.enabled == true)
    }

    @Test("Provider reads admitted MCP tool grants as metadata and cannot mutate them or transport type")
    func providerCatalogReadsAdmittedToolAuthorizationWithoutGrantingWrites2893() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let server = MCPServer(
            id: "setc-tools2893", name: "Synthetic MCP", type: .http,
            enabled: true, url: "https://mcp.invalid"
        )
        try center.mcpManager.addServer(server)
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        #expect(center.setMCPToolAuthorized(serverID: server.id, toolName: "read.name/β", authorized: true))
        _ = try await center.mcpManager.discoverTools(serverID: server.id) { server in
            MCPClient(server: server, transport: Settings2893CatalogTransport())
        }
        let prefix = "mcp." + server.id.utf8.map { String(format: "%02x", $0) }.joined()
        let readKey = prefix + ".tools."
            + "read.name/β".utf8.map { String(format: "%02x", $0) }.joined() + ".authorized"
        let deniedKey = prefix + ".tools."
            + "write".utf8.map { String(format: "%02x", $0) }.joined() + ".authorized"
        let unknownKey = prefix + ".tools."
            + "unknown".utf8.map { String(format: "%02x", $0) }.joined() + ".authorized"
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        let beforeConfig = try Data(contentsOf: center.mcpManager.fileURL)
        let beforeGrants = try Data(contentsOf: center.mcpManager.authorizationFileURL)
        let read = Settings2094Provider(name: BL6SettingsToolApproval.catalogToolName, input: [:])
        bridge.chat.streamingProviderOverride = read
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        bridge.chat.draftText = "查看合成工具授权设置。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat, approval: approval)
        #expect(read.requestCount == 2)
        let body = try #require(read.returnedToolMessage)
        let catalog = try #require(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        let values = try decodeCatalogValues(catalog)
        #expect(values[readKey] == .toggle(true))
        #expect(values[deniedKey] == .toggle(false))
        #expect(values[unknownKey] == nil)
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        #expect(entries.filter { ($0["id"] as? String)?.hasPrefix(prefix) == true }.count == 6)
        for key in [readKey, deniedKey, "\(prefix).type"] {
            #expect(entries.first { $0["id"] as? String == key }?["agentMutable"] as? Bool == false)
        }
        #expect(!body.contains("fixture-schema-secret"))
        #expect(try Data(contentsOf: center.mcpManager.fileURL) == beforeConfig)
        #expect(try Data(contentsOf: center.mcpManager.authorizationFileURL) == beforeGrants)

        let revision = try #require(catalog["mcpRevision"] as? String)
        let rejectedChanges: [(key: String, value: [String: Any])] = [
            (readKey, ["kind": "toggle", "toggle": false]),
            (deniedKey, ["kind": "toggle", "toggle": true]),
            ("\(prefix).type", ["kind": "text", "text": "stdio"])
        ]
        for (index, change) in rejectedChanges.enumerated() {
            let write = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
                "operation": "apply", "expectedRevision": revision,
                "changes": [change.key: change.value]
            ], callIDPrefix: "settings2893-readonly-\(index)")
            bridge.chat.streamingProviderOverride = write
            bridge.chat.draftText = "尝试修改只读的合成目录值。"
            bridge.chat.submitComposer()
            try await settle(bridge.chat, approval: approval)
            #expect(write.requestCount == 2)
            #expect(write.returnedToolMessage?.contains("Error executing tool") == true)
            #expect(try Data(contentsOf: center.mcpManager.fileURL) == beforeConfig)
            #expect(try Data(contentsOf: center.mcpManager.authorizationFileURL) == beforeGrants)
        }
        #expect(center.isMCPToolAuthorized(serverID: server.id, toolName: "read.name/β"))
        #expect(!center.isMCPToolAuthorized(serverID: server.id, toolName: "write"))
        #expect(center.mcpManager.server(id: server.id)?.type == .http)

        func readCurrentCatalog3152(_ suffix: String) async throws -> [String: Any] {
            let config = try Data(contentsOf: center.mcpManager.fileURL)
            let grants = try Data(contentsOf: center.mcpManager.authorizationFileURL)
            let provider = Settings2094Provider(
                name: BL6SettingsToolApproval.catalogToolName, input: [:],
                callIDPrefix: "settings3152-read-\(suffix)"
            )
            bridge.chat.streamingProviderOverride = provider
            bridge.chat.draftText = "读取当前合成只读目录。"
            bridge.chat.submitComposer()
            try await settle(bridge.chat, approval: approval)
            #expect(provider.requestCount == 2)
            let result = try #require(provider.returnedToolMessage)
            #expect(!result.contains("fixture-schema-secret"))
            #expect(try Data(contentsOf: center.mcpManager.fileURL) == config)
            #expect(try Data(contentsOf: center.mcpManager.authorizationFileURL) == grants)
            return try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        }

        // Reading the catalog must not perform discovery to manufacture a
        // current tool capability. A tool grant edit does not change the remote
        // schema, so the already accepted discovery snapshot stays valid and the
        // catalog keeps listing the tools with their updated (revoked) state;
        // earlier this was asserted as "entries disappear", which pinned the
        // defect that any grant edit cleared the tool list. Whether the read
        // performed discovery is shown directly by the snapshot's publication
        // identity: a discovery would publish a new one.
        #expect(center.setMCPToolAuthorized(serverID: server.id, toolName: "read.name/β", authorized: false))
        let publicationBeforeRead = try #require(
            center.mcpManager.discoverySnapshot(serverID: server.id)?.publicationID)
        let fenced = try await readCurrentCatalog3152("fenced")
        #expect(center.mcpManager.discoverySnapshot(serverID: server.id)?.publicationID == publicationBeforeRead)
        let fencedValues = try decodeCatalogValues(fenced)
        #expect(fencedValues[readKey] == .toggle(false))
        #expect(fencedValues[deniedKey] == .toggle(false))
        #expect(fencedValues[unknownKey] == nil)
        let fencedEntries = try #require(fenced["entries"] as? [[String: Any]])
        #expect(fencedEntries.filter { ($0["id"] as? String)?.hasPrefix(prefix) == true }.count == 6)
        #expect(fencedEntries.first { $0["id"] as? String == readKey }?["agentMutable"] as? Bool == false)
        _ = try await center.mcpManager.discoverTools(serverID: server.id) { server in
            MCPClient(server: server, transport: Settings2893CatalogTransport())
        }
        let revoked = try await readCurrentCatalog3152("revoked")
        let revokedValues = try decodeCatalogValues(revoked)
        #expect(revokedValues[readKey] == .toggle(false))
        #expect(revokedValues[deniedKey] == .toggle(false))
        #expect(revokedValues[unknownKey] == nil)
        let revokedEntries = try #require(revoked["entries"] as? [[String: Any]])
        #expect(revokedEntries.filter { ($0["id"] as? String)?.hasPrefix(prefix) == true }.count == 6)
        #expect(revokedEntries.first { $0["id"] as? String == readKey }?["agentMutable"] as? Bool == false)

        // The original native draft changes transport metadata; the model
        // still has no mutation authority for the projected enum.
        let currentServer3152 = try #require(center.mcpManager.server(id: server.id))
        var draft = MCPServerEditDraft(existing: currentServer3152)
        draft.type = .stdio
        draft.command = "fixture-command-secret"
        draft.enabled = false
        #expect(draft.save(to: center))
        let changed = try await readCurrentCatalog3152("type")
        let changedValues = try decodeCatalogValues(changed)
        #expect(changedValues["\(prefix).type"] == .text("stdio"))
        #expect(changedValues[readKey] == nil && changedValues[deniedKey] == nil)
        let changedEntries = try #require(changed["entries"] as? [[String: Any]])
        #expect(changedEntries.filter { ($0["id"] as? String)?.hasPrefix(prefix) == true }.count == 4)
        #expect(changedEntries.first { $0["id"] as? String == "\(prefix).type" }?["agentMutable"] as? Bool == false)
        #expect(!String(describing: changed).contains("fixture-command-secret"))
    }

    @Test("approved Provider cannot write projected MCP authorization")
    func approvedProviderCannotMutateMCPAuthorization() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let server = MCPServer(
            id: "setc-authorized", name: "Synthetic MCP", type: .http,
            enabled: true, url: "https://mcp.invalid"
        )
        try center.mcpManager.addServer(server)
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        let authorizationFile = center.mcpManager.authorizationFileURL
        let before = try Data(contentsOf: authorizationFile)
        let key = "mcp." + server.id.utf8.map { String(format: "%02x", $0) }.joined() + ".authorized"
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        let revision = try #require(center.mcpManager.bl6NameRevision())
        let write = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision,
            "changes": [key: ["kind": "toggle", "toggle": false]]
        ])
        bridge.chat.streamingProviderOverride = write
        bridge.chat.draftText = "修改合成 MCP 授权状态。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(write.requestCount == 2)
        let requests = await approval.requests
        #expect(requests.contains { $0.toolName == BL6SettingsToolApproval.toolName })
        #expect(write.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(center.isMCPServerAuthorized(id: server.id))
        let after = try Data(contentsOf: authorizationFile)
        #expect(after == before)
    }

    @Test("approved Provider MCP disable and undo persist the bit but never restore an old grant")
    func approvedMCPEnablementUsesCanonicalStoreAndFreshGrantBoundary() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let server = MCPServer(
            id: "setc-enabled", name: "Synthetic MCP", type: .http,
            enabled: true, url: "https://mcp.invalid"
        )
        try center.mcpManager.addServer(server)
        _ = try center.mcpManager.authorizeServer(id: server.id)
        let key = "mcp." + server.id.utf8.map { String(format: "%02x", $0) }.joined() + ".enabled"
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        let before = try #require(center.mcpManager.bl6NameRevision())
        let disable = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": before,
            "changes": [key: ["kind": "toggle", "toggle": false]]
        ])
        bridge.chat.streamingProviderOverride = disable
        bridge.chat.draftText = "禁用这个合成 MCP。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(disable.requestCount == 2)
        let disableBody = try #require(disable.returnedToolMessage)
        let disableReceipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(disableBody.utf8))
        #expect(disableReceipt.changedKeys == [key])
        #expect(center.mcpManager.server(id: server.id)?.enabled == false)
        #expect(center.mcpManager.authorization(serverID: server.id) == nil)
        let reopenedDisabled = MCPServerManager(
            fileURL: center.mcpManager.fileURL,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            authorizationFileURL: center.mcpManager.authorizationFileURL
        )
        #expect(reopenedDisabled.server(id: server.id)?.enabled == false)
        #expect(reopenedDisabled.authorization(serverID: server.id) == nil)
        let disabledReplay = try reopenedDisabled.bl6EnablementReplayRecord(
            for: disableReceipt.requestID, profileID: center.settingsStore.directory.standardizedFileURL.path
        ).get()
        #expect(disabledReplay?.receipt == disableReceipt)

        let undoRevision = try #require(center.mcpManager.bl6NameRevision())
        let undo = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "rollback", "expectedRevision": undoRevision,
            "undoReceiptID": disableReceipt.receiptID, "changes": [String: Any]()
        ], callIDPrefix: "settings2094-enabled-undo")
        bridge.chat.streamingProviderOverride = undo
        bridge.chat.draftText = "撤销刚才的合成开关修改。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(undo.requestCount == 2)
        let undoBody = try #require(undo.returnedToolMessage)
        let undoReceipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(undoBody.utf8))
        #expect(undoReceipt.changedKeys == [key])
        let reopenedEnabled = MCPServerManager(
            fileURL: center.mcpManager.fileURL,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            authorizationFileURL: center.mcpManager.authorizationFileURL
        )
        #expect(reopenedEnabled.server(id: server.id)?.enabled == true)
        #expect(reopenedEnabled.authorization(serverID: server.id) == nil)
        let enabledReplay = try reopenedEnabled.bl6EnablementReplayRecord(
            for: undoReceipt.requestID, profileID: center.settingsStore.directory.standardizedFileURL.path
        ).get()
        #expect(enabledReplay?.receipt == undoReceipt)
    }

    @Test("production Provider reads only the App-owned Skills and scoped Scheduler values")
    func providerCatalogReadsBoundSkillsAndVisibleScheduler() async throws {
        let (center, bridge, root, skills, scheduler) = try makeFixture(includeSyntheticSkill: true)
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        #expect(skills.catalogRefreshStatus == .ready)
        let session = try #require(bridge.chat.activeSessionID)
        bridge.chat.setProject(
            ChatStore.SessionProject(id: "project-A", name: "合成项目", workingDirectory: root.path),
            forSession: session
        )
        center.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        #expect(scheduler.add(
            name: "Synthetic visible task", cronExpression: "0 9 * * *",
            command: "SYNTHETIC_PRIVATE_COMMAND_2170", isEnabled: false,
            targetSessionID: session, targetProjectID: "project-A", targetTurnID: 1
        ) == nil)
        let task = try #require(scheduler.tasks.first)
        let schedulePrefix = "scheduler.\(task.id.uuidString.lowercased())"
        let skillKey = "skills.local:" + SkillManifest.hash(root.appendingPathComponent("hermes/creative/catalog-owned/SKILL.md").standardizedFileURL.path) + ".enabled"
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value

        func readCatalog() async throws -> (String, [String: Any]) {
            let provider = Settings2094Provider(
                name: BL6SettingsToolApproval.catalogToolName, input: [:]
            )
            bridge.chat.streamingProviderOverride = provider
            bridge.chat.composerPolicySelection = ComposerPolicySelection(
                mode: .manual, approvalScope: .request,
                effort: .standard, bypassModeConfirmed: false
            )
            bridge.chat.draftText = "查看当前设置。"
            bridge.chat.submitComposer()
            try await settle(bridge.chat)
            #expect(provider.requestCount == 2)
            let body = try #require(provider.returnedToolMessage)
            let parsed = try #require(
                JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            )
            return (body, parsed)
        }

        let (body, first) = try await readCatalog()
        let values = try decodeCatalogValues(first)
        #expect(values["credential.provider-api-key"] == .redactedSecret(present: false))
        #expect(values[skillKey] == .toggle(false))
        #expect(values["\(schedulePrefix).name"] == .text(task.name))
        #expect(values["\(schedulePrefix).cron-expression"] == .text("0 9 * * *"))
        #expect(values["\(schedulePrefix).enabled"] == .toggle(false))
        #expect(values["\(schedulePrefix).authorized"] == .toggle(false))
        let entries = try #require(first["entries"] as? [[String: Any]])
        #expect(entries.filter {
            ($0["id"] as? String == skillKey)
                || ($0["id"] as? String)?.hasPrefix(schedulePrefix) == true
        }.count == 5)
        #expect(entries.filter {
            ($0["id"] as? String == skillKey)
                || ($0["id"] as? String)?.hasPrefix(schedulePrefix) == true
        }.allSatisfy { ($0["agentMutable"] as? Bool) == (($0["id"] as? String) == "\(schedulePrefix).enabled") })
        #expect(!body.contains("SYNTHETIC_PRIVATE_COMMAND_2170"))
        #expect(scheduler.authorize(task.id, actorID: "SYNTHETIC_PRIVATE_ACTOR_2893"))
        let (authorizedBody, authorizedCatalog) = try await readCatalog()
        let authorizedValues = try decodeCatalogValues(authorizedCatalog)
        #expect(authorizedValues["credential.provider-api-key"] == .redactedSecret(present: false))
        #expect(authorizedValues["\(schedulePrefix).authorized"] == .toggle(true))
        let authorizedEntries = try #require(authorizedCatalog["entries"] as? [[String: Any]])
        #expect(authorizedEntries.first {
            $0["id"] as? String == "\(schedulePrefix).authorized"
        }?["agentMutable"] as? Bool == false)
        #expect(!authorizedBody.contains("SYNTHETIC_PRIVATE_ACTOR_2893"))
        #expect(scheduler.revokeAuthorization(task.id))
        let (_, revokedCatalog3152) = try await readCatalog()
        let revokedValues3152 = try decodeCatalogValues(revokedCatalog3152)
        #expect(revokedValues3152["credential.provider-api-key"] == .redactedSecret(present: false))
        #expect(revokedValues3152["\(schedulePrefix).authorized"] == .toggle(false))
        #expect(scheduler.task(id: task.id)?.isEnabled == false)
        #expect(scheduler.occurrences.isEmpty && scheduler.occurrenceJournal.isEmpty)
        #expect(!body.contains("targetSessionID") && !body.contains("authorizationActorID"))

        bridge.chat.setProject(
            ChatStore.SessionProject(id: "project-B", name: "另一合成项目", workingDirectory: root.path),
            forSession: session
        )
        let (_, second) = try await readCatalog()
        let secondValues = try #require(second["values"] as? [String: Any])
        #expect(secondValues[skillKey] != nil)
        #expect(!secondValues.keys.contains { $0.hasPrefix(schedulePrefix) })
        #expect(scheduler.task(id: task.id)?.targetProjectID == "project-A")
    }

    @Test("model mutation cannot turn a read-only Skills or Scheduler catalog row into an effect",
          arguments: ["skills", "scheduler-authorization"])
    func providerRejectsReadOnlyStoreMutation(_ target: String) async throws {
        let (center, bridge, root, skills, scheduler) = try makeFixture(includeSyntheticSkill: true)
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let session = try #require(bridge.chat.activeSessionID)
        bridge.chat.setProject(
            ChatStore.SessionProject(id: "project-A", name: "合成项目", workingDirectory: root.path),
            forSession: session
        )
        center.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        #expect(scheduler.add(
            name: "Synthetic immutable task", cronExpression: "0 9 * * *",
            command: "SYNTHETIC_PRIVATE_COMMAND_2170", isEnabled: false,
            targetSessionID: session, targetProjectID: "project-A", targetTurnID: 1
        ) == nil)
        let task = try #require(scheduler.tasks.first)
        let skillKey = "skills.local:" + SkillManifest.hash(root.appendingPathComponent("hermes/creative/catalog-owned/SKILL.md").standardizedFileURL.path) + ".enabled"
        let schedulerKey = SchedulerStoreTypedCatalogAdapter.settingID(
            taskID: task.id, field: "authorized"
        )
        let key = target == "skills" ? skillKey : schedulerKey
        let proposed = true
        let approval = Settings2094Approval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        let revision = try #require(center.bl6EffectiveSettingsSnapshot?.catalogRevision)
        let provider = Settings2094Provider(name: BL6SettingsToolApproval.toolName, input: [
            "operation": "apply", "expectedRevision": revision,
            "changes": [key: ["kind": "toggle", "toggle": proposed]]
        ])
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        bridge.chat.draftText = "调整只读目录项。"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(provider.requestCount == 2)
        #expect(provider.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(!skills.isEnabled("local:" + SkillManifest.hash(root.appendingPathComponent("hermes/creative/catalog-owned/SKILL.md").standardizedFileURL.path)))
        #expect(scheduler.task(id: task.id)?.isEnabled == false)
        #expect(scheduler.task(id: task.id)?.isAuthorized == false)
        let reopened = SchedulerTaskStore(
            defaults: bridge.preferencesDefaults,
            occurrenceLedgerURL: root.appendingPathComponent("scheduler-occurrences.json")
        )
        #expect(reopened.task(id: task.id)?.isEnabled == false)
        #expect(reopened.task(id: task.id)?.isAuthorized == false)
    }
}

@MainActor
private func cafScopedSkillDiagnostics(label: String, skills: SkillsStore, store: SkillStore, skillID: String) {
    let snapshot = store.snapshot()
    let root = store.skillDirectoryURL(for: skillID).standardizedFileURL
    let unresolved = root.appendingPathComponent("SKILL.md").standardizedFileURL
    let resolved = unresolved.resolvingSymlinksInPath()
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    func identity(_ url: URL) -> [String: String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return [:] }
        return ["device": String(describing: attributes[.systemNumber] ?? "UNKNOWN"),
                "inode": String(describing: attributes[.systemFileNumber] ?? "UNKNOWN"),
                "type": String(describing: attributes[.type] ?? "UNKNOWN")]
    }
    let fileIdentity = identity(unresolved), resolvedIdentity = identity(resolved)
    let rootIdentity = identity(root), normalizedRootIdentity = identity(resolvedRoot)
    let metadata: [String: Any] = [
        "label": label, "catalogStatus": String(describing: skills.catalogRefreshStatus),
        "stableSummary": skills.catalogDiagnostics.stableSummary,
        "samples": skills.catalogDiagnostics.samples.map {
            ["source": String(describing: $0.source), "code": String(describing: $0.code), "locator": $0.locator]
        },
        "snapshotHasSKILLmd": snapshot.fileContents[skillID]?["SKILL.md"] != nil,
        "snapshotHasRawContent": snapshot.rawContents[skillID] != nil,
        "listedHasSKILLmd": store.listSkillFiles(skillID).contains("SKILL.md"),
        "liveRawContentNonNil": store.rawContent(skillID) != nil,
        "liveReadSkillFileNonNil": store.readSkillFile(skillID, relativePath: "SKILL.md") != nil,
        "rootStandard": root.path, "fileUnresolved": unresolved.path,
        "fileResolved": resolved.path, "rootResolved": resolvedRoot.path,
        "existingGuardPrefix": resolved.path == root.path || resolved.path.hasPrefix(root.path + "/"),
        "jointNormalizedPrefix": resolved.path == resolvedRoot.path || resolved.path.hasPrefix(resolvedRoot.path + "/"),
        "fileIdentity": fileIdentity, "resolvedFileIdentity": resolvedIdentity,
        "rootIdentity": rootIdentity, "resolvedRootIdentity": normalizedRootIdentity,
        "filePhysicalIdentityMatches": !fileIdentity.isEmpty && fileIdentity == resolvedIdentity,
        "rootPhysicalIdentityMatches": !rootIdentity.isEmpty && rootIdentity == normalizedRootIdentity
    ]
    if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
       let output = String(data: data, encoding: .utf8) {
        print("CAF_SKILL_DIAGNOSTIC " + output)
    }
}
