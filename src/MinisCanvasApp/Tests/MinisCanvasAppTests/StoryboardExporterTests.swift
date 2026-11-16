import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - P2 分镜表工具栏批量操作：导出 / 逐镜提示词 / 全部展开（定向测试）
//
// 覆盖：StoryboardExporter 纯函数（JSON 形状与中文不转义 / Markdown 每镜 section /
// 文件名时间戳 / 逐镜提示词汇总 / 可展开节点收集）+ CanvasStore 扩展（写盘到临时目录、
// 全部展开遍历与幂等）。GUI（剪贴板/NSSavePanel）不在测试路径触发。

@Suite("P2 分镜表工具栏批量操作")
@MainActor
struct StoryboardExporterTests {

    /// 三行分镜表（字段齐全，含中文/参考图/审核三态/备注）
    private func sampleTable() -> StoryboardTable {
        StoryboardTable(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "分镜表",
            rows: [
                StoryboardRow(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    sceneIndex: 1,
                    title: "分镜1",
                    prompt: "魏衔踏雾而来，仙袂飘举。",
                    imageRefs: ["/tmp/shot1.png"],
                    videoRefs: ["/tmp/shot1.mp4"],
                    reviewStatus: .pass,
                    notes: "首镜，打光偏冷。",
                    nodeIDs: [UUID(uuidString: "33333333-3333-3333-3333-333333333333")!]
                ),
                StoryboardRow(
                    sceneIndex: 2,
                    title: "分镜2",
                    prompt: "大殿香炉青烟袅袅。",
                    reviewStatus: .pending,
                    notes: ""
                ),
                StoryboardRow(
                    sceneIndex: 3,
                    title: "分镜3",
                    prompt: "",
                    reviewStatus: .reject,
                    notes: "表情不自然，需重拍。"
                ),
            ],
            sourceNodeID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
    }

    // MARK: 导出 JSON

    @Test("exportJSON：可解析、字段齐全、中文不转义")
    func exportJSONShapeAndFields() throws {
        let json = try StoryboardExporter.exportJSON(sampleTable())

        // 中文原样输出（不转义为 \uXXXX）
        #expect(json.contains("魏衔踏雾而来"))
        #expect(!json.contains("\\u"))

        // 顶层形状
        let data = try #require(json.data(using: .utf8))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["title"] as? String == "分镜表")
        #expect(obj["sourceNodeID"] as? String == "44444444-4444-4444-4444-444444444444")
        #expect(obj["id"] as? String == "11111111-1111-1111-1111-111111111111")
        #expect(obj["updatedAt"] != nil)

        let rows = try #require(obj["rows"] as? [[String: Any]])
        #expect(rows.count == 3)

        // 行字段齐全
        let row1 = try #require(rows.first)
        #expect(row1["sceneIndex"] as? Int == 1)
        #expect(row1["title"] as? String == "分镜1")
        #expect(row1["prompt"] as? String == "魏衔踏雾而来，仙袂飘举。")
        #expect(row1["imageRefs"] as? [String] == ["/tmp/shot1.png"])
        #expect(row1["videoRefs"] as? [String] == ["/tmp/shot1.mp4"])
        #expect(row1["reviewStatus"] as? String == "PASS")
        #expect(row1["notes"] as? String == "首镜，打光偏冷。")
        #expect(row1["nodeIDs"] as? [String] == ["33333333-3333-3333-3333-333333333333"])

        // 三态 rawValue 契约
        let row3 = rows[2]
        #expect(row3["reviewStatus"] as? String == "REJECT")
    }

    // MARK: 导出 Markdown

    @Test("exportMarkdown：# 标题 + 每镜 ## 镜号.标题 + 提示词/参考图/审核状态/备注")
    func exportMarkdownSections() {
        let md = StoryboardExporter.exportMarkdown(sampleTable())

        #expect(md.contains("# 分镜表"))
        #expect(md.contains("## 01. 分镜1"))
        #expect(md.contains("## 02. 分镜2"))
        #expect(md.contains("## 03. 分镜3"))
        #expect(md.contains("**提示词**"))
        #expect(md.contains("魏衔踏雾而来，仙袂飘举。"))
        #expect(md.contains("**参考图路径**"))
        #expect(md.contains("- /tmp/shot1.png"))
        #expect(md.contains("**审核状态**"))
        #expect(md.contains("通过"))
        #expect(md.contains("待审"))
        #expect(md.contains("打回"))
        #expect(md.contains("**备注**"))
        #expect(md.contains("首镜，打光偏冷。"))
        #expect(md.contains("表情不自然，需重拍。"))

        // 空字段兜底
        #expect(md.contains("（无）"))
    }

    // MARK: 导出文件名

    @Test("exportFileName：前缀 + yyyyMMdd_HHmmss 时间戳")
    func exportFileNameTimestamp() throws {
        // 固定日期注入，断言精确值（en_US_POSIX 固定格式，与时区无关）
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 5
        components.hour = 14
        components.minute = 30
        components.second = 7
        let fixed = try #require(Calendar(identifier: .gregorian).date(from: components))

        let name = StoryboardExporter.exportFileName(date: fixed)
        #expect(name == "MinisCanvas-分镜表-20260805_143007")

        // 默认当前时间：格式校验
        let now = StoryboardExporter.exportFileName()
        #expect(now.hasPrefix("MinisCanvas-分镜表-"))
        let suffix = now.dropFirst("MinisCanvas-分镜表-".count)
        #expect(suffix.count == 15) // yyyyMMdd_HHmmss = 8+1+6
        let range = suffix.range(of: #"^\d{8}_\d{6}$"#, options: .regularExpression)
        #expect(range != nil)
    }

    // MARK: 逐镜提示词汇总

    @Test("promptSummaryText：每镜镜号.标题 + 提示词，空提示词标注")
    func promptSummaryTextJoinsRows() {
        let text = StoryboardExporter.promptSummaryText(sampleTable())
        #expect(text.contains("【逐镜提示词】分镜表"))
        #expect(text.contains("01. 分镜1"))
        #expect(text.contains("魏衔踏雾而来，仙袂飘举。"))
        #expect(text.contains("02. 分镜2"))
        #expect(text.contains("大殿香炉青烟袅袅。"))
        #expect(text.contains("03. 分镜3"))
        #expect(text.contains("（无）"))
    }

    // MARK: 全部展开（可展开节点收集 + 遍历调用 + 幂等）

    /// 模板图 + 3 段分镜脚本文本（与 ManjuStoryboardExpandTests 同源构造）
    private func templateStore(script: String) -> CanvasStore {
        let store = CanvasStore(graph: ManjuPipelineTemplate.makeManjuPipeline(assets: .demo))
        let sb = store.graph.nodes.first { $0.type == ManjuNodeType.storyboard.rawValue }!
        store.setContent(nodeID: sb.id, content: script)
        return store
    }

    @Test("expandableStoryboardNodeIDs：收集分镜节点（y 主排序）")
    func expandableNodeIDsCollectsStoryboards() {
        let store = templateStore(script: """
        第1镜：魏衔踏雾而来。
        第2镜：大殿香炉青烟。
        第3镜：神像暗部。
        """)
        let ids = StoryboardExporter.expandableStoryboardNodeIDs(in: store.graph)
        #expect(ids.count == 1)
        #expect(store.graph.node(id: ids[0])?.type == ManjuNodeType.storyboard.rawValue)
    }

    @Test("expandAllStoryboards：未展开 3 段 → 展开为 3 节点并返回 3")
    func expandAllExpandsUnexpanded() {
        let store = templateStore(script: """
        第1镜：魏衔踏雾而来。
        第2镜：大殿香炉青烟。
        第3镜：神像暗部。
        """)
        let before = store.graph.nodes.count
        let storyboardsBefore = store.graph.nodes.filter { $0.type == ManjuNodeType.storyboard.rawValue }.count

        let total = store.expandAllStoryboards()

        #expect(total == 3)
        #expect(store.graph.nodes.count == before + 2)
        let storyboardsAfter = store.graph.nodes.filter { $0.type == ManjuNodeType.storyboard.rawValue }.count
        #expect(storyboardsAfter == storyboardsBefore + 2)
        // 每个分镜节点内容 = 对应段
        let contents = store.graph.nodes
            .filter { $0.type == ManjuNodeType.storyboard.rawValue }
            .compactMap { $0.backendConfig?.params["content"] }
        #expect(contents.contains("第1镜：魏衔踏雾而来。"))
        #expect(contents.contains("第3镜：神像暗部。"))
    }

    @Test("expandAllStoryboards：幂等——再次调用不重复展开")
    func expandAllIsIdempotent() {
        let store = templateStore(script: """
        第1镜：魏衔踏雾而来。
        第2镜：大殿香炉青烟。
        第3镜：神像暗部。
        """)
        let first = store.expandAllStoryboards()
        #expect(first == 3)
        let nodesAfterFirst = store.graph.nodes.count

        let second = store.expandAllStoryboards()

        // 已展开节点内容均为单段 → expandStoryboard 返回 1 不改图 → 累计 0
        #expect(second == 0)
        #expect(store.graph.nodes.count == nodesAfterFirst)
    }

    @Test("expandAllStoryboards：无分镜节点 → 0 且不改图")
    func expandAllEmptyGraph() {
        let store = CanvasStore(graph: NodeGraph())
        let total = store.expandAllStoryboards()
        #expect(total == 0)
        #expect(store.graph.nodes.isEmpty)
    }

    // MARK: 写盘（临时目录，不污染 ~/Downloads）

    @Test("exportStoryboardJSON：落盘临时目录、内容可解析、statusMessage 提示路径")
    func exportJSONWritesFile() throws {
        let store = templateStore(script: "第1镜：魏衔踏雾而来。")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoryboardExporterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try #require(store.exportStoryboardJSON(to: dir))

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.hasSuffix(".json"))
        #expect(path.contains("MinisCanvas-分镜表-"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["title"] as? String == "分镜表")
        // statusMessage 提示路径
        #expect(store.statusMessage?.contains("已导出分镜表 JSON") == true)
        #expect(store.statusMessage?.contains(path) == true)
    }

    @Test("exportStoryboardMarkdown：落盘临时目录、内容含分镜 section、statusMessage 提示路径")
    func exportMarkdownWritesFile() throws {
        let store = templateStore(script: "第1镜：魏衔踏雾而来。")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoryboardExporterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try #require(store.exportStoryboardMarkdown(to: dir))

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.hasSuffix(".md"))
        let content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(content.contains("# 分镜表"))
        #expect(content.contains("## 01."))
        #expect(store.statusMessage?.contains("已导出分镜表 Markdown") == true)
    }
}
