import AppKit
import MinisCore

/// A display-only projection. Persisted/provider/copy/export source strings do
/// not enter this representation. Every external attachment is sanitized first.
enum ChatTranscriptStatusIconProjection {
    private static let originalKey = NSAttributedString.Key("MinisCanvas.statusIconOriginal")
    private static let entries: [(emoji: String, icon: MinisIcon, label: String)] = [
        ("⏳", .spinner, "生成中"), ("⏹️", .stop, "已停止"), ("⏹", .stop, "已停止"),
        ("⚠️", .warning, "警告"), ("⚠", .warning, "警告"),
        ("❌", .close, "失败"), ("✅", .success, "成功"), ("🪄", .activity, "上下文整理")
    ]

    @MainActor static func preload() async {
        for icon in [MinisIcon.spinner, .stop, .warning, .close, .success, .activity] {
            guard !Task.isCancelled else { return }
            _ = await MinisIconLayerCache.shared.layers(for: icon)
        }
    }

    static var resourceRevision: UInt64 { MinisIconLayerCache.nativeBytes.snapshot().revision }

    /// Match only the closed status catalog as complete extended graphemes.
    /// ZWJ, modifiers, flags and keycap sequences are never split for a match.
    private static func catalogEntry(for character: Character) -> (emoji: String, icon: MinisIcon, label: String)? {
        let value = String(character)
        guard !value.unicodeScalars.contains(where: { $0.value == 0x200D }) else { return nil }
        return entries.first { $0.emoji.unicodeScalars.elementsEqual(value.unicodeScalars) }
    }

    static func hasStatus(inMarkdown text: String) -> Bool {
        func containsStatus(_ value: String) -> Bool { value.contains { catalogEntry(for: $0) != nil } }
        return MinisCore.MarkdownParser.parse(text).contains { block in
            switch block {
            case .paragraph(let value), .blockquote(let value), .heading(_, let value):
                return containsStatus(value)
            case .list(let items, _):
                return items.contains(where: containsStatus)
            case .nestedList(let items):
                return items.contains { containsStatus($0.text) }
            case .codeBlock, .table, .divider:
                return false
            }
        }
    }

