import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// UF04 native consumer fixtures for message role/content alignment.
///
/// These tests keep role placement outside the shared renderer: the renderer
/// owns the semantic leading edge inside a role container, while the native
/// hosts verify that final NSTextView content and streaming SwiftUI content
/// both receive real geometry at the supported widths and type sizes.
@Suite("UF04 message content alignment", .serialized)
@MainActor
struct ChatMessageContentAlignmentTests {
    private static let widths: [CGFloat] = [600, 800, 1000, 1280, 1600]
    private static let fontSizes: [CGFloat] = [12, 13, 16, 20]
    private static let fixtureText = """
    # 消息正文 / message body

    中文与 English mixed text should remain readable inside the role container.

    - 第一项 list body
    - Second list item with a long line that wraps inside the available width.

    ```swift
    let value = 1
    print(value)
    ```
    """

    @Test("final attributed body normalizes every semantic run to leading")
    func finalAttributedBodyUsesLeadingParagraphs() {
        for baseSize in Self.fontSizes {
            let state = MarkdownAttributedTextBuilder.renderState(
                content: Self.fixtureText,
                isMarkdown: true,
                baseSize: baseSize
            )
            #expect(!state.isFallback)
            #expect(state.attributedString.string.contains("第一项 list body"))
            #expect(state.attributedString.string.contains("let value = 1"))

            let fullRange = NSRange(location: 0, length: state.attributedString.length)
            var paragraphRunCount = 0
            var allRunsAreLeading = true
            state.attributedString.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
                guard range.length > 0 else { return }
                paragraphRunCount += 1
                guard let style = value as? NSParagraphStyle else {
                    allRunsAreLeading = false
                    return
                }
                if style.alignment != MessageContentAlignment.leading {
                    allRunsAreLeading = false
                }
            }
            #expect(paragraphRunCount > 0)
            #expect(allRunsAreLeading)

            let codeRange = (state.attributedString.string as NSString).range(of: "let value = 1")
            guard codeRange.location != NSNotFound else {
                Issue.record("code fixture was lost from final attributed content")
                continue
            }
            let style = state.attributedString.attribute(.paragraphStyle, at: codeRange.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.textBlocks.count == 1)
            let codeBlock = style?.textBlocks.first
            #expect(codeBlock?.backgroundColor != nil)
            // 代码卡片：文字与卡片边缘的距离走段落缩进，不用块内边距（AppKit 只给块内首段加内边距会让首行错位）。
            #expect(codeBlock is CodeSurfaceTextBlock)
            #expect(codeBlock?.width(for: .padding, edge: .minX) == 0)
            #expect(style?.headIndent == CodeSurfaceTextBlock.textInset)
            #expect(style?.firstLineHeadIndent == CodeSurfaceTextBlock.textInset)

            let listRange = (state.attributedString.string as NSString).range(of: "第一项 list body")
            if listRange.location != NSNotFound {
                let listStyle = state.attributedString.attribute(.paragraphStyle, at: listRange.location, effectiveRange: nil) as? NSParagraphStyle
                #expect(listStyle?.textBlocks.isEmpty == true)
            }
            #expect(state.attributedString.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) == nil)
        }
    }

    @Test func nativeFencedCodeFillCoversLinesAndInterlineWhitespace() throws {
        let body = "Outside prose\n\n```swift\nlet a = 1\nlet b = 2\nlet c = 3\n```"
        let transcript = ChatTranscriptFormatter.attributedString([ChatMessageUI(role: .assistant, content: body)])
        let fixture = NativeMessageHost(
            root: AnyView(ReadOnlyAttributedTextView(attributedString: transcript)
                .background(Color.white).environment(\.colorScheme, .light)
                .frame(width: 600, height: 360, alignment: .leading)),
            width: 600, height: 360
        )
        defer { fixture.close() }
        fixture.layout()
        let text = try #require(Self.findTextView(in: fixture.hostView))
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        let origin = text.textContainerOrigin
        let markers = ["Outside prose", "let a = 1", "let b = 2", "let c = 3"]
        let lines = try markers.map { marker in
            let range = (text.string as NSString).range(of: marker)
            try #require(range.location != NSNotFound)
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let ink = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            return (line.offsetBy(dx: origin.x, dy: origin.y), ink.maxX + origin.x)
        }
        let left = try #require(lines.map { $0.1 }.max())
        let right = try #require(lines.map { $0.0.maxX }.min())
        try #require(right - left > 16)
        let sampleX = (left + right) / 2
        let host = fixture.hostView
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)

        func pixel(_ y: CGFloat) throws -> [CGFloat] {
            let point = NSPoint(x: sampleX, y: y)
            try #require(text.visibleRect.contains(point))
            let converted = host.convert(point, from: text)
            let bounds = host.bounds
            try #require(bounds.contains(converted))
            let x = Int((converted.x - bounds.minX) * CGFloat(bitmap.pixelsWide) / bounds.width)
            let row = host.isFlipped ? converted.y - bounds.minY : bounds.maxY - converted.y
            let y = Int(row * CGFloat(bitmap.pixelsHigh) / bounds.height)
            try #require(x >= 0 && x < bitmap.pixelsWide && y >= 0 && y < bitmap.pixelsHigh)
            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            return [color.redComponent, color.greenComponent, color.blueComponent]
        }

        let outside = try pixel(lines[0].0.midY)
        let code = try pixel(lines[1].0.midY)
        #expect(code != outside)
        for index in 1...3 {
            #expect(try pixel(lines[index].0.midY) == code)
        }
        for index in 1...2 {
            let edge = (lines[index].0.maxY + lines[index + 1].0.minY) / 2
            #expect(try pixel(edge) == code)
        }
    }

    @Test("native final and streaming consumers preserve geometry and AX text")
    func nativeFinalAndStreamingGeometry() {
        for width in Self.widths {
            for baseSize in Self.fontSizes {
                let finalState = MarkdownAttributedTextBuilder.renderState(
                    content: Self.fixtureText,
                    isMarkdown: true,
                    baseSize: baseSize
                )
                let finalFixture = NativeMessageHost(
                    root: AnyView(
                        ReadOnlyAttributedTextView(attributedString: finalState.attributedString)
                            .frame(width: width, height: 360, alignment: .leading)
                    ),
                    width: width,
                    height: 360
                )
                defer { finalFixture.close() }
                finalFixture.layout()

                guard let textView = Self.findTextView(in: finalFixture.hostView) else {
                    Issue.record("final message did not produce a native NSTextView")
                    continue
                }
                #expect(textView.textStorage?.length == finalState.attributedString.length)
                #expect(textView.frame.width > 0)
                #expect((textView as NSAccessibilityProtocol).accessibilityRole() != nil)
                var nativeRunsAreLeading = true
                let nativeText = textView.attributedString()
                let nativeRange = NSRange(location: 0, length: nativeText.length)
                nativeText.enumerateAttribute(.paragraphStyle, in: nativeRange) { value, range, _ in
                    guard range.length > 0,
                          let style = value as? NSParagraphStyle,
                          style.alignment == MessageContentAlignment.leading else {
                        nativeRunsAreLeading = false
                        return
                    }
                }
                #expect(nativeRunsAreLeading)

                let streamingFixture = NativeMessageHost(
                    root: AnyView(
                        MarkdownTextView(text: Self.fixtureText, baseSize: baseSize)
                            .frame(width: width, height: 360, alignment: .leading)
                    ),
                    width: width,
                    height: 360
                )
                defer { streamingFixture.close() }
                streamingFixture.layout()
                #expect(streamingFixture.hostView.frame.width > 0)
                #expect(streamingFixture.hostView.frame.height > 0)
                #expect(streamingFixture.hostView.fittingSize.height > 0)
            }
        }
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for child in view.subviews {
            if let textView = findTextView(in: child) {
                return textView
            }
        }
        return nil
    }
}

