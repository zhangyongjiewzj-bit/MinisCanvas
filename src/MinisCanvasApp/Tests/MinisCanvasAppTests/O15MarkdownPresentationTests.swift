import XCTest
import AppKit
@testable import MinisCanvasApp

@MainActor
final class O15MarkdownPresentationTests: XCTestCase {
    func testLongTableShowsAlignedColumnsAndCopyNotice() {
        let source = "| A | B | C | D | E |\n| --- | --- | --- | --- | --- |\n"
            + (1...201).map { "| row\($0) | b | c | d | e |" }.joined(separator: "\n")
        let rendered = MarkdownAttributedTextBuilder.build(content: source, isMarkdown: true)
        XCTAssertTrue(rendered.string.contains("row200"))
        XCTAssertFalse(rendered.string.contains("row201"))
        XCTAssertTrue(rendered.string.contains("还有 1 行，复制可得全部"))
        let paragraph = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual((paragraph?.textBlocks.first as? NSTextTableBlock)?.table.numberOfColumns, 5)
    }

    func testMalformedParagraphPreservesOtherParagraphFormatting() {
        let rendered = MarkdownAttributedTextBuilder.renderState(
            content: "# 正常标题\n\n未闭合 `片段\n\n完整段落", isMarkdown: true)
        XCTAssertTrue(rendered.attributedString.string.contains("未闭合 `片段"))
        XCTAssertTrue(rendered.attributedString.string.contains("完整段落"))
        XCTAssertFalse(rendered.attributedString.string.hasPrefix("#"))
        XCTAssertTrue(rendered.attributedString.string.contains("Markdown 格式异常，已按纯文本显示。"))
    }

    func testOnlyExplicitWebLinksSurviveSanitizationAsConfirmedNavigation() {
        let rendered = MarkdownAttributedTextBuilder.build(
            content: "[网页](https://example.com/docs) [本地](file:///tmp/private)", isMarkdown: true)
        let safe = ReadOnlyAttributedTextView.sanitized(rendered)
        let webRange = (safe.string as NSString).range(of: "网页")
        let fileRange = (safe.string as NSString).range(of: "本地")
        XCTAssertEqual((safe.attribute(.link, at: webRange.location, effectiveRange: nil) as? URL)?.scheme, "https")
        XCTAssertNil(safe.attribute(.link, at: fileRange.location, effectiveRange: nil))
        XCTAssertNil(TranscriptExternalLink.allowedURL("https://user:password@example.com"))
        let sessionID = UUID()
        let original = ReadOnlyAttributedTextView.Coordinator()
        original.linkSessionID = sessionID
        XCTAssertFalse(original.hasConfirmedLink(to: "example.com"))
        TranscriptExternalLink.confirm(host: "example.com", sessionID: sessionID)
        let recreated = ReadOnlyAttributedTextView.Coordinator()
        recreated.linkSessionID = sessionID
        XCTAssertTrue(recreated.hasConfirmedLink(to: "example.com"))
        recreated.linkSessionID = UUID()
        XCTAssertFalse(recreated.hasConfirmedLink(to: "example.com"))
        let longURL = URL(string: "https://example.com/" + String(repeating: "a", count: 700))!
        XCTAssertLessThan(TranscriptExternalLink.confirmationDisplay(for: longURL).count, longURL.absoluteString.count)
        // An arbitrary incoming link has no app-authored navigation marker.
        XCTAssertNil(ReadOnlyAttributedTextView.sanitized(NSAttributedString(
            string: "link", attributes: [.link: URL(string: "https://example.com")!]
        )).attribute(.link, at: 0, effectiveRange: nil))
    }
    func testRepeatedMalformedInlineKeepsSafeParagraphAndDropsUnsafeDestinations() {
        let malformed = "[危险](file:///tmp/perf-assessment-private) `未闭合"
        let rendered = MarkdownAttributedTextBuilder.renderState(
            content: "# 完整标题\n\n\(malformed)\n\n[安全](https://example.com/safe)\n\n\(malformed)",
            isMarkdown: true)
        XCTAssertEqual(rendered.status, .fallback)
        XCTAssertTrue(rendered.attributedString.string.contains("Markdown 格式异常，已按纯文本显示。"))
        XCTAssertFalse(rendered.attributedString.string.hasPrefix("#"))
        XCTAssertEqual(rendered.attributedString.string.components(separatedBy: "危险").count - 1, 2)
        XCTAssertFalse(rendered.attributedString.string.contains("file:///tmp/perf-assessment-private"))
        let safe = ReadOnlyAttributedTextView.sanitized(rendered.attributedString)
        let webRange = (safe.string as NSString).range(of: "安全")
        XCTAssertNotEqual(webRange.location, NSNotFound)
        if webRange.location != NSNotFound {
            XCTAssertEqual((safe.attribute(.link, at: webRange.location, effectiveRange: nil) as? URL)?.absoluteString,
                "https://example.com/safe")
        }
        safe.enumerateAttribute(.link, in: NSRange(location: 0, length: safe.length)) { value, _, _ in
            if let url = value as? URL { XCTAssertEqual(url.scheme, "https") }
        }
    }

    func testFreshRenderAndStandaloneBlocksKeepTheirOwnSafetyAssessment() {
        let web = MarkdownAttributedTextBuilder.renderState(
            content: "[同名](https://example.com/safe)", isMarkdown: true)
        XCTAssertEqual(web.status, .rendered)
        let unsafe = MarkdownAttributedTextBuilder.renderState(
            content: "[同名](file:///tmp/perf-assessment-private)", isMarkdown: true)
        XCTAssertEqual(unsafe.status, .sanitized)
        XCTAssertEqual(unsafe.attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines), "同名")
        let malformed = "[同名](file:///tmp/perf-assessment-private) `未闭合"
        let broken = MarkdownAttributedTextBuilder.renderState(content: malformed, isMarkdown: true)
        XCTAssertEqual(broken.status, .fallback)
        XCTAssertFalse(broken.attributedString.string.contains("file:///tmp/perf-assessment-private"))
        let standalone = MarkdownAttributedTextBuilder.attributed(from: [.paragraph(malformed)])
        XCTAssertTrue(standalone.string.contains("同名"))
        XCTAssertFalse(standalone.string.contains("file:///tmp/perf-assessment-private"))
        XCTAssertFalse(standalone.string.contains("]("))
        standalone.enumerateAttribute(.link, in: NSRange(location: 0, length: standalone.length)) { value, _, _ in
            XCTAssertNil(value)
        }
        let freshWeb = MarkdownAttributedTextBuilder.renderState(
            content: "[同名](https://example.com/safe)", isMarkdown: true)
        XCTAssertEqual(freshWeb, web)
    }

}