    static func prepare(_ source: NSAttributedString, palette: Aj38Palette? = nil) -> NSAttributedString {
        let safe = ReadOnlyAttributedTextView.sanitized(source)
        let result = NSMutableAttributedString(attributedString: safe)
        let bytes = MinisIconLayerCache.nativeBytes.snapshot().values
        var replacements: [(NSRange, NSAttributedString)] = []
        for match in matches(safe) {
            let attributes = safe.attributes(at: match.range.location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont
            guard let layers = bytes[match.icon],
                  let image = image(layers: layers, icon: match.icon, palette: palette,
                                    size: max(12, font?.pointSize ?? 13)) else { continue }
            image.accessibilityDescription = match.label
            let attachment = MinisStatusIconAttachment(original: match.original, label: match.label, image: image)
            attachment.bounds = NSRect(x: 0, y: font?.descender ?? -2,
                                       width: image.size.width, height: image.size.height)
            let projected = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            var copied = attributes
            copied[.attachment] = attachment
            copied[originalKey] = match.original
            projected.setAttributes(copied, range: NSRange(location: 0, length: projected.length))
            replacements.append((match.range, projected))
        }
        for (range, value) in replacements.reversed() { result.replaceCharacters(in: range, with: value) }
        return result
    }

    static func hasStatus(in source: NSAttributedString) -> Bool { !matches(source).isEmpty }

    static func containsIcons(_ source: NSAttributedString) -> Bool {
        var found = false
        source.enumerateAttribute(.attachment, in: NSRange(location: 0, length: source.length)) { value, _, stop in
            if value is MinisStatusIconAttachment { found = true; stop.pointee = true }
        }
        return found
    }

    static func copyText(_ source: NSAttributedString) -> String {
        textProjection(source, accessibility: false)
    }

    static func accessibilityText(_ source: NSAttributedString) -> String {
        let result = NSMutableAttributedString(attributedString: source)
        for match in matches(source).reversed() {
            let tail = (source.string as NSString).substring(from: NSMaxRange(match.range))
            let leadingSpaces = tail.prefix { $0 == " " || $0 == "\t" }
            let alreadyNamed = tail.dropFirst(leadingSpaces.count).hasPrefix(match.label)
            let range = NSRange(location: match.range.location,
                                length: match.range.length + (String(leadingSpaces) as NSString).length)
            result.replaceCharacters(in: range, with: alreadyNamed ? "" : match.label + "，")
        }
        return textProjection(result, accessibility: true)
    }

    private static func matches(_ source: NSAttributedString)
        -> [(range: NSRange, icon: MinisIcon, label: String, original: String)] {
        let string = source.string
        // 目录里每个状态符号的首个 Unicode 标量；与 `entries` 保持一致。
        // 先按标量快速扫描：没有候选就不做逐字符（字素簇）切分，这是流式长回复里
        // 每个片段都要走的路径；有候选时只对候选所在的行逐字符匹配（字素簇不会跨行）。
        func isCandidate(_ value: UInt32) -> Bool {
            guard value >= 0x23F3 else { return false }
            switch value {
            case 0x23F3, 0x23F9, 0x26A0, 0x274C, 0x2705, 0x1FA84: return true
            default: return false
            }
        }
        var candidateLines: [NSRange] = []
        let text = string as NSString
        var scanned = 0
        var scalarPosition = 0
        for scalar in string.unicodeScalars {
            if scalarPosition >= scanned, isCandidate(scalar.value) {
                let line = text.lineRange(for: NSRange(location: scalarPosition, length: 0))
                candidateLines.append(line)
                scanned = NSMaxRange(line)
            }
            scalarPosition += scalar.value > 0xFFFF ? 2 : 1
        }
        var found: [(range: NSRange, icon: MinisIcon, label: String, original: String)] = []
        for line in candidateLines {
            var position = line.location
            for character in text.substring(with: line) {
                let original = String(character)
                let length = original.utf16.count
                defer { position += length }
                guard let entry = catalogEntry(for: character), position < source.length else { continue }
                // A joiner at the next boundary is also protected even if a future
                // Unicode segmentation implementation treats it separately.
                if position + length < text.length, text.character(at: position + length) == 0x200D { continue }
                let attributes = source.attributes(at: position, effectiveRange: nil)
                let font = attributes[.font] as? NSFont
                let style = attributes[.paragraphStyle] as? NSParagraphStyle
                let isCode = font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
                    || font?.isFixedPitch == true
                    || attributes[.backgroundColor] != nil
                let isTable = style?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true
                guard !isCode && !isTable else { continue }
                found.append((NSRange(location: position, length: length), entry.icon, entry.label, original))
            }
        }
        return found
    }

    private static func textProjection(_ source: NSAttributedString, accessibility: Bool) -> String {
        let result = NSMutableString(string: "")
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? MinisStatusIconAttachment {
                if accessibility {
                    let remaining = (source.string as NSString).substring(from: NSMaxRange(range))
                        .trimmingCharacters(in: .whitespaces)
                    if !remaining.hasPrefix(attachment.label) { result.append(attachment.label + "，") }
                } else {
                    // Only the closed private attachment owns this attribute.
                    // A foreign attributed string cannot opt in with a string key.
                    result.append(attachment.original)
                }
            } else {
                result.append((source.string as NSString).substring(with: range)
                    .replacingOccurrences(of: "\u{FFFC}", with: ""))
            }
        }
        return result as String
    }

    private static func image(layers: MinisIconLayerBytes, icon: MinisIcon, palette: Aj38Palette?, size: CGFloat) -> NSImage? {
        guard let primary = NSImage(data: layers.primary), let secondary = NSImage(data: layers.secondary) else { return nil }
        let color: NSColor
        switch icon {
        case .warning: color = palette.map { nsColor($0.statusWarning) } ?? .systemOrange
        case .close: color = palette.map { nsColor($0.danger) } ?? .systemRed
        case .success: color = palette.map { nsColor($0.success) } ?? .systemGreen
        default: color = palette.map { nsColor($0.textSecondary) } ?? .secondaryLabelColor
        }
        let dimensions = NSSize(width: size, height: size)
        func tinted(_ layer: NSImage, alpha: CGFloat) -> NSImage {
            NSImage(size: dimensions, flipped: false) { rect in
                layer.draw(in: rect)
                color.withAlphaComponent(alpha).setFill()
                rect.fill(using: .sourceIn)
                return true
            }
        }
        let bottom = tinted(secondary, alpha: CGFloat(MinisIconTokens.secondaryOpacity))
        let top = tinted(primary, alpha: 1)
        return NSImage(size: dimensions, flipped: false) { rect in
            bottom.draw(in: rect)
            top.draw(in: rect)
            return true
        }
    }

