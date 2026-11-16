import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - U4 聊天输入区插件 / Skill 选择器测试
//
// 用户需求：对话输入处可选择插件和 skill —— 输入框 🧩 按钮弹 popover 选
// 插件 / 技能，选中项以 chip 挂输入框上方（× 移除），名称随消息注入系统提示。
// 覆盖：
//   · SkillCatalogLoader：SKILL.md frontmatter 解析 / 递归扫描 / MCP 条目 / 汇总去重
//   · ChatStore 选中状态：toggle / deselect / clear / 目录刷新剪枝
//   · pickerContentInjectionFragment：插件片段格式 + canonical Skill 发送链路

// MARK: 工具

/// 临时目录（每个测试独立；返回 URL，测试结束自行清理）
private func u4TempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("U4-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 在目录里写一个 SKILL.md（自动建父目录）
private func writeSkillMD(at dir: URL, content: String) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try content.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
}

private let u4SampleSkillMD = """
---
name: image-prompt-writer
description: 图片和视频的提示词怎么写，文生图 / 图生图 / 镜头分镜。
version: 1.2.0
---

# Image Prompt Writer

正文：写稳定中文提示词。
"""

/// 记录引擎：捕获 streamReply 收到的 systemPrompt（U4 注入链路断言用）。
final class U4SystemPromptRecordingEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { true }

    private let lock = NSLock()
    private var _systemPrompts: [String] = []
    var systemPrompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _systemPrompts
    }

    /// NSLock 不能在 async 上下文直接 lock/unlock（Swift 并发隔离）——
    /// 包装进同步 helper，供 streamReply（async）调用。
    private func record(_ prompt: String) {
        lock.lock()
        _systemPrompts.append(prompt)
        lock.unlock()
    }

    func interrupt() {}

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        record(systemPrompt)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("ok"))
            continuation.finish()
        }
    }

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

// MARK: - Catalog 加载与解析

@Suite("U4 SkillCatalogLoader：SKILL.md 解析与目录扫描")
struct U4CatalogLoaderTests {

    @Test func skillItemParsesFrontmatterNameAndDescription() throws {
        let item = SkillCatalogLoader.skillItem(skillMD: u4SampleSkillMD, directoryName: "image-prompt-writer")
        let unwrapped = try #require(item)
        #expect(unwrapped.kind == .skill)
        #expect(unwrapped.name == "image-prompt-writer")
        #expect(unwrapped.detail.hasPrefix("图片和视频的提示词怎么写"))
        #expect(unwrapped.id == "skill:image-prompt-writer")
    }

    @Test func skillItemFallsBackToDirectoryNameWhenNoName() throws {
        // 无 frontmatter：整篇落 body → name 回退目录名
        let item = SkillCatalogLoader.skillItem(skillMD: "# 只有正文\n没有 frontmatter", directoryName: "my-skill")
        let unwrapped = try #require(item)
        #expect(unwrapped.name == "my-skill")
        #expect(unwrapped.id == "skill:my-skill")
    }

    @Test func skillItemRejectsEmptyContent() {
        #expect(SkillCatalogLoader.skillItem(skillMD: "   \n  ", directoryName: "x") == nil)
        #expect(SkillCatalogLoader.skillItem(skillMD: "", directoryName: "x") == nil)
    }

    @Test func explicitDirectoryScansCategorySubdirectories() throws {
        // Hermes 技能库带分类子目录：creative/manju-core/SKILL.md
        let root = try u4TempDir("hermes")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkillMD(at: root.appendingPathComponent("creative/manju-core"), content: """
        ---
        name: manju-core
        description: 漫剧铁律层。
        ---
        正文。
        """)
        try writeSkillMD(at: root.appendingPathComponent("github/github-pr-workflow"), content: """
        ---
        name: github-pr-workflow
        description: GitHub PR lifecycle.
        ---
        body
        """)
        // 干扰项：无 SKILL.md 的目录 / 隐藏文件
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty-category"), withIntermediateDirectories: true)

        let items = SkillsScanner.scanLocalDirectory(root: root)
        #expect(items.count == 2)
        #expect(Set(items.map(\.name)) == ["manju-core", "github-pr-workflow"])
        #expect(items.allSatisfy { $0.source == .localDirectory })
        // 按名称排序
        #expect(items.map(\.name) == items.sorted { $0.name < $1.name }.map(\.name))
    }

