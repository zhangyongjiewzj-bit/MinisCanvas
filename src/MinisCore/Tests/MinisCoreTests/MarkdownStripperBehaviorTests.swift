import Testing
@testable import MinisCore

struct MarkdownStripperBehaviorTests {
    @Test func wordUnderscoresSurviveAlongsideEmphasis() {
        let input = "foo_bar_baz https://example.com/word_part_name _重点_"
        let expected = "foo_bar_baz https://example.com/word_part_name 重点"
        #expect(MarkdownStripper.strip(input) == expected)
        #expect(MarkdownStripper.plainText(input) == expected)
    }

    @Test func singleCharacterDividerLinesDisappear() {
        for (input, expected) in [("前\n-\n*\n后", "前 后"), ("~~", "")] {
            #expect(MarkdownStripper.strip(input) == expected)
            #expect(MarkdownStripper.plainText(input) == expected)
        }
    }

    @Test func entryPointsPreserveUnicodeAndInteriorTabs() {
        for (input, expected) in [
            ("", ""), (" \n\t ", ""),
            ("  中文👩🏽‍💻  e\u{301}\t正文\n\n下一行  ", "中文👩🏽‍💻 e\u{301}\t正文 下一行")
        ] {
            #expect(MarkdownStripper.strip(input) == expected)
            #expect(MarkdownStripper.plainText(input) == expected)
        }
    }

    @Test func imagesAndLinksUseDifferentEmptyLabelRules() {
        let input = "![头像🙂](https://example.com/a.png) ![](hidden.png) "
            + "[](https://example.com?q=1&lang=zh \"标题\") <https://example.com/path>"
        #expect(MarkdownStripper.strip(input)
            == "头像🙂 https://example.com?q=1&lang=zh https://example.com/path")
    }

    @Test func lineFormsKeepOrdinaryPunctuationAndTildeBody() {
        let input = "> 引用\n1. 一\n2) 二\n3: 三\n+ 四\n---\n"
            + "a | b |\n| :--- |\n~~~text\n保留内容\n~~~\n"
            + "正文#号 3.14 /a/b\n####### 不是标题"
        #expect(MarkdownStripper.strip(input)
            == "引用 一 二 三 四 保留内容 正文#号 3.14 /a/b ####### 不是标题")
    }
}
