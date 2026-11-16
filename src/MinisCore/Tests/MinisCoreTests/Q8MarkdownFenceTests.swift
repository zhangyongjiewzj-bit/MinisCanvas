import Foundation
import Testing
@testable import MinisCore

// MARK: - Q8-r5（Q8-r4 P1-1）：Markdown 围栏闭合误判 + 流式分块内容泄漏回归
//
// 原始实证（Q8-r4.log L16-19）："```\n`a`b`\ncode_leaks\n```" 被切成 3 块，
// 围栏内代码泄漏成普通段落渲染。根因：fenceCloseLength 曾统计行内任意位置
// 围栏字符数，行内反引号（inline code）被误判为闭合围栏。
// 修复（snapshot 043052c）：闭合围栏 = 行首前缀连续围栏字符 + 仅允许尾部空白
// （CommonMark：闭合围栏不含 info string）。本套件把该行为钉死为回归测试，
// 并用逐字符流式分块模拟验证：任何截断前缀中，未闭合围栏后的内容始终留在
// codeBlock 内（保持代码块样式，等后续 chunk 补齐），不泄漏为段落。

@Suite("Q8Markdown: 围栏闭合与流式分块")
struct Q8MarkdownFenceTests {

    // MARK: 原始实证回归（Q8-r4 P1-1 的三种围栏形态）

    @Test func inlineBackticksInsideFenceDoNotCloseIt() {
        // 行内 `a`b` 三个反引号散布行内 ≠ 闭合围栏
        let blocks = MarkdownParser.parse("```\n`a`b`\ncode_leaks\n```")
        #expect(blocks == [.codeBlock(language: nil, code: "`a`b`\ncode_leaks")])
    }

    @Test func fourBacktickFenceWithInlineBackticks() {
        let blocks = MarkdownParser.parse("````\n`a`b`\ncode_leaks\n````")
        #expect(blocks == [.codeBlock(language: nil, code: "`a`b`\ncode_leaks")])
    }

    @Test func tildeFenceWithInlineTildes() {
        let blocks = MarkdownParser.parse("~~~\n~a~b~\ncode_leaks\n~~~")
        #expect(blocks == [.codeBlock(language: nil, code: "~a~b~\ncode_leaks")])
    }

