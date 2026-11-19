import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// 快档修复线 A（权限与设置分发）RED：
// M05 设置改动不得覆盖会话模式；M04 上限不足文案；M06 撤销失效说明；
// 第 4 条 下调自主权上限后自动降为手动审批（仅状态/逻辑层）。

private actor QuickFixAApproval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
                         requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private final class QuickFixAProvider:
    LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable
{
    let name = "quickfixa-offline"
    var model = LLMModel(id: "quickfixa-model", displayName: "QuickFixA", provider: "quickfixa-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "quickfixa-isolated"
    private let lock = NSLock()
    private var requests: [[LLMMessage]] = []
    private let callInput: [String: Any]
    private let callID: String

    init(input: [String: Any], callID: String) {
        callInput = input
        self.callID = callID
    }

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
                id: callID, name: BL6SettingsToolApproval.toolName,
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

@Suite("QuickFixA 权限与设置分发", .serialized)
@MainActor
struct QuickFixAPermissionSettingsDispatchTests {
    private static let fontKey = "typography.ui-base-font-size"

    // MARK: 夹具（直接 SettingsCenter，无聊天）

    private func makeCenter() throws -> (SettingsCenter, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFixA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            providerReadinessTransport: FailClosedProviderReadinessTransport()
        )
        return (center, root)
    }

    private func intent(
        _ id: String, _ operation: BL6SettingsOperation = .apply,
        changes: [String: BL6SettingValue] = [:], revision: String
    ) -> BL6SettingsIntent {
        BL6SettingsIntent(
            requestID: id, operation: operation, changes: changes,
            expectedRevision: revision, approval: .approved(receiptID: "approval-\(id)")
        )
    }

    private let bypassDefault = ComposerPolicySettings(
        mode: .bypassPermission, approvalScope: .request, effort: .standard,
        bypassModeConfirmed: true
    )
    private let manualSelection = ComposerPolicySelection(
        mode: .manual, approvalScope: .request, effort: .standard, bypassModeConfirmed: false
    )

    // MARK: M05 · 无关设置不得再次下发 Composer 默认策略

    @Test("M05 只改字号的 apply 与 rollback 不触发 onComposerPolicyChanged")
    func fontSizeApplyAndRollbackDoNotRepublishComposerPolicy() throws {
        let (center, root) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        center.composerPolicy = bypassDefault
        var republished = 0
        center.onComposerPolicyChanged = { _ in republished += 1 }

        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        guard case .success(let applied) = center.dispatchBL6Settings(intent(
            "qfa-font-apply", changes: [Self.fontKey: .integer(16)], revision: before.catalogRevision
        )) else { Issue.record("字号 apply 应成功"); return }
        #expect(republished == 0, "apply 后不应回调 onComposerPolicyChanged（M05，BL6SettingsCenterDispatch.swift:398/:1171）")

        let after = try #require(center.bl6EffectiveSettingsSnapshot)
        guard case .success = center.dispatchBL6Settings(intent(
            "qfa-font-rollback", .rollback, changes: applied.rollbackValues, revision: after.catalogRevision
        )) else { Issue.record("字号 rollback 应成功"); return }
        #expect(republished == 0, "rollback 后不应回调 onComposerPolicyChanged（M05，:1248 同类）")
    }

    @Test("M05 全局选择绕过权限、默认上限 L2，设置里改字号后会话已选“手动审批”保持不变")
    func fontSizeChangeKeepsSessionManualSelection() throws {
        let (center, root) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        center.composerPolicy = bypassDefault
        #expect(center.policyRuntimeDefaults.autonomyLevel == .l2)
        let chat = ChatStore()
        // 与 MinisCanvasApp.swift:1578 的生产接线一致。
        center.onComposerPolicyChanged = { [weak chat] policy in chat?.restoreComposerPolicy(policy) }
        chat.composerPolicySelection = manualSelection

        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        guard case .success(let applied) = center.dispatchBL6Settings(intent(
            "qfa-keep-apply", changes: [Self.fontKey: .integer(16)], revision: before.catalogRevision
        )) else { Issue.record("字号 apply 应成功"); return }
        #expect(chat.composerPolicySelection.mode == .manual)

        let after = try #require(center.bl6EffectiveSettingsSnapshot)
        guard case .success = center.dispatchBL6Settings(intent(
            "qfa-keep-rollback", .rollback, changes: applied.rollbackValues, revision: after.catalogRevision
        )) else { Issue.record("字号 rollback 应成功"); return }
        #expect(chat.composerPolicySelection.mode == .manual)
    }

    // MARK: 聊天工具路径夹具（approved 分发，M05 主路径 + M06）

    private func makeToolFixture() throws -> (SettingsCenter, BridgeStore, URL) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("qfa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        try #require(readiness.upsert([
            ProviderReadinessPersistenceRecord(
                providerID: "quickfixa-offline", modelID: "quickfixa-model",
                status: .passed, readinessState: .mock, checkedAt: now,
                evidenceID: "quickfixa-synthetic-readiness", isApplied: true,
                discoveryReceiptID: "quickfixa-synthetic-discovery", discoveredAt: now,
                applyReceiptID: "provider-readiness-apply:quickfixa-synthetic", appliedAt: now
            )
        ]))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("quickfixa-\(UUID().uuidString)")),
            providerReadinessStore: readiness
        )
        let defaults = try #require(UserDefaults(suiteName: "quickfixa-\(UUID().uuidString)"))
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
        _ = try center.settingsStore.update(\.general.language, to: "zh-Hans").get()
        center.reloadAll()
        return (center, bridge, root)
    }

    private func attach(_ center: SettingsCenter, _ bridge: BridgeStore, root: URL) async {
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: QuickFixAApproval(), externalNetworkAllowed: true
        ).value
    }

    private func runToolCall(
        _ input: [String: Any], callID: String, in bridge: BridgeStore
    ) async throws -> String {
        let provider = QuickFixAProvider(input: input, callID: callID)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = "QuickFixA 设置请求"
        bridge.chat.submitComposer()
        try await Task.sleep(for: .milliseconds(100))
        let deadline = Date().addingTimeInterval(20)
        while bridge.chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!bridge.chat.isStreaming)
        return try #require(provider.returnedToolMessage)
    }

    private func fontApplyInput(_ snapshot: BL6EffectiveSettingsSnapshot, to size: Int) -> [String: Any] {
        ["operation": "apply", "expectedRevision": snapshot.catalogRevision,
         "changes": [Self.fontKey: ["kind": "integer", "integer": size]]]
    }

    @Test("M05 聊天 conversation_settings 改字号 apply 与 rollback 提交后，会话“手动审批”不被默认模式覆盖")
    func chatToolFontChangeKeepsSessionMode() async throws {
        let (center, bridge, root) = try makeToolFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        await attach(center, bridge, root: root)
        center.composerPolicy = bypassDefault
        center.onComposerPolicyChanged = { [weak bridge] policy in bridge?.chat.restoreComposerPolicy(policy) }
        bridge.chat.composerPolicySelection = manualSelection

        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let applyText = try await runToolCall(
            fontApplyInput(before, to: 17), callID: "qfa-m05-apply", in: bridge)
        let receipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(applyText.utf8))
        #expect(center.bl6EffectiveSettingsSnapshot?.value(for: Self.fontKey) == .integer(17))
        #expect(bridge.chat.composerPolicySelection.mode == .manual,
                "apply 提交后会话模式被默认“绕过权限”覆盖（BL6SettingsCenterDispatch.swift:398）")
        bridge.chat.composerPolicySelection = manualSelection

        let applied = try #require(center.bl6EffectiveSettingsSnapshot)
        let undoText = try await runToolCall(
            ["operation": "rollback", "expectedRevision": applied.catalogRevision,
             "changes": [String: Any](), "undoReceiptID": receipt.receiptID],
            callID: "qfa-m05-undo", in: bridge)
        let undo = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(undoText.utf8))
        #expect(undo.operation == .rollback)
        #expect(bridge.chat.composerPolicySelection.mode == .manual,
                "rollback 提交后会话模式被默认模式覆盖（BL6SettingsCenterDispatch.swift:398）")
    }

    // MARK: M06 · 撤销失效说明

    @Test("M06 回执失效（设置之后又变过）时，返回信息说明无法撤销并给出字号原值")
    func staleUndoReceiptExplainsAndReturnsOriginalValue() async throws {
        let (center, bridge, root) = try makeToolFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        await attach(center, bridge, root: root)
        bridge.chat.composerPolicySelection = manualSelection

        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        guard case .integer(let original)? = before.value(for: Self.fontKey) else {
            Issue.record("字号应为整数设置"); return
        }
        let newSize = original == 18 ? 17 : 18
        let applyText = try await runToolCall(
            fontApplyInput(before, to: newSize), callID: "qfa-m06-apply", in: bridge)
        let receipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(applyText.utf8))

        // 回执之后设置又变过一次（用户在设置里手改）。
        let mid = try #require(center.bl6EffectiveSettingsSnapshot)
        let otherSize = (newSize == 12 || original == 12) ? 13 : 12
        guard case .success = center.dispatchBL6Settings(intent(
            "qfa-m06-user-change", changes: [Self.fontKey: .integer(otherSize)], revision: mid.catalogRevision
        )) else { Issue.record("中间改动应成功"); return }
        let now = try #require(center.bl6EffectiveSettingsSnapshot)

        let undoText = try await runToolCall(
            ["operation": "rollback", "expectedRevision": now.catalogRevision,
             "changes": [String: Any](), "undoReceiptID": receipt.receiptID],
            callID: "qfa-m06-undo", in: bridge)
        #expect(center.bl6EffectiveSettingsSnapshot?.value(for: Self.fontKey) == .integer(otherSize),
                "失效撤销不得改动设置")
        #expect(undoText.contains("无法撤销"), "应说明无法撤销，实际：\(undoText)")
        #expect(undoText.contains("又变过"), "应说明这次改动之后设置又变过，实际：\(undoText)")
        #expect(undoText.contains(String(original)), "应给出回执里的原值 \(original)，实际：\(undoText)")
        #expect(!undoText.contains("staleRevision"), "不应只给内部错误名，实际：\(undoText)")
    }

    // MARK: M04 · 上限不足文案

    @Test("M04 modeExceedsAutonomyCeiling 的用户可见文案为中文并指出处理办法")
    func modeExceedsCeilingMessageIsChineseAndActionable() {
        let error = ComposerAuthorizationError.modeExceedsAutonomyCeiling(required: .l3, maximum: .l1)
        for text in [error.localizedDescription, ChatStore.userErrorMessage(error)] {
            #expect(!text.contains("Composer mode requires"), "仍是英文：\(text)")
            #expect(text.contains("手动审批"), "应提示改为手动审批：\(text)")
            #expect(text.contains("运行安全上限"), "应提示到 设置 → 智能体运行 → 运行安全上限 调高：\(text)")
            #expect(text.contains("超出了你设置的运行安全上限"), "应说明当前模式超出上限：\(text)")
            #expect(!text.contains("L3") && !text.contains("L1"), "不应露出内部级别：\(text)")
        }
    }

    // MARK: 第 4 条 · 下调上限后自动降为手动审批（状态/逻辑层）

    private struct Wired {
        let center: SettingsCenter
        let bridge: BridgeStore
        let profile: RuntimeIsolationProfile
        let defaults: UserDefaults
    }

    private func makeWired() throws -> Wired {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "QuickFixA4", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
        let defaults = profile.makeUserDefaults()
        let keychain = profile.makeKeychainStore()
        let logManager = profile.makeLogManager()
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.minisCoreDirectory, keychain: keychain,
                                  privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: logManager,
            mcpManager: MCPServerManager(
                fileURL: profile.mcpDirectory.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        )
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: logManager,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("Workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            memoryStore: center.memoryStore,
            canvasFeatureLane: .phase3NonCanvas
        )
        ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: center, profile: profile,
            childConcurrencySelection: center.childConcurrencySelection
        )
        ProductionOrchestrationDefaults.bindPolicyRuntimeDefaults(to: bridge, settings: center, profile: profile)
        // 与 MinisCanvasApp.swift:1578 的生产接线一致。
        center.onComposerPolicyChanged = { [weak bridge] policy in bridge?.chat.restoreComposerPolicy(policy) }
        return Wired(center: center, bridge: bridge, profile: profile, defaults: defaults)
    }

    private func cleanup(_ wired: Wired) {
        if let suite = wired.profile.userDefaultsSuiteName {
            wired.defaults.removePersistentDomain(forName: suite)
        }
        try? wired.profile.cleanupDisposableRoots()
    }

    @Test("第4条 下调上限使已保存的默认模式超限时，默认模式落盘并生效为手动审批")
    func loweringCeilingDowngradesSavedDefaultMode() async throws {
        let wired = try makeWired()
        defer { cleanup(wired) }
        let center = wired.center, chat = wired.bridge.chat
        #expect(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l3)))
        center.composerPolicy = bypassDefault
        chat.restoreComposerPolicy(center.composerPolicy)
        #expect(chat.composerPolicySelection.mode == .bypassPermission)

        #expect(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l1)))
        await wired.bridge.lastChildGovernorSafetyTask?.value

        #expect(ComposerTaskMode.bypassPermission.requiredAutonomyLevel > center.policyRuntimeDefaults.autonomyLevel)
        #expect(center.composerPolicy.mode == .manual, "设置里保存的默认模式应降为手动审批")
        #expect(SettingsStore(directory: center.settingsStore.directory)
            .settings.agent.composerPolicy.mode == .manual, "降级应落盘")
        #expect(chat.composerPolicySelection.mode == .manual, "当前会话模式也应是手动审批")
    }

    @Test("第4条 下调上限使当前会话已选模式超限时，会话模式自动降为手动审批")
    func loweringCeilingDowngradesCurrentSessionMode() async throws {
        let wired = try makeWired()
        defer { cleanup(wired) }
        let center = wired.center, chat = wired.bridge.chat
        #expect(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l3)))
        // 保存的默认是手动；仅会话里临时选了“自动”（需要 L3）。
        chat.restoreComposerPolicy(center.composerPolicy)
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false
        )

        #expect(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l1)))
        await wired.bridge.lastChildGovernorSafetyTask?.value

        // 注入点说明：ChatStore 目前没有“上限变更”入口；修复需要让 onPolicyRuntimeDefaultsChanged
        // 路径（MinisCanvasApp.swift:306 bindPolicyRuntimeDefaults）或 ChatStore 在更新
        // composerPolicyFacts 时校验当前 selection.mode.requiredAutonomyLevel。
        #expect(chat.composerPolicyFacts.autonomyCeiling == .l1)
        #expect(chat.composerPolicySelection.mode == .manual, "当前会话模式超过新上限，应自动降为手动审批")
    }

    @Test("第4条 下调上限但默认模式仍在上限内时，默认模式保持不变")
    func loweringCeilingKeepsModeStillWithinCeiling() async throws {
        let wired = try makeWired()
        defer { cleanup(wired) }
        let center = wired.center
        #expect(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l3)))
        let autoEdit = ComposerPolicySettings(
            mode: .autoEdit, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        center.composerPolicy = autoEdit
        #expect(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l2)))
        await wired.bridge.lastChildGovernorSafetyTask?.value
        #expect(center.composerPolicy.mode == .autoEdit)
        #expect(ComposerTaskMode.autoEdit.requiredAutonomyLevel <= center.policyRuntimeDefaults.autonomyLevel)
    }
}

@MainActor
@Suite("规则面板编辑不放大权限")
struct PermissionRulePanelEditTests {
    @Test("仅编辑规则不可编辑（避免保存后升格为写入），写入规则仍可编辑")
    func fileEditRuleIsDeleteOnly() {
        func rule(_ capability: String) -> PersistentApprovalRule {
            PersistentApprovalRule(
                projectKey: PersistentApprovalRule.globalProjectKey, projectRoots: [],
                kind: .projectDirectory, capability: capability, pattern: "/tmp/proj")
        }
        #expect(PermissionRulesPanelModel.draftFields(of: rule("file_edit")) == nil)
        #expect(PermissionRulesPanelModel.draftFields(of: rule("file_write"))?.type == .writePath)
    }
}