    @Test func explicitDirectoryMissingRootReturnsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("U4-missing-\(UUID().uuidString)")
        #expect(SkillsScanner.scanLocalDirectory(root: missing).isEmpty)
    }

    @Test func storeSkillItemsMapFromSkillStore() throws {
        let dir = try u4TempDir("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillStore(skillsRoot: dir)
        try store.importSkill(content: u4SampleSkillMD, source: .file)

        let items = SkillCatalogLoader.storeSkillItems(from: store)
        #expect(items.count == 1)
        #expect(items[0].name == "image-prompt-writer")
        #expect(items[0].id == "skill:image-prompt-writer")
        #expect(items[0].detail.hasPrefix("图片和视频的提示词怎么写"))
    }

    @Test func pluginItemsMapMCPServers() {
        let servers = [
            MCPServer(id: "github", name: "GitHub", type: .stdio, command: "npx", args: ["-y", "@mcp/github"]),
            MCPServer(id: "kb", name: "知识库", type: .http, enabled: false, url: "https://kb.local/mcp"),
        ]
        let items = SkillCatalogLoader.pluginItems(servers: servers)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.kind == .plugin })
        #expect(items[0].id == "plugin:github")
        #expect(items[0].detail.contains("stdio"))
        #expect(items[0].detail.contains("npx"))
        #expect(items[0].isEnabled)
        // 停用服务器保留展示并标注
        #expect(items[1].detail.contains("已停用"))
        #expect(items[1].detail.contains("HTTP"))
        #expect(!items[1].isEnabled)
    }




}

// MARK: - ChatStore 选中状态增删

@Suite("U4 ChatStore：选中状态增删与目录剪枝")
@MainActor
struct U4SelectionStateTests {

    private func item(_ id: String, name: String) -> PickerCatalogItem {
        PickerCatalogItem(id: id, kind: .skill, name: name, detail: "")
    }

    @Test func toggleAddsThenRemoves() {
        let chat = ChatStore()
        let a = item("skill:manju-core", name: "manju-core")
        let b = item("plugin:github", name: "GitHub")

        chat.togglePickerItem(a)
        #expect(chat.selectedPickerItems.map(\.id) == ["skill:manju-core"])
        #expect(chat.draftText == "@manju-core", "选中即把可见 @引用插入草稿")

        chat.togglePickerItem(b)
        #expect(chat.selectedPickerItems.map(\.id) == ["skill:manju-core", "plugin:github"])
        #expect(chat.draftText == "@manju-core @GitHub")

        // 再点一次 = 取消选中（幂等，不产生重复条目；草稿引用同步删除）
        chat.togglePickerItem(a)
        #expect(chat.selectedPickerItems.map(\.id) == ["plugin:github"])
        #expect(chat.draftText == "@GitHub")
    }

    @Test func deselectByIDRemovesOnlyTarget() {
        let chat = ChatStore()
        let a = item("skill:manju-core", name: "manju-core")
        let b = item("skill:manju-video", name: "manju-video")
        chat.togglePickerItem(a)
        chat.togglePickerItem(b)
        #expect(chat.draftText == "@manju-core @manju-video")

        chat.deselectPickerItem(id: "skill:manju-core")
        #expect(chat.selectedPickerItems.map(\.id) == ["skill:manju-video"])
        #expect(chat.draftText == "@manju-video", "× 移除 chips = 删除草稿里的对应 @引用")

        // 移除不存在的 id：无副作用（选中与草稿都不动）
        chat.deselectPickerItem(id: "skill:nonexistent")
        #expect(chat.selectedPickerItems.count == 1)
        #expect(chat.draftText == "@manju-video")
    }

    @Test func clearSelectionRemovesAll() {
        let chat = ChatStore()
        chat.togglePickerItem(item("skill:a", name: "a"))
        chat.togglePickerItem(item("plugin:b", name: "b"))
        chat.clearPickerSelection()
        #expect(chat.selectedPickerItems.isEmpty)
        #expect(chat.draftText.isEmpty, "清空选中 = 清空草稿里的 @引用")
    }

