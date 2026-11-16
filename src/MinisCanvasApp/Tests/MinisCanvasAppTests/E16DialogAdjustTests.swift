import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - E16 对话驱动节点内容调整：指令解析

@Suite("E16 节点内容指令解析")
struct E16CommandParserTests {
    @Test func setContentVariants() {
        // 改 <节点名> 的内容：<新内容>
        guard case .setNodeContent(let kw, let content)? = CommandParser.parse("改 剧情 的内容：更紧凑的剧情") else {
            Issue.record("应解析为 setNodeContent"); return
        }
        #expect(kw == "剧情")
        #expect(content == "更紧凑的剧情")

        // 设置 <节点名>：<内容>
        guard case .setNodeContent(let kw2, let content2)? = CommandParser.parse("设置 剧情：第一章 风起") else {
            Issue.record("应解析为 setNodeContent"); return
        }
        #expect(kw2 == "剧情")
        #expect(content2 == "第一章 风起")

        // 把 <节点名> 的内容改成：<内容>
        guard case .setNodeContent(let kw3, let content3)? = CommandParser.parse("把 剧本 的内容改成：对白更少") else {
            Issue.record("应解析为 setNodeContent"); return
        }
        #expect(kw3 == "剧本")
        #expect(content3 == "对白更少")
    }

    @Test func adjustNode() {
        guard case .adjustNodeContent(let kw, let inst)? = CommandParser.parse("调整 剧情：更紧凑") else {
            Issue.record("应解析为 adjustNodeContent"); return
        }
        #expect(kw == "剧情")
        #expect(inst == "更紧凑")
    }

    @Test func summarizeNode() {
        guard case .summarizeNode(let kw)? = CommandParser.parse("总结 剧情") else {
            Issue.record("应解析为 summarizeNode"); return
        }
        #expect(kw == "剧情")
        guard case .summarizeNode(let kw2)? = CommandParser.parse("总结：剧本") else {
            Issue.record("应解析为 summarizeNode"); return
        }
        #expect(kw2 == "剧本")
    }

    @Test func importNovelVariants() {
        // 导入小说 <路径或粘贴>
        guard case .importNovel(let p)? = CommandParser.parse("导入小说 /tmp/novel.txt") else {
            Issue.record("应解析为 importNovel"); return
        }
        #expect(p == "/tmp/novel.txt")
        // 小说内容：<文本>
        guard case .importNovel(let t)? = CommandParser.parse("小说内容：从前有座山，山里有座庙") else {
            Issue.record("应解析为 importNovel"); return
        }
        #expect(t == "从前有座山，山里有座庙")
    }

    @Test func unrelatedChatStillNil() {
        #expect(CommandParser.parse("调整心态，好好休息") == nil)
        #expect(CommandParser.parse("总结一下今天的收获") == nil)
        #expect(CommandParser.parse("把灯关掉") == nil)
        // 既有指令不受影响
        #expect(CommandParser.parse("连线 文本输入 -> LLM 推理") != nil)
        #expect(CommandParser.parse("执行") != nil)
    }
}

// MARK: - E16 节点名模糊匹配 + 内容读写

@Suite("E16 节点名匹配与内容存储")
@MainActor
struct E16NodeMatchTests {
    @Test func fuzzyTitleMatch() {
        let store = CanvasStore()
        let node = store.addNode(ofType: ManjuNodeType.plotOutline.rawValue)
        #expect(node != nil)
        // 「剧情」→ 命中标题「剧情拆解」的节点
        #expect(store.node(matchingTitle: "剧情")?.id == node?.id)
        #expect(store.node(matchingTitle: "拆解")?.id == node?.id)
    }

    @Test func contentRoundTrip() {
        let store = CanvasStore()
        let node = store.addNode(ofType: ManjuNodeType.plotOutline.rawValue)
        #expect(node != nil)
        #expect(store.nodeContent(id: node!.id) == nil)
        #expect(store.updateNodeContent("紧凑剧情", for: node!.id))
        #expect(store.nodeContent(id: node!.id) == "紧凑剧情")
        // 覆盖写
        #expect(store.updateNodeContent("更紧凑", for: node!.id))
        #expect(store.nodeContent(id: node!.id) == "更紧凑")
        // 不存在节点写失败
        #expect(!store.updateNodeContent("x", for: UUID()))
    }

