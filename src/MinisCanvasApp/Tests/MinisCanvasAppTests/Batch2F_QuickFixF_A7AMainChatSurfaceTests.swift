import AppKit
import Foundation
import Testing

@testable import MinisCanvasApp

/// Batch2F 线 F（界面）RED：A7-A 主聊天四项观感。
/// 新符号（缺失即编译失败，属预期 RED）：
///  - `ChatReadingLayout.columnWidth(availableWidth:gutter:)`
///  - `ChatReadingLayout.columnLeadingInset(availableWidth:gutter:)`
///  - `ChatReadingLayout.composerColumnWidth(availableWidth:gutter:)`
///  - `ComposerSurfaceStyle.resolve(palette:isFocused:isDropTargeted:)`
///  - `SessionRowSurfaceStyle.resolve(isActive:isHovered:palette:)`
@Suite("Batch2F A7-A 主聊天：居中列 / 助手去底色 / 输入卡片 / 会话行")
struct Batch2FA7AMainChatSurfaceTests {

    // MARK: 1. M12 正文列居中，输入区与正文列同宽

    @Test("宽窗口下正文列在可用宽度内水平居中")
    func transcriptColumnIsCenteredInWideWindow() {
        let available: CGFloat = 1_400
        let width = ChatReadingLayout.columnWidth(availableWidth: available, gutter: 12)
        #expect(width == ChatReadingLayout.maxContentWidth)
        let leading = ChatReadingLayout.columnLeadingInset(availableWidth: available, gutter: 12)
        #expect(abs(leading - (available - width) / 2) < 0.5)
        // 左右留白相等：靠左排版（leading 恒为 0/gutter）在此失败。
        #expect(abs(leading - (available - width - leading)) < 0.5)
    }

    @Test("窄窗口下正文列占满可用宽度、无居中偏移")
    func transcriptColumnFillsNarrowWindow() {
        let width = ChatReadingLayout.columnWidth(availableWidth: 600, gutter: 12)
        #expect(width == 576)
        #expect(ChatReadingLayout.columnLeadingInset(availableWidth: 600, gutter: 12) == 12)
    }

    @Test("输入区与正文列同宽对齐（各宽度下上限一致）")
    func composerColumnMatchesTranscriptColumn() {
        for available: CGFloat in [600, 800, 1_000, 1_280, 1_600, 2_400] {
            let transcript = ChatReadingLayout.columnWidth(availableWidth: available, gutter: 12)
            let composer = ChatReadingLayout.composerColumnWidth(availableWidth: available, gutter: 12)
            #expect(composer == transcript, "available=\(available)")
            #expect(composer <= ChatReadingLayout.maxContentWidth)
        }
    }

    // MARK: 2. 助手正文去底色，用户消息保持区分

    private func backgroundAlpha(
        of role: ChatRole, palette: Aj38Palette?
    ) -> CGFloat {
        let message = ChatMessageUI(role: role, content: "正文一行")
        let attributed = ChatTranscriptFormatter.formattedMessage(
            message, baseSize: 13, redactor: nil, palette: palette
        )
        var alpha: CGFloat = 0
        attributed.enumerateAttribute(
            .paragraphStyle, in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let block = (value as? NSParagraphStyle)?.textBlocks.first,
                  let color = block.backgroundColor?.usingColorSpace(.sRGB) else { return }
            alpha = max(alpha, color.alphaComponent)
        }
        return alpha
    }

    @Test("助手消息文本块无底色（带主题色板）")
    func assistantHasNoBackgroundWithPalette() {
        #expect(backgroundAlpha(of: .assistant, palette: .light) == 0)
        #expect(backgroundAlpha(of: .assistant, palette: .dark) == 0)
    }

    @Test("助手消息文本块无底色（系统色回退）")
    func assistantHasNoBackgroundWithoutPalette() {
        #expect(backgroundAlpha(of: .assistant, palette: nil) == 0)
    }

    @Test("用户消息仍有可见底色，与助手区分")
    func userKeepsVisibleBackground() {
        let user = backgroundAlpha(of: .user, palette: .light)
        #expect(user > 0.05 && user <= 0.25)
        #expect(user > backgroundAlpha(of: .assistant, palette: .light))
        #expect(backgroundAlpha(of: .user, palette: nil) > 0.05)
    }

    // MARK: 3. 输入框常态为有可见边界的卡片

    @Test("输入卡片常态有 1pt 描边，且填充不同于外层分区底色")
    func composerRestingCardHasBorderAndRaisedFill() {
        for palette in [Aj38Palette.light, Aj38Palette.dark] {
            let style = ComposerSurfaceStyle.resolve(
                palette: palette, isFocused: false, isDropTargeted: false)
            #expect(style.strokeWidth == 1)
            #expect(style.stroke == palette.borderSubtle)
            #expect(style.fill != palette.backgroundSecondary)
        }
    }

    @Test("聚焦用 accent 描边，拖放沿用 1.5pt accent 描边")
    func composerFocusAndDropStrokes() {
        let palette = Aj38Palette.light
        let focused = ComposerSurfaceStyle.resolve(
            palette: palette, isFocused: true, isDropTargeted: false)
        #expect(focused.stroke == palette.accent)
        #expect(focused.strokeWidth >= 1)
        let drop = ComposerSurfaceStyle.resolve(
            palette: palette, isFocused: false, isDropTargeted: true)
        #expect(drop.stroke == palette.accent)
        #expect(drop.strokeWidth == 1.5)
    }

    // MARK: 4. 会话行：未选中无底色，悬停淡底，选中高亮

    @Test("未选中且未悬停：无底色、无描边")
    func idleSessionRowHasNoFill() {
        let style = SessionRowSurfaceStyle.resolve(
            isActive: false, isHovered: false, palette: .light)
        #expect(style.fillOpacity == 0)
        #expect(style.edgeOpacity == 0)
    }

    @Test("悬停：淡底（0 < 不透明度 <= 8%），无选中描边")
    func hoveredSessionRowHasFaintFill() {
        let style = SessionRowSurfaceStyle.resolve(
            isActive: false, isHovered: true, palette: .light)
        #expect(style.fillOpacity > 0 && style.fillOpacity <= 0.08)
        #expect(style.edgeOpacity == 0)
    }

    @Test("选中保持 accent 高亮与描边，悬停不叠加第二层高亮")
    func activeSessionRowKeepsHighlight() {
        let palette = Aj38Palette.light
        let active = SessionRowSurfaceStyle.resolve(
            isActive: true, isHovered: false, palette: palette)
        #expect(active.fillColor == palette.accent)
        #expect(active.fillOpacity >= 0.14)
        #expect(active.edgeOpacity > 0)
        let activeHover = SessionRowSurfaceStyle.resolve(
            isActive: true, isHovered: true, palette: palette)
        #expect(activeHover == active)
    }
}
