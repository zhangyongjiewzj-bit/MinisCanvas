import XCTest
import AppKit
import MinisCore
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
        // 11/16 用户要求"链接都能点开"：本地 file 链接也保留为可点链接（打开前另有确认与可执行拦截）。
        XCTAssertEqual((safe.attribute(.link, at: fileRange.location, effectiveRange: nil) as? URL)?.scheme, "file")
        let custom = ReadOnlyAttributedTextView.sanitized(MarkdownAttributedTextBuilder.build(
            content: "[自定义](x-custom://open)", isMarkdown: true))
        let customRange = (custom.string as NSString).range(of: "自定义")
        XCTAssertNil(custom.attribute(.link, at: customRange.location, effectiveRange: nil))
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
        // 11/16：本地 file 链接改为可点，不再计为被清洗；自定义 scheme 仍被清洗。
        let local = MarkdownAttributedTextBuilder.renderState(
            content: "[同名](file:///tmp/perf-assessment-private)", isMarkdown: true)
        XCTAssertEqual(local.status, .rendered)
        XCTAssertEqual(local.attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines), "同名")
        let unsafe = MarkdownAttributedTextBuilder.renderState(
            content: "[同名](x-custom://perf-assessment-private)", isMarkdown: true)
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

    /// MC4-030：白字用户气泡里的引用、代码标签、列表标记、表格尾部提示不得再叠透明度，
    /// 否则在深色气泡底色（刚好 4.5:1）上低于项目文字对比度门槛。
    func testUserBubbleSecondaryTextStaysOpaqueWhiteMeetingContrast() {
        let source = "> 引用文字\n\n- 项目\n\n```swift\nlet a = 1\n```\n\n| A |\n| --- |\n"
            + (1...201).map { "| r\($0) |" }.joined(separator: "\n")
        let rendered = MarkdownAttributedTextBuilder.build(content: source, isMarkdown: true, baseColor: .white)
        let full = NSRange(location: 0, length: rendered.length)
        var checked = 0
        rendered.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
            let text = (rendered.string as NSString).substring(with: range)
            guard text.contains("引用文字") || text.contains("•") || text.contains("swift")
                || text.contains("还有 1 行") else { return }
            checked += 1
            XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001, "次级文字不应带透明度：\(text)")
            let bubble = ThemeContrast.fillMeetingWhiteText(ThemeColor(hex: 0xE08B68))
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.contrastRatio(ThemeColor(r: 1, g: 1, b: 1), bubble), 4.5 - 0.001)
        }
        XCTAssertGreaterThanOrEqual(checked, 4)
    }

    func testSecondaryColorStillDimsNonWhiteBase() {
        let dimmed = MarkdownAttributedTextBuilder.secondaryColor(.black, alpha: 0.7)
        XCTAssertEqual(dimmed.alphaComponent, 0.7, accuracy: 0.001)
    }

}