    @Test func novelNodeLookup() {
        let store = CanvasStore()
        #expect(store.novelNode() == nil)
        let novel = store.addNode(ofType: ManjuNodeType.novelImport.rawValue)
        #expect(novel != nil)
        #expect(store.novelNode()?.id == novel?.id)
    }
}

// MARK: - E16 聊天指令 → 画布联动（设置 / 导入）

@Suite("E16 聊天设置与导入")
@MainActor
struct E16ChatSetImportTests {
    @Test func setContentViaChat() async {
        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
        // Phase B：「建节点 剧情拆解」等文本创作类指令已下线 → 测试直接用程序化创建
        // （addNode 仍兼容文本创作类，旧图数据/一键流水线同款路径）
        #expect(bridge.canvas.addNode(ofType: ManjuNodeType.plotOutline.rawValue) != nil)
        let node = bridge.canvas.node(matchingTitle: "剧情")
        #expect(node != nil)

        bridge.chat.draftText = "设置 剧情：第一章 风起云涌"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        #expect(bridge.canvas.nodeContent(id: node!.id) == "第一章 风起云涌")
        let assistant = bridge.chat.messages.filter { $0.role == .assistant }
        #expect(assistant.contains { $0.content.contains("已更新节点「剧情拆解」") })
    }

    /// Phase B：文本创作类「建节点」指令 → 不创建节点 + 聊天引导
    @Test func chatAddTextCreativeNodeDeclined() async {
        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
        bridge.chat.draftText = "建节点 剧情拆解"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        #expect(bridge.canvas.graph.nodes.isEmpty)
        let assistant = bridge.chat.messages.filter { $0.role == .assistant }
        #expect(assistant.contains { $0.content.contains("文本创作类") })
    }

    @Test func setContentNodeNotFound() async {
        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
        bridge.chat.draftText = "设置 不存在的节点：内容"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        let assistant = bridge.chat.messages.filter { $0.role == .assistant }
        #expect(assistant.contains { $0.content.contains("找不到名称包含「不存在的节点」") })
    }

    @Test func importNovelReusesExistingNode() async {
        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
        // Phase B：「建节点 小说导入」已下线 → 程序化创建（兼容路径仍可用）
        #expect(bridge.canvas.addNode(ofType: ManjuNodeType.novelImport.rawValue) != nil)
        let novel = bridge.canvas.novelNode()
        #expect(novel != nil)

        bridge.chat.draftText = "导入小说 夜色笼罩着山城"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        #expect(bridge.canvas.nodeContent(id: novel!.id) == "夜色笼罩着山城")
        #expect(bridge.canvas.graph.nodes.count == 1) // 未新建重复节点
    }

    @Test func importNovelFromRealFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e16-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("novel.txt")
        try "第一章 风起".write(to: url, atomically: true, encoding: .utf8)

        #expect(BridgeStore.readFileIfPath(url.path) == "第一章 风起")
        #expect(BridgeStore.readFileIfPath("~/不存在的路径.txt") == nil)
        #expect(BridgeStore.readFileIfPath("纯文本不读文件") == nil)

        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
        bridge.chat.draftText = "导入小说 \(url.path)"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        let novel = bridge.canvas.novelNode()
        #expect(novel != nil)
        #expect(bridge.canvas.nodeContent(id: novel!.id) == "第一章 风起")
    }
}

// MARK: - E16 Agent 调整 / 总结流程（Mock LLM）

@Suite("E16 Agent 调整与总结")
@MainActor
struct E16AgentAdjustTests {
    @Test func lightweightProviderInheritsPrimaryWhenUnset() throws {
        let chat = ChatStore()
        chat.setProvider(.openAI)
        #expect(chat.applyPickedModel(modelID: "gpt-5.4"))
        chat.lightweightModelReferenceSource = { nil }

        let provider = try chat.lightweightTaskProvider()
        #expect(provider.model.id == "gpt-5.4")
    }

