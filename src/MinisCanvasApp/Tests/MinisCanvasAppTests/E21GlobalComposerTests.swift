import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - E21 全局对话条：画布选中节点 → 指令自动补全节点名

@Suite("E21 选中节点上下文补全")
struct E21SelectedNodeContextTests {
    @Test func adjustWithoutNodeNameInjectsSelected() {
        // 「调整 更紧凑」→「调整 <节点名>：更紧凑」
        #expect(GlobalComposer.applySelectedNodeContext(text: "调整 更紧凑", nodeTitle: "剧情拆解")
            == "调整 剧情拆解：更紧凑")
        #expect(GlobalComposer.applySelectedNodeContext(text: "调整 更紧凑一点", nodeTitle: "LLM 推理")
            == "调整 LLM 推理：更紧凑一点")
    }

    @Test func noSelectedNodeLeavesTextUntouched() {
        #expect(GlobalComposer.applySelectedNodeContext(text: "调整 更紧凑", nodeTitle: nil) == "调整 更紧凑")
        #expect(GlobalComposer.applySelectedNodeContext(text: "调整 更紧凑", nodeTitle: "") == "调整 更紧凑")
        #expect(GlobalComposer.applySelectedNodeContext(text: "", nodeTitle: "剧情拆解") == "")
    }

    @Test func alreadyNamedNodeCommandUnchanged() {
        // 已带节点名（CommandParser 可解析为完整节点指令）→ 不补
        #expect(GlobalComposer.applySelectedNodeContext(text: "调整 剧情：更紧凑", nodeTitle: "剧情拆解")
            == "调整 剧情：更紧凑")
        #expect(GlobalComposer.applySelectedNodeContext(text: "总结 剧情", nodeTitle: "剧情拆解") == "总结 剧情")
        #expect(GlobalComposer.applySelectedNodeContext(text: "设置 剧情：第一章", nodeTitle: "剧情拆解")
            == "设置 剧情：第一章")
        // 非节点编辑指令照旧（建节点/连线/执行）
        #expect(GlobalComposer.applySelectedNodeContext(text: "建节点 llm", nodeTitle: "剧情拆解") == "建节点 llm")
        #expect(GlobalComposer.applySelectedNodeContext(text: "连线 文本输入 -> LLM 推理", nodeTitle: "剧情拆解")
            == "连线 文本输入 -> LLM 推理")
        #expect(GlobalComposer.applySelectedNodeContext(text: "执行", nodeTitle: "剧情拆解") == "执行")
    }

    @Test func summarizeAndSetVariants() {
        // 「总结」→「总结 <节点名>」
        #expect(GlobalComposer.applySelectedNodeContext(text: "总结", nodeTitle: "剧情拆解") == "总结 剧情拆解")
        // 「改 更紧凑」→「改 <节点名> 的内容：更紧凑」
        #expect(GlobalComposer.applySelectedNodeContext(text: "改 更紧凑", nodeTitle: "剧情拆解")
            == "改 剧情拆解 的内容：更紧凑")
        // 「设置 更紧凑」→「设置 <节点名>：更紧凑」
        #expect(GlobalComposer.applySelectedNodeContext(text: "设置 更紧凑", nodeTitle: "剧情拆解")
            == "设置 剧情拆解：更紧凑")
    }

    @Test func plainChatUnchanged() {
        #expect(GlobalComposer.applySelectedNodeContext(text: "帮我想个标题", nodeTitle: "剧情拆解") == "帮我想个标题")
        #expect(GlobalComposer.applySelectedNodeContext(text: "调整心态，好好休息", nodeTitle: "剧情拆解")
            == "调整心态，好好休息")
        #expect(GlobalComposer.applySelectedNodeContext(text: "把灯关掉", nodeTitle: "剧情拆解") == "把灯关掉")
        #expect(GlobalComposer.applySelectedNodeContext(text: "调整", nodeTitle: "剧情拆解") == "调整")
    }
}

// MARK: - E21 发送走原链路（补全后 → chat.sendDraft → onSendCommand 画布指令）

