import Foundation
import Testing
@testable import MinisCore

struct ToolResultExcerptTests {
    @Test func shortTextIsReturnedUnchanged() {
        let result = ToolResultExcerpt.excerpt("短文本 short", head: 400, tail: 400)
        #expect(result.text == "短文本 short")
        #expect(result.omittedCharacters == 0)
    }

    @Test func longTextKeepsHeadAndTailAndCountsTheOmission() {
        let source = String(repeating: "a", count: 100) + String(repeating: "m", count: 5_000)
            + String(repeating: "z", count: 100)
        let result = ToolResultExcerpt.excerpt(source, head: 100, tail: 100, maxUTF8Bytes: nil)
        #expect(result.omittedCharacters == 5_000)
        #expect(result.text == String(repeating: "a", count: 100)
            + ToolResultExcerpt.omissionMarker(omittedCharacters: 5_000)
            + String(repeating: "z", count: 100))
    }

    @Test func byteCeilingHoldsForCJKAndEmojiAndNeverSplitsACluster() {
        let unit = "测试😀e\u{301}字"
        let source = String(repeating: unit, count: 3_000)
        let result = ToolResultExcerpt.excerpt(source)
        #expect(result.text.utf8.count <= ToolResultExcerpt.maximumUTF8Bytes)
        let marker = ToolResultExcerpt.omissionMarker(omittedCharacters: result.omittedCharacters)
        let parts = result.text.components(separatedBy: marker)
        #expect(parts.count == 2)
        #expect(source.hasPrefix(parts[0]))
        #expect(source.hasSuffix(parts[1]))
        #expect(result.omittedCharacters == source.count - parts[0].count - parts[1].count)
    }

    @Test func secretStraddlingTheCutIsNotLeaked() {
        // Synthetic key built here; matches the sk- format rule.
        let secret = "sk-" + String(repeating: "Ab3dEf7hIj", count: 4)
        let source = String(repeating: "p", count: 395) + secret + String(repeating: "q", count: 3_000)
        let result = ToolResultExcerpt.excerpt(source, head: 400, tail: 400, maxUTF8Bytes: nil)
        let characters = Array(secret)
        for start in 0...(characters.count - 8) {
            #expect(!result.text.contains(String(characters[start..<(start + 8)])))
        }
    }

    @Test func excerptOfAnExcerptNeverGrows() {
        let source = String(repeating: "段落内容。", count: 4_000)
        let first = ToolResultExcerpt.excerpt(source, head: 1_200, tail: 400, maxUTF8Bytes: nil)
        let second = ToolResultExcerpt.excerpt(first.text, head: 1_200, tail: 400, maxUTF8Bytes: nil)
        #expect(second.text.count <= first.text.count)
        let near = String(repeating: "x", count: 801)
        let nearResult = ToolResultExcerpt.excerpt(near, head: 400, tail: 400, maxUTF8Bytes: nil)
        #expect(ToolResultExcerpt.excerpt(nearResult.text, head: 400, tail: 400, maxUTF8Bytes: nil).text.count
            <= max(nearResult.text.count, near.count))
    }
}
