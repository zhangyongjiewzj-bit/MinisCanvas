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
        let text = source.string as NSString
        var found: [(range: NSRange, icon: MinisIcon, label: String, original: String)] = []
        var position = 0
        for character in source.string {
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
            manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, _ in
                guard lineGlyphs.length > 0 else { return }
                let character = manager.characterIndexForGlyph(at: lineGlyphs.location)
                guard character < storage.length,
                      let style = storage.attribute(.paragraphStyle, at: character,
                          effectiveRange: nil) as? NSParagraphStyle,
                      !style.textBlocks.contains(where: { $0 is NSTextTableBlock }),
                      let fill = style.textBlocks.first?.backgroundColor else { return }
                let surface = line.offsetBy(dx: origin.x, dy: origin.y).intersection(visibleDirty)
                guard !surface.isEmpty else { return }
                fill.setFill()
                surface.fill()
                // Ordinary nested blocks are the fenced-code surface. AppKit
                // does not paint that inner fill here, so composite it over the
                // role surface before the native selection and glyph pass.
                if style.textBlocks.count == 2, let codeFill = style.textBlocks.last?.backgroundColor {
                    codeFill.setFill()
                    surface.fill()
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