    private static func nsColor(_ color: ThemeColor) -> NSColor {
        NSColor(srgbRed: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: 1)
    }
}

/// No decoder/file wrapper/URL can create a trusted display icon.
private final class MinisStatusIconAttachment: NSTextAttachment {
    let original: String
    let label: String
    init(original: String, label: String, image: NSImage) {
        self.original = original
        self.label = label
        super.init(data: nil, ofType: nil)
        self.image = image
    }
    required init?(coder: NSCoder) { return nil }
}

/// Preserve the user's original characters across selection, Select All,
/// Services and dragging. Icon-bearing selections publish plain text only.
final class ChatTranscriptNativeTextView: NSTextView {
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let storage = textStorage, range.location != NSNotFound,
              range.location >= 0, range.length >= 0,
              range.location <= storage.length,
              range.length <= storage.length - range.location else { return nil }
        // AX attributed strings use AX-specific keys, not the display paragraph
        // and table objects. Project ordinary runs directly, avoiding AppKit's
        // expensive rich-table attribute conversion without changing storage.
        let result = NSMutableAttributedString()
        let source = storage.string as NSString
        let end = range.location + range.length
        var cursor = range.location
        while cursor < end {
            var effective = NSRange()
            let attributes = storage.attributes(at: cursor, effectiveRange: &effective)
            let run = NSIntersectionRange(effective, NSRange(location: cursor, length: end - cursor))
            let runFont = (attributes[.font] as? NSFont) ?? font
            let hasNativeSemantics = attributes[TranscriptExternalLink.destination] != nil
                || attributes[.link] != nil || attributes[.attachment] != nil
                || ((attributes[.baselineOffset] as? NSNumber)?.doubleValue ?? 0) != 0
                || attributes[.superscript] != nil || attributes[.shadow] != nil
            if hasNativeSemantics || runFont == nil {
                // In particular, AXLink is a corresponding native element, not
                // a URL. Preserve the existing delegate/session confirmation and
                // native attachment/offset semantics for exactly this run.
                guard let native = super.accessibilityAttributedString(for: run) else { return nil }
                result.append(native)
            } else if let runFont {
                var ax: [NSAttributedString.Key: Any] = [:]
                var fontKeys: [String: Any] = [
                    NSAccessibility.FontAttributeKey.fontName.rawValue: runFont.fontName,
                    NSAccessibility.FontAttributeKey.fontSize.rawValue: NSNumber(value: Double(runFont.pointSize))
                ]
                if let family = runFont.familyName {
                    fontKeys[NSAccessibility.FontAttributeKey.fontFamily.rawValue] = family
                }
                if let name = runFont.displayName {
                    fontKeys[NSAccessibility.FontAttributeKey.visibleName.rawValue] = name
                }
                ax[.accessibilityFont] = fontKeys
                if #available(macOS 26.0, *) {
                    let traits = NSFontManager.shared.traits(of: runFont)
                    ax[.accessibilityFontBoldAttribute] = NSNumber(value: traits.contains(.boldFontMask))
                    ax[.accessibilityFontItalicAttribute] = NSNumber(value: traits.contains(.italicFontMask))
                }
                if let color = (attributes[.foregroundColor] as? NSColor) ?? textColor {
                    ax[.accessibilityForegroundColor] = color.cgColor
                }
                if let color = attributes[.backgroundColor] as? NSColor {
                    ax[.accessibilityBackgroundColor] = color.cgColor
                }
                if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
                    ax[.accessibilityAlignment] = NSNumber(value: style.alignment.rawValue)
                }
                if let underline = attributes[.underlineStyle] as? NSNumber {
                    ax[.accessibilityUnderline] = underline
                }
                if let strike = attributes[.strikethroughStyle] as? NSNumber {
                    ax[.accessibilityStrikethrough] = NSNumber(value: strike.intValue != 0)
                }
                if let color = attributes[.underlineColor] as? NSColor {
                    ax[.accessibilityUnderlineColor] = color.cgColor
                }
                if let color = attributes[.strikethroughColor] as? NSColor {
                    ax[.accessibilityStrikethroughColor] = color.cgColor
                }
                result.append(NSAttributedString(string: source.substring(with: run), attributes: ax))
            }
            cursor = NSMaxRange(run)
        }
        return result
    }

    private struct CodeCardSpan {
        let block: CodeSurfaceTextBlock
        let minX: CGFloat
        let maxX: CGFloat
        var minY: CGFloat
        var maxY: CGFloat
        let firstCharacter: Int
        var lastCharacter: Int
    }

    private struct BubbleSpan {
        let block: UserBubbleTextBlock
        var minX: CGFloat
        var maxX: CGFloat
        var minY: CGFloat
        var maxY: CGFloat
        var firstCharacter: Int
        var lastCharacter: Int
        /// 可见行里文字实际占到的最左位置（文字靠右排，气泡按它收窄贴合文字）。
        var textMinX: CGFloat
    }

    private static func sameBubble(_ block: UserBubbleTextBlock, at index: Int,
                                   in storage: NSTextStorage) -> Bool {
        guard index >= 0, index < storage.length,
              let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        else { return false }
        return style.textBlocks.first === block
    }

    /// 整个用户气泡（不论哪几行在本次脏区里）各行文字的最左边（容器坐标）。
    /// 只量这一块的行，O(气泡行数)。
    static func bubbleTextMinX(_ block: UserBubbleTextBlock, at index: Int, storage: NSTextStorage,
                               manager: NSLayoutManager, container: NSTextContainer) -> CGFloat? {
        guard index >= 0, index < storage.length else { return nil }
        let blockRange = storage.range(of: block, at: index)
        guard blockRange.length > 0 else { return nil }
        let glyphs = manager.glyphRange(forCharacterRange: blockRange, actualCharacterRange: nil)
        var minX: CGFloat?
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
            guard lineGlyphs.length > 0 else { return }
            let x = manager.boundingRect(forGlyphRange: lineGlyphs, in: container).minX
            minX = min(minX ?? x, x)
        }
        return minX
    }

    private static func sameCodeSurface(_ block: CodeSurfaceTextBlock, at index: Int,
                                        in storage: NSTextStorage) -> Bool {
        guard index >= 0, index < storage.length,
              let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        else { return false }
        return style.textBlocks.last === block
    }

    override func draw(_ dirtyRect: NSRect) {
        // Paint the existing role block surfaces before AppKit paints Markdown
        // run backgrounds, selection and glyphs. Query only the dirty viewport;
        // never force layout or enumerate attributes over the whole transcript.
        let visibleDirty = dirtyRect.intersection(visibleRect)
        if !visibleDirty.isEmpty, let storage = textStorage,
           let manager = layoutManager, let container = textContainer {
            let origin = textContainerOrigin
            let containerRect = visibleDirty.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = manager.glyphRange(forBoundingRect: containerRect, in: container)
            // 代码卡片按块收集可见行，枚举完再一次画圆角卡片（只看脏区内的行，O(可见行)）。
            var cards: [ObjectIdentifier: CodeCardSpan] = [:]
            var cardOrder: [ObjectIdentifier] = []
            var bubbles: [ObjectIdentifier: BubbleSpan] = [:]
            var bubbleOrder: [ObjectIdentifier] = []
            manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, _ in
                guard lineGlyphs.length > 0 else { return }
                let character = manager.characterIndexForGlyph(at: lineGlyphs.location)
                guard character < storage.length,
                      let style = storage.attribute(.paragraphStyle, at: character,
                          effectiveRange: nil) as? NSParagraphStyle,
                      !style.textBlocks.contains(where: { $0 is NSTextTableBlock }) else { return }
                let blocks = style.textBlocks
                let codeSurface = blocks.last as? CodeSurfaceTextBlock
                let surface = line.offsetBy(dx: origin.x, dy: origin.y).intersection(visibleDirty)
                if let bubble = blocks.first as? UserBubbleTextBlock {
                    // 用户气泡：按块收集可见行，枚举完再画圆角底色（O(可见行)）。
                    let id = ObjectIdentifier(bubble)
                    let lineRect = line.offsetBy(dx: origin.x, dy: origin.y)
                    let lineEnd = NSMaxRange(manager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil))
                    // 只量本行字形的包围盒（O(本行)），不触发全文排版。
                    let textMinX = manager.boundingRect(forGlyphRange: lineGlyphs, in: container).minX + origin.x
                    if var span = bubbles[id] {
                        span.minX = min(span.minX, lineRect.minX)
                        span.maxX = max(span.maxX, lineRect.maxX)
                        span.minY = min(span.minY, lineRect.minY)
                        span.maxY = max(span.maxY, lineRect.maxY)
                        span.firstCharacter = min(span.firstCharacter, character)
                        span.lastCharacter = max(span.lastCharacter, lineEnd)
                        span.textMinX = min(span.textMinX, textMinX)
                        bubbles[id] = span
                    } else {
                        bubbles[id] = BubbleSpan(block: bubble, minX: lineRect.minX, maxX: lineRect.maxX,
                                                 minY: lineRect.minY, maxY: lineRect.maxY,
                                                 firstCharacter: character, lastCharacter: lineEnd,
                                                 textMinX: textMinX)
                        bubbleOrder.append(id)
                    }
                } else if let role = blocks.first, role !== codeSurface, let fill = role.backgroundColor, !surface.isEmpty {
                    fill.setFill()
                    surface.fill()
                }
                if let codeSurface {
                    let id = ObjectIdentifier(codeSurface)
                    let paragraph = storage.mutableString.paragraphRange(
                        for: NSRange(location: character, length: 0))
                    let lineRect = line.offsetBy(dx: origin.x, dy: origin.y)
                    // 卡片上沿 = 首段段前间距之下再留出内边距；下沿同理。
                    let isParagraphStart = character == paragraph.location
                    let isParagraphEnd = NSMaxRange(manager.characterRange(
                        forGlyphRange: lineGlyphs, actualGlyphRange: nil)) >= NSMaxRange(paragraph)
                    let top = lineRect.minY + (isParagraphStart
                        ? max(0, style.paragraphSpacingBefore - CodeSurfaceTextBlock.verticalPadding) : 0)
                    let bottom = lineRect.maxY - (isParagraphEnd
                        ? max(0, style.paragraphSpacing - CodeSurfaceTextBlock.verticalPadding) : 0)
                    let minX = origin.x + max(0, style.headIndent - CodeSurfaceTextBlock.textInset)
                    let maxX = origin.x + container.size.width
                        + min(0, style.tailIndent + CodeSurfaceTextBlock.textInset)
                    if var span = cards[id] {
                        span.minY = min(span.minY, top)
                        span.maxY = max(span.maxY, bottom)
                        span.lastCharacter = max(span.lastCharacter, NSMaxRange(paragraph))
                        cards[id] = span
                    } else {
                        cards[id] = CodeCardSpan(block: codeSurface, minX: minX, maxX: maxX,
                                                 minY: top, maxY: bottom,
                                                 firstCharacter: paragraph.location,
                                                 lastCharacter: NSMaxRange(paragraph))
                        cardOrder.append(id)
                    }
                } else if blocks.count == 2, let codeFill = blocks.last?.backgroundColor, !surface.isEmpty {
                    // Ordinary nested blocks without the card class keep the flat fill.
                    codeFill.setFill()
                    surface.fill()
                }
            }
            for id in bubbleOrder {
                guard var span = bubbles[id], let fill = span.block.backgroundColor else { continue }
                // 局部重画只枚举脏区里的行；气泡左边缘必须按整块所有行量，否则只重画到
                // 较短的一行时，长行露在底色外（11/19 旅途"色块"）。只量本气泡的行。
                if let blockMinX = Self.bubbleTextMinX(span.block, at: span.firstCharacter,
                                                       storage: storage, manager: manager, container: container) {
                    span.textMinX = min(span.textMinX, blockMinX + origin.x)
                }
                // 行矩形 = 气泡内容区；文字已缩进一个阅读列 gutter，底色向外只伸出 textInset。
                let overhang = max(0, ChatReadingLayout.horizontalInset - UserBubbleTextBlock.textInset)
                let trim = UserBubbleTextBlock.verticalTrim
                // 气泡靠右：左边缘贴着文字（再留 textInset），一定盖住文字，且不窄于最小宽度。
                // 最大宽度由文字换行内缩（UserBubbleTextBlock.wrapInset）决定，这里不再截断。
                let right = span.maxX - overhang
                let columnLeft = span.minX + overhang
                let fittedLeft = span.textMinX - UserBubbleTextBlock.textInset
                let narrowestLeft = right - UserBubbleTextBlock.minimumWidth
                let left = max(columnLeft, min(fittedLeft, narrowestLeft))
                var rect = NSRect(x: left, y: span.minY + trim,
                                  width: max(0, right - left),
                                  height: max(0, span.maxY - span.minY - trim * 2))
                // 气泡延续到脏区外时，把那一侧推出可见区，不在中途画出圆角。
                if span.firstCharacter > 0, Self.sameBubble(span.block, at: span.firstCharacter - 1, in: storage) {
                    rect.origin.y -= 2000
                    rect.size.height += 2000
                }
                if span.lastCharacter < storage.length, Self.sameBubble(span.block, at: span.lastCharacter, in: storage) {
                    rect.size.height += 2000
                }
                guard rect.width > 0, rect.height > 0 else { continue }
                fill.setFill()
                NSBezierPath(roundedRect: rect, xRadius: UserBubbleTextBlock.cornerRadius,
                             yRadius: UserBubbleTextBlock.cornerRadius).fill()
            }
            for id in cardOrder {
                guard let span = cards[id] else { continue }
                var rect = NSRect(x: span.minX, y: span.minY,
                                  width: max(0, span.maxX - span.minX), height: max(0, span.maxY - span.minY))
                // 卡片延续到脏区外时，把那一侧推出可见区，不在中途画出圆角。
                if span.firstCharacter > 0, Self.sameCodeSurface(span.block, at: span.firstCharacter - 1, in: storage) {
                    rect.origin.y -= 2000
                    rect.size.height += 2000
                }
                if span.lastCharacter < storage.length, Self.sameCodeSurface(span.block, at: span.lastCharacter, in: storage) {
                    rect.size.height += 2000
                }
                guard rect.width > 0, rect.height > 0 else { continue }
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: CodeSurfaceTextBlock.cornerRadius,
                                        yRadius: CodeSurfaceTextBlock.cornerRadius)
                if let fill = span.block.backgroundColor {
                    fill.setFill()
                    path.fill()
                }
                if let border = span.block.borderColor(for: .minX) {
                    border.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
        super.draw(dirtyRect)
    }

    /// Keep the factory-owned scroll configuration and text defaults. Only the
    /// document view's pasteboard behavior changes; its text engine is identical.
    static func makeScrollable() -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let original = scrollView.documentView as? NSTextView else { return scrollView }
        let replacement = ChatTranscriptNativeTextView(usingTextLayoutManager: original.textLayoutManager != nil)
        replacement.frame = original.frame
        replacement.autoresizingMask = original.autoresizingMask
        replacement.isHorizontallyResizable = original.isHorizontallyResizable
        replacement.isVerticallyResizable = original.isVerticallyResizable
        replacement.minSize = original.minSize
        replacement.maxSize = original.maxSize
        replacement.textContainerInset = original.textContainerInset
        if let source = original.textContainer, let target = replacement.textContainer {
            target.containerSize = source.containerSize
            target.widthTracksTextView = source.widthTracksTextView
            target.heightTracksTextView = source.heightTracksTextView
            target.lineFragmentPadding = source.lineFragmentPadding
            target.lineBreakMode = source.lineBreakMode
        }
        scrollView.documentView = replacement
        return scrollView
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        selectedProjectionContainsIcons ? [.string] : super.writablePasteboardTypes
    }

    private var selectedProjectionContainsIcons: Bool {
        guard let storage = textStorage else { return false }
        return selectedRanges.contains { value in
            let range = value.rangeValue
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= storage.length else { return false }
            var found = false
            storage.enumerateAttribute(.attachment, in: range) { attachment, _, stop in
                if attachment is MinisStatusIconAttachment { found = true; stop.pointee = true }
            }
            return found
        }
    }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard selectedProjectionContainsIcons else { return super.writeSelection(to: pasteboard, type: type) }
        guard type == .string, let storage = textStorage else { return false }
        let text = selectedRanges.compactMap { value -> String? in
            let range = value.rangeValue
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= storage.length else { return nil }
            return ChatTranscriptStatusIconProjection.copyText(storage.attributedSubstring(from: range))
        }.joined(separator: "\n")
        return pasteboard.setString(text, forType: .string)
    }
}
