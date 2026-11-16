import Testing
import Foundation
import AppKit
@testable import MinisCanvasApp

// MARK: - AJ-26/AJ-27：文档全选 + 全文/气泡复制

@Suite("文档全选与复制（AJ-26/AJ-27）", .serialized)
@MainActor
struct CopyAndSelectAllTests {

    // MARK: Markdown 富文本构建（NSTextView 只读渲染数据源）

    @Test func markdownBuildPreservesHeadingAndParagraph() {
        let attr = MarkdownAttributedTextBuilder.build(content: "# 标题\n\n正文段落", isMarkdown: true)
        #expect(attr.string.contains("标题"))
        #expect(attr.string.contains("正文段落"))

        // 标题应使用更大字号（富样式保留）
        var foundHeadingFont = false
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            if let font = value as? NSFont, font.pointSize > 13 {
                foundHeadingFont = true
            }
        }
        #expect(foundHeadingFont)
    }

    @Test func markdownBuildPreservesCodeBlock() throws {
        let attr = MarkdownAttributedTextBuilder.build(content: "```swift\nlet a = 1\n```", isMarkdown: true)
        #expect(attr.string.contains("let a = 1"))
        let codeRange = (attr.string as NSString).range(of: "let a = 1")
        try #require(codeRange.location != NSNotFound)
        let style = attr.attribute(.paragraphStyle, at: codeRange.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.textBlocks.last?.backgroundColor != nil)
    }

    @Test func markdownBuildPreservesListItems() {
        let attr = MarkdownAttributedTextBuilder.build(content: "- 甲\n- 乙", isMarkdown: true)
        #expect(attr.string.contains("甲"))
        #expect(attr.string.contains("乙"))
    }

    @Test func markdownBuildPreservesTableHeader() {
        let attr = MarkdownAttributedTextBuilder.build(content: "| 列A | 列B |\n|---|---|\n| 1 | 2 |", isMarkdown: true)
        #expect(attr.string.contains("列A"))
        #expect(attr.string.contains("列B"))
    }

    @Test func builderOnlyAndFormattedTableKeepReadableNativeCellLines() throws {
        // One source-requested factory sample, before any layoutManager
        // access. The TextKit 2 getter itself does not force compatibility.
        do {
            let factoryProbe = NSTextView.scrollableTextView()
            let factoryText = try #require(factoryProbe.documentView as? NSTextView)
            let isTextKit2 = factoryText.textLayoutManager != nil
            print("GOAL22_TEXTKIT_FACTORY_IS_TK2=\(isTextKit2) inspectedSDK=26.5 apiAvailableFrom=macOS12 os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        }
        let approval = "每条命令都会弹确认卡片；你可以选择只批准这一次，或在该项目内记住。"
        let modification = "修改操作需要本次确认，完成后应保留原始正文、复制内容和可读的表格列宽。"
        let markdown = """
            | 项目 | 说明 |
            | --- | --- |
            | 审批 | \(approval) |
            | 交互式命令 | 等待用户输入后继续执行，不跳过确认。 |
            | 修改操作 | \(modification) |
            | 文件 | 只读取本次授权的合成文件。 |
            | 完成 | 保留结果和原始消息。 |
            """
        let message = ChatMessageUI(role: .assistant, content: markdown)
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let plainBefore = ChatTranscriptFormatter.plainText([message])
        let accessibleBefore = ChatTranscriptFormatter.accessibilityText([message])
        let exportBefore = SessionMarkdownExport.markdown(title: "合成表格", messages: [message], redactor: redactor)
        let builder = MarkdownAttributedTextBuilder.build(content: markdown, isMarkdown: true, baseSize: 13)
        let formatted = ChatTranscriptFormatter.formattedMessage(message, baseSize: 13, redactor: nil)
        #expect(formatted.string == "助手\n" + builder.string)

        // Mount the existing production read-only consumer in an owned,
        // non-key native host. Never activate or replace the user's window.
        func measure(_ source: NSAttributedString, width: CGFloat, phase: String, inspectTable: Bool = true) throws
            -> [(lines: Int, maxUsedWidth: CGFloat, maxCharacters: Int)] {
            let safe = ReadOnlyAttributedTextView.sanitized(source)
            #expect(Array(safe.string.utf16) == Array(source.string.utf16))
            let document = ChatTranscriptFormattedDocument(attributedString: safe, messageStartLocations: [0])
            let component = ReadOnlyAttributedTextView(transcriptDocument: document,
                update: ChatTranscriptStorageUpdate(revision: 1, generation: 1,
                    replacementStart: nil, replacement: nil))
            let coordinator = component.makeCoordinator()
            let scroll = component.makeNSView(coordinator: coordinator)
            let view = try #require(scroll.documentView as? NSTextView)
            let lease = NativeTestHostLifecycle.begin("Goal22TableCopy", requestActivation: false)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 2000),
                styleMask: [.titled], backing: .buffered, defer: false)
            NativeTestHostLifecycle.bind(lease, to: window)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
            view.frame = scroll.bounds
            defer {
                window.makeFirstResponder(nil)
                ReadOnlyAttributedTextView.dismantleNSView(scroll, coordinator: coordinator)
                window.orderOut(nil)
                window.contentView = nil
                window.close()
                NativeTestHostLifecycle.end(window)
                withExtendedLifetime(coordinator) {}
            }
            let container = try #require(view.textContainer)
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            window.layoutIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            try #require(view.window === window)
            try #require(window.makeFirstResponder(view))
            let manager = try #require(view.layoutManager)
            manager.ensureLayout(for: container)
            var observations: [(lines: Int, maxUsedWidth: CGFloat, maxCharacters: Int)] = []
            for cell in (inspectTable ? [approval, modification] : []) {
                let characters = (view.string as NSString).range(of: cell)
                try #require(characters.location != NSNotFound)
                let style = try #require(safe.attribute(.paragraphStyle, at: characters.location,
                    effectiveRange: nil) as? NSParagraphStyle)
                #expect(style.textBlocks.contains { $0 is NSTextTableBlock })
                let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                try #require(glyphs.length > 0)
                var lines = 0, maxCharacters = 0
                var maxUsedWidth: CGFloat = 0
                manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, lineGlyphs, _ in
                    let intersection = NSIntersectionRange(glyphs, lineGlyphs)
                    guard intersection.length > 0 else { return }
                    let lineCharacters = manager.characterRange(forGlyphRange: intersection,
                        actualGlyphRange: nil)
                    lines += 1
                    maxCharacters = max(maxCharacters, NSIntersectionRange(characters, lineCharacters).length)
                    maxUsedWidth = max(maxUsedWidth, used.width)
                    #expect(used.width.isFinite && used.width > 0)
                }
                try #require(lines > 0)
                print("GOAL22_TABLE_NATIVE phase=\(phase) width=\(width) cell=\(observations.count) lines=\(lines) maxUsedWidth=\(maxUsedWidth) maxCharacters=\(maxCharacters)")
                observations.append((lines, maxUsedWidth, maxCharacters))
            }
            if source.string.contains("表格前文") {
                func glyphRect(_ text: String) throws -> NSRect {
                    let range = (view.string as NSString).range(of: text)
                    try #require(range.location != NSNotFound)
                    let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    return manager.boundingRect(forGlyphRange: glyphs, in: container)
                }
                let before = try glyphRect("表格前文")
                let after = try glyphRect("表格后文")
                // A label such as “说明” also occurs in the preceding prose.
                // Only native table-cell effective ranges belong to this union.
                var tableGlyphRanges: [NSRange] = []
                safe.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: safe.length)) { value, characters, _ in
                    guard let style = value as? NSParagraphStyle,
                          style.textBlocks.contains(where: { $0 is NSTextTableBlock }) else { return }
                    tableGlyphRanges.append(manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil))
                }
                try #require(!tableGlyphRanges.isEmpty, "UNKNOWN: no native table-cell glyph ranges")
                var tableBounds = NSRect.null
                for glyphs in tableGlyphRanges {
                    let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                    try #require(!rect.isEmpty && rect.height.isFinite && rect.height < CGFloat.greatestFiniteMagnitude,
                                 "UNKNOWN: no finite visible table glyph bounds")
                    tableBounds = tableBounds.union(rect)
                }
                let leading = tableBounds.minX
                let trailing = width - tableBounds.maxX
                let beforeGap = tableBounds.minY - before.maxY
                let afterGap = after.minY - tableBounds.maxY
                print("GOAL22_TABLE_READING phase=\(phase) width=\(width) tableBounds=\(tableBounds) leading=\(leading) trailing=\(trailing) beforeGap=\(beforeGap) afterGap=\(afterGap)")
                #expect(leading >= ChatReadingLayout.horizontalInset)
                #expect(trailing >= ChatReadingLayout.horizontalInset)
                #expect(tableBounds.width <= ChatReadingLayout.maxContentWidth)
                #expect(beforeGap > 0)
                #expect(afterGap > 0)
                // Usage rectangles include typographic line height. Measure actual ink
                // by drawing this same laid-out glyph range, without re-typesetting.
                func nativeInkBounds(_ glyphs: NSRange, lineRect: NSRect) throws -> NSRect {
                    try #require(glyphs.length > 0 && lineRect.height.isFinite && lineRect.height > 0)
                    let allocation = manager.boundingRect(forGlyphRange: glyphs, in: container)
                        .union(lineRect).insetBy(dx: -lineRect.height, dy: -lineRect.height).integral
                    let scale: CGFloat = 2 // two bitmap pixels per native layout point
                    let pixelWidthValue = ceil(allocation.width * scale)
                    let pixelHeightValue = ceil(allocation.height * scale)
                    try #require(allocation.minX.isFinite && allocation.minY.isFinite &&
                        pixelWidthValue.isFinite && pixelHeightValue.isFinite &&
                        pixelWidthValue > 0 && pixelHeightValue > 0 &&
                        pixelWidthValue < CGFloat(Int.max / 4) && pixelHeightValue < CGFloat(Int.max / 4))
                    let pixelWidth = Int(pixelWidthValue), pixelHeight = Int(pixelHeightValue)
                    let bytesPerRow = pixelWidth * 4
                    let (byteCount, overflow) = bytesPerRow.multipliedReportingOverflow(by: pixelHeight)
                    try #require(!overflow && byteCount > 0)
                    let pixelMemory = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
                    pixelMemory.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
                    defer { pixelMemory.deallocate() }
                    do {
                        // Explicit byte order: R,G,B,A; transparent 8-bit premultiplied alpha.
                        let context = try #require(CGContext(data: pixelMemory,
                            width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                CGImageAlphaInfo.premultipliedLast.rawValue))
                        try #require(context.data == pixelMemory)
                        let bytes = UnsafeMutableBufferPointer(
                            start: pixelMemory.assumingMemoryBound(to: UInt8.self), count: byteCount)
                        try #require(context.ctm.isIdentity)
                        // Calibrate memory row/column direction against an actual device
                        // pixel. Do not assume that bitmap row zero means native top.
                        context.saveGState()
                        context.setShouldAntialias(false)
                        // Use components in this exact device space, not a generic
                        // CGColor that Quartz may color-convert before byte storage.
                        context.setFillColorSpace(CGColorSpaceCreateDeviceRGB())
                        context.setFillColor([1, 0, 0, 1])
                        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                        context.restoreGState()
                        context.flush()
                        var originPixels: [(x: Int, y: Int)] = []
                        for y in 0..<pixelHeight {
                            for x in 0..<pixelWidth where bytes[y * bytesPerRow + x * 4 + 3] > 0 {
                                originPixels.append((x, y))
                            }
                        }
                        let origin = try #require(originPixels.first)
                        try #require(originPixels.count == 1 &&
                            (origin.x == 0 || origin.x == pixelWidth - 1) &&
                            (origin.y == 0 || origin.y == pixelHeight - 1))
                        let originByte = origin.y * bytesPerRow + origin.x * 4
                        try #require(bytes[originByte] == 255 && bytes[originByte + 1] == 0 &&
                            bytes[originByte + 2] == 0 && bytes[originByte + 3] == 255)
                        context.clear(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
                        // Native container coordinates run downwards. This explicit
                        // CTM maps them into the calibrated bitmap's device space.
                        context.translateBy(x: 0, y: CGFloat(pixelHeight))
                        context.scaleBy(x: scale, y: -scale)
                        context.translateBy(x: -allocation.minX, y: -allocation.minY)
                        let deviceToNative = context.ctm.inverted()
                        do {
                            NSGraphicsContext.saveGraphicsState()
                            defer { NSGraphicsContext.restoreGraphicsState() }
                            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                            manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
                        }
                        context.flush()
                        var minX = pixelWidth, minY = pixelHeight, maxX = -1, maxY = -1
                        for y in 0..<pixelHeight {
                            for x in 0..<pixelWidth where bytes[y * bytesPerRow + x * 4 + 3] > 0 {
                                let deviceX = origin.x == 0 ? x : pixelWidth - 1 - x
                                let deviceY = origin.y == 0 ? y : pixelHeight - 1 - y
                                minX = min(minX, deviceX); maxX = max(maxX, deviceX)
                                minY = min(minY, deviceY); maxY = max(maxY, deviceY)
                            }
                        }
                        // Empty or edge-clipped observations have no valid ink metric.
                        try #require(maxX >= minX && maxY >= minY && minX > 0 && minY > 0 &&
                            maxX < pixelWidth - 1 && maxY < pixelHeight - 1)
                        let deviceInk = CGRect(x: CGFloat(minX), y: CGFloat(minY),
                            width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
                        let ink = deviceInk.applying(deviceToNative)
                        try #require(ink.minX.isFinite && ink.minY.isFinite &&
                            ink.width.isFinite && ink.height.isFinite && !ink.isEmpty &&
                            lineRect.intersects(ink))
                        return ink
                    }
                }
                var cellLineGaps: [CGFloat] = []
                for text in [approval, modification] {
                    let range = (view.string as NSString).range(of: text)
                    try #require(range.location != NSNotFound)
                    let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    var nativeLines: [(glyphs: NSRange, rect: NSRect)] = []
                    manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, lineGlyphs, _ in
                        let intersection = NSIntersectionRange(glyphs, lineGlyphs)
                        if intersection.length > 0 { nativeLines.append((intersection, rect)) }
                    }
                    try #require(!nativeLines.isEmpty)
                    var previous: NSRect?
                    for line in nativeLines {
                        let ink = try nativeInkBounds(line.glyphs, lineRect: line.rect)
                        if let previous { cellLineGaps.append(ink.minY - previous.maxY) }
                        previous = ink
                    }
                }
                try #require(!cellLineGaps.isEmpty, "UNKNOWN: no adjacent native cell ink lines")
                print("GOAL22_TABLE_READING_LINES phase=\(phase) inkGapsPoints=\(cellLineGaps) pixelsPerPoint=2")
                #expect(cellLineGaps.allSatisfy { $0 > 0 })
                // Actual role/background painting remains a Release LIVE
                // screenshot requirement; paragraph attributes cannot prove it.
            }
            // Native copy writes only to an isolated synthetic pasteboard;
            // the user's general clipboard is never read or replaced.
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            view.selectAll(nil)
            let nonKeyRange = view.selectedRange()
            let nonKeySelectedLength = nonKeyRange.location != NSNotFound
                && NSMaxRange(nonKeyRange) <= safe.length
                ? view.textStorage?.attributedSubstring(from: nonKeyRange).length ?? -1 : -1
            let nonKeyWrote = view.writeSelection(to: pasteboard, types: [.string])
            let nonKeyCopied = pasteboard.string(forType: .string)
            let nonKeyCopiedLength = nonKeyCopied?.utf16.count ?? -1
            if phase == "plain-control" {
                // The single-type API requires its type to be declared first
                // (NSTextView.h); compare it on the same owned selection.
                pasteboard.clearContents()
                pasteboard.declareTypes([.string], owner: nil)
                let singleTypeWrote = view.writeSelection(to: pasteboard, type: .string)
                let singleTypeCopied = pasteboard.string(forType: .string)
                print("GOAL22_PLAIN_COPY_API_COMPARE typesWrote=\(nonKeyWrote) typesResult=\(String(describing: nonKeyCopied)) singleTypeWrote=\(singleTypeWrote) singleTypeResult=\(String(describing: singleTypeCopied)) selectedLength=\(nonKeySelectedLength)")
            }
            // Test-owned key/first-responder lifecycle only; no application
            // activation and no general pasteboard or user window access.
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.makeKeyAndOrderFront(nil)
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            try #require(window.makeFirstResponder(view))
            view.selectAll(nil)
            #expect(view.selectedRange() == NSRange(location: 0, length: safe.length))
            #expect(view.window?.firstResponder === view)
            let legacyString = NSPasteboard.PasteboardType(rawValue: "NSStringPboardType")
            let plainTextFlavor = try #require(view.writablePasteboardTypes.first {
                $0 == .string || $0 == legacyString
            }, "native consumer must publish a supported plain-text flavor")
            let selected = view.selectedRange()
            let selectedLength = selected.location != NSNotFound && NSMaxRange(selected) <= safe.length
                ? view.textStorage?.attributedSubstring(from: selected).length ?? -1 : -1
            let wroteSelection = view.writeSelection(to: pasteboard, types: [plainTextFlavor])
            let copied = pasteboard.string(forType: plainTextFlavor)
            print("GOAL22_TABLE_COPY_CONTROL phase=\(phase) width=\(width) nonKeySelectedLength=\(nonKeySelectedLength) nonKeyWrote=\(nonKeyWrote) nonKeyCopiedLength=\(nonKeyCopiedLength) isKey=\(window.isKeyWindow) selectedLength=\(selectedLength) expectedLength=\(safe.length) flavor=\(plainTextFlavor.rawValue) wrote=\(wroteSelection) copiedLength=\(copied?.utf16.count ?? -1) writableTypes=\(view.writablePasteboardTypes.map(\.rawValue))")
            #expect(selectedLength == safe.length)
            #expect(wroteSelection)
            #expect(copied == safe.string)
            return observations
        }

        _ = try measure(NSAttributedString(string: "合成复制短句", attributes: [.font: NSFont.systemFont(ofSize: 13)]),
            width: 500, phase: "plain-control", inspectTable: false)
        let builder500 = try measure(builder, width: 500, phase: "builder")
        let formatter500 = try measure(formatted, width: 500, phase: "formatter")
        let builder900 = try measure(builder, width: 900, phase: "builder")
        let formatter900 = try measure(formatted, width: 900, phase: "formatter")
        for index in builder500.indices {
            // Relative comparison distinguishes a formatter-only collapse
            // from a builder/native-table problem. Avoid pixel snapshots.
            #expect(formatter500[index].maxCharacters >= 4)
            #expect(formatter900[index].maxCharacters >= 4)
            #expect(formatter500[index].maxUsedWidth >= builder500[index].maxUsedWidth * 0.65)
            #expect(formatter900[index].maxUsedWidth >= builder900[index].maxUsedWidth * 0.65)
            #expect(formatter500[index].lines <= builder500[index].lines + 2)
            #expect(formatter900[index].lines <= builder900[index].lines + 2)
            #expect(builder900[index].lines <= builder500[index].lines)
            #expect(formatter900[index].lines <= formatter500[index].lines)
        }
        for role in [ChatRole.user, .assistant] {
            let body = "表格前文：这段说明位于表格前面，保留原生阅读栏和段落。\n\n" + markdown
                + "\n\n表格后文：表格结束后继续正常阅读和复制。"
            let roleMessage = ChatMessageUI(role: role, content: body)
            let label = role == .user ? "用户" : "助手"
            let roleFormatted = ChatTranscriptFormatter.formattedMessage(roleMessage,
                baseSize: 13, redactor: nil)
            for viewportWidth in [CGFloat(500), 900] {
                // Same production maxContentWidth fact; no fixture padding.
                _ = try measure(roleFormatted, width: min(viewportWidth, ChatReadingLayout.maxContentWidth),
                    phase: "reading-" + label)
            }
            #expect(roleMessage.content == body)
            #expect(ChatTranscriptFormatter.plainText([roleMessage]) == "【" + label + "】\n" + body)
            #expect(ChatTranscriptFormatter.accessibilityText([roleMessage]) == label + "：" + body)
            #expect(SessionMarkdownExport.markdown(title: "合成表格", messages: [roleMessage], redactor: redactor)
                == "# 合成表格\n\n## " + label + "\n\n" + body + "\n")
        }
        #expect(message.content == markdown)
        #expect(plainBefore == "【助手】\n" + markdown)
        #expect(accessibleBefore == "助手：" + markdown)
        #expect(ChatTranscriptFormatter.plainText([message]) == plainBefore)
        #expect(ChatTranscriptFormatter.accessibilityText([message]) == accessibleBefore)
        #expect(SessionMarkdownExport.markdown(title: "合成表格", messages: [message], redactor: redactor) == exportBefore)
        #expect(exportBefore == "# 合成表格\n\n## 助手\n\n" + markdown + "\n")
    }

    @Test func plainTextBuildIsMonospaced() {
        let attr = MarkdownAttributedTextBuilder.build(content: "纯文本内容", isMarkdown: false)
        #expect(attr.string == "纯文本内容")
        if let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        }
    }

    @Test func emptyPlainTextDoesNotCrash() {
        let attr = MarkdownAttributedTextBuilder.build(content: "", isMarkdown: false)
        #expect(attr.string == "")
    }

    @Test func readOnlyTextSelectionPolicyClampsAndPreservesRanges() {
        let selected = [
            NSValue(range: NSRange(location: 2, length: 5)),
            NSValue(range: NSRange(location: 20, length: 10))
        ]

        let preserved = ReadOnlyAttributedTextView.preservedSelectionRanges(
            selected,
            contentLength: 8
        )

        #expect(preserved.map { $0.rangeValue } == [
            NSRange(location: 2, length: 5),
            NSRange(location: 8, length: 0)
        ])
    }

    @Test func readOnlyTextSelectionPolicyDoesNotRewriteEqualContent() {
        let content = NSAttributedString(string: "same")

        #expect(!ReadOnlyAttributedTextView.shouldReplaceTextStorage(
            current: content,
            replacement: NSAttributedString(string: "same")
        ))
        #expect(ReadOnlyAttributedTextView.shouldReplaceTextStorage(
            current: content,
            replacement: NSAttributedString(string: "changed")
        ))
    }

    @Test func transcriptFormatterKeepsAllMessagesAndRoleBoundaries() {
        let messages = [
            ChatMessageUI(role: .user, content: "请读取文件"),
            ChatMessageUI(role: .assistant, content: "已读取\n第二行"),
            ChatMessageUI(role: .system, content: "已完成")
        ]

        #expect(ChatTranscriptFormatter.plainText(messages) == "【用户】\n请读取文件\n\n【助手】\n已读取\n第二行\n\n【系统】\n已完成")
    }

    @Test func transcriptFormatterReturnsEmptyForNoMessages() {
        #expect(ChatTranscriptFormatter.plainText([]).isEmpty)
    }

    @Test func transcriptFormatterUsesVisibleContentAndKeepsAttachmentLabels() {
        let attachment = ChatAttachment(
            kind: .file,
            fileName: "design.pdf",
            fileType: .unknown,
            fileURL: "/tmp/design.pdf"
        )
        let message = ChatMessageUI(
            role: .user,
            content: "请查看\n\n我上传了文件 design.pdf：\n隐藏注入内容",
            attachments: [attachment]
        )

        #expect(ChatTranscriptFormatter.plainText([message]) == "【用户】\n请查看\n附件：design.pdf")
    }

    @Test func transcriptAttributedStringGivesRolesDistinctVisualStyles() {
        let attributed = ChatTranscriptFormatter.attributedString([
            ChatMessageUI(role: .user, content: "用户内容"),
            ChatMessageUI(role: .assistant, content: "助手内容")
        ])
        let userTitleRange = (attributed.string as NSString).range(of: "用户\n")
        let assistantTitleRange = (attributed.string as NSString).range(of: "助手\n")
        let userRange = (attributed.string as NSString).range(of: "用户内容")
        let assistantRange = (attributed.string as NSString).range(of: "助手内容")
        let userTitle = attributed.attribute(.paragraphStyle, at: userTitleRange.location, effectiveRange: nil) as? NSParagraphStyle
        let assistantTitle = attributed.attribute(.paragraphStyle, at: assistantTitleRange.location, effectiveRange: nil) as? NSParagraphStyle
        let userParagraph = attributed.attribute(.paragraphStyle, at: userRange.location, effectiveRange: nil) as? NSParagraphStyle
        let assistantParagraph = attributed.attribute(.paragraphStyle, at: assistantRange.location, effectiveRange: nil) as? NSParagraphStyle

        #expect(userTitleRange.location == 0)
        #expect(assistantTitleRange.location > userRange.location)
        #expect(userTitle?.alignment == .right)
        #expect(assistantTitle?.alignment == .left)
        #expect(userTitle?.tailIndent == -80) // 28pt inset + 44pt copy/edit clearance + 8pt gap
        #expect(assistantTitle?.tailIndent == -56) // 28pt inset + 20pt copy clearance + 8pt gap
        #expect(userParagraph?.alignment == .right)
        #expect(assistantParagraph?.alignment == .left)
        #expect(userParagraph?.tailIndent == -28) // Body reading column is unchanged.
    }

    @Test func transcriptAttributedStringUsesReadableMessageInsets() {
        let attributed = ChatTranscriptFormatter.attributedString([
            ChatMessageUI(role: .user, content: "用户内容"),
            ChatMessageUI(role: .assistant, content: "助手内容")
        ])
        let userBodyRange = (attributed.string as NSString).range(of: "用户内容")
        let assistantBodyRange = (attributed.string as NSString).range(of: "助手内容")

        let userBody = attributed.attribute(
            .paragraphStyle,
            at: userBodyRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let assistantBody = attributed.attribute(
            .paragraphStyle,
            at: assistantBodyRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle

        // Message bodies need a visible content column on both sides. Without these
        // insets, long assistant/user messages read as one unstructured text wall.
        #expect(userBody?.firstLineHeadIndent ?? 0 >= 24)
        #expect(userBody?.tailIndent ?? 0 <= -24)
        #expect(assistantBody?.firstLineHeadIndent ?? 0 >= 24)
        #expect(assistantBody?.tailIndent ?? 0 <= -24)
        #expect(userBody?.paragraphSpacingBefore ?? 0 >= 8)
        #expect(assistantBody?.paragraphSpacingBefore ?? 0 >= 8)
    }

    @Test func transcriptVisibleRoleTitlesKeepPlainCopyAndAccessibilityContracts() {
        let messages = [
            ChatMessageUI(role: .user, content: "用户正文"),
            ChatMessageUI(role: .assistant, content: "助手正文")
        ]
        let attributed = ChatTranscriptFormatter.attributedString(messages)

        #expect(attributed.string.contains("用户\n用户正文"))
        #expect(attributed.string.contains("助手\n助手正文"))
        #expect(!attributed.string.contains("【用户】"))
        #expect(!attributed.string.contains("【助手】"))
        #expect(ChatTranscriptFormatter.plainText(messages) == "【用户】\n用户正文\n\n【助手】\n助手正文")
        #expect(ChatTranscriptFormatter.accessibilityText(messages) == "用户：用户正文\n\n助手：助手正文")
    }

    @Test func roleBackgroundUsesParagraphBlocksAndSurvivesSanitization() throws {
        let messages = [
            ChatMessageUI(role: .user, content: "用户正文"),
            ChatMessageUI(role: .assistant, content: "助手正文")
        ]
        let attributed = ChatTranscriptFormatter.attributedString(messages, palette: .light)
        let safe = ReadOnlyAttributedTextView.sanitized(attributed)
        let text = safe.string as NSString
        let userTitle = text.range(of: "用户\n")
        let userBody = text.range(of: "用户正文")
        let assistantTitle = text.range(of: "助手\n")
        let assistantBody = text.range(of: "助手正文")
        let userMessageLength = ChatTranscriptFormatter.formattedMessage(
            messages[0], baseSize: 13, redactor: nil, palette: .light
        ).length
        let separatorLength = ChatTranscriptFormatter.separatorDocument().length
        try #require(userTitle.location != NSNotFound)
        try #require(userBody.location != NSNotFound)
        try #require(assistantTitle.location != NSNotFound)
        try #require(assistantBody.location != NSNotFound)
        try #require(userMessageLength >= userBody.upperBound)
        try #require(userMessageLength + separatorLength <= safe.length)
        let separator = NSRange(location: userMessageLength, length: separatorLength)
        let bodyTail = NSRange(
            location: userBody.upperBound,
            length: userMessageLength - userBody.upperBound
        )
        func block(at location: Int) -> NSTextBlock? {
            let style = safe.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            return style?.textBlocks.first
        }

        #expect(userTitle.location == 0)
        #expect(safe.string == attributed.string)
        #expect((text.substring(with: bodyTail)) == "\n") // Markdown paragraph's own trailing newline.
        #expect(separator.length == 2)
        #expect(text.substring(with: separator) == "\n\n")
        #expect(assistantTitle.location == separator.upperBound)
        #expect(block(at: userTitle.location)?.backgroundColor != nil)
        #expect(block(at: userBody.location)?.backgroundColor != nil)
        #expect(block(at: assistantTitle.location)?.backgroundColor != nil)
        #expect(block(at: assistantBody.location)?.backgroundColor != nil)
        #expect(block(at: userBody.upperBound) != nil)
        for location in separator.location..<separator.upperBound {
            let rawStyle = attributed.attribute(
                .paragraphStyle, at: location, effectiveRange: nil
            ) as? NSParagraphStyle
            let expectation561_1 = (rawStyle?.textBlocks ?? []).isEmpty
            #expect(expectation561_1)
            #expect(block(at: location) == nil)
        }
        #expect(block(at: userBody.location)?.backgroundColor != block(at: assistantBody.location)?.backgroundColor)
    }

    @Test func oneNativeTextViewSelectsAcrossVisibleRoleBoundaries() {
        let messages = [
            ChatMessageUI(role: .user, content: "第一条正文"),
            ChatMessageUI(role: .assistant, content: "第二条正文")
        ]
        let content = ReadOnlyAttributedTextView.sanitized(
            ChatTranscriptFormatter.attributedString(messages)
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        textView.isEditable = false
        textView.isSelectable = true
        textView.textStorage?.setAttributedString(content)
        textView.selectAll(nil)
        #expect(textView.selectedRange() == NSRange(location: 0, length: content.length))

        let text = textView.string as NSString
        let first = text.range(of: "第一条正文")
        let second = text.range(of: "第二条正文")
        textView.setSelectedRange(NSRange(location: first.location, length: second.upperBound - first.location))
        let selected = text.substring(with: textView.selectedRange())
        #expect(selected.contains("第一条正文"))
        #expect(selected.contains("助手\n第二条正文"))
        #expect(ChatTranscriptFormatter.plainText(messages).contains("【助手】\n第二条正文"))
    }

    @Test func transcriptBodyDoesNotApplyPerCharacterBackgroundColor() {
        let attributed = ChatTranscriptFormatter.attributedString([
            ChatMessageUI(role: .user, content: "干净正文"),
            ChatMessageUI(role: .assistant, content: "另一段正文")
        ])
        let range = NSRange(location: 0, length: attributed.length)
        var backgroundCount = 0
        attributed.enumerateAttribute(.backgroundColor, in: range) { value, _, _ in
            if value != nil { backgroundCount += 1 }
        }

        #expect(backgroundCount == 0)
    }

    @Test func contextPanelWidthDragPreservesRequestAndDynamicLayoutBounds() {
        var state = ContextPanelWidthDragState(width: 300)
        state.beginDrag()
        state.apply(10_000)
        #expect(state.width == 10_300)
        var effectiveRightWidths: [Double] = []
        for width in [600.0, 800.0, 1_000.0, 1_280.0, 1_600.0] {
            let decision = AdaptiveLayoutPolicy.decision(
                for: width,
                preferredLeftWidth: 240,
                preferredRightWidth: state.width
            )
            #expect(decision.rightWidth >= AdaptiveLayoutPolicy.persistentRightMinimumWidth)
            #expect(decision.rightWidth <= decision.rightMaximumWidth)
            #expect(decision.rightWidth < state.width)
            if decision.rightPanel == .persistentCollapsible {
                #expect(decision.leftWidth + decision.rightWidth
                    + decision.mainMinimumWidth + 2 * AdaptiveLayoutPolicy.dividerWidth <= width)
            } else {
                #expect(decision.rightWidth + AdaptiveLayoutPolicy.dividerWidth <= width)
            }
            effectiveRightWidths.append(decision.rightWidth)
            #expect(state.width == 10_300)
        }
        #expect(effectiveRightWidths[4] > effectiveRightWidths[3])
        state.apply(-10_000)
        #expect(state.width == SidebarWidthMemory.minWidth)
        state.endDrag()
        #expect(state.dragStartWidth == nil)
        state.apply(500)
        #expect(state.width == SidebarWidthMemory.minWidth)
    }

    @Test func chatLayoutReservesVisibleComposerSpace() {
        #expect(ChatLayoutMetrics.composerMinimumHeight >= 44)
        #expect(ChatLayoutMetrics.composerLayoutPriority > ChatLayoutMetrics.messageListLayoutPriority)
    }

    @Test func transcriptMeasuresDocumentHeight() {
        let view = ReadOnlyAttributedTextView(
            attributedString: NSAttributedString(string: "长对话"),
            fitContentHeight: true
        )

        #expect(view.fitContentHeight)
    }

    @Test func transcriptRequestsMeasuredVisibleContentHeight() {
        let document = ChatTranscriptFormatter.formattedDocument([
            ChatMessageUI(role: .user, content: "可见正文")
        ])
        let update = ChatTranscriptStorageUpdate(
            revision: 1, generation: 1, replacementStart: nil, replacement: nil
        )
        // This is the transcript-specific constructor used by ChatSidebarView,
        // not the bubble constructor's default fitContentHeight parameter.
        let view = ReadOnlyAttributedTextView(transcriptDocument: document, update: update)

        #expect(view.fitContentHeight)
        #expect(view.attributedString.string == document.attributedString.string)
        #expect(view.transcriptUpdate?.revision == update.revision)
        let inset = NSSize(width: 0, height: 4)
        let short = ReadOnlyAttributedTextView.measuredContentHeight(
            usedRect: NSRect(x: 0, y: 0, width: 240, height: 20), inset: inset
        )
        let tall = ReadOnlyAttributedTextView.measuredContentHeight(
            usedRect: NSRect(x: 0, y: 0, width: 240, height: 60), inset: inset
        )
        #expect(short == 29)
        #expect(tall == 69)
        #expect(tall > short)
    }

    @Test func transcriptLayoutIdentityChangesWhenNewSessionGetsItsFirstMessage() {
        let sessionID = UUID()
        let empty = ChatTranscriptLayoutIdentity(sessionID: sessionID, messages: [])
        let firstMessage = ChatMessageUI(role: .user, content: "新会话正文")

        #expect(
            empty != ChatTranscriptLayoutIdentity(
                sessionID: sessionID,
                messages: [firstMessage]
            )
        )
    }

    @Test func transcriptLayoutIdentityChangesAcrossCopiedSessions() {
        let copiedMessage = ChatMessageUI(role: .user, content: "复制后的同一条消息")

        #expect(
            ChatTranscriptLayoutIdentity(sessionID: UUID(), messages: [copiedMessage])
                != ChatTranscriptLayoutIdentity(sessionID: UUID(), messages: [copiedMessage])
        )
    }

    @Test func transcriptLayoutIdentityStaysStableWhileOneMessageStreams() {
        let sessionID = UUID()
        let messageID = UUID()
        let firstChunk = ChatMessageUI(
            id: messageID,
            role: .assistant,
            content: "第一段",
            isStreaming: true
        )
        let secondChunk = ChatMessageUI(
            id: messageID,
            role: .assistant,
            content: "第一段第二段",
            isStreaming: true
        )

        #expect(
            ChatTranscriptLayoutIdentity(sessionID: sessionID, messages: [firstChunk])
                == ChatTranscriptLayoutIdentity(sessionID: sessionID, messages: [secondChunk])
        )
    }

    @Test func transcriptFormattedDocumentKeepsMessageAnchorsInBuildOrder() {
        let messages = [
            ChatMessageUI(role: .user, content: "第一条"),
            ChatMessageUI(role: .assistant, content: "第二条"),
            ChatMessageUI(role: .tool, content: "第三条")
        ]

        let document = ChatTranscriptFormatter.formattedDocument(messages)

        #expect(document.messageStartLocations.count == messages.count)
        #expect(document.messageStartLocations == document.messageStartLocations.sorted())
        #expect(document.attributedString.length > document.messageStartLocations.last!)
    }

    // MARK: 剪贴板工具

    @Test func copyToIsolatedPasteboardWritesString() {
        let pasteboard = makeIsolatedPasteboard()

        copyTextToClipboard("测试复制内容", pasteboard: pasteboard)

        #expect(pasteboard.copiedString == "测试复制内容")
        #expect(pasteboard.clearCount == 1)
    }

    // MARK: - AJ-27/C4-2 共享气泡按钮组件（ChatBubble / NodeChatBubble 统一）

    @MainActor
    @Test func bubbleCopyButtonIsInstantiableAndReusesActionButton() {
        var tapped = false
        // BubbleActionButton 可实例化，点击触发回调
        let actionView = BubbleActionButton(title: "复制", systemImage: "doc.on.doc", help: "h") {
            tapped = true
        }
        #expect(actionView.systemImage == "doc.on.doc")
        #expect(actionView.title == "复制")
        actionView.action()
        #expect(tapped)

        // BubbleCopyButton 复用 BubbleActionButton 并绑定剪贴板写入
        let pasteboard = makeIsolatedPasteboard()
        let copyView = BubbleCopyButton(content: "共享组件拷贝", pasteboard: pasteboard)
        copyView.action()
        #expect(pasteboard.copiedString == "共享组件拷贝")
        #expect(pasteboard.clearCount == 1)
    }

    private func makeIsolatedPasteboard() -> IsolatedPasteboard {
        IsolatedPasteboard()
    }

    private final class IsolatedPasteboard: PasteboardWriting {
        private(set) var copiedString: String?
        private(set) var clearCount = 0

        func clearContents() -> Int {
            clearCount += 1
            copiedString = nil
            return clearCount
        }

        func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
            guard dataType == .string else { return false }
            copiedString = string
            return true
        }
    }
}
