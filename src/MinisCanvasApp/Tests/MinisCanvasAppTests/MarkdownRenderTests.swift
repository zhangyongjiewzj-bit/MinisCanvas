import Testing
import Foundation
@testable import MinisCanvasApp

// MARK: - Markdown 渲染层（MinisCore 块映射）测试

@Suite("Markdown 渲染映射")
struct MarkdownRenderTests {

    @Test func blockquoteMapsToParagraph() {
        let blocks = MarkdownParser.blocks(from: "> 引用一行\n> 引用二行")
        guard case .paragraph(let p)? = blocks.first else {
            Issue.record("引用应映射为段落"); return
        }
        #expect(p == "引用一行\n引用二行")
    }

    @Test func orderedListMapsToItems() {
        let blocks = MarkdownParser.blocks(from: "1. 甲\n2. 乙")
        guard case .list(let items)? = blocks.first else {
            Issue.record("有序列表应映射为 list"); return
        }
        #expect(items == ["甲", "乙"])
    }

    @Test func tableMapsToParagraph() {
        let blocks = MarkdownParser.blocks(from: "| 列A | 列B |\n|---|---|\n| 1 | 2 |")
        guard case .paragraph(let p)? = blocks.first else {
            Issue.record("表格应映射为段落"); return
        }
        #expect(p.contains("列A"))
        #expect(p.contains("1"))
    }

    @Test func dividerMapsToParagraph() {
        let blocks = MarkdownParser.blocks(from: "---")
        guard case .paragraph(let p)? = blocks.first else {
            Issue.record("分隔线应映射为段落"); return
        }
        #expect(p.contains("—"))
    }

    @Test func codeFenceWithLanguageThroughCore() {
        let blocks = MarkdownParser.blocks(from: "```swift\nlet a = 1\n```")
        guard case .code(let language, let code)? = blocks.first else {
            Issue.record("应为代码块"); return
        }
        #expect(language == "swift")
        #expect(code == "let a = 1")
    }

    @Test func truncatedStreamingInputDoesNotCrash() {
        // 流式中间态：未闭合围栏 + 未闭合列表，解析器容错不崩
        let blocks = MarkdownParser.blocks(from: "## 标题\n\n- 项一\n```swift\nlet a = ")
        #expect(!blocks.isEmpty)
    }

    @Test func mixedBlocksKeepOrder() {
        let blocks = MarkdownParser.blocks(from: "# 标题\n\n> 引用\n\n- 甲\n- 乙\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---")
        #expect(blocks.count == 5)
        guard case .heading(let level, _) = blocks[0] else { Issue.record("首块应为标题"); return }
        #expect(level == 1)
    }

    @Test func attributedRenderKeepsAssessmentAndVisibleText() {
        let state = MarkdownAttributedTextBuilder.renderState(
            content: "# 标题\n\n[链接](https://example.com)",
            isMarkdown: true
        )
        #expect(state.status == .rendered)
        #expect(state.status.userMessage == nil)
        let linkRange = (state.attributedString.string as NSString).range(of: "链接")
        #expect(linkRange.location != NSNotFound)
        if linkRange.location != NSNotFound {
            let destination = state.attributedString.attribute(
                TranscriptExternalLink.destination, at: linkRange.location, effectiveRange: nil
            ) as? URL
            #expect(destination?.absoluteString == "https://example.com")
        }
        #expect(state.attributedString.string.contains("标题"))
        #expect(state.attributedString.string.contains("链接"))
    }

    @Test func literalRedactionRunsKeepTheSigned15BodyAndTagWithoutFallback() {
        for count in [24, 26, 28] {
            let mask = String(repeating: "*", count: count)
            let content = "No tools. 只回复 G22_C15_BODYTAIL_OK，不添加其它内容。下面仅为合成测试文字：\n"
                + "idempotency_key=\(mask)；switch_after_create=false；最后一句：中文尾段必须完整保留。"
            let state = MarkdownAttributedTextBuilder.renderState(content: content, isMarkdown: true)
            #expect(state.status == .rendered)
            #expect(state.statusMessage == nil)
            #expect(state.attributedString.string.contains("idempotency_key=\(mask)；switch_after_create=false；最后一句：中文尾段必须完整保留。"))
            #expect(state.attributedString.string.contains("G22_C15_BODYTAIL_OK"))
            let transcript = ChatTranscriptFormatter.formattedMessage(
                ChatMessageUI(role: .user, content: content), baseSize: 13,
                redactor: ChatTranscriptRedactor(secretValues: []))
            #expect(transcript.string.contains(mask))
            #expect(transcript.string.contains("中文尾段必须完整保留。"))
            #expect(!transcript.string.contains(ReadOnlyAttributedTextStatus.fallback.userMessage ?? "unexpected fallback"))
        }
        let tag = MarkdownAttributedTextBuilder.renderState(content: "G22_C15_BODYTAIL_OK", isMarkdown: true)
        #expect(tag.status == .rendered)
        #expect(tag.attributedString.string == "G22_C15_BODYTAIL_OK\n")
    }