    @Test func inlineCodeWithLanguageFence() {
        // LLM 典型输出：带语言围栏 + 代码内含 inline code 与反引号串
        let md = "```swift\nlet s = \"`a`b`\"\nprint(s) // ```` 不是闭合\n```"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks == [.codeBlock(language: "swift", code: "let s = \"`a`b`\"\nprint(s) // ```` 不是闭合")])
    }

    // MARK: CommonMark 闭合语义钉死

    @Test func closingFenceWithInfoStringDoesNotClose() {
        // 闭合围栏后跟非空白文本（info string）→ 不是闭合，仍是代码内容
        let blocks = MarkdownParser.parse("```\ncode\n```swift\nmore\n```")
        #expect(blocks == [.codeBlock(language: nil, code: "code\n```swift\nmore")])
    }

    @Test func shorterFenceCannotCloseLongerOpening() {
        // 开围栏 4 个字符 → 3 个字符的行不是闭合
        let blocks = MarkdownParser.parse("````\n```\nstill code\n````")
        #expect(blocks == [.codeBlock(language: nil, code: "```\nstill code")])
    }

    @Test func closingFenceAllowsTrailingWhitespace() {
        let blocks = MarkdownParser.parse("```\ncode\n```   ")
        #expect(blocks == [.codeBlock(language: nil, code: "code")])
    }

    // MARK: 流式分块模拟（逐字符增量，任意前缀不泄漏）

    /// 逐字符喂入；只要闭合围栏尚未到达，开围栏之后的全部内容必须位于
    /// codeBlock 内（未闭合容错 = 保持代码块样式），任何 chunk 不得把
    /// 围栏内内容泄漏成 paragraph。
    @Test func streamingChunksNeverLeakUnclosedFenceContent() {
        let full = """
        # 标题

        ```swift
        let a = `inline` // 行内反引号
        print(a)
        ```

        尾部段落
        """
        var received = ""
        var checkedChunks = 0
        for ch in full {
            received.append(ch)
            // 闭合围栏（独立一行 ```）尚未到达时才做泄漏断言
            let closed = received.contains("\n```\n") || received.hasSuffix("\n```")
            guard !closed, received.contains("```swift") else { continue }
            guard let fenceRange = received.range(of: "```swift", options: .backwards) else { continue }

            // 开围栏之后（去掉紧随的换行）的所有内容都应在 codeBlock 内
            var inside = String(received[fenceRange.upperBound...])
            if inside.hasPrefix("\n") { inside.removeFirst() }

            let codeBlocks = MarkdownParser.parse(received).compactMap { block -> String? in
                if case .codeBlock(_, let code) = block { return code } else { return nil }
            }
            #expect(
                codeBlocks.contains(inside),
                "流式 chunk 泄漏（前缀截断到 …\(received.suffix(28))…）"
            )
            // 且不允许出现「围栏内内容」形成的段落
            let paragraphs = MarkdownParser.parse(received).compactMap { block -> String? in
                if case .paragraph(let text) = block { return text } else { return nil }
            }
            for p in paragraphs {
                #expect(!inside.contains(p), "段落泄漏：\(p)")
            }
            checkedChunks += 1
        }
        #expect(checkedChunks > 20, "应有足够多的未闭合中间态被断言")

        // 完整内容到齐 → 3 块：标题 / 代码块 / 段落
        let finalBlocks = MarkdownParser.parse(full)
        #expect(finalBlocks == [
            .heading(level: 1, text: "标题"),
            .codeBlock(language: "swift", code: "let a = `inline` // 行内反引号\nprint(a)"),
            .paragraph("尾部段落"),
        ])
    }

    /// 分块边界恰好切在闭合围栏中间（"…\n`"、"…\n``"）也不泄漏。
    @Test func streamingChunkBoundaryInsideClosingFence() {
        let cases: [(prefix: String, code: String)] = [
            ("```\n`a`b`\ncode_leaks\n`", "`a`b`\ncode_leaks\n`"),
            ("```\n`a`b`\ncode_leaks\n``", "`a`b`\ncode_leaks\n``"),
        ]
        for (prefix, expectedCode) in cases {
            let blocks = MarkdownParser.parse(prefix)
            // 关键断言：只有 1 个 codeBlock，无段落泄漏
            #expect(blocks.count == 1, "前缀截断 …\(prefix.suffix(6)) 产出块数异常")
            if case .codeBlock(let lang, let code) = blocks.first {
                #expect(lang == nil)
                #expect(code == expectedCode)
            } else {
                Issue.record("前缀截断 …\(prefix.suffix(6)) 未产出 codeBlock：\(blocks)")
            }
        }
    }

    /// 嵌套围栏（外 4 反引号包裹 3 反引号行）：3 反引号行是内容不是闭合。
    @Test func streamingNestedFenceStaysInCodeBlock() {
        let full = "````\n```python\nprint(1)\n```\n````"
        var received = ""
        for ch in full {
            received.append(ch)
            guard received.hasPrefix("````\n"), !received.hasSuffix("````") else { continue }
            let blocks = MarkdownParser.parse(received)
            #expect(blocks.count == 1, "嵌套围栏流式中途应保持单一 codeBlock：…\(received.suffix(16))")
            if let first = blocks.first, case .codeBlock = first {} else {
                Issue.record("嵌套围栏流式中途块类型错误：\(blocks)")
            }
        }
        #expect(MarkdownParser.parse(full) == [
            .codeBlock(language: nil, code: "```python\nprint(1)\n```")
        ])
    }
}
