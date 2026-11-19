import Foundation
import Testing
@testable import MinisCore

struct MarkdownParserTests {

    // MARK: - 标题

    @Test func headingLevels() {
        let blocks = MarkdownParser.parse("# 一级\n## 二级\n### 三级")
        #expect(blocks == [
            .heading(level: 1, text: "一级"),
            .heading(level: 2, text: "二级"),
            .heading(level: 3, text: "三级"),
        ])
    }

    @Test func headingWithoutSpaceIsParagraph() {
        let blocks = MarkdownParser.parse("#不是标题")
        #expect(blocks == [.paragraph("#不是标题")])
    }

    // MARK: - 段落与行内标记保留

    @Test func paragraphKeepsInlineMarkers() {
        let blocks = MarkdownParser.parse("这是**粗体**和*斜体*与`code`的段落")
        #expect(blocks == [.paragraph("这是**粗体**和*斜体*与`code`的段落")])
    }

    @Test func multiLineParagraphJoins() {
        let blocks = MarkdownParser.parse("第一行\n第二行")
        #expect(blocks == [.paragraph("第一行\n第二行")])
    }

    // MARK: - 代码块

    @Test func fencedCodeBlockWithLanguage() {
        let md = "```swift\nlet x = 1\nprint(x)\n```"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks == [.codeBlock(language: "swift", code: "let x = 1\nprint(x)")])
    }

    /// Q8-r4 P1-1 回归：行内反引号不得误判为闭合围栏（原 fenceCloseLength
    /// 统计全行围栏字符数，`a`b` 这类行导致代码泄漏成段落）。
    @Test func inlineBackticksInsideFenceDoNotCloseIt() {
        let md = "```\n`a`b`\ncode_leaks\n```"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks == [.codeBlock(language: nil, code: "`a`b`\ncode_leaks")])
    }

    /// 闭合围栏带 info string 不是合法闭合（CommonMark），内容保持块内。
    @Test func closingFenceWithInfoStringIsNotCloser() {
        let md = "```\ncode\n```swift\nmore\n```"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks == [.codeBlock(language: nil, code: "code\n```swift\nmore")])
    }

    /// ~~~ 围栏同样不被行内波浪号误闭合。
    @Test func inlineTildesInsideFenceDoNotCloseIt() {
        let md = "~~~\n~~note~~\nkept\n~~~"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks == [.codeBlock(language: nil, code: "~~note~~\nkept")])
    }

    @Test func fencedCodeBlockWithoutLanguage() {
        let blocks = MarkdownParser.parse("```\nraw text\n```")
        #expect(blocks == [.codeBlock(language: nil, code: "raw text")])
    }

    // MARK: - 引用

    @Test func blockquoteSingleLine() {
        let blocks = MarkdownParser.parse("> 引用的内容")
        #expect(blocks == [.blockquote("引用的内容")])
    }

    @Test func blockquoteMultiLine() {
        let blocks = MarkdownParser.parse("> 第一行\n> 第二行")
        #expect(blocks == [.blockquote("第一行\n第二行")])
    }

    // MARK: - 列表

    @Test func unorderedList() {
        let blocks = MarkdownParser.parse("- 甲\n- 乙\n- 丙")
        #expect(blocks == [.list(items: ["甲", "乙", "丙"], ordered: false)])
    }

    @Test func orderedList() {
        let blocks = MarkdownParser.parse("1. 一\n2. 二\n3. 三")
        #expect(blocks == [.list(items: ["一", "二", "三"], ordered: true)])
    }

    @Test func listStopsAtBlankLine() {
        let blocks = MarkdownParser.parse("- 甲\n\n普通段落")
        #expect(blocks == [.list(items: ["甲"], ordered: false), .paragraph("普通段落")])
    }

    @Test func nestedBulletsUnderOrderedKeepStructure() {
        let blocks = MarkdownParser.parse("1. 第一\n   - 子项甲\n   - 子项乙\n2. 第二")
        #expect(blocks == [.nestedList(items: [
            MarkdownListItem(level: 0, ordered: true, number: 1, text: "第一"),
            MarkdownListItem(level: 1, ordered: false, number: 0, text: "子项甲"),
            MarkdownListItem(level: 1, ordered: false, number: 0, text: "子项乙"),
            MarkdownListItem(level: 0, ordered: true, number: 2, text: "第二"),
        ])])
    }

    @Test func orderedListKeepsStartAndSurvivesBlankLines() {
        let blocks = MarkdownParser.parse("3. 三\n\n4. 四\n\n5. 五")
        #expect(blocks == [.nestedList(items: [
            MarkdownListItem(level: 0, ordered: true, number: 3, text: "三"),
            MarkdownListItem(level: 0, ordered: true, number: 4, text: "四"),
            MarkdownListItem(level: 0, ordered: true, number: 5, text: "五"),
        ])])
    }

    @Test func headingWithHashInsideTextStaysHeading() {
        #expect(MarkdownParser.parse("## C# 与 F# 入门") == [.heading(level: 2, text: "C# 与 F# 入门")])
    }

    // MARK: - 表格

    @Test func tableParsing() {
        let md = "| 名称 | 价格 |\n| --- | --- |\n| 苹果 | 5 |\n| 香蕉 | 3 |"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks == [
            .table(header: ["名称", "价格"], rows: [["苹果", "5"], ["香蕉", "3"]])
        ])
    }

    @Test func tableWithoutSeparatorIsParagraph() {
        let blocks = MarkdownParser.parse("| a | b |\n| c | d |")
        #expect(blocks == [.paragraph("| a | b |\n| c | d |")])
    }

    // MARK: - 分隔线

    @Test func dividerVariants() {
        #expect(MarkdownParser.parse("---") == [.divider])
        #expect(MarkdownParser.parse("***") == [.divider])
        #expect(MarkdownParser.parse("___") == [.divider])
    }

    @Test func dashWithSpaceIsListNotDivider() {
        // "- 列表" 是列表项而非分隔线
        #expect(MarkdownParser.parse("- 列表") == [.list(items: ["列表"], ordered: false)])
    }

    // MARK: - 混合文档

    @Test func mixedDocument() {
        let md = """
        # 标题

        一段文字。

        - 项一
        - 项二

        > 引用

        ```python
        print(1)
        ```
        """
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 5)
        #expect(blocks[0] == .heading(level: 1, text: "标题"))
        #expect(blocks[1] == .paragraph("一段文字。"))
        #expect(blocks[2] == .list(items: ["项一", "项二"], ordered: false))
        #expect(blocks[3] == .blockquote("引用"))
        #expect(blocks[4] == .codeBlock(language: "python", code: "print(1)"))
    }

    // MARK: - 容错（流式半输入）

    @Test func truncatedFenceDoesNotCrash() {
        // 未闭合的代码围栏：产出已收集的代码块
        let blocks = MarkdownParser.parse("```swift\nlet a = 1\nprint(a)")
        #expect(blocks == [.codeBlock(language: "swift", code: "let a = 1\nprint(a)")])
    }

    @Test func bareFenceOnly() {
        // 只有开围栏、无内容
        let blocks = MarkdownParser.parse("```")
        #expect(blocks == [.codeBlock(language: nil, code: "")])
    }

    @Test func truncatedTableKeepsParsedRows() {
        let md = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks == [.table(header: ["a", "b"], rows: [["1", "2"]])])
    }

    @Test func truncatedHeadingAndList() {
        // 只有 "#" / "-" / "1." 的流式中间态不崩，产出空内容块
        #expect(MarkdownParser.parse("#") == [.paragraph("#")])
        #expect(MarkdownParser.parse("-") == [.list(items: [""], ordered: false)])
        #expect(MarkdownParser.parse("1.") == [.list(items: [""], ordered: true)])
    }

    @Test func truncatedInlineCodeKeepsRawText() {
        // 行内代码未闭合：保留原始文本，不崩
        let blocks = MarkdownParser.parse("使用 `code 未闭合")
        #expect(blocks == [.paragraph("使用 `code 未闭合")])
    }

    @Test func truncatedListItemMidTyping() {
        // 列表项只有一半
        let blocks = MarkdownParser.parse("- 正在输入")
        #expect(blocks == [.list(items: ["正在输入"], ordered: false)])
    }

    @Test func truncatedTableHeaderOnly() {
        // 只有表头行（无分隔行）：按段落处理，不崩
        let blocks = MarkdownParser.parse("| 名称 | 价格 |")
        #expect(blocks == [.paragraph("| 名称 | 价格 |")])
    }

    // MARK: - 空输入

    @Test func emptyInput() {
        #expect(MarkdownParser.parse("") == [])
        #expect(MarkdownParser.parse("\n\n  \n") == [])
    }

    @Test func whitespaceOnlyInput() {
        #expect(MarkdownParser.parse("   ") == [])
    }

    // MARK: - Codable 往返

    @Test func codableRoundTrip() throws {
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, text: "标题"),
            .paragraph("正文 **粗**"),
            .codeBlock(language: "swift", code: "let x = 1"),
            .blockquote("引用"),
            .list(items: ["a", "b"], ordered: true),
            .table(header: ["h"], rows: [["r"]]),
            .divider,
        ]
        let data = try JSONEncoder().encode(blocks)
        let decoded = try JSONDecoder().decode([MarkdownBlock].self, from: data)
        #expect(decoded == blocks)
    }
}
