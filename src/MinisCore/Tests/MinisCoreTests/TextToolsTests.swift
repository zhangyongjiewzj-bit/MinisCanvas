import Foundation
import Testing
@testable import MinisCore

struct TextToolsTests {

    // MARK: - TokenCounter

    @Test func tokenCountEmptyIsZero() {
        #expect(TokenCounter.shared.countTokens("") == 0)
    }

    @Test func tokenCountEnglishWords() {
        // The local estimate counts each contiguous English word once.
        #expect(TokenCounter.shared.countTokens("hello world") == 2)
    }

    @Test func tokenCountDeterministic() {
        let text = "MinisCanvas 是一个本地优先的 AI 助手。Hello, world!"
        let first = TokenCounter.shared.countTokens(text)
        let second = TokenCounter.shared.countTokens(text)
        #expect(first == second)
        #expect(first > 0)
    }

    @Test func tokenCountMixedChineseEnglish() {
        let text = "你好世界，这是一个测试。Hello world, this is a test."
        let count = TokenCounter.shared.countTokens(text)
        // The local estimate is bounded by the UTF-8 representation.
        #expect(count > 0)
        #expect(count <= text.utf8.count)
    }

    @Test func tokenCountChineseBounded() {
        let text = "你好世界"
        let count = TokenCounter.shared.countTokens(text)
        #expect(count >= 1)
        #expect(count <= text.utf8.count) // 12 bytes for 4 CJK chars
    }

    // MARK: - SentenceSplitter

    @Test func splitChinesePunctuation() {
        #expect(SentenceSplitter.split("你好。世界！") == ["你好。", "世界！"])
    }

    @Test func splitEnglishPunctuation() {
        let result = SentenceSplitter.split("Hello world! How are you? Fine.")
        #expect(result == ["Hello world!", "How are you?", "Fine."])
    }

    @Test func splitSemicolons() {
        let result = SentenceSplitter.split("第一；第二; third")
        #expect(result == ["第一；", "第二;", "third"])
    }

    @Test func splitNoTerminatorReturnsSingleSentence() {
        #expect(SentenceSplitter.split("just some text") == ["just some text"])
    }

    @Test func splitWhitespaceOnlyIsEmpty() {
        #expect(SentenceSplitter.split("   \n  ").isEmpty)
    }

    // MARK: - MarkdownStripper

    @Test func stripHeadings() {
        #expect(MarkdownStripper.strip("# 一级标题") == "一级标题")
        #expect(MarkdownStripper.strip("### 三级") == "三级")
    }

    @Test func stripCodeBlock() {
        #expect(MarkdownStripper.strip("```swift\nlet x = 1\nprint(x)\n```") == "")
    }

    @Test func stripInlineEmphasis() {
        #expect(MarkdownStripper.strip("**粗体**和*斜体*与`code`") == "粗体和斜体与code")
    }

    @Test func stripLinks() {
        #expect(MarkdownStripper.strip("[OpenAI](https://openai.com)") == "OpenAI")
        // Empty link text falls back to the URL.
        #expect(MarkdownStripper.strip("[](https://example.com)") == "https://example.com")
    }

    @Test func stripTableAndList() {
        let md = "| a | b |\n|---|---|\n| 1 | 2 |\n\n- item一\n- item二"
        let result = MarkdownStripper.strip(md)
        #expect(result == "item一 item二")
    }

    @Test func stripMixedDocument() {
        let md = "# 标题\n\n正文段落，包含**重点**内容。\n\n- 列表项"
        let result = MarkdownStripper.strip(md)
        #expect(result == "标题 正文段落，包含重点内容。 列表项")
    }

    // MARK: - TextSegmenter

    @Test func segmentEmptyIsEmpty() {
        #expect(TextSegmenter.segment("   ", maxLength: 10).isEmpty)
        #expect(TextSegmenter.segment("文本", maxLength: 0).isEmpty)
    }

    @Test func segmentShortTextSingleChunk() {
        #expect(TextSegmenter.segment("短文本", maxLength: 100) == ["短文本"])
    }

    @Test func segmentPacksSentencesWithinLimit() {
        let result = TextSegmenter.segment("第一句。第二句。第三句。", maxLength: 20)
        #expect(result == ["第一句。 第二句。 第三句。"])
    }

    @Test func segmentBreaksAtSentenceBoundary() {
        let result = TextSegmenter.segment("第一句。第二句。第三句。", maxLength: 10)
        #expect(result == ["第一句。 第二句。", "第三句。"])
        for chunk in result {
            #expect(chunk.count <= 10)
        }
    }

    @Test func segmentHardCutsOverlongSentence() {
        let long = String(repeating: "a", count: 100)
        let result = TextSegmenter.segment(long, maxLength: 30)
        #expect(result.count == 4)
        for chunk in result {
            #expect(chunk.count <= 30)
        }
        #expect(result.joined() == long)
    }

    @Test func segmentAllChunksWithinLimitMixed() {
        let text = "这是第一句话，讲的是开头。然后是第二句话，稍微长一点。\nThird sentence in English follows here. And a fourth one."
        let result = TextSegmenter.segment(text, maxLength: 15)
        #expect(!result.isEmpty)
        for chunk in result {
            #expect(chunk.count <= 15)
        }
    }
}