    @Test func literalRunsDoNotDisableStrongOrOtherFallbackGuards() {
        let bold = MarkdownAttributedTextBuilder.renderState(content: "**正常强调**", isMarkdown: true)
        #expect(bold.status == .rendered)
        #expect(bold.attributedString.string.contains("正常强调"))
        #expect(!bold.attributedString.string.contains("**"))
        for content in ["**未闭合强调", "未闭合强调**", "***未闭合强调", "未闭合 `代码",
                        "***（未闭合强调", "***“未闭合强调", "***!未闭合强调",
                        "值=***（未闭合强调", "值=***“未闭合强调", "值=***!未闭合强调",
                        "***；未闭合强调"] {
            let state = MarkdownAttributedTextBuilder.renderState(content: content, isMarkdown: true)
            #expect(state.status == .fallback)
            #expect(state.attributedString.string.contains(content))
        }
        for content in ["**标记=***；", "**标记=******；", "标记=***；正常强调***"] {
            let state = MarkdownAttributedTextBuilder.renderState(content: content, isMarkdown: true)
            #expect(state.status == .rendered)
            #expect(state.statusMessage == nil)
            #expect(state.attributedString.string.contains("标记="))
        }
        let mixed = MarkdownAttributedTextBuilder.renderState(
            content: "遮蔽：**************************； **正常强调**", isMarkdown: true)
        #expect(mixed.status == .rendered)
        #expect(mixed.attributedString.string.contains("**************************"))
        #expect(mixed.attributedString.string.contains("正常强调"))
    }

    // MARK: 第二轮修复：行内代码、列表、链接、代码块复制

    @Test func globAndStarsInsideInlineCodeDoNotTriggerFormatWarning() {
        let state = MarkdownAttributedTextBuilder.renderState(
            content: "用 `src/**/*.swift` 和 `**kwargs` 匹配", isMarkdown: true)
        #expect(state.status == .rendered)
        #expect(state.statusMessage == nil)
        #expect(!state.attributedString.string.contains("Markdown 格式异常"))
    }

    @Test func unclosedBacktickIsOnlyFlaggedAfterStreamingEnds() {
        let streaming = MarkdownAttributedTextBuilder.renderState(
            content: "正在写 `code", isMarkdown: true, isStreaming: true)
        #expect(streaming.status == .rendered)
        let finished = MarkdownAttributedTextBuilder.renderState(content: "正在写 `code", isMarkdown: true)
        #expect(finished.status == .fallback)
    }

    @Test func nestedAndRestartedOrderedListsRenderTheirOwnNumbers() {
        let nested = MarkdownAttributedTextBuilder.build(
            content: "1. 第一\n   - 子项\n2. 第二", isMarkdown: true).string
        #expect(nested.contains("1. 第一"))
        #expect(nested.contains("• 子项") || nested.contains("◦ 子项"))
        #expect(nested.contains("2. 第二"))
        let spaced = MarkdownAttributedTextBuilder.build(
            content: "3. 三\n\n4. 四", isMarkdown: true).string
        #expect(spaced.contains("3. 三"))
        #expect(spaced.contains("4. 四"))
        #expect(!spaced.contains("1. 四"))
    }

    @Test func bareURLAndExistingFilePathBecomeLinks() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("W6Link-\(UUID().uuidString).swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let text = MarkdownAttributedTextBuilder.build(
            content: "见 https://example.com/docs。文件 \(file.path):42 与不存在的 /nope/none.txt", isMarkdown: true)
        let ns = text.string as NSString
        let url = ns.range(of: "https://example.com/docs")
        #expect((text.attribute(TranscriptExternalLink.destination, at: url.location, effectiveRange: nil) as? URL)?
            .absoluteString == "https://example.com/docs")
        let path = ns.range(of: file.path)
        #expect(text.attribute(TranscriptExternalLink.destination, at: path.location, effectiveRange: nil) != nil)
        let missing = ns.range(of: "/nope/none.txt")
        #expect(text.attribute(TranscriptExternalLink.destination, at: missing.location, effectiveRange: nil) == nil)
    }

    @Test func fencedCodeBlockCarriesAClickableCopyEntry() {
        let text = MarkdownAttributedTextBuilder.build(content: "```swift\nlet a = 1\n```", isMarkdown: true)
        let range = (text.string as NSString).range(of: TranscriptCodeCopy.label)
        #expect(range.location != NSNotFound)
        #expect(text.attribute(TranscriptCodeCopy.payload, at: range.location, effectiveRange: nil) as? String == "let a = 1")
        let safe = ReadOnlyAttributedTextView.sanitized(text)
        #expect(safe.attribute(.link, at: range.location, effectiveRange: nil) != nil)
    }

}