    @Test func lightweightProviderUsesProviderScopedModel() throws {
        let chat = ChatStore()
        chat.setProvider(.openAI)
        #expect(chat.applyPickedModel(modelID: "gpt-5.4"))
        chat.lightweightModelReferenceSource = {
            ProviderModelReference(providerID: "openAI", modelID: "gpt-4o-mini")
        }

        let provider = try chat.lightweightTaskProvider()
        #expect(provider.model.id == "gpt-4o-mini")
        #expect(chat.selectedModelID == "gpt-5.4")
    }

    @Test func lightweightProviderRejectsWrongNamespace() throws {
        let chat = ChatStore()
        chat.setProvider(.openAI)
        #expect(chat.applyPickedModel(modelID: "gpt-5.4"))
        chat.lightweightModelReferenceSource = {
            ProviderModelReference(providerID: "anthropic", modelID: "claude-haiku-4-5")
        }

        let provider = try chat.lightweightTaskProvider()
        #expect(provider.model.id == "gpt-5.4")
    }

    @Test func adjustNodeViaAgent() async {
        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
        // Phase B：文本创作类建节点指令已下线 → 程序化创建
        #expect(bridge.canvas.addNode(ofType: ManjuNodeType.plotOutline.rawValue) != nil)
        let node = bridge.canvas.node(matchingTitle: "剧情")
        #expect(node != nil)
        bridge.canvas.updateNodeContent("原剧情：节奏缓慢，铺垫冗长", for: node!.id)

        // 调整 剧情：更紧凑 → AgentLoop（MockProvider）→ 新内容写回
        bridge.chat.draftText = "调整 剧情：更紧凑"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)

        let content = bridge.canvas.nodeContent(id: node!.id)
        #expect(content != nil)
        #expect(content!.contains("用户要求调整：更紧凑")) // Mock 回显 prompt
        #expect(content!.contains("原剧情")) // prompt 带上了节点原内容
        let assistant = bridge.chat.messages.filter { $0.role == .assistant }
        #expect(assistant.contains { $0.content.contains("已更新节点「剧情拆解」") })
    }

    @Test func summarizeNodeViaAgent() async {
        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
        // Phase B：文本创作类建节点指令已下线 → 程序化创建
        #expect(bridge.canvas.addNode(ofType: ManjuNodeType.plotOutline.rawValue) != nil)
        let node = bridge.canvas.node(matchingTitle: "剧情")
        #expect(node != nil)
        bridge.canvas.updateNodeContent("第一章 风起。第二章 云涌。第三章 决战。", for: node!.id)

        bridge.chat.draftText = "总结 剧情"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)

        let content = bridge.canvas.nodeContent(id: node!.id)
        #expect(content != nil)
        #expect(content!.contains("请总结以下节点内容"))
        let assistant = bridge.chat.messages.filter { $0.role == .assistant }
        #expect(assistant.contains { $0.content.contains("已更新节点「剧情拆解」") })
    }

    @Test func adjustNodeNotFoundReportsInChat() async {
        let bridge = BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
        bridge.chat.draftText = "调整 不存在的节点：更紧凑"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        let assistant = bridge.chat.messages.filter { $0.role == .assistant }
        #expect(assistant.contains { $0.content.contains("找不到名称包含「不存在的节点」") })
    }

    @Test func oneShotAgentReplyDirect() async throws {
        let reply = try await AgentLoopChatEngine.oneShotAgentReply(
            provider: MockProvider.shared,
            systemPrompt: "test",
            userText: "调整：更紧凑"
        )
        #expect(reply.contains("收到：调整：更紧凑"))
    }
}

// MARK: - E16 预览/截断辅助

@Suite("E16 文本辅助")
@MainActor
struct E16TextHelperTests {
    @Test func previewTruncates() {
        #expect(BridgeStore.preview("短文本") == "短文本")
        let long = String(repeating: "字", count: 80)
        let p = BridgeStore.preview(long)
        #expect(p.count == 51) // 50 字 + …
        #expect(p.hasSuffix("…"))
        // 换行压平
        #expect(BridgeStore.preview("a\nb") == "a b")
    }

    @Test func cappedKeepsShort() {
        #expect(BridgeStore.capped("短内容") == "短内容")
        let long = String(repeating: "字", count: 1200)
        let c = BridgeStore.capped(long)
        #expect(c.count < 1200)
        #expect(c.hasSuffix("…（内容过长已截断）"))
    }
}