    @Test func draftReferenceHelpersAppendAndRemove() {
        // 追加：空草稿直接写；非空追加到末尾；已有引用不重复（大小写不敏感）
        #expect(ChatStore.appendingReference("manju-core", to: "") == "@manju-core")
        #expect(ChatStore.appendingReference("manju-core", to: "帮我写分镜") == "帮我写分镜 @manju-core")
        #expect(ChatStore.appendingReference("manju-core", to: "@manju-core") == "@manju-core")
        #expect(ChatStore.appendingReference("manju-core", to: "@MANJU-CORE 帮我") == "@MANJU-CORE 帮我")
        // 移除：整段、行首、行尾、中段（大小写不敏感 + 不吃掉用户原文空格）
        #expect(ChatStore.removingReference("manju-core", from: "@manju-core") == "")
        #expect(ChatStore.removingReference("manju-core", from: "@manju-core 帮我写") == "帮我写")
        #expect(ChatStore.removingReference("manju-core", from: "帮我写 @manju-core") == "帮我写")
        #expect(ChatStore.removingReference("manju-core", from: "帮我 @MANJU-CORE 写") == "帮我 写")
        #expect(ChatStore.removingReference("manju-core", from: "无引用文本") == "无引用文本")
    }

    @Test func pickerReferencesExtractsAtMentions() {
        #expect(ChatStore.pickerReferences(in: "帮我 @manju-core 写分镜", catalogNames: ["manju-core", "manju-video"])
            == ["manju-core"])
        #expect(ChatStore.pickerReferences(in: "无引用", catalogNames: ["manju-core"]) == [])
        #expect(ChatStore.pickerReferences(in: "空目录", catalogNames: []) == [])
        // 大小写不敏感 + 去重 + 保持出现顺序
        #expect(ChatStore.pickerReferences(in: "@MANJU-CORE 和 @manju-video 再提 @manju-core",
            catalogNames: ["manju-core", "manju-video"]) == ["manju-core", "manju-video"])
        #expect(ChatStore.pickerReferences(in: "@a @a", catalogNames: ["a"]) == ["a"])
        // 最长优先：长名不被短名前缀截胡
        #expect(ChatStore.pickerReferences(in: "@manju-corex", catalogNames: ["manju-corex", "manju-core"])
            == ["manju-corex"])
        // 含空格的中文技能名也能整名匹配
        #expect(ChatStore.pickerReferences(in: "用 @AI 桌面客户端开发 帮我", catalogNames: ["AI 桌面客户端开发"])
            == ["AI 桌面客户端开发"])
    }

    @Test func loadCatalogPrunesStaleSelections() {
        let chat = ChatStore()
        let keep = item("skill:keep", name: "keep")
        let stale = item("skill:stale", name: "stale")
        chat.togglePickerItem(keep)
        chat.togglePickerItem(stale)

        // 注入目录：stale 已不在目录中（技能被删除 / MCP 被移除）
        chat.pickerCatalogLoader = { [keep] }
        chat.loadPickerCatalog()

        #expect(chat.pickerCatalog.map(\.id) == ["skill:keep"])
        #expect(chat.selectedPickerItems.map(\.id) == ["skill:keep"],
                "目录刷新后，已不存在的选中项应被剔除")
        #expect(chat.draftText == "@keep", "被剔除的旧选择不应留在草稿引用中")
    }

    @Test func disabledPluginIsVisibleButCannotBeSelectedOrInjected() async throws {
        let chat = ChatStore()
        let engine = U4SystemPromptRecordingEngine()
        chat.agentEngine = engine
        let enabled = PickerCatalogItem(
            id: "plugin:kb", kind: .plugin, name: "知识库", detail: "HTTP",
            isEnabled: true
        )
        let disabled = PickerCatalogItem(
            id: "plugin:kb", kind: .plugin, name: "知识库", detail: "HTTP（已停用）",
            isEnabled: false
        )

        chat.pickerCatalogLoader = { [enabled] }
        chat.loadPickerCatalog()
        chat.togglePickerItem(enabled)
        #expect(chat.selectedPickerItems.map(\.id) == ["plugin:kb"])
        #expect(chat.draftText == "@知识库")

        chat.pickerCatalogLoader = { [disabled] }
        chat.loadPickerCatalog()
        let current = try #require(chat.pickerCatalog.first)
        #expect(current.id == "plugin:kb")
        #expect(current.detail.contains("已停用"))
        #expect(!current.isEnabled)
        #expect(chat.selectedPickerItems.isEmpty)
        #expect(chat.draftText.isEmpty)

        chat.togglePickerItem(disabled)
        chat.togglePickerItem(enabled) // stale previously enabled row
        #expect(chat.selectedPickerItems.isEmpty)
        #expect(chat.draftText.isEmpty)
        #expect(ChatStore.pickerContentInjectionFragment(for: [disabled]) == nil)

        // A typed @name must not bypass the refreshed disabled catalog.
        chat.draftText = "请用 @知识库 查资料"
        chat.sendDraft()
        var waited: TimeInterval = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        let prompt = try #require(engine.systemPrompts.last)
        #expect(!prompt.contains("插件：知识库"))
        #expect(!prompt.contains("<user_selected_skills>"))
    }

    @Test func loadCatalogInBackgroundAppliesResultWithoutBlocking() async {
        let chat = ChatStore()
        let loaded = item("skill:background", name: "background")
        chat.pickerCatalogLoader = { [loaded] }

        let task = chat.loadPickerCatalogInBackground()
        await task.value

        #expect(!chat.isPickerCatalogLoading)
        #expect(chat.pickerCatalog.map(\.id) == ["skill:background"])
    }

    @Test func pickerContentInjectionFragmentFormatsPluginsOnly() throws {
        #expect(ChatStore.pickerContentInjectionFragment(for: []) == nil)

        let skill = PickerCatalogItem(id: "skill:manju-core", kind: .skill, name: "manju-core",
                                      detail: "漫剧铁律层", content: "# Manju Core\n正文：每次生产任务必须加载。")
        let plugin = PickerCatalogItem(id: "plugin:github", kind: .plugin, name: "GitHub", detail: "stdio")
        let fragment = try #require(ChatStore.pickerContentInjectionFragment(for: [skill, plugin]))
        #expect(fragment.contains("user_selected_skills"))
        #expect(fragment.contains("插件：GitHub"))
        #expect(!fragment.contains("manju-core"), "Skill 缓存不得成为 prompt 来源")
        let disabledPlugin = PickerCatalogItem(
            id: "plugin:disabled", kind: .plugin, name: "停用插件", detail: "已停用",
            isEnabled: false
        )
        #expect(ChatStore.pickerContentInjectionFragment(for: [disabledPlugin]) == nil)

        // Skill-only selections are handled by SkillInjector and leave this
        // cached-content helper empty.
        let bare = PickerCatalogItem(id: "skill:bare", kind: .skill, name: "bare", detail: "")
        #expect(ChatStore.pickerContentInjectionFragment(for: [bare]) == nil)
        let legacy = SkillCatalogLoader.buildInjection(
            for: "@manju-core",
            from: [skill]
        )
        #expect(legacy.fragment == nil)
        #expect(legacy.receipts.first?.state == .rejected)
        #expect(!legacy.receipts.contains { $0.injected })
    }

    @Test func sendDraftInjectsAtMentionedSkillsIntoSystemPrompt() async throws {
        let root = try u4TempDir("send-canonical")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        let imported = try store.importSkillThroughLifecycle(
            content: u4SampleSkillMD,
            source: .file,
            reason: "U4 canonical picker regression",
            approval: SkillApproval(approverID: "u4-test")
        )
        let injector = SkillInjector(store: store)

        let chat = ChatStore()
        let engine = U4SystemPromptRecordingEngine()
        chat.agentEngine = engine
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(
                turn: turn,
                skillInjector: injector.snapshotForTurn(),
                mcpBridge: nil
            )
        }
        // The catalog deliberately carries stale content. Production must use
        // the canonical store snapshot selected by the turn runtime instead.
        chat.pickerCatalogLoader = {
            [PickerCatalogItem(
                id: "skill:\(imported.skill.id)",
                kind: .skill,
                name: imported.skill.name,
                detail: imported.skill.description,
                content: "STALE CACHED PICKER BODY"
            )]
        }
        chat.loadPickerCatalog()

        // 选中技能 → @引用插入草稿 → 用户继续打字 → 发送
        chat.togglePickerItem(PickerCatalogItem(
            id: "skill:\(imported.skill.id)",
            kind: .skill,
            name: imported.skill.name,
            detail: ""
        ))
        #expect(chat.draftText == "@\(imported.skill.name)")
        chat.draftText += " 帮我写分镜"

        chat.sendDraft()

        // 等流式任务跑完（Mock 引擎立即 yield + finish）
        var waited: TimeInterval = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(!chat.isStreaming)

        let prompt = try #require(engine.systemPrompts.last, "引擎应收到系统提示")
        #expect(prompt.contains("<injected_skills>"))
        #expect(prompt.contains("正文：写稳定中文提示词。"), "canonical SKILL.md body enters the prompt")
        #expect(!prompt.contains("STALE CACHED PICKER BODY"), "cached picker body is never injected")
        #expect(chat.lastSkillInjectionReceipts.contains {
            $0.skillID == imported.skill.id && $0.state == .active && $0.injected
        })
        #expect(prompt.contains(ChatStore.systemPrompt), "基础系统提示仍在前")

        // 本次消息语义：发送后清空草稿选择，已命中的技能可在同会话继续使用
        #expect(chat.selectedPickerItems.isEmpty, "发送后选中项清空（chips 与草稿引用同生命周期）")
        chat.draftText = "再写一条"
        chat.sendDraft()
        waited = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(engine.systemPrompts.count == 2)
        #expect(engine.systemPrompts[1].components(separatedBy: "<skill name=").count - 1 == 1)
        #expect(engine.systemPrompts[1].contains("正文：写稳定中文提示词。"))
        #expect(!engine.systemPrompts[1].contains("STALE CACHED PICKER BODY"))
        #expect(chat.selectedPickerItems.isEmpty)
        #expect(chat.lastSkillInjectionReceipts.filter(\.injected).map(\.skillID) == [imported.skill.id])

        // 手动输入 @引用（未打开 popover）同样注入；目录已在内存，无额外扫描
        chat.draftText = "用 @\(imported.skill.name) 帮我改"
        chat.sendDraft()
        waited = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(engine.systemPrompts.count == 3)
        #expect(engine.systemPrompts[2].contains("<injected_skills>"))

        // 没有新引用时仍保留本会话已命中的技能
        chat.draftText = "普通消息"
        chat.sendDraft()
        waited = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(engine.systemPrompts.count == 4)
        #expect(engine.systemPrompts[3].components(separatedBy: "<skill name=").count - 1 == 1)
        #expect(engine.systemPrompts[3].contains("正文：写稳定中文提示词。"))
        #expect(!engine.systemPrompts[3].contains("STALE CACHED PICKER BODY"))
        #expect(chat.selectedPickerItems.isEmpty)
        #expect(chat.lastSkillInjectionReceipts.filter(\.injected).map(\.skillID) == [imported.skill.id])
    }

    @Test func pickerSelectionRejectsDisabledDriftedAndUnregisteredContent() throws {
        let root = try u4TempDir("reject-canonical")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        let imported = try store.importSkillThroughLifecycle(
            content: u4SampleSkillMD,
            source: .file,
            reason: "U4 rejection regression",
            approval: SkillApproval(approverID: "u4-test")
        )
        let injector = SkillInjector(store: store)
        let selectedID = "skill:\(imported.skill.id)"

        let accepted = injector.buildInjection(for: "普通消息", selectedSkillIDs: [selectedID])
        #expect(accepted.fragment?.contains("正文：写稳定中文提示词。") == true)
        #expect(accepted.receipts.contains { $0.skillID == imported.skill.id && $0.injected })

        store.setEnabled(imported.skill.id, enabled: false)
        let disabled = SkillInjector(store: store).buildInjection(
            for: "普通消息",
            selectedSkillIDs: [selectedID]
        )
        #expect(disabled.fragment == nil)
        #expect(disabled.receipts.contains {
            $0.skillID == imported.skill.id && $0.state == .rejected && $0.omittedReason != nil
        })

        // Re-enabling cannot restore a drifted payload. The store quarantines
        // it before the injector can read a body, so stale picker content is
        // absent from every result.
        store.setEnabled(imported.skill.id, enabled: true)
        try "STALE RAW SKILL CONTENT".write(
            to: root.appendingPathComponent(imported.skill.id).appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let drifted = SkillInjector(store: store).buildInjection(
            for: "普通消息",
            selectedSkillIDs: [selectedID]
        )
        #expect(drifted.fragment == nil)
        #expect(drifted.receipts.contains {
            $0.skillID == imported.skill.id && $0.state == .rejected
        })
        #expect(!drifted.receipts.contains {
            $0.contentHash == SkillManifest.hash("STALE RAW SKILL CONTENT") && $0.injected
        })

        let unregistered = SkillInjector(store: store).buildInjection(
            for: "普通消息",
            selectedSkillIDs: ["skill:hermes-only-raw"]
        )
        #expect(unregistered.fragment == nil)
        #expect(unregistered.receipts.contains {
            $0.skillID == "hermes-only-raw" && $0.state == .rejected
        })
    }
}