@MainActor
private final class NativeMessageHost {
    let window: NSWindow
    let controller: NSHostingController<AnyView>

    init(root: AnyView, width: CGFloat, height: CGFloat) {
        controller = NSHostingController(rootView: root)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        window.orderFrontRegardless()
    }

    var hostView: NSView { controller.view }

    func layout() {
        window.layoutIfNeeded()
        hostView.frame = window.contentView?.bounds ?? .zero
        hostView.layoutSubtreeIfNeeded()
        hostView.display()
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }
}

/// 思考过程块：默认折叠、不进入正文；展开后才出现全文。
@Suite("思考过程显示")
@MainActor
struct ChatThinkingDisplayTests {
    private func assistant(thinking: String?, seconds: Double? = nil, content: String = "答案") -> ChatMessageUI {
        var message = ChatMessageUI(role: .assistant, content: content)
        message.thinkingText = thinking
        message.thinkingSeconds = seconds
        return message
    }

    @Test func titleShowsStreamingSecondsOrCharacterCount() {
        #expect(ChatTranscriptFormatter.thinkingTitle(thinking: "abc", seconds: nil, isThinkingNow: true) == "正在思考…")
        #expect(ChatTranscriptFormatter.thinkingTitle(thinking: "abc", seconds: 4.4, isThinkingNow: false) == "思考了 4 秒")
        #expect(ChatTranscriptFormatter.thinkingTitle(thinking: "想想看", seconds: nil, isThinkingNow: false) == "思考过程 · 3 字")
    }

    @Test func thinkingIsCollapsedByDefaultAndExpandsOnDemand() {
        let message = assistant(thinking: "内部推理文本")
        let collapsed = ChatTranscriptFormatter.formattedMessage(message, baseSize: 13, redactor: nil).string
        #expect(collapsed.contains("▸ 思考过程"))
        #expect(!collapsed.contains("内部推理文本"))
        let expandedMessage = ChatTranscriptFormatter.thinkingDisplayMessage(message, expanded: true)
        let expanded = ChatTranscriptFormatter.formattedMessage(expandedMessage, baseSize: 13, redactor: nil).string
        #expect(expanded.contains("内部推理文本"))
    }

    @Test func thinkingNeverEntersCopiedOrExportedText() {
        let message = assistant(thinking: "内部推理文本")
        #expect(!ChatTranscriptFormatter.plainText([message]).contains("内部推理文本"))
    }
}