@Suite("E21 补全后发送链路")
@MainActor
struct E21ComposerSendPathTests {
    @Test func augmentedAdjustRoutesToCanvasCommand() async throws {
        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
        // Phase B：建节点命令只接受生成类节点（文本创作类已出新建入口），
        // 用「文本输入」（text 类）验证补全→调整链路，与节点类型无关
        bridge.chat.draftText = "建节点 文本输入"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        let node = try #require(bridge.canvas.node(matchingTitle: "文本输入"))
        bridge.canvas.updateNodeContent("原文本：节奏缓慢", for: node.id)
        bridge.canvas.selectNode(id: node.id) // 模拟画布选中该节点

        // 等价于用户在全局对话条输入「调整 更紧凑」（画布选中该节点，自动补全节点名）
        bridge.chat.draftText = GlobalComposer.applySelectedNodeContext(
            text: "调整 更紧凑",
            nodeTitle: bridge.canvas.graph.node(id: node.id)?.title
        )
        #expect(bridge.chat.draftText == "调整 文本输入：更紧凑")
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)

        // 走原链路：Agent 读节点内容 → 按指令改写 → 写回 + 聊天回执
        let content = try #require(bridge.canvas.nodeContent(id: node.id))
        #expect(content.contains("用户要求调整：更紧凑")) // Mock 回显 prompt 带上了指令
        let assistant = bridge.chat.messages.filter { $0.role == .assistant }
        #expect(assistant.contains { $0.content.contains("正在让 Agent 调整「文本输入」") })
    }

    @Test func noSelectionKeepsOriginalTextAndCommandPath() {
        let bridge = BridgeStore()
        // 未选中节点：文本原样（不补全）
        let original = GlobalComposer.applySelectedNodeContext(text: "调整 更紧凑", nodeTitle: nil)
        #expect(original == "调整 更紧凑")
        // 未补全的指令解析不出画布节点指令 → 走普通对话（LLM），不会误改节点
        #expect(CommandParser.parse(original) == nil)
        // 画布无节点时发送也不触发节点调整
        bridge.chat.draftText = original
        bridge.chat.sendDraft()
        #expect(bridge.canvas.graph.nodes.isEmpty)
        let user = bridge.chat.messages.filter { $0.role == .user }
        #expect(user.contains { $0.content == "调整 更紧凑" })
    }

    @Test func augmentAppliesToSelectedNodeOnly() {
        // 画布选中 A：指令补全到 A；指令已带其他节点名时不改（保持原语义）
        let titleA = "剧情拆解"
        #expect(GlobalComposer.applySelectedNodeContext(text: "调整 更紧凑", nodeTitle: titleA)
            == "调整 剧情拆解：更紧凑")
        #expect(GlobalComposer.applySelectedNodeContext(text: "调整 脚本生成：精简对白", nodeTitle: titleA)
            == "调整 脚本生成：精简对白")
    }
}

// MARK: - AJ-1 全局对话条接线：插件 / 技能选择注入
//
// 接线断言：GlobalComposerView 的 🧩 按钮复用 U4 PluginSkillPickerPopover，
// 选中项经 bridge.chat（ChatStore）共享状态，发送走 chat.sendDraft → 系统提示注入
// skill 选择走 SkillInjector 的 canonical <injected_skills> 片段；user_selected_skills 仅属于插件。