/// Offline transport; the production AgentLoop still prepares and persists
/// its normal canonical context before it calls this Provider.
private final class U4GlobalSkillContextProvider2979:
    LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable
{
    let name = "u4-global-offline"
    var model = LLMModel(id: "u4-global-model", displayName: "U4 global owned", provider: "u4-global-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "u4-global-owned"
    private let lock = NSLock()
    private var captured: [String] = []
    var prompts: [String] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(systemPrompt ?? "") }
        return LLMResponse(text: "owned U4 response", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("U4 actual Provider global skill context metadata", .serialized)
@MainActor
struct U4GlobalSkillContextManifest2979Tests {
    @Test(arguments: ["global", "disabled", "pending", "foreignScope"])
    func actualProviderGlobalSkillContextManifest2979(_ boundary: String) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("u4-global2979-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: "u4-global-offline", modelID: "u4-global-model",
            status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "u4-global-synthetic-readiness", isApplied: true,
            discoveryReceiptID: "u4-global-synthetic-discovery", discoveredAt: now,
            applyReceiptID: "provider-readiness-apply:u4-global-synthetic", appliedAt: now)]))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("u4-global2979-" + UUID().uuidString)),
            providerReadinessStore: readiness)
        let foreign = boundary == "foreignScope"
            ? MemoryScope(sessionID: "foreign-session", projectID: "foreign-project") : nil
        let imported = try center.skillStore.importSkillThroughLifecycle(
            content: "---\nname: Global U4 Owned2979\ndescription: synthetic local selection\n---\nU4_GLOBAL_2979_CANONICAL_BODY",
            source: .file, reason: "synthetic original local user approval", scope: foreign,
            approval: boundary == "pending" ? nil : SkillApproval(approverID: "synthetic-u4-user", scope: foreign))
        if boundary == "disabled" {
            try #require(center.skillStore.setEnabled(imported.skill.id, enabled: false))
        }
        let receiptBefore = center.skillStore.lifecycleReceipt(for: imported.skill.id)
        let journalBefore = try Data(contentsOf: center.skillStore.lifecycleReceiptsFileURL)
        let defaults = try #require(UserDefaults(suiteName: "u4-global2979-" + UUID().uuidString))
        let skills = SkillsStore(
                                appStore: center.skillStore, stateFileURL: root.appendingPathComponent("skills-enabled.json"))
        cafU4SkillDiagnostics(label: "U4_" + boundary, skills: skills, store: center.skillStore, skillID: imported.skill.id)
        let bridge = try BridgeStore(
            taskStorePersistenceURL: root.appendingPathComponent("agent-tasks.json"),
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            settingsCatalogSkillsStore: skills,
            logManager: LogManager(directory: root.appendingPathComponent("bridge-logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, memoryStore: center.memoryStore, providerReadinessStore: readiness,
            canvasFeatureLane: .phase3NonCanvas)
        defer { bridge.chat.stopAllStreamingForSafety() }
        bridge.bindProductionEffectiveSettingsSource { [weak center] in center?.bl6EffectiveSettingsSnapshot }
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: sessions.directory, skillStore: center.skillStore,
            externalNetworkAllowed: true).value
        let session = try #require(bridge.chat.activeSessionID)
        #expect(bridge.chat.activeMemoryScope == nil)
        #expect(bridge.isSafetyFeatureEnabled(.userSkills))
        let provider = U4GlobalSkillContextProvider2979()
        bridge.chat.streamingProviderOverride = provider
        // A stale picker row is deliberately insufficient authority in the
        // three negative cases. Only the original Core lifecycle decides.
        bridge.chat.pickerCatalogLoader = {
            [PickerCatalogItem(id: "skill:" + imported.skill.id, kind: .skill,
                name: imported.skill.name, detail: "synthetic", content: "STALE_PICKER_BODY")]
        }
        bridge.chat.loadPickerCatalog()
        bridge.chat.togglePickerItem(PickerCatalogItem(id: "skill:" + imported.skill.id,
            kind: .skill, name: imported.skill.name, detail: "synthetic"))
        bridge.chat.draftText += " synthetic no-project message"
        bridge.chat.submitComposer()
        try await Task.sleep(for: .milliseconds(100))
        let deadline = Date().addingTimeInterval(20)
        while bridge.chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!bridge.chat.isStreaming)
        #expect(provider.prompts.count == 1)
        let prompt = try #require(provider.prompts.first)
        #expect(!prompt.contains("STALE_PICKER_BODY"))
        #expect(prompt.contains("U4_GLOBAL_2979_CANONICAL_BODY") == (boundary == "global"))
        let turn = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        let turnData = try Data(contentsOf: sessions.directory.appendingPathComponent("agent-turn-context-v1.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: turnData) as? [String: Any])
        let records = try #require(json["records"] as? [[String: Any]])
        let record = try #require(records.first { item in
            guard let identity = item["identity"] as? [String: Any],
                  let key = identity["turn"] as? [String: Any] else { return false }
            return key["sessionID"] as? String == session.uuidString && key["turnID"] as? Int == turn.turnID
        })
        // The current canonical producer keys generated manifests by its
        // complete execution identity. Consume the persisted actual identity,
        // rather than reconstructing the retired display-turn runID.
        let identityData = try JSONSerialization.data(withJSONObject: try #require(record["identity"]))
        let executionIdentity = try JSONDecoder().decode(AgentExecutionIdentity.self, from: identityData)
        #expect(executionIdentity.turn.sessionID == session.uuidString)
        #expect(executionIdentity.turn.turnID == turn.turnID)
        #expect(executionIdentity.turn.messageID == turn.messageID)
        let runID = try AgentLoopChatEngine.generatedContextManifestRunID(for: executionIdentity)
        let manifest = try #require(bridge.contextManifestStore.manifest(runID: runID))
        let expectedIDs = boundary == "global" ? [imported.skill.id] : []
        #expect(manifest.snapshot.skillIdentifiers == expectedIDs)
        #expect(manifest.snapshot.sessionID == session.uuidString)
        #expect(manifest.entries.map(\.identifier) == ["system-prompt"])
        #expect(bridge.chat.lastSkillInjectionReceipts.contains { $0.skillID == imported.skill.id && $0.injected }
                == (boundary == "global"))
        let snapshot = try #require(record["snapshot"] as? [String: Any])
        #expect(snapshot["skillIdentifiers"] as? [String] == expectedIDs)
        #expect(snapshot["snapshotID"] as? String == manifest.snapshot.snapshotID)
        #expect(record["status"] as? String == "completed")
        #expect(center.skillStore.lifecycleReceipt(for: imported.skill.id) == receiptBefore)
        #expect(try Data(contentsOf: center.skillStore.lifecycleReceiptsFileURL) == journalBefore)
    }
}

@MainActor
private func cafU4SkillDiagnostics(label: String, skills: SkillsStore, store: SkillStore, skillID: String) {
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