private final class E21PickerRecordingProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "e21-picker-offline"
    var model = LLMModel(id: "e21-picker", displayName: "E21 picker", provider: "e21-picker-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var configurationMaterial: String? = "e21-picker-fixed-local"
    private var capturedPrompts: [String] = []

    var runtimeConfigurationMaterial: String? {
        get { lock.withLock { configurationMaterial } }
        set { lock.withLock { configurationMaterial = newValue } }
    }

    var systemPrompts: [String] { lock.withLock { capturedPrompts } }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        lock.withLock { capturedPrompts.append(systemPrompt ?? "") }
        return LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("AJ-1 全局对话条插件/技能注入接线")
@MainActor
struct E21GlobalComposerPickerInjectionTests {


    @Test func sendPathInjectsSelectedPickerItems() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("e21-picker-injection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills", isDirectory: true))
        _ = try skillStore.importSkill(content: """
        ---
        name: manju-core
        description: canonical E21 injection fixture
        version: 1.0.0
        ---

        manju-core 正文
        """, source: .bundled)

        let provider = E21PickerRecordingProvider()
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let checkedAt = Date()
        let lineage = ProviderReadinessLineage.derived(
            providerID: provider.name, modelID: provider.model.id, checkedAt: checkedAt
        )
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: provider.name, modelID: provider.model.id,
            status: .passed, readinessState: .mock, checkedAt: checkedAt,
            evidenceID: "e21-picker-owned-synthetic", isApplied: false,
            discoveryReceiptID: lineage.discoveryReceiptID,
            discoveredAt: lineage.discoveredAt
        )]))
        try #require(readiness.applyDiscoveredModels(
            providerID: provider.name, modelIDs: [provider.model.id],
            appliedAt: checkedAt.addingTimeInterval(1)
        ).count == 1)
        let logger = LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 30)
        logger.isFileLoggingEnabled = false
        let sessions = SessionStore(directory: root)
        let defaultsName = "e21-picker-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let usageDomain = defaultsName + ".usage"
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            defaults.removePersistentDomain(forName: usageDomain)
        }
        let keychain = KeychainStore(backing: CredentialIsolatedBacking())
        let env = EnvVarStore(
            directory: root.appendingPathComponent("environment"), keychain: keychain,
            privacyStore: EnvVarPrivacyStore(defaults: defaults)
        )
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain)
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: logger,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: badges,
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            sessionStore: sessions, memoryStore: memory, commandEnvStore: env,
            canonicalMCPManager: manager, providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-center.json")
        )
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            mcpManager: manager,
            skillStore: skillStore,
            externalRunners: [:],
            externalNetworkAllowed: true
        ).value
        // Install the owner for this isolated selector after Bridge attachment.
        let settingsSessions = sessions
        let settingsOwner = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: env, memoryStore: memory,
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: settingsSessions, sessionBadgeStore: badges,
            logManager: logger, mcpManager: manager, skillStore: skillStore,
            usageStore: UsageStore(domain: .suite(usageDomain)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness
        )
        defer { withExtendedLifetime(settingsOwner) {} }
        bridge.chat.streamingProviderOverride = provider
        #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
        let installed = try #require(skillStore.allSkills().first { $0.id == "manju-core" })
        #expect(installed.isEnabled)
        #expect(skillStore.isInjectable(installed))
        #expect(skillStore.skillContent(installed.id)?.contains("manju-core 正文") == true)
        // 注入固定目录（含 picker 展示内容），避免发送路径触发真实全盘扫描；正文只准来自 canonical SkillStore。
        bridge.chat.pickerCatalogLoader = {
            [PickerCatalogItem(id: "skill:manju-core", kind: .skill, name: "manju-core",
                               detail: "漫剧铁律层", content: "picker catalog display only")]
        }
        bridge.chat.loadPickerCatalog()

        // 模拟用户在 GlobalComposerView 🧩 popover 选中技能：
        // toggle 已把可见引用 @manju-core 插入草稿，用户继续打字后发送
        bridge.chat.togglePickerItem(PickerCatalogItem(id: "skill:manju-core", kind: .skill, name: "manju-core", detail: ""))
        #expect(bridge.chat.draftText == "@manju-core")
        bridge.chat.draftText += " 帮我写分镜"

        // 与 GlobalComposerView.send() 相同的发送链路
        bridge.chat.sendDraft()

        var waited: TimeInterval = 0
        while (bridge.chat.isStreaming || provider.systemPrompts.isEmpty) && waited < 10 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(!bridge.chat.isStreaming)

        let requiredValue561_1 = provider.systemPrompts.last
        let prompt: String = try #require(requiredValue561_1)
        #expect(prompt.contains("<injected_skills>") == true, "全局对话条技能引用应进入 canonical 注入容器")
        #expect(prompt.contains("<skill name=\"manju-core\">") == true)
        #expect(prompt.contains("manju-core 正文") == true, "canonical SkillStore 正文随消息注入系统提示")
        #expect(prompt.contains("<user_selected_skills>") == false, "技能引用不应伪装成插件选择")
        #expect(prompt.contains("### 技能：manju-core") == false, "技能注入不再依赖旧 Markdown 标题契约")
        #expect(prompt.contains("picker catalog display only") == false, "picker 展示缓存不得成为 prompt 来源")
        #expect(prompt.contains(ChatStore.systemPrompt) == true, "基础系统提示仍在前")
    }
}
